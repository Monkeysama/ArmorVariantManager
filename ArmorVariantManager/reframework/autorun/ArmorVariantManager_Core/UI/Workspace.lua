local Workspace = {}

function Workspace.new(game, backend, config_session, GameConfig)
    local PresetGroups = require("ArmorVariantManager_Core.Presets.Groups")
    local runtime, appearance = backend.runtime, backend.appearance
    local loaded_configs = config_session.cache
    local active_overrides, active_group_presets, actor_runtime = appearance.overrides, appearance.groups, appearance.state
    local equipment = runtime.equipment
    local state = {weapon=false, group="", group_index=1, preset_index=1, presets={}, groups={},
        selecting=false, pending={}, mode_groups={}, restore_group=false}
    local workspace = {state=state, config=GameConfig.new(), applied={}}
    function workspace.get_body_id()
        if state.weapon then
            local id, _ = backend.weapon_id(runtime.actors.local_player())
            return id
        end
        return runtime.equipment.body_id(runtime.actors.local_player())
    end

    -- 界面展示本地角色的条件结果；编辑基线仍按装备共享。
    function workspace.get_effective_group_presets(body_id)
        local character = runtime.actors.local_player()
        local slot = (game.wilds and backend.is_weapon_id(body_id) or not game.wilds and state.weapon) and "weapon" or "armor"
        local context = character and actor_runtime:peek(tostring(character), slot, body_id, loaded_configs[body_id])
        return context and context.groups or active_group_presets[body_id] or {}
    end

    -- =============================================================================
    -- 预设和分组 UI 辅助
    -- =============================================================================
    -- 辅助函数：更新预设名称列表 (用于 UI)
    function workspace.update_preset_names_list()
        state.presets = {}
        -- 根据当前分组获取对应的预设列表和排序
        local target_presets = nil
        local target_order = nil
        if state.group == "" then
            target_presets = workspace.config.presets
            target_order = workspace.config.preset_order
        else
            if workspace.config.groups and workspace.config.groups[state.group] then
                target_presets = workspace.config.groups[state.group].presets or {}
                target_order = workspace.config.groups[state.group].preset_order
            else
                target_presets = {}
            end
        end
        if target_presets then
            -- 优先按 order 排序，fallback 按字母排序
            if target_order and #target_order > 0 then
                -- 先按 order 中的顺序添加
                local added = {}
                for _, name in ipairs(target_order) do
                    if target_presets[name] then
                        table.insert(state.presets, name)
                        added[name] = true
                    end
                end
                -- 再稳定添加 order 中没有的预设，确保旧 UI 与新 UI 使用同一排序。
                local missing = {}
                for name, _ in pairs(target_presets) do
                    if not added[name] then
                        table.insert(missing, name)
                    end
                end
                table.sort(missing)
                for _, name in ipairs(missing) do table.insert(state.presets, name) end
            else
                for name, _ in pairs(target_presets) do
                    table.insert(state.presets, name)
                end
                table.sort(state.presets)
            end
        end
        -- 2. 自动选中本地角色当前分组的活跃预设，未建立状态时回退默认预设
        local current_body_id = workspace.get_body_id and workspace.get_body_id() or nil
        local active_preset_name = ""
        if current_body_id then
            active_preset_name = workspace.get_effective_group_presets(current_body_id)[state.group] or ""
        end
        -- 如果当前角色没有选择记录，回退默认预设
        if active_preset_name == "" then
            if state.group == "" then
                active_preset_name = workspace.config.default_preset or ""
            else
                if workspace.config.groups and workspace.config.groups[state.group] then
                    active_preset_name = workspace.config.groups[state.group].default_preset or ""
                end
            end
        end
        if active_preset_name ~= "" then
            local found = false
            for i, name in ipairs(state.presets) do
                if name == active_preset_name then state.preset_index = i; found = true; break end
            end
            if not found then state.preset_index = 1 end
        else
            state.preset_index = 1
        end
        if #state.presets == 0 then state.preset_index = 1
        elseif state.preset_index > #state.presets then state.preset_index = 1 end
    end

    -- 辅助函数：更新分组名称列表 (用于 UI)
    function workspace.update_group_names_list()
        state.groups = {}
        if workspace.config.groups then
            -- 优先按 group_order 排序，fallback 按字母排序
            if workspace.config.group_order and #workspace.config.group_order > 0 then
                local added = {}
                for _, name in ipairs(workspace.config.group_order) do
                    if workspace.config.groups[name] then
                        table.insert(state.groups, name)
                        added[name] = true
                    end
                end
                for name, _ in pairs(workspace.config.groups) do
                    if not added[name] then
                        table.insert(state.groups, name)
                    end
                end
            else
                for name, _ in pairs(workspace.config.groups) do
                    table.insert(state.groups, name)
                end
                table.sort(state.groups)
            end
        end
        if #state.groups == 0 then state.group_index = 1
        elseif state.group_index > #state.groups then state.group_index = 1 end
    end
    function workspace.get_material_group_owner(part_index, mat_name)
        return PresetGroups.owner(workspace.config, part_index, mat_name)
    end

    -- 辅助函数：检测材质被哪些全局分组的 mask 覆盖（用于 UI 提示）
    function workspace.get_material_global_groups(part_index, mat_name)
        return PresetGroups.global_names(workspace.config, part_index, mat_name)
    end

    -- 切换防具/武器模式前保存当前配置的分组，下一帧加载目标配置后再恢复对应分组。
    function workspace.switch_variant_mode(weapon_mode)
        if state.weapon == weapon_mode then return end
        if state.body_id then state.mode_groups[state.body_id] = state.group end
        state.weapon = weapon_mode
        state.body_id = nil
        state.group = ""
        state.restore_group = true
        if game.wilds then equipment.clear(weapon_mode and "weapon" or "armor")
        else equipment.clear() end
    end

    -- 辅助函数：判断材质是否属于当前 UI 上下文 (主列表或当前分组)
    function workspace.is_material_in_current_context(part_index, mat_name)
        return PresetGroups.contains(workspace.config, state.group, part_index, mat_name)
    end

    -- 辅助函数：判断某材质是否被全局分组的当前预设锁定为隐藏
    -- 返回 true 表示被全局隐藏，此时不允许将其显示出来
    -- 注意：当前上下文本身就是全局分组时不做限制，允许在其内部自由编辑
    function workspace.is_globally_hidden(part_index, mat_name)
        -- 在全局分组上下文内操作时，不施加任何限制
        if state.group ~= "" and workspace.config.groups
            and workspace.config.groups[state.group]
            and workspace.config.groups[state.group].is_global then
            return false
        end
        if not workspace.config.groups then return false end
        local s_idx = tostring(part_index)
        local body_id = workspace.get_body_id()
        local active_saved = body_id and workspace.get_effective_group_presets(body_id) or {}
        for g_name, g_data in pairs(workspace.config.groups) do
            if g_data.is_global and g_data.mask and g_data.mask[s_idx]
                and g_data.mask[s_idx][mat_name] == true then
                -- 优先用用户当前选中的预设，fallback 到默认预设
                local pname = active_saved[g_name]
                if not pname or pname == "" then pname = g_data.default_preset end
                if pname and pname ~= "" and g_data.presets and g_data.presets[pname] then
                    local def = g_data.presets[pname]
                    if def[s_idx] and def[s_idx].materials and def[s_idx].materials[mat_name] == false then
                        return true
                    end
                end
            end
        end
        return false
    end
    function workspace.get_current_preset_data(preset_name)
        if state.group == "" then
            return workspace.config.presets and workspace.config.presets[preset_name]
        else
            if workspace.config.groups and workspace.config.groups[state.group] then
                return workspace.config.groups[state.group].presets and workspace.config.groups[state.group].presets[preset_name]
            end
        end
        return nil
    end

    function workspace.load_body_config(body_id)
        if not body_id then return false end
        -- 1. 重置当前内存配置，确保切换到新 Body 时不残留旧数据
        workspace.config = GameConfig.new()
        -- 2. 尝试加载数据
        local data = backend.load(body_id)
        if data then
            workspace.config = data
            -- 写入缓存，避免重复尝试加载
            loaded_configs[body_id] = workspace.config
        end
        -- 3. 始终更新 UI 列表索引和名称列表，即使加载失败也要清除 UI
        workspace.update_group_names_list()
        workspace.update_preset_names_list()
        if data then
            -- 核心修复：调用 apply_all_defaults 进行全量合并加载
            workspace.apply_all_defaults(body_id)
            return true
        end
        return false
    end


    function workspace.apply_all_defaults(id)
        return appearance.defaults(id, backend.load(id))
    end
    function workspace.select_group(name)
        if name ~= "" and not workspace.config.groups[name] then return false end
        state.group, state.group_index = name, 1
        for index, value in ipairs(state.groups) do
            if value == name then state.group_index = index+1; break end
        end
        workspace.update_preset_names_list()
        return true
    end

    function workspace.update()
        -- 1. 维护本地玩家 UI 状态
        local local_body_id = workspace.get_body_id()
        if local_body_id then
            if local_body_id ~= state.body_id then
                state.body_id = local_body_id
                -- 切换装备后分组属于新的 Body，必须回到默认分组，避免沿用上一件装备的分组名称。
                state.group = ""
                local restoring_mode_group = state.restore_group == true
                if not restoring_mode_group then
                    -- 真实换装回到旧装备时只读取 JSON 默认预设，不恢复上次临时选择或手动覆盖。
                    active_group_presets[local_body_id] = nil
                    active_overrides[local_body_id] = nil
                    workspace.applied[local_body_id] = nil
                end
                -- 如果该 body_id 已有 active_overrides（说明之前已加载过），只更新 UI 不重置状态
                if active_overrides[local_body_id] then
                    -- 仅更新 UI 配置和列表
                    local data = backend.load(local_body_id)
                    if data then
                        workspace.config = data
                        workspace.update_group_names_list()
                        workspace.update_preset_names_list()
                    else
                        -- 手动开关会留下 active_overrides，但没有 JSON 时必须清空上一件装备的预设 UI。
                        workspace.load_body_config(local_body_id)
                    end
                else
                    -- 全新加载：重置状态并应用默认预设
                    workspace.applied[local_body_id] = nil
                    workspace.load_body_config(local_body_id)
                end
                -- 仅模式切换后恢复同一配置 ID 的分组；新装备没有记录时仍使用默认分组。
                if restoring_mode_group then
                    state.restore_group = false
                    local saved_group = state.mode_groups[local_body_id]
                    if saved_group and saved_group ~= "" and workspace.config.groups
                        and workspace.config.groups[saved_group] then
                        state.group = saved_group
                        for index, group_name in ipairs(state.groups) do
                            if group_name == saved_group then
                                state.group_index = index + 1
                                break
                            end
                        end
                        workspace.update_preset_names_list()
                    end
                end
            end
        end
        -- 当 local_body_id 为 nil 时不重置 last_body_id，避免模型短暂重建期间丢失状态
    end
    return workspace
end

return Workspace
