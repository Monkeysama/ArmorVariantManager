local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local Input = {}
local function measure_text_width(font, value)
    if not font or not value or value == "" then return 0 end
    local suffix = "."
    return math.max(0, font:measure(value .. suffix) - font:measure(suffix))
end
function Input.new(d2d_api, colors, fonts)
    local component = {}
    function component:draw(value, placeholder, x, y, w, h, focused, show_clear, composition)
        local mouse_x, mouse_y = Runtime.mouse_position()
        local hovered = Runtime.point_in_rect(mouse_x, mouse_y, x, y, w, h)
        local has_value = value ~= nil and value ~= ""
        local can_clear = show_clear ~= false
        local clear_width = can_clear and has_value and 28 or 0
        local content_right = x + w - clear_width
        d2d_api.fill_rounded_rect(x, y, w, h, 5, 5, colors.panel_alt)
        d2d_api.outline_rect(x, y, w, h, 1,
            focused and colors.accent or hovered and colors.accent or colors.border)
        local committed_value = has_value and value or ""
        local display_value = has_value and value or not focused and placeholder or ""
        local text_color = has_value and colors.text or colors.placeholder or colors.muted
        local text_x = x + 9
        local _, text_y = Runtime.center_text(fonts.tiny, display_value,
            text_x, y, 0, h)
        Runtime.text(d2d_api, fonts.tiny, display_value, text_x, text_y, text_color)
        if focused and composition and composition ~= "" then
            local committed_width = measure_text_width(fonts.tiny, committed_value)
            local composition_x = math.min(content_right - 6, text_x + committed_width)
            Runtime.text(d2d_api, fonts.tiny, composition, composition_x, text_y, colors.accent)
            local composition_width = measure_text_width(fonts.tiny, composition)
            d2d_api.line(composition_x, y + h - 6,
                math.min(content_right - 6, composition_x + composition_width), y + h - 6, 1, colors.accent)
            display_value = committed_value .. composition
        end
        if focused then
            local text_width = measure_text_width(fonts.tiny, display_value)
            local caret_x = math.min(content_right - 6, text_x + text_width + 1)
            local pulse = (math.sin(os.clock() * math.pi * 2) + 1) / 2
            local alpha = math.floor(72 + pulse * 183)
            local caret_color = alpha * 0x1000000 + (colors.accent % 0x1000000)
            d2d_api.line(caret_x, y + 6, caret_x, y + h - 6, 1, caret_color)
        end
        local clear_clicked = false
        if can_clear and has_value then
            local clear_x = x + w - clear_width
            local clear_text_x, clear_text_y = Runtime.center_text(fonts.small, "x",
                clear_x, y, clear_width, h)
            Runtime.text(d2d_api, fonts.small, "x", clear_text_x, clear_text_y,
                hovered and colors.text or colors.muted)
            clear_clicked = Runtime.is_mouse_clicked()
                and Runtime.point_in_rect(mouse_x, mouse_y, clear_x, y, clear_width, h)
        end
        return {
            focused = Runtime.is_mouse_clicked() and hovered and not clear_clicked,
            clear = clear_clicked,
            hovered = hovered,
            rect = { x = x, y = y, w = w, h = h }
        }
    end
    return component
end
return Input
