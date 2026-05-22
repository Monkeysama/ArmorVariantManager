-- ==========================================================
-- 复杂状态 UI 独立渲染模块 (Extension UI Renderer)
-- ==========================================================
local ExtensionUI = {}

function ExtensionUI.get_default_rule()
    return {
        threshold = 50, trigger_on_damage = false, condition_delay = 0,
        mode = 1, duration = 0, loop_inactive_time = 0, loop_count = 0,
        chain_loop_count = 1, chain_nodes = { { duration = 1, targets = {} } },
        targets = {}, keep_until_state_ends = false
    }
end

function ExtensionUI.draw_targets_ui(targets, id_prefix, all_groups, all_groups_display, current_config, T)
    local changed = false
    imgui.indent(20)
    for j, target in ipairs(targets) do
        imgui.push_id(id_prefix .. "_t_" .. j)
        local g_idx = 1
        for idx, g in ipairs(all_groups) do if g == (target.group or "") then g_idx = idx break end end
        
        imgui.set_next_item_width(120)
        local c_g, v_g = imgui.combo("##g", g_idx, all_groups_display)
        if c_g then target.group = all_groups[v_g]; target.preset = ""; changed = true end

        imgui.same_line()
        local target_presets = {}
        if target.group == "" or target.group == nil then
            if current_config.presets then for pname, _ in pairs(current_config.presets) do table.insert(target_presets, pname) end end
        else
            if current_config.groups and current_config.groups[target.group] and current_config.groups[target.group].presets then
                for pname, _ in pairs(current_config.groups[target.group].presets) do table.insert(target_presets, pname) end
            end
        end
        
        -- 【核心修复】：为防止中文字符排序时导致 Lua 崩溃，包裹在 pcall 中安全排序
        pcall(function() table.sort(target_presets) end)

        local p_idx = 1
        for idx, p in ipairs(target_presets) do if p == target.preset then p_idx = idx break end end
        if #target_presets == 0 then table.insert(target_presets, "None") end
        
        imgui.set_next_item_width(150)
        local c_p, v_p = imgui.combo("##p", p_idx, target_presets)
        if c_p and target_presets[v_p] ~= "None" then target.preset = target_presets[v_p]; changed = true end

        imgui.same_line()
        if imgui.button(T("delete_condition") .. "##d") then table.remove(targets, j); changed = true end
        imgui.pop_id()
    end

    if imgui.button("+ " .. T("add_condition") .. "##" .. id_prefix) then
        table.insert(targets, { group = "", preset = "" }); changed = true
    end
    imgui.unindent(20)
    return changed
end

function ExtensionUI.draw_rule_ui(rule, i, all_groups, all_groups_display, current_config, T)
    local changed = false

    if rule.condition_delay == nil then rule.condition_delay = 0 end
    if rule.mode == nil then rule.mode = 1 end
    if rule.loop_inactive_time == nil then rule.loop_inactive_time = 0 end
    if rule.loop_count == nil then rule.loop_count = 0 end
    if rule.chain_loop_count == nil then rule.chain_loop_count = 1 end
    if rule.chain_nodes == nil then rule.chain_nodes = { { duration = 1, targets = {} } } end
    if rule.duration == nil then rule.duration = 0 end

    local c_dmg, v_dmg = imgui.checkbox(T("trigger_on_damage") .. "##" .. i, rule.trigger_on_damage)
    if c_dmg then rule.trigger_on_damage = v_dmg; changed = true end

    if not rule.trigger_on_damage then
        imgui.same_line(); imgui.set_next_item_width(120)
        local c_t, v_t_str = imgui.input_text(T("hp_percent") .. "##" .. i, tostring(rule.threshold))
        if c_t then local num = tonumber(v_t_str); if num then rule.threshold = math.max(1, math.min(100, num)); changed = true end end
    end
    imgui.spacing()

    imgui.set_next_item_width(120)
    local c_delay, v_delay_str = imgui.input_text(T("condition_delay") .. "##" .. i, tostring(rule.condition_delay))
    if c_delay then local num = tonumber(v_delay_str); if num then rule.condition_delay = math.max(0, num); changed = true end end
    imgui.spacing()

    local modes = { T("mode_normal"), T("mode_loop"), T("mode_chain") }
    imgui.set_next_item_width(150)
    local c_m, v_m = imgui.combo(T("action_mode") .. "##" .. i, rule.mode, modes)
    if c_m then rule.mode = v_m; changed = true end
    imgui.separator()

    if rule.mode == 1 or rule.mode == 2 then
        imgui.set_next_item_width(120)
        local c_dur, v_dur_str = imgui.input_text(T("duration") .. "##" .. i, tostring(rule.duration))
        if c_dur then local num = tonumber(v_dur_str); if num then rule.duration = math.max(0, num); changed = true end end

        if rule.mode == 1 then
            if not rule.trigger_on_damage then
                imgui.same_line()
                local c_keep, v_keep = imgui.checkbox(T("keep_state") .. "##" .. i, rule.keep_until_state_ends)
                if c_keep then rule.keep_until_state_ends = v_keep; changed = true end
            end
        elseif rule.mode == 2 then
            imgui.same_line(); imgui.set_next_item_width(120)
            local c_in, v_in_str = imgui.input_text(T("loop_inactive") .. "##" .. i, tostring(rule.loop_inactive_time))
            if c_in then local num = tonumber(v_in_str); if num then rule.loop_inactive_time = math.max(0, num); changed = true end end

            imgui.set_next_item_width(120)
            local c_lc, v_lc_str = imgui.input_text(T("loop_count") .. "##" .. i, tostring(rule.loop_count))
            if c_lc then local num = tonumber(v_lc_str); if num then rule.loop_count = math.max(0, num); changed = true end end
        end
        if ExtensionUI.draw_targets_ui(rule.targets, "tgt_" .. i, all_groups, all_groups_display, current_config, T) then changed = true end

    elseif rule.mode == 3 then
        imgui.set_next_item_width(120)
        local c_clc, v_clc_str = imgui.input_text(T("chain_loop_count") .. "##" .. i, tostring(rule.chain_loop_count))
        if c_clc then local num = tonumber(v_clc_str); if num then rule.chain_loop_count = math.max(0, num); changed = true end end

        imgui.separator()
        for n_idx, node in ipairs(rule.chain_nodes) do
            imgui.push_id("node_" .. i .. "_" .. n_idx)
            imgui.text_colored(T("chain_node") .. " " .. n_idx, 0xFF00FF00)

            imgui.set_next_item_width(120)
            local c_ndur, v_ndur_str = imgui.input_text(T("duration") .. "##n", tostring(node.duration))
            if c_ndur then local num = tonumber(v_ndur_str); if num then node.duration = math.max(0, num); changed = true end end
            imgui.same_line()
            if imgui.button(T("delete_chain_node")) then table.remove(rule.chain_nodes, n_idx); changed = true end

            if ExtensionUI.draw_targets_ui(node.targets, "ntgt_" .. i .. "_" .. n_idx, all_groups, all_groups_display, current_config, T) then changed = true end
            imgui.separator()
            imgui.pop_id()
        end
        if imgui.button("+ " .. T("add_chain_node") .. "##" .. i) then table.insert(rule.chain_nodes, { duration = 1, targets = {} }); changed = true end
    end
    return changed
end

return ExtensionUI