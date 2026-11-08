-- 溶解效果提供者(移植自社区测试包 AVM_rand_perf 的 local.random2,2026-11-08)。
--
-- 别的 mod 可以注册一个"效果提供者",接管溶解用的着色器 / 贴图(比如换一种溶解图样);
-- **时机始终由 AVM 决定**(什么时候开始、走多快、什么时候结束都在 Dissolve.lua),提供者只管外观。
--
-- 提供者表(api_version = 1):
--   id                         字符串,≤ 96 字
--   effects                    效果 ID 列表(1..32 个,每个 ≤ 64 字,不能叫 "random")
--   name      可选             显示名:字符串,或 { ["zh-CN"] = ..., ["en-US"] = ... }
--   labels    可选             labels[效果 ID] = 显示名(同上两种写法)
--   default   可选             没存过选择(或存的效果已不存在)时用哪个效果;不给 = "random"
--   random_pool 可选           选"随机"时从哪些效果里抽(效果 ID 列表);不给 = 全部效果
--   supports(mesh, j, hint)    这个材质归不归它管,返回 true 才会绑定;hint 见 bind
--   begin_transaction(info)    info = { id, effect_id, source, source_key, hint };返回 false = 拒绝
--   bind_material(tx_id, mesh, j)
--   end_transaction(tx_id)     返回 false = 还没收尾好,下一帧再试
--   reset(reason)              注销 / 整体复位时调用
--   reset_mesh(mesh) 可选      定位预览等场合把这个 mesh 上的溶解立即复位时调用
--
-- 一次"事务" = 一个提供者在一个角色(scope 的 source)上的一轮过渡:第一个材质绑定时开始、
-- 按当时的选择定效果(选"随机"就在这里抽),这一轮里同一角色后续开始溶解的材质都加入它;
-- 事务里所有材质的溶解都结束后收尾。同时最多 16 个事务,超了就不绑定(照常用模板自带的溶解)。
--
-- 和测试包原版的区别:同一个材质在同一个事务里只绑定一次(原版血量驱动时每帧都重新 bind_material),
-- 没有事务时 update 直接返回;显示名可由提供者给出。
local M = {}

local MAX_PROVIDERS, MAX_TRANSACTIONS, MAX_EFFECTS = 4, 16, 32

-- 显示名只收字符串或 { 语言 = 字符串 },别的丢掉(要进快照,不能带函数 / 托管对象)
local function clean_label(v)
    if type(v) == "string" then return v:sub(1, 64) end
    if type(v) ~= "table" then return nil end
    local out
    for lang, s in pairs(v) do
        if type(lang) == "string" and #lang <= 16 and type(s) == "string" then
            out = out or {}
            out[lang] = s:sub(1, 64)
        end
    end
    return out
end

