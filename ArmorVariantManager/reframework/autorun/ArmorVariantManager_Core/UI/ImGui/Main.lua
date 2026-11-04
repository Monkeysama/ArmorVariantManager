local Main = {}

function Main.new(app, legacy)
    local game, backend, runtime = app.game, app.backend, app.runtime
    local appearance, global_config = app.appearance, app.global_config
    local workspace = app.workspace
    local state = workspace.state
    local T, version, author = app.translate, app.version, app.author
    local TransformManager = app.rules
    local active_overrides = appearance.overrides
    local view = {new_preset_name="", new_group_name="", new_group_is_global=false,
        filters={}, sort_temp_list={}, sort_selected_index=1, auto_find_log=""}
    local show_debug_window = false
    local variant_manager_ui = legacy
    local game_options = app.game_options
    local safe_get_game_object = runtime.scene_object and runtime.scene_object.game_object
    local actors = runtime.actors
    local function get_all_characters() return actors.all() end
    local can_use_transform = actors.can_transform
    local draw_targets_ui = require("ArmorVariantManager_Core.UI.ImGui.Targets").new(app)
    local draw_presets = require("ArmorVariantManager_Core.UI.ImGui.Presets").new(app, view)
    local draw_material_panel = require("ArmorVariantManager_Core.UI.ImGui.Materials").new({
        access = require(game.prefix .. "MaterialView").new(),
        translate = T, edit = function(id, part, material, enabled)
            return appearance.edit(id, part, material, enabled, workspace.config)
        end,
        owner = workspace.get_material_group_owner, global_groups = workspace.get_material_global_groups,
        in_context = workspace.is_material_in_current_context, hidden = workspace.is_globally_hidden,
        body_id = workspace.get_body_id, selected = workspace.get_effective_group_presets,
        context = function()
            return {filters = view.filters, pending = state.pending,
                selecting = state.selecting, new_global = view.new_group_is_global,
                overrides = active_overrides, config = workspace.config,
                group = state.group, weapon = state.weapon}
        end,
    })

    local function draw_mesh_toggle(game_object, label, body_id, part_index)
        return draw_material_panel(game_object, label, body_id, part_index)
    end

    local draw_part_list = require("ArmorVariantManager_Core.UI.ImGui.Parts").new(
        runtime.part_view, T, draw_mesh_toggle)
    local draw_game_conditions = require(game.prefix .. "ImGuiConditions").new({
        translate = T,
        rules = TransformManager,
        save = app.save_current_config_to_file,
        draw_targets = draw_targets_ui,
        set_enabled = backend.set_enabled, refresh = backend.refresh,
        can_transform = can_use_transform,
        game_object = safe_get_game_object,
    })

    local function set_setting(id, value)
        local saved, reason = app.set_setting(id, value)
        view.settings_error = not saved and reason or nil
    end

    return function()
        -- D2D与旧ImGui回调都读取同一状态，不在这里重复轮询游戏菜单/加载状态。
        if imgui.tree_node(T("mod_name")) then
            if runtime.is_suspended() then
                imgui.text(T("runtime_paused"))
                imgui.tree_pop()
                return
            end
            imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
            imgui.separator()

            -- 新 UI 设置和旧 UI 隐藏逻辑由独立模块处理。
            if variant_manager_ui and variant_manager_ui:draw_settings() then
                imgui.tree_pop()
                return
            end

            if game.wilds and show_debug_window then
                if imgui.tree_node("Debug Info") then
                    local all_chars = get_all_characters()
                    imgui.text("Detected Characters: " .. tostring(#all_chars))
                    if imgui.begin_table("DebugTable", 3) then
                        imgui.table_setup_column("Index")
                        imgui.table_setup_column("Address")
                        imgui.table_setup_column("BodyID")
                        imgui.table_headers_row()
                        for i, char in ipairs(all_chars) do
                            imgui.table_next_row()
                            imgui.table_set_column_index(0)
                            imgui.text(tostring(i))
                            imgui.table_set_column_index(1)
                            local addr = "N/A"
                            if char and sdk.is_managed_object(char) then
                                local ok, game_obj = (function() local go = safe_get_game_object(char, "ui_body_mesh") if not go then return false end return true, go end)()
                                if ok and game_obj then addr = tostring(game_obj) end
                            else
                                addr = "Invalid/Destroyed"
                            end
                            imgui.text(addr)
                            imgui.table_set_column_index(2)
                            imgui.text(runtime.equipment.body_id(char) or "Unknown")
                        end
                        imgui.end_table()
                    end
                    imgui.separator()
                    imgui.text("Cache Status:")
                    for k, v in pairs(actors.cached()) do
                        imgui.text("Key: " .. tostring(k) .. " | Valid: " .. tostring(sdk.is_managed_object(v.char)))
                    end
                    imgui.tree_pop()
                end
            end

            -- 使用 pcall 包裹核心绘制逻辑，防止 Lua 错误导致 ImGui 状态异常
            local status, err = pcall(function()
                -- 模式切换 Tabs (使用 Radio Button 替代 Tab Bar，因为 REFramework 某些版本不支持 begin_tab_bar)
                local armor_mode_text = T("armor_mode") or "Armor Variant"
                local weapon_mode_text = T("weapon_mode") or "Weapon Variant"

                -- 使用 Checkbox 模拟切换，因为部分版本也没有 radio_button
                local changed_armor, new_armor = imgui.checkbox(armor_mode_text, not state.weapon)
                if changed_armor and new_armor then
                    workspace.switch_variant_mode(false)
                end

                imgui.same_line()
                local changed_weapon, new_weapon = imgui.checkbox(weapon_mode_text, state.weapon)
                if changed_weapon and new_weapon then
                    workspace.switch_variant_mode(true)
                end
                imgui.separator()

                local character = runtime.actors.local_player()
                if character and sdk.is_managed_object(character) then
                    local body_id = workspace.get_body_id()
                    -- imgui.text(T("current_body_id") .. tostring(body_id))
                    if body_id then
                        -- ========== 预设管理区域 ==========
                        if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                            draw_presets(body_id)
                            imgui.tree_pop()
                        end

                        imgui.separator()

                        -- ========== 变身管理区域 ==========
                        if imgui.tree_node(T("transform_manager") .. " (" .. body_id .. ")") then
                            local inner_status, inner_err = pcall(function()
                                draw_game_conditions(workspace.config, body_id, character)
                            end)
                            if not inner_status then
                                imgui.text_colored("UI Error: " .. tostring(inner_err), 0xFFFF0000)
                            end
                            imgui.tree_pop()
                        end

                        imgui.separator()

                        draw_part_list(character, body_id, state.weapon, active_overrides[body_id], backend.player_handle(character))

                        imgui.separator()

                        -- ========== 语言切换 ==========
                        if imgui.tree_node(T("language")) then
                            -- 使用 Checkbox 模拟 RadioButton (因为 radio_button 可能不可用)
                            local is_en = global_config.language == "en"
                            local changed_en, new_en = imgui.checkbox("English", is_en)
                            if changed_en and new_en then
                                set_setting("language", "en")
                            end
                            imgui.same_line()
                            local is_zh = global_config.language == "zh"
                            local changed_zh, new_zh = imgui.checkbox("中文", is_zh)
                            if changed_zh and new_zh then
                                set_setting("language", "zh")
                            end
                            imgui.tree_pop()
                        end

                        imgui.separator()

                        if game_options then game_options.multiplayer() end

                        -- ========== 性能设置 ==========
                        if imgui.tree_node(T("performance_settings")) then
                            if game_options then game_options.performance()
                            else
                            imgui.text(T("performance_desc"))
                            imgui.spacing()
                            -- 1. 扫描间隔
                            local changed_si, val_si = imgui.slider_float(T("scan_interval"), global_config.scan_interval, 0.1, 5.0)
                            if changed_si then
                                set_setting("scan_interval", val_si)
                            end
                            -- 2. 刷新间隔 (Body ID TTL)
                            local changed_ttl, val_ttl = imgui.slider_float(T("refresh_interval"), global_config.body_id_ttl, 0.1, 10.0)
                            if changed_ttl then
                                set_setting("body_id_ttl", val_ttl)
                            end
                            -- 3. 分帧扫描步频
                            local changed_bs, val_bs = imgui.slider_int(T("scanner_batch_size"), global_config.scanner_batch_size, 10, 1000)
                            if changed_bs then
                                set_setting("scanner_batch_size", val_bs)
                            end
                            end
                            imgui.tree_pop()
                        end
                    else
                        imgui.text_colored(T("no_body_part"), 0xFF0000FF)
                    end
                else
                    imgui.text_colored(T("waiting_for_player"), 0xFF0000FF)
                end
            end)
            if view.settings_error then imgui.text_colored(view.settings_error, 0xFF0000FF) end
            -- 如果发生错误，显示错误信息
            if not status then
                imgui.text_colored(T("lua_error") .. tostring(err), 0xFF0000FF)
            end
            imgui.tree_pop()
        end
    end
end

return Main
