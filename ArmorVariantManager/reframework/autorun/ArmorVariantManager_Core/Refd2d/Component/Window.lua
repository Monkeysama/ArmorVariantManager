local Runtime = require("ArmorVariantManager_Core.Refd2d.Component.Runtime")

local Window = {}

-- 创建支持标题栏和四周边沿拖动的窗口组件。
function Window.new()
    local component = {
        dragging = false,
        offset_x = 0,
        offset_y = 0
    }

    -- 限制窗口位置，确保窗口不会完全离开屏幕。
    function component:clamp(x, y, sw, sh, w, h)
        local margin = 24
        local max_x = math.max(margin, sw - w - margin)
        local max_y = math.max(margin, sh - h - margin)
        return math.max(margin, math.min(x, max_x)), math.max(margin, math.min(y, max_y))
    end

    -- 更新窗口拖拽状态，并返回本帧窗口坐标。
    function component:update(mx, my, x, y, w, h, sw, sh, excluded_rects)
        if self.dragging then
            if Runtime.is_mouse_down() then
                x = mx - self.offset_x
                y = my - self.offset_y
                x, y = self:clamp(x, y, sw, sh, w, h)
            else
                self.dragging = false
            end
            return x, y
        end

        local header = Runtime.point_in_rect(mx, my, x + 6, y + 6, w - 12, 58)
        local edge = 8
        local in_edge = Runtime.point_in_rect(mx, my, x, y, w, edge)
            or Runtime.point_in_rect(mx, my, x, y + h - edge, w, edge)
            or Runtime.point_in_rect(mx, my, x, y, edge, h)
            or Runtime.point_in_rect(mx, my, x + w - edge, y, edge, h)
        local excluded = false
        for _, rect in ipairs(excluded_rects or {}) do
            if Runtime.point_in_rect(mx, my, rect.x, rect.y, rect.w, rect.h) then
                excluded = true
                break
            end
        end
        if Runtime.is_mouse_clicked() and (header or in_edge) and not excluded then
            self.dragging = true
            self.offset_x = mx - x
            self.offset_y = my - y
        end
        return x, y
    end

    return component
end

return Window
