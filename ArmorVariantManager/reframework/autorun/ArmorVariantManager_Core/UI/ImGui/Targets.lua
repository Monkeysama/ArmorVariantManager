local Targets = {}

function Targets.new(app)
    local workspace = app.workspace
    local state, T = workspace.state, app.translate
    local function draw_targets_ui(targets, rule_type, rule_idx)
        local body_id = state.body_id
        for j, target in ipairs(targets) do
            imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)

            -- 分组选择
            -- 准备分组下拉框的数据（按 group_order 排序）
            local all_groups = { "" }
            local all_groups_display = { T("main_list") or "Main" }
            local global_label_t = T("global_group_label") or "[Global]"
            if workspace.config.groups then
                -- 按 group_order 排序，fallback 字母序
                local ordered_gnames = {}
                local in_order = {}
                if workspace.config.group_order then
                    for _, gname in ipairs(workspace.config.group_order) do
                        if workspace.config.groups[gname] then
                            table.insert(ordered_gnames, gname)
                            in_order[gname] = true
                        end
                    end
                end
                for gname, _ in pairs(workspace.config.groups) do
                    if not in_order[gname] then table.insert(ordered_gnames, gname) end
                end
                for _, gname in ipairs(ordered_gnames) do
                    local g_data = workspace.config.groups[gname]
                    table.insert(all_groups, gname)
                    if g_data.is_global then
                        table.insert(all_groups_display, global_label_t .. " " .. gname)
                    else
                        table.insert(all_groups_display, gname)
                    end
                end
            end
            local g_idx = 1
            for idx, g in ipairs(all_groups) do
                if g == (target.group or "") then g_idx = idx; break end
            end
            imgui.set_next_item_width(120)
            local c_g, v_g = imgui.combo("##group", g_idx, all_groups_display)
            if c_g then
                target.group = all_groups[v_g]
                target.preset = "" -- 分组改变时重置预设
                app.save_current_config_to_file(body_id)
            end

            imgui.same_line()

            -- 预设选择（按 preset_order 排序）
            local target_presets = {}
            if target.group == "" or target.group == nil then
                if workspace.config.presets then
                    -- 按 preset_order 排序，fallback 字母序
                    local in_order = {}
                    if workspace.config.preset_order then
                        for _, pname in ipairs(workspace.config.preset_order) do
                            if workspace.config.presets[pname] then
                                table.insert(target_presets, pname)
                                in_order[pname] = true
                            end
                        end
                    end
                    for pname, _ in pairs(workspace.config.presets) do
                        if not in_order[pname] then table.insert(target_presets, pname) end
                    end
                end
            else
                if workspace.config.groups and workspace.config.groups[target.group] and workspace.config.groups[target.group].presets then
                    local g_data = workspace.config.groups[target.group]
                    -- 按分组的 preset_order 排序，fallback 字母序
                    local in_order = {}
                    if g_data.preset_order then
                        for _, pname in ipairs(g_data.preset_order) do
                            if g_data.presets[pname] then
                                table.insert(target_presets, pname)
                                in_order[pname] = true
                            end
                        end
                    end
                    for pname, _ in pairs(g_data.presets) do
                        if not in_order[pname] then table.insert(target_presets, pname) end
                    end
                end
            end

            local p_idx = 1
            local found = false
            for idx, p in ipairs(target_presets) do
                if p == target.preset then p_idx = idx; found = true; break end
            end

            if not found and #target_presets > 0 then
                target.preset = target_presets[1]
                app.save_current_config_to_file(body_id)
            end

            if #target_presets == 0 then table.insert(target_presets, "None") end

            imgui.set_next_item_width(150)
            local c_p, v_p = imgui.combo("##preset", p_idx, target_presets)
            if c_p and target_presets[v_p] ~= "None" then
                target.preset = target_presets[v_p]
                app.save_current_config_to_file(body_id)
            end

            imgui.same_line()
            if imgui.button(T("delete_condition") .. "##del_cond") then
                table.remove(targets, j)
                app.save_current_config_to_file(body_id)
            end
            imgui.pop_id()
        end
    end

    return draw_targets_ui
end

return Targets
