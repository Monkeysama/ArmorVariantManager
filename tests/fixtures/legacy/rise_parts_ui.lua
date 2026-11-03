return function(env)
 local _ENV=env
 return function()
                    -- 部件列表
                    if is_weapon_mode then
                        if imgui.tree_node(T("weapon_parts") or "Weapon Parts") then
                            local weapon_parts = get_cached_weapon_parts(primary)
                            local weapon_type = Utils.get_current_weapon_type(primary)
                            if weapon_parts and #weapon_parts > 0 then
                                for idx, part_obj in ipairs(weapon_parts) do
                                    if part_obj and safe_object_alive(part_obj) then
                                        local mesh_comp = get_mesh_component_recursive(part_obj)
                                        if mesh_comp then
                                            local mesh_game_obj = mesh_comp:call("get_GameObject")
                                            local obj_name = mesh_game_obj:call("get_Name")
                                            local part_name = Utils.get_weapon_part_name(weapon_type, idx - 1)
                                            draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, idx - 1)
                                        else
                                            local obj_name = SceneObject.call(part_obj, "get_Name")
                                            imgui.text_colored(string.format("Part %d [%s] (No Mesh)", idx - 1, obj_name), 0xFF808080)
                                        end
                                    else
                                        imgui.text_colored(string.format("Part %d (Missing)", idx - 1), 0xFF808080)
                                    end
                                end
                            else
                                imgui.text_colored(T("weapon_not_equipped") or "No weapon equipped", 0xFF808080)
                            end
                            imgui.tree_pop()
                        end
                    else
                        local armor_parts = { [0]=T("helm"), [1]=T("body"), [2]=T("arm"), [3]=T("waist"), [4]=T("leg") }
                        if imgui.tree_node(T("armor_parts")) then
                            local armor_order = {2, 1, 0, 4, 3}
                            for _, idx in ipairs(armor_order) do
                                local part_obj = get_cached_character_part(primary, idx)
                                local part_name = armor_parts[idx]
                                if part_obj then
                                    local mesh_comp = get_mesh_component_recursive(part_obj)
                                    -- - get_GameObject() 有可能拿不到（部件刚重建、mesh 还没就绪）。
                                    --   以前这里直接索引它，一旦为 nil 就会抛错 —— 而这段在 pcall
                                    --   里，于是错误后面的**整块面板内容（语言 / 联机 / 性能设置…）
                                    --   全部被截断**，玩家只会看到「面板少了一截」。必须判空。
                                    local mesh_game_obj = mesh_comp and mesh_comp:call("get_GameObject")
                                    if mesh_game_obj then
                                        local obj_name = mesh_game_obj:call("get_Name")
                                        draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, idx)
                                    else
                                        local obj_name = SceneObject.call(part_obj, "get_Name")
                                        imgui.text_colored(string.format("%s [%s] (No Mesh)", part_name, obj_name), 0xFF808080)
                                    end
                                else
                                    imgui.text_colored(part_name .. " " .. T("not_equipped"), 0xFF808080)
                                end
                            end
                            imgui.tree_pop()
                        end
                    end

 end
end
