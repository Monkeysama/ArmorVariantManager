local Appearance = require("ArmorVariantManager_Core.Games.Rise.Appearance")
local Runtime = require("ArmorVariantManager_Core.Games.Rise.Runtime")
local Rules = require("ArmorVariantManager_Core.Games.Rise.Rules")
local Application = {}

-- 配置会话由共享应用持有；游戏应用连接外观、运行服务和界面操作。
function Application.new(settings, session)
    local app = {}

    local function refresh_monster_hp_gate()
        local needed = false
        for _, config in pairs(session.cache) do
            if type(config) == "table" and config.enable_transform == true then
                local parallel = config.parallel_settings and config.parallel_settings.monster_hp
                local uses = config.transform_type == "monster_hp"
                    or (config.is_parallel and parallel and parallel.enabled == true)
                if uses and config.monster_hp_transform_rules and next(config.monster_hp_transform_rules) then
                    needed = true
                    break
                end
            end
        end
        Rules.set_monster_hp_tracking(needed)
    end

    function app.load(id)
        local previous = session.cache[id]
        local config = session.load(id)
        if previous ~= session.cache[id] then refresh_monster_hp_gate() end
        return config
    end

    app.appearance = Appearance.new(app.load)
    app.runtime = Runtime.new(settings, app.appearance)
    _G.__AVM_LANGUAGE = settings.language
    refresh_monster_hp_gate()

    function app.player_handle(character)
        for _, entry in ipairs(app.runtime.actors.get().entries) do
            if entry.obj == character then return entry.player end
        end
    end

    function app.weapon_id(character)
        local player = app.player_handle(character)
        return app.runtime.equipment.weapon_id(character, player), app.runtime.equipment.weapons(character, player)
    end

    local type_mesh
    function app.capture(config, group, id, weapon, contains)
        local character = app.runtime.actors.local_player()
        if not character then return nil end
        type_mesh = type_mesh or sdk.find_type_definition("via.render.Mesh")
        if not type_mesh then return nil end
        return app.runtime.capture(character, app.player_handle(character), config, group, weapon, contains)
    end

    -- 规则编辑可保持同一战斗信号，仍必须废弃该装备的编译结果和材质快路径。
    function app.refresh(id, config, character)
        if not id or not config then return false end
        Rules.invalidate_config(id, config)
        app.runtime.materials.invalidate(id)
        refresh_monster_hp_gate()
        return app.runtime.refresh(character)
    end

    function app.set_enabled(id, config, enabled)
        config.enable_transform = enabled
        return app.refresh(id, config)
    end

    function app.select(id, config, group, preset)
        if not app.appearance.select(id, config, group, preset) then return false end
        app.runtime.refresh()
        return true
    end

    function app.edit(id, part, material, enabled)
        if not app.appearance.edit(id, part, material, enabled) then return false end
        app.runtime.refresh()
        return true
    end

    -- 写入失败不重建手动意图；成功后按调用方选择保留编辑状态或重建默认预设。
    function app.save(id, config, preserve)
        local saved, reason = session.save(id, config)
        if not saved then return false, reason end
        Rules.invalidate_config(id, config)
        if not preserve then app.appearance.defaults(id, config) end
        app.runtime.materials.invalidate(id)
        refresh_monster_hp_gate()
        return true
    end

    function app.restore(id)
        local restored, reason = session.restore(id)
        if not restored then return false, reason end
        local config = app.load(id)
        if not config then return false end
        app.appearance.defaults(id, config)
        Rules.invalidate_config(id, config)
        app.runtime.materials.invalidate(id)
        app.runtime.refresh()
        return true
    end

    return app
end

return Application
