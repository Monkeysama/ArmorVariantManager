return function(env)
    local _ENV = env
local function draw_mesh_toggle(game_object, label, body_id, part_index)
    if not game_object then return end
    if not safe_object_alive(game_object) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then
            imgui.text_colored(label .. " " .. T("type_loading"), 0xFF808080)
            return
        end
    end
    local mesh_component = SceneObject.call(game_object, "getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh_component then
        if imgui.tree_node(label) then
            -- 启用模型复选框：武器模式下强制开启并禁用，防具模式正常交互
            local is_enabled = SceneObject.call(mesh_component, "get_Enabled")
            if is_weapon_mode then
                imgui.begin_disabled(true)
                imgui.checkbox(T("enable_mesh"), true)  -- 始终显示勾选，不可修改
                imgui.end_disabled()
            else
                local changed, new_value = imgui.checkbox(T("enable_mesh"), is_enabled)
                if changed then
                    SceneObject.call(mesh_component, "set_Enabled", new_value)
                    if body_id and part_index then
                        local s_idx = tostring(part_index)
                        if not active_overrides[body_id] then active_overrides[body_id] = {} end
                        if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                        active_overrides[body_id][s_idx].mesh_enabled = new_value
                        TransformManager.edit_base_field(body_id, s_idx, nil, new_value)
                        bump_overrides_version(body_id)
                    end
                end
            end

            local mat_count = SceneObject.call(mesh_component, "get_MaterialNum")
            if mat_count and mat_count > 0 then
                local s_idx = tostring(part_index)
                local function mat_is_operable(mat_name)
                    local flt = mat_filter_text[part_index] or ""
                    if flt ~= "" and not string.find(string.lower(mat_name), string.lower(flt), 1, true) then
                        return false
                    end
                    if is_selection_mode then
                        return get_material_group_owner(part_index, mat_name) == nil
                    else
                        return is_material_in_current_context(part_index, mat_name)
                    end
                end

                imgui.same_line()
                if imgui.button(T("select_all") .. "##sa_" .. s_idx) then
                    local all_on = true
                    for k = 0, mat_count - 1 do
                        local mn = SceneObject.call(mesh_component, "getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not (pending_material_selections[s_idx] and pending_material_selections[s_idx][mn]) then
                                    all_on = false; break
                                end
                            else
                                local intent = (active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mn])
                                local cur_on = (intent ~= nil) and intent or SceneObject.call(mesh_component, "getMaterialsEnable", k)
                                if not cur_on then
                                    all_on = false; break
                                end
                            end
                        end
                    end
                    local target_val = not all_on
                    for k = 0, mat_count - 1 do
                        local mn = SceneObject.call(mesh_component, "getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                pending_material_selections[s_idx][mn] = target_val or nil
                            else
                                SceneObject.call(mesh_component, "setMaterialsEnable", k, target_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = target_val
                                    TransformManager.edit_base_field(body_id, s_idx, mn, target_val)
                                    bump_overrides_version(body_id)
                                end
                            end
                        end
                    end
                end

                imgui.same_line()
                if imgui.button(T("invert_select") .. "##inv_" .. s_idx) then
                    for k = 0, mat_count - 1 do
                        local mn = SceneObject.call(mesh_component, "getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                local cur = pending_material_selections[s_idx][mn]
                                pending_material_selections[s_idx][mn] = (not cur) or nil
                            else
                                local cur = SceneObject.call(mesh_component, "getMaterialsEnable", k)
                                local nv = not cur
                                SceneObject.call(mesh_component, "setMaterialsEnable", k, nv)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = nv
                                    TransformManager.edit_base_field(body_id, s_idx, mn, nv)
                                    bump_overrides_version(body_id)
                                end
                            end
                        end
                    end
                end

                imgui.same_line()
                imgui.set_next_item_width(140)
                local flt_cur = mat_filter_text[part_index] or ""
                local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                if flt_changed then mat_filter_text[part_index] = flt_val end
                if flt_cur ~= "" then
                    imgui.same_line()
                    if imgui.button("x##fltclr_" .. s_idx) then mat_filter_text[part_index] = "" end
                end

                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")
                local filter_str = string.lower(mat_filter_text[part_index] or "")
                for i = 0, mat_count - 1 do
                    local mat_name = SceneObject.call(mesh_component, "getMaterialName", i)
                    if mat_name then
                        if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                            local is_mat_enabled = SceneObject.call(mesh_component, "getMaterialsEnable", i)
                            local owner = get_material_group_owner(part_index, mat_name)
                            local global_groups = get_material_global_groups(part_index, mat_name)
                            if is_selection_mode then
                                local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                                if owner and not new_group_is_global then
                                    imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF808080)
                                else
                                    local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                    if changed_sel then
                                        if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                        pending_material_selections[s_idx][mat_name] = new_sel
                                    end
                                    if #global_groups > 0 then
                                        local body_id_hint = get_primary_body_id()
                                        local saved = (body_id_hint and active_group_presets[body_id_hint]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname = saved[gname]
                                            if not pname or pname == "" then pname = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname and g_data.presets and g_data.presets[pname]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            else
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_visible"), gname), 0xFF80C0FF)
                                            end
                                        end
                                    end
                                end
                            else
                                if is_material_in_current_context(part_index, mat_name) then
                                    local mat_label = string.format("[%d] %s", i, mat_name)
                                    local intent_val = (active_overrides[body_id]
                                        and active_overrides[body_id][s_idx]
                                        and active_overrides[body_id][s_idx].materials
                                        and active_overrides[body_id][s_idx].materials[mat_name])
                                    local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                    local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                    if mat_changed then
                                        if body_id and part_index then
                                            if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                            if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                            if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                            active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                            TransformManager.edit_base_field(body_id, s_idx, mat_name, mat_new_val)
                                            bump_overrides_version(body_id)
                                        end
                                        local render_val
                                        if mat_new_val == true and is_globally_hidden(part_index, mat_name) then
                                            render_val = false
                                        else
                                            render_val = mat_new_val
                                        end
                                        SceneObject.call(mesh_component, "setMaterialsEnable", i, render_val)
                                    end
                                    if #global_groups > 0 then
                                        local body_id_hint2 = get_primary_body_id()
                                        local saved2 = (body_id_hint2 and active_group_presets[body_id_hint2]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname2 = saved2[gname]
                                            if not pname2 or pname2 == "" then pname2 = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname2 and g_data.presets and g_data.presets[pname2]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            end
                                        end
                                    end
                                else
                                    if current_group_name == "" and owner then
                                        imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF804040)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            imgui.tree_pop()
        end
    else
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end

-- 辅助函数：绘制条件的目标列表（分组下拉框支持全局分组前缀）
    return draw_mesh_toggle
end
