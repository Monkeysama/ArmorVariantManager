-- 冻结自 093c61c，用于对照重构前的分组与预设行为。
return function(env)
    local source = [====[
local merge_overrides
local function get_material_group_owner(part_index, mat_name)
    if not mat_name then return nil end
    if not current_config or not current_config.groups then return nil end
    local s_idx = tostring(part_index)
    for g_name, g_data in pairs(current_config.groups) do
        if not g_data.is_global then
            if g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
                return g_name
            end
        end
    end
    return nil
end

local function is_material_in_current_context(part_index, mat_name)
    if current_group_name == "" then
        return get_material_group_owner(part_index, mat_name) == nil
    else
        local g_data = current_config.groups and current_config.groups[current_group_name]
        if g_data and g_data.is_global then
            local s_idx = tostring(part_index)
            return g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] == true
        else
            local owner = get_material_group_owner(part_index, mat_name)
            return owner == current_group_name
        end
    end
end

local function create_new_group(group_name, body_id, is_global)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    local has_selection = false
    for _, v in pairs(pending_material_selections) do
        if next(v) then has_selection = true; break end
    end
    if not has_selection then return false end
    if not current_config.groups then current_config.groups = {} end
    if current_config.groups[group_name] then return false end
    local new_group = {
        mask = deep_copy_table(pending_material_selections),
        presets = {},
        is_global = is_global == true
    }
    if not new_group.is_global then
        if current_config.presets then
            for _, preset_data in pairs(current_config.presets) do
                for part_idx_str, mats in pairs(new_group.mask) do
                    if preset_data[part_idx_str] and preset_data[part_idx_str].materials then
                        for m_name, _ in pairs(mats) do
                            preset_data[part_idx_str].materials[m_name] = nil
                        end
                    end
                end
            end
        end
    end
    current_config.groups[group_name] = new_group
    if not current_config.group_order then current_config.group_order = {} end
    table.insert(current_config.group_order, group_name)
    pending_material_selections = {}
    is_selection_mode = false
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

local function delete_group(group_name, body_id)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    if not current_config.groups or not current_config.groups[group_name] then return false end
    current_config.groups[group_name] = nil
    if current_config.group_order then
        for i = #current_config.group_order, 1, -1 do
            if current_config.group_order[i] == group_name then
                table.remove(current_config.group_order, i)
                break
            end
        end
    end
    if current_group_name == group_name then
        current_group_name = ""
        selected_group_index = 1
        update_preset_names_list()
    end
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

local function merge_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            overrides[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                overrides[p_idx].materials[mat_name] = is_enabled
            end
        end
    end
    bump_overrides_version(body_id)
end

merge_overrides = function(base, add)
    local result = deep_copy_table(base) or {}
    if not add then return result end
    for p_idx, p_data in pairs(add) do
        if not result[p_idx] then result[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            result[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not result[p_idx].materials then result[p_idx].materials = {} end
            for m, en in pairs(p_data.materials) do
                result[p_idx].materials[m] = en
            end
        end
    end
    return result
end

local function merge_global_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if p_data.materials then
            if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                if is_enabled == false then
                    overrides[p_idx].materials[mat_name] = false
                end
            end
        end
    end
    bump_overrides_version(body_id)
end
return {
    get_material_group_owner = get_material_group_owner,
    is_material_in_current_context = is_material_in_current_context,
    create_new_group = create_new_group,
    delete_group = delete_group,
    merge_preset_into_overrides = merge_preset_into_overrides,
    merge_overrides = merge_overrides,
    merge_global_preset_into_overrides = merge_global_preset_into_overrides,
}
]====]
    return assert(load(source, "legacy rise presets", "t", env))()
end
