local Settings = require("ArmorVariantManager_Core.Config.Settings")
local Defaults = require("ArmorVariantManager_Core.Games.Wilds.Settings")
local PortraitCamera = require("ArmorVariantManager_Core.Games.Wilds.PortraitCamera")
local Model = {}

function Model.new(deps)
    local config, defaults = deps.config, Defaults.new()
    local model = { sections = Settings.sections(defaults) }
    model.sections[#model.sections + 1] = { id = "performance", label = "d2d_settings_performance",
        description = "performance_desc", scope = "global", fields = {
            { id = "scan_interval", label = "scan_interval", type = "number", default = defaults.scan_interval,
                min = 0.1, max = 5, step = 0.1 },
            { id = "body_id_ttl", label = "refresh_interval", type = "number", default = defaults.body_id_ttl,
                min = 0.1, max = 10, step = 0.1 },
            { id = "scanner_batch_size", label = "scanner_batch_size", type = "number",
                default = defaults.scanner_batch_size, min = 10, max = 1000, step = 10, integer = true },
        } }
    local function preview()
        return deps.get_portrait_preview and deps.get_portrait_preview()
    end
    local function available()
        if preview() then return true end
        return false, config.language == "en" and "Full-body preview service is unavailable."
            or "全身预览服务不可用。"
    end
    local camera_defaults = PortraitCamera.settings()
    local fields = {
        { id = "portrait_enabled", label = "preview_title", type = "boolean", default = false, available = available },
    }
    for _, item in ipairs({
        { "distance", "preview_distance", 1, 6, 0.05 },
        { "horizontal", "preview_horizontal", -1.5, 1.5, 0.05 },
        { "vertical", "preview_vertical", -1.5, 1.5, 0.05 },
        { "light_intensity", "preview_light_intensity", 0, 2, 0.05 },
        { "refresh_fps", "preview_refresh_rate" },
    }) do
        local key = item[1]
        local field = { id = "portrait_camera." .. key, label = item[2], type = key == "refresh_fps" and "select" or "number",
            path = { "portrait_camera", key }, min = item[3], max = item[4], step = item[5],
            default = camera_defaults[key], available = available,
            read = function() return PortraitCamera.settings(config.portrait_camera)[key] end }
        if key == "refresh_fps" then
            field.options = { { value = 30, label = "30 FPS" }, { value = 60, label = "60 FPS" },
                { value = 0, label = "preview_full_speed" } }
        end
        fields[#fields + 1] = field
    end
    fields[#fields + 1] = { id = "portrait_camera.reset", label = "preview_camera_reset", type = "action",
        path = { "portrait_camera" }, reset_values = camera_defaults, available = available }
    model.sections[#model.sections + 1] = { id = "preview", label = "preview_title", scope = "global", fields = fields }
    function model.on_saved(id)
        if id == "portrait_enabled" then return preview().set_enabled(config.portrait_enabled)
        elseif id:match("^portrait_camera%.") then return preview().set_camera_settings(config.portrait_camera) end
    end
    return model
end

return Model
