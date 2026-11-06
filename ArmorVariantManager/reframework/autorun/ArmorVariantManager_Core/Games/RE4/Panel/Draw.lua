-- 独立面板的绘制层:画在 REFramework 的 ImGui 背景绘制列表上(re.on_frame 里调用)。
-- 改编自 ShapeKeySystem 的 ShapeKeySystem_UI/Draw.lua(d026d06,2026-11-04),只保留 ImGui 后端:
--   * 需要 Lua 里有 ImDrawList(REFramework 2025-05 起)和动态字号(2025-07 起);
--     自带字体 Roboto CJK SC 有中文字形。条件不满足时 D.available() 为 false,面板不打开
--   * 坐标都是逻辑坐标,D.S(界面缩放)换算成屏幕像素
--   * D.push_clip 维护裁剪矩形:矩形按它切,放不下的文字整段不画
--   * D.defer(fn) 在页面之后执行(下拉浮层、悬停提示),不受裁剪
--   * 文字原样绘制:调用方传进来的已经是界面语言的文字(SKS 版在这里翻译)

local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")

local D = {}

D.S = 1.0
D.FS = 1.0   -- 字号缩放(在 D.S 之上,只改字体不改布局)
local floor, max, min = math.floor, math.max, math.min

local clip_stack = {}
local clip = nil          -- { x0, y0, x1, y1 } 逻辑坐标

local fonts = {}
local measure_cache, measure_count = {}, 0
local deferred = {}
local surface_w, surface_h = 1920, 1080

function D.available()
    return type(imgui) == "table" and imgui.get_background_draw_list ~= nil
        and imgui.calc_text_size ~= nil and imgui.get_display_size ~= nil
end

-- ImGui 的颜色是 ABGR(主题里是 ARGB);点是 { x, y } 表
local DL = nil            -- 这一帧的背景绘制列表
local function col(c)
    c = floor(c or 0) % 0x100000000
    return (c & 0xFF00FF00) | ((c >> 16) & 0xFF) | ((c & 0xFF) << 16)
end

-- 动态字号(ImGui 1.92);旧版 REFramework 全部用默认字号
local function push_px(px) return imgui.push_font_size ~= nil and pcall(imgui.push_font_size, px + 0.0) end

local font_mt = { __index = {} }
function font_mt.__index:measure(s)
    local sized = push_px(self.px)
    local ok, v = pcall(imgui.calc_text_size, s)
    if sized then imgui.pop_font_size() end
    if not ok or not v then return 0, 0 end
    return v.x + (self.bold and 1 or 0), v.y
end

local A = {}
A.text = function(f, s, x, y, c)
    if not DL then return end
    local sized = push_px(f.px)
    c = col(c)
    pcall(DL.add_text, DL, { x, y }, c, s)
    if f.bold then pcall(DL.add_text, DL, { x + 0.8, y }, c, s) end   -- 没有粗体字形:叠印一次
    if sized then imgui.pop_font_size() end
end
A.fill_rect = function(x, y, w, h, c)
    if DL then DL:add_rect_filled({ x, y }, { x + w, y + h }, col(c), 0.0, 0) end
end
A.fill_rounded_rect = function(x, y, w, h, r, c)
    if DL then DL:add_rect_filled({ x, y }, { x + w, y + h }, col(c), r + 0.0, 0) end
end
A.outline_rect = function(x, y, w, h, r, t, c)
    if DL then DL:add_rect({ x, y }, { x + w, y + h }, col(c), r + 0.0, 0, t + 0.0) end
end
A.line = function(x1, y1, x2, y2, t, c)
    if DL then DL:add_line({ x1, y1 }, { x2, y2 }, col(c), t + 0.0) end
end
A.fill_circle = function(x, y, r, c)
    if DL then DL:add_circle_filled({ x, y }, r + 0.0, col(c), 0) end
end
A.circle = function(x, y, r, t, c)
    if DL then DL:add_circle({ x, y }, r + 0.0, col(c), 0, t + 0.0) end
end
A.fill_quad = function(x1, y1, x2, y2, x3, y3, x4, y4, c)
    if DL then DL:add_quad_filled({ x1, y1 }, { x2, y2 }, { x3, y3 }, { x4, y4 }, col(c)) end
end

local function refresh_surface()
    local ok, v = pcall(imgui.get_display_size)
    if not ok or not v or type(v.x) ~= "number" or type(v.y) ~= "number" or v.x <= 0 or v.y <= 0 then return false end
    surface_w, surface_h = v.x, v.y
    return true
end

-- 每次绘制开始时调用;拿不到屏幕尺寸时返回 false,这一帧不画
function D.reset_frame(scale, font_scale)
    if not refresh_surface() then return false end
    local ok, dl = pcall(imgui.get_background_draw_list)
    DL = ok and dl or nil
    if not DL then return false end
    font_scale = font_scale or 1.0
    if scale ~= D.S or font_scale ~= D.FS then
        D.S, D.FS = scale, font_scale
        fonts, measure_cache, measure_count = {}, {}, 0
    end
    clip_stack, clip = {}, nil
    deferred = {}
    return true
