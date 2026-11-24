local ShapeKeys = {}

-- 预设可选字段 sks = { [SKS 键组名] = 选项名 | 0 }，0 表示这个键组不选任何选项。
-- 只引用 SKS 当前捏脸配置里的键组和选项名字，不保存形态键数值；缺少字段的旧 JSON 不受影响。
ShapeKeys.FIELD = "sks"

local function valid_group(name) return type(name) == "string" and name ~= "" end
local function valid_option(value) return (type(value) == "string" and value ~= "") or value == 0 end
ShapeKeys.valid_group, ShapeKeys.valid_option = valid_group, valid_option

-- 只返回能发送的条目；其他值读入时跳过，写回时仍随预设原样保留。
function ShapeKeys.read(preset)
    local result = {}
    local field = type(preset) == "table" and preset[ShapeKeys.FIELD]
    if type(field) ~= "table" then return result end
    for group, option in pairs(field) do
        if valid_group(group) and valid_option(option) then result[group] = option end
    end
    return result
end

-- option 为 nil 时移除该键组；字段清空后删除，保持未使用联动的预设与旧格式一致。
function ShapeKeys.set(preset, group, option)
    if type(preset) ~= "table" then return false, "预设不存在" end
    if not valid_group(group) then return false, "键组名称无效" end
    if option ~= nil and not valid_option(option) then return false, "键组选项无效" end
    local field = preset[ShapeKeys.FIELD]
    if type(field) ~= "table" then
        if option == nil then return true end
        field = {}
        preset[ShapeKeys.FIELD] = field
    end
    field[group] = option
    if next(field) == nil then preset[ShapeKeys.FIELD] = nil end
    return true
end

-- 覆盖保存时重新捕获的只有网格与材质，联动设置沿用同名旧预设。
function ShapeKeys.carry(previous, data)
    if type(previous) ~= "table" or type(data) ~= "table" or data[ShapeKeys.FIELD] ~= nil then return data end
    local field = previous[ShapeKeys.FIELD]
    if type(field) ~= "table" then return data end
    local copy = {}
    for group, option in pairs(field) do copy[group] = option end
    data[ShapeKeys.FIELD] = copy
    return data
end

-- 分组按界面排序；旧 JSON 缺少排序的部分按名称排列，避免 pairs 顺序让结果随机变化。
local function ordered_groups(config)
    local ordered, seen, missing = {}, {}, {}
    for _, name in ipairs(config.group_order or {}) do
        if config.groups and config.groups[name] and not seen[name] then
            ordered[#ordered + 1], seen[name] = name, true
        end
    end
    for name in pairs(config.groups or {}) do
        if not seen[name] then missing[#missing + 1] = name end
    end
    table.sort(missing)
    for _, name in ipairs(missing) do ordered[#ordered + 1] = name end
    return ordered
end

local function find(owner, name, fallback)
    if fallback and (not name or name == "" or not (owner.presets and owner.presets[name])) then
        name = owner.default_preset
    end
    return name and name ~= "" and owner.presets and owner.presets[name] or nil
end

-- 与 Selection.compose 的覆盖顺序一致：主列表、普通组、规则目标、全局组，后写的键组覆盖先写的。
-- groups 是角色解算后的各组预设名，targets 是本次条件规则命中的预设名（可省略）。
function ShapeKeys.resolve(config, groups, targets)
    local result = {}
    if type(config) ~= "table" then return result end
    groups = groups or {}
    local function merge(preset)
        for group, option in pairs(ShapeKeys.read(preset)) do result[group] = option end
    end
    local order = ordered_groups(config)
    merge(find(config, groups[""], true))
    for _, name in ipairs(order) do
        local group = config.groups[name]
        if not group.is_global then merge(find(group, groups[name], true)) end
    end
    if targets then
        merge(find(config, targets[""], false))
        for _, name in ipairs(order) do
            local group = config.groups[name]
            if not group.is_global then merge(find(group, targets[name], false)) end
        end
    end
    for _, name in ipairs(order) do
        local group = config.groups[name]
        if group.is_global then merge(find(group, groups[name], true)) end
    end
    return result
end

return ShapeKeys
