local PresetGroups = require("ArmorVariantManager_Core.Presets.Groups")
local PresetEditor = require("ArmorVariantManager_Core.Presets.Editor")
local App = {}

function App.new(options)
    local backend, game = options.backend, options.game
    local runtime, appearance = backend.runtime, backend.appearance
    local app = options
    app.runtime, app.appearance = runtime, appearance
    app.global_config = app.global_settings.value
    local global_config, config_session, GameConfig = app.global_config, app.session, app.schema
    local TransformManager = app.rules
    local loaded_configs = config_session.cache
    local workspace = require("ArmorVariantManager_Core.UI.Workspace").new(game, backend, config_session, GameConfig)
    app.workspace = workspace
    local state = workspace.state
    local manual_import = not game.wilds and require(game.prefix .. "ManualImport").new() or nil
    app.manual_import = manual_import
    local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
    -- 预览和游戏选项装配后建立设置事务，三个界面共用保存与应用失败语义。
    function app.initialize_settings()
        app.settings = require("ArmorVariantManager_Core.Config.Settings").new({
            global_session=app.global_settings,translate=app.translate,
            model=require(game.prefix .. "SettingsModel").new({config=global_config,transition=runtime.transition,
                options=app.game_options,get_portrait_preview=function() return app.portrait end}),
            on_saved=function(id,value,current)
                _G.__AVM_LANGUAGE = global_config.language
                if id == "auto_set_selected_preset_as_default" and value == true
                    and current.id and not current.suspended and current.selected and workspace.get_current_preset_data(current.selected) then
                    return app.set_preset_as_default(current.selected, current.id)
                end
                return true
            end,
        })
    end

    function app.set_setting(id, value, preset_name, body_id)
        return app.settings.action({id=id, value=value}, {
            id=body_id or workspace.get_body_id(), suspended=runtime.is_suspended(),
            selected=preset_name or state.presets[state.preset_index],
        })
    end

    function app.save_global_settings()
        local saved, reason = app.global_settings.save()
        if saved then _G.__AVM_LANGUAGE = global_config.language end
        return saved, reason
    end
    local function deep_copy_table(orig)
        local orig_type = type(orig)
        local copy
        if orig_type == 'table' then
            copy = {}
            for orig_key, orig_value in next, orig, nil do
                copy[deep_copy_table(orig_key)] = deep_copy_table(orig_value)
            end
            setmetatable(copy, deep_copy_table(getmetatable(orig)))
        else -- number, string, boolean, etc
            copy = orig
        end
        return copy
    end

    function app.create_new_group(group_name, body_id, is_global)
        if not body_id then return false end
        local previous = deep_copy_table(workspace.config)
        if not PresetGroups.create(workspace.config, group_name, state.pending, is_global, game.wilds) then return false end
        if app.save_current_config_to_file(body_id) == false then
            for key in pairs(workspace.config) do workspace.config[key] = nil end
            for key, value in pairs(previous) do workspace.config[key] = value end
            if TransformManager.refresh_config_rules then TransformManager.refresh_config_rules(workspace.config) end
            return false
        end
        state.pending = {}
        state.selecting = false
        workspace.update_group_names_list()
        return true
    end

    -- 辅助函数：删除材质级分组并归还控制权
    function app.delete_group(group_name, body_id)
        if not body_id then return false end
        local previous = deep_copy_table(workspace.config)
        if not PresetGroups.delete(workspace.config, group_name) then return false end
        if app.save_current_config_to_file(body_id) == false then
            for key in pairs(workspace.config) do workspace.config[key] = nil end
            for key, value in pairs(previous) do workspace.config[key] = value end
            if TransformManager.refresh_config_rules then TransformManager.refresh_config_rules(workspace.config) end
            return false
        end
        if state.group == group_name then
            state.group = ""
            state.group_index = 1
            workspace.update_preset_names_list()
        end
        workspace.update_group_names_list()
        return true
    end
    function app.apply_preset(preset_name)
        local preset_data = workspace.get_current_preset_data(preset_name)
        if not preset_data then return end
        local current_body_id = workspace.get_body_id()
        if current_body_id then
            backend.select(current_body_id, workspace.config, state.group, preset_name)
            workspace.applied[current_body_id] = preset_name
        end
    end

    app.save_current_config_to_file = function(body_id, preserve_active_state)
        return backend.save(body_id, workspace.config, preserve_active_state)
    end

    -- 将指定预设写为当前分组的默认预设，供旧 UI、新 UI 和自动保存开关共用。
    function app.set_preset_as_default(preset_name, body_id)
        if not body_id or not preset_name or preset_name == "" or not workspace.config then return false end
        local saved, reason = PresetEditor.set_default(workspace.config, state.group, preset_name, function(preserve)
            return app.save_current_config_to_file(body_id, preserve)
        end)
        if not saved then return false, reason end
        workspace.update_preset_names_list()
        return true
    end

    -- 删除与排序都通过编辑层保存，失败时保留原配置。
    function app.delete_preset(preset_name, body_id)
        if not body_id or not preset_name or preset_name == "" or not workspace.config then return false end
        local saved = PresetEditor.delete(workspace.config, state.group, preset_name, function(preserve)
            return app.save_current_config_to_file(body_id, preserve)
        end)
        workspace.update_preset_names_list()
        return saved
    end

    function app.reorder_presets(names, body_id, preserve_state)
        if not body_id or not workspace.config then return false end
        local saved, reason = PresetEditor.reorder(workspace.config, state.group, names, function(preserve)
            return app.save_current_config_to_file(body_id, preserve_state or preserve)
        end)
        workspace.update_preset_names_list()
        return saved, reason
    end

    function app.reorder_groups(names, body_id, preserve_state)
        if not body_id or not workspace.config then return false end
        local saved, reason = PresetEditor.reorder_groups(workspace.config, names, function(preserve)
            return app.save_current_config_to_file(body_id, preserve_state or preserve)
        end)
        workspace.update_group_names_list()
        return saved, reason
    end

    -- 开启自动保存时立即持久化当前选中预设，避免开关状态和当前默认预设不一致。
    function app.auto_set_selected_preset_as_default(body_id)
        if not global_config.auto_set_selected_preset_as_default then return false end
        return app.set_preset_as_default(state.presets[state.preset_index], body_id)
    end

    -- 将备份写回主配置文件，成功后同步工作区。

    function app.restore_config_from_backup(body_id)
        local restored, reason = backend.restore(body_id)
        if not restored then return false, reason end
        workspace.config = backend.load(body_id)
        workspace.update_group_names_list()
        workspace.update_preset_names_list()
        return true
    end

    function app.save_preset(preset_name, body_id)
        body_id = body_id or workspace.get_body_id()
        if not body_id then return false end
        local data = backend.capture(workspace.config, state.group, body_id, state.weapon,
            workspace.is_material_in_current_context, workspace.get_effective_group_presets(body_id))
        if not data then return false end
        local saved, reason = PresetEditor.write(workspace.config, state.group, preset_name, data, function(preserve)
            return app.save_current_config_to_file(body_id, preserve)
        end)
        workspace.update_preset_names_list()
        return saved, reason
    end
    function app.load_manual_preset_file(file_path, body_id)
        if not manual_import or not body_id or body_id ~= workspace.get_body_id()
            or body_id ~= state.body_id or runtime.is_suspended() then
            return false, "角色不可用或装备已变化"
        end
        local data, reason = manual_import.load(file_path)
        if not data then return false, reason end
        Normalize.apply(data, GameConfig)
        local previous_cache = loaded_configs[body_id]
        local saved, save_reason = backend.save(body_id, data)
        if not saved then
            loaded_configs[body_id] = previous_cache
            return false, save_reason
        end
        workspace.config = data
        state.group, state.group_index = "", 1
        state.mode_groups[body_id] = ""
        state.selecting, state.pending = false, {}
        workspace.imported = workspace.config
        workspace.update_group_names_list()
        workspace.update_preset_names_list()
        backend.refresh(body_id, workspace.config, runtime.actors.local_player())
        return true
    end
    function app.find_auto_preset(target_body_id)
        local data, message = runtime.find_preset(target_body_id, runtime.actors.local_player(),
            backend.player_handle(runtime.actors.local_player()), state.weapon)
        if not data then return false, message end
        local previous, previous_cache = workspace.config, loaded_configs[target_body_id]
        workspace.config = data
        if not app.save_current_config_to_file(target_body_id) then
            workspace.config, loaded_configs[target_body_id] = previous, previous_cache
            return false, "Failed to save matched preset"
        end
        workspace.update_preset_names_list()
        return true, message
    end


    return app
end

return App
