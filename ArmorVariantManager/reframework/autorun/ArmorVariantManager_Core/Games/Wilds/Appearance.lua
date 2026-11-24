local Defaults = require("ArmorVariantManager_Core.Presets.Defaults")
local Selection = require("ArmorVariantManager_Core.Presets.Selection")
local Visibility = require("ArmorVariantManager_Core.Presets.Visibility")
local State = require("ArmorVariantManager_Core.Runtime.State")
local Presets = require("ArmorVariantManager_Core.Games.Wilds.Presets")
local Height = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingFix")
local Appearance = {}

-- 手动意图按装备共享；条件结果与高度快照按角色保存。
function Appearance.new(deps)
    local app = {overrides={}, groups={}, state=State.new(), height=Height.new_preset_state()}
    local preview

    function app.end_material_preview(id)
        if not preview or (id and preview.equipment ~= id) then return false end
        preview.material_preview = nil
        preview = nil
        return true
    end

    -- 全局组草稿只预览在当前角色上。缺少预设值的材质退出预览时恢复网格原值。
    function app.preview_material(id, part, name, enabled, config, mesh)
        local character = deps.local_player()
        if not character or not mesh then return false end
        local slot = deps.is_weapon_id(id) and "weapon" or "armor"
        local context = app.state:get(tostring(character), slot, id, config)
        if preview ~= context then
            app.end_material_preview()
            preview = context
        end
        local changes = type(name) == "table" and name or {[name]=enabled}
        context.material_preview = context.material_preview or {}
        local key = tostring(part)
        local originals = context.preview_originals or {}
        local part_originals = originals[key] or {materials={}}
        local baseline = context.overrides and context.overrides[key]
        baseline = baseline and baseline.materials or {}
        for index = 0, mesh:call("get_MaterialNum") - 1 do
            local material = mesh:call("getMaterialName", index)
            if changes[material] ~= nil and baseline[material] == nil and part_originals.materials[material] == nil then
                if deps.dissolve then
                    part_originals.materials[material] = deps.dissolve.call(mesh, "getMaterialsEnable", index)
                else
                    part_originals.materials[material] = mesh:call("getMaterialsEnable", index)
                end
            end
        end
        if next(part_originals.materials) then
            originals[key] = part_originals
            context.preview_originals = originals
        end
        Visibility.set(context.material_preview, part, changes)
        return true
    end

    function app.defaults(id, config)
        config = config or deps.load(id)
        if not config then return end
        app.end_material_preview(id)
        app.overrides[id] = {ground_clipping_fix=Height.default_settings(config)}
        app.height.reset(id)
        local selected = app.groups[id] or {}
        app.groups[id] = selected
        Defaults.normal(config, Presets, app.overrides[id], selected)
        local layer = Defaults.globals(config, Presets, {}, selected)
        Presets.apply_global_layer(config, app.overrides[id], layer)
    end

    -- 无目标时不读取角色地址；菜单外观不读取战斗信号。
    function app.transform(config, character, overrides, merge)
        if not deps.rules.has_configured_rules(config) or not deps.can_transform(character) then
            app.height.set_runtime(character, config, overrides and overrides.ground_clipping_fix)
            return overrides, false, nil, nil
        end
        local object = deps.game_object(character, "transform_rules")
        local result, changed, targets, all_targets, rules = deps.rules.apply_transform_rules(
            tostring(object or character), config, character, overrides, merge)
        app.height.set_runtime(character, config, result and result.ground_clipping_fix)
        return result, changed, targets, all_targets, rules
    end

    function app.resolve(id, config, character, slot)
        local context = app.state:get(tostring(character), slot, id, config)
        local first_apply = context.overrides == nil
        local result, changed, targets, all_targets, rules = app.transform(config, character, app.overrides[id], Presets.merge)
        -- 防具的溶解过渡由引起切换的规则决定；首次应用不溶解。
        if deps.dissolve and slot == "armor" then
            if first_apply then deps.dissolve.reset_character(tostring(character), rules, config)
            elseif changed or not rules then deps.dissolve.rules_changed(tostring(character), rules, config) end
        end
        local selected, rebuild = Selection.resolve_groups(config, app.groups[id], targets, all_targets)
        if rebuild then
            result = Selection.compose(config, selected, targets, {
                ground_clipping_fix=result.ground_clipping_fix or Height.default_settings(config)
            }, Presets)
        else
            if result == app.overrides[id] then result = Presets.merge(result, {}) end
            Selection.merge_globals(config, selected, result, Presets)
        end
        if context.preview_originals then result = Presets.merge(context.preview_originals, result) end
        if context.material_preview then result = Presets.merge(result, context.material_preview) end
        context.groups, context.targets, context.overrides = selected, targets, result
        app.height.set_runtime(character, config, result and result.ground_clipping_fix)
        return result, changed or first_apply, first_apply
    end

    -- 未勾选高度只切换材质；勾选的零值可清除之前的高度修正。
    function app.select(id, config, group, preset)
        local owner = group == "" and config or config.groups and config.groups[group]
        local data = owner and owner.presets and owner.presets[preset]
        if not data then return false end
        app.end_material_preview(id)
        local previous_height = app.overrides[id] and app.overrides[id].ground_clipping_fix
        local selected = app.groups[id] or {}
        app.groups[id] = selected
        app.overrides[id] = Selection.apply(config, selected, app.overrides[id], group, preset, Presets)
        if owner.is_global then
            local layer = Selection.merge_globals(config, selected, {}, Presets)
            Presets.apply_global_layer(config, app.overrides[id], layer)
        end
        app.height.reset(id, group)
        if not deps.is_weapon_id(id) then
            app.overrides[id].ground_clipping_fix = Height.participating_settings(data, config)
                or previous_height or Height.default_settings(config)
        end
        return true
    end

    -- 材质和网格开关只修改草稿，保存仍由预设编辑入口负责。
    function app.edit(id, part, material, enabled)
        if not id or part == nil then return false end
        app.overrides[id] = app.overrides[id] or {}
        Visibility.set(app.overrides[id], part, material, enabled)
        return true
    end

    -- 场景重置不清配置或手动意图。
    function app.reset()
        app.end_material_preview()
        app.state:clear()
        if deps.dissolve then deps.dissolve.reset() end
        deps.rules.clear_last_state_cache()
    end

    return app
end

return Appearance
