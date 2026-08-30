local Runtime = {}

-- 读取鼠标位置，兼容不同 REFramework 版本的输入 API。
function Runtime.mouse_position()
    local custom_cursor = _G.__AVM_REFD2D_CURSOR_POSITION
    -- D2D 控件和自绘光标必须使用同一套表面局部坐标。
    -- PresentRectCursorPosition 是引擎坐标，窗口化/DPI 下可能超出 D2D 表面，
    -- 因此只作为没有自绘位置时的回退，不能覆盖已经累积的局部坐标。
    if _G.__AVM_REFD2D_INPUT_BLOCKED == true then
        -- 弹窗开启时优先使用实时真实鼠标位置，使自绘光标不再依赖相对移动累积。
        local real_ok, real_mouse = pcall(function() return imgui.get_mouse() end)
        if real_ok and real_mouse and type(real_mouse.x) == "number"
            and type(real_mouse.y) == "number" and real_mouse.x >= 0 and real_mouse.y >= 0 then
            return real_mouse.x, real_mouse.y
        end
        -- 真实坐标暂时不可用时，保留相对移动累积作为兼容回退。
        if type(custom_cursor) == "table" and type(custom_cursor.x) == "number"
            and type(custom_cursor.y) == "number" then
            return custom_cursor.x, custom_cursor.y
        end
    end

    -- 弹窗拦截期间优先读取 PresentRect 局部坐标。它由引擎按游戏渲染区域计算，
    -- 窗口模式下不会混入桌面偏移，也不会像 ScreenCursorPosition 那样被相对模式锁到中心。
    if _G.__AVM_REFD2D_INPUT_BLOCKED == true then
        local native_ok, native_mouse = pcall(function() return sdk.get_native_singleton("via.hid.Mouse") end)
        if native_ok and native_mouse then
            local point_ok, point = pcall(function()
                return sdk.call_native_func(native_mouse, sdk.find_type_definition("via.hid.Mouse"),
                    "get_PresentRectCursorPosition()")
            end)
            if point_ok and point then
                local x, y = point.x, point.y
                if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 then return x, y end
            end
        end
        -- 某些运行时无法提供 PresentRect 坐标时，退回到 InputBlocker 累积的相对移动。
        if type(custom_cursor) == "table" and type(custom_cursor.x) == "number"
            and type(custom_cursor.y) == "number" then
            return custom_cursor.x, custom_cursor.y
        end
    end

    local ok, mouse = pcall(function() return imgui.get_mouse() end)
    if ok and mouse then
        local x, y = mouse.x, mouse.y
        if type(x) == "number" and type(y) == "number" and x >= 0 and y >= 0 then
            return x, y
        end
    end
    -- 游戏系统光标隐藏时，ImGui 在部分版本可能返回无效位置；读取绝对鼠标坐标
    -- 作为自绘光标的回退，不重新启用系统光标，也不使用相对移动量。
    local native_ok, native_mouse = pcall(function() return sdk.get_native_singleton("via.hid.Mouse") end)
    if native_ok and native_mouse then
        local point_ok, point = pcall(function()
            return sdk.call_native_func(native_mouse, sdk.find_type_definition("via.hid.Mouse"),
                "get_ScreenCursorPosition()")
        end)
        if point_ok and point then
            local x, y = point.x, point.y
            if type(x) == "number" and type(y) == "number" then return x, y end
        end
    end
    return -1, -1
end

-- 判断鼠标是否位于矩形区域。
function Runtime.point_in_rect(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

-- 安全读取鼠标按下状态。
function Runtime.is_mouse_down()
    local ok, value = pcall(function() return imgui.is_mouse_down(0) end)
    return ok and value or false
end

-- 安全读取鼠标点击状态。
function Runtime.is_mouse_clicked()
    local ok, value = pcall(function() return imgui.is_mouse_clicked(0) end)
    return ok and value or false
end

-- 检测真实鼠标是否仍位于游戏 D2D 表面内，不能使用自绘光标的累积坐标。
function Runtime.real_mouse_inside_surface()
    local size_ok, width, height = pcall(function()
        if d2d and d2d.surface_size then return d2d.surface_size() end
        return nil, nil
    end)
    if not size_ok or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return true
    end

    local mouse_ok, mouse = pcall(function() return imgui.get_mouse() end)
    if mouse_ok and mouse and type(mouse.x) == "number" and type(mouse.y) == "number" then
        return mouse.x >= 0 and mouse.y >= 0 and mouse.x <= width and mouse.y <= height
    end

    -- 某些运行时没有有效的 ImGui 鼠标坐标时，保守保持显示，避免误隐藏光标。
    return true
end

-- 绘制文本，避免字体尚未初始化时触发 D2D 错误。
function Runtime.text(d2d_api, font, value, x, y, color)
    if font and value ~= nil then
        d2d_api.text(font, tostring(value), x, y, color)
    end
end

-- 按字体实际宽度拆分 UTF-8 文本，供窄面板中的提示与说明复用。
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

-- 根据字体的实际高度计算文本垂直居中位置。
function Runtime.center_text(font, value, x, y, w, h)
    local text_w, text_h = 0, 0
    if font then text_w, text_h = font:measure(tostring(value)) end
    return x + math.max(0, (w - text_w) / 2), y + math.max(0, (h - text_h) / 2)
end

return Runtime
