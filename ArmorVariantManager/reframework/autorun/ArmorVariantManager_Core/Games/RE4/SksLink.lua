-- AVM → ShapeKeySystem(SKS,形态键插件)键组联动。
--
-- 定位(2026-11-09 和用户定的):SKS 的捏脸配置相当于一个角色的一份完整设定,归 SKS 自己管;
-- AVM 的状态组选项对应 SKS 的键组选项。所以 AVM 只说"这个角色的某个键组现在用哪个选项",
-- 不选 SKS 的配置,也不碰形态键数值。数据见 ModelV3 文件头(base.sks / groups[i].sks),
-- 解算见 ModelV3.sks_of。
--
-- 接口:`_G.ShapeKeySystemAPI`(SKS 1.1 起有 select_group_option)。没装 SKS 或版本更早时
-- 这里什么都不做,配置里的引用原样保留。
--
-- 发送规则:
--   * 每帧收集各目标解算出的 { 键组 -> 选项 },按 SKS 的角色标识合并(同一个人有玩家本体和
--     傀儡 / 雕像时玩家说了算),和上次发出去的比,只发变了的键组。
--   * 发送过的键组不再被任何一层写到时(比如状态组从带键组的选项切回「（无）」),发一次 0,
--     把这个键组还原成「（无）」,并从"已发送"里去掉,之后再写到时会重新发送。
--     从来没被 AVM 写过的键组不碰。想让它回到别的选项,在整套造型上写默认值。
--   * 角色不在场时不动它的记录,免得每次过场 / 加载回来都把用户在 SKS 里的手动调整冲掉。
--   * SKS 重置(ShapeKeySystemAPI 换成新表)后清空记录,下一帧全部重发;SKS 对重复选择
--     什么都不做,所以重发没有副作用。
--   * 发送失败(多半是当前 SKS 配置没有这个键组)记下错误码给界面看;SKS 每次扫描后
--     重试失败的键组(用户可能换了配置)。
local L = {}

L.OWNER = "ArmorVariantManager"

local api_ref = nil       -- 上次看到的接口表;换了 = SKS 重置过
local sent = {}           -- [角色标识] = { [键组] = 选项 | 0 }:已发出去的
local status = {}         -- [角色标识] = { [键组] = 错误码 }:发送失败的
local actor_cache = {}    -- [head 网格名] = 角色标识 | false
local view_cache = {}     -- [角色标识] = { time, view }

local function copy(t)
    local o = {}
    for k, v in pairs(t or {}) do o[k] = v end
    return o
end

local function on_scan()
    -- 换装 / 换配置后重试失败的键组
    for id, st in pairs(status) do
        local s = sent[id]
        if s then for g in pairs(st) do s[g] = nil end end
    end
    view_cache = {}
end

local function api()
    local a = rawget(_G, "ShapeKeySystemAPI")
    if type(a) ~= "table" or type(a.select_group_option) ~= "function" then a = nil end
    if a ~= api_ref then
        api_ref = a
        sent, status, actor_cache, view_cache = {}, {}, {}, {}
        if a and type(a.on) == "function" then pcall(a.on, "scan", on_scan) end
    end
    return a
end
L.api = api

function L.available() return api() ~= nil end

-- head 网格名(CharacterId.identify 的 head_mesh,如 "cha000_10")→ SKS 的角色标识
function L.actor_of(head_mesh)
    local a = api()
    if not a or type(head_mesh) ~= "string" or type(a.actor_of) ~= "function" then return nil end
    local hit = actor_cache[head_mesh]
    if hit == nil then
        local ok, id = pcall(a.actor_of, head_mesh)
        hit = (ok and type(id) == "string") and id or false
        actor_cache[head_mesh] = hit
    end
    return hit or nil
end

