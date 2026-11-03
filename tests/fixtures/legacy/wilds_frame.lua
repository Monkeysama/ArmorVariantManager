-- 荒野 dbdbba4 的完整帧回调，用于比较调用顺序与界面状态。
return function(env)
    local _ENV = env
    return function()
    local suspended = runtime_guard:update()
    variant_manager_ui:set_suspended(suspended)
    if suspended then return end
    -- 0.1 执行分帧扫描器
    if not tick_scanner() then variant_manager_ui:set_suspended(true); return end

    -- D2D 新 UI 自己维护快捷键按下沿和弹窗状态。
    variant_manager_ui:update()

    -- 1. 维护本地玩家 UI 状态
    local local_body_id = get_body_id()
    if local_body_id then
        if local_body_id ~= last_body_id then
            last_body_id = local_body_id
            -- 切换装备后分组属于新的 Body，必须回到默认分组，避免沿用上一件装备的分组名称。
            current_group_name = ""
            local restoring_mode_group = pending_mode_group_restore == true
            if not restoring_mode_group then
                -- 真实换装回到旧装备时只读取 JSON 默认预设，不恢复上次临时选择或手动覆盖。
                active_group_presets[local_body_id] = nil
                active_overrides[local_body_id] = nil
                temp_applied_presets[local_body_id] = nil
            end
            -- 如果该 body_id 已有 active_overrides（说明之前已加载过），只更新 UI 不重置状态
            if active_overrides[local_body_id] then
                -- 仅更新 UI 配置和列表
                local data = load_config_data(local_body_id)
                if data then
                    current_config = data
                    update_group_names_list()
                    update_preset_names_list()
                else
                    -- 手动开关会留下 active_overrides，但没有 JSON 时必须清空上一件装备的预设 UI。
                    load_body_config(local_body_id)
                end
            else
                -- 全新加载：重置状态并应用默认预设
                temp_applied_presets[local_body_id] = nil
                load_body_config(local_body_id)
            end
            -- 仅模式切换后恢复同一配置 ID 的分组；新装备没有记录时仍使用默认分组。
            if restoring_mode_group then
                pending_mode_group_restore = false
                local saved_group = mode_group_selection[local_body_id]
                if saved_group and saved_group ~= "" and current_config.groups
                    and current_config.groups[saved_group] then
                    current_group_name = saved_group
                    for index, group_name in ipairs(group_names_list) do
                        if group_name == saved_group then
                            selected_group_index = index + 1
                            break
                        end
                    end
                    update_preset_names_list()
                end
            end
        end
    end
    -- 当 local_body_id 为 nil 时不重置 last_body_id，避免模型短暂重建期间丢失状态

    -- 遍历所有角色并应用规则引擎
    -- 2. 遍历所有玩家并应用配置
    local all_chars = get_all_characters()
    -- 本地玩家是每帧预设应用的直接目标；角色扫描在模型重建或菜单场景中可能暂时漏掉它，
    -- 因此补入 MasterPlayer 角色，保证自定义 Body ID 也能持续应用预设状态。
    local local_char_for_frame = get_local_player_character()
    if local_char_for_frame and sdk.is_managed_object(local_char_for_frame) then
        local local_seen = false
        for _, listed_char in ipairs(all_chars) do
            if listed_char == local_char_for_frame then
                local_seen = true
                break
            end
        end
        if not local_seen then
            table.insert(all_chars, local_char_for_frame)
        end
    end
    local seen = {}
    for _, char in ipairs(all_chars) do
        if char and sdk.is_managed_object(char) then
            seen[tostring(char)] = process_character(char)
        end
    end
    actor_runtime:retain(seen)
    end
end
