local Dissolve = {}

-- 溶解过渡核心：把材质或部件的开关改成按时间推进的溶解，不依赖具体游戏。
-- 只作用于带 Dissolve_Rate 变量的材质（溶解模板），其他材质照旧瞬间开关。材质参数约定见 docs/DISSOLVE.md：
--   Dissolve_Rate  xyz = 溶解比例 0..1（0 完整，1 全部消失），w = Reversing（0 中心向外，1 外向中心）
--   Dissolve_Flag  y = IsMorphed（1 时可见判定反转）；其他分量保持 mdf 原值。没有 Dissolve_Flag 的材质照常溶解
-- 两种出现方式：
--   "morph"    出现方与消失方同时把比例从 0 推到 1，出现方置 IsMorphed，新外观在旧外观消失的位置原地长出；需要模板支持 IsMorphed
--   "reverse"  出现 = 消失倒放（比例 1 -> 0，IsMorphed 为 0），任何带 Dissolve_Rate 的模板都可用
-- forward = false 时比例从 1 走到 0 并置 Reversing（外向中心）；"reverse" 方式不区分方向。
-- 动画结束时关闭消失方，并把两个变量写回 mdf 原值。中途反向切换时从当前位置接着走。

Dissolve.MORPH, Dissolve.REVERSE = "morph", "reverse"
local RATE, FLAG = "Dissolve_Rate", "Dissolve_Flag"

-- settings = { duration = 秒, forward = 布尔, appear = "morph" | "reverse" }；nil 表示瞬间开关。
function Dissolve.settings(duration, forward, appear)
    return { duration = math.max(0, tonumber(duration) or 0), forward = forward ~= false,
        appear = appear == Dissolve.REVERSE and Dissolve.REVERSE or Dissolve.MORPH }
end

