-- ac68657 material capture
return function(env)
local _ENV = env
local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_body_id() end
    if not body_id then return false end
    local character = get_local_player_character()
    if not character then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = {}

    if is_weapon_id(body_id) then
        local w_id, w_objs = get_character_weapon_id(character)
        if w_objs then
            for idx, w_obj in ipairs(w_objs) do
                local mesh_component = get_mesh_component_recursive(w_obj)
                if mesh_component then
                    local part_data = {
                        materials = {}
                    }
                    -- 全局分组不保存 mesh_enabled，避免整体隐藏部件
                    local is_global_ctx = (current_group_name ~= "" and current_config.groups
                        and current_config.groups[current_group_name]
                        and current_config.groups[current_group_name].is_global)
                    if not is_global_ctx then
                        part_data.mesh_enabled = mesh_component:call("get_Enabled")
                    end
                    local mat_count = mesh_component:call("get_MaterialNum")
                    if mat_count then
                        for j = 0, mat_count - 1 do
                            local mat_name = mesh_component:call("getMaterialName", j)
                            if is_material_in_current_context(idx - 1, mat_name) then
                                -- 优先读意图值（active_overrides），避免全局锁导致游戏状态是 false 而丢失用户意图
                                local s_idx = tostring(idx - 1)
                                local intent = active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mat_name]
                                local is_mat_enabled = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", j)
                                part_data.materials[mat_name] = is_mat_enabled
                            end
                        end
                    end
                    if next(part_data.materials) or current_group_name == "" then
                        new_preset_data[tostring(idx - 1)] = part_data
                    end
                end
            end
        end
    else
        for i = 0, 5 do
            local part_obj = get_character_part(character, i)
            local reference_part_data = active_overrides[body_id]
                and active_overrides[body_id][tostring(i)]
            local mesh_components = get_character_part_meshes(character, i, reference_part_data)
            if #mesh_components > 0 then
                -- 一个部位可能对应多个 Mesh；合并材料状态，避免后一个 Mesh 覆盖前一个 Mesh。
                local part_data = {
                    materials = {}
                }
                -- 全局分组不保存 mesh_enabled，避免整体隐藏部件
                local is_global_ctx = (current_group_name ~= "" and current_config.groups
                    and current_config.groups[current_group_name]
                    and current_config.groups[current_group_name].is_global)
                for _, mesh_component in ipairs(mesh_components) do
                    if not is_global_ctx and part_data.mesh_enabled == nil then
                        part_data.mesh_enabled = mesh_component:call("get_Enabled")
                    end
                    local mat_count = mesh_component:call("get_MaterialNum")
                    if mat_count then
                        for j = 0, mat_count - 1 do
                            local mat_name = mesh_component:call("getMaterialName", j)
                            if is_material_in_current_context(i, mat_name) then
                                -- 优先读意图值（active_overrides），避免全局锁导致游戏状态是 false 而丢失用户意图
                                local s_idx_j = tostring(i)
                                local intent = active_overrides[body_id]
                                    and active_overrides[body_id][s_idx_j]
                                    and active_overrides[body_id][s_idx_j].materials
                                    and active_overrides[body_id][s_idx_j].materials[mat_name]
                                local is_mat_enabled = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", j)
                                part_data.materials[mat_name] = is_mat_enabled
                            end
                        end
                    end
                end
                if next(part_data.materials) or current_group_name == "" then
                    new_preset_data[tostring(i)] = part_data
                end
            end
        end
    end
    return new_preset_data
end
return save_preset
end
