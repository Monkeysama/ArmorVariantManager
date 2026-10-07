-- ============================================================================
--  ImGui 绘制后端 —— 用 REFramework 自带的 ImGui 绘制列表，实现与原生
--  reframework-d2d 插件等价的 `d2d` API
-- ----------------------------------------------------------------------------
--  为什么需要它：
--    原生插件 ArmorVariantManager_UI.dll（即 cursey 的 reframework-d2d，MK 的构建）
--    在崛起版本上会在 REFramework 的插件加载阶段把进程带崩，而且没有源码、改不动。
--    因此这里用 REFramework 自己的 ImGui 绘制列表把同一套绘制 API 在 Lua 侧重新
--    实现，彻底摆脱对第三方原生插件的依赖。
--
--  ★ 关键设计一：绘制列表只能在 ImGui 帧内取（re.on_draw_ui 回调里）。
--    在 re.on_frame 里调用 imgui.get_*_draw_list() 拿不到，所以：
--      - is_available() 只做「与帧无关」的宽松检查；
--      - 绘制列表、字体、绘制方法探测全部延后到 on_draw_ui 帧内完成。
--
--  ★ 关键设计二：ImDrawList 各方法的参数形式离线无法确认，所以每个图元都在
--    首次调用时**用真实参数 + 透明颜色 / 空字符串**去试各种重载，记住能用的那一种；
--    探测不会在屏幕上留下任何可见内容。float 形式与 ImVec2 形式都覆盖。
--
--  覆盖的 API（与 UI 层实际用到的完全一致）：
--    d2d.register(on_ready, on_frame) / surface_size()
--    d2d.Font.new(name, size, bold) -> font:measure(text)
--    d2d.fill_rect / fill_rounded_rect / outline_rect / line / text
--    d2d.push_transform / pop_transform
--    d2d.bridge.register_runtime / unregister_runtime   （无原生输入法，空实现）
--
--  注意：ImGui / draw 系列 API 的颜色是 **ABGR**，而 UI 层的 COLORS 是 **ARGB**，
--        所以每次下发前都要做一次 R/B 交换（用算术实现，兼容 Lua 5.1~5.4）。
-- ============================================================================
local ImGuiBackend = {}

local MAX_WIDTH_CACHE = 8192
local DRAW_LIST_GETTERS = {
    "get_foreground_draw_list",
    "get_background_draw_list",
    "get_window_draw_list",
    "get_draw_list"
}
local DRAW_METHODS = { "add_rect_filled", "add_rect", "add_line", "add_text" }
-- 承载绘制用的全屏透明窗口标志：
-- NoTitleBar|NoResize|NoMove|NoScrollbar|NoScrollWithMouse|NoCollapse|NoBackground
-- |NoSavedSettings|NoMouseInputs|NoBringToFrontOnFocus|NoNavInputs|NoNavFocus
local OVERLAY_FLAGS = 205759

-- ARGB -> ABGR（ImGui 的 IM_COL32）
local function to_imgui_color(argb)
    local c = tonumber(argb) or 0
    if c < 0 then c = c + 4294967296 end
    c = math.floor(c) % 4294967296
    local a = math.floor(c / 16777216) % 256
    local r = math.floor(c / 65536) % 256
    local g = math.floor(c / 256) % 256
    local b = c % 256
    return a * 16777216 + b * 65536 + g * 256 + r
end

ImGuiBackend.to_imgui_color = to_imgui_color

local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function unpack_args(list)
    local unpack_fn = table.unpack or unpack
    return unpack_fn(list)
end

local function log_error(message)
    if log and log.error then pcall(function() log.error("[ArmorVariantManager] " .. message) end) end
end

local function log_info(message)
    if log and log.info then pcall(function() log.info("[ArmorVariantManager] " .. message) end) end
end

-- ============================================================================
--  环境检查（只做与「是否在 ImGui 帧内」无关的宽松判断）
-- ============================================================================
function ImGuiBackend.is_available()
    if imgui == nil then return false end
    if type(safe(function() return re and re.on_draw_ui end)) ~= "function" then return false end
    local has_size = type(safe(function() return imgui.get_display_size end)) == "function"
    local has_measure = type(safe(function() return imgui.calc_text_size end)) == "function"
    if not has_size and not has_measure then return false end
    return true
end

