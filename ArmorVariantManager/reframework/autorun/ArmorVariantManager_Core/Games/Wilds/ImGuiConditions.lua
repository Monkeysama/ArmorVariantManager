local Conditions = {}

-- 原生条件面板；游戏状态和编辑操作由应用层提供。
function Conditions.new(deps)
    local T = deps.translate
    local TransformManager = deps.rules
    local save_current_config_to_file = deps.save
    local draw_targets_ui = deps.draw_targets
    local can_use_transform = deps.can_transform
    local safe_get_game_object = deps.game_object
    local test_hp_input = "100"
    return function(current_config, body_id, character)
        if not can_use_transform(character) then return end
        -- 模块状态提示（选中条件或启用了该条件时才提示）
        local function should_show_warning(type_key)
            if not TransformManager.has_configured_condition(current_config, type_key) then return false end
            if current_config.is_parallel then
                return current_config.parallel_settings and current_config.parallel_settings[type_key] and current_config.parallel_settings[type_key].enabled
            else
                return current_config.transform_type == type_key
            end
        end

        if should_show_warning("hp") and not TransformManager.is_hp_module_initialized() then
            imgui.text_colored(T("hp_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("weapon") and not TransformManager.has_weapon_getter() then
            imgui.text_colored(T("weapon_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("spirit") and not TransformManager.has_spirit_getter() then
            imgui.text_colored(T("spirit_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("dual_blades") and not TransformManager.has_dual_blades_getter() then
            imgui.text_colored(T("dual_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("switch_axe") and not TransformManager.has_switch_axe_getter() then
            imgui.text_colored(T("switch_axe_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("insect_glaive") and not TransformManager.has_insect_glaive_getter() then
            imgui.text_colored(T("insect_glaive_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("charge_blade") and not TransformManager.has_charge_blade_getter() then
            imgui.text_colored(T("charge_blade_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("greatsword_type") and not TransformManager.has_greatsword_getter() then
            imgui.text_colored(T("greatsword_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("bow_level") and not TransformManager.has_bow_getter() then
            imgui.text_colored(T("bow_module_not_found"), 0xFF0000FF)
        end
        if should_show_warning("hammer_level") and not TransformManager.has_hammer_getter() then
            imgui.text_colored(T("hammer_module_not_found"), 0xFF0000FF)
        end
        imgui.separator()

        -- 模式选择
        local mode_text = current_config.is_parallel and T("current_mode_parallel") or T("current_mode_selection")
        imgui.text(mode_text)
        local parallel_btn_text = current_config.is_parallel and T("switch_to_selection") or T("switch_to_parallel")
        if imgui.button(parallel_btn_text) then
            current_config.is_parallel = not current_config.is_parallel
            save_current_config_to_file(body_id)
        end

        if not current_config.is_parallel then
            -- 单一条件模式
            local c_type_idx = 1
            if current_config.transform_type == "hp" then c_type_idx = 1
            elseif current_config.transform_type == "damage" then c_type_idx = 2
            elseif current_config.transform_type == "weapon" then c_type_idx = 3
            elseif current_config.transform_type == "spirit" then c_type_idx = 4
            elseif current_config.transform_type == "dual_blades" then c_type_idx = 5
            elseif current_config.transform_type == "switch_axe" then c_type_idx = 6
            elseif current_config.transform_type == "insect_glaive" then c_type_idx = 7
            elseif current_config.transform_type == "charge_blade" then c_type_idx = 8
            elseif current_config.transform_type == "greatsword_type" then c_type_idx = 9
            elseif current_config.transform_type == "greatsword_level" then c_type_idx = 10
            elseif current_config.transform_type == "bow_level" then c_type_idx = 11
            elseif current_config.transform_type == "hammer_level" then c_type_idx = 12
            end
            local c_type_list = {
                T("condition_hp"),
                T("condition_damage"),
                T("condition_weapon"),
                T("condition_spirit"),
                T("condition_dual_blades"),
                T("condition_switch_axe"),
                T("condition_insect_glaive"),
                T("condition_charge_blade"),
                T("condition_greatsword_type"),
                T("condition_greatsword_level"),
                T("condition_bow_level"),
                T("condition_hammer_level")
            }
            local c_changed, c_val = imgui.combo(T("transform_condition_type"), c_type_idx, c_type_list)
            if c_changed then
                if c_val == 1 then current_config.transform_type = "hp"
                elseif c_val == 2 then current_config.transform_type = "damage"
                elseif c_val == 3 then current_config.transform_type = "weapon"
                elseif c_val == 4 then current_config.transform_type = "spirit"
                elseif c_val == 5 then current_config.transform_type = "dual_blades"
                elseif c_val == 6 then current_config.transform_type = "switch_axe"
                elseif c_val == 7 then current_config.transform_type = "insect_glaive"
                elseif c_val == 8 then current_config.transform_type = "charge_blade"
                elseif c_val == 9 then current_config.transform_type = "greatsword_type"
                elseif c_val == 10 then current_config.transform_type = "greatsword_level"
                elseif c_val == 11 then current_config.transform_type = "bow_level"
                else current_config.transform_type = "hammer_level"
                end
                save_current_config_to_file(body_id)
            end
        else
            -- 并行条件模式
            imgui.indent(10)
            local function draw_parallel_setting(cond_key, label)
                local set = current_config.parallel_settings[cond_key]
                if not set then return end
                local changed_en, val_en = imgui.checkbox(T("enable") .. " " .. label, set.enabled)
                if changed_en then set.enabled = val_en; save_current_config_to_file(body_id) end
                imgui.same_line()
                imgui.set_next_item_width(80)
                local changed_pri, val_pri = imgui.input_text(T("priority") .. "##" .. cond_key, tostring(set.priority))
                if changed_pri then
                    local p = tonumber(val_pri)
                    if p then set.priority = p; save_current_config_to_file(body_id) end
                end
            end
            draw_parallel_setting("hp", T("condition_hp"))
            draw_parallel_setting("weapon", T("condition_weapon"))
            draw_parallel_setting("damage", T("condition_damage"))
            draw_parallel_setting("spirit", T("condition_spirit"))
            draw_parallel_setting("dual_blades", T("condition_dual_blades"))
            draw_parallel_setting("switch_axe", T("condition_switch_axe"))
            draw_parallel_setting("insect_glaive", T("condition_insect_glaive"))
            draw_parallel_setting("charge_blade", T("condition_charge_blade"))
            draw_parallel_setting("greatsword_type", T("condition_greatsword_type"))
            draw_parallel_setting("greatsword_level", T("condition_greatsword_level"))
            draw_parallel_setting("bow_level", T("condition_bow_level"))
            draw_parallel_setting("hammer_level", T("condition_hammer_level"))
            imgui.unindent(10)
        end
        imgui.separator()

        -- 辅助函数：显示某个规则类型的配置
        local function show_rule_list(rules, rule_type, get_display_name_func)
            if not rules then return end
            for i, rule in ipairs(rules) do
                imgui.push_id(rule_type .. "_rule_" .. i)
                imgui.spacing()
                local display_name = get_display_name_func(rule)
                imgui.text(display_name)
                imgui.indent(20)
                if not rule.targets then rule.targets = {} end
                draw_targets_ui(rule.targets, rule_type, i)
                if imgui.button("+ " .. T("add_condition") .. "##add_" .. rule_type .. "_" .. i) then
                    table.insert(rule.targets, { group = "", preset = "" })
                    save_current_config_to_file(body_id)
                end
                imgui.unindent(20)
                imgui.separator()
                imgui.pop_id()
            end
        end

        -- HP 规则
        local show_hp = (not current_config.is_parallel and current_config.transform_type == "hp") or
                       (current_config.is_parallel and current_config.parallel_settings.hp and current_config.parallel_settings.hp.enabled)
        if show_hp then
            -- 当前生命值百分比展示 (调试用)
            local cur_hp = TransformManager.get_configured_state(current_config, "hp", character)
            if cur_hp then
                imgui.text(string.format(T("cur_hp_percent"), cur_hp))
                imgui.set_next_item_width(80)
                local c_test, v_test = imgui.input_text("##test_hp_input", test_hp_input)
                if c_test then test_hp_input = v_test end
                imgui.same_line()
                if imgui.button(T("test_hp_btn")) then
                    local num = tonumber(test_hp_input)
                    if num then
                        if num < 0 then num = 0 end
                        if num > 100 then num = 100 end
                        TransformManager.set_character_hp_percent(character, num)
                    end
                end
                imgui.separator()
            end
            if not current_config.transform_rules then current_config.transform_rules = {} end
            if imgui.button(T("add_node")) then
                table.insert(current_config.transform_rules, { threshold = 50, targets = {} })
                save_current_config_to_file(body_id)
            end
            imgui.separator()
            for i, rule in ipairs(current_config.transform_rules) do
                imgui.push_id("hp_rule_" .. i)
                imgui.spacing()

                imgui.set_next_item_width(120)
                local c_t, v_t_str = imgui.input_text(T("hp_percent") .. "##" .. i, tostring(rule.threshold))
                if c_t then
                    local num = tonumber(v_t_str)
                    if num then
                        if num < 1 then num = 1 end
                        if num > 100 then num = 100 end
                        rule.threshold = num
                        save_current_config_to_file(body_id)
                    end
                end
                imgui.same_line()

                if imgui.button(T("delete_node") .. "##" .. i) then
                    table.remove(current_config.transform_rules, i)
                    save_current_config_to_file(body_id)
                end

                -- 缩进显示 Conditions
                imgui.indent(20)
                if not rule.targets then rule.targets = {} end
                draw_targets_ui(rule.targets, "hp", i)
                if imgui.button("+ " .. T("add_condition") .. "##hp_add_" .. i) then
                    table.insert(rule.targets, { group = "", preset = "" })
                    save_current_config_to_file(body_id)
                end
                imgui.unindent(20)
                imgui.separator()
                imgui.pop_id()
            end
        end

        -- 武器规则
        local show_weapon = (not current_config.is_parallel and current_config.transform_type == "weapon") or
                           (current_config.is_parallel and current_config.parallel_settings.weapon and current_config.parallel_settings.weapon.enabled)
        if show_weapon then
            local is_drawn = TransformManager.get_configured_state(current_config, "weapon", character)
            imgui.text((T("condition_weapon") or "Weapon State") .. ": " .. (is_drawn and T("weapon_drawn") or T("weapon_sheathed")))
            imgui.separator()
            if not current_config.weapon_transform_rules then
                current_config.weapon_transform_rules = {
                    { state = "sheathed", targets = {} },
                    { state = "drawn", targets = {} }
                }
            end
            show_rule_list(current_config.weapon_transform_rules, "weapon", function(rule)
                return rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn")
            end)
        end

        -- 受击规则
        local show_damage = (not current_config.is_parallel and current_config.transform_type == "damage") or
                       (current_config.is_parallel and current_config.parallel_settings.damage and current_config.parallel_settings.damage.enabled)
        if show_damage then
            imgui.text(T("condition_damage"))
            imgui.separator()
            if not current_config.damage_transform_rules then
                current_config.damage_transform_rules = { { duration = 5, targets = {} } }
            end
            local dmg_rule = current_config.damage_transform_rules[1]

            -- 剩余时间和测试按钮
            local char_go_ok, char_go = (function() local go = safe_get_game_object(character, "ui_mode_switch") if not go then return false end return true, go end)()
            local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(character)
            if imgui.button((T("damage_test_btn") or "Test Hit") .. "##test_dmg") then
                local cur_hp = TransformManager.get_character_hp(character)
                if cur_hp then
                    TransformManager.set_character_hp(character, cur_hp - 25)
                end
            end

            local remaining = TransformManager.get_configured_state(current_config, "damage", character, char_addr) or 0
            if remaining > 0 then
                imgui.text_colored(string.format(T("damage_countdown") or "Countdown: %.1f s", remaining), 0xFF00A0FF)
            end
            imgui.separator()

            imgui.spacing()

            if dmg_rule.condition_delay == nil then dmg_rule.condition_delay = 0 end
            if dmg_rule.mode == nil then dmg_rule.mode = 1 end
            if dmg_rule.loop_inactive_time == nil then dmg_rule.loop_inactive_time = 0 end
            if dmg_rule.loop_count == nil then dmg_rule.loop_count = 0 end
            if dmg_rule.chain_loop_count == nil then dmg_rule.chain_loop_count = 1 end
            if dmg_rule.chain_nodes == nil then dmg_rule.chain_nodes = { { duration = 1, targets = {} } } end
            if dmg_rule.duration == nil then dmg_rule.duration = 5 end

            imgui.set_next_item_width(120)
            local c_delay, v_delay_str = imgui.input_text(T("condition_delay") .. "##dmg", tostring(dmg_rule.condition_delay))
            if c_delay then local num = tonumber(v_delay_str); if num then dmg_rule.condition_delay = math.max(0, num); save_current_config_to_file(body_id) end end
            imgui.spacing()

            local modes = { T("mode_normal"), T("mode_loop"), T("mode_chain") }
            imgui.set_next_item_width(150)
            local c_m, v_m = imgui.combo(T("action_mode") .. "##dmg", dmg_rule.mode, modes)
            if c_m then dmg_rule.mode = v_m; save_current_config_to_file(body_id) end
            imgui.separator()

            if dmg_rule.mode == 1 or dmg_rule.mode == 2 then
                imgui.set_next_item_width(120)
                local c_dur, v_dur_str = imgui.input_text(T("duration") .. "##dmg", tostring(dmg_rule.duration))
                if c_dur then
                    local num = tonumber(v_dur_str)
                    if num then if num < 0 then num = 0 end; dmg_rule.duration = num; save_current_config_to_file(body_id) end
                end
                imgui.same_line()
                imgui.text_colored(T("duration_desc"), 0xFF808080)

                if dmg_rule.mode == 2 then
                    imgui.set_next_item_width(120)
                    local c_in, v_in_str = imgui.input_text(T("loop_inactive_time") .. "##dmg", tostring(dmg_rule.loop_inactive_time))
                    if c_in then local num = tonumber(v_in_str); if num then dmg_rule.loop_inactive_time = math.max(0, num); save_current_config_to_file(body_id) end end

                    imgui.same_line(); imgui.set_next_item_width(120)
                    local c_lc, v_lc_str = imgui.input_text(T("loop_count") .. "##dmg", tostring(dmg_rule.loop_count))
                    if c_lc then local num = tonumber(v_lc_str); if num then dmg_rule.loop_count = math.max(0, num); save_current_config_to_file(body_id) end end
                    imgui.same_line(); imgui.text_colored(T("loop_count_desc"), 0xFF808080)
                end

                imgui.indent(20)
                if not dmg_rule.targets then dmg_rule.targets = {} end
                draw_targets_ui(dmg_rule.targets, "damage", 1)
                if imgui.button("+ " .. T("add_condition") .. "##dmg_add") then
                    table.insert(dmg_rule.targets, { group = "", preset = "" })
                    save_current_config_to_file(body_id)
                end
                imgui.unindent(20)

            elseif dmg_rule.mode == 3 then
                imgui.set_next_item_width(120)
                local c_clc, v_clc_str = imgui.input_text(T("chain_loop_count") .. "##dmg", tostring(dmg_rule.chain_loop_count))
                if c_clc then local num = tonumber(v_clc_str); if num then dmg_rule.chain_loop_count = math.max(0, num); save_current_config_to_file(body_id) end end
                imgui.same_line(); imgui.text_colored(T("loop_count_desc"), 0xFF808080)

                for n_idx, node in ipairs(dmg_rule.chain_nodes) do
                    imgui.push_id("dmg_chain_node_" .. n_idx)
                    imgui.spacing()
                    imgui.text(T("chain_node") .. " " .. n_idx)
                    imgui.same_line()
                    if imgui.button(T("delete_chain_node")) then
                        table.remove(dmg_rule.chain_nodes, n_idx)
                        save_current_config_to_file(body_id)
                    end

                    imgui.set_next_item_width(120)
                    local c_ndur, v_ndur_str = imgui.input_text(T("duration") .. "##ndur", tostring(node.duration))
                    if c_ndur then local num = tonumber(v_ndur_str); if num then node.duration = math.max(0, num); save_current_config_to_file(body_id) end end

                    imgui.indent(20)
                    if not node.targets then node.targets = {} end
                    draw_targets_ui(node.targets, "damage_chain_" .. n_idx, 1)
                    if imgui.button("+ " .. T("add_condition") .. "##dmg_chain_add_" .. n_idx) then
                        table.insert(node.targets, { group = "", preset = "" })
                        save_current_config_to_file(body_id)
                    end
                    imgui.unindent(20)
                    imgui.separator()
                    imgui.pop_id()
                end

                if imgui.button("+ " .. T("add_chain_node") .. "##dmg_chain_add") then
                    table.insert(dmg_rule.chain_nodes, { duration = 1, targets = {} })
                    save_current_config_to_file(body_id)
                end
            end
        end

        -- 气刃规则
        local show_spirit = (not current_config.is_parallel and current_config.transform_type == "spirit") or
                           (current_config.is_parallel and current_config.parallel_settings.spirit and current_config.parallel_settings.spirit.enabled)
        if show_spirit then
            local current_level = TransformManager.get_configured_state(current_config, "spirit", character)
            local level_text = current_level and tostring(current_level) or "?"
            imgui.text(T("spirit_level") .. ": " .. level_text)
            imgui.separator()
            if not current_config.spirit_transform_rules then
                current_config.spirit_transform_rules = {
                    { level = 1, targets = {} },
                    { level = 2, targets = {} },
                    { level = 3, targets = {} },
                    { level = 4, targets = {} }
                }
            end
            show_rule_list(current_config.spirit_transform_rules, "spirit", function(rule)
                if rule.level == 1 then return T("spirit_level_1")
                elseif rule.level == 2 then return T("spirit_level_2")
                elseif rule.level == 3 then return T("spirit_level_3")
                elseif rule.level == 4 then return T("spirit_level_4")
                else return T("spirit_level") .. " " .. tostring(rule.level) end
            end)
        end

        -- 双刀鬼人规则
        local show_dual = (not current_config.is_parallel and current_config.transform_type == "dual_blades") or
                         (current_config.is_parallel and current_config.parallel_settings.dual_blades and current_config.parallel_settings.dual_blades.enabled)
        if show_dual then
            local cur_state = TransformManager.get_configured_state(current_config, "dual_blades", character)
            local state_text = ""
            if cur_state == "normal" then state_text = T("dual_normal")
            elseif cur_state == "kijin" then state_text = T("dual_kijin")
            elseif cur_state == "enhancement" then state_text = T("dual_enhancement")
            else state_text = "?" end
            imgui.text(T("dual_current") .. ": " .. state_text)
            imgui.separator()
            if not current_config.dual_blades_transform_rules then
                current_config.dual_blades_transform_rules = {
                    { state = "normal", targets = {} },
                    { state = "kijin", targets = {} },
                    { state = "enhancement", targets = {} }
                }
            end
            show_rule_list(current_config.dual_blades_transform_rules, "dual", function(rule)
                if rule.state == "normal" then return T("dual_normal")
                elseif rule.state == "kijin" then return T("dual_kijin")
                elseif rule.state == "enhancement" then return T("dual_enhancement")
                else return rule.state end
            end)
        end

        -- 斩斧规则
        local show_switch_axe = (not current_config.is_parallel and current_config.transform_type == "switch_axe") or
                               (current_config.is_parallel and current_config.parallel_settings.switch_axe and current_config.parallel_settings.switch_axe.enabled)
        if show_switch_axe then
            local cur_state = TransformManager.get_configured_state(current_config, "switch_axe", character)
            local state_text = ""
            if cur_state == "sword_normal" then state_text = T("switch_axe_sword_normal")
            elseif cur_state == "sword_awakened" then state_text = T("switch_axe_sword_awakened")
            elseif cur_state == "axe_normal" then state_text = T("switch_axe_axe_normal")
            elseif cur_state == "axe_enhanced" then state_text = T("switch_axe_axe_enhanced")
            else state_text = "?" end
            imgui.text(T("switch_axe_current") .. ": " .. state_text)
            imgui.separator()
            if not current_config.switch_axe_transform_rules then
                current_config.switch_axe_transform_rules = {
                    { state = "sword_normal", targets = {} },
                    { state = "sword_awakened", targets = {} },
                    { state = "axe_normal", targets = {} },
                    { state = "axe_enhanced", targets = {} }
                }
            end
            show_rule_list(current_config.switch_axe_transform_rules, "switch_axe", function(rule)
                if rule.state == "sword_normal" then return T("switch_axe_sword_normal")
                elseif rule.state == "sword_awakened" then return T("switch_axe_sword_awakened")
                elseif rule.state == "axe_normal" then return T("switch_axe_axe_normal")
                elseif rule.state == "axe_enhanced" then return T("switch_axe_axe_enhanced")
                else return rule.state end
            end)
        end

        -- 虫棍灯色规则
        local show_insect_glaive = (not current_config.is_parallel and current_config.transform_type == "insect_glaive") or
                                  (current_config.is_parallel and current_config.parallel_settings.insect_glaive and current_config.parallel_settings.insect_glaive.enabled)
        if show_insect_glaive then
            local cur_state = TransformManager.get_configured_state(current_config, "insect_glaive", character)
            local state_text = ""
            if cur_state == "none" then state_text = T("insect_glaive_none")
            elseif cur_state == "white" then state_text = T("insect_glaive_white")
            elseif cur_state == "orange" then state_text = T("insect_glaive_orange")
            elseif cur_state == "red" then state_text = T("insect_glaive_red")
            elseif cur_state == "triple" then state_text = T("insect_glaive_triple")
            else state_text = "?" end
            imgui.text(T("insect_glaive_current") .. ": " .. state_text)
            imgui.separator()
            if not current_config.insect_glaive_transform_rules then
                current_config.insect_glaive_transform_rules = {
                    { state = "none", targets = {} },
                    { state = "white", targets = {} },
                    { state = "orange", targets = {} },
                    { state = "red", targets = {} },
                    { state = "triple", targets = {} }
                }
            end
            show_rule_list(current_config.insect_glaive_transform_rules, "insect_glaive", function(rule)
                if rule.state == "none" then return T("insect_glaive_none")
                elseif rule.state == "white" then return T("insect_glaive_white")
                elseif rule.state == "orange" then return T("insect_glaive_orange")
                elseif rule.state == "red" then return T("insect_glaive_red")
                elseif rule.state == "triple" then return T("insect_glaive_triple")
                else return rule.state end
            end)
        end

        -- 盾斧规则
        local show_charge_blade = (not current_config.is_parallel and current_config.transform_type == "charge_blade") or
                                 (current_config.is_parallel and current_config.parallel_settings.charge_blade and current_config.parallel_settings.charge_blade.enabled)
        if show_charge_blade then
            local cur_state = TransformManager.get_configured_state(current_config, "charge_blade", character)
            local state_text = ""
            if cur_state == "sword" then state_text = T("charge_blade_sword")
            elseif cur_state == "axe" then state_text = T("charge_blade_axe")
            elseif cur_state == "sword_shield" then state_text = T("charge_blade_sword_shield")
            elseif cur_state == "sword_sword" then state_text = T("charge_blade_sword_sword")
            elseif cur_state == "sword_shield_sword" then state_text = T("charge_blade_sword_shield_sword")
            elseif cur_state == "axe_axe" then state_text = T("charge_blade_axe_axe")
            elseif cur_state == "triple" then state_text = T("charge_blade_triple")
            else state_text = "?" end
            imgui.text(T("charge_blade_current") .. ": " .. state_text)
            imgui.separator()
            if not current_config.charge_blade_transform_rules then
                current_config.charge_blade_transform_rules = {
                    { state = "sword", targets = {} },
                    { state = "axe", targets = {} },
                    { state = "sword_shield", targets = {} },
                    { state = "sword_sword", targets = {} },
                    { state = "sword_shield_sword", targets = {} },
                    { state = "axe_axe", targets = {} },
                    { state = "triple", targets = {} }
                }
            end
            show_rule_list(current_config.charge_blade_transform_rules, "charge_blade", function(rule)
                if rule.state == "sword" then return T("charge_blade_sword")
                elseif rule.state == "axe" then return T("charge_blade_axe")
                elseif rule.state == "sword_shield" then return T("charge_blade_sword_shield")
                elseif rule.state == "sword_sword" then return T("charge_blade_sword_sword")
                elseif rule.state == "sword_shield_sword" then return T("charge_blade_sword_shield_sword")
                elseif rule.state == "axe_axe" then return T("charge_blade_axe_axe")
                elseif rule.state == "triple" then return T("charge_blade_triple")
                else return rule.state end
            end)
        end

        -- 大剑蓄力类型规则
        local show_greatsword_type = (not current_config.is_parallel and current_config.transform_type == "greatsword_type") or
                                    (current_config.is_parallel and current_config.parallel_settings.greatsword_type and current_config.parallel_settings.greatsword_type.enabled)
        if show_greatsword_type then
            local cur_type = TransformManager.get_configured_state(current_config, "greatsword_type", character)
            local type_text = ""
            if cur_type == "0" then type_text = T("greatsword_type_0")
            elseif cur_type == "1" then type_text = T("greatsword_type_1")
            elseif cur_type == "2" then type_text = T("greatsword_type_2")
            elseif cur_type == "3" then type_text = T("greatsword_type_3")
            elseif cur_type == "5" then type_text = T("greatsword_type_5")
            else type_text = T("greatsword_type_other") end
            imgui.text(T("greatsword_type_current") .. ": " .. type_text)
            imgui.separator()
            if not current_config.greatsword_type_transform_rules then
                current_config.greatsword_type_transform_rules = {
                    { state = "0", targets = {} },
                    { state = "1", targets = {} },
                    { state = "2", targets = {} },
                    { state = "3", targets = {} },
                    { state = "5", targets = {} },
                    { state = "other", targets = {} }
                }
            end
            show_rule_list(current_config.greatsword_type_transform_rules, "greatsword_type", function(rule)
                if rule.state == "0" then return T("greatsword_type_0")
                elseif rule.state == "1" then return T("greatsword_type_1")
                elseif rule.state == "2" then return T("greatsword_type_2")
                elseif rule.state == "3" then return T("greatsword_type_3")
                elseif rule.state == "5" then return T("greatsword_type_5")
                else return T("greatsword_type_other") end
            end)
        end

        -- 大剑蓄力等级规则
        local show_greatsword_level = (not current_config.is_parallel and current_config.transform_type == "greatsword_level") or
                                     (current_config.is_parallel and current_config.parallel_settings.greatsword_level and current_config.parallel_settings.greatsword_level.enabled)
        if show_greatsword_level then
            local cur_level = TransformManager.get_configured_state(current_config, "greatsword_level", character)
            imgui.text(T("greatsword_level_current") .. ": " .. tostring(cur_level))
            imgui.separator()
            if not current_config.greatsword_level_transform_rules then
                current_config.greatsword_level_transform_rules = {
                    { level = 0, targets = {} },
                    { level = 1, targets = {} },
                    { level = 2, targets = {} },
                    { level = 3, targets = {} }
                }
            end
            show_rule_list(current_config.greatsword_level_transform_rules, "greatsword_level", function(rule)
                return T("greatsword_level_" .. tostring(rule.level))
            end)
        end

        -- 弓箭蓄力等级规则
        local show_bow_level = (not current_config.is_parallel and current_config.transform_type == "bow_level") or
                              (current_config.is_parallel and current_config.parallel_settings.bow_level and current_config.parallel_settings.bow_level.enabled)
        if show_bow_level then
            local cur_level = TransformManager.get_configured_state(current_config, "bow_level", character)
            local level_text = ""
            if cur_level == 1 then level_text = T("bow_level_1")
            elseif cur_level == 2 then level_text = T("bow_level_2")
            elseif cur_level == 3 then level_text = T("bow_level_3")
            elseif cur_level == 4 then level_text = T("bow_level_4")
            else level_text = tostring(cur_level) end
            imgui.text(T("bow_level_current") .. ": " .. level_text)
            imgui.separator()
            if not current_config.bow_level_transform_rules then
                current_config.bow_level_transform_rules = {
                    { level = 1, targets = {} },
                    { level = 2, targets = {} },
                    { level = 3, targets = {} },
                    { level = 4, targets = {} }
                }
            end
            show_rule_list(current_config.bow_level_transform_rules, "bow_level", function(rule)
                if rule.level == 1 then return T("bow_level_1")
                elseif rule.level == 2 then return T("bow_level_2")
                elseif rule.level == 3 then return T("bow_level_3")
                elseif rule.level == 4 then return T("bow_level_4")
                else return T("bow_level") .. " " .. tostring(rule.level) end
            end)
        end

        -- 大锤蓄力等级规则
        local show_hammer_level = (not current_config.is_parallel and current_config.transform_type == "hammer_level") or
                                 (current_config.is_parallel and current_config.parallel_settings.hammer_level and current_config.parallel_settings.hammer_level.enabled)
        if show_hammer_level then
            local cur_level = TransformManager.get_configured_state(current_config, "hammer_level", character)
            local level_text = ""
            if cur_level == 0 then level_text = T("hammer_level_0")
            elseif cur_level == 1 then level_text = T("hammer_level_1")
            elseif cur_level == 2 then level_text = T("hammer_level_2")
            elseif cur_level == 3 then level_text = T("hammer_level_3")
            else level_text = tostring(cur_level) end
            imgui.text(T("hammer_level_current") .. ": " .. level_text)
            imgui.separator()
            if not current_config.hammer_level_transform_rules then
                current_config.hammer_level_transform_rules = {
                    { level = 0, targets = {} },
                    { level = 1, targets = {} },
                    { level = 2, targets = {} },
                    { level = 3, targets = {} }
                }
            end
            show_rule_list(current_config.hammer_level_transform_rules, "hammer_level", function(rule)
                if rule.level == 0 then return T("hammer_level_0")
                elseif rule.level == 1 then return T("hammer_level_1")
                elseif rule.level == 2 then return T("hammer_level_2")
                elseif rule.level == 3 then return T("hammer_level_3")
                else return T("hammer_level") .. " " .. tostring(rule.level) end
            end)
        end
    end
end

return Conditions
