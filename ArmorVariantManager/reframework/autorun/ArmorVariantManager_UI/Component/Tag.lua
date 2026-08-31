local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local Tag = {}
function Tag.new(d2d_api, colors, fonts)
    local component = {}
    function component:draw(label, x, y, maximum_x, variant)
        local font = fonts.tiny
        local text_width = font and font:measure(label) or 0
        local tag_width = text_width + 12
        if x + tag_width > maximum_x then return x, false end
        local is_global = variant == "global"
        local is_default = variant == "default"
        local fill = is_default and colors.tag_default_fill
            or is_global and colors.tag_global_fill or colors.tag_group_fill
        local text_color = is_default and colors.tag_default_text
            or is_global and colors.tag_global_text or colors.tag_group_text
        d2d_api.fill_rounded_rect(x, y + 4, tag_width, 18, 4, 4, fill)
        local text_x, text_y = Runtime.center_text(font, label, x, y + 4, tag_width, 18)
        text_y = text_y + 1
        Runtime.text(d2d_api, font, label, text_x, text_y, text_color)
        return x + tag_width + 4, true
    end
    function component:measure(label)
        local font = fonts.tiny
        local text_width = font and font:measure(label) or 0
        return text_width + 12
    end
    return component
end
return Tag