-- 帧内探测：找出可用的绘制列表与缺失的方法（供日志诊断）
function ImGuiBackend.probe_in_frame()
    local report = { getter = nil, draw_list = nil, missing = {} }
    for _, name in ipairs(DRAW_LIST_GETTERS) do
        local fn = safe(function() return imgui[name] end)
        if type(fn) == "function" then
            local list = safe(fn)
            if list ~= nil then
                report.getter = name
                report.draw_list = list
                break
            end
        end
    end
    if not report.draw_list then
        report.missing[#report.missing + 1] = "draw_list(" .. table.concat(DRAW_LIST_GETTERS, "|") .. ")"
        return report
    end
    for _, name in ipairs(DRAW_METHODS) do
        if type(safe(function() return report.draw_list[name] end)) ~= "function" then
            report.missing[#report.missing + 1] = name
        end
    end
    return report
end

-- ---------------------------------------------------------------- 参数形式候选
-- 每个 builder 接收一个「语义参数表」并返回实际调用参数表。
--
-- ★★ 实测教训（一定要保留这段注释）：
--   REFramework 的 ImDrawList 绑定接受 ImVec2（Lua 里就是 {x, y} 数组）形式。
--   如果传的是**一串数字**（x1,y1,x2,y2,...），调用**不会报错**，但也**不会画出任何东西**
--   —— 用 pcall 探测「有没有报错」根本分辨不出来，于是很容易挑中一个静默失效的形式，
--   表现就是「代码在画、日志有计数、屏幕上一片空白」。
--   因此这里一律把 **{x,y} 向量形式 + 最短参数** 放在最前面（已实测可渲染），
--   数字形式只作为兜底放在最后。
local FILLED_VARIANTS = {
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col } end,
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col, a.rounding } end,
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col, a.rounding, 0 } end,
    function(a) return { a.x1, a.y1, a.x2, a.y2, a.col, a.rounding, 0 } end,
    function(a) return { a.x1, a.y1, a.x2, a.y2, a.col } end
}
local OUTLINE_VARIANTS = {
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col } end,
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col, a.rounding, 0, a.thickness } end,
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col, a.rounding, 0 } end,
    function(a) return { a.x1, a.y1, a.x2, a.y2, a.col, a.thickness } end,
    function(a) return { a.x1, a.y1, a.x2, a.y2, a.col } end
}
local LINE_VARIANTS = {
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col } end,
    function(a) return { { a.x1, a.y1 }, { a.x2, a.y2 }, a.col, a.thickness } end,
    function(a) return { a.x1, a.y1, a.x2, a.y2, a.col, a.thickness } end,
    function(a) return { a.x1, a.y1, a.x2, a.y2, a.col } end
}
-- 文本：同样是 {x, y} 向量形式优先；带字体的重载放在后面（字体句柄为空时跳过，避免空指针崩溃）
local TEXT_VARIANTS = {
    function(a) return { { a.x, a.y }, a.col, a.text } end,
    function(a) return { { a.x, a.y }, a.col, a.text, nil } end,
    function(a)
        if not a.font then return nil end
        return { a.font, a.font_size, { a.x, a.y }, a.col, a.text }
    end,
    function(a) return { a.x, a.y, a.col, a.text } end
}

