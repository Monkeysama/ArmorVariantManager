local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local Button = {}
function Button.new(d2d_api, colors, fonts)
    local component = {}
    function component:draw(label, x, y, w, h, selected, state, text_font, disabled)
        local mx, my = Runtime.mouse_position()
        local hovered = not disabled and Runtime.point_in_rect(mx, my, x, y, w, h)
        local dragging = false
        local fill = disabled and colors.panel or selected and colors.accent_dark or colors.panel_alt
        if hovered then
            fill = selected and 0xFF2D6472 or 0xFF303B4A
        end
        d2d_api.fill_rounded_rect(x, y, w, h, 5, 5, fill)
        d2d_api.outline_rect(x, y, w, h, 1, disabled and colors.border or hovered and colors.accent or colors.border)
        local font = text_font or fonts.body
        local text_x, text_y = Runtime.center_text(font, label, x, y, w, h)
        Runtime.text(d2d_api, font, label, text_x, text_y,
            disabled and colors.disabled or selected and colors.text or colors.muted)
        return not disabled and Runtime.is_mouse_clicked() and hovered
    end
    return component
end
return Button
