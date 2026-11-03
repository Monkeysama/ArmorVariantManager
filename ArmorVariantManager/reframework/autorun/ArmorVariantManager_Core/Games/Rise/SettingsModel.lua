local Settings = require("ArmorVariantManager_Core.UI.Reff.Settings")
local Defaults = require("ArmorVariantManager_Core.Games.Rise.Settings")
local Model = {}

function Model.new(deps)
    local defaults, config, transition = Defaults.new(), deps.config, deps.transition
    local transition_settings = transition or { enabled = true, duration = 0.355 }
    local model = { sections = Settings.sections(defaults) }
    local function transition_available()
        if transition then return true end
        return false, config.language == "en" and "Dissolve transitions are unavailable." or "溶解过渡不可用。"
    end
    local function quality_available()
        if deps.options and deps.options.apply_image_quality then return true end
        return false, config.language == "en" and "Image quality controls are unavailable." or "渲染比例控制不可用。"
    end
    model.sections[#model.sections + 1] = { id = "multiplayer", label = "d2d_settings_multiplayer", scope = "global", fields = {
        { id = "enable_multiplayer", label = "enable_multiplayer", description = "multiplayer_desc",
            type = "boolean", default = defaults.enable_multiplayer },
    } }
    local function save_transition() return transition:save_settings() end
    model.sections[#model.sections + 1] = { id = "transitions", label = "enable_dissolve", scope = "global", fields = {
        { id = "dissolve_enabled", label = "enable_dissolve", type = "boolean", default = true,
            owner = transition_settings, path = { "enabled" }, save = save_transition, available = transition_available },
        { id = "dissolve_duration", label = "dissolve_duration", type = "number", default = 0.355,
            owner = transition_settings, path = { "duration" }, save = save_transition, available = transition_available,
            min = 0.1, max = 2, step = 0.01 },
    } }
    model.sections[#model.sections + 1] = { id = "graphics", label = "image_quality", scope = "global", fields = {
        { id = "enable_image_quality", label = "enable_image_quality", type = "boolean",
            default = defaults.enable_image_quality, available = quality_available },
        { id = "image_quality_rate", label = "image_quality_rate", description = "1.0 = 100%",
            type = "number", default = defaults.image_quality_rate,
            min = 0.1, max = 4, step = 0.05, available = quality_available },
    } }
    function model.on_saved(id)
        if id == "dissolve_enabled" and not transition.enabled then return transition:finish_all()
        elseif id == "enable_image_quality" or id == "image_quality_rate" then return deps.options.apply_image_quality() end
    end
    return model
end

return Model
