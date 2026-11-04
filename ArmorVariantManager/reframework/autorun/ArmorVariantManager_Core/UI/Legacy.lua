local Legacy = {}

function Legacy.new(app)
    local backend, runtime = app.backend, app.runtime
    local appearance, config_session, global_config = app.appearance, app.session, app.global_config
    local workspace = app.workspace
    local state = workspace.state
    local T, version, author = app.translate, app.version, app.author
    local TransformManager = app.rules
    local active_overrides = appearance.overrides
    local VariantManagerUI = require("ArmorVariantManager_Core.UI.VariantManagerUI")
    local runtime_guard = runtime.guard
    local safe_get_game_object = runtime.scene_object.game_object
    local can_use_transform = runtime.actors.can_transform
    local get_mesh_component_recursive, get_character_part_meshes = runtime.meshes.first, runtime.meshes.part_meshes
    local get_ground_clipping_settings, set_ground_clipping_settings = app.height.get, app.height.set
    local ground_clipping_fix = {get_status=app.height.status}
    local variant_manager_ui
    local visibility_editor = require("ArmorVariantManager_Core.Runtime.Visibility").new({
        edit = appearance.edit,
        valid = sdk.is_managed_object,
        call = function(mesh, method, ...) return mesh:call(method, ...) end,
        hidden = workspace.is_globally_hidden,
    })

    local portrait_preview = app.portrait or require("ArmorVariantManager_Core.Games.Wilds.Portrait").new(global_config, function()
        local ui = variant_manager_ui
        return ui and ui.visible and ui.ready and global_config.new_ui_enabled and not ui.suspended
            and not runtime.is_suspended()
    end)

    variant_manager_ui = VariantManagerUI.new({
        portrait_preview = portrait_preview,
        is_suspended = function() return runtime_guard.suspended end,
        config = global_config,
        translate = T,
        version = version,
        author = author,
        save_settings = app.save_global_settings,
        get_ground_clipping_settings = get_ground_clipping_settings,
        set_ground_clipping_settings = set_ground_clipping_settings,
        get_ground_clipping_status = ground_clipping_fix.get_status,

        -- 提供新 UI 所需的当前装备上下文。
        get_context = function()
            local body_id = workspace.get_body_id()
            -- 初次打开新 UI 时主动对齐当前实际应用预设；活跃状态尚未建立时回退当前分组默认预设。
            local active_preset_name = workspace.get_effective_group_presets(body_id)[state.group] or ""
            if not active_preset_name or active_preset_name == "" then
                if state.group == "" then
                    active_preset_name = workspace.config.default_preset or ""
                else
                    local group = workspace.config.groups and workspace.config.groups[state.group]
                    active_preset_name = group and group.default_preset or ""
                end
            end
            if active_preset_name ~= "" then
                for index, preset_name in ipairs(state.presets) do
                    if preset_name == active_preset_name then
                        state.preset_index = index
                        break
                    end
                end
            end
            return {
                body_id = body_id,
                character = runtime.actors.local_player(),
                weapon_mode = state.weapon,
                group_name = state.group,
                group_names = state.groups,
                preset_names = state.presets,
                selected_preset_index = state.preset_index,
                -- 新 UI 按名称选中，不能在分组切换过渡帧通过旧索引反查上一分组的预设。
                selected_preset_name = active_preset_name ~= "" and active_preset_name
                    or state.presets[state.preset_index],
                config_restored = body_id and config_session.pending(body_id),
                config = workspace.config
            }
        end,

        -- 判断配置中是否已有任意预设，兼容默认分组、普通分组和旧 JSON 缺少排序字段的情况。
        has_any_presets = function(config)
            if config and config.presets and next(config.presets) then return true end
            for _, group in pairs((config and config.groups) or {}) do
                if group.presets and next(group.presets) then return true end
            end
            return false
        end,

        -- 新 UI 直接复用旧 UI 的材质匹配逻辑，避免产生第二套 JSON 查找和保存规则。
        auto_find_preset = function(body_id)
            local ok, found, message = pcall(app.find_auto_preset, body_id)
            if not ok then return false, tostring(found) end
            return found == true, message
        end,

        -- 备份恢复与忽略继续使用旧 UI 的会话标记，恢复后会自动刷新当前分组和预设列表。
        -- "已处理"标记由 restore_config_from_backup 在写回成功后设置：
        -- 失败时不能提前置位，否则横幅会消失、备份也不再受保护。
        restore_backup = function(body_id)
            if not body_id then return false end
            return app.restore_config_from_backup(body_id) == true
        end,

        dismiss_backup = function(body_id)
            if not body_id then return end
            config_session.dismiss(body_id)
        end,

        -- 新 UI 切换模式时与旧 UI 共用分组记忆和缓存刷新规则。
        set_mode = function(weapon_mode)
            workspace.switch_variant_mode(weapon_mode)
        end,

        -- 新 UI 选择分组后，恢复该分组当前已应用的预设，不强制回退为默认预设。
        select_group = function(group_name)
            group_name = group_name or ""
            -- 换装重建期间列表可能暂时来自上一帧，忽略已经失效的分组名称。
            if group_name ~= "" and (not workspace.config.groups or not workspace.config.groups[group_name]) then
                group_name = ""
            end
            workspace.select_group(group_name)
            variant_manager_ui.material_offset = 0
        end,

        select_preset = function(index)
            state.preset_index = index
        end,

        -- 新 UI 拖动普通分组后写回旧 UI 共用的 group_order。
        reorder_groups = function(items)
            local names = {}
            for _, item in ipairs(items or {}) do
                if item.name and item.name ~= "" then names[#names + 1] = item.name end
            end
            return app.reorder_groups(names, workspace.get_body_id())
        end,

        -- 新 UI 创建分组时复用旧 UI 的材质剥离、全局重叠和 group_order 逻辑。
        create_group = function(group_name, is_global, selections)
            local body_id = workspace.get_body_id()
            if not body_id then return false end
            state.pending = selections or {}
            local created = app.create_new_group(group_name, body_id, is_global == true)
            if created then
                state.group = group_name
                state.group_index = 1
                for i, name in ipairs(state.groups) do
                    if name == state.group then state.group_index = i + 1; break end
                end
                state.preset_index = 1
                workspace.update_group_names_list()
                workspace.update_preset_names_list()
            else
                state.pending = {}
            end
            return created == true
        end,

        -- 新 UI 删除分组时复用旧 UI 的配置清理和当前分组回退逻辑。
        delete_group = function(group_name)
            local body_id = workspace.get_body_id()
            if not body_id then return false end
            local deleted = app.delete_group(group_name, body_id)
            if deleted then
                state.preset_index = 1
                variant_manager_ui.material_offset = 0
                workspace.update_group_names_list()
                workspace.update_preset_names_list()
            end
            return deleted == true
        end,

        -- 新 UI 拖动预设后写回默认分组或当前分组的 preset_order。
        reorder_presets = function(items)
            return app.reorder_presets(items, workspace.get_body_id())
        end,

        -- 新 UI 新增预设，复用旧 UI 的 save_preset、排序与配置保存逻辑。
        create_preset = function(preset_name)
            local body_id = workspace.get_body_id()
            if not body_id or not preset_name or preset_name == "" then return false end
            local saved = app.save_preset(preset_name, body_id)
            if saved then workspace.update_preset_names_list() end
            return saved == true
        end,

        -- 新 UI 覆盖当前预设，保留旧 UI 对分组和全局分组的保存行为。
        overwrite_preset = function(preset_name)
            local body_id = workspace.get_body_id()
            if not body_id or not preset_name or preset_name == "" then return false end
            local saved = app.save_preset(preset_name, body_id)
            if saved then workspace.update_preset_names_list() end
            return saved == true
        end,

        -- 新 UI 删除预设，并同步移除默认预设和排序数组中的名称。
        delete_preset = function(preset_name)
            return app.delete_preset(preset_name, workspace.get_body_id())
        end,

        -- 新 UI 设置当前选中预设为默认预设，沿用旧 UI 的分组配置写入规则。
        set_default_preset = function(preset_name)
            return app.set_preset_as_default(preset_name, workspace.get_body_id())
        end,

        -- 新 UI 勾选自动保存后立即写入当前预设，配置本身保存到 GlobalSettings.json。
        set_auto_default_enabled = function(enabled, preset_name, body_id)
            return app.set_setting("auto_set_selected_preset_as_default", enabled == true, preset_name, body_id)
        end,

        -- 新 UI 选择预设后调用，顺序保持与旧 UI 一致：先应用预设，再保存默认预设。
        auto_set_default_preset = function(preset_name, body_id)
            if not global_config.auto_set_selected_preset_as_default then return false end
            return app.set_preset_as_default(preset_name, body_id or workspace.get_body_id())
        end,

        apply_preset = app.apply_preset,

        -- 新 UI 变身管理复用当前配置的原始保存入口，保持旧 JSON 字段不变。
        save_transform = function(context)
            local body_id = context and context.body_id or workspace.get_body_id()
            if body_id then app.save_current_config_to_file(body_id) end
        end,

        -- 为新 UI 提供当前条件状态，实际条件读取仍由 TransformManager 负责。
        get_transform_state = function(type_key, character)
            if not can_use_transform(character)
                or not TransformManager.has_configured_condition(workspace.config, type_key) then return nil end
            if type_key == "damage" then
                -- 受击条件以角色地址维护倒计时，地址生成方式与旧 UI 保持一致。
                local ok, remaining = pcall(function()
                    local game_object = safe_get_game_object(character, "transform_state_damage")
                    local character_address = tostring(game_object or character)
                    return TransformManager.get_damage_remaining_time(character_address)
                end)
                return ok and remaining or nil
            end
            local getters = {
                hp = TransformManager.get_character_hp_percent,
                weapon = TransformManager.get_character_weapon_drawn,
                spirit = TransformManager.get_character_spirit_level,
                dual_blades = TransformManager.get_character_dual_blades_state,
                switch_axe = TransformManager.get_character_switch_axe_state,
                insect_glaive = TransformManager.get_character_insect_glaive_state,
                charge_blade = TransformManager.get_character_charge_blade_state,
                greatsword_type = TransformManager.get_character_greatsword_charge_type,
                greatsword_level = TransformManager.get_character_greatsword_charge_level,
                bow_level = TransformManager.get_character_bow_charge_level,
                hammer_level = TransformManager.get_character_hammer_charge_level
            }
            local getter = getters[type_key]
            if not getter then return nil end
            local ok, value = pcall(function() return getter(character) end)
            -- false 是武器“收刀”等有效状态，不能用 Lua 的 and/or 简写转成 nil。
            if ok then return value end
            return nil
        end,

        -- 生命值测试沿用旧 UI 的 TransformManager 写入接口，仅用于当前本地角色。
        set_test_hp = function(character, percent)
            if not can_use_transform(character) then return false end
            local ok, result = pcall(function()
                return TransformManager.set_character_hp_percent(character, percent)
            end)
            return ok and result ~= false
        end,

        -- 获取当前部位候选 Mesh，兼容自定义 Body ID 和旧 JSON 结构。
        get_meshes = function(character, body_id, part_index)
            if not character or not body_id then return {} end
            if state.weapon then
                local _, weapon_objs = backend.weapon_id(character)
                local weapon_obj = weapon_objs and weapon_objs[part_index + 1]
                local mesh = weapon_obj and get_mesh_component_recursive(weapon_obj)
                return mesh and { mesh } or {}
            end
            local reference = active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
            return get_character_part_meshes(character, part_index, reference)
        end,

        -- 读取当前部位的 Mesh 和材质状态，UI 不直接耦合装备扫描细节。
        get_mesh_view = function(meshes, body_id, part_index)
            local mesh = meshes and meshes[1]
            if not mesh or not sdk.is_managed_object(mesh) then return nil end
            local view = {
                mesh_enabled = mesh:call("get_Enabled") ~= false,
                materials = {}
            }
            local count = mesh:call("get_MaterialNum") or 0
            for i = 0, count - 1 do
                table.insert(view.materials, {
                    name = mesh:call("getMaterialName", i),
                    enabled = mesh:call("getMaterialsEnable", i) ~= false,
                    index = i
                })
            end
            return view
        end,

        get_override = function(body_id, part_index)
            return active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
        end,

        set_mesh_enabled = visibility_editor.mesh,
        set_material_enabled = visibility_editor.material,

        is_material_in_context = workspace.is_material_in_current_context,

        -- 为新 UI 返回与旧 UI 完全一致的普通分组占用、全局分组占用和可操作状态。
        get_material_occupancy = function(part_index, material_name)
            return {
                owner = workspace.get_material_group_owner(part_index, material_name),
                global_groups = workspace.get_material_global_groups(part_index, material_name),
                in_context = workspace.is_material_in_current_context(part_index, material_name)
            }
        end,

        get_part_count = function(character, weapon_mode)
            if not weapon_mode then return 6 end
            local _, weapon_objs = backend.weapon_id(character)
            return weapon_objs and #weapon_objs or 1
        end,

        -- 武器部件优先显示旧 UI 括号内的真实 Mesh 名称，不再使用“武器 0”之类的序号名称。
        get_part_label = function(character, weapon_mode, part_index)
            if not weapon_mode then return nil end
            local _, weapon_objs = backend.weapon_id(character)
            local weapon_obj = weapon_objs and weapon_objs[part_index + 1]
            if not weapon_obj or not sdk.is_managed_object(weapon_obj) then return nil end
            local mesh = get_mesh_component_recursive(weapon_obj)
            local target = safe_get_game_object(mesh, "part_label") or weapon_obj
            local ok, name = pcall(function() return target:call("get_Name") end)
            return ok and name or nil
        end
    })
    -- REFramework 重载脚本时可能复用 require 缓存，兼容旧缓存实例缺少原型方法的情况。
    if variant_manager_ui and not variant_manager_ui.update then
        setmetatable(variant_manager_ui, { __index = VariantManagerUI })
    end

    app.portrait = portrait_preview
    return variant_manager_ui
end

return Legacy
