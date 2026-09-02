local Runtime = {}
Runtime.ui_scale = 1
Runtime.frame_input = nil
function Runtime.set_ui_scale(scale)
    Runtime.ui_scale = math.max(0.01, tonumber(scale) or 1)
end
function Runtime.to_logical_point(x, y)
    return x / Runtime.ui_scale, y / Runtime.ui_scale
end
function Runtime.raw_mouse_position()
    if Runtime.frame_input then
        return Runtime.frame_input.raw_x, Runtime.frame_input.raw_y
    end
    local ok, mouse = pcall(function() return imgui.get_mouse() end)
    if ok and mouse and type(mouse.x) == "number" and type(mouse.y) == "number" then
        return mouse.x, mouse.y
    end
    return -1, -1
end
function Runtime.mouse_position()
    if Runtime.frame_input then
        return Runtime.frame_input.mouse_x, Runtime.frame_input.mouse_y
    end
    local custom_cursor = _G.__AVM_REFD2D_CURSOR_POSITION
    if _G.__AVM_REFD2D_INPUT_BLOCKED == true then
        local real_ok, real_mouse = pcall(function() return imgui.get_mouse() end)
        if real_ok and real_mouse and type(real_mouse.x) == "number"
            and type(real_mouse.y) == "number" and real_mouse.x >= 0 and real_mouse.y >= 0 then
            return Runtime.to_logical_point(real_mouse.x, real_mouse.y)
        end
        if type(custom_cursor) == "table" and type(custom_cursor.x) == "number"
            and type(custom_cursor.y) == "number" then
            return Runtime.to_logical_point(custom_cursor.x, custom_cursor.y)
        end
    end
    if _G.__AVM_REFD2D_INPUT_BLOCKED == true then
        local native_ok, native_mouse = pcall(function() return sdk.get_native_singleton("via.hid.Mouse") end)
        if native_ok and native_mouse then
            local point_ok, point = pcall(function()
                return sdk.call_native_func(native_mouse, sdk.find_type_definition("via.hid.Mouse"),
                    "get_PresentRectCursorPosition()")
            end)
            if point_ok and point then
                local x, y = point.x, point.y
                if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 then return Runtime.to_logical_point(x, y) end
            end
        end
        if type(custom_cursor) == "table" and type(custom_cursor.x) == "number"
            and type(custom_cursor.y) == "number" then
            return Runtime.to_logical_point(custom_cursor.x, custom_cursor.y)
        end
    end
    local ok, mouse = pcall(function() return imgui.get_mouse() end)
    if ok and mouse then
        local x, y = mouse.x, mouse.y
        if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 then
            return Runtime.to_logical_point(x, y)
        end
    end
    local native_ok, native_mouse = pcall(function() return sdk.get_native_singleton("via.hid.Mouse") end)
    if native_ok and native_mouse then
        local point_ok, point = pcall(function()
            return sdk.call_native_func(native_mouse, sdk.find_type_definition("via.hid.Mouse"),
                "get_ScreenCursorPosition()")
        end)
        if point_ok and point then
            local x, y = point.x, point.y
            if type(x) == "number" and type(y) == "number" then return Runtime.to_logical_point(x, y) end
        end
    end
    return -1, -1
end
function Runtime.begin_input_frame()
    Runtime.frame_input = nil
    local raw_x, raw_y = Runtime.raw_mouse_position()
    local mouse_x, mouse_y = Runtime.mouse_position()
    local down_ok, down = pcall(function() return imgui.is_mouse_down(0) end)
    local clicked_ok, clicked = pcall(function() return imgui.is_mouse_clicked(0) end)
    Runtime.frame_input = {
        raw_x = raw_x,
        raw_y = raw_y,
        mouse_x = mouse_x,
        mouse_y = mouse_y,
        mouse_down = down_ok and down == true or false,
        mouse_clicked = clicked_ok and clicked == true or false
    }
end
function Runtime.end_input_frame()
    Runtime.frame_input = nil
end
function Runtime.point_in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end
function Runtime.is_mouse_down()
    if Runtime.frame_input then return Runtime.frame_input.mouse_down end
    local ok, value = pcall(function() return imgui.is_mouse_down(0) end)
    return ok and value or false
end
function Runtime.is_mouse_clicked()
    if Runtime.frame_input then return Runtime.frame_input.mouse_clicked end
    local ok, value = pcall(function() return imgui.is_mouse_clicked(0) end)
    return ok and value or false
end
function Runtime.real_mouse_inside_surface()
    local size_ok, width, height = pcall(function()
        if d2d and d2d.surface_size then return d2d.surface_size() end
        return nil, nil
    end)
    if not size_ok or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return true
    end
    local mouse_x, mouse_y = Runtime.raw_mouse_position()
    if type(mouse_x) == "number" and type(mouse_y) == "number"
        and mouse_x >= 0 and mouse_y >= 0 then
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
