-- 荒野 b1b3bbb 的界面显隐操作；仅隔离外部环境。
return function(env)
    local _ENV = env
local function draw_mesh_toggle(game_object, label, body_id, part_index)
    if not game_object then return end
    if not sdk.is_managed_object(game_object) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then
            imgui.text_colored(label .. " " .. T("type_loading"), 0xFF808080)
            return
        end
    end
    -- 获取 Mesh 组件
    local mesh_component = game_object:call("getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh_component then
        if imgui.tree_node(label) then
            -- 1. 整体 Mesh 开关
            local is_enabled = mesh_component:call("get_Enabled")
            local changed, new_value = imgui.checkbox(T("enable_mesh"), is_enabled)
            if changed then
                mesh_component:call("set_Enabled", new_value)
                -- 更新 active_overrides
                if body_id and part_index then
                    local s_idx = tostring(part_index)
                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                    active_overrides[body_id][s_idx].mesh_enabled = new_value
                end
            end

            -- 2. 遍历材质
            local mat_count = mesh_component:call("get_MaterialNum")
            if mat_count and mat_count > 0 then
                local s_idx = tostring(part_index)

                -- 辅助：判断某材质在当前模式下是否"可操作"（过滤后可见且未被普通分组占用）
                local function mat_is_operable(mn)
                    local flt = mat_filter_text[part_index] or ""
                    if flt ~= "" and not string.find(string.lower(mn), string.lower(flt), 1, true) then
                        return false
                    end
                    if is_selection_mode then
                        return get_material_group_owner(part_index, mn) == nil
                    else
                        return is_material_in_current_context(part_index, mn)
                    end
                end

                -- 全选 / 反选 / 过滤框：与"启用模型"checkbox 同行
                imgui.same_line()
                if imgui.button(T("select_all") .. "##sa_" .. s_idx) then
                    -- 收集所有可操作材质的当前状态
                    local all_on = true
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not (pending_material_selections[s_idx] and pending_material_selections[s_idx][mn]) then
                                    all_on = false; break
                                end
                            else
                                -- 优先用意图值判断全选状态
                                local intent = (active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mn])
                                local cur_on = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", k)
                                if not cur_on then
                                    all_on = false; break
                                end
                            end
                        end
                    end
                    local target_val = not all_on
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                pending_material_selections[s_idx][mn] = target_val or nil
                            else
                                -- 全局隐藏锁：意图值正常存储，渲染时应用锁
                                local render_val
                                if target_val == true and is_globally_hidden(part_index, mn) then
                                    render_val = false
                                else
                                    render_val = target_val
                                end
                                mesh_component:call("setMaterialsEnable", k, render_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = target_val  -- 存意图值
                                end
                            end
                        end
                    end
                end

                imgui.same_line()

                -- 反选按钮：将可操作材质的当前状态取反
                if imgui.button(T("invert_select") .. "##inv_" .. s_idx) then
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                local cur = pending_material_selections[s_idx][mn]
                                pending_material_selections[s_idx][mn] = (not cur) or nil
                            else
                                local cur = mesh_component:call("getMaterialsEnable", k)
                                local nv = not cur
                                -- 全局隐藏锁：意图值正常存储，渲染时应用锁
                                local render_val
                                if nv == true and is_globally_hidden(part_index, mn) then
                                    render_val = false
                                else
                                    render_val = nv
                                end
                                mesh_component:call("setMaterialsEnable", k, render_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = nv  -- 存意图值
                                end
                            end
                        end
                    end
                end

                -- 过滤输入框（与全选/反选同行）
                imgui.same_line()
                imgui.set_next_item_width(140)
                local flt_cur = mat_filter_text[part_index] or ""
                local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                if flt_changed then mat_filter_text[part_index] = flt_val end
                if flt_cur ~= "" then
                    imgui.same_line()
                    if imgui.button("x##fltclr_" .. s_idx) then mat_filter_text[part_index] = "" end
                end

                -- 材质列表
                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")

                -- 材质列表（过滤后显示）
                local filter_str = string.lower(mat_filter_text[part_index] or "")
                for i = 0, mat_count - 1 do
                    local mat_name = mesh_component:call("getMaterialName", i)
                    if mat_name then
                        -- 过滤：名称不含关键字则跳过
                        if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                            local is_mat_enabled = mesh_component:call("getMaterialsEnable", i)
                            local owner = get_material_group_owner(part_index, mat_name)
                            local global_groups = get_material_global_groups(part_index, mat_name)
                            -- A. 分组创建模式
                            if is_selection_mode then
                                local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                                if owner and not new_group_is_global then
                                    -- 普通分组不能选择已被其他普通分组占用的材质
                                    imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF808080)
                                else
                                    local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                    if changed_sel then
                                        if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                        pending_material_selections[s_idx][mat_name] = new_sel
                                    end
                                    if #global_groups > 0 then
                                        local bid_hint = get_body_id()
                                        local ag_saved = (bid_hint and get_effective_group_presets(bid_hint)) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname = ag_saved[gname]
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
                                -- B. 正常管理模式
                                if is_material_in_current_context(part_index, mat_name) then
                                    local mat_label = string.format("[%d] %s", i, mat_name)
                                    -- 优先用 active_overrides 里的意图值显示 checkbox，避免全局锁强制隐藏后 checkbox 跳回未勾选
                                    local intent_val = (active_overrides[body_id]
                                        and active_overrides[body_id][s_idx]
                                        and active_overrides[body_id][s_idx].materials
                                        and active_overrides[body_id][s_idx].materials[mat_name])
                                    local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                    local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                    if mat_changed then
                                        -- 记录用户意图值到 active_overrides（全局锁不影响存储的意图）
                                        if body_id and part_index then
                                            if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                            if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                            if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                            active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                        end
                                        -- 实际渲染时应用全局锁：被全局隐藏的材质始终保持隐藏
                                        local render_val
                                        if mat_new_val == true and is_globally_hidden(part_index, mat_name) then
                                            render_val = false
                                        else
                                            render_val = mat_new_val
                                        end
                                        mesh_component:call("setMaterialsEnable", i, render_val)
                                    end
                                    if #global_groups > 0 then
                                        local bid_hint2 = get_body_id()
                                        local ag_saved2 = (bid_hint2 and get_effective_group_presets(bid_hint2)) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname2 = ag_saved2[gname]
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
        -- 如果没有 Mesh 组件，显示禁用状态的文本
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end


return draw_mesh_toggle, {
    set_mesh_enabled = function(body_id, part_index, meshes, enabled)
        if not body_id then return end
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        local key = tostring(part_index)
        if not active_overrides[body_id][key] then
            active_overrides[body_id][key] = { materials = {} }
        elseif not active_overrides[body_id][key].materials then
            active_overrides[body_id][key].materials = {}
        end
        active_overrides[body_id][key].mesh_enabled = enabled
        for _, mesh in ipairs(meshes or {}) do
            if sdk.is_managed_object(mesh) then mesh:call("set_Enabled", enabled) end
        end
    end,

    -- 切换材质显示状态，并遵守全局隐藏分组的优先级。
    set_material_enabled = function(body_id, part_index, meshes, material_name, enabled)
        if not body_id then return end
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        local key = tostring(part_index)
        if not active_overrides[body_id][key] then
            active_overrides[body_id][key] = { materials = {} }
        elseif not active_overrides[body_id][key].materials then
            active_overrides[body_id][key].materials = {}
        end
        active_overrides[body_id][key].materials[material_name] = enabled
        local render_enabled = enabled
        if enabled and is_globally_hidden(part_index, material_name) then render_enabled = false end
        for _, mesh in ipairs(meshes or {}) do
            if sdk.is_managed_object(mesh) then
                local count = mesh:call("get_MaterialNum") or 0
                for i = 0, count - 1 do
                    if mesh:call("getMaterialName", i) == material_name then
                        mesh:call("setMaterialsEnable", i, render_enabled)
                    end
                end
            end
        end
    end,

}
end
