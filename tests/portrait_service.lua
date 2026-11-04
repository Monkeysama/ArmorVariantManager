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
print("PASS: application-owned portrait, injected legacy host, independent settings and old standalone constructor")
