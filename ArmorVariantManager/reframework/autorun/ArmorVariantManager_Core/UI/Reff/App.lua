local ReffApp = {}

function ReffApp.new(app)
    local game, backend, runtime = app.game, app.backend, app.runtime
    local appearance, config_session, global_config = app.appearance, app.session, app.global_config
    local workspace = app.workspace
    local state = workspace.state
    local T, version = app.translate, app.version
    local TransformManager = app.rules
    local active_overrides = appearance.overrides
    local manual_import = app.manual_import
    local get_ground_clipping_settings = app.height and app.height.get
    local set_ground_clipping_settings = app.height and app.height.set
    local get_ground_clipping_status = app.height and app.height.status
    local safe_get_game_object = runtime.scene_object and runtime.scene_object.game_object
    local can_use_transform = runtime.actors.can_transform
    local get_character_part_meshes = runtime.meshes and runtime.meshes.part_meshes
    local access = require(game.prefix .. "MaterialView").new()
    local reff_parts = require("ArmorVariantManager_Core.UI.Reff.Parts").new({
        collect=runtime.part_view, access=access, translate=T, contains=workspace.is_material_in_current_context,
        hidden=workspace.is_globally_hidden, global_names=workspace.get_material_global_groups, owner=workspace.get_material_group_owner,
    })
    local function context()
        local id = workspace.get_body_id()
        local suspended = runtime.is_suspended() or id ~= state.body_id
        if suspended then id = nil end
        local character = runtime.actors.local_player()
        return {id=id,config=workspace.config,character=character,player=backend.player_handle(character),
            weapon=state.weapon,suspended=suspended,group=state.group,group_names=state.groups,
            preset_names=state.presets,selected=state.presets[state.preset_index],
            selecting=state.selecting,pending=state.pending,baseline=id and active_overrides[id]}
    end
    local select_group = workspace.select_group
    local editor = require("ArmorVariantManager_Core.Runtime.Visibility").new({
        edit=function(id,part,material,enabled) return appearance.edit(id,part,material,enabled,workspace.config) end,
        valid=access.valid,call=access.call,hidden=workspace.is_globally_hidden,
    })
    local function edit(request, current, material)
        if type(request.part) ~= "number" or type(request.enabled) ~= "boolean" then return false, "显隐参数无效" end
        local mesh = reff_parts.find(current,request.part)
        if not mesh then return false, "部件已不可用" end
        if material then
            if type(request.name) ~= "string" or not workspace.is_material_in_current_context(request.part,request.name) then
                return false, "材质不属于当前分组"
            end
            local found = false
            for index=0,access.call(mesh,"get_MaterialNum")-1 do
                if access.call(mesh,"getMaterialName",index) == request.name then found = true; break end
            end
            if not found then return false, "材质已不可用" end
        elseif current.weapon and access.weapon_mesh_locked then return false, "此游戏的武器网格保持启用" end
        local targets = {mesh}
        if game.wilds and not current.weapon then
            targets = get_character_part_meshes(current.character,request.part,current.baseline and current.baseline[tostring(request.part)])
        end
        if material then return editor.material(current.id,request.part,targets,request.name,request.enabled) end
        return editor.mesh(current.id,request.part,targets,request.enabled)
    end
    local function preset_name(request)
        return type(request.name) == "string" and request.name ~= "" and request.name
    end
    -- 拖动只移动一项并原子保存；固定分组仍完整保留在旧 group_order 中。
    local function reorder(request, current, groups)
        local direct = request.target ~= nil
        if not preset_name(request) or (direct and (type(request.target) ~= "string" or type(request.after) ~= "boolean")
            or not direct and request.offset ~= -1 and request.offset ~= 1) then
            return false, "排序参数无效"
        end
        if direct and (request.group ~= current.group or request.weapon ~= current.weapon) then
            return false, "装备或分组已变化，请重新操作"
        end
        local names, fixed, index, target = {}, {}, nil, nil
        for _, name in ipairs(groups and current.group_names or current.preset_names) do
            if direct and groups and current.config.groups[name].is_global then fixed[#fixed+1] = name
            else
                names[#names+1] = name
                if name == request.name then index = #names end
                if name == request.target then target = #names end
            end
        end
        if not index then return false, "排序项目已不存在" end
        if direct and not target then return false, "排序目标已不存在或不可移动" end
        local destination = direct and (target + (request.after and 1 or 0) - (index < target and 1 or 0)) or index + request.offset
        if direct and request.target == request.name then return true end
        if destination < 1 or destination > #names then return false, "项目已在列表边界" end
        if destination == index then return true end
        table.remove(names,index)
        table.insert(names,destination,request.name)
        local saved, reason
        if groups then
            for _, name in ipairs(names) do fixed[#fixed+1] = name end
            saved, reason = app.reorder_groups(fixed, current.id, true)
            select_group(current.group)
        else saved, reason = app.reorder_presets(names, current.id, true) end
        for position, name in ipairs(state.presets) do
            if name == current.selected then state.preset_index = position; break end
        end
        return saved, reason
    end
    local Conditions = require("ArmorVariantManager_Core.UI.Reff.Conditions")
    local condition_model = require(game.prefix .. "ConditionModel")
    local module_checks = game.wilds and {
        hp={"is_hp_module_initialized","hp_module_not_found"}, weapon={"has_weapon_getter","weapon_module_not_found"},
        spirit={"has_spirit_getter","spirit_module_not_found"}, dual_blades={"has_dual_blades_getter","dual_module_not_found"},
        switch_axe={"has_switch_axe_getter","switch_axe_module_not_found"}, insect_glaive={"has_insect_glaive_getter","insect_glaive_module_not_found"},
        charge_blade={"has_charge_blade_getter","charge_blade_module_not_found"}, greatsword_type={"has_greatsword_getter","greatsword_module_not_found"},
        greatsword_level={"has_greatsword_getter","greatsword_module_not_found"}, bow_level={"has_bow_getter","bow_module_not_found"},
        hammer_level={"has_hammer_getter","hammer_module_not_found"},
    } or {}
    local conditions = Conditions.new({
        model=condition_model,translate=T,
        save=function(current) return backend.save(current.id,current.config,true) end,
        -- 条件编辑不清除手动基线；持久化成功后才失效规则缓存并立即应用。
        refresh=function(current)
            if game.wilds then
                TransformManager.refresh_config_rules(current.config)
                TransformManager.clear_last_state_cache()
                backend.refresh(current.id)
            else
                backend.refresh(current.id,current.config,current.character)
            end
        end,
        state=function(current,id)
            if game.wilds then
                if not can_use_transform(current.character) then return nil end
            elseif not current.player then return nil end
            local ok,value,warning = pcall(function()
                local check = module_checks[id]
                local raw
                if game.wilds then
                    local object = safe_get_game_object(current.character,"reff_condition_state")
                    raw = TransformManager.get_configured_state(current.config,id,current.character,tostring(object or current.character))
                else
                    raw = TransformManager.get_current_raw_state({transform_type=id,is_parallel=false},current.player)
                end
                if check and TransformManager.has_configured_condition(current.config,id)
                    and not TransformManager[check[1]]() then return nil,T(check[2]) end
                return Conditions.format_state(condition_model,id,raw,T)
            end)
            if not ok then return nil,tostring(value) end
            return value,warning
        end,
        test_hp=game.wilds and function(current,value)
            if not can_use_transform(current.character) then return false,"当前角色不能测试生命值" end
            return TransformManager.set_character_hp_percent(current.character,math.max(0,math.min(100,value)))
        end or nil,
        test_damage=game.wilds and function(current)
            if not can_use_transform(current.character) then return false,"当前角色不能测试受击" end
            local hp = TransformManager.get_character_hp(current.character)
            if not hp then return false,"当前生命值不可用" end
            return TransformManager.set_character_hp(current.character,hp-25)
        end or nil,
    })
    local global_options = app.settings
    local height_options = game.wilds and require(game.prefix .. "HeightSettings").new({
        translate=T,get=get_ground_clipping_settings,set=set_ground_clipping_settings,status=get_ground_clipping_status,
    })
    local settings = {
        snapshot=function(current)
            local result = global_options.snapshot(current)
            if height_options then result.sections[#result.sections+1] = height_options.snapshot(current) end
            return result
        end,
        action=function(request,current)
            if height_options and height_options.handles(request.id) then return height_options.action(request,current) end
            return global_options.action(request,current)
        end,
    }
    -- 启动时固定帮助依赖，REFF 回调期间宿主可能已恢复默认模块搜索路径。
    local reff_help = require("ArmorVariantManager_Core.UI.Reff.Help")
    local controller = require("ArmorVariantManager_Core.UI.Reff.Controller").new({
        game=game.name,version=version,context=context,parts=reff_parts.snapshot,conditions=conditions,settings=settings,
        main_label=function() return T("main_list") end,
        language=function() return global_config.language end,
        backup_pending=config_session.pending,
        imports=manual_import and function(current) return manual_import.list(current.weapon) end or nil,
        preview=app.preview,
        documentation=function()
            return reff_help.snapshot(global_config.language,game.name)
        end,
        theme=function() return global_config.reff_theme == "reff" and "reff" or "custom" end,
        set_theme=function(value)
            local previous = global_config.reff_theme
            global_config.reff_theme = value
            if not app.save_global_settings() then global_config.reff_theme = previous; return false end
            return true
        end,
        set_mode=workspace.switch_variant_mode,
        operations={
            group=function(request) return type(request.name) == "string" and select_group(request.name) end,
            preset=function(request,current)
                if not preset_name(request) or not workspace.get_current_preset_data(request.name) then return false, "预设已不存在" end
                if global_config.auto_set_selected_preset_as_default and not app.set_preset_as_default(request.name,current.id) then return false end
                app.apply_preset(request.name)
                for index,name in ipairs(state.presets) do if name == request.name then state.preset_index=index; break end end
                return true
            end,
            save=function(request,current) return preset_name(request) and app.save_preset(request.name,current.id) end,
            ["delete-preset"]=function(request,current) return preset_name(request) and app.delete_preset(request.name,current.id) end,
            default=function(request,current) return preset_name(request) and app.set_preset_as_default(request.name,current.id) end,
            ["reorder-preset"]=function(request,current) return reorder(request,current,false) end,
            ["reorder-group"]=function(request,current) return reorder(request,current,true) end,
            mesh=function(request,current) return edit(request,current,false) end,
            material=function(request,current) return edit(request,current,true) end,
            selection=function(request)
                if type(request.enabled) ~= "boolean" then return false end
                state.selecting = request.enabled
                if not request.enabled then state.pending = {} end
                return true
            end,
            ["select-material"]=function(request,current)
                if not current.selecting or type(request.enabled) ~= "boolean" then return false end
                local mesh = reff_parts.find(current,request.part)
                if not mesh then return false end
                for index=0,access.call(mesh,"get_MaterialNum")-1 do
                    if access.call(mesh,"getMaterialName",index) == request.name then
                        local part = tostring(request.part)
                        state.pending[part] = state.pending[part] or {}
                        state.pending[part][request.name] = request.enabled or nil
                        return true
                    end
                end
                return false
            end,
            ["create-group"]=function(request,current)
                if not preset_name(request) or not current.selecting then return false end
                if not request.global then
                    for part,names in pairs(state.pending) do
                        for name,selected in pairs(names) do
                            if selected and workspace.get_material_group_owner(part,name) then return false, "普通分组不能重复占用材质" end
                        end
                    end
                end
                if not app.create_new_group(request.name,current.id,request.global == true) then return false end
                return select_group(request.name)
            end,
            ["delete-group"]=function(request,current) return preset_name(request) and app.delete_group(request.name,current.id) end,
            find=function(_,current)
                local saved,reason = app.find_auto_preset(current.id)
                if saved then workspace.update_group_names_list(); workspace.update_preset_names_list() end
                return saved,reason
            end,
            ["import-preset"]=function(request,current)
                return app.load_manual_preset_file(request.path,current.id)
            end,
            restore=function(_,current) return app.restore_config_from_backup(current.id) end,
            ["dismiss-backup"]=function(_,current)
                config_session.dismiss(current.id)
                return true
            end,
        },
    })
    require("ArmorVariantManager_Core.UI.Reff.Bridge").register(controller)
end

return ReffApp
