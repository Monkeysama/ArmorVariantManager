local Runtime = require("ArmorVariantManager_UI.Component.Runtime")

local Input = {}

-- 字体测量会忽略末尾空格；追加可见占位字符后再减去其宽度，保留真实的光标前进距离。
local function measure_text_width(font, value)
    if not font or not value or value == "" then return 0 end
    local suffix = "."
    return math.max(0, font:measure(value .. suffix) - font:measure(suffix))
end

-- 创建单行输入框，负责绘制焦点、光标和清除按钮。
function Input.new(d2d_api, colors, fonts)
    local component = {}

    function component:draw(value, placeholder, x, y, w, h, focused, show_clear, composition,
        caret_start, caret_end)
        local mouse_x, mouse_y = Runtime.mouse_position()
        local hovered = Runtime.point_in_rect(mouse_x, mouse_y, x, y, w, h)
        local has_value = value ~= nil and value ~= ""
        local can_clear = show_clear ~= false
        local clear_width = can_clear and has_value and 28 or 0
        local content_right = x + w - clear_width

        d2d_api.fill_rounded_rect(x, y, w, h, 5, 5, colors.panel_alt)
        d2d_api.outline_rect(x, y, w, h, 1,
            focused and colors.accent or hovered and colors.accent or colors.border)

        -- 聚焦空输入框只显示光标，避免占位提示与输入位置重叠。
        local committed_value = has_value and value or ""
        local display_value = has_value and value or not focused and placeholder or ""
        local text_color = has_value and colors.text or colors.placeholder or colors.muted
        -- 输入内容和占位提示固定左对齐，仅在输入框高度方向居中。
        local text_x = x + 9
        local _, text_y = Runtime.center_text(fonts.tiny, display_value,
            text_x, y, 0, h)
        Runtime.text(d2d_api, fonts.tiny, display_value, text_x, text_y, text_color)
        -- 原生 IME 输入期间以强调色显示预编辑文本，最终确认后由提交文本替换。
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
            local caret_value = display_value
            if not composition or composition == "" then
                local caret_offset = tonumber(caret_end or caret_start)
                if caret_offset ~= nil then
                    caret_value = string.sub(committed_value, 1,
                        math.max(0, math.floor(caret_offset)))
                end
            end
            local text_width = measure_text_width(fonts.tiny, caret_value)
            local caret_x = math.min(content_right - 6, text_x + text_width + 1)
            -- 使用透明度正弦变化模拟输入光标呼吸，不改变布局或光标位置。
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


