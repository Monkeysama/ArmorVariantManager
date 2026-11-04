package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
-- 旧 require 路径仍返回正式实现，不创建第二份模块状态或生命周期。
for _, name in ipairs({"PortraitCamera", "PortraitModel", "PortraitPreview", "GroundClippingFix", "GroundClippingTargets"}) do
    assert(require("ArmorVariantManager_Core." .. name) == require("ArmorVariantManager_Core.Games.Wilds." .. name))
end
local created, received, visible, preview_enabled = 0, nil, false, false
local preview = { set_enabled = function(value) preview_enabled = value end,
    set_camera_settings = function(value) received = value end }
package.loaded["ArmorVariantManager_Core.Games.Wilds.PortraitPreview"] = {
    new = function(deps) created = created + 1; preview.deps = deps; return preview end,
}
re = { on_frame = function() end, on_script_reset = function() end }
local config = { portrait_enabled = true, portrait_camera = { distance = 3, extension = "keep" } }
local Portrait = require("ArmorVariantManager_Core.Games.Wilds.Portrait")
local service = Portrait.new(config, function() return visible end)
assert(service == preview and created == 1 and preview_enabled == true)
assert(preview.deps.camera_settings == config.portrait_camera)
assert(not preview.deps.should_show()); visible = true; assert(preview.deps.should_show())

-- 旧弹窗仅借用应用服务，独立调用方仍能自行创建；设置入口不经弹窗取实例。
local UI = require("ArmorVariantManager_Core.UI.VariantManagerUI")
local ui = UI.new({ config = config, portrait_preview = service })
assert(ui.portrait_preview == service and created == 1)
assert(received == config.portrait_camera)
ui.portrait_preview = nil
local Global = require("ArmorVariantManager_Core.Config.Global")
local defaults = require("ArmorVariantManager_Core.Games.Wilds.Settings")
local session = Global.new(defaults, { save = function() return true end })
session.value.portrait_camera = config.portrait_camera
local settings = require("ArmorVariantManager_Core.UI.Reff.Settings").new({
    global_session = session,
    model = require("ArmorVariantManager_Core.Games.Wilds.SettingsModel").new({
        config = session.value, get_portrait_preview = function() return service end,
    }),
    translate = function(key) return key end,
})
assert(settings.action({kind="setting",id="portrait_camera.distance",value=4}, {}))
assert(received.distance == 4 and received.extension == "keep" and created == 1)
local standalone = UI.new({ config = config })
assert(standalone.portrait_preview == service and created == 2)

local now, suspended, available, host, rectangle = 0, false, true
local reff_visible=true
reff_native={is_visible=function() return reff_visible end}
preview.reff_available=function() return available end
preview.set_host=function(value) host=value end
preview.set_rectangle=function(value) rectangle=value end
preview.enabled,preview.status=true,"preview_live"
visible=false
local shared,web=Portrait.connect(config,{
    clock=function() return now end,suspended=function() return suspended end,legacy_visible=function() return visible end,
})
assert(shared==preview and created==3 and not preview.deps.should_show())
assert(web.action({visible=true}).available and host=="reff" and rectangle.w==330)
web.action({visible=true,width=280,height=680})
assert(rectangle.w==280 and rectangle.h==680,"Web canvas dimensions were discarded")
assert(preview.deps.should_show())
suspended=true;assert(not preview.deps.should_show());suspended=false
now=.4;web.action({visible=true});now=.8;assert(preview.deps.should_show(),"heartbeat did not renew camera lease")
reff_visible=false;assert(not preview.deps.should_show() and host=="legacy","hidden REFF kept camera active")
reff_visible=true;web.action({visible=true})
now=1.4;assert(not preview.deps.should_show() and host=="legacy","closed page retained REFF camera ownership")
visible=true;assert(preview.deps.should_show(),"old preview cannot resume after page closes")
web.action({visible=true});web.action({visible=false})
assert(host=="legacy" and rectangle==nil and preview.deps.should_show())
available=false;assert(not web.action({visible=true}).available and host=="legacy")
assert(not pcall(web.action,{visible="yes"}),"invalid visibility intent was accepted")
print("PASS: application-owned portrait, injected legacy host, independent settings and old standalone constructor")
