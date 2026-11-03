local Defaults = require("ArmorVariantManager_Core.Presets.Defaults")
local Selection = require("ArmorVariantManager_Core.Presets.Selection")
local State = require("ArmorVariantManager_Core.Runtime.State")
local Presets = require("ArmorVariantManager_Core.Games.Wilds.Presets")
local Height = require("ArmorVariantManager_Core.GroundClippingFix")
local Appearance = {}

-- 手动意图按装备共享；条件结果与高度快照按角色保存。
function Appearance.new(deps)
    local app = {overrides={}, groups={}, state=State.new(), height=Height.new_preset_state()}

    function app.defaults(id, config)
        config = config or deps.load(id)
        if not config then return end
        app.overrides[id] = {ground_clipping_fix=Height.default_settings(config)}
        app.height.reset(id)
        local selected = app.groups[id] or {}
        app.groups[id] = selected
        Defaults.normal(config, Presets, app.overrides[id], selected)
        Defaults.globals(config, Presets, app.overrides[id], selected)
    end

    -- 无目标时不读取角色地址；菜单外观不读取战斗信号。
    function app.transform(config, character, overrides, merge)
        if not deps.rules.has_configured_rules(config) or not deps.can_transform(character) then
            app.height.set_runtime(character, config, overrides and overrides.ground_clipping_fix)
            return overrides, false, nil, nil
        end
        local object = deps.game_object(character, "transform_rules")
        local result, changed, targets, all_targets = deps.rules.apply_transform_rules(
            tostring(object or character), config, character, overrides, merge)
        app.height.set_runtime(character, config, result and result.ground_clipping_fix)
        return result, changed, targets, all_targets
    end

    function app.resolve(id, config, character, slot)
        local context = app.state:get(tostring(character), slot, id, config)
        local first_apply = context.overrides == nil
        local result, changed, targets, all_targets = app.transform(config, character, app.overrides[id], Presets.merge)
        local selected, rebuild = Selection.resolve_groups(config, app.groups[id], targets, all_targets)
        if rebuild then
            result = Selection.compose(config, selected, targets, {
                ground_clipping_fix=result.ground_clipping_fix or Height.default_settings(config)
            }, Presets)
        else
            if result == app.overrides[id] then result = Presets.merge(result, {}) end
            Selection.merge_globals(config, selected, result, Presets)
        end
        context.groups, context.overrides = selected, result
        app.height.set_runtime(character, config, result and result.ground_clipping_fix)
        return result, changed or first_apply
    end

    -- 未勾选高度只切换材质；勾选的零值可清除之前的高度修正。
    function app.select(id, config, group, preset)
        local owner = group == "" and config or config.groups and config.groups[group]
        local data = owner and owner.presets and owner.presets[preset]
        if not data then return false end
        local previous_height = app.overrides[id] and app.overrides[id].ground_clipping_fix
        local selected = app.groups[id] or {}
        app.groups[id] = selected
        app.overrides[id] = Selection.apply(config, selected, app.overrides[id], group, preset, Presets)
        app.height.reset(id, group)
        if not deps.is_weapon_id(id) then
            app.overrides[id].ground_clipping_fix = Height.participating_settings(data, config)
                or previous_height or Height.default_settings(config)
        end
        return true
    end

    -- 场景重置不清配置或手动意图。
    function app.reset()
        app.state:clear()
        deps.rules.clear_last_state_cache()
    end

    return app
end

return Appearance
