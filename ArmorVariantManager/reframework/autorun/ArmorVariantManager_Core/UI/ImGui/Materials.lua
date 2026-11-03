local Materials = {}

-- 控件只读取界面上下文并提交编辑；对象访问与武器开关策略来自游戏适配。
function Materials.new(deps)
    local access = deps.access
    local call = access.call
    return function(game_object, label, body_id, part_index)
        if not game_object or not access.valid(game_object) then return end
        local context = deps.context()
        local mesh_component, reason = access.mesh(game_object)
        if reason == "loading" then
            imgui.text_colored(label .. " " .. deps.translate("type_loading"), 0xFF808080)
            return
        end
        if mesh_component then
            if imgui.tree_node(label) then
                -- 1. 整体 Mesh 开关
                local is_enabled = call(mesh_component, "get_Enabled")
                if access.weapon_mesh_locked and context.weapon then
                    imgui.begin_disabled(true)
                    imgui.checkbox(deps.translate("enable_mesh"), true)
                    imgui.end_disabled()
                else
                    local changed, new_value = imgui.checkbox(deps.translate("enable_mesh"), is_enabled)
                    if changed then
                        call(mesh_component, "set_Enabled", new_value)
                        -- 记录手动显隐意图
                        if body_id and part_index then
                            deps.edit(body_id, part_index, nil, new_value)
                        end
                    end
                end

                -- 2. 遍历材质
                local mat_count = call(mesh_component, "get_MaterialNum")
                if mat_count and mat_count > 0 then
                    local s_idx = tostring(part_index)

                    -- 辅助：判断某材质在当前模式下是否"可操作"（过滤后可见且未被普通分组占用）
                    local function mat_is_operable(mn)
                        local flt = context.filters[part_index] or ""
                        if flt ~= "" and not string.find(string.lower(mn), string.lower(flt), 1, true) then
                            return false
                        end
                        if context.selecting then
                            return deps.owner(part_index, mn) == nil
                        else
                            return deps.in_context(part_index, mn)
                        end
                    end

                    -- 全选 / 反选 / 过滤框：与"启用模型"checkbox 同行
                    imgui.same_line()
                    if imgui.button(deps.translate("select_all") .. "##sa_" .. s_idx) then
                        -- 收集所有可操作材质的当前状态
                        local all_on = true
                        for k = 0, mat_count - 1 do
                            local mn = call(mesh_component, "getMaterialName", k)
                            if mn and mat_is_operable(mn) then
                                if context.selecting then
                                    if not (context.pending[s_idx] and context.pending[s_idx][mn]) then
                                        all_on = false; break
                                    end
                                else
                                    -- 优先用意图值判断全选状态
                                    local intent = (context.overrides[body_id]
                                        and context.overrides[body_id][s_idx]
                                        and context.overrides[body_id][s_idx].materials
                                        and context.overrides[body_id][s_idx].materials[mn])
                                    local cur_on = (intent ~= nil) and intent or call(mesh_component, "getMaterialsEnable", k)
                                    if not cur_on then
                                        all_on = false; break
                                    end
                                end
                            end
                        end
                        local target_val = not all_on
                        for k = 0, mat_count - 1 do
                            local mn = call(mesh_component, "getMaterialName", k)
                            if mn and mat_is_operable(mn) then
                                if context.selecting then
                                    if not context.pending[s_idx] then context.pending[s_idx] = {} end
                                    context.pending[s_idx][mn] = target_val or nil
                                else
                                    -- 全局隐藏锁：意图值正常存储，渲染时应用锁
                                    local render_val
                                    if access.bulk_lock and target_val == true and deps.hidden(part_index, mn) then
                                        render_val = false
                                    else
                                        render_val = target_val
                                    end
                                    call(mesh_component, "setMaterialsEnable", k, render_val)
                                    if body_id then
                                        deps.edit(body_id, part_index, mn, target_val)
                                    end
                                end
                            end
                        end
                    end

                    imgui.same_line()

                    -- 反选按钮：将可操作材质的当前状态取反
                    if imgui.button(deps.translate("invert_select") .. "##inv_" .. s_idx) then
                        for k = 0, mat_count - 1 do
                            local mn = call(mesh_component, "getMaterialName", k)
                            if mn and mat_is_operable(mn) then
                                if context.selecting then
                                    if not context.pending[s_idx] then context.pending[s_idx] = {} end
                                    local cur = context.pending[s_idx][mn]
                                    context.pending[s_idx][mn] = (not cur) or nil
                                else
                                    local cur = call(mesh_component, "getMaterialsEnable", k)
                                    local nv = not cur
                                    -- 全局隐藏锁：意图值正常存储，渲染时应用锁
                                    local render_val
                                    if access.bulk_lock and nv == true and deps.hidden(part_index, mn) then
                                        render_val = false
                                    else
                                        render_val = nv
                                    end
                                    call(mesh_component, "setMaterialsEnable", k, render_val)
                                    if body_id then
                                        deps.edit(body_id, part_index, mn, nv)
                                    end
                                end
                            end
                        end
                    end

                    -- 过滤输入框（与全选/反选同行）
                    imgui.same_line()
                    imgui.set_next_item_width(140)
                    local flt_cur = context.filters[part_index] or ""
                    local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                    if flt_changed then context.filters[part_index] = flt_val end
                    if flt_cur ~= "" then
                        imgui.same_line()
                        if imgui.button("x##fltclr_" .. s_idx) then context.filters[part_index] = "" end
                    end

                    -- 材质列表
                    imgui.separator()
                    imgui.text(deps.translate("materials") .. " (" .. tostring(mat_count) .. "):")

                    -- 材质列表（过滤后显示）
                    local filter_str = string.lower(context.filters[part_index] or "")
                    for i = 0, mat_count - 1 do
                        local mat_name = call(mesh_component, "getMaterialName", i)
                        if mat_name then
                            -- 过滤：名称不含关键字则跳过
                            if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                                local is_mat_enabled = call(mesh_component, "getMaterialsEnable", i)
                                local owner = deps.owner(part_index, mat_name)
                                local global_groups = deps.global_groups(part_index, mat_name)
                                -- A. 分组创建模式
                                if context.selecting then
                                    local is_selected = context.pending[s_idx] and context.pending[s_idx][mat_name]
                                    if owner and not context.new_global then
                                        -- 普通分组不能选择已被其他普通分组占用的材质
                                        imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, deps.translate("already_in_group"), owner), 0xFF808080)
                                    else
                                        local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                        if changed_sel then
                                            if not context.pending[s_idx] then context.pending[s_idx] = {} end
                                            context.pending[s_idx][mat_name] = new_sel
                                        end
                                        if #global_groups > 0 then
                                            local bid_hint = deps.body_id()
                                            local ag_saved = (bid_hint and deps.selected(bid_hint)) or {}
                                            for _, gname in ipairs(global_groups) do
                                                local g_data = context.config.groups and context.config.groups[gname]
                                                local pname = ag_saved[gname]
                                                if not pname or pname == "" then pname = g_data and g_data.default_preset end
                                                local def_preset = g_data and pname and g_data.presets and g_data.presets[pname]
                                                local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                                if global_hidden then
                                                    imgui.same_line()
                                                    imgui.text_colored(string.format(deps.translate("in_global_group_hidden"), gname), 0xFF4080FF)
                                                else
                                                    imgui.same_line()
                                                    imgui.text_colored(string.format(deps.translate("in_global_group_visible"), gname), 0xFF80C0FF)
                                                end
                                            end
                                        end
                                    end
                                else
                                    -- B. 正常管理模式
                                    if deps.in_context(part_index, mat_name) then
                                        local mat_label = string.format("[%d] %s", i, mat_name)
                                        -- 优先用 context.overrides 里的意图值显示 checkbox，避免全局锁强制隐藏后 checkbox 跳回未勾选
                                        local intent_val = (context.overrides[body_id]
                                            and context.overrides[body_id][s_idx]
                                            and context.overrides[body_id][s_idx].materials
                                            and context.overrides[body_id][s_idx].materials[mat_name])
                                        local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                        local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                        if mat_changed then
                                            -- 记录用户意图值到 context.overrides（全局锁不影响存储的意图）
                                            if body_id and part_index then
                                                deps.edit(body_id, part_index, mat_name, mat_new_val)
                                            end
                                            -- 实际渲染时应用全局锁：被全局隐藏的材质始终保持隐藏
                                            local render_val
                                            if mat_new_val == true and deps.hidden(part_index, mat_name) then
                                                render_val = false
                                            else
                                                render_val = mat_new_val
                                            end
                                            call(mesh_component, "setMaterialsEnable", i, render_val)
                                        end
                                        if #global_groups > 0 then
                                            local bid_hint2 = deps.body_id()
                                            local ag_saved2 = (bid_hint2 and deps.selected(bid_hint2)) or {}
                                            for _, gname in ipairs(global_groups) do
                                                local g_data = context.config.groups and context.config.groups[gname]
                                                local pname2 = ag_saved2[gname]
                                                if not pname2 or pname2 == "" then pname2 = g_data and g_data.default_preset end
                                                local def_preset = g_data and pname2 and g_data.presets and g_data.presets[pname2]
                                                local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                                if global_hidden then
                                                    imgui.same_line()
                                                    imgui.text_colored(string.format(deps.translate("in_global_group_hidden"), gname), 0xFF4080FF)
                                                end
                                            end
                                        end
                                    else
                                        if context.group == "" and owner then
                                            imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, deps.translate("already_in_group"), owner), 0xFF804040)
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
            imgui.text_colored(label .. " " .. deps.translate("no_mesh"), 0xFF808080)
        end
    end
end

return Materials
