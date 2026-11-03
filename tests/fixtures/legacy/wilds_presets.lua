-- 冻结自 9f2d14d，用于对照重构前的分组与预设行为。
return function(env)
    local source = [====[
local merge_overrides
local function get_material_group_owner(part_index, mat_name)
    if not mat_name then return nil end
    if not current_config.groups then return nil end
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
        -- 主列表只管理未被任何普通分组占用的材质
        local owner = get_material_group_owner(part_index, mat_name)
        return owner == nil
    else
        local g_data = current_config.groups and current_config.groups[current_group_name]
        if g_data and g_data.is_global then
            -- 全局分组：用 mask 直接判断是否在该组内
            local s_idx = tostring(part_index)
            return g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] == true
        else
            -- 普通分组：通过归属判定
            local owner = get_material_group_owner(part_index, mat_name)
            return owner == current_group_name
        end
    end
end

local function create_new_group(group_name, body_id, is_global)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    -- 0. 检查是否有勾选材质
    local has_selection = false
    for _, v in pairs(pending_material_selections) do
        if next(v) then has_selection = true; break end
    end
    if not has_selection then return false end
    if not current_config.groups then current_config.groups = {} end
    if current_config.groups[group_name] then return false end -- 重名检查
    -- 1. 创建分组结构
    local normalized_mask = {}
    for part_index, materials in pairs(pending_material_selections) do
        for material_name, selected in pairs(materials or {}) do
            if selected == true then
                if not normalized_mask[part_index] then normalized_mask[part_index] = {} end
                normalized_mask[part_index][material_name] = true
            end
        end
    end
    local normalized_has_selection = false
    for _, materials in pairs(normalized_mask) do
        if next(materials) then normalized_has_selection = true; break end
    end
    if not normalized_has_selection then return false end
    local new_group = {
        mask = normalized_mask,
        presets = {},
        is_global = is_global == true
    }
    -- 2. 只有普通分组才需要从主列表/其他普通分组预设中剥离材质控制权
    -- 全局分组允许 mask 与其他分组重叠，不做剥离
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
    -- 3. 保存新分组并清空选择
    current_config.groups[group_name] = new_group
    -- 维护 group_order：新建分组追加到末尾
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
    -- 归还逻辑：删除分组时直接丢弃分组特有的预设数据
    -- 仅将材质控制权通过清除 mask 的方式归还给主列表（主列表预设中该材质的状态将恢复为默认或通过重新保存来定义）
    -- 删除分组
    current_config.groups[group_name] = nil
    -- 维护 group_order：从数组中移除
    if current_config.group_order then
        for i = #current_config.group_order, 1, -1 do
            if current_config.group_order[i] == group_name then
                table.remove(current_config.group_order, i)
                break
            end
        end
    end
    -- 如果当前在被删除的分组，切换回主列表
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
        if p_idx == "ground_clipping_fix" then goto continue_preset_part end
        if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
        -- 合并 Mesh 整体开关
        if p_data.mesh_enabled ~= nil then
            overrides[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        -- 合并材质开关
        if p_data.materials then
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                overrides[p_idx].materials[mat_name] = is_enabled
            end
        end
        ::continue_preset_part::
    end
end

local function merge_overrides(base_data, add_data)
    local result = deep_copy_table(base_data) or {}
    if not add_data then return result end
    for p_idx, p_data in pairs(add_data) do
        if p_idx == "ground_clipping_fix" then
            local settings = GroundClippingFix.read_settings(p_data)
            if settings.enabled then result.ground_clipping_fix = settings end
            goto continue_override_part
        end
        if not result[p_idx] then result[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            result[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not result[p_idx].materials then result[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                result[p_idx].materials[mat_name] = is_enabled
            end
        end
        ::continue_override_part::
    end
    return result
end

local function merge_global_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if p_idx == "ground_clipping_fix" then goto continue_global_part end
        if p_data.materials then
            if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                if is_enabled == false then
                    -- 强制覆盖：全局隐藏具有最高优先级，无论之前是否为 true
                    overrides[p_idx].materials[mat_name] = false
                elseif is_enabled == true
                    and overrides[p_idx].materials[mat_name] == nil then
                    -- 没有默认/普通分组状态时，全局组的 true 也必须显式恢复显示；
                    -- 有下层状态时保留下层值，维持全局组只覆盖隐藏的优先级语义。
                    overrides[p_idx].materials[mat_name] = true
                end
            end
        end
        ::continue_global_part::
    end
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
    return assert(load(source, "legacy wilds presets", "t", env))()
end
