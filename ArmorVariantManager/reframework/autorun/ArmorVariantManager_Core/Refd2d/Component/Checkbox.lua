local Runtime = require("ArmorVariantManager_Core.Refd2d.Component.Runtime")

local Checkbox = {}

-- 创建 D2D 勾选框组件，用于表示并切换 Mesh 或材质的显示状态。
function Checkbox.new(d2d_api, colors, fonts)
    local component = {}

    -- disabled 为 true 时仅展示状态，不触发材质开关；text_color 可用于分组占用的弱化文字。
    function component:draw(label, x, y, w, h, checked, disabled, text_color)
        local mx, my = Runtime.mouse_position()
        local hovered = not disabled and Runtime.point_in_rect(mx, my, x, y, w, h)
        local box_size = math.min(18, math.max(14, h - 8))
        local box_x = x + 4
        local box_y = y + (h - box_size) / 2
        local text_x = box_x + box_size + 9

        d2d_api.fill_rounded_rect(box_x, box_y, box_size, box_size, 3, 3,
            disabled and colors.panel or checked and colors.accent_dark or colors.panel_alt)
        d2d_api.outline_rect(box_x, box_y, box_size, box_size, 1,
            hovered and colors.accent or disabled and colors.muted or colors.border)
        if checked then
            d2d_api.line(box_x + 4, box_y + box_size / 2,
                box_x + box_size / 2 - 1, box_y + box_size - 4, 2,
                disabled and colors.muted or colors.accent)
            d2d_api.line(box_x + box_size / 2 - 1, box_y + box_size - 4,
                box_x + box_size - 3, box_y + 4, 2, disabled and colors.muted or colors.accent)
        end

        local _, text_y = Runtime.center_text(fonts.body, label, text_x, y,
            w - (text_x - x), h)
        Runtime.text(d2d_api, fonts.body, label, text_x, text_y,
            text_color or disabled and colors.muted or checked and colors.text or colors.muted)
        return not disabled and Runtime.is_mouse_clicked() and hovered
    end

    return component
end

return Checkbox
