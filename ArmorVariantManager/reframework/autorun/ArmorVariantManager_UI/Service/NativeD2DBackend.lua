local DrawClip = require("ArmorVariantManager_UI.Service.DrawClip")
local WindowsInput = require("ArmorVariantManager_UI.Service.WindowsInput")
-- 标准 cursey/ref-d2d 没有 push_transform/pop_transform。
-- 只使用上游公开 API，在 Lua 中变换坐标，整帧生成成功后再提交原生绘制。
local NativeD2DBackend = {}

function NativeD2DBackend.create(native)
    if type(native) ~= "table" or native.is_imgui_backend then return nil, "没有原生 d2d" end
    for _, name in ipairs({ "register", "surface_size", "fill_rect", "outline_rect", "line", "text" }) do
        if type(native[name]) ~= "function" then return nil, "缺少 " .. name end
    end
    if type(native.Font) ~= "table" or type(native.Font.new) ~= "function" then
        return nil, "缺少 Font.new"
    end

    local api = { Font = {}, bridge = native.bridge }
    local scale, offset_x, offset_y = 1, 0, 0
    local stack, commands = {}, nil
    local failed, last_draw, last_error = false, 0, nil
    local clip
    local function reset()
        scale, offset_x, offset_y = 1, 0, 0
        stack = {}
        if clip then clip.reset() end
    end
    local function queue(fn, ...)
        assert(commands, "d2d 图元只能在绘制回调内使用")
        commands[#commands + 1] = { fn = fn, args = table.pack(...) }
    end
    local function px(x) return x * scale + offset_x end
    local function py(y) return y * scale + offset_y end
    clip=DrawClip.new(px,py,function() return scale end)
    api.push_clip_rect=clip.push
    api.pop_clip_rect=clip.pop

    local font_pool={}
    function api.Font.new(name, size, bold)
        local font = { _name = name, _size = size, _bold = bold == true, _handles = {} }
        -- 所有缩放字号在原生初始化回调中创建。整数像素缓存有界，绘制时不创建资源。
        for pixels = math.max(1, math.floor(size * 0.25)), math.ceil(size * 4) do
            local key=name.."|"..pixels.."|"..tostring(font._bold)
            if not font_pool[key] then
                font_pool[key]=assert(native.Font.new(name,pixels,font._bold),"原生字体创建失败")
            end
            font._handles[pixels]=font_pool[key]
        end
        font._base = assert(font._handles[size], "缺少原生基础字体")
        function font:measure(text) return self._base:measure(tostring(text or "")) end
        return font
    end

    function api.surface_size()
        local w,h = WindowsInput.surface_size()
        if w then return w,h end
        return native.surface_size()
    end
    function api.fill_rect(x, y, w, h, color)
        x,y,w,h=clip.rect(x,y,w,h)
        if not x then return end
        queue(native.fill_rect, x, y, w, h, color)
    end
    function api.fill_rounded_rect(x, y, w, h, rx, ry, color)
        if type(native.fill_rounded_rect) ~= "function" then return api.fill_rect(x,y,w,h,color) end
        x,y,w,h=clip.rect(x,y,w,h)
        if not x then return end
        queue(native.fill_rounded_rect, x, y, w, h, rx * scale, ry * scale, color)
    end
    function api.outline_rect(x, y, w, h, thickness, color)
        x,y,w,h=clip.rect(x,y,w,h)
        if not x then return end
        queue(native.outline_rect, x, y, w, h, thickness * scale, color)
    end
    function api.line(x1, y1, x2, y2, thickness, color)
        x1,y1,x2,y2=clip.line(x1,y1,x2,y2)
        if not x1 then return end
        queue(native.line, x1, y1, x2, y2, thickness * scale, color)
    end
    function api.text(font, text, x, y, color)
        if not font or text == nil then return end
        if not clip.text(font,tostring(text),x,y) then return end
        local pixels = math.floor(font._size * scale + 0.5)
        local handle = assert(font._handles[pixels], "原生字号超出缩放范围")
        queue(native.text, handle, tostring(text), px(x), py(y), color)
    end
    function api.push_transform(x, y, factor)
        stack[#stack + 1] = { scale, offset_x, offset_y }
        offset_x, offset_y = px(x or 0), py(y or 0)
        scale = scale * (tonumber(factor) or 1)
    end
    function api.pop_transform()
        local previous = assert(table.remove(stack), "变换栈不平衡")
        scale, offset_x, offset_y = table.unpack(previous)
    end
    function api.last_draw_time() return last_draw end
    function api.can_draw() return not failed end
    function api.register(on_ready, on_frame, should_run)
        native.register(function()
            if failed then return end
            reset()
            local ok, err = pcall(on_ready)
            if not ok then failed, last_error = true, tostring(err) end
        end, function()
            if failed or (should_run and not should_run()) then return end
            reset()
            commands = {}
            local ok, result = pcall(on_frame)
            if ok and result ~= false then
                ok, result = pcall(function()
                    assert(#stack == 0, "绘制结束时变换栈未恢复")
                    for _, command in ipairs(commands) do
                        command.fn(table.unpack(command.args, 1, command.args.n))
                    end
                end)
                if ok and #commands > 0 then last_draw = os.clock() end
            end
            commands = nil
            reset()
            if not ok then
                failed, last_error = true, tostring(result)
                if log and log.error then
                    pcall(log.error, "[ArmorVariantManager] 原生 d2d 提交失败: " .. last_error)
                end
            end
        end)
    end
    function api.describe() return "native (Lua transform, error=" .. tostring(last_error) .. ")" end
    return api
end

return NativeD2DBackend