end

-- ---------------------------------------------------------------- 字体 / 文字
function D.font(size, bold)
    size = size or T.font.body
    local key = size * 2 + (bold and 1 or 0)
    local f = fonts[key]
    if f == nil then
        f = setmetatable({ px = max(6, floor(size * D.S * D.FS + 0.5)), bold = bold == true }, font_mt)
        fonts[key] = f
    end
    return f
end

-- 逻辑宽高
function D.measure(f, s)
    if not f or s == nil or s == "" then return 0, 0 end
    local per = measure_cache[f]
    if not per then per = {}; measure_cache[f] = per end
    local m = per[s]
    if m then return m[1], m[2] end
    local ok, w, h = pcall(f.measure, f, s)
    if not ok then w, h = 0, 0 end
    w, h = (w or 0) / D.S, (h or 0) / D.S
    measure_count = measure_count + 1
    if measure_count > 4000 then measure_cache, measure_count = {}, 0 end
    per[s] = { w, h }
    return w, h
end

local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- 超宽时截断并加省略号
function D.fit(f, s, max_w)
    s = tostring(s or "")
    if max_w <= 0 then return "" end
    if D.measure(f, s) <= max_w then return s end
    local chars = {}
    for ch in s:gmatch(UTF8_CHAR) do chars[#chars + 1] = ch end
    local lo, hi = 0, #chars
    while lo < hi do
        local mid = floor((lo + hi + 1) / 2)
        if D.measure(f, table.concat(chars, "", 1, mid) .. "…") <= max_w then lo = mid else hi = mid - 1 end
    end
    return table.concat(chars, "", 1, lo) .. "…"
end

-- 按宽度折行:中文逐字折,英文尽量在空格处折。返回行列表(按 字号 / 宽度 / 文字 缓存:
-- 折行要量很多段子串,不缓存的话帮助页每帧都在量字)
local wrap_cache, wrap_count = {}, 0
function D.wrap(f, s, max_w)
    local key = f.px .. "|" .. floor(max_w) .. "|" .. tostring(s)
    local hit = wrap_cache[key]
    if hit then return hit end
    local lines = D._wrap(f, s, max_w)
    wrap_count = wrap_count + 1
    if wrap_count > 2000 then wrap_cache, wrap_count = {}, 0 end
    wrap_cache[key] = lines
    return lines
end
function D._wrap(f, s, max_w)
    local lines = {}
    for para in (tostring(s or "") .. "\n"):gmatch("(.-)\n") do
        if para == "" then lines[#lines + 1] = ""
        else
            local chars = {}
            for ch in para:gmatch(UTF8_CHAR) do chars[#chars + 1] = ch end
            local start = 1
            while start <= #chars do
                local lo, hi = start, #chars
                while lo < hi do
                    local mid = floor((lo + hi + 1) / 2)
                    if D.measure(f, table.concat(chars, "", start, mid)) <= max_w then lo = mid else hi = mid - 1 end
                end
                local stop = lo
                if stop < #chars then
                    -- 往回找空格(最多回退 24 个字符),避免把英文单词拆开
                    for k = stop, max(start, stop - 24), -1 do
                        if chars[k] == " " then stop = k; break end
                    end
                end
                lines[#lines + 1] = table.concat(chars, "", start, stop)
                start = stop + 1
                while chars[start] == " " do start = start + 1 end
            end
        end
    end
    return lines
end

local function inside_y(y, h)
    return not clip or (y >= clip[2] - 0.5 and y + h <= clip[4] + 0.5)
end

-- 左上角在 (x, y) 的文字;max_w 截断。返回画出的宽度
function D.text(s, x, y, color, f, max_w)
    f = f or D.font()
    if not f or s == nil then return 0 end
    s = tostring(s)
    if not utf8.len(s) then return 0 end
    if max_w then s = D.fit(f, s, max_w) end
    local w, h = D.measure(f, s)
    if not inside_y(y, h) then return w end
    if clip and (x > clip[3] or x + w < clip[1]) then return w end
    A.text(f, s, x * D.S, y * D.S, color or T.c.text)
    return w
end

function D.text_center(s, x, y, w, h, color, f)
    f = f or D.font()
    local tw, th = D.measure(f, s)
    if tw > w then return D.text(s, x, y + (h - th) / 2, color, f, w) end
    return D.text(s, x + (w - tw) / 2, y + (h - th) / 2, color, f)
end

-- 在一行里垂直居中、左对齐
function D.text_mid(s, x, y, h, color, f, max_w)
    f = f or D.font()
    local _, th = D.measure(f, "Ag国")
    return D.text(s, x, y + (h - th) / 2, color, f, max_w)
end

-- 折行文字,返回用掉的高度
function D.paragraph(s, x, y, w, color, f, line_h)
    f = f or D.font()
    local _, th = D.measure(f, "Ag国")
    line_h = line_h or (th + 4)
    local cy = y
    for _, line in ipairs(D.wrap(f, s, w)) do
        D.text(line, x, cy, color, f)
        cy = cy + line_h
    end
    return cy - y
end

-- ---------------------------------------------------------------- 图形
local function cut(x, y, w, h)
    if not clip then return x, y, w, h, true end
    local x0, y0 = max(x, clip[1]), max(y, clip[2])
    local x1, y1 = min(x + w, clip[3]), min(y + h, clip[4])
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1 - x0, y1 - y0, (x0 == x and y0 == y and x1 == x + w and y1 == y + h)
end

function D.rect(x, y, w, h, color)
    local cx, cy, cw, ch = cut(x, y, w, h)
    if not cx then return end
    local S = D.S
    A.fill_rect(cx * S, cy * S, cw * S, ch * S, color)
end

function D.rrect(x, y, w, h, r, color)
    local cx, cy, cw, ch, whole = cut(x, y, w, h)
    if not cx then return end
    local S = D.S
    if whole and r and r > 0 then A.fill_rounded_rect(x * S, y * S, w * S, h * S, r * S, color)
    else A.fill_rect(cx * S, cy * S, cw * S, ch * S, color) end
end

function D.outline(x, y, w, h, r, thickness, color)
    local _, _, _, _, whole = cut(x, y, w, h)
    if not whole then
        local t = thickness or 1
        D.rect(x, y, w, t, color); D.rect(x, y + h - t, w, t, color)
        D.rect(x, y, t, h, color); D.rect(x + w - t, y, t, h, color)
        return
    end
    local S = D.S
    A.outline_rect(x * S, y * S, w * S, h * S, (r or 0) * S, (thickness or 1) * S, color)
end

function D.line(x1, y1, x2, y2, thickness, color)
    if clip and (max(y1, y2) < clip[2] or min(y1, y2) > clip[4]) then return end
    local S = D.S
    A.line(x1 * S, y1 * S, x2 * S, y2 * S, (thickness or 1) * S, color)
end

function D.fill_circle(x, y, r, color)
    if not inside_y(y - r, 2 * r) then return end
    A.fill_circle(x * D.S, y * D.S, r * D.S, color)
end

function D.circle(x, y, r, thickness, color)
    if not inside_y(y - r, 2 * r) then return end
    A.circle(x * D.S, y * D.S, r * D.S, (thickness or 1) * D.S, color)
end

function D.quad(x1, y1, x2, y2, x3, y3, x4, y4, color)
    local S = D.S
    A.fill_quad(x1 * S, y1 * S, x2 * S, y2 * S, x3 * S, y3 * S, x4 * S, y4 * S, color)
end

-- ---------------------------------------------------------------- 图标(画出来的,字体里未必有 ✕ ▾ ▸)
function D.icon_x(cx, cy, s, color)
    D.line(cx - s, cy - s, cx + s, cy + s, 1.5, color)
    D.line(cx - s, cy + s, cx + s, cy - s, 1.5, color)
end

-- 实心三角:朝下(展开)或朝右(收起)
function D.icon_tri(cx, cy, s, down, color)
    if not inside_y(cy - s, 2 * s) then return end
    if down then D.quad(cx - s, cy - s * 0.5, cx + s, cy - s * 0.5, cx, cy + s * 0.6, cx, cy + s * 0.6, color)
    else D.quad(cx - s * 0.5, cy - s, cx + s * 0.6, cy, cx + s * 0.6, cy, cx - s * 0.5, cy + s, color) end
end

-- 朝上 / 朝下的小箭头(上移 / 下移按钮)
function D.icon_arrow(cx, cy, s, up, color)
    if not inside_y(cy - s, 2 * s) then return end
    if up then D.quad(cx - s, cy + s * 0.5, cx, cy - s * 0.6, cx, cy - s * 0.6, cx + s, cy + s * 0.5, color)
    else D.quad(cx - s, cy - s * 0.5, cx + s, cy - s * 0.5, cx, cy + s * 0.6, cx, cy + s * 0.6, color) end
end

-- ---------------------------------------------------------------- 裁剪 / 延后绘制
function D.push_clip(x, y, w, h)
    clip_stack[#clip_stack + 1] = clip or false
    local c = { x, y, x + w, y + h }
    if clip then
        c[1], c[2] = max(c[1], clip[1]), max(c[2], clip[2])
        c[3], c[4] = min(c[3], clip[3]), min(c[4], clip[4])
    end
    clip = c
end

function D.pop_clip()
    clip = clip_stack[#clip_stack] or nil
    clip_stack[#clip_stack] = nil
end

function D.get_clip() return clip end

function D.defer(fn) deferred[#deferred + 1] = fn end

function D.flush_deferred()
    local list = deferred
    deferred = {}
    local saved = clip
    clip = nil
    for _, fn in ipairs(list) do pcall(fn) end
    clip = saved
end

-- 物理像素 / 逻辑尺寸
function D.surface_pixels() return surface_w, surface_h end
function D.surface_size() return surface_w / D.S, surface_h / D.S end

return D
