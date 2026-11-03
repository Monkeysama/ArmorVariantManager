local Portrait = {}
local PortraitPreview = require("ArmorVariantManager_Core.PortraitPreview")

-- 应用层拥有唯一预览；界面只提供可见状态和矩形，不负责注册或销毁游戏资源。
function Portrait.new(config, should_show)
    local preview = PortraitPreview.new({
        camera_settings = config.portrait_camera,
        should_show = should_show,
        log = function(message) if log and log.error then log.error("[AVM Portrait] " .. message) end end,
    })
    preview.set_enabled(config.portrait_enabled == true)
    return preview
end

return Portrait
