-- 093c61c material capture
return function(env)
local _ENV = env
local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_primary_body_id() end
    if not body_id then return false end
    local primary = get_primary_player()
    if not primary then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = {}

    -- 判断当前上下文是否为全局分组
    local is_global_context = (current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global)

    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if weapon_parts then
            for i, part_obj in ipairs(weapon_parts) do
                if part_obj then
                    local mesh_component = get_mesh_component_recursive(part_obj)
                    if mesh_component then
                        local part_data = {
                            mesh_enabled = SceneObject.call(mesh_component, "get_Enabled"),
                            materials = {}
                        }
                        local mat_count = SceneObject.call(mesh_component, "get_MaterialNum")
                        if mat_count then
                            for j = 0, mat_count - 1 do
                                local mat_name = SceneObject.call(mesh_component, "getMaterialName", j)
                                if is_material_in_current_context(i - 1, mat_name) then
                                    local is_mat_enabled = SceneObject.call(mesh_component, "getMaterialsEnable", j)
                                    -- 全局分组：仅存储 false（隐藏），跳过 true
                                    if is_global_context then
                                        if is_mat_enabled == false then
                                            part_data.materials[mat_name] = false
                                        end
                                    else
                                        part_data.materials[mat_name] = is_mat_enabled
                                    end
                                end
                            end
                        end
                        -- 只有存储了材质数据（或主列表/普通分组才保存）
                        if next(part_data.materials) or current_group_name == "" or not is_global_context then
                            new_preset_data[tostring(i - 1)] = part_data
                        end
                    end
                end
            end
        end
    else
        for i = 0, 4 do
            local part_obj = get_character_part(primary, i)
            if part_obj then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    local part_data = {
                        mesh_enabled = SceneObject.call(mesh_component, "get_Enabled"),
                        materials = {}
                    }
                    local mat_count = SceneObject.call(mesh_component, "get_MaterialNum")
                    if mat_count then
                        for j = 0, mat_count - 1 do
                            local mat_name = SceneObject.call(mesh_component, "getMaterialName", j)
                            if is_material_in_current_context(i, mat_name) then
                                local is_mat_enabled = SceneObject.call(mesh_component, "getMaterialsEnable", j)
                                -- 全局分组：仅存储 false（隐藏），跳过 true
                                if is_global_context then
                                    if is_mat_enabled == false then
                                        part_data.materials[mat_name] = false
                                    end
                                else
                                    part_data.materials[mat_name] = is_mat_enabled
                                end
                            end
                        end
                    end
                    -- 只有存储了材质数据（或主列表/普通分组才保存）
                    if next(part_data.materials) or current_group_name == "" or not is_global_context then
                        new_preset_data[tostring(i)] = part_data
                    end
                end
            end
        end
    end

    -- 如果全局分组且没有任何材质需要隐藏，仍需保存一个空表以标记预设存在
    if is_global_context and not next(new_preset_data) then
        -- 至少保存一个空结构，表示这是一个有效的预设（无隐藏项，即全部显示）
        new_preset_data = { _empty = true }  -- 用特殊标记表示空预设
    end

    return new_preset_data
end
return save_preset
end
