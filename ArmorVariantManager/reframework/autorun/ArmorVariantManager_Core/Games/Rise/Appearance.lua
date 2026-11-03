local Defaults = require("ArmorVariantManager_Core.Presets.Defaults")
local Processor = require("ArmorVariantManager_Core.Runtime.Processor")
local State = require("ArmorVariantManager_Core.Runtime.State")
local Selection = require("ArmorVariantManager_Core.Presets.Selection")
local Presets = require("ArmorVariantManager_Core.Games.Rise.Presets")
local Rules = require("ArmorVariantManager_Core.Games.Rise.Rules")
local Appearance = {}

-- 共享表只存手动意图；规则结果保存在角色/槽位上下文中。
function Appearance.new(load_config)
    local app = {overrides = {}, groups = {}, state = State.new()}

    function app.defaults(id, config)
        local selected = {}
        local normal = Defaults.normal(config, Presets, {}, selected)
        normal = Rules.set_model_base(id, normal, selected)
        app.overrides[id] = Defaults.globals(config, Presets, normal, selected, Presets.default_global)
        app.groups[id] = selected
        for name, group in pairs(config.groups or {}) do
            if group.is_global and selected[name] then
                Rules.update_base_preset(id, config, name, selected[name], Presets.merge)
            end
        end
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
            local result, targets, targeted, rule_changed = app.overrides[id]
            -- 菜单回退对象没有玩家句柄，不能借本地猎人信号触发条件。
            if config.enable_transform and not actor.is_event and entry.player then
                result, rule_changed, targets, targeted = Rules.apply_transform_rules(tostring(entry.obj),
                    slot .. "_" .. id, config, entry.obj, context.overrides or result, Presets.merge, entry.player)
            end
            local groups = Selection.resolve_groups(config, app.groups[id], targets, targeted)
            for name, preset in pairs(targets or {}) do groups[name] = preset end
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
        local seen = process({entry = entry, is_event = is_event, runtime = runtime})
        app.state:retain_actor(tostring(entry.obj), seen)
    end

    function app.reset() app.state:clear() end
    function app.forget_actor(object) app.state:forget(tostring(object)) end
    return app
end

return Appearance
