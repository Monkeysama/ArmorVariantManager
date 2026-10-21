local DrawClip = require("ArmorVariantManager_UI.Service.DrawClip")
local WindowsInput = require("ArmorVariantManager_UI.Service.WindowsInput")
-- 崛起内置绘制后端，使用 REFramework 官方 draw.* 接口。
-- 不加载字体、不接触 ImDrawList 重载、不创建全屏 ImGui 窗口。
-- Font 是默认字体的轻量包装；测量和绘制都使用相同的默认字号。
local ImGuiBackend = {}
-- Register with REF while the module is loading, before frame dispatch starts.
-- api.register() can be called by the UI update inside an on_frame callback.
-- Adding a REF callback there invalidates ScriptState's vector iteration.
local frame_tasks = {}
if re and type(re.on_frame) == "function" then
    re.on_frame(function()
        for _, task in ipairs(frame_tasks) do task() end
    end)
end

local function member(object, name)
    local ok, value = pcall(function() return object[name] end)
    if ok then return value end
end

function ImGuiBackend.has_draw_api()
    for _, name in ipairs({ "filled_rect", "outline_rect", "line", "text" }) do
        if type(member(draw, name)) ~= "function" then return false end
    end
    return true
end

function ImGuiBackend.is_available()
    return type(member(re, "on_frame")) == "function"
        and type(member(imgui, "get_display_size")) == "function"
        and type(member(imgui, "calc_text_size")) == "function"
        and ImGuiBackend.has_draw_api()
end

function ImGuiBackend.to_imgui_color(argb)
    local c = math.floor(tonumber(argb) or 0) % 4294967296
    local a = math.floor(c / 16777216) % 256
    local r = math.floor(c / 65536) % 256
    local g = math.floor(c / 256) % 256
    local b = c % 256
    return a * 16777216 + b * 65536 + g * 256 + r
end

function ImGuiBackend.create()
    if not ImGuiBackend.is_available() then return nil end
    local api = { Font = {}, is_imgui_backend = true }
    local failed, last_error, last_draw = false, nil, 0
    local scale, offset_x, offset_y = 1, 0, 0
    local stack, commands = {}, nil
    local ready, registered = false, false
    local stats = { frames = 0, drawn_frames = 0, filled = 0, outline = 0, line = 0, text = 0 }
    local width_cache, cache_count = {}, 0

    local clip
    local function reset()
        scale, offset_x, offset_y = 1, 0, 0
        stack = {}
        if clip then clip.reset() end
    end
    local function fail(err)
        failed, last_error = true, tostring(err)
        if log and log.error then
            pcall(log.error, "[ArmorVariantManager] 内置 draw 后端已停用: " .. last_error)
        end
    end
    local function px(x) return x * scale + offset_x end
    local function py(y) return y * scale + offset_y end
    clip=DrawClip.new(px,py,function() return scale end)
    api.push_clip_rect=clip.push
    api.pop_clip_rect=clip.pop
    local function queue(kind, fn, ...)
        assert(commands, "draw 图元只能在绘制回调内使用")
        commands[#commands + 1] = { kind = kind, fn = fn, args = table.pack(...) }
    end
    function api.Font.new()
        local font = {}
        function font:measure(value)
            local text = tostring(value or "")
            local size = width_cache[text]
            if not size then
                local result = imgui.calc_text_size(text)
                local w, h = tonumber(result.x or result[1]), tonumber(result.y or result[2])
                assert(w and h, "calc_text_size 返回值不兼容")
                size = { w, h }
                if cache_count < 8192 then
                    width_cache[text] = size
                    cache_count = cache_count + 1
                end
            end
            -- draw.text 无字号参数，不能用请求字号估算宽度，否则文字布局与实际绘制错位。
            return size[1] / scale, size[2] / scale
        end
        return font
    end
    function api.surface_size()
        local w,h = WindowsInput.surface_size()
        if w then return w,h end
        local size = imgui.get_display_size()
        local w, h = tonumber(size.x or size[1]), tonumber(size.y or size[2])
        assert(w and h, "get_display_size 返回值不兼容")
        return w, h
    end
    function api.fill_rect(x, y, w, h, color)
        x,y,w,h=clip.rect(x,y,w,h)
        if not x then return end
        queue("filled", draw.filled_rect, x, y, w, h,
            ImGuiBackend.to_imgui_color(color))
    end
    function api.fill_rounded_rect(x, y, w, h, rx, ry, color)
        -- 官方 draw API 仅提供直角矩形。
        api.fill_rect(x, y, w, h, color)
    end
    function api.outline_rect(x, y, w, h, thickness, color)
        x,y,w,h=clip.rect(x,y,w,h)
        if not x then return end
        queue("outline", draw.outline_rect, x, y, w, h,
            ImGuiBackend.to_imgui_color(color))
    end
    function api.line(x1, y1, x2, y2, thickness, color)
        x1,y1,x2,y2=clip.line(x1,y1,x2,y2)
        if not x1 then return end
        queue("line", draw.line, x1, y1, x2, y2, ImGuiBackend.to_imgui_color(color))
    end
    function api.text(font, value, x, y, color)
        if not font or value == nil or tostring(value) == "" then return end
        if not clip.text(font,tostring(value),x,y) then return end
        queue("text", draw.text, tostring(value), px(x), py(y), ImGuiBackend.to_imgui_color(color))
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
    function api.register(on_ready, on_frame, should_run)
        assert(not registered, "draw 后端重复注册")
        registered = true
        frame_tasks[#frame_tasks + 1] = function()
            if failed or (should_run and not should_run()) then return end
            stats.frames = stats.frames + 1
            reset()
            commands = {}
            local submitted = false
            local ok, result = pcall(function()
                if not ready then
                    if on_ready then on_ready() end
                    ready = true
                end
                if on_frame and on_frame() == false then return false end
                assert(#stack == 0, "绘制结束时变换栈未恢复")
                for _, command in ipairs(commands) do
                    command.fn(table.unpack(command.args, 1, command.args.n))
                    stats[command.kind] = stats[command.kind] + 1
                end
                submitted = #commands > 0
                return true
            end)
            commands = nil
            reset()
            if not ok then
                fail(result)
            elseif result ~= false and submitted then
                stats.drawn_frames = stats.drawn_frames + 1
                last_draw = os.clock()
            end
        end
    end
    function api.can_draw() return not failed end
    function api.last_draw_time() return last_draw end
    function api.active_path() return "draw" end
    function api.stats()
        local result = {}
        for key, value in pairs(stats) do result[key] = value end
        result.draw_failed, result.last_error = failed, last_error
        return result
    end
    function api.describe()
        return string.format("draw (frames=%d, drawn=%d, text=%d, error=%s)",
            stats.frames, stats.drawn_frames, stats.text, tostring(last_error))
    end
    api.bridge = {
        register_runtime = function() return false end,
        unregister_runtime = function() return false end
    }
    return api
end

return ImGuiBackend