-- options = { load = fn() -> { [提供者 id] = 选择 }, save = fn(表) -> 成功?, random = fn(n) -> 1..n }
function M.new(options)
    options = options or {}
    local providers, order, transactions, selections = {}, {}, {}, {}
    if options.load then
        local ok, saved = pcall(options.load)
        if ok and type(saved) == "table" then
            for id, mode in pairs(saved) do
                if type(id) == "string" and type(mode) == "string" then selections[id] = mode end
            end
        end
    end
    local scope, serial = nil, 0
    local api = {}

    local function call(p, name, ...)
        local ok, result = pcall(p[name], ...)
        return ok and result ~= false, result
    end
    local function close(key, tx)
        if call(tx.provider, "end_transaction", tx.id) then transactions[key] = nil; return true end
        return false
    end

    -- 注册;返回注销函数
    function api.register(p)
        assert(type(p) == "table" and p.api_version == 1 and type(p.id) == "string" and #p.id <= 96, "Invalid effect provider")
        assert(not providers[p.id] and #order < MAX_PROVIDERS, "Duplicate or excessive effect provider")
        for _, name in ipairs({ "supports", "begin_transaction", "bind_material", "end_transaction", "reset" }) do
            assert(type(p[name]) == "function", "Missing provider method: " .. name)
        end
        local effects, seen, labels = {}, {}, {}
        for _, id in ipairs(p.effects or {}) do
            assert(type(id) == "string" and id ~= "random" and not seen[id] and #id <= 64, "Invalid effect ID")
            effects[#effects + 1] = id
            seen[id] = true
            labels[id] = type(p.labels) == "table" and clean_label(p.labels[id]) or nil
        end
        assert(#effects > 0 and #effects <= MAX_EFFECTS, "Invalid effect count")
        assert(p.default == nil or p.default == "random" or seen[p.default], "Invalid default effect")
        local pool = {}
        if type(p.random_pool) == "table" then
            for _, id in ipairs(p.random_pool) do if seen[id] then pool[#pool + 1] = id end end
        end
        if #pool == 0 then pool = effects end
        local record = { provider = p, effects = effects, allowed = seen, labels = labels, name = clean_label(p.name), pool = pool }
        providers[p.id] = record
        order[#order + 1] = p.id
        -- 没存过选择,或存的效果对不上(提供者更新后删了某个效果):用提供者的默认,没有默认就随机
        if selections[p.id] ~= "random" and not seen[selections[p.id]] then selections[p.id] = p.default or "random" end
        local removed = false
        return function()
            if removed then return end
            removed = true
            if providers[p.id] ~= record then return end
            call(p, "reset", "unregister")
            for key, tx in pairs(transactions) do if tx.provider == p then transactions[key] = nil end end
            providers[p.id] = nil
            for i, id in ipairs(order) do if id == p.id then table.remove(order, i); break end end
        end
    end

    -- 选效果("random" 或某个效果 ID);存盘失败就撤回。下一轮过渡生效
    function api.select(id, mode)
        local r = providers[id]
        if not r or (mode ~= "random" and not r.allowed[mode]) then return false, "Unknown provider/effect" end
        local previous = selections[id]
        selections[id] = mode
        if options.save then
            local copy = {}
            for k, v in pairs(selections) do copy[k] = v end
            local ok, result = pcall(options.save, copy)
            if not ok or result == false then selections[id] = previous; return false, "Effect preference was not saved" end
        end
        return true
    end

    -- 当前选择("random" 或效果 ID);提供者自己判断 supports 时用(比如内置样式选了"原样"就不接管)
    function api.selection(id) return selections[id] end

    -- 给界面:[{ id, name, mode, effects = { id... }, labels = { [id] = 显示名 } }]
    function api.list()
        local out = {}
        for _, id in ipairs(order) do
            local r = providers[id]
            local effects, labels = {}, {}
            for i, name in ipairs(r.effects) do
                effects[i] = name
                labels[name] = r.labels[name]
            end
            out[#out + 1] = { id = id, name = r.name, mode = selections[id], effects = effects, labels = labels }
        end
        return out
    end

    -- 当前在应用哪个角色(Main 的 apply_resolved 进出时设 / 清)。原样交给提供者,
    -- 让它按这个角色找 mesh,不用去猜"当前本地玩家"。不进快照、不存盘
    function api.scope(value)
        scope = value and { source = value, source_key = tostring(value) } or nil
    end

    -- 一个材质开始溶解(定时过渡开始 / 血量驱动进入中间段)时调用;返回有没有被某个提供者接管。
    -- hint = 这次过渡的附加信息(目前是 { preset = 溶解预设名 },内置样式用),原样交给 supports / begin_transaction
    function api.bind(mesh, j, hint)
        if not order[1] then return false end
        local row_key = tostring(mesh) .. "_" .. tostring(j)
        for _, id in ipairs(order) do
            local r = providers[id]
            local p = r.provider
            local ok, supported = pcall(p.supports, mesh, j, hint)
            if ok and supported == true then
                local key = id .. "|" .. (scope and scope.source_key or tostring(mesh))
                local tx = transactions[key]
                if tx and tx.rows[row_key] then return true end
                if not tx then
                    local n = 0
                    for _ in pairs(transactions) do n = n + 1 end
                    if n >= MAX_TRANSACTIONS then return false end
                    local effect = selections[id]
                    if effect == "random" then effect = r.pool[(options.random or math.random)(#r.pool)] end
                    serial = serial + 1
                    tx = { id = "avm-effect-" .. serial, provider = p, effect = effect, rows = {} }
                    if not call(p, "begin_transaction", {
                        id = tx.id, effect_id = effect,
                        source = scope and scope.source or nil,
                        source_key = scope and scope.source_key or nil,
                        hint = hint,
                    }) then return false end
                    transactions[key] = tx
                end
                if not call(p, "bind_material", tx.id, mesh, j) then return false end
                tx.rows[row_key] = { mesh = mesh, j = j }
                return true
            end
        end
        return false
    end

    -- 每帧:事务里没有材质还在溶解就收尾。is_animating(mesh, j) 由 Dissolve 给
    function api.update(is_animating)
        if next(transactions) == nil then return end
        for key, tx in pairs(transactions) do
            local busy = false
            for _, row in pairs(tx.rows) do
                local ok, on = pcall(is_animating, row.mesh, row.j)
                if ok and on then busy = true; break end
            end
            if not busy then close(key, tx) end
        end
    end

    -- 这个 mesh 上的溶解被立即复位(定位预览):通知提供者,把它的材质移出事务,空了就收尾
    function api.reset_mesh(mesh)
        if not order[1] and next(transactions) == nil then return end
        for _, id in ipairs(order) do
            local p = providers[id].provider
            if type(p.reset_mesh) == "function" then call(p, "reset_mesh", mesh) end
        end
        local mk = tostring(mesh)
        for key, tx in pairs(transactions) do
            for k, row in pairs(tx.rows) do if tostring(row.mesh) == mk then tx.rows[k] = nil end end
            if not next(tx.rows) then close(key, tx) end
        end
    end

    function api.reset(reason)
        for _, id in ipairs(order) do call(providers[id].provider, "reset", reason or "reset") end
        transactions = {}
        scope = nil
    end

    return api
end

return M
