local Dissolve = {}

-- 溶解过渡核心：把材质或部件的开关改成按时间推进的溶解，不依赖具体游戏。
-- 只作用于带 Dissolve_Rate 变量的材质（溶解模板），其他材质照旧瞬间开关。材质参数约定见 docs/DISSOLVE.md：
--   Dissolve_Rate  xyz = 溶解比例 0..1（0 完整，1 全部消失），w = Reversing（0 中心向外，1 外向中心）
--   Dissolve_Flag  y = IsMorphed（1 时可见判定反转）；其他分量保持 mdf 原值。没有 Dissolve_Flag 的材质照常溶解
-- 两种出现方式：
--   "morph"    出现方与消失方同时把比例从 0 推到 1，出现方置 IsMorphed，新外观在旧外观消失的位置原地长出；需要模板支持 IsMorphed
--   "reverse"  出现 = 消失倒放（比例 1 -> 0，IsMorphed 为 0），任何带 Dissolve_Rate 的模板都可用
-- forward = false 时比例从 1 走到 0 并置 Reversing（外向中心）；"reverse" 方式不区分方向。
-- 动画结束时关闭消失方，并还原动画启动前的两个变量。中途反向切换时从当前位置接着走。

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
    local valid = deps.valid or function() return true end
    local report = deps.report or function(reason)
        if log then log.error("[AVM] Dissolve: " .. tostring(reason)) end
    end
    local current = nil      -- 本次写入使用的过渡（use）
    local materials = {}     -- 网格_序号 -> 动画
    local meshes = {}        -- 网格 -> 动画（整个部件）
    local last_clock = clock()

    local function try(fn, ...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        return nil
    end
    local function call(object, method, ...) return object:call(method, ...) end

    local function set(mesh, method, ...)
        local result = call(mesh, method, ...)
        if result == false then error(method .. " returned false", 0) end
    end

    local function components(value)
        return {value.x, value.y, value.z, value.w}
    end

    local function find_var(mesh, j)
        local rate, flag
        for k = 0, (call(mesh, "getMaterialVariableNum", j) or 0) - 1 do
            local name = call(mesh, "getMaterialVariableName", j, k)
            if name == RATE then rate = k elseif name == FLAG then flag = k end
        end
        if not rate then return nil end
        local v = {rate=rate, flag=flag, name=call(mesh, "getMaterialName", j)}
        v.rate0 = components(call(mesh, "getMaterialFloat4", j, rate))
        if flag then v.flag0 = components(call(mesh, "getMaterialFloat4", j, flag)) end
        return v
    end

    local function discover(mesh, j)
        local ok, v = pcall(find_var, mesh, j)
        if ok then return v end
        report(v)
    end

    local function write(a)
        local rate, mesh, j, v = a.rate, a.mesh, a.j, a.v
        set(mesh, "setMaterialFloat4", j, v.rate, vector(rate, rate, rate, a.reversing))
        if v.flag then
            local f = v.flag0
            set(mesh, "setMaterialFloat4", j, v.flag, vector(f[1], a.morphed, f[3], f[4]))
        end
    end

    local function restore(a)
        local v = a.v
        local function original(index, value)
            set(a.mesh, "setMaterialFloat4", a.j, index, vector(table.unpack(value)))
        end
        local ok, reason = pcall(original, v.rate, v.rate0)
        if v.flag then
            local flag_ok, flag_reason = pcall(original, v.flag, v.flag0)
            if not flag_ok then return false, flag_reason end
        end
        return ok, reason
    end

    local function animation(mesh, j, v, show, previous)
        local a = {mesh=mesh, j=j, v=v, show=show, duration=current.duration, owner=current.owner, ui=current.ui}
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
        local mesh, j, v = a.mesh, a.j, a.v
        return valid(mesh) and try(call, mesh, "getMaterialName", j) == v.name
            and try(call, mesh, "getMaterialVariableName", j, v.rate) == RATE
            and (not v.flag or try(call, mesh, "getMaterialVariableName", j, v.flag) == FLAG)
    end

    local function finish_material(a)
        if not material_alive(a) then return true end
        local ok, reason = pcall(set, a.mesh, "setMaterialsEnable", a.j, a.show)
        local restored, restore_reason = restore(a)
        return ok and restored, reason or restore_reason
    end

    local function finish_part(part)
        if not valid(part.mesh) then return true end
        local had_materials = next(part.animations) ~= nil
        for j, a in pairs(part.animations) do
            if not material_alive(a) then part.animations[j] = nil end
        end
        if had_materials and not next(part.animations) then return true end
        local ok, reason = pcall(set, part.mesh, "set_Enabled", part.show)
        for j, a in pairs(part.animations) do
            local restored, failure = restore(a)
            if restored then part.animations[j] = nil
            else ok, reason = false, reason or failure end
        end
        return ok, reason
    end

    local function complete(state, finish)
        state.finishing = true
        local ok, reason = finish(state)
        if not ok and state.error ~= reason then
            state.error = reason
            report(reason)
        end
        return ok, reason
    end

    local function apply_frame(a)
        local ok, reason = pcall(write, a)
        if not ok then report(reason) end
        return ok
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
        if a and not material_alive(a) then materials[key], a = nil, nil end
        local animate = current and current.duration > 0 and try(call, mesh, "get_Enabled") ~= false
        if animate and a and not a.finishing and a.show == want then return end
        if not a and cur == want then return end
        local previous = a or part and part.animations[j]
        if part then part.animations[j] = nil end
        if previous and not material_alive(previous) then previous = nil end
        local v = animate and (previous and previous.v or discover(mesh, j))
        if v then
            local n = animation(mesh, j, v, want, previous)
            if apply_frame(n) then
                local ok, reason = true, nil
                if want and cur ~= true then ok, reason = pcall(set, mesh, "setMaterialsEnable", j, true) end
                if ok then materials[key] = n; return end
                report(reason)
            end
            previous = n
        end
        if not previous then
            set(mesh, "setMaterialsEnable", j, want)
            return
        end
        previous.show = want
        if complete(previous, finish_material) then materials[key] = nil
        else materials[key] = previous end
    end

    -- 只推进实际开启且没有独立动画的材质。
    function core:set_mesh(mesh, want, cur, allow_enable)
        local key = tostring(mesh)
        local part = meshes[key]
        local animate = current and current.duration > 0
        if want and allow_enable == false then return end
        if animate and part and not part.finishing and part.show == want then return end
        if cur == want and not part then return end
        local next_part = {mesh=mesh, show=want, animations={},
            owner=current and current.owner, ui=current and current.ui}
        local old = part and part.animations or {}
        if animate then
            for j = 0, (try(call, mesh, "get_MaterialNum") or 0) - 1 do
                if not materials[key .. "_" .. tostring(j)] and try(call, mesh, "getMaterialsEnable", j) then
                    local previous = old[j]
                    if previous and not material_alive(previous) then previous = nil end
                    local v = previous and previous.v or discover(mesh, j)
                    if v then
                        local n = animation(mesh, j, v, want, previous)
                        next_part.animations[j], old[j] = n, nil
                        if not apply_frame(n) then next_part.finishing = true; break end
                    end
                end
            end
        end
        -- 被本次切换排除的旧材质仍需归还参数。
        for j, a in pairs(old) do
            if material_alive(a) then
                local ok, reason = restore(a)
                if not ok then
                    report(reason)
                    next_part.animations[j], next_part.finishing = a, true
                end
            end
        end
        if want and not next_part.finishing and cur ~= true and next(next_part.animations) then
            local ok, reason = pcall(set, mesh, "set_Enabled", true)
            if not ok then next_part.finishing = true; report(reason) end
        end
        if not next_part.finishing and next(next_part.animations) then
            meshes[key] = next_part
        else
            if complete(next_part, finish_part) then meshes[key] = nil
            else meshes[key] = next_part end
        end
    end

    local function advance(a, dt)
        local step = dt / a.duration
        if a.rate < a.target then a.rate = math.min(a.target, a.rate + step)
        else a.rate = math.max(a.target, a.rate - step) end
        return a.rate == a.target
    end

    -- 每帧调用一次。失效对象或替换后的材质不参与恢复。
    function core:update()
        local now = clock()
        local dt = math.min(math.max(now - last_clock, 0), 0.1)
        last_clock = now
        for key, a in pairs(materials) do
            if not material_alive(a) then
                materials[key] = nil
            elseif a.finishing or advance(a, dt) or not apply_frame(a) then
                if complete(a, finish_material) then materials[key] = nil end
            end
        end
        for key, part in pairs(meshes) do
            local running, had_materials = false, next(part.animations) ~= nil
            if not part.finishing then
                for j, a in pairs(part.animations) do
                    if not material_alive(a) then
                        part.animations[j] = nil
                    else
                        if not advance(a, dt) then running = true end
                        if not apply_frame(a) then part.finishing = true; break end
                    end
                end
            end
            if had_materials and not part.finishing and not next(part.animations) then
                meshes[key] = nil
            elseif part.finishing or not running then
                if complete(part, finish_part) then meshes[key] = nil end
            end
        end
    end

    -- 可按动画所有者收尾。失败条目保留，供下一帧或同值设置操作重试。
    function core:finish_all(matches)
        local failure
        for key, a in pairs(materials) do
            if not matches or matches(a) then
                local ok, reason = complete(a, finish_material)
                if ok then materials[key] = nil else failure = failure or reason end
            end
        end
        for key, part in pairs(meshes) do
            if not matches or matches(part) then
                local ok, reason = complete(part, finish_part)
                if ok then meshes[key] = nil else failure = failure or reason end
            end
        end
        return failure == nil, failure
    end

    -- 切场景时丢弃引用，不再访问可能已销毁的对象。
    function core:abandon()
        materials, meshes = {}, {}
        last_clock = clock()
    end

    return core
end

return Dissolve
