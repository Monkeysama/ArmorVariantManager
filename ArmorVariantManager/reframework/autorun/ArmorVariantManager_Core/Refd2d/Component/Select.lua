local Runtime = require("ArmorVariantManager_Core.Refd2d.Component.Runtime")

local Select = {}

-- 创建 Element Plus 风格的下拉选择器，选项面板在当前 D2D 面板内容之后绘制。
function Select.new(d2d_api, colors, fonts)
    local component = {
        open_key = nil,
        active_request = nil,
        changed_key = nil,
        changed_value = nil,
        changed_index = nil
    }

    -- 注册本帧的选择器区域，并返回上一帧点击选项产生的变化。
    function component:draw(options)
        options = options or {}
        local values = options.values or {}
        local key = options.key or tostring(options.x) .. ":" .. tostring(options.y)
        local x, y = options.x, options.y
        local w, h = options.w, options.h
        local mx, my = Runtime.mouse_position()
        local hovered = not options.disabled and Runtime.point_in_rect(mx, my, x, y, w, h)
        local selected_index = math.max(1, math.min(#values, options.selected_index or 1))
        local labels = options.labels or values
        local selected_value = labels[selected_index] or options.placeholder or ""
        local fill = options.disabled and colors.panel or hovered and 0xFF303B4A or colors.panel_alt
        d2d_api.fill_rounded_rect(x, y, w, h, 5, 5, fill)
        d2d_api.outline_rect(x, y, w, h, 1,
            options.disabled and colors.border or self.open_key == key and colors.accent or
                hovered and colors.accent or colors.border)
        local font = options.font or fonts.small
        local text_x, text_y = Runtime.center_text(font, selected_value, x + 8, y, w - 28, h)
        Runtime.text(d2d_api, font, selected_value, text_x, text_y,
            options.disabled and colors.disabled or colors.text)
        local arrow_x = x + w - 16
        local arrow_y = y + h / 2
        d2d_api.line(arrow_x - 4, arrow_y - 2, arrow_x, arrow_y + 2, 1, colors.muted)
        d2d_api.line(arrow_x, arrow_y + 2, arrow_x + 4, arrow_y - 2, 1, colors.muted)

        if hovered and Runtime.is_mouse_clicked() then
            self.open_key = self.open_key == key and nil or key
            self.active_request = nil
        elseif self.open_key == key then
            self.active_request = {
                key = key, x = x, y = y, w = w, h = h, values = values, labels = labels,
                selected_index = selected_index, placeholder = options.placeholder,
                on_change = options.on_change, max_visible = options.max_visible or 16
            }
        end
        if self.changed_key == key then
            local changed_value, changed_index = self.changed_value, self.changed_index
            self.changed_key, self.changed_value, self.changed_index = nil, nil, nil
            return true, changed_value, changed_index
        end
        return false, selected_value, selected_index
    end

    -- 在变身面板最后绘制下拉选项，确保选项显示在规则内容上层。
    function component:draw_popup()
        local request = self.active_request
        if not request or self.open_key ~= request.key then
            self.active_request = nil
            return
        end
        local values = request.values
        local mx, my = Runtime.mouse_position()
        local row_h = 30
        local max_visible = math.max(1, math.min(request.max_visible, #values))
        local popup_h = max_visible * row_h + 8
        local popup_y = request.y + request.h + 4
        local sw, sh = d2d_api.surface_size()
        if sh and popup_y + popup_h > sh - 8 then popup_y = request.y - popup_h - 4 end
        d2d_api.fill_rounded_rect(request.x, popup_y, request.w, popup_h, 5, 5, colors.panel)
        d2d_api.outline_rect(request.x, popup_y, request.w, popup_h, 1, colors.accent)
        local start_index = 1
        local end_index = math.min(#values, max_visible)
        for index = start_index, end_index do
            local row_y = popup_y + 4 + (index - start_index) * row_h
            local hovered = Runtime.point_in_rect(mx, my, request.x, row_y, request.w, row_h)
            if hovered then d2d_api.fill_rect(request.x + 2, row_y, request.w - 4, row_h, colors.accent_dark) end
            local text_x, text_y = Runtime.center_text(fonts.small, request.labels[index],
                request.x + 10, row_y, request.w - 20, row_h)
            Runtime.text(d2d_api, fonts.small, request.labels[index], text_x, text_y,
                index == request.selected_index and colors.accent or colors.muted)
            if hovered and Runtime.is_mouse_clicked() then
                self.changed_key = request.key
                self.changed_value = values[index]
                self.changed_index = index
                self.open_key = nil
                if request.on_change then request.on_change(values[index], index) end
                self.active_request = nil
                return
            end
        end
        local inside_field = Runtime.point_in_rect(mx, my, request.x, request.y, request.w, request.h)
        local inside_popup = Runtime.point_in_rect(mx, my, request.x, popup_y, request.w, popup_h)
        if Runtime.is_mouse_clicked() and not inside_field and not inside_popup then
            self.open_key = nil
            self.active_request = nil
        end
    end

    return component
end

return Select
