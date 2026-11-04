local Processor = require("ArmorVariantManager_Core.Runtime.Processor")
local Application = {}

-- 连接配置会话、外观与运行服务，界面只负责选择和显示。
function Application.new(runtime, appearance, session, rules, is_weapon_id)
    local app = {runtime=runtime, appearance=appearance, load=session.load}
    local equipment, materials = runtime.equipment, runtime.materials
    app.is_weapon_id, app.weapon_id = is_weapon_id, equipment.weapon_id
    function app.player_handle() return nil end

    local type_mesh
    function app.capture(config, group_name, id, weapon, contains, selected)
        local character = runtime.actors.local_player()
        if not character then return nil end
        type_mesh = type_mesh or sdk.find_type_definition("via.render.Mesh")
        if not type_mesh then return nil end
        local data = runtime.capture(character, config, group_name, appearance.overrides[id], is_weapon_id(id), contains)
        if not is_weapon_id(id) then
            local group = group_name == "" and config or config.groups[group_name]
            data.ground_clipping_fix = appearance.height.get_editor(config, id, group_name,
                selected[group_name] or group and group.default_preset)
        end
        return data
    end
    app.process = Processor.new({
        identify = function(character, slot)
            if slot == "armor" then return equipment.body_id(character) end
            return equipment.weapon_id(character)
        end,
        load = app.load,
        initialize = function(id)
            if not appearance.overrides[id] then appearance.defaults(id) end
        end,
        resolve = appearance.resolve,
        apply = function(character, slot, objects, result)
            if slot == "armor" then materials.armor(character, result)
            else materials.weapon(character, objects, result) end
        end,
    })

    -- 即时切换覆盖同装备角色，并补入扫描尚未发现的本地菜单演员。
    function app.refresh(id)
        local characters = runtime.actors.all()
        local primary = runtime.actors.local_player()
        if primary and sdk.is_managed_object(primary) then
            local found = false
            for _, character in ipairs(characters) do
                if character == primary then found = true; break end
            end
            if not found then characters[#characters + 1] = primary end
        end
        local weapon = is_weapon_id(id)
        for _, character in ipairs(characters) do
            local current, objects
            if weapon then current, objects = equipment.weapon_id(character)
            else current = equipment.body_id(character) end
            if current and current == id then
                local result = appearance.resolve(id, app.load(id), character, weapon and "weapon" or "armor")
                if weapon then materials.weapon(character, objects, result)
                else materials.armor(character, result) end
            end
        end
    end

    function app.select(id, config, group, preset)
        if not id or not appearance.select(id, config, group, preset) then return false end
        app.refresh(id)
        return true
    end

    -- 保存失败保留手动外观；仅持久化时不重建默认值或清除规则状态。
    function app.save(id, config, preserve)
        if not id then return end
        if not preserve then rules.refresh_config_rules(config) end
        local saved, reason = session.save(id, config)
        if not saved then return false, reason end
        if preserve then return true end
        appearance.overrides[id], appearance.groups[id] = nil, nil
        if rules.clear_last_state_cache then rules.clear_last_state_cache() end
        return true
    end

    function app.restore(id)
        local restored, reason = session.restore(id)
        if not restored then return false, reason end
        appearance.overrides[id], appearance.groups[id] = nil, nil
        local config = app.load(id)
        if config then appearance.defaults(id, config) end
        if rules.clear_last_state_cache then rules.clear_last_state_cache() end
        return true
    end

    return app
end

return Application
