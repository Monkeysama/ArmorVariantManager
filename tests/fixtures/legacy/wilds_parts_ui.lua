return function(env)
 local _ENV=env
 return function()
                    -- ========== 防具/武器部位列表 ==========
                    if is_weapon_mode then
                        if imgui.tree_node(T("weapon_parts") or "Weapon Parts") then
                            local w_id, w_objs = get_character_weapon_id(character)
                            if w_objs and #w_objs > 0 then
                                for idx, w_obj in ipairs(w_objs) do
                                    if sdk.is_managed_object(w_obj) then
                                        local mesh_comp = get_mesh_component_recursive(w_obj)
                                        local mesh_game_obj = mesh_comp and safe_get_game_object(mesh_comp, "draw_weapon_mesh") or nil
                                        if mesh_game_obj then
                                            local obj_name = mesh_game_obj:call("get_Name")
                                            draw_mesh_toggle(mesh_game_obj, string.format("Weapon %d [%s]", idx - 1, obj_name), body_id, tostring(idx - 1))
                                        else
                                            local obj_name = w_obj:call("get_Name")
                                            imgui.text_colored(string.format("Weapon %d [%s] (No Mesh)", idx - 1, obj_name), 0xFF808080)
                                        end
                                    end
                                end
                            else
                                imgui.text_colored("Weapon " .. T("not_equipped"), 0xFF808080)
                            end
                            imgui.tree_pop()
                        end
                    else
                        -- 1. 遍历防具部位 (Helm, Body, Arm, Waist, Leg)
                        local armor_parts = {
                            [0] = T("helm"),
                            [1] = T("body"),
                            [2] = T("arm"),
                            [3] = T("waist"),
                            [4] = T("leg"),
                            [5] = T("slinger")
                        }
                        if imgui.tree_node(T("armor_parts")) then
                            for i = 0, 5 do
                                local part_obj = get_character_part(character, i)
                                local part_name = armor_parts[i]
                                local reference_part_data = active_overrides[body_id]
                                    and active_overrides[body_id][tostring(i)]
                                local mesh_components = get_character_part_meshes(character, i, reference_part_data)
                                local mesh_game_obj = mesh_components[1] and safe_get_game_object(mesh_components[1], "draw_part_mesh") or nil
                                if mesh_game_obj then
                                    -- UI 每个部位只显示主 Mesh；附属 Mesh 由预设应用逻辑同步控制。
                                    local obj_name = mesh_game_obj:call("get_Name") or "Mesh"
                                    draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, i)
                                elseif part_obj and not is_player_face_object(part_obj) then
                                    local obj_name = part_obj:call("get_Name")
                                    imgui.text_colored(string.format("%s [%s] (No Mesh)", part_name, obj_name), 0xFF808080)
                                else
                                    imgui.text_colored(part_name .. " " .. T("not_equipped"), 0xFF808080)
                                end
                            end
                            imgui.tree_pop()
                        end
                    end

 end
end
