package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local callbacks = {}
re = { on_frame = function(fn) callbacks[#callbacks + 1] = fn end, on_script_reset = function() end }
imgui = { get_mouse = function() return { x = -1, y = -1 } end,
    is_mouse_clicked = function() return false end, is_mouse_down = function() return false end }
local UI = require("ArmorVariantManager_Core.UI.VariantManagerUI")
local languages = require("ArmorVariantManager_Core.Localization")
local Preview = require("ArmorVariantManager_Core.Games.Wilds.PortraitPreview")
local Slider = require("ArmorVariantManager_UI.Component.Slider")
local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local Panel = require("ArmorVariantManager_UI.Component.Panel")
local width, height, lang = 1920, 1080, "zh"
local drawn_backgrounds, rectangle, request = {}, nil, nil
local saved, text_records, button_records = 0, {}, {}
local function font(size)
    return { measure = function(_, value)
        local measured = 0
        for _, code in utf8.codes(value) do measured = measured + (code < 128 and size * 0.53 or size) end
        return measured, size
    end }
end
local ui = UI.new({ config = { new_ui_enabled = true }, get_context = function() return {} end,
    -- UI 构造测试不应要求 REFramework SDK；预览状态机仍使用真实实现和离线适配器。
    portrait_preview = Preview.new({ adapter = {}, should_show = function() return true end }),
    save_settings = function() saved = saved + 1 end,
    translate = function(key) return assert(languages[lang][key], key) end })
ui.ready, ui.visible = true, true
ui.fonts = { title = font(24), body = font(18), small = font(16), tiny = font(13) }
ui.d2d = { surface_size = function() return width, height end, fill_rect = function() end,
    push_transform = function() end, pop_transform = function() end,
    fill_rounded_rect = function(x, y, w, h, _, _, color)
        drawn_backgrounds[#drawn_backgrounds + 1] = { x = x, y = y, w = w, h = h, color = color }
    end,
    outline_rect = function() end, text = function(f, value, x, y)
        local measured, line_height = f:measure(value)
        text_records[#text_records + 1] = { value, x, y, measured, line_height }
    end,
    line = function() end }
ui.panel = Panel.new(ui.d2d, ui.colors)
ui.button = { draw = function(_, label, x, y, w, h)
    button_records[#button_records + 1] = { label, x, y, w, h }
    return label == request
end }
local function text_record(value)
    for _, item in ipairs(text_records) do if item[1] == value then return item end end
    error("Missing text: " .. value)
end
local function aligned_chrome(p)
    local title = text_record(languages[lang].preview_title)
    local closes = {}
    for _, item in ipairs(button_records) do if item[1] == "×" then closes[#closes + 1] = item end end
    assert(#closes == 2 and closes[1][3] == closes[2][3]
        and closes[1][4] == closes[2][4] and closes[1][5] == closes[2][5],
        "Preview and editor close buttons must share a row and size")
    assert(math.abs(title[3] + title[5] / 2 - closes[1][3] - closes[1][5] / 2) < 0.0001,
        "Preview title must be vertically centered with its close button")
    assert(title[2] + title[4] + 8 <= closes[1][2], "Preview title must not touch its close button")
    assert(rectangle.y / ui.window_scale >= closes[1][3] + closes[1][5],
        "The GPU image must not cover the close button")
    local status = text_record(languages[lang].preview_live)
    local footer_center = p.y + p.h - 24
    assert(math.abs(status[3] + status[5] / 2 - footer_center) < 0.0001,
        "Preview status must align with the editor footer")
    for _, item in ipairs(button_records) do
        if item[1] == languages[lang].d2d_parts_tab then
            assert(math.abs(item[3] + item[5] / 2 - footer_center) < 0.0001,
                "Footer buttons must use the same center line as the footer text")
        end
    end
end
ui.portrait_preview.set_enabled(true)
ui.portrait_preview.status = "preview_live"
ui.portrait_preview.set_rectangle = function(value) rectangle = value end
for _, language in ipairs({ "zh", "en" }) do
    lang = language
    for _, spec in ipairs({ { 1920, 1080, 1 }, { 1920, 1080, 1.25 }, { 1366, 768, 1 }, { 1280, 720, 0.8 }, { 1100, 768, 1 } }) do
        width, height, ui.window_scale = table.unpack(spec)
        ui.window_x, ui.window_y, drawn_backgrounds, rectangle = nil, nil, {}, nil
        text_records, button_records = {}, {}
        ui:draw()
        assert(rectangle, "Preview rectangle must be submitted")
        assert(rectangle.x >= 0 and rectangle.y >= 0)
        assert(rectangle.x + rectangle.w <= width and rectangle.y + rectangle.h <= height)
        local p, editor = drawn_backgrounds[1], drawn_backgrounds[2]
        assert(math.abs(rectangle.h / ui.window_scale - (p.h - 112)) < 0.0001, "Use the full available card height")
        assert(math.abs(rectangle.w / ui.window_scale - (p.w - 24)) < 0.0001, "Use the card width; camera projection preserves proportions")
        assert(rectangle.x + rectangle.w < ui.window_x * ui.window_scale, "Keep preview left of editor")
        assert(math.abs(p.x + p.w - ui.window_x) < 0.0001, "Preview must touch the editor without a gap")
        assert(p.y == editor.y and p.h == editor.h, "Preview and editor stay vertically aligned")
        assert(p.color == ui.colors.panel and editor.color == ui.colors.background,
            "Restore the original preview panel color without changing the editor")
        assert(math.abs(rectangle.y / ui.window_scale - p.y - 64) < 0.0001,
            "Keep the image below the aligned header")
        assert(math.abs((rectangle.y + rectangle.h) / ui.window_scale - p.y - p.h + 48) < 0.0001,
            "Keep the image above the aligned footer")
        aligned_chrome(p)
        ui.window_x, ui.window_y = ui.window_x - 40, ui.window_y + 10
        drawn_backgrounds, rectangle, text_records, button_records = {}, nil, {}, {}
        ui:draw()
        p = drawn_backgrounds[1]
        aligned_chrome(p)
        assert(math.abs(p.x + p.w - ui.window_x) < 0.0001, "Moved preview must stay attached")
        assert(math.abs(rectangle.x - (p.x + 12) * ui.window_scale) < 0.0001,
            "Moved image must use the current physical rectangle")
    end
end
-- 网页宿主不能被同时打开的旧弹窗覆盖相机租约。
local web_rectangle = {x=0,y=0,w=330,h=360}
rectangle, drawn_backgrounds = web_rectangle, {}
ui.portrait_preview.set_host("reff")
ui:draw()
assert(rectangle == web_rectangle and drawn_backgrounds[1].color == ui.colors.background,
    "Legacy window must not overwrite the REFF camera lease or draw a second preview card")
ui.portrait_preview.set_host("legacy")
ui:draw()
assert(rectangle ~= web_rectangle, "Legacy card must resume after REFF releases the preview")
-- 长状态按完整文本块居中，最窄预览也不能越过底边。
for _, language in ipairs({ "zh", "en" }) do
    lang = language
    for _, status in ipairs({ "preview_waiting", "preview_error", "preview_restore_error" }) do
        ui.portrait_preview.status = status
        text_records, button_records = {}, {}
        ui:draw_portrait_preview(24, 24, 198, 600, 1)
        for _, item in ipairs(text_records) do
            assert(item[2] >= 24 and item[2] + item[4] <= 222 and item[3] + item[5] <= 624,
                "Wrapped preview status must fit: " .. item[1])
        end
    end
end
ui.portrait_preview.status = "preview_live"
width, height, ui.window_scale = 1024, 768, 1
rectangle, ui.window_x, ui.window_y = nil, nil, nil
ui:draw(); assert(not rectangle and not ui.preview_has_space, "Narrow screens must not keep stale drawing")
request = "×"; ui:draw_portrait_preview(24, 24, 240, 600, 1)
assert(not ui.portrait_preview.enabled, "Close button records disabled intent")
assert(ui.deps.config.portrait_enabled == false, "Card close persists disabled preference")
assert(#callbacks == 1, "Preview has one game callback independent of scanner")

-- 设置页实际滑块交互：双语布局、实时意图、全局保存、重置以及原常规入口。
ui.sliders = {}
for _, key in ipairs({ "portrait_distance", "portrait_horizontal", "portrait_vertical", "portrait_light_intensity",
    "scan_interval", "body_id_ttl", "scanner_batch_size" }) do
    ui.sliders[key] = Slider.new(ui.d2d, ui.colors, ui.fonts)
end
local mouse = { x = -1, y = -1, down = false, clicked = false }
imgui.get_mouse = function() return mouse end
imgui.is_mouse_down = function() return mouse.down end
imgui.is_mouse_clicked = function() return mouse.clicked end
local function settings_frame(x, y, down, clicked, panel_width)
    Runtime.set_ui_scale(1)
    mouse.x, mouse.y, mouse.down, mouse.clicked = x, y, down == true, clicked == true
    Runtime.capture_input(); Runtime.begin_input_frame()
    ui:draw_settings_panel(0, 0, panel_width or 550, 518)
    Runtime.end_input_frame()
end
ui.deps.config.scan_interval, ui.deps.config.body_id_ttl, ui.deps.config.scanner_batch_size = 0.5, 1.0, 200
ui.deps.config.new_ui_key = 0x24
ui.preview_has_space = true
Runtime.reset_pending_input(); request = nil; settings_frame(-1, -1)
for _, language in ipairs({ "zh", "en" }) do
    lang = language
    request = languages[lang].preview_camera_tab; settings_frame(-1, -1)
    assert(ui.settings_section == "camera")
    request = nil
    local before = saved
    ui.portrait_preview.set_camera_settings({ extension = "retain" })
    settings_frame(458, 122, true, true); settings_frame(-1, -1)
    settings_frame(148, 174, true, true); settings_frame(-1, -1)
    settings_frame(458, 226, true, true); settings_frame(-1, -1)
    settings_frame(458, 278, true, true); settings_frame(-1, -1)
    assert(ui.deps.config.portrait_camera.light_intensity == 2)
    assert(saved == before + 4 and ui.deps.config.portrait_camera.distance == 6)
    assert(ui.deps.config.portrait_camera.horizontal == -1.5 and ui.deps.config.portrait_camera.vertical == 1.5)
    assert(ui.portrait_preview.camera_settings.extension == "retain")
    for _, fps in ipairs({60, 0, 30}) do
        local old_saved = saved
        request = fps == 0 and languages[lang].preview_full_speed or tostring(fps) .. " FPS"
        settings_frame(-1, -1)
        assert(ui.deps.config.portrait_camera.refresh_fps == fps and saved == old_saved + 1)
    end
    request = languages[lang].preview_camera_reset; settings_frame(-1, -1)
    assert(ui.deps.config.portrait_camera.distance == 1.5 and ui.deps.config.portrait_camera.horizontal == 0)
    assert(ui.deps.config.portrait_camera.light_intensity == 1)
    assert(ui.deps.config.portrait_camera.refresh_fps == 30)
    assert(ui.deps.config.portrait_camera.vertical == 0 and ui.deps.config.portrait_camera.extension == "retain")
    request = nil
    for _, panel_width in ipairs({ 430, 550 }) do
        text_records = {}; settings_frame(-1, -1, false, false, panel_width)
        for _, item in ipairs(text_records) do
            assert(item[2] >= 0 and item[2] + item[4] <= panel_width and item[3] >= 0 and item[3] + item[5] <= 518,
                "Camera settings text must fit: " .. item[1])
        end
    end
    request = languages[lang].d2d_settings_general; settings_frame(-1, -1)
    assert(ui.settings_section == "general", "Keep existing language/performance/hotkey controls reachable")
    request = nil
    for _, panel_width in ipairs({ 430, 550 }) do
        text_records = {}; settings_frame(-1, -1, false, false, panel_width)
        local labels = {}
        for _, item in ipairs(text_records) do
            assert(item[2] >= 0 and item[2] + item[4] <= panel_width and item[3] >= 0 and item[3] + item[5] <= 518,
                "General settings text must fit: " .. item[1])
            labels[item[1]] = true
        end
        for _, key in ipairs({ "d2d_settings_language", "d2d_settings_performance", "d2d_settings_shortcut" }) do
            assert(labels[languages[lang][key]], "Keep the General setting: " .. key)
        end
    end
end
request = languages[lang].preview_title; settings_frame(-1, -1)
assert(ui.portrait_preview.enabled and ui.settings_section == "camera", "Enabling preview reveals camera controls")
assert(ui.deps.config.portrait_enabled == true, "Settings toggle persists enabled preference")
local restored = UI.new({config=ui.deps.config, portrait_preview=Preview.new({adapter={},register=false}),
    save_settings=function() error("Restoring settings must not write configuration") end})
assert(restored.portrait_preview.enabled, "Global enabled preference survives UI recreation")
assert(restored.portrait_preview.camera_settings.refresh_fps == ui.portrait_preview.camera_settings.refresh_fps)
print("PASS: attached preview, original background and aligned header/footer, full-height card, physical viewport, Chinese/English/scales, camera sliders, save/reset, General tab and narrow-screen/close behavior")