-- deps.clock() 秒；deps.vector(x, y, z, w) 构造引擎的 Vector4f。
function Dissolve.new(deps)
    deps = deps or {}
    local clock = deps.clock or os.clock
    local vector = deps.vector or function(x, y, z, w) return Vector4f.new(x, y, z, w) end
    local core = {}
    local current = nil      -- 本次写入使用的过渡（use）
    local var_cache = {}     -- 网格_序号_材质名 -> { rate, flag, flag0 } 或 false
    local materials = {}     -- 网格_序号 -> 动画
    local meshes = {}        -- 网格 -> 动画（整个部件）
    local last_clock = clock()

    local function try(fn, ...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        return nil
    end
    local function call(object, method, ...) return object:call(method, ...) end

    local function find_var(mesh, j)
        local name = try(call, mesh, "getMaterialName", j) or ""
        local key = tostring(mesh) .. "_" .. tostring(j) .. "_" .. name
        local v = var_cache[key]
        if v == nil then
            local rate, flag
            for k = 0, (try(call, mesh, "getMaterialVariableNum", j) or 0) - 1 do
                local n = try(call, mesh, "getMaterialVariableName", j, k)
                if n == RATE then rate = k elseif n == FLAG then flag = k end
            end
            v = false
            if rate then
                local f0 = flag and try(call, mesh, "getMaterialFloat4", j, flag)
                v = { rate = rate, flag = f0 and flag or nil, flag0 = f0 and { f0.x, f0.y, f0.z, f0.w } or nil, name = name }
            end
            var_cache[key] = v
        end
        return v or nil
    end

    local function write(a)
        local rate, mesh, j, v = a.rate, a.mesh, a.j, a.v
        try(call, mesh, "setMaterialFloat4", j, v.rate, vector(rate, rate, rate, a.reversing))
        if v.flag then
            local f = v.flag0
            try(call, mesh, "setMaterialFloat4", j, v.flag, vector(f[1], a.morphed, f[3], f[4]))
        end
    end

    local function restore(mesh, j, v)
        try(call, mesh, "setMaterialFloat4", j, v.rate, vector(0, 0, 0, 0))
        if v.flag then
            local f = v.flag0
            try(call, mesh, "setMaterialFloat4", j, v.flag, vector(f[1], f[2], f[3], f[4]))
        end
    end

    local function animation(mesh, j, v, show, previous)
        local a = { mesh = mesh, j = j, v = v, show = show, duration = current.duration }
        if previous then
            -- 保持当前遮罩，反切只改变比例的终点。
            a.rate, a.reversing, a.morphed = previous.rate, previous.reversing, previous.morphed
            a.target = previous.show == show and previous.target or 1 - previous.target
        elseif current.appear == Dissolve.REVERSE or not v.flag then
            a.rate, a.target = show and 1 or 0, show and 0 or 1
            a.reversing, a.morphed = 0, 0
        else
            a.rate, a.target = current.forward and 0 or 1, current.forward and 1 or 0
            a.reversing = current.forward and 0 or 1
            a.morphed = show == current.forward and 1 or 0
        end
        return a
    end

    local function material_alive(a)
        return try(call, a.mesh, "getMaterialName", a.j) == a.v.name
    end

    -- 选定之后的 set_* 使用的过渡；nil 表示瞬间开关（正在播放的动画会被收回）。
    function core:use(settings) current = type(settings) == "table" and settings or nil end

    -- 动画期间返回目标显隐，读取方据此判断是否需要再写；没有动画时返回 nil。
    function core:material_target(mesh, j)
        local a = materials[tostring(mesh) .. "_" .. tostring(j)]
        if a then return a.show end
        return nil
    end
    function core:mesh_target(mesh)
        local a = meshes[tostring(mesh)]
        if a then return a.show end
        return nil
    end
    function core:is_animating(mesh, j)
        if j == nil then return meshes[tostring(mesh)] ~= nil end
        return materials[tostring(mesh) .. "_" .. tostring(j)] ~= nil
    end

    -- 材质开关可以接管已有的部件动画。同一材质只在一个列表中推进。
    function core:set_material(mesh, j, want, cur)
        local key = tostring(mesh) .. "_" .. tostring(j)
        local a, part = materials[key], meshes[tostring(mesh)]
        if a and a.show == want then return end
        if not a and cur == want then return end
        local previous = a or part and part.animations[j]
        if part then part.animations[j] = nil end
        local v = current and current.duration > 0 and try(call, mesh, "get_Enabled") ~= false
            and (previous and previous.v or find_var(mesh, j))
        if not v then
            if previous then restore(mesh, j, previous.v); materials[key] = nil end
            if cur ~= want then call(mesh, "setMaterialsEnable", j, want) end
            return
        end
        local n = animation(mesh, j, v, want, previous)
        write(n)
        if want and cur ~= true then call(mesh, "setMaterialsEnable", j, true) end
        materials[key] = n
    end

    -- 只推进实际开启且没有独立动画的材质。
    function core:set_mesh(mesh, want, cur, allow_enable)
        local key = tostring(mesh)
        local a = meshes[key]
        if a and a.show == want then return end
        if want and allow_enable == false then return end
        if cur == want and not a then return end
        local animations = {}
        if current and current.duration > 0 then
            for j = 0, (try(call, mesh, "get_MaterialNum") or 0) - 1 do
                if not materials[key .. "_" .. tostring(j)] and try(call, mesh, "getMaterialsEnable", j) then
                    local previous = a and a.animations[j]
                    local v = previous and previous.v or find_var(mesh, j)
                    if v then
                        local n = animation(mesh, j, v, want, previous)
                        write(n)
                        animations[j] = n
                    end
                end
            end
        end
        if not next(animations) then
            if a then
                for _, old in pairs(a.animations) do restore(mesh, old.j, old.v) end
                meshes[key] = nil
            end
            if cur ~= want then call(mesh, "set_Enabled", want) end
            return
        end
        if want and cur ~= true then call(mesh, "set_Enabled", true) end
        meshes[key] = {mesh = mesh, show = want, animations = animations}
    end

    local function advance(a, dt)
        local step = dt / a.duration
        if a.rate < a.target then a.rate = math.min(a.target, a.rate + step)
        else a.rate = math.max(a.target, a.rate - step) end
        return a.rate == a.target
    end

    -- 每帧调用一次。对象失效或材质换了的动画直接丢弃，不再写入。
    function core:update()
        local now = clock()
        local dt = math.min(math.max(now - last_clock, 0), 0.1)
        last_clock = now
        for key, a in pairs(materials) do
            if not material_alive(a) then
                materials[key] = nil
            elseif advance(a, dt) then
                if not a.show then try(call, a.mesh, "setMaterialsEnable", a.j, false) end
                restore(a.mesh, a.j, a.v)
                materials[key] = nil
            else
                write(a)
            end
        end
        for key, part in pairs(meshes) do
            local running = false
            for j, a in pairs(part.animations) do
                if not material_alive(a) then
                    part.animations[j] = nil
                else
                    -- 其余材质仍在消失时，已到终点的材质保持完全溶解。
                    if not advance(a, dt) then running = true end
                    write(a)
                end
            end
            if not running then
                if not part.show and try(call, part.mesh, "get_MaterialNum") then
                    try(call, part.mesh, "set_Enabled", false)
                end
                for j, a in pairs(part.animations) do restore(part.mesh, j, a.v) end
                meshes[key] = nil
            end
        end
    end

    -- 立即播完全部动画并还原变量（脚本重置、关闭溶解时）。
    function core:finish_all()
        for key, a in pairs(materials) do
            if material_alive(a) then
                if not a.show then try(call, a.mesh, "setMaterialsEnable", a.j, false) end
                restore(a.mesh, a.j, a.v)
            end
            materials[key] = nil
        end
        for key, part in pairs(meshes) do
            if try(call, part.mesh, "get_MaterialNum") then
                if not part.show then try(call, part.mesh, "set_Enabled", false) end
                for j, a in pairs(part.animations) do
                    if material_alive(a) then restore(part.mesh, j, a.v) end
                end
            end
            meshes[key] = nil
        end
    end

    -- 切场景时丢弃引用，不再访问可能已销毁的对象；网格地址可能被复用，变量缓存一并清空。
    function core:abandon()
        materials, meshes, var_cache = {}, {}, {}
    end

    return core
end

return Dissolve
