local Portrait = {}
local PortraitPreview = require("ArmorVariantManager_Core.Games.Wilds.PortraitPreview")

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

-- 两个界面共享同一相机；网页心跳只记录意图，资源操作仍由预览状态机的游戏回调执行。
function Portrait.connect(config, environment)
    local clock = environment.clock or os.clock
    local deadline, reff_selected = 0, false
    local function reff_visible()
        local native = rawget(_G, "reff_native")
        return native and native.is_visible and native.is_visible() == true
    end
    local preview
    preview = Portrait.new(config, function()
        local web_visible = deadline > clock() and reff_visible()
        if not web_visible and reff_selected then
            preview.set_host("legacy")
            reff_selected = false
        end
        return not environment.suspended() and (web_visible or environment.legacy_visible())
    end)
    local web = {}
    function web.snapshot()
        return {available=preview.reff_available(), enabled=preview.enabled,
            status=preview.status, error=preview.error}
    end
    function web.action(request)
        assert(type(request) == "table" and type(request.visible) == "boolean", "预览可见状态无效")
        if request.visible and reff_visible() and preview.reff_available() then
            deadline, reff_selected = clock() + 0.5, true
            preview.set_host("reff")
            -- CSS 尺寸只用于相机取景；最终屏幕位置和裁剪仍由正式槽位提供。
            preview.set_rectangle({x=0,y=0,w=request.width or 330,h=request.height or 360})
        else
            deadline, reff_selected = 0, false
            preview.set_host("legacy")
            preview.set_rectangle(nil)
        end
        return web.snapshot()
    end
    return preview, web
end

return Portrait