-- ============================================================================
--  创建一份 api（形状与原生 d2d 一致）
-- ============================================================================
function ImGuiBackend.create()
    if not ImGuiBackend.is_available() then return nil end

    local state = {
        draw_list = nil,
        scale = 1,
        stack = {},
        width = 0,
        height = 0,
        ready = false,
        frames = 0,
        drawn_frames = 0,
        last_error = nil,
        first_probe_done = false,
        no_draw_list_frames = 0,
        draw_failed = false,
        active_path = "on_frame",   -- "on_frame"（主路径）或 "draw_ui"（兜底）
        frame_path_failures = 0,
        last_draw_clock = 0,
        variant = {},        -- method -> 命中的 builder 下标（false 表示都不匹配）
        variant_warned = {}
    }
    local width_cache = {}
    local width_cache_count = 0
    local default_font_size = tonumber(safe(function() return imgui.get_default_font_size() end)) or 18
    local stats = { filled = 0, outline = 0, line = 0, text = 0, variants = {} }

    local function tx(value) return (value or 0) * state.scale end

    -- ---------------------------------------------------------------- 字体
    local font_handles = {}
    local function load_font(size)
        if font_handles[size] ~= nil then return font_handles[size] end
        local handle = nil
        if type(safe(function() return imgui.load_font end)) == "function" then
            -- 第一个参数传 nil = 用默认字体，只改字号
            handle = safe(function() return imgui.load_font(nil, size) end)
        end
        font_handles[size] = handle or false
        return font_handles[size]
    end

    local function measure_base(text)
        local cached = width_cache[text]
        if cached then return cached end
        local width = nil
        local size = safe(function() return imgui.calc_text_size(text) end)
        if size then width = tonumber(size.x) or tonumber(size[1]) end
        if not width then
            -- 兜底估算：CJK 按一个字宽、ASCII 约 0.55 字宽
            local wide = 0
            for _ in tostring(text):gmatch("[^\128-\191]") do wide = wide + 1 end
            local ascii = #tostring(text) - wide * 3
            if ascii < 0 then ascii = 0 end
            width = (wide + ascii * 0.55) * default_font_size
        end
        if width_cache_count < MAX_WIDTH_CACHE then
            width_cache[text] = width
            width_cache_count = width_cache_count + 1
        end
        return width
    end

    local Font = {}
    function Font.new(name, size, bold)
        local handle = load_font(size)
        local font = { _size = size, _handle = handle or nil, _bold = bold == true }
        function font:measure(value)
            local text = tostring(value or "")
            return measure_base(text) * (self._size / default_font_size), self._size * 1.25
        end
        return font
    end

    -- -------------------------------------------------- 图元：探测 + 下发
    local function invoke(method, variants, args, probe)
        local dl = state.draw_list
        if not dl then return false end
        local index = state.variant[method]
        if index == nil then
            local fn = dl[method]
            if type(fn) ~= "function" then
                state.variant[method] = false
                return false
            end
            for candidate, builder in ipairs(variants) do
                local built_ok, built = pcall(builder, probe)
                -- builder 返回 nil = 该候选在当前参数下不适用（例如没有字体句柄），跳过
                if built_ok and built ~= nil then
                    local ok = pcall(function() return fn(dl, unpack_args(built)) end)
                    if ok then
                        state.variant[method] = candidate
                        stats.variants[method] = candidate
                        index = candidate
                        break
                    end
                end
            end
            if index == nil then
                state.variant[method] = false
                if not state.variant_warned[method] then
                    state.variant_warned[method] = true
                    log_error("内置 ImGui 后端：ImDrawList:" .. method
                        .. " 的所有参数形式都不匹配，该图元将不绘制")
                end
                return false
            end
        end
        if index == false then return false end
        local built_ok, built = pcall(variants[index], args)
        if not built_ok or built == nil then return false end
        return pcall(function() return dl[method](dl, unpack_args(built)) end)
    end

    local transparent = to_imgui_color(0x00000000)

    local api = {}

    -- ==========================================================================
    --  一帧的绘制派发（两条路径共用）
    -- ==========================================================================
    local function dispatch_frame(on_ready, on_frame)
        -- ---- 帧内取绘制列表（帧外拿不到）----
        local dl = state.draw_list
        if not dl then
            local report = ImGuiBackend.probe_in_frame()
            dl = report.draw_list
            state.draw_list = dl
            if not state.first_probe_done then
                state.first_probe_done = true
                if dl then
                    log_info("内置 ImGui 后端已就绪：draw_list=" .. tostring(report.getter)
                        .. (#report.missing > 0
                            and ("，缺少绘制方法: " .. table.concat(report.missing, ","))
                            or "，绘制方法齐全"))
                else
                    log_error("内置 ImGui 后端拿不到绘制列表（尝试过 "
                        .. table.concat(DRAW_LIST_GETTERS, "/") .. "），面板将无法绘制")
                end
            end
        end

        local size = safe(function() return imgui.get_display_size() end)
        if size then
            state.width = tonumber(size.x) or tonumber(size[1]) or state.width
            state.height = tonumber(size.y) or tonumber(size[2]) or state.height
        end
        state.scale = 1
        state.stack = {}

        if not state.ready then
            state.ready = true
            if on_ready then pcall(on_ready) end
        end
        state.frames = state.frames + 1
        if not dl then
            -- 连续拿不到绘制列表 → 判定这个后端在本机不可用。
            -- 这样面板会退回旧版 ImGui 界面，用户永远不会面对「新旧面板都打不开」的死局。
            state.no_draw_list_frames = state.no_draw_list_frames + 1
            if state.no_draw_list_frames >= 60 and not state.draw_failed then
                state.draw_failed = true
                log_error("内置 ImGui 后端连续 " .. tostring(state.no_draw_list_frames)
                    .. " 帧拿不到绘制列表，已停用并回退旧版面板")
            end
        else
            state.no_draw_list_frames = 0
            state.last_draw_clock = os.clock()
            if on_frame then
                state.drawn_frames = state.drawn_frames + 1
                -- 心跳日志：每 3600 个绘制帧（约 1 分钟）打一次，便于回看「面板有没有在画」
                if state.drawn_frames % 3600 == 0 then
                    log_info(string.format(
                        "绘制心跳：已绘制帧=%d, 矩形=%d, 描边=%d, 线=%d, 文字=%d, 屏幕=%dx%d, 路径=%s",
                        state.drawn_frames, stats.filled, stats.outline, stats.line, stats.text,
                        math.floor(state.width), math.floor(state.height),
                        tostring(state.active_path)))
                end
                local ok, err = pcall(on_frame)
                if not ok then
                    state.last_error = tostring(err)
                    -- 只记录、不抛出：绘制失败绝不能影响游戏
                    log_error("ImGui 后端绘制失败: " .. tostring(err))
                end
            end
        end
        state.draw_list = nil
        return dl ~= nil
    end

    function api.register(on_ready, on_frame)
        -- ★ 关键：re.on_draw_ui 只在 REFramework 菜单里的「Script Generated UI」打开时
        --   才会被调用（官方文档明确写了），菜单一关就完全不再触发。
        --   所以主路径必须用 re.on_frame（每帧都调用），并按文档要求自己用
        --   begin_window / end_window 承载绘制。
        --   re.on_draw_ui 保留作为兜底：万一 on_frame 里开窗口失败，就切回它。
        re.on_frame(function()
            if state.active_path == "draw_ui" then return end
            local entered = false
            local begin_ok, begin_err = pcall(function()
                local size = safe(function() return imgui.get_display_size() end)
                local w = 1920
                local h = 1080
                if size then
                    w = tonumber(size.x) or tonumber(size[1]) or w
                    h = tonumber(size.y) or tonumber(size[2]) or h
                end
                imgui.set_next_window_pos(0, 0)
                imgui.set_next_window_size(w, h)
                -- 全屏、无边框、无背景、不接收输入、不抢焦点
                imgui.begin_window("##ArmorVariantManagerOverlay", nil, OVERLAY_FLAGS)
                entered = true
            end)
            if not begin_ok then
                state.frame_path_failures = (state.frame_path_failures or 0) + 1
                if state.frame_path_failures == 1 then
                    log_error("内置 ImGui 后端：on_frame 里 begin_window 失败: " .. tostring(begin_err))
                end
                -- 连续失败就放弃这条路，改用 re.on_draw_ui 兜底
                if state.frame_path_failures >= 30 and state.active_path ~= "draw_ui" then
                    state.active_path = "draw_ui"
                    log_info("内置 ImGui 后端：改用 re.on_draw_ui 兜底（仅菜单打开时可见）")
                end
                return
            end
            state.frame_path_failures = 0
            state.active_path = "on_frame"
            dispatch_frame(on_ready, on_frame)
            if entered then pcall(function() imgui.end_window() end) end
        end)

        re.on_draw_ui(function()
            -- 主路径正常工作时不再重复绘制
            if state.active_path == "on_frame" then return end
            dispatch_frame(on_ready, on_frame)
        end)
    end

    -- 最近一次成功绘制的时间（供 UI 层判断「面板其实没画出来」）
    function api.last_draw_time()
        return state.last_draw_clock or 0
    end

    function api.active_path()
        return state.active_path
    end

    -- 供 UI 层判断「这个后端现在还能不能画」：拿不到绘制列表时必须让位给旧面板
    function api.can_draw()
        return state.draw_failed ~= true
    end

    function api.surface_size()
        if state.width > 0 and state.height > 0 then
            return state.width, state.height
        end
        local size = safe(function() return imgui.get_display_size() end)
        if size then
            local w = tonumber(size.x) or tonumber(size[1]) or 0
            local h = tonumber(size.y) or tonumber(size[2]) or 0
            if w > 0 and h > 0 then
                state.width, state.height = w, h
                return w, h
            end
        end
        return 1920, 1080
    end

    api.Font = Font

    function api.fill_rect(x, y, w, h, color)
        local args = { x1 = tx(x), y1 = tx(y), x2 = tx(x + w), y2 = tx(y + h),
            col = to_imgui_color(color), rounding = 0 }
        local probe = { x1 = args.x1, y1 = args.y1, x2 = args.x2, y2 = args.y2,
            col = transparent, rounding = 0 }
        if invoke("add_rect_filled", FILLED_VARIANTS, args, probe) then
            stats.filled = stats.filled + 1
        end
    end

    function api.fill_rounded_rect(x, y, w, h, rx, ry, color)
        local radius = rx or 0
        if ry and ry < radius then radius = ry end
        local args = { x1 = tx(x), y1 = tx(y), x2 = tx(x + w), y2 = tx(y + h),
            col = to_imgui_color(color), rounding = tx(radius) }
        local probe = { x1 = args.x1, y1 = args.y1, x2 = args.x2, y2 = args.y2,
            col = transparent, rounding = args.rounding }
        if invoke("add_rect_filled", FILLED_VARIANTS, args, probe) then
            stats.filled = stats.filled + 1
        end
    end

    function api.outline_rect(x, y, w, h, thickness, color)
        local args = { x1 = tx(x), y1 = tx(y), x2 = tx(x + w), y2 = tx(y + h),
            col = to_imgui_color(color), thickness = math.max(1, tx(thickness or 1)), rounding = 0 }
        local probe = { x1 = args.x1, y1 = args.y1, x2 = args.x2, y2 = args.y2,
            col = transparent, thickness = args.thickness, rounding = 0 }
        if invoke("add_rect", OUTLINE_VARIANTS, args, probe) then
            stats.outline = stats.outline + 1
        end
    end

    function api.line(x1, y1, x2, y2, thickness, color)
        local args = { x1 = tx(x1), y1 = tx(y1), x2 = tx(x2), y2 = tx(y2),
            col = to_imgui_color(color), thickness = math.max(1, tx(thickness or 1)) }
        local probe = { x1 = args.x1, y1 = args.y1, x2 = args.x2, y2 = args.y2,
            col = transparent, thickness = args.thickness }
        if invoke("add_line", LINE_VARIANTS, args, probe) then
            stats.line = stats.line + 1
        end
    end

    function api.text(font, value, x, y, color)
        if value == nil then return end
        local text = tostring(value)
        if text == "" then return end
        -- 字号靠 push_font 实现（ImGui 的 add_text 用当前字体渲染）
        local handle = font and font._handle
        if handle then pcall(function() imgui.push_font(handle) end) end
        local args = { x = tx(x), y = tx(y), col = to_imgui_color(color), text = text,
            font = handle, font_size = font and font._size or default_font_size }
        -- 探测用空字符串：不会在屏幕上画出任何可见内容
        local probe = { x = args.x, y = args.y, col = transparent, text = "",
            font = args.font, font_size = args.font_size }
        if invoke("add_text", TEXT_VARIANTS, args, probe) then
            stats.text = stats.text + 1
        end
        if handle then pcall(function() imgui.pop_font() end) end
    end

    function api.push_transform(x, y, scale)
        table.insert(state.stack, { scale = state.scale })
        state.scale = (state.scale or 1) * (tonumber(scale) or 1)
    end

    function api.pop_transform()
        local previous = table.remove(state.stack)
        if previous then state.scale = previous.scale end
    end

    api.bridge = {
        register_runtime = function() return false end,
        unregister_runtime = function() return false end
    }

    api.is_imgui_backend = true
    api.stats = function()
        return {
            frames = state.frames,
            drawn_frames = state.drawn_frames,
            filled = stats.filled,
            outline = stats.outline,
            line = stats.line,
            text = stats.text,
            variants = stats.variants,
            draw_failed = state.draw_failed == true,
            last_error = state.last_error
        }
    end
    api.describe = function()
        return string.format("imgui (frames=%d, drawn=%d, rect=%d, line=%d, text=%d, error=%s)",
            state.frames, state.drawn_frames, stats.filled, stats.line, stats.text,
            tostring(state.last_error))
    end

    return api
end

return ImGuiBackend
