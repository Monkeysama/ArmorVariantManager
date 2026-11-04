local Presets = {}

function Presets.new(app, view)
    local game = app.game
    local config_session, global_config = app.session, app.global_config
    local workspace = app.workspace
    local state, T = workspace.state, app.translate
    local PART_INDEX_TO_NAME = {[0]="helm",[1]="body",[2]="arm",[3]="waist",[4]="leg",[5]="slinger"}
    local get_ground_clipping_settings = app.height and app.height.get
    local set_ground_clipping_settings = app.height and app.height.set
    local manual_import = app.manual_import
    local manual_selector = {files={}, names={}, index=1, open=false, error=""}
    local function draw_manual_import(body_id)
        if not manual_import or state.weapon then return end
        if manual_selector.body_id ~= body_id then
            manual_selector.body_id, manual_selector.open, manual_selector.error = body_id, false, ""
        end
        if imgui.button(T("manual_find_preset")) then
            manual_selector.open = not manual_selector.open
            if manual_selector.open then
                local ok, files = pcall(manual_import.list, false)
                manual_selector.files, manual_selector.names, manual_selector.index = {}, {}, 1
                manual_selector.error = ok and "" or tostring(files)
                if ok then
                    manual_selector.files = files
                    for index, file in ipairs(files) do manual_selector.names[index] = file.name end
                end
            end
        end
        if not manual_selector.open then return end
        if #manual_selector.files == 0 then
            imgui.text(T("no_preset_files"))
        else
            local changed, index = imgui.combo("##manual_file_selector", manual_selector.index, manual_selector.names)
            if changed then manual_selector.index = index end
            if imgui.button(T("load_selected_preset")) then
                local ok, saved, reason = pcall(app.load_manual_preset_file,
                    manual_selector.files[manual_selector.index].path, body_id)
                if ok and saved then manual_selector.open, manual_selector.error = false, ""
                else manual_selector.error = tostring(ok and reason or saved) end
            end
        end
        if manual_selector.error ~= "" then imgui.text_colored(manual_selector.error, 0xFF0000FF) end
    end


    return function(body_id)
        if view.imported ~= workspace.imported then
            view.imported, view.sort_mode = workspace.imported, nil
        end
        -- 使用 pcall 包裹整个预设管理区域，防止 UI 脚本报错导致 ImGui Mismatch 崩溃
        local ui_status, ui_err = pcall(function()
            -- 配置被还原提示横幅：检测到主配置被 mod 重装覆盖时，提供一键恢复入口
            -- 恢复/忽略后由配置会话立即隐藏横幅。
            if config_session.pending(body_id) then
                imgui.text_colored(T("config_restored_warning"), 0xFF00CCFF)
                if imgui.button(T("restore_from_backup") .. "##restore_backup") then
                    -- "已处理"标记由 restore_config_from_backup 在写回成功后设置。
                    app.restore_config_from_backup(body_id)
                end
                imgui.same_line()
                if imgui.button(T("dismiss") .. "##dismiss_restore") then
                    config_session.dismiss(body_id)
                end
                imgui.separator()
            end
            -- 1. 准备数据
            local global_label = T("global_group_label") or "[Global]"
            local full_group_list = {T("main_list")}
            for _, gname in ipairs(state.groups) do
                local g_data = workspace.config.groups and workspace.config.groups[gname]
                if g_data and g_data.is_global then
                    table.insert(full_group_list, global_label .. " " .. gname)
                else
                    table.insert(full_group_list, gname)
                end
            end
            local current_group_combo_index = 1
            if state.group ~= "" then
                for i, gname in ipairs(state.groups) do
                    if gname == state.group then current_group_combo_index = i + 1; break end
                end
            end

            -- 2. 预设与分组选择 (左右分区布局)
            if imgui.begin_table("PresetsLayout", 2, 512) then
                imgui.table_setup_column("PresetArea", 2048, 1.0)
                imgui.table_setup_column("GroupArea", 2048, 1.0)
                -- 第一行
                imgui.table_next_row()
                imgui.table_next_column()
                imgui.text(T("preset") .. ":")
                imgui.table_next_column()
                imgui.text(T("group") .. ":")

                -- 第二行
                imgui.table_next_row()
                imgui.table_next_column()
                imgui.set_next_item_width(-1)
                if #state.presets > 0 then
                    local changed_idx, idx = imgui.combo("##preset_selector", state.preset_index, state.presets)
                    if changed_idx then
                        state.preset_index = idx
                        local current_preset_name = state.presets[state.preset_index]
                        if current_preset_name then app.apply_preset(current_preset_name) end
                        app.auto_set_selected_preset_as_default(body_id)
                    end
                else
                    local no_preset_key = state.weapon and "no_weapon_presets" or "no_presets"
                    imgui.text_colored("[" .. T(no_preset_key) .. "]", 0xFF808080)
                end

                imgui.table_next_column()
                imgui.set_next_item_width(-1)
                local changed_g, g_idx = imgui.combo("##group_selector", current_group_combo_index, full_group_list)
                if changed_g then
                    state.group = (g_idx == 1) and "" or state.groups[g_idx - 1]
                    state.group_index = g_idx
                    workspace.update_preset_names_list()
                end

                -- 第三行
                imgui.table_next_row()
                imgui.table_next_column()
                -- 预设操作
                if #state.presets > 0 then
                    local current_preset_name = state.presets[state.preset_index]
                    local ctx_default = (state.group == "") and workspace.config.default_preset or
                                       (workspace.config.groups[state.group] and workspace.config.groups[state.group].default_preset)
                    if imgui.button(T("delete_preset")) then
                        app.delete_preset(current_preset_name, body_id)
                    end
                    imgui.same_line()
                    if not global_config.auto_set_selected_preset_as_default
                        and imgui.button(T("set_as_default")) then
                        app.set_preset_as_default(current_preset_name, body_id)
                    end
                    -- 预设状态提示
                    imgui.same_line()
                    if ctx_default == current_preset_name then
                        imgui.text_colored(T("selected_and_default"), 0xFF00FF00)
                    else
                        imgui.text_colored(T("selected_not_default"), 0xFF00CCFF)
                    end
                    -- 排序按钮
                    imgui.same_line()
                    if imgui.button(T("sort") .. "##p_sort") then
                        view.sort_mode = "preset"
                        -- 初始化排序临时列表
                        view.sort_temp_list = {}
                        for _, pn in ipairs(state.presets) do
                            table.insert(view.sort_temp_list, pn)
                        end
                        view.sort_selected_index = state.preset_index
                    end
                end

                -- 自动保存为全局设置；开启时立即将当前选中预设写为当前分组默认值。
                imgui.spacing()
                local changed_auto, auto_enabled = imgui.checkbox(
                    T("auto_set_selected_preset_as_default"),
                    global_config.auto_set_selected_preset_as_default == true)
                if changed_auto then
                    local saved, reason = app.set_setting("auto_set_selected_preset_as_default", auto_enabled == true)
                    view.settings_error = not saved and reason or nil
                end

                -- 新增预设 UI (在预设列)
                imgui.spacing()
                imgui.text(T("create_new_preset"))
                imgui.set_next_item_width(-1)
                local cp, ptext = imgui.input_text("##new_preset_name_input", view.new_preset_name)
                if cp then view.new_preset_name = ptext end
                if imgui.button(T("save_preset") .. "##p_left") then
                    if view.new_preset_name ~= "" then
                        if app.save_preset(view.new_preset_name, body_id) then
                            view.new_preset_name = ""
                            workspace.update_preset_names_list()
                        end
                    end
                end
                -- 覆盖当前预设按钮
                if #state.presets > 0 then
                    imgui.same_line()
                    if imgui.button(T("overwrite_preset") .. "##p_overwrite") then
                        local current_preset_name = state.presets[state.preset_index]
                        if current_preset_name and current_preset_name ~= "" then
                            app.save_preset(current_preset_name, body_id)
                        end
                    end
                end

                imgui.table_next_column()
                -- 分组操作
                if not state.selecting then
                    if imgui.button(T("start_selection") .. "##right") then
                        state.selecting = true
                        state.pending = {}
                    end
                    if state.group ~= "" then
                        imgui.same_line()
                        if imgui.button(T("delete_group") .. "##right") then
                            app.delete_group(state.group, body_id)
                        end
                    end
                    -- 分组排序按钮（有分组时才显示）
                    if workspace.config.groups and next(workspace.config.groups) then
                        imgui.same_line()
                        if imgui.button(T("sort") .. "##g_sort") then
                            view.sort_mode = "group"
                            view.sort_temp_list = {}
                            for _, gn in ipairs(state.groups) do
                                table.insert(view.sort_temp_list, gn)
                            end
                            view.sort_selected_index = 1
                            if state.group ~= "" then
                                for gi, gn in ipairs(view.sort_temp_list) do
                                    if gn == state.group then view.sort_selected_index = gi; break end
                                end
                            end
                        end
                    end
                else
                    -- 选择模式活跃状态
                    imgui.text_colored(T("selection_mode") .. " ", 0xFF00FFFF)
                    imgui.text_colored(T("selection_mode_desc") .. " ", 0xFF00FFFF)
                    local cg, gtext = imgui.input_text(T("name") .. "##gn", view.new_group_name)
                    if cg then view.new_group_name = gtext end
                    -- 全局分组勾选框
                    local cg_global, new_is_global = imgui.checkbox(T("is_global_group") .. "##gisgl", view.new_group_is_global)
                    if cg_global then view.new_group_is_global = new_is_global end
                    if view.new_group_is_global then
                        imgui.same_line()
                        imgui.text_colored(T("is_global_group_desc"), 0xFF80FFFF)
                    end
                    if imgui.button(T("confirm_creation") .. "##gconfirm") then
                        if view.new_group_name ~= "" and app.create_new_group(view.new_group_name, body_id, view.new_group_is_global) then
                            state.group = view.new_group_name
                            view.new_group_name = ""
                            view.new_group_is_global = false
                            state.selecting = false
                            workspace.update_group_names_list()
                            workspace.update_preset_names_list()
                        end
                    end
                    imgui.same_line()
                    if imgui.button(T("cancel") .. "##gcancel") then
                        state.selecting = false
                        view.new_group_is_global = false
                    end
                end
                imgui.end_table()
            end

            -- 分组材质预览
            -- 4. 分组预览
            if state.group ~= "" then
                local group_data = workspace.config.groups[state.group]
                if group_data and group_data.mask and imgui.tree_node(T("materials") .. " in " .. state.group) then
                    for p_idx, mats in pairs(group_data.mask) do
                        local part_name = T(PART_INDEX_TO_NAME[tonumber(p_idx)]) or p_idx
                        for m_name, _ in pairs(mats) do
                            imgui.text("  • [" .. part_name .. "] " .. tostring(m_name))
                        end
                    end
                    imgui.tree_pop()
                end
            end

            -- C. 自动查找 (仅在没有任何预设数据时显示)
            local has_any_data = (next(workspace.config.presets) ~= nil)
            if not has_any_data and workspace.config.groups then
                for _, g in pairs(workspace.config.groups) do
                    if g.presets and next(g.presets) then has_any_data = true; break end
                end
            end
            if not has_any_data then
                imgui.separator()
                if imgui.button(T("auto_find_preset")) then
                    local st, res, m = pcall(app.find_auto_preset, body_id)
                    if st and res then
                        view.auto_find_log = T("auto_find_success") .. tostring(m or "")
                    elseif st and m == "No matching preset found" then
                        view.auto_find_log = T("auto_find_fail")
                    else
                        view.auto_find_log = st and ("Failed: " .. tostring(m)) or "Lua Error: " .. tostring(res)
                    end
                end
                if view.auto_find_log ~= "" then imgui.text_colored(view.auto_find_log, 0xFF00FFFF) end
            end
            draw_manual_import(body_id)

            -- 陷地修复放在预设、分组及自动查找按钮和结果提示下方。
            if game.wilds and not state.weapon then
                imgui.separator()
                local settings = get_ground_clipping_settings()
                local changed, value = imgui.checkbox(T("heel_title"), settings.enabled)
                if changed then set_ground_clipping_settings({ enabled = value }, body_id) end
                imgui.same_line()
                imgui.set_next_item_width(160)
                changed, value = imgui.slider_float("##ground_clipping_height", settings.height_cm, -10, 50, "%.1f cm")
                if changed then set_ground_clipping_settings({ height_cm = value }, body_id) end
                imgui.same_line()
                if imgui.button(T("heel_reset_short") .. "##ground_clipping_reset") then
                    set_ground_clipping_settings({ enabled = true, height_cm = 0 }, body_id)
                end
                imgui.separator()
            end
        end)
        if not ui_status then
            imgui.text_colored("UI Error: " .. tostring(ui_err), 0xFFFF0000)
            pcall(imgui.end_table)
        end

        -- 排序面板（在 pcall 外渲染，独立区域）
        if view.sort_mode then
            imgui.separator()
            local sort_title = (view.sort_mode == "group") and (T("sort") .. " - " .. T("group")) or (T("sort") .. " - " .. T("preset"))
            imgui.text_colored(sort_title, 0xFF00FFFF)
            imgui.spacing()
            -- 提示文字
            if view.sort_selected_index and view.sort_selected_index >= 1 and view.sort_selected_index <= #view.sort_temp_list then
                imgui.text_colored(T("sort_hint_selected") .. ": " .. view.sort_temp_list[view.sort_selected_index], 0xFFFFFF80)
            else
                imgui.text_colored(T("sort_hint_click"), 0xFF808080)
            end
            imgui.spacing()
            for si, sname in ipairs(view.sort_temp_list) do
                -- 上移按钮
                if si <= 1 then imgui.begin_disabled() end
                if imgui.button(T("move_up") .. "##su_" .. si) then
                    if si > 1 then
                        view.sort_temp_list[si], view.sort_temp_list[si - 1] = view.sort_temp_list[si - 1], view.sort_temp_list[si]
                        if view.sort_selected_index == si then view.sort_selected_index = si - 1
                        elseif view.sort_selected_index == si - 1 then view.sort_selected_index = si end
                    end
                end
                if si <= 1 then imgui.end_disabled() end
                imgui.same_line()
                -- 下移按钮
                if si >= #view.sort_temp_list then imgui.begin_disabled() end
                if imgui.button(T("move_down") .. "##sd_" .. si) then
                    if si < #view.sort_temp_list then
                        view.sort_temp_list[si], view.sort_temp_list[si + 1] = view.sort_temp_list[si + 1], view.sort_temp_list[si]
                        if view.sort_selected_index == si then view.sort_selected_index = si + 1
                        elseif view.sort_selected_index == si + 1 then view.sort_selected_index = si end
                    end
                end
                if si >= #view.sort_temp_list then imgui.end_disabled() end
                imgui.same_line()
                -- 名称按钮（点击选中，选中项高亮）
                if si == view.sort_selected_index then
                    imgui.push_style_color(21, 0xFF00AAFF) -- ImGuiCol_Button 高亮
                end
                if imgui.button(tostring(si) .. ". " .. sname .. "##sn_" .. si) then
                    view.sort_selected_index = si
                end
                if si == view.sort_selected_index then
                    imgui.pop_style_color(1)
                end
                -- 插入按钮：将选中项移动到第si行的位置
                if view.sort_selected_index and view.sort_selected_index ~= si and view.sort_selected_index >= 1 and view.sort_selected_index <= #view.sort_temp_list then
                    imgui.same_line()
                    if imgui.button(T("sort_insert_here") .. "##si_" .. si) then
                        local item = table.remove(view.sort_temp_list, view.sort_selected_index)
                        table.insert(view.sort_temp_list, si, item)
                        view.sort_selected_index = si
                    end
                end
            end
            -- 底部按钮
            imgui.spacing()
            if imgui.button(T("sort_confirm") .. "##sort_ok") then
                local saved
                if view.sort_mode == "group" then
                    saved = app.reorder_groups(view.sort_temp_list, body_id)
                elseif view.sort_mode == "preset" then
                    saved = app.reorder_presets(view.sort_temp_list, body_id)
                end
                if saved then
                    view.sort_mode = nil
                    view.sort_temp_list = {}
                end
            end
            imgui.same_line()
            if imgui.button(T("sort_cancel") .. "##sort_no") then
                view.sort_mode = nil
                view.sort_temp_list = {}
            end
        end
    end
end

return Presets
