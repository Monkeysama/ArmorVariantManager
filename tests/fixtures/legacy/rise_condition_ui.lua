-- rise 093c61c：原生条件面板旧行为。
return function(env)
    local _ENV = env
    return function()
        local enable_transform = current_config.enable_transform
        local changed_enable, new_enable = imgui.checkbox(T("enable_transform"), enable_transform)
        if changed_enable then
            current_config.enable_transform = new_enable
            if new_enable then
                local char_addr = tostring(primary)
                TransformManager.clear_cache(char_addr)
                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                )
                active_overrides[body_id] = new_overrides
                bump_overrides_version(body_id)
                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                if current_config.groups then
                    for g_name, g_data in pairs(current_config.groups) do
                        if g_data.is_global then
                            if activated_targets and activated_targets[g_name] then
                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                            end
                        end
                    end
                end
                if is_weapon_mode then
                    local weapon_parts = get_cached_weapon_parts(primary)
                    if weapon_parts then
                        apply_preset_to_weapon(weapon_parts, new_overrides, true, body_id)
                    end
                else
                    apply_preset_to_character(primary, new_overrides, true)
                end
            else
                apply_all_defaults(body_id)
                if active_overrides[body_id] then
                    if is_weapon_mode then
                        local weapon_parts = get_cached_weapon_parts(primary)
                        if weapon_parts then
                            apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                        end
                    else
                        apply_preset_to_character(primary, active_overrides[body_id], true)
                    end
                end
            end
            save_current_config_to_file(body_id)
        end
        imgui.separator()
        if current_config.enable_transform then
            local current_state_str = TransformManager.get_current_state_display(current_config, primary)
            if current_state_str ~= "" then
                imgui.text(T("current_state") .. ": " .. current_state_str)
                imgui.separator()
            end
            local mode_text = current_config.is_parallel and T("current_mode_parallel") or T("current_mode_selection")
            imgui.text(mode_text)
            local parallel_btn_text = current_config.is_parallel and T("switch_to_selection") or T("switch_to_parallel")
            if imgui.button(parallel_btn_text) then
                current_config.is_parallel = not current_config.is_parallel
                save_current_config_to_file(body_id)
            end
            -- Both modes edit the same rules without changing transform_type.
            local function draw_condition_rules(condition_type)
                -- 武器条件
                if condition_type == "weapon" then
                    for i, rule in ipairs(current_config.weapon_transform_rules) do
                        imgui.push_id("weapon_rule_" .. i)
                        imgui.text(rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn"))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "weapon", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##weapon_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 红蓝书
                elseif condition_type == "scroll" then
                    for i, rule in ipairs(current_config.scroll_transform_rules) do
                        imgui.push_id("scroll_rule_" .. i)
                        imgui.text(rule.state == "red" and T("scroll_red") or T("scroll_blue"))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "scroll", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##scroll_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 怪物血量
                elseif condition_type == "monster_hp" then
                    -- Query HP explicitly; the aggregate parallel config has no raw state.
                    local curHP = TransformManager.get_current_raw_state({
                        transform_type = "monster_hp",
                        monster_hp_transform_rules = current_config.monster_hp_transform_rules
                    }, primary)
                    if curHP then
                        imgui.text(string.format(T("monster_current_hp"), curHP))
                    else
                        imgui.text_colored(T("no_monster_target"), 0xFF808080)
                    end
                    imgui.separator()
                    if imgui.button(T("add_hp_node")) then
                        table.insert(current_config.monster_hp_transform_rules, { threshold = 50, targets = {} })
                        save_current_config_to_file(body_id)
                    end
                    for i, rule in ipairs(current_config.monster_hp_transform_rules) do
                        imgui.push_id("monster_hp_rule_" .. i)
                        imgui.set_next_item_width(120)
                        local c_t, v_t_str = imgui.input_text(T("monster_hp_threshold") .. "##" .. i, tostring(rule.threshold))
                        if c_t then
                            local num = tonumber(v_t_str)
                            if num then
                                if num < 0 then num = 0 end
                                if num > 100 then num = 100 end
                                rule.threshold = num
                                save_current_config_to_file(body_id)
                            end
                        end
                        imgui.same_line()
                        if imgui.button(T("delete_node") .. "##" .. i) then
                            table.remove(current_config.monster_hp_transform_rules, i)
                            save_current_config_to_file(body_id)
                        end
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "monster_hp", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##monster_hp_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 太刀气刃等级
                elseif condition_type == "longsword" then
                    for i, rule in ipairs(current_config.longsword_transform_rules) do
                        imgui.push_id("longsword_rule_" .. i)
                        local level_names = {
                            [0] = T("spirit_level_0"),
                            [1] = T("spirit_level_1"),
                            [2] = T("spirit_level_2"),
                            [3] = T("spirit_level_3")
                        }
                        imgui.text(level_names[rule.level] or string.format("%s %d", T("spirit_level"), rule.level))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "longsword", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##longsword_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 双刀鬼人状态
                elseif condition_type == "dual_blades" then
                    for i, rule in ipairs(current_config.dual_blades_transform_rules) do
                        imgui.push_id("dual_blades_rule_" .. i)
                        local state_names = {
                            [0] = T("dual_normal"),
                            [1] = T("dual_kijin"),
                            [2] = T("dual_enhancement")
                        }
                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "dual_blades", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##dual_blades_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 斩斧模式
                elseif condition_type == "switch_axe" then
                    for i, rule in ipairs(current_config.switch_axe_transform_rules) do
                        imgui.push_id("switch_axe_rule_" .. i)
                        local state_names = {
                            [0] = T("switch_axe_axe"),
                            [1] = T("switch_axe_sword"),
                            [2] = T("switch_axe_awakened")
                        }
                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "switch_axe", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##switch_axe_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 盾斧强化状态
                elseif condition_type == "charge_axe" then
                    for i, rule in ipairs(current_config.charge_axe_transform_rules) do
                        imgui.push_id("charge_axe_rule_" .. i)
                        local state_names = {
                            [0] = T("charge_axe_axe"),
                            [1] = T("charge_axe_sword"),
                            [2] = T("charge_axe_axe_enhanced"),
                            [3] = T("charge_axe_shield"),
                            [4] = T("charge_axe_sword_enhanced"),
                            [5] = T("charge_axe_triple")
                        }
                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "charge_axe", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##charge_axe_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 大剑蓄力等级
                elseif condition_type == "greatsword_level" then
                    for i, rule in ipairs(current_config.greatsword_level_transform_rules) do
                        imgui.push_id("greatsword_level_rule_" .. i)
                        local level_names = {
                            [0] = T("greatsword_level_0"),
                            [1] = T("greatsword_level_1"),
                            [2] = T("greatsword_level_2"),
                            [3] = T("greatsword_level_3")
                        }
                        imgui.text(level_names[rule.level] or string.format("%s %d", T("greatsword_level"), rule.level))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "greatsword_level", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##greatsword_level_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 大锤蓄力等级
                elseif condition_type == "hammer" then
                    for i, rule in ipairs(current_config.hammer_transform_rules) do
                        imgui.push_id("hammer_rule_" .. i)
                        local level_names = {
                            [0] = T("hammer_level_0"),
                            [1] = T("hammer_level_1"),
                            [2] = T("hammer_level_2")
                        }
                        imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "hammer", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##hammer_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end

                -- 弓箭蓄力等级
                elseif condition_type == "bow" then
                    for i, rule in ipairs(current_config.bow_transform_rules) do
                        imgui.push_id("bow_rule_" .. i)
                        local level_names = {
                            [0] = T("bow_level_0"),
                            [1] = T("bow_level_1"),
                            [2] = T("bow_level_2"),
                            [3] = T("bow_level_3")
                        }
                        imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                        imgui.indent(20)
                        draw_targets_ui(rule.targets, "bow", i, body_id, primary)
                        if imgui.button("+ " .. T("add_condition") .. "##bow_add_" .. i) then
                            local default_preset = current_config.default_preset or ""
                            if default_preset == "" and next(current_config.presets) then
                                for name, _ in pairs(current_config.presets) do
                                    default_preset = name
                                    break
                                end
                            end
                            table.insert(rule.targets, { group = "", preset = default_preset })
                            save_current_config_to_file(body_id)
                            if current_config.enable_transform then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local wp = get_cached_weapon_parts(primary)
                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            end
                        end
                        imgui.unindent(20)
                        imgui.separator()
                        imgui.pop_id()
                    end
                end
            end
            if not current_config.is_parallel then
                local c_type_idx = 1
                if current_config.transform_type == "weapon" then c_type_idx = 1
                elseif current_config.transform_type == "scroll" then c_type_idx = 2
                elseif current_config.transform_type == "monster_hp" then c_type_idx = 3
                elseif current_config.transform_type == "longsword" then c_type_idx = 4
                elseif current_config.transform_type == "dual_blades" then c_type_idx = 5
                elseif current_config.transform_type == "switch_axe" then c_type_idx = 6
                elseif current_config.transform_type == "charge_axe" then c_type_idx = 7
                elseif current_config.transform_type == "greatsword_level" then c_type_idx = 8
                elseif current_config.transform_type == "hammer" then c_type_idx = 9
                elseif current_config.transform_type == "bow" then c_type_idx = 10
                end
                local c_type_list = {
                    T("condition_weapon"), T("condition_scroll"), T("condition_monster_hp"),
                    T("condition_longsword"), T("condition_dual_blades"), T("condition_switch_axe"),
                    T("condition_charge_axe"), T("condition_greatsword_level"),
                    T("condition_hammer"), T("condition_bow")
                }
                local c_changed, c_val = imgui.combo(T("transform_condition_type"), c_type_idx, c_type_list)
                if c_changed then
                    if c_val == 1 then current_config.transform_type = "weapon"
                    elseif c_val == 2 then current_config.transform_type = "scroll"
                    elseif c_val == 3 then current_config.transform_type = "monster_hp"
                    elseif c_val == 4 then current_config.transform_type = "longsword"
                    elseif c_val == 5 then current_config.transform_type = "dual_blades"
                    elseif c_val == 6 then current_config.transform_type = "switch_axe"
                    elseif c_val == 7 then current_config.transform_type = "charge_axe"
                    elseif c_val == 8 then current_config.transform_type = "greatsword_level"
                    elseif c_val == 9 then current_config.transform_type = "hammer"
                    else current_config.transform_type = "bow" end
                    save_current_config_to_file(body_id)
                end

                draw_condition_rules(current_config.transform_type)
            else
                -- 并行模式
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
                draw_parallel_setting("weapon", T("condition_weapon"))
                draw_parallel_setting("scroll", T("condition_scroll"))
                draw_parallel_setting("monster_hp", T("condition_monster_hp"))
                draw_parallel_setting("longsword", T("condition_longsword"))
                draw_parallel_setting("dual_blades", T("condition_dual_blades"))
                draw_parallel_setting("switch_axe", T("condition_switch_axe"))
                draw_parallel_setting("charge_axe", T("condition_charge_axe"))
                draw_parallel_setting("greatsword_level", T("condition_greatsword_level"))
                draw_parallel_setting("hammer", T("condition_hammer"))
                draw_parallel_setting("bow", T("condition_bow"))
                imgui.unindent(10)
                if imgui.tree_node(T("parallel_rules_details")) then
                    for _, kind in ipairs({ "weapon", "scroll", "monster_hp", "longsword",
                        "dual_blades", "switch_axe", "charge_axe", "greatsword_level", "hammer", "bow" }) do
                        if imgui.tree_node(T("condition_" .. kind) .. "##parallel_rules_" .. kind) then
                            draw_condition_rules(kind)
                            imgui.tree_pop()
                        end
                    end
                    imgui.tree_pop()
                end
            end
        end
    end
end
