local WindowsInput = require("ArmorVariantManager_UI.Service.WindowsInput")
local EngineMouse = require("ArmorVariantManager_UI.Service.EngineMouse")
local Runtime = {}
Runtime.last_click_sequence = nil
function Runtime.pointer_source()
    local state=WindowsInput.state()
    if state then return state.foreground and "windows" or "unfocused" end
    return _G.__AVM_REFD2D_INPUT_BLOCKED and "engine" or "imgui"
end
function Runtime.reset_pointer()
    local state = WindowsInput.state()
    Runtime.last_click_sequence = state and state.click_sequence or nil
    Runtime.frame_clicked = false
end
function Runtime.begin_frame()
    local state = WindowsInput.state()
    if state then
        Runtime.frame_clicked = Runtime.last_click_sequence ~= nil
            and state.click_sequence ~= Runtime.last_click_sequence and state.foreground == true
        Runtime.last_click_sequence = state.click_sequence
    else Runtime.frame_clicked = nil end
end
function Runtime.surface_size(api)
    local w,h = WindowsInput.surface_size()
    if w then return w,h end
    return api.surface_size()
end
Runtime.key_down = WindowsInput.key_down
Runtime.first_key = WindowsInput.first_key
Runtime.refresh_input = WindowsInput.refresh
Runtime.ui_scale = 1
function Runtime.set_ui_scale(scale)
    Runtime.ui_scale = math.max(0.01, tonumber(scale) or 1)
end
function Runtime.to_logical_point(x, y)
    return x / Runtime.ui_scale, y / Runtime.ui_scale
end

-- ============================================================================
--  崛起版本适配：引擎光标（via.hid.Mouse）
-- ----------------------------------------------------------------------------
--  为什么需要它：
--    游戏使用「相对鼠标」时，Windows 只会把光标锁在窗口中心反复发 WM_MOUSEMOVE，
--    因此 REFramework 暴露给 Lua 的 imgui.get_mouse() 会长时间停留在窗口中心，
--    用它当 UI 光标会导致鼠标完全点不动。
--    新版 UI 打开时会通过 InputBlocker 把 via.hid.Mouse 切换到「绝对坐标」模式，
--    此时引擎自己记录的光标位置才是正确的，所以接管输入期间以它为准。
--  （via.hid.Mouse 在崛起版本确认存在：EMV Engine 等插件同样在使用它。）
-- ============================================================================
local engine_mouse_singleton = nil
local engine_mouse_typedef = nil
local engine_mouse_probed_at = -1
function Runtime.engine_mouse_position()
    if not engine_mouse_singleton then
        -- 只缓存「成功」；失败时最多每秒重试一次，避免启动早期探测失败被永久缓存
        local now = os.clock()
        if engine_mouse_probed_at >= 0 and now - engine_mouse_probed_at < 1.0 then
            return nil, nil
        end
        engine_mouse_probed_at = now
        local ok_single, singleton = pcall(function() return sdk.get_native_singleton("via.hid.Mouse") end)
        local ok_type, typedef = pcall(function() return sdk.find_type_definition("via.hid.Mouse") end)
        if ok_single and ok_type and singleton and typedef then
            engine_mouse_singleton = singleton
            engine_mouse_typedef = typedef
        end
    end
    if not engine_mouse_singleton then return nil, nil end
    return EngineMouse.read(function(method_name)
        return pcall(function()
            return sdk.call_native_func(engine_mouse_singleton, engine_mouse_typedef, method_name)
        end)
    end, function()
        local size = imgui.get_display_size()
        return size.x or size[1], size.y or size[2]
    end)
end

function Runtime.raw_mouse_position()
    local state = WindowsInput.state()
    if state and state.foreground then return state.cursor_x, state.cursor_y end
    if _G.__AVM_REFD2D_INPUT_BLOCKED == true then
        local engine_x, engine_y = Runtime.engine_mouse_position()
        if engine_x and engine_y then return engine_x, engine_y end
    end
    local ok, mouse = pcall(function() return imgui.get_mouse() end)
    if ok and mouse then
        local x, y = EngineMouse.coordinates(mouse)
        if x then return x, y end
    end
    return -1, -1
end

function Runtime.mouse_position()
    local x,y = Runtime.raw_mouse_position()
    x,y = Runtime.to_logical_point(x,y)
    local c=Runtime.input_clip
    if c and (x<c.x or y<c.y or x>c.x+c.w or y>c.y+c.h) then return -1,-1 end
    return x,y
end

function Runtime.point_in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end
function Runtime.is_mouse_down()
    local state = WindowsInput.state()
    if state then return state.foreground == true and state.mouse_down == true end
    local ok, value = pcall(function() return imgui.is_mouse_down(0) end)
    return ok and value or false
end
function Runtime.is_mouse_clicked()
    if Runtime.frame_clicked ~= nil then return Runtime.frame_clicked end
    local ok, value = pcall(function() return imgui.is_mouse_clicked(0) end)
    return ok and value or false
end
function Runtime.real_mouse_inside_surface()
    local size_ok, width, height = pcall(function()
        if d2d and d2d.surface_size then return Runtime.surface_size(d2d) end
        return nil, nil
    end)
    if not size_ok or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return true
    end
    -- 与 raw_mouse_position / d2d.surface_size 一样都是物理像素，保持一致
    local mouse_x, mouse_y = Runtime.raw_mouse_position()
    if type(mouse_x) == "number" and type(mouse_y) == "number" then
        return mouse_x >= 0 and mouse_y >= 0 and mouse_x <= width and mouse_y <= height
    end
    return true
end
function Runtime.text(d2d_api, font, value, x, y, color)
    if font and value ~= nil then
        d2d_api.text(font, tostring(value), x, y, color)
    end
end
function Runtime.wrap_text(font, value, max_width)
    local text = tostring(value or "")
    if not font or max_width <= 0 or text == "" then return { text } end
    local lines = {}
    local line = ""
    for character in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if character == "\n" then
            table.insert(lines, line)
            line = ""
        else
            local candidate = line .. character
            local candidate_width = font:measure(candidate)
            if line ~= "" and candidate_width > max_width then
                table.insert(lines, line)
                line = character == " " and "" or character
            else
                line = candidate
            end
        end
    end
    if line ~= "" or #lines == 0 then table.insert(lines, line) end
    return lines
end
function Runtime.center_text(font, value, x, y, w, h)
    local text_w, text_h = 0, 0
    if font then text_w, text_h = font:measure(tostring(value)) end
    return x + math.max(0, (w - text_w) / 2), y + math.max(0, (h - text_h) / 2)
end
return Runtime
