local Runtime = require("ArmorVariantManager_UI.Component.Runtime")

local InputNumber = {}

-- 创建数字输入控件，左右按钮和数值共用一个边框。
function InputNumber.new(d2d_api, colors, fonts)
    local component = {}

    function component:draw(value, x, y, w, h, minimum, maximum, step)
        value = tonumber(value) or minimum or 0
        minimum = minimum or 0
        maximum = maximum or math.huge
        step = step or 1
        local mx, my = Runtime.mouse_position()
        local hovered = Runtime.point_in_rect(mx, my, x, y, w, h)
        d2d_api.fill_rounded_rect(x, y, w, h, 5, 5,
            hovered and 0xFF303B4A or colors.panel_alt)
        d2d_api.outline_rect(x, y, w, h, 1, hovered and colors.accent or colors.border)
        -- 缩窄左右步进按钮，扩大中间数值显示区，保持网页数字输入框的视觉比例。
        local button_w = math.min(24, math.max(18, w * 0.20))
        local changed, next_value = false, value
        if Runtime.is_mouse_clicked() and Runtime.point_in_rect(mx, my, x, y, button_w, h) then
            next_value = math.max(minimum, value - step)
            changed = next_value ~= value
        elseif Runtime.is_mouse_clicked() and Runtime.point_in_rect(mx, my,
            x + w - button_w, y, button_w, h) then
            next_value = math.min(maximum, value + step)
            changed = next_value ~= value
        end
        d2d_api.line(x + button_w, y + 4, x + button_w, y + h - 4, 1, colors.border)
        d2d_api.line(x + w - button_w, y + 4, x + w - button_w, y + h - 4, 1, colors.border)
        local minus_x, minus_y = Runtime.center_text(fonts.small, "-", x, y, button_w, h)
        local plus_x, plus_y = Runtime.center_text(fonts.small, "+", x + w - button_w, y, button_w, h)
        Runtime.text(d2d_api, fonts.small, "-", minus_x, minus_y, colors.muted)
        Runtime.text(d2d_api, fonts.small, "+", plus_x, plus_y, colors.muted)
        local display = tostring(next_value)
        local value_x, value_y = Runtime.center_text(fonts.small, display,
            x + button_w, y, w - button_w * 2, h)
        Runtime.text(d2d_api, fonts.small, display, value_x, value_y, colors.text)
        return changed, next_value
    end

    return component
end

return InputNumber


