-- 冻结自荒野 fcb44e6 / 崛起 093c61c，比较手动预设切换及其选择状态。
local legacy = {}
function legacy.Wilds(env)
    local source = [====[
local function apply_preset(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_body_id = get_body_id()
    if current_body_id then
        -- 全局分组会重建材质状态，先保留高度，未勾选的预设不能借重建清空其他分组的修正。
        local previous_height = active_overrides[current_body_id] and active_overrides[current_body_id].ground_clipping_fix
        -- 记录当前分组的选中预设（用于全局分组全量重算时恢复）
        if not active_group_presets[current_body_id] then active_group_presets[current_body_id] = {} end
        active_group_presets[current_body_id][current_group_name] = preset_name
        ground_clipping_presets.reset(current_body_id, current_group_name)

        -- 判断当前是否为全局分组
        local is_current_global = (current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name]
            and current_config.groups[current_group_name].is_global)

        if is_current_global then
            -- 全局分组预设切换：全量重算（不自动更新 default_preset，只有用户点"设为默认"才更新）
            active_overrides[current_body_id] = {}
            local saved = active_group_presets[current_body_id] or {}
            -- 1. 主列表当前预设
            local main_preset_name = saved[""]
            if main_preset_name and main_preset_name ~= "" and current_config.presets and current_config.presets[main_preset_name] then
                merge_preset_into_overrides(current_body_id, current_config.presets[main_preset_name])
            elseif current_config.default_preset and current_config.default_preset ~= "" and current_config.presets then
                local def = current_config.presets[current_config.default_preset]
                if def then merge_preset_into_overrides(current_body_id, def) end
            end
            -- 2. 普通分组的当前预设
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if not g_data.is_global then
                        local gp_name = saved[g_name]
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_preset_into_overrides(current_body_id, g_data.presets[gp_name])
                        elseif g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                            local g_def = g_data.presets[g_data.default_preset]
                            if g_def then merge_preset_into_overrides(current_body_id, g_def) end
                        end
                    end
                end
            end
            -- 3. 所有全局分组（只锁隐藏项），当前切换的全局组用新 preset_name
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global then
                        local gp_name = (g_name == current_group_name) and preset_name or saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_body_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        else
            -- 普通分组/主列表：增量合并当前预设数据，再叠加全局锁
            merge_preset_into_overrides(current_body_id, preset_data)
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global and g_data.presets then
                        -- 优先用用户当前选中的预设（active_group_presets），fallback 到默认预设
                        local active_saved = active_group_presets[current_body_id] or {}
                        local gp_name = active_saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_body_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        end
        -- 仅勾选的预设覆盖高度；未勾选只切换材质，勾选的 0 cm 可主动归零。
        if not is_weapon_id(current_body_id) then
            active_overrides[current_body_id].ground_clipping_fix = GroundClippingFix.participating_settings(preset_data, current_config)
                or previous_height or GroundClippingFix.default_settings(current_config)
        end
        temp_applied_presets[current_body_id] = preset_name
    end
    local all_chars = get_all_characters()
    -- 本地玩家是预设切换的直接目标；在装备箱/菜单等场景中，异步扫描缓存可能暂时漏掉它，
    -- 因此强制把本地角色补入本帧列表，保证自定义 Body ID 也能立即应用预设。
    local local_char_for_preset = get_local_player_character()
    if local_char_for_preset and sdk.is_managed_object(local_char_for_preset) then
        local local_seen = false
        for _, listed_char in ipairs(all_chars) do
            if listed_char == local_char_for_preset then
                local_seen = true
                break
            end
        end
        if not local_seen then
            table.insert(all_chars, local_char_for_preset)
        end
    end
    for _, char in ipairs(all_chars) do
        if is_weapon_id(current_body_id) then
            local char_weapon_id, w_objs = get_character_weapon_id(char)
            if char_weapon_id and char_weapon_id == current_body_id then
                local config = load_config_data(char_weapon_id)
                local new_overrides = resolve_character_overrides(char_weapon_id, config, char, "weapon")
                apply_preset_to_weapon(char, w_objs, new_overrides, true, true)
            end
        else
            local char_body_id = get_character_body_id(char)
            if char_body_id and char_body_id == current_body_id then
                local config = load_config_data(char_body_id)
                local new_overrides = resolve_character_overrides(char_body_id, config, char, "armor")
                apply_preset_to_armor(char, new_overrides, true, true)
            end
        end
    end
end
return apply_preset
]====]
    return assert(load(source, "legacy-select-wilds", "t", env))()
end
function legacy.Rise(env)
    local source = [====[
local apply_preset = function(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_id = get_primary_body_id()
    if current_id then
        if not active_group_presets[current_id] then active_group_presets[current_id] = {} end
        active_group_presets[current_id][current_group_name] = preset_name
        TransformManager.update_base_preset(current_id, current_config, current_group_name, preset_name, merge_overrides)
        local is_current_global = (current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name]
            and current_config.groups[current_group_name].is_global)
        if is_current_global then
            -- 全局分组：重建整个 overrides
            active_overrides[current_id] = {}
            bump_overrides_version(current_id)
            local saved = active_group_presets[current_id] or {}
            -- 主列表
            local main_preset_name = saved[""]
            if main_preset_name and main_preset_name ~= "" and current_config.presets and current_config.presets[main_preset_name] then
                merge_preset_into_overrides(current_id, current_config.presets[main_preset_name])
            elseif current_config.default_preset and current_config.default_preset ~= "" and current_config.presets then
                local def = current_config.presets[current_config.default_preset]
                if def then merge_preset_into_overrides(current_id, def) end
            end
            -- 普通分组
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if not g_data.is_global then
                        local gp_name = saved[g_name]
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_preset_into_overrides(current_id, g_data.presets[gp_name])
                        elseif g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                            local g_def = g_data.presets[g_data.default_preset]
                            if g_def then merge_preset_into_overrides(current_id, g_def) end
                        end
                    end
                end
            end
            -- 全局分组（当前分组使用新预设，其他使用已保存或默认）
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global then
                        local gp_name = (g_name == current_group_name) and preset_name or saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        else
            -- 普通分组或主列表：直接合并，再叠加全局分组的隐藏覆盖
            merge_preset_into_overrides(current_id, preset_data)
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global and g_data.presets then
                        local saved = active_group_presets[current_id] or {}
                        local gp_name = saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        end
        -- 清除渲染缓存，强制下一帧重新应用
        Applied.invalidate_body(current_id)
    end
    local primary = get_primary_player()
    if not primary then return end
    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if weapon_parts then
            apply_preset_to_weapon(weapon_parts, active_overrides[current_id], true, current_id)
        end
    else
        apply_preset_to_character(primary, active_overrides[current_id], true)
    end
end
return apply_preset
]====]
    return assert(load(source, "legacy-select-rise", "t", env))()
end
return legacy
