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

-- 设置入口直接借用应用服务，公开独立构造入口不依赖任何显示框架。
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
local standalone = Portrait.new(config, function() return visible end)
assert(standalone == service and created == 2)

local now, suspended, available, host, rectangle = 0, false, true
local reff_visible=true
reff_native={is_visible=function() return reff_visible end}
preview.reff_available=function() return available end
preview.set_host=function(value) host=value end
preview.set_rectangle=function(value) rectangle=value end
preview.enabled,preview.status=true,"preview_live"
visible=false
local shared,web=Portrait.connect(config,{
    clock=function() return now end,suspended=function() return suspended end,
})
assert(shared==preview and created==3 and not preview.deps.should_show())
assert(web.action({visible=true}).available and host=="reff" and rectangle.w==330)
web.action({visible=true,width=280,height=680})
assert(rectangle.w==280 and rectangle.h==680,"Web canvas dimensions were discarded")
assert(preview.deps.should_show())
suspended=true;assert(not preview.deps.should_show());suspended=false
now=.4;web.action({visible=true});now=.8;assert(preview.deps.should_show(),"heartbeat did not renew camera lease")
reff_visible=false;assert(not preview.deps.should_show() and host=="reff","hidden REFF kept camera active")
reff_visible=true;web.action({visible=true})
now=1.4;assert(not preview.deps.should_show() and host=="reff","closed page retained REFF camera ownership")
visible=true;assert(not preview.deps.should_show(),"closed page resumed a retired host")
web.action({visible=true});web.action({visible=false})
assert(host=="reff" and rectangle==nil and not preview.deps.should_show())
available=false;assert(not web.action({visible=true}).available and not preview.deps.should_show())
assert(not pcall(web.action,{visible="yes"}),"invalid visibility intent was accepted")
print("PASS: application-owned REFF portrait, hidden/expired leases, independent settings and public standalone constructor")
