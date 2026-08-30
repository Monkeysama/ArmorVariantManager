local Runtime = require("ArmorVariantManager_Core.Refd2d.Component.Runtime")

local Slider = {}

-- 创建可拖动的数值滑动条，供设置页复用。
function Slider.new(d2d_api, colors, fonts)
    local component = {
        dragging = false
    }

    function component:draw(label, value, x, y, w, minimum, maximum, step, formatter)
        local mx, my = Runtime.mouse_position()
        local label_width = math.min(210, math.max(130, w * 0.42))
        local track_x = x + label_width
        local track_w = math.max(80, w - label_width)
        local track_y = y + 13
        local track_h = 5
        local range = math.max(0.0001, maximum - minimum)
        local ratio = math.max(0, math.min(1, (value - minimum) / range))
        local thumb_x = track_x + track_w * ratio
        local hovered = Runtime.point_in_rect(mx, my, track_x - 8, y, track_w + 16, 30)

        if Runtime.is_mouse_clicked() and hovered then self.dragging = true end
        if not Runtime.is_mouse_down() then self.dragging = false end

        local changed = false
        if self.dragging and Runtime.is_mouse_down() then
            local next_ratio = math.max(0, math.min(1, (mx - track_x) / track_w))
            local next_value = minimum + next_ratio * range
            if step and step > 0 then
                next_value = math.floor(next_value / step + 0.5) * step
            end
            next_value = math.max(minimum, math.min(maximum, next_value))
            changed = next_value ~= value
            value = next_value
            ratio = math.max(0, math.min(1, (value - minimum) / range))
            thumb_x = track_x + track_w * ratio
        end

        Runtime.text(d2d_api, fonts.body, label, x, y + 4, colors.text)
        d2d_api.fill_rounded_rect(track_x, track_y, track_w, track_h, 3, 3, colors.panel_alt)
        d2d_api.fill_rounded_rect(track_x, track_y, math.max(0, thumb_x - track_x), track_h,
            3, 3, colors.accent_dark)
        d2d_api.fill_rounded_rect(thumb_x - 7, track_y - 6, 14, 17, 5, 5,
            self.dragging or hovered and colors.accent or colors.border)

        local display_value = formatter and formatter(value) or tostring(value)
        local value_x, value_y = Runtime.center_text(fonts.small, display_value,
            track_x, y, track_w, 30)
        Runtime.text(d2d_api, fonts.small, display_value, value_x, value_y, colors.muted)
        return changed, value
    end

    return component
end

return Slider
