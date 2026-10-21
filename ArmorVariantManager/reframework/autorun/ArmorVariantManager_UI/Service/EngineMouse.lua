-- Rise ScreenCursorPosition is in pixels. PresentRectCursorPosition is NDC:
-- x = 2 * pixel_x / width - 1; y = 1 - 2 * pixel_y / height.
-- Never select a getter based on the sign of its coordinates.
local EngineMouse = {}
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < 10000000
end
function EngineMouse.coordinates(point)
    local ok, x, y = pcall(function() return point.x, point.y end)
    if ok and finite(x) and finite(y) then return x, y end
end
function EngineMouse.read(call, surface)
    local ok, point = call("get_ScreenCursorPosition()")
    if ok and point then
        local x, y = EngineMouse.coordinates(point)
        if x then return x, y end
    end
    ok, point = call("get_PresentRectCursorPosition()")
    if not ok or not point then return nil, nil end
    local x, y = EngineMouse.coordinates(point)
    if not x then return nil, nil end
    local size_ok, width, height = pcall(surface)
    if size_ok and finite(width) and finite(height) and width > 0 and height > 0 then
        return (x + 1) * width / 2, (1 - y) * height / 2
    end
    return nil, nil
end
return EngineMouse
