local Compose = require("ArmorVariantManager_Core.Presets.Compose")
local Groups = {}

-- 普通组独占材质，全局组不参与归属判定。
function Groups.owner(config, part_index, material)
    if not material or not config or not config.groups then return nil end
    local part = tostring(part_index)
    for name, group in pairs(config.groups) do
        if not group.is_global and group.mask and group.mask[part] and group.mask[part][material] then
            return name
        end
    end
end

function Groups.global_names(config, part_index, material)
    local result = {}
    if not material then return result end
    local part = tostring(part_index)
    for name, group in pairs(config.groups or {}) do
        if group.is_global and group.mask and group.mask[part] and group.mask[part][material] == true then
            result[#result + 1] = name
        end
    end
    table.sort(result)
    return result
end

-- 主列表管理未分组材质；全局组按自己的 mask 显示。
function Groups.contains(config, name, part_index, material)
    if name == "" then return Groups.owner(config, part_index, material) == nil end
    local group = config.groups and config.groups[name]
    if group and group.is_global then
        local part = tostring(part_index)
        return group.mask and group.mask[part] and group.mask[part][material] == true
    end
    return Groups.owner(config, part_index, material) == name
end

-- 荒野忽略取消勾选项；崛起沿用完整选择表，避免改变已有 mask 的含义。
function Groups.create(config, name, selections, is_global, selected_only)
    if not name or name == "" then return false end
    local has_selection = false
    for _, materials in pairs(selections) do
        if next(materials) then has_selection = true; break end
    end
    if not has_selection then return false end
    if not config.groups then config.groups = {} end
    if config.groups[name] then return false end
    local mask
    if selected_only then
        mask = {}
        for part, materials in pairs(selections) do
            for material, selected in pairs(materials) do
                if selected == true then
                    if not mask[part] then mask[part] = {} end
                    mask[part][material] = true
                end
            end
        end
        if next(mask) == nil then return false end
    else
        mask = Compose.copy(selections)
    end
    local group = { mask = mask, presets = {}, is_global = is_global == true }
    if not group.is_global then
        for _, preset in pairs(config.presets or {}) do
            for part, materials in pairs(mask) do
                if preset[part] and preset[part].materials then
                    for material in pairs(materials) do preset[part].materials[material] = nil end
                end
            end
        end
    end
    config.groups[name] = group
    if not config.group_order then config.group_order = {} end
    config.group_order[#config.group_order + 1] = name
    return true
end

-- 删除只释放 mask，不把已移出的材质值写回主预设。
function Groups.delete(config, name)
    if not name or name == "" or not config.groups or not config.groups[name] then return false end
    config.groups[name] = nil
    for index = #(config.group_order or {}), 1, -1 do
        if config.group_order[index] == name then table.remove(config.group_order, index); break end
    end
    return true
end

return Groups
