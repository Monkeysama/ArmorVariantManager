local HeightEditor = {}

function HeightEditor.new(app)
    local backend, runtime = app.backend, app.runtime
    local workspace = app.workspace
    local state = workspace.state
    local active_overrides = app.appearance.overrides
    local ground_clipping_presets = app.appearance.height
    local runtime_guard = runtime.guard
    local safe_get_game_object = runtime.scene_object.game_object
    local GroundClippingFix = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingFix")
    local GroundClippingTargets = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingTargets")
    local collect_ground_clipping_targets = GroundClippingTargets.new({
        get_scene = function() return runtime_guard:get_scene() end,
        get_game_object = safe_get_game_object
    })
    local ground_clipping_fix = GroundClippingFix.new({
        is_suspended = function() return runtime_guard.scene_suspended end,
        get_targets = collect_ground_clipping_targets,
        get_status_target = function()
            local object = safe_get_game_object(runtime.actors.local_player(), "ground_clipping_status")
            local transform = object and object:call("get_Transform")
            return transform and transform:get_address()
        end,
        get_settings = function(hunter)
            local body_id = runtime.equipment.body_id(hunter)
            if not body_id then return nil end
            local config = not state.weapon and body_id == state.body_id and workspace.config
                or backend.load(body_id)
            local base = active_overrides[body_id] and active_overrides[body_id].ground_clipping_fix
            return ground_clipping_presets.get_runtime(hunter, config, base), body_id
        end
    })


    return require("ArmorVariantManager_Core.UI.HeightEditor").new(app, ground_clipping_fix)
end

return HeightEditor
