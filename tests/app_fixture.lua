local Fixture = {}
local prefix = "ArmorVariantManager_Core."

-- 引擎与存储可替换，工作区及事务始终执行正式模块。
function Fixture.new(game, options)
    options = options or {}
    local backend = options.backend or {}
    backend.runtime = backend.runtime or {
        actors={local_player=function() end}, equipment={body_id=function() return "armor" end},
        scene_object={}, meshes={}, guard={}, is_suspended=function() return false end,
    }
    backend.appearance = backend.appearance or {overrides={}, groups={}, state=require(prefix .. "Runtime.State").new()}
    backend.is_weapon_id = backend.is_weapon_id or function() return false end
    backend.player_handle = backend.player_handle or function() end
    local app = require(prefix .. "App").new({
        game={wilds=game == "Wilds", prefix=prefix .. "Games." .. game .. "."},
        backend=backend, schema=require(prefix .. "Games." .. game .. ".Config"),
        session=options.session or {cache={}}, rules=options.rules or {},
        global_settings=options.global_settings or {value={}, save=function() return true end},
        translate=function(key) return key end,
    })
    app.height = {}
    app.initialize_settings()
    return app
end

-- 只替换旧显示宿主和预览生命周期，执行正式 UI 适配器的全部回调接线。
function Fixture.legacy(app)
    local env = setmetatable({require=function(name)
        if name == prefix .. "UI.VariantManagerUI" then return {new=function(deps) return deps end} end
        if name == prefix .. "Games.Wilds.Portrait" then return {new=function() return {} end} end
        return require(name)
    end}, {__index=_G})
    return assert(loadfile("ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/UI/Legacy.lua", "t", env))().new(app)
end

return Fixture
