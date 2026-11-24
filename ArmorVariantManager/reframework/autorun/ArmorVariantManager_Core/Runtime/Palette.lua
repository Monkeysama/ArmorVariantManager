local Palette = require("ArmorVariantManager_Core.Presets.Palette")
local Writer = {}

-- 把预设的调色覆盖写到网格材质上，只用组件方法，不依赖具体游戏。
-- 第一次写某个参数前按网格实例记下原值，覆盖取消后写回原值；每帧读当前值，与目标不同才写，
-- 其他插件改写了被覆盖的参数时会被写回，没被覆盖的参数不碰。float4 只写改过的分量，
-- 其余分量保持当前值（可能正被溶解过渡写入）。网格换了实例（换装、读档）后原值重新记录。
Writer.FLOAT, Writer.FLOAT4 = 1, 4

local function try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end
local function call(object, method, ...) return object:call(method, ...) end

-- 材质参数表：{ [参数名] = { index, type } }，只收 float 与 float4。
function Writer.variables(mesh, j)
    local vars = {}
    for k = 0, (try(call, mesh, "getMaterialVariableNum", j) or 0) - 1 do
        local param = try(call, mesh, "getMaterialVariableName", j, k)
        local kind = try(call, mesh, "getMaterialVariableType", j, k)
        if type(param) == "string" and (kind == Writer.FLOAT or kind == Writer.FLOAT4) then
            vars[param] = { index = k, type = kind }
        end
    end
    return vars
end

function Writer.read(mesh, j, var)
    if var.type == Writer.FLOAT then return try(call, mesh, "getMaterialFloat", j, var.index) end
    local value = try(call, mesh, "getMaterialFloat4", j, var.index)
    return value and { value.x, value.y, value.z, value.w } or nil
end

local function same(a, b)
    if type(a) == "number" then return type(b) == "number" and math.abs(a - b) < 1e-6 end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for i = 1, 4 do
        if type(a[i]) ~= "number" or type(b[i]) ~= "number" or math.abs(a[i] - b[i]) >= 1e-6 then return false end
    end
    return true
end

-- deps.vector(x, y, z, w) 构造 Vector4f。
function Writer.new(deps)
    deps = deps or {}
    local vector = deps.vector or function(x, y, z, w) return Vector4f.new(x, y, z, w) end
    local writer = {}
    local actors = {}    -- 角色键 -> { [网格键] = { mesh, vars = { [j] = 参数表 }, original = { ["j|参数"] = 原值 }, touched = { ["j|参数"] = 分量集合 | true } } }

    local function write(mesh, j, var, value)
        if var.type == Writer.FLOAT then call(mesh, "setMaterialFloat", j, var.index, value)
        else call(mesh, "setMaterialFloat4", j, var.index, vector(value[1], value[2], value[3], value[4])) end
    end

    -- 应用一个网格。overrides = 该部位的覆盖 { [材质名] = { [参数] = 值 } }，nil 表示没有覆盖（只还原写过的）。
    function writer.apply(actor, mesh, overrides)
        local meshes = actors[actor]
        if not meshes then meshes = {}; actors[actor] = meshes end
        local key = tostring(mesh)
        local state = meshes[key]
        if not state or state.mesh ~= mesh then
            state = { mesh = mesh, vars = {}, original = {}, touched = {} }
            meshes[key] = state
        end
        state.seen = true
        overrides = overrides or {}
        for j = 0, (try(call, mesh, "get_MaterialNum") or 0) - 1 do
            local material = try(call, mesh, "getMaterialName", j)
            local wanted = material and overrides[material]
            local prefix = j .. "|"
            local params = {}
            for param in pairs(wanted or {}) do params[param] = true end
            for touched in pairs(state.touched) do
                if touched:sub(1, #prefix) == prefix then params[touched:sub(#prefix + 1)] = true end
            end
            if next(params) then
                state.vars[j] = state.vars[j] or Writer.variables(mesh, j)
                for param in pairs(params) do
                    local var, tk = state.vars[j][param], prefix .. param
                    local want = wanted and wanted[param]
                    if not var or Palette.RESERVED[param] then
                        state.touched[tk] = nil
                    else
                        local current = Writer.read(mesh, j, var)
                        if state.original[tk] == nil then state.original[tk] = current end
                        local original = state.original[tk]
                        if var.type == Writer.FLOAT then
                            local target = Palette.finite(want) and want or original
                            if target ~= nil and not same(current, target) then write(mesh, j, var, target) end
                            state.touched[tk] = Palette.finite(want) and true or nil
                        elseif original and current then
                            local components = type(want) == "table" and want or {}
                            local previous = type(state.touched[tk]) == "table" and state.touched[tk] or {}
                            local target, now = { current[1], current[2], current[3], current[4] }, {}
                            for component, i in pairs(Palette.COMPONENT_INDEX) do
                                if Palette.finite(components[component]) then target[i] = components[component]; now[component] = true
                                elseif previous[component] then target[i] = original[i] end
                            end
                            if not same(current, target) then write(mesh, j, var, target) end
                            state.touched[tk] = next(now) and now or nil
                        end
                        if not state.touched[tk] then state.original[tk] = nil end
                    end
                end
            end
        end
    end

    -- 角色有写过的参数时为 true；没有覆盖也没有待还原的角色可以跳过整次应用。
    function writer.active(actor) return actors[actor] ~= nil end

    -- 一个角色本帧的应用开始与结束：结束时丢弃本帧没出现的网格（换装后旧网格已不在角色上）。
    function writer.begin(actor)
        for _, state in pairs(actors[actor] or {}) do state.seen = false end
    end
    function writer.finish(actor)
        local meshes = actors[actor]
        if not meshes then return end
        for key, state in pairs(meshes) do
            if not state.seen then meshes[key] = nil end
        end
        if next(meshes) == nil then actors[actor] = nil end
    end

    -- 给界面读取：材质的 float / float4 参数，含当前值，以及被覆盖时的原值。
    function writer.inspect(actor, mesh, material)
        local result = {}
        for j = 0, (try(call, mesh, "get_MaterialNum") or 0) - 1 do
            if try(call, mesh, "getMaterialName", j) == material then
                local state = actors[actor] and actors[actor][tostring(mesh)]
                for param, var in pairs(Writer.variables(mesh, j)) do
                    if not Palette.RESERVED[param] then
                        local original = state and state.original[j .. "|" .. param]
                        result[#result + 1] = { name = param, type = var.type == Writer.FLOAT and "float" or "float4",
                            value = Writer.read(mesh, j, var), original = original }
                    end
                end
                break
            end
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end

    -- 切场景时丢弃全部状态，不访问可能已销毁的对象。
    function writer.reset() actors = {} end

    return writer
end

return Writer
