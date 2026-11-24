local Palette = {}

-- 预设可选字段 palette = { [部位] = { [材质名] = { [参数名] = 数值 | { x =, y =, z =, w = } } } }。
-- 部位键与预设里的部位键相同（"0".."5"，武器按对象序号）。float 参数存数值；float4 只存改过的分量，
-- 没改的分量保持材质当前的值。只存覆盖值，不存原值；缺少字段的旧 JSON 不受影响。
-- Dissolve_Rate、Dissolve_Flag 由溶解过渡写入，不接受覆盖。
Palette.FIELD = "palette"
Palette.COMPONENTS = { "x", "y", "z", "w" }
Palette.COMPONENT_INDEX = { x = 1, y = 2, z = 3, w = 4 }
Palette.RESERVED = { Dissolve_Rate = true, Dissolve_Flag = true }

local function is_table(value) return type(value) == "table" end
local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function name(value) return type(value) == "string" and value ~= "" end
local function round(value) return math.floor(value * 1e5 + 0.5) / 1e5 end
Palette.finite = finite

local function clean_value(value)
    if finite(value) then return value end
    if not is_table(value) then return nil end
    local components = {}
    for _, key in ipairs(Palette.COMPONENTS) do
        if finite(value[key]) then components[key] = value[key] end
    end
    return next(components) and components or nil
end

-- 只返回格式正确的条目；其他内容读入时跳过，写回时仍随预设原样保留。
function Palette.read(preset)
    local result = {}
    local field = is_table(preset) and preset[Palette.FIELD]
    for part, materials in pairs(is_table(field) and field or {}) do
        if name(part) and is_table(materials) then
            local cleaned = {}
            for material, params in pairs(materials) do
                if name(material) and is_table(params) then
                    local values = {}
                    for param, value in pairs(params) do
                        if name(param) and not Palette.RESERVED[param] then values[param] = clean_value(value) end
                    end
                    if next(values) then cleaned[material] = values end
                end
            end
            if next(cleaned) then result[part] = cleaned end
        end
    end
    return result
end

-- 设置一项覆盖。component 为 nil 时 value 是 float 数值，或 { x..w } 中要改的分量；
-- component 为 "x".."w" 时只改这个分量。value 为 nil 时取消（component 为 nil 时取消整个参数）。
-- 返回 changed, reason；取消后清空的层级一并删除，最终没有覆盖时删除整个字段。
function Palette.set(preset, part, material, param, value, component)
    if not is_table(preset) then return false, "预设不存在" end
    if not (name(part) and name(material) and name(param)) then return false, "材质参数无效" end
    if Palette.RESERVED[param] then return false, "溶解参数由溶解过渡控制" end
    if component ~= nil and not Palette.COMPONENT_INDEX[component] then return false, "分量无效" end
    local field = is_table(preset[Palette.FIELD]) and preset[Palette.FIELD] or nil
    local params = field and is_table(field[part]) and is_table(field[part][material]) and field[part][material] or nil
    local current = params and params[param]
    if value == nil then
        if current == nil then return false end
        if component ~= nil and is_table(current) then
            if current[component] == nil then return false end
            current[component] = nil
            if next(current) == nil then params[param] = nil end
        else
            params[param] = nil
        end
        if next(params) == nil then field[part][material] = nil end
        if next(field[part]) == nil then field[part] = nil end
        if next(field) == nil then preset[Palette.FIELD] = nil end
        return true
    end
    local next_value
    if component ~= nil then
        if not finite(value) then return false, "数值无效" end
        next_value = is_table(current) and current or {}
        if next_value[component] == round(value) then return false end
        next_value[component] = round(value)
    elseif finite(value) then
        if current == round(value) then return false end
        next_value = round(value)
    else
        local components = clean_value(value)
        if not components then return false, "数值无效" end
        next_value = is_table(current) and current or {}
        for key, item in pairs(components) do next_value[key] = round(item) end
    end
    if not field then field = {}; preset[Palette.FIELD] = field end
    field[part] = is_table(field[part]) and field[part] or {}
    field[part][material] = is_table(field[part][material]) and field[part][material] or {}
    field[part][material][param] = next_value
    return true
end

local function copy(value)
    if not is_table(value) then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

-- 覆盖保存时重新捕获的只有网格与材质开关，调色沿用同名旧预设。
function Palette.carry(previous, data)
    if not is_table(previous) or not is_table(data) or data[Palette.FIELD] ~= nil then return data end
    if is_table(previous[Palette.FIELD]) then data[Palette.FIELD] = copy(previous[Palette.FIELD]) end
    return data
end

-- 把 overrides 合并进 target：按参数合并，float4 只覆盖写了的分量。
function Palette.merge_into(target, overrides)
    for part, materials in pairs(overrides) do
        local out_part = target[part] or {}
        target[part] = out_part
        for material, params in pairs(materials) do
            local out_material = out_part[material] or {}
            out_part[material] = out_material
            for param, value in pairs(params) do
                if is_table(value) then
                    local components = is_table(out_material[param]) and out_material[param] or {}
                    for key, item in pairs(value) do components[key] = item end
                    out_material[param] = components
                else
                    out_material[param] = value
                end
            end
        end
    end
    return target
end

-- 分组按界面排序；旧 JSON 缺少排序的部分按名称排列。
local function ordered_groups(config)
    local ordered, seen, missing = {}, {}, {}
    for _, group in ipairs(config.group_order or {}) do
        if config.groups and config.groups[group] and not seen[group] then
            ordered[#ordered + 1], seen[group] = group, true
        end
    end
    for group in pairs(config.groups or {}) do
        if not seen[group] then missing[#missing + 1] = group end
    end
    table.sort(missing)
    for _, group in ipairs(missing) do ordered[#ordered + 1] = group end
    return ordered
end

local function find(owner, preset_name, fallback)
    if fallback and (not preset_name or preset_name == "" or not (owner.presets and owner.presets[preset_name])) then
        preset_name = owner.default_preset
    end
    return preset_name and preset_name ~= "" and owner.presets and owner.presets[preset_name] or nil
end

-- 与 Selection.compose 的覆盖顺序一致：主列表、普通组、规则目标、全局组，后写的覆盖先写的。
-- groups 是角色解算后的各组预设名，targets 是本次条件规则命中的预设名（可省略）。
function Palette.resolve(config, groups, targets)
    local result = {}
    if not is_table(config) then return result end
    groups = groups or {}
    local function merge(preset) Palette.merge_into(result, Palette.read(preset)) end
    local order = ordered_groups(config)
    merge(find(config, groups[""], true))
    for _, group in ipairs(order) do
        if not config.groups[group].is_global then merge(find(config.groups[group], groups[group], true)) end
    end
    if targets then
        merge(find(config, targets[""], false))
        for _, group in ipairs(order) do
            if not config.groups[group].is_global then merge(find(config.groups[group], targets[group], false)) end
        end
    end
    for _, group in ipairs(order) do
        if config.groups[group].is_global then merge(find(config.groups[group], groups[group], true)) end
    end
    return result
end

return Palette
