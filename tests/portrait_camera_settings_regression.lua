package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local Camera = require("ArmorVariantManager_Core.Games.Wilds.PortraitCamera")
local Preview = require("ArmorVariantManager_Core.Games.Wilds.PortraitPreview")
local function same(a, b, message) assert(a == b, (message or "mismatch") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end

-- 镜头配置兼容旧文件，修正越界值，并保留不属于本功能的字段。
local defaults = Camera.settings(nil)
same(defaults.distance, 2.8); same(defaults.horizontal, 0); same(defaults.vertical, 0)
same(defaults.light_intensity, 1.0)
same(defaults.refresh_fps, 30)
for _, value in ipairs({0, 30, 60}) do same(Camera.settings({refresh_fps=value}).refresh_fps, value) end
for _, value in ipairs({-1, 1, 120, "30", math.huge}) do same(Camera.settings({refresh_fps=value}).refresh_fps, 30) end
same(Camera.settings({light_intensity=9}).light_intensity, 2.0)
same(Camera.settings({light_intensity=-1}).light_intensity, 0.0)
same(Camera.settings({light_intensity=0/0}).light_intensity, 1.0)
local incoming = { distance = 99, horizontal = -9, vertical = 9, extension = { keep = true } }
local bounded = Camera.settings(incoming)
same(bounded.distance, 6); same(bounded.horizontal, -1.5); same(bounded.vertical, 1.5)
same(bounded.extension, incoming.extension); same(incoming.distance, 99, "Do not mutate loaded settings")
for _, bad in ipairs({ math.huge, -math.huge, 0 / 0, "near", false }) do
    same(Camera.settings({ distance = bad }).distance, defaults.distance)
end
same(Camera.settings({ distance = -2 }).distance, 1)

-- 执行主入口的真实全局读写函数，确保新增设置与旧字段、未知字段一起往返。
local loaded, saved
local session = require("ArmorVariantManager_Core.Config.Global").new(
    require("ArmorVariantManager_Core.Games.Wilds.Settings"), {
        load = function() return loaded end,
        save = function(path, value)
            same(path, "ArmorVariantManager/GlobalSettings.json"); saved = value; return true
        end,
    })
local env = {global_config=session.value}
local app = dofile("tests/app_fixture.lua").new("Wilds", {global_settings=session})
local load_settings, save_settings = session.load, app.save_global_settings
loaded = { language = "en", new_ui_enabled = false, auto_set_selected_preset_as_default = false,
    portrait_camera = { distance = 2.15, horizontal = 0.35, vertical = -0.1, refresh_fps = 0, extension = "keep" },
    unknown_global = { retain = 77 } }
load_settings(); save_settings()
same(saved.language, "en"); same(saved.new_ui_enabled, false)
same(saved.auto_set_selected_preset_as_default, false)
same(saved.portrait_camera.distance, 2.15); same(saved.portrait_camera.extension, "keep")
same(saved.portrait_camera.refresh_fps, 0)
same(saved.unknown_global.retain, 77)
loaded = { language = "zh" }; load_settings(); same(env.global_config.portrait_camera.distance, 2.15)

-- 渲染阶段只记录镜头请求；游戏更新只提交镜头设置，不重写固定 RT 的投影。
local phase, now, configured, queried = "render", 0, nil, 0
local function game_only() same(phase, "game", "No camera SDK work in the renderer") end
local adapter = { independent = true,
    configure = function(settings, aspect) game_only(); configured = { settings = settings, aspect = aspect } end,
    current = function() game_only(); queried = queried + 1; return {} end,
    identity = function() return "camera" end, holder = function() return 17 end,
    output = function() return 0, 1 end, stop = function() game_only() end }
local native = { portrait_version = function() return 4 end, portrait_ready = function() return 1 end,
    portrait_state = function() return 1 end, portrait_output = function() return 0 end,
    portrait_alpha = function() return 0 end, portrait_update = function() game_only(); return 0 end }
local preview = Preview.new({ adapter = adapter, register = false, bridge = function() return native end,
    clock = function() return now end, camera_settings = loaded.portrait_camera })
preview.set_enabled(true); preview.set_rectangle({ x = 10, y = 20, w = 256, h = 608 })
preview.set_camera_settings({ distance = 2.2, horizontal = 0.4, vertical = -0.2 })
same(configured, nil); phase = "game"; preview.tick()
same(configured.settings.distance, 2.2); same(configured.aspect, nil, "Viewport is handled by native proportional crop")
same(configured.settings.refresh_fps, 30)
phase = "render"; preview.set_camera_settings({ distance = 1.8 })
phase = "game"; now = 0.02; preview.tick()
same(configured.settings.distance, 1.8); same(queried, 2, "Live edits do not wait for a restart")
preview.shutdown()
print("PASS: camera defaults/clamps, old and unknown JSON fields, live intent and game-thread lens settings without projection overrides")
