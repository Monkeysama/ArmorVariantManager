local Panel = {}
function Panel.new(d2d_api, colors)
    local component = {}
    function component:draw(x, y, w, h)
        d2d_api.fill_rounded_rect(x, y, w, h, 7, 7, colors.panel)
        d2d_api.outline_rect(x, y, w, h, 1, colors.border)
    end
    return component
end
return Panel