-- entries = { { head = head 网格名, want = { 键组 -> 选项 } | nil, player = bool }, ... }
function L.push(entries)
    local a = api()
    if not a then return end
    local by = {}
    for _, e in ipairs(entries or {}) do
        local id = L.actor_of(e.head)
        if id and (by[id] == nil or (e.player and not by[id].player)) then by[id] = e end
    end
    for id, e in pairs(by) do
        local want = e.want or {}
        local prev = sent[id] or {}
        local st = status[id] or {}
        for g, v in pairs(want) do
            if prev[g] ~= v then
                local ok, done, err = pcall(a.select_group_option, L.OWNER, g, v, { actor = id })
                if ok and done then st[g] = nil
                else st[g] = ok and (type(err) == "string" and err or "E_FAILED") or "E_CALL" end
                view_cache[id] = nil
            end
        end
        -- 上次发过、这次没有任何一层写到的键组:还原成「（无）」(之前就发送失败的不管,SKS 里本来没生效)
        for g in pairs(prev) do
            if want[g] == nil and not st[g] then
                pcall(a.select_group_option, L.OWNER, g, 0, { actor = id })
                view_cache[id] = nil
            end
        end
        for g in pairs(st) do if want[g] == nil then st[g] = nil end end
        sent[id] = copy(want)
        status[id] = next(st) and st or nil
    end
end

-- 编辑界面用:这个角色能选的键组(当前 SKS 配置的键组 + 这个角色所有配置里键组的并集)。
-- 返回 nil = 没装 SKS(或版本太旧);{ available = true } = 装了但这个角色 SKS 不驱动;
-- 否则 { available, actor, name, groups = { { name, options = {...}, inCurrent, value } }, errors }
-- value:当前配置里这个键组生效的选项名(不选时为 0)。结果缓存 1 秒
function L.view(head_mesh)
    local a = api()
    if not a then return nil end
    local id = L.actor_of(head_mesh)
    if not id then return { available = true } end
    local now = os.clock()
    local c = view_cache[id]
    if c and now - c.time < 1.0 then return c.view end

    local info
    local ok, list = pcall(a.actors)
    for _, x in ipairs(ok and type(list) == "table" and list or {}) do
        if type(x) == "table" and x.id == id then info = x; break end
    end
    local view = { available = true }
    if info then
        local rows, order = {}, {}
        local function add(groups, current)
            for _, kg in ipairs(type(groups) == "table" and groups or {}) do
                if type(kg) == "table" and type(kg.name) == "string" and kg.name ~= "" then
                    local row = rows[kg.name]
                    if not row then
                        row = { name = kg.name, options = {}, seen = {}, inCurrent = false }
                        rows[kg.name] = row
                        order[#order + 1] = row
                    end
                    for _, o in ipairs(type(kg.options) == "table" and kg.options or {}) do
                        if type(o) == "string" and not row.seen[o] then
                            row.seen[o] = true
                            row.options[#row.options + 1] = o
                        end
                    end
                    if current then
                        row.inCurrent = true
                        local v = tonumber(kg.value) or 0
                        row.value = (v > 0 and type(kg.options) == "table" and kg.options[v]) or 0
                    end
                end
            end
        end
        if type(a.key_groups) == "function" then
            local ok2, cur = pcall(a.key_groups, { actor = id })
            if ok2 then add(cur, true) end
        end
        if type(a.sculpt_presets) == "function" then
            local ok3, presets = pcall(a.sculpt_presets, info.folder)
            for _, p in ipairs(ok3 and type(presets) == "table" and presets or {}) do
                if type(p) == "table" then add(p.key_groups, false) end
            end
        end
        for _, row in ipairs(order) do row.seen = nil end
        view.actor, view.name, view.groups = id, info.name, order
        view.errors = copy(status[id])
    end
    view_cache[id] = { time = now, view = view }
    return view
end

-- 测试用:清空所有记录
function L._reset()
    api_ref, sent, status, actor_cache, view_cache = nil, {}, {}, {}, {}
end

return L
