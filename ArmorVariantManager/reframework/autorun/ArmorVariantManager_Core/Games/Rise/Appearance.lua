local Defaults = require("ArmorVariantManager_Core.Presets.Defaults")
local Processor = require("ArmorVariantManager_Core.Runtime.Processor")
local State = require("ArmorVariantManager_Core.Runtime.State")
local Selection = require("ArmorVariantManager_Core.Presets.Selection")
local Visibility = require("ArmorVariantManager_Core.Presets.Visibility")
local Presets = require("ArmorVariantManager_Core.Games.Rise.Presets")
local Rules = require("ArmorVariantManager_Core.Games.Rise.Rules")
local Height = require("ArmorVariantManager_Core.Presets.Height")
local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Appearance = {}

-- 共享表只存手动意图；规则结果保存在角色/槽位上下文中。
function Appearance.new(load_config)
    local app = {overrides = {}, groups = {}, state = State.new(), height = Height.new_preset_state()}
    local edited_outputs = {}
    local preview

    function app.end_material_preview()
        if not preview then return false end
        local id = preview.id
        preview = nil
        app.overrides[id] = Rules.with_model_base(id, app.overrides[id])
        if edited_outputs[id] then
            edited_outputs[id] = Rules.with_model_base(id, edited_outputs[id])
        end
        return true
    end

    -- 全局组的勾选只预览在本地猎人上，不改已选预设或规则的回滚基础。
    function app.preview_material(id, part, name, enabled, config, mesh)
        if not app.overrides[id] then app.defaults(id, config) end
        if not preview or preview.id ~= id then
            app.end_material_preview()
            preview = {id=id, fields={}}
        end
        local materials = type(name) == "table" and name or {[name]=enabled}
        Rules.capture_mesh(id, part, mesh, {materials=materials}, SceneObject.call)
        Visibility.set(preview.fields, part, materials)
        preview.base = nil
        return true
    end

    function app.defaults(id, config)
        if preview and preview.id == id then preview = nil end
        edited_outputs[id] = nil
        local selected = {}
        local normal = Defaults.normal(config, Presets, {}, selected)
        normal = Rules.set_model_base(id, normal, selected)
        app.overrides[id] = Defaults.globals(config, Presets, normal, selected, Presets.default_global)
        app.groups[id] = selected
        app.height.reset(id)
        local height = Height.default_settings(config, Presets.default_global)
        if height.enabled then app.overrides[id].ground_clipping_fix = height end
        for name, group in pairs(config.groups or {}) do
            if group.is_global and selected[name] then
                Rules.update_base_preset(id, config, name, selected[name], Presets.merge)
            end
        end
    end

    -- 更新手动意图与条件回滚基础；新结果实例让未启用规则的角色也刷新材质版本。
    function app.select(id, config, group_name, preset_name)
        local owner = group_name == "" and config or config.groups and config.groups[group_name]
        if not (owner and owner.presets and owner.presets[preset_name]) then return false end
        if not app.overrides[id] then app.defaults(id, config) end
        if preview and preview.id == id then app.end_material_preview() end
        local last_height = app.overrides[id].ground_clipping_fix
        app.overrides[id] = Selection.apply(config, app.groups[id], Presets.merge(app.overrides[id], {}),
            group_name, preset_name, Presets)
        if owner.is_global then
            app.overrides[id] = Rules.with_model_base(id, app.overrides[id])
        end
        app.height.reset(id, group_name)
        app.overrides[id].ground_clipping_fix = Height.participating_settings(owner.presets[preset_name], config) or last_height
        Rules.update_base_preset(id, config, group_name, preset_name, Presets.merge)
        edited_outputs[id] = nil
        return true
    end

    -- 换用新草稿实例使各角色察觉编辑；规则结束后回到编辑后的基础值。
    function app.edit(id, part, material, enabled, config)
        if not id or part == nil then return false end
        config = config or load_config(id)
        if not config then return false end
        if not app.overrides[id] then app.defaults(id, config) end
        local draft = Presets.merge(app.overrides[id] or {}, {})
        Visibility.set(draft, part, material, enabled)
        app.overrides[id] = draft
        Rules.edit_base_field(id, part, material, enabled)
        local result = Presets.merge(draft, {})
        Selection.merge_globals(config, app.groups[id], result, Presets)
        edited_outputs[id] = result
        return true
    end

    local process = Processor.new({
        identify = function(actor, slot)
            local equipment, entry = actor.runtime.equipment, actor.entry
            if slot == "armor" then return equipment.body_id(entry.obj) end
            local id = equipment.weapon_id(entry.obj, entry.player)
            if id then return id, equipment.weapons(entry.obj, entry.player) end
        end,
        load = function(id, actor)
            local config = load_config(id)
            if not config or actor.entry.is_local then return config end
            if config.presets and next(config.presets) then return config end
            for _, group in pairs(config.groups or {}) do
                if group.presets and next(group.presets) then return config end
            end
        end,
        initialize = function(id, config)
            if not app.overrides[id] then app.defaults(id, config) end
        end,
        resolve = function(id, config, actor, slot)
            local entry = actor.entry
            local context = app.state:get(tostring(entry.obj), slot, id, config)
            local result, targets, targeted, rule_changed = edited_outputs[id] or app.overrides[id]
            -- 菜单回退对象没有玩家句柄，不能借本地猎人信号触发条件。
            if config.enable_transform and not actor.is_event and entry.player then
                result, rule_changed, targets, targeted = Rules.apply_transform_rules(tostring(entry.obj),
                    slot .. "_" .. id, config, entry.obj, context.overrides or result, Presets.merge, entry.player)
            end
            local groups = Selection.resolve_groups(config, app.groups[id], targets, targeted)
            for name, preset in pairs(targets or {}) do groups[name] = preset end
            if slot == "armor" and entry.is_local and entry.player and not actor.is_event then
                local settings = app.overrides[id].ground_clipping_fix
                if targets and next(targets) and result and result.ground_clipping_fix then
                    settings = result.ground_clipping_fix
                end
                if settings and settings.enabled and settings.height_cm ~= 0 then
                    app.height_actor, app.height_cm = entry.obj, settings.height_cm
                end
            end
            if preview and preview.id == id and entry.is_local and not actor.is_event then
                if preview.base ~= result then
                    preview.base = result
                    preview.output = Presets.merge(result, preview.fields)
                end
                result = preview.output
            end
            local changed = context.overrides ~= result
            if changed then context.version = (context.version or 0) + 1 end
            context.overrides, context.groups = result, groups
            return result, changed
        end,
        apply = function(actor, slot, objects, result, changed, id, config)
            local entry = actor.entry
            local context = app.state:peek(tostring(entry.obj), slot, id, config)
            local options = {body_id = id, version = context.version, special_cg = actor.is_event}
            if slot == "armor" then actor.runtime.materials.armor(entry.obj, result, options)
            else actor.runtime.materials.weapon(entry.obj, objects, result, options) end
        end,
    })

    -- 与 Runtime 的回调直接对接；清场不丢配置和手动选择。
    function app.process(entry, is_event, runtime)
        if entry.is_local then app.height_actor, app.height_cm = nil, nil end
        local seen = process({entry = entry, is_event = is_event, runtime = runtime})
        app.state:retain_actor(tostring(entry.obj), seen)
    end

    function app.reset()
        app.end_material_preview()
        app.height_actor, app.height_cm = nil, nil
        app.state:clear()
    end
    function app.forget_actor(object) app.state:forget(tostring(object)) end
    return app
end

return Appearance
