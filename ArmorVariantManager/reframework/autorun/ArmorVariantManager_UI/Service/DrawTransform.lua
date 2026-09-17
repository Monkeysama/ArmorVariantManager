local DrawTransform = {}
local unpack_values = table.unpack or unpack
local ARG_SPEC = {
    text = { x = { 3 }, y = { 4 }, font = 1 },
    measure_text = { font_base = 1 },
    fill_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    filled_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    outline_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5 } },
    rounded_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5, 6, 7 } },
    fill_rounded_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5, 6 } },
    quad = { x = { 1, 3, 5, 7 }, y = { 2, 4, 6, 8 }, lengths = { 9 } },
    fill_quad = { x = { 1, 3, 5, 7 }, y = { 2, 4, 6, 8 } },
    line = { x = { 1, 3 }, y = { 2, 4 }, lengths = { 5 } },
    image = { x = { 2 }, y = { 3 }, lengths = { 4, 5 } },
    fill_circle = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    fill_oval = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    circle = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5 } },
    oval = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5 } },
    pie = { x = { 1 }, y = { 2 }, lengths = { 3 } },
    outline_pie = { x = { 1 }, y = { 2 }, lengths = { 3, 6 } },
    ring = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    outline_ring = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 7 } }
}
local EMPTY = {}
local FONT_PROXY_MEASURE = function(proxy, value)
    return proxy.base:measure(value)
end
local FONT_PROXY_MT = {
    __index = function(_, key)
        if key == "measure" then return FONT_PROXY_MEASURE end
        return nil
    end
}
local function is_font_proxy(value)
    return type(value) == "table" and rawget(value, "__avm_font_proxy") == true
end
local function resolve_scaled_font(proxy, scale)
    if scale == 1 then return proxy.base end
    local size = math.floor(proxy.size * scale + 0.5)
    if size < 1 then size = 1 end
    local cached = proxy.scaled[size]
    if cached then return cached end
    local created = proxy.make_variant(size)
    if created == nil then created = proxy.base end
    proxy.scaled[size] = created
    return created
end
function DrawTransform.needs_wrap(api)
    if type(api) ~= "table" then return false end
    return type(api.push_transform) ~= "function" or type(api.pop_transform) ~= "function"
end
function DrawTransform.wrap(api)
    if type(api) ~= "table" then return api end
    local facade = setmetatable({}, { __index = api })
    local stack = { { scale = 1, x = 0, y = 0 } }
    local font_factory = nil
    if type(api.Font) == "table" and type(api.Font.new) == "function" then
        font_factory = function(...) return api.Font.new(...) end
    elseif type(api.create_font) == "function" then
        font_factory = function(...) return api.create_font(...) end
    end
    local function make_font(...)
        local count = select("#", ...)
        local args = { ... }
        local base_ok, base = pcall(font_factory, unpack_values(args, 1, count))
        if not base_ok or base == nil then return nil end
        if count < 2 or type(args[2]) ~= "number" then return base end
        local proxy = {
            __avm_font_proxy = true,
            base = base,
            size = args[2],
            scaled = {}
        }
        proxy.make_variant = function(new_size)
            local ok, font
            if count >= 4 then
                ok, font = pcall(font_factory, args[1], new_size, args[3], args[4])
            elseif count == 3 then
                ok, font = pcall(font_factory, args[1], new_size, args[3])
            else
                ok, font = pcall(font_factory, args[1], new_size)
            end
            if ok then return font end
            return nil
        end
        return setmetatable(proxy, FONT_PROXY_MT)
    end
    if font_factory then
        facade.Font = setmetatable({ new = make_font }, { __index = api.Font })
    end
    facade.push_transform = function(x, y, scale)
        local top = stack[#stack]
        local factor = tonumber(scale) or 1
        if factor <= 0 then factor = 0.01 end
        stack[#stack + 1] = {
            scale = top.scale * factor,
            x = top.x * factor + (tonumber(x) or 0),
            y = top.y * factor + (tonumber(y) or 0)
        }
    end
    facade.pop_transform = function()
        if #stack > 1 then table.remove(stack) end
    end
    for name, spec in pairs(ARG_SPEC) do
        local raw = api[name]
        if type(raw) == "function" then
            local xs = spec.x or EMPTY
            local ys = spec.y or EMPTY
            local lengths = spec.lengths or EMPTY
            local x_count = #xs
            local y_count = #ys
            local length_count = #lengths
            local font_index = spec.font
            local base_font_index = spec.font_base
            local font_arg = font_index or base_font_index
            facade[name] = function(...)
                local top = stack[#stack]
                local identity = top.scale == 1 and top.x == 0 and top.y == 0
                local count = select("#", ...)
                local args = nil
                if font_arg then
                    args = { ... }
                    local font = args[font_arg]
                    if is_font_proxy(font) then
                        args[font_arg] = base_font_index and font.base
                            or resolve_scaled_font(font, top.scale)
                    end
                end
                if identity then
                    if args then return raw(unpack_values(args, 1, count)) end
                    return raw(...)
                end
                if not args then
                    args = { ... }
                end
                for i = 1, x_count do
                    local index = xs[i]
                    local value = args[index]
                    if type(value) == "number" then
                        args[index] = top.x + value * top.scale
                    end
                end
                for i = 1, y_count do
                    local index = ys[i]
                    local value = args[index]
                    if type(value) == "number" then
                        args[index] = top.y + value * top.scale
                    end
                end
                for i = 1, length_count do
                    local index = lengths[i]
                    local value = args[index]
                    if type(value) == "number" then
                        args[index] = value * top.scale
                    end
                end
                return raw(unpack_values(args, 1, count))
            end
        end
    end
    return facade
end
return DrawTransform
