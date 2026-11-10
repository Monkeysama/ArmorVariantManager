-- 独立面板的即时模式控件:每个控件画自己,返回这次绘制里用户做了什么。
-- id 只对跨绘制保持状态的控件有意义(滑条拖动、展开的下拉框、滚动位置、正在编辑的输入框)。
-- 基础控件改编自 ShapeKeySystem 的 ShapeKeySystem_UI/Widgets.lua(d026d06,2026-11-04);
-- 分段按钮、三态、状态圆点、数值框 / 提交框、流式排版是 AVM 加的。

local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")
local TextInput = require("ArmorVariantManager_Core.Games.RE4.Panel.TextInput")

local W = {}
local C = T.c
local max, min, floor, abs = math.max, math.min, math.floor, math.abs

W.open_select = nil      -- 展开的下拉框 id
W.pending = {}
local scroll = {}        -- id -> 滚动位置
local scroll_stack = {}
local select_offsets = {}
local select_grab = 0

local function small() return D.font(T.font.small) end
local function body() return D.font(T.font.body) end
local function bold() return D.font(T.font.body, true) end
W.small, W.body, W.bold = small, body, bold

function W.text_w(label, f) return (D.measure(f or body(), label)) end

-- ---------------------------------------------------------------- 基础
function W.panel_box(x, y, w, h, accent)
    D.rrect(x, y, w, h, T.m.radius, C.panel2)
    D.outline(x, y, w, h, T.m.radius, 1, C.line)
    if accent then D.rect(x + 1, y, w - 2, 2, accent) end
end

function W.label(text, x, y, color, max_w)
    return D.text(text, x, y, color or C.muted, small(), max_w)
end

function W.h2(text, x, y, max_w)
    return D.text(text, x, y, C.text, D.font(T.font.big, true), max_w)
end

-- 小标签(圆角边框 + 文字)。返回宽度
function W.tag(text, x, y, color, h)
    h = h or 20
    local f = small()
    local w = D.measure(f, text) + 14
    D.rrect(x, y, w, h, h / 2, C.ink)
    D.outline(x, y, w, h, h / 2, 1, color or C.line)
    D.text_center(text, x, y, w, h, color or C.muted, f)
    return w
end
function W.tag_w(text) return D.measure(small(), text) + 14 end

function W.meter(x, y, w, h, v, color)
    D.rect(x, y, w, h, C.ink)
    D.outline(x, y, w, h, 0, 1, C.line)
    v = max(0, min(1, v or 0))
    if v > 0 then D.rect(x + 1, y + 1, (w - 2) * v, h - 2, color or C.signal) end
end

function W.separator(x, y, w) D.rect(x, y, w, 1, C.line) end

-- 悬停提示,画在最上层
function W.tooltip(text, x, y, w, h)
    if not text or text == "" or I.active or not I.hit(x, y, w, h) then return end
    D.defer(function()
        local f = small()
        local sw = D.surface_size()
        local lines = D.wrap(f, text, 420)
        local tw = 0
        for _, l in ipairs(lines) do tw = max(tw, (D.measure(f, l))) end
        local _, lh = D.measure(f, "Ag国")
        local th = #lines * (lh + 2)
        local tx = min(I.mx + 14, sw - tw - 20)
        local ty = I.my + 18
        D.rrect(tx, ty, tw + 12, th + 8, 3, C.ink)
        D.outline(tx, ty, tw + 12, th + 8, 3, 1, C.line)
        for i, l in ipairs(lines) do D.text(l, tx + 6, ty + 4 + (i - 1) * (lh + 2), C.text, f) end
    end)
end

-- 状态圆点:颜色之外还有形状(照顾色弱)
--   active 实心绿 / partial 半实心绿 / outranked 红色带斜线 / idle 空心灰 / off 虚线灰 / paused 空心灰
function W.status_dot(kind, cx, cy, r)
    r = r or 5
    if kind == "active" then D.fill_circle(cx, cy, r, C.ok)
    elseif kind == "partial" then
        D.circle(cx, cy, r, 1.5, C.ok)
        D.quad(cx - r * 0.7, cy, cx + r * 0.7, cy, cx + r * 0.5, cy + r * 0.6, cx - r * 0.5, cy + r * 0.6, C.ok)
    elseif kind == "outranked" then
        D.circle(cx, cy, r, 1.5, C.error)
        D.line(cx - r * 0.7, cy + r * 0.7, cx + r * 0.7, cy - r * 0.7, 1.5, C.error)
    elseif kind == "off" then
        for k = 0, 5 do
            local a = k * math.pi / 3
            D.fill_circle(cx + math.cos(a) * r, cy + math.sin(a) * r, 1, C.faint)
        end
    else D.circle(cx, cy, r, 1.5, C.faint) end
end

-- ---------------------------------------------------------------- 按钮
-- opt: kind = "primary" | "ghost" | "danger", disabled, pressed, font, text_color, tip
function W.button_w(label, opt) return D.measure((opt and opt.font) or body(), label) + 22 end
function W.button(label, x, y, w, h, opt)
    opt = opt or {}
    local f = opt.font or body()
    if not w then w = D.measure(f, label) + 22 end
    h = h or T.m.row_h
    local hover = not opt.disabled and I.hit(x, y, w, h) and not I.active
    local bg, border, fg = C.panel3, C.line, C.text
    if opt.kind == "primary" then bg, border, fg = C.brass_dim, C.brass, 0xFFFFF6E2
    elseif opt.kind == "ghost" then bg = 0x00000000
    elseif opt.kind == "danger" then bg, border, fg = 0x00000000, C.error, C.error end
    if opt.pressed then bg, border, fg = C.brass_dim, C.brass, 0xFFFFF6E2 end
    if opt.eff then border, fg = C.ok, C.ok end
    if hover then border = (opt.kind == "danger") and C.error or C.muted end
    if opt.disabled then fg = C.faint end
    fg = opt.text_color or fg
    if bg ~= 0 then D.rrect(x, y, w, h, 3, bg) end
    D.outline(x, y, w, h, 3, 1, border)
    D.text_center(label, x, y, w, h, fg, f)
    if opt.tip then W.tooltip(opt.tip, x, y, w, h) end
    local clicked = not opt.disabled and I.click(x, y, w, h)
    return clicked, w
end

-- 小号文字按钮(行内操作)
function W.tbutton_w(label) return D.measure(small(), label) + 22 end
function W.tbutton(label, x, y, opt)
    opt = opt or {}
    opt.font = small()
    opt.kind = opt.kind or "ghost"
    return W.button(label, x, y, nil, 22, opt)
end

-- 画出来的 ✕
function W.close_button(x, y, s)
    local hover = I.hit(x, y, s, s) and not I.active
    D.outline(x, y, s, s, 3, 1, hover and C.muted or C.line)
    D.icon_x(x + s / 2, y + s / 2, s * 0.22, hover and C.text or C.muted)
    return I.click(x, y, s, s)
end

-- 行内的小 ✕(删除条件之类)
function W.x_button(x, y, s, disabled)
    s = s or 22
    local hover = not disabled and I.hit(x, y, s, s) and not I.active
    D.icon_x(x + s / 2, y + s / 2, s * 0.2, disabled and C.faint or (hover and C.error or C.muted))
    return not disabled and I.click(x, y, s, s)
end

-- 上移 / 下移小按钮。返回 -1 / 1 / nil
function W.move_buttons(x, y, disabled)
    local s = 22
    local res
    for k, up in ipairs({ true, false }) do
        local bx = x + (k - 1) * (s + 2)
        local hover = not disabled and I.hit(bx, y, s, s) and not I.active
        D.outline(bx, y, s, s, 3, 1, hover and C.muted or C.line)
        D.icon_arrow(bx + s / 2, y + s / 2, 4, up, disabled and C.faint or (hover and C.text or C.muted))
        if not disabled and I.click(bx, y, s, s) then res = up and -1 or 1 end
    end
    return res, 2 * s + 2
end

-- 展开 / 收起的小三角。返回 clicked
function W.caret(x, y, open, h)
    h = h or T.m.row_h
    local hover = I.hit(x, y, 18, h)
    D.icon_tri(x + 9, y + h / 2, 4, open, hover and C.text or C.brass)
    return I.click(x, y, 18, h)
end

-- 开关 + 文字。返回 changed, value, width
function W.toggle(label, x, y, value, opt)
    opt = opt or {}
    local f = opt.font or body()
    local lw = label and label ~= "" and (D.measure(f, label) + 8) or 0
    local h = opt.h or T.m.row_h
    local w = 30 + lw
    local sy = y + (h - 16) / 2
    local disabled = opt.disabled
    D.rrect(x, sy, 30, 16, 8, value and C.brass_dim or C.panel3)
    D.outline(x, sy, 30, 16, 8, 1, value and C.brass or C.line)
    D.fill_circle(value and (x + 22) or (x + 8), sy + 8, 6, disabled and C.faint or (value and C.brass or C.muted))
    if lw > 0 then D.text_mid(label, x + 38, y, h, (value and not disabled) and C.text or C.muted, f) end
    if opt.tip then W.tooltip(opt.tip, x, y, w, h) end
    if not disabled and I.click(x, y, w, h) then return true, not value, w end
    return false, value, w
end
function W.toggle_w(label, f) return 30 + ((label and label ~= "") and (D.measure(f or body(), label) + 8) or 0) end

-- 勾选框 + 文字。返回 changed, value, width
function W.checkbox(label, x, y, value, opt)
    opt = opt or {}
    local f = opt.font or body()
    local h = opt.h or T.m.row_h
    local lw = label and label ~= "" and (D.measure(f, label) + 6) or 0
    local w = 16 + lw
    local by = y + (h - 14) / 2
    local hover = not opt.disabled and I.hit(x, y, w, h)
    D.rrect(x, by, 14, 14, 2, C.ink)
    D.outline(x, by, 14, 14, 2, 1, value and C.brass or (hover and C.muted or C.line))
    if value then D.rrect(x + 3, by + 3, 8, 8, 1, opt.disabled and C.faint or C.brass) end
    if lw > 0 then D.text_mid(label, x + 20, y, h, opt.color or (opt.disabled and C.faint or C.text), f) end
    if opt.tip then W.tooltip(opt.tip, x, y, w, h) end
    if not opt.disabled and I.click(x, y, w, h) then return true, not value, w end
    return false, value, w
end
function W.checkbox_w(label, f) return 16 + ((label and label ~= "") and (D.measure(f or body(), label) + 6) or 0) end

-- 分段按钮(一组互斥选项)。items = { { label, value, eff = bool, tip }, ... }
-- 按 w 自动折行。返回 clicked_value(或 nil)和用掉的高度
function W.segments(x, y, w, items, current, opt)
    opt = opt or {}
    local h = opt.h or 26
    local f = opt.font or small()
    local bx, by = x, y
    local picked
    for _, it in ipairs(items) do
        local bw = D.measure(f, it[1]) + 20
        if bx > x and bx + bw > x + w then bx, by = x, by + h + 4 end
        local clicked = W.button(it[1], bx, by, bw, h, { font = f, pressed = it[2] == current and not it.eff,
            eff = it.eff, disabled = opt.disabled, tip = it.tip or opt.tip })
        if clicked then picked = it[2] end
        bx = bx + bw + 4
    end
    return picked, by - y + h
end

-- 三态「- | 关 | 开」(状态组)或二态「关 | 开」(整套造型)。返回新值或 nil、宽度
function W.tri(x, y, value, labels, two, disabled)
    local opts = two and { { "off", labels.off }, { "on", labels.on } }
        or { { "none", "-" }, { "off", labels.off }, { "on", labels.on } }
    local f = small()
    local bx = x
    local res
    for _, o in ipairs(opts) do
        local bw = max(26, D.measure(f, o[2]) + 14)
        local on = value == o[1]
        local col = o[1] == "on" and C.ok or (o[1] == "off" and C.error or C.muted)
        local hover = not disabled and I.hit(bx, y, bw, 22) and not I.active
        if on then D.rrect(bx, y, bw, 22, 3, o[1] == "on" and C.ok_dim or (o[1] == "off" and C.error_dim or C.panel3)) end
        D.outline(bx, y, bw, 22, 3, 1, on and col or (hover and C.muted or C.line))
        D.text_center(o[2], bx, y, bw, 22, on and col or (disabled and C.faint or C.muted), f)
        if not disabled and I.click(bx, y, bw, 22) then res = o[1] end
        bx = bx + bw + 2
    end
    return res, bx - x
end

-- ---------------------------------------------------------------- 滑条
-- opt: step, disabled, fmt(数值文字格式), value_w。返回 changed, value, released(这次绘制刚松手)
-- 松手:I.begin_frame 在鼠标抬起后就清掉 I.active,所以按"上一次绘制还是它在拖、这次不是了"判断
local dragging = {}
function W.slider(id, x, y, w, h, value, lo, hi, opt)
    opt = opt or {}
    h = h or T.m.row_h
    local vw = opt.fmt and (opt.value_w or 50) or 0
    local tw = w - vw - (vw > 0 and 8 or 0)
    local ty = y + h / 2 - 2
    local range = max(1e-6, hi - lo)
    value = value or lo
    local changed, released = false, false
    if not opt.disabled then
        if I.active == nil and I.click(x - 6, y, tw + 12, h) then I.active = id end
        if I.active == id and I.down then
            local r = max(0, min(1, (I.mx - x) / tw))
            local v = lo + r * range
            if opt.step and opt.step > 0 then v = floor(v / opt.step + 0.5) * opt.step end
            v = max(lo, min(hi, v))
            if abs(v - value) > 1e-9 then value, changed = v, true end
        end
    end
    if I.active == id then dragging[id] = true
    elseif dragging[id] then dragging[id] = nil; released = true end
    local r = max(0, min(1, (value - lo) / range))
    local hover = not opt.disabled and (I.active == id or (I.active == nil and I.hit(x - 6, y, tw + 12, h)))
    D.rrect(x, ty, tw, 4, 2, C.panel3)
    if r > 0 then D.rrect(x, ty, tw * r, 4, 2, opt.disabled and C.faint or (opt.color or C.brass_dim)) end
    local kx = x + tw * r
    D.rrect(kx - 6, ty - 5, 12, 14, 3, opt.disabled and C.faint or (hover and 0xFFF0C070 or C.brass))
    if vw > 0 then
        D.text_mid(string.format(opt.fmt, value), x + tw + 8, y, h, opt.disabled and C.faint or C.text, small())
    end
    return changed, value, released
end
-- ---------------------------------------------------------------- 下拉框
local function selection_scroll(id, x, y, w, h, content_h, offset, step)
    local limit = max(0, content_h - h)
    offset = max(0, min(offset or 0, limit))
    if I.wheel ~= 0 and I.hit(x, y, w, h) then
        offset = max(0, min(limit, offset - I.wheel * step))
        I.wheel = 0
    end
    if limit == 0 then return offset, 0 end
    local bx, bw = x + w - 10, 6
    local th = min(h, max(24, h * h / content_h))
    local travel = h - th
    local ty = y + travel * offset / limit
    local key = "select-sb:" .. id
    if I.active == nil and I.click(bx - 2, y, bw + 4, h) then
        select_grab = I.my >= ty and I.my < ty + th and (I.my - ty) or th / 2
        I.active = key
    end
    if I.active == key and I.down and travel > 0 then
        offset = max(0, min(limit, (I.my - y - select_grab) / travel * limit))
        ty = y + travel * offset / limit
    end
    D.rrect(bx, y, bw, h, 2, C.ink)
    D.rrect(bx, ty, bw, th, 2, I.active == key and C.muted or C.faint)
    return offset, 14
end

-- 下拉选择:labels 是名字列表;opt.headers[i] = true 的项是不可选的分组标题。
-- 浮层延后绘制,选中的结果在下一次绘制返回。返回 changed, index
function W.select(id, x, y, w, h, labels, index, opt)
    opt = opt or {}
    h = h or T.m.row_h
    local headers = opt.headers or {}
    local open = W.open_select == id
    local hover = not opt.disabled and I.hit(x, y, w, h)
    D.rrect(x, y, w, h, 3, C.ink)
    D.outline(x, y, w, h, 3, 1, (open or hover) and C.muted or C.line)
    D.text_mid(labels[index] or opt.placeholder or "-", x + 8, y, h, opt.disabled and C.faint or (opt.color or C.text),
        opt.font or small(), w - 28)
    D.icon_tri(x + w - 13, y + h / 2, 4, true, C.muted)
    if opt.tip then W.tooltip(opt.tip, x, y, w, h) end
    local p = W.pending[id]
    W.pending[id] = nil
    if not opt.disabled and I.click(x, y, w, h) then
        if open then W.open_select = nil else W.open_select = id end
        open = not open
        if #labels == 0 then W.open_select, open = nil, false end
    end
    if not open then
        if p and p ~= index then return true, p end
        return false, index
    end
    local ih = 24
    local n = #labels
    local pw = max(w, opt.popup_w or 0)
    local _, sh = D.surface_size()
    local ph = min(n * ih, 360, max(ih, sh - 66))
    local py = y + h + 2
    if py + ph > sh - 10 then py = y - ph - 2 end
    py = max(10, min(py, sh - ph - 10))
    local offset = select_offsets[id] or max(0, (index or 1) * ih - ph)
    I.add_overlay(x, py, pw, ph)
    local result
    D.defer(function()
        I.in_overlay = true
        D.rrect(x, py, pw, ph, 3, C.panel2)
        D.outline(x, py, pw, ph, 3, 1, C.muted)
        local gutter
        offset, gutter = selection_scroll(id, x, py, pw, ph, n * ih, offset, ih * 3)
        select_offsets[id] = offset
        D.push_clip(x + 1, py, pw - gutter - 2, ph)
        for i, label in ipairs(labels) do
            local iy = py + (i - 1) * ih - offset
            if iy + ih > py and iy < py + ph then
                if headers[i] then
                    D.text_mid(label, x + 8, iy, ih, C.faint, small(), pw - gutter - 16)
                else
                    local hov = I.active == nil and I.hit(x, iy, pw - gutter, ih)
                    if hov or i == index then D.rect(x + 1, iy, pw - gutter - 2, ih, hov and C.panel3 or C.ink) end
                    D.text_mid(label, x + (next(headers) and 18 or 8), iy, ih, i == index and C.brass or C.text, body(), pw - gutter - 26)
                    if I.active == nil and I.click(x, iy, pw - gutter, ih) then result = i end
                end
            end
        end
        D.pop_clip()
        I.in_overlay = false
    end)
    D.defer(function()
        if result then
            W.pending[id] = result
            W.open_select = nil
        elseif I.clicked and not I.inside(x, py, pw, ph) and not I.inside(x, y, w, h) then
            W.open_select = nil
        end
    end)
    if p and p ~= index then return true, p end
    return false, index
end

-- ---------------------------------------------------------------- 可折叠的标题
-- 返回 clicked、高度
function W.header(label, x, y, w, open, stat, stat_color)
    local h = 26
    local f = bold()
    D.icon_tri(x + 7, y + h / 2, 4, open, C.brass)
    local lw = D.text_mid(label, x + 18, y, h, C.text, f)
    local sx = x + 26 + lw
    if stat and stat ~= "" then sx = sx + D.text_mid(stat, sx, y, h, stat_color or C.muted, small(), max(0, x + w - sx - 10)) + 10 end
    D.rect(min(sx, x + w), y + h / 2, max(0, x + w - sx), 1, C.line)
    return I.click(x, y, w, h), h
end

-- ---------------------------------------------------------------- 输入框
-- 原位输入框:自绘边框和占位文字,标准 ImGui InputText 负责文字本身。on_change 每次按键都会调用
function W.text_box(id, x, y, w, h, value, placeholder, on_change, opt)
    opt = opt or {}
    h = h or T.m.row_h
    local hover = I.hit(x, y, w, h)
    D.rrect(x, y, w, h, 3, C.ink)
    D.outline(x, y, w, h, 3, 1, (TextInput.active == id and C.brass) or (hover and C.muted or C.line))
    local registered = not opt.disabled and not I.locked and TextInput.register(id, x, y, w, h, value, on_change)
    if not registered and value and value ~= "" then D.text_mid(value, x + 8, y, h, opt.disabled and C.faint or C.text, body(), w - 16)
    elseif (not value or value == "") and TextInput.active ~= id then
        D.text_mid(placeholder or "", x + 8, y, h, C.faint, body(), w - 16)
    end
    if opt.tip then W.tooltip(opt.tip, x, y, w, h) end
    if I.click(x, y, w, h) and registered then
        TextInput.request_focus(id)
        W.text_clicked = true
    end
end

-- 草稿输入框:编辑时只改草稿,离开(失去焦点)时把草稿交给 on_commit;外部值变了且没在编辑就跟着变。
-- drafts 是页面持有的表。
function W.commit_box(drafts, id, x, y, w, h, value, placeholder, on_commit, opt)
    local d = drafts[id]
    if d and TextInput.active ~= id and d.seen then
        drafts[id] = nil
        if d.text ~= d.base then on_commit(d.text) end
        d = nil
    end
    if d and TextInput.active == id then d.seen = true end
    if not d then d = { text = value or "", base = value or "" }; drafts[id] = d end
    if TextInput.active ~= id and not d.seen and d.base ~= (value or "") then d.text, d.base = value or "", value or "" end
    W.text_box(id, x, y, w, h, d.text, placeholder, function(t) d.text = t; d.seen = true end, opt)
end

-- 数值框:同 REFF 页的 Re4Num —— 离开时提交;不是数字就退回原值;min / max 是硬范围。
-- allow_empty:清空 = 不设(提交 nil)。显示最多 3 位小数、去掉末尾的 0
local function fmt_num(v)
    if type(v) ~= "number" then return "" end
    local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
    if s == "-0" then s = "0" end
    return s
end
W.fmt_num = fmt_num
function W.num_box(drafts, id, x, y, w, value, opt, on_commit)
    opt = opt or {}
    W.commit_box(drafts, id, x, y, w, 24, fmt_num(value), opt.placeholder, function(raw)
        raw = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("，", "."):gsub("。", ".")
        if raw == "" then
            if opt.allow_empty and value ~= nil then on_commit(nil) end
            return
        end
        local n = tonumber(raw)
        if not n then return end
        if opt.min then n = max(opt.min, n) end
        if opt.max then n = min(opt.max, n) end
        n = floor(n * 1000 + 0.5) / 1000
        if n ~= value then on_commit(n) end
    end, opt)
end

-- ---------------------------------------------------------------- 流式排版
-- 从左往右放东西,放不下就换行。F:place(width, h) 返回 x, y;F:height() 返回总高度
local Flow = {}
Flow.__index = Flow
function W.flow(x, y, w, gap, row_h)
    return setmetatable({ x0 = x, y0 = y, w = w, x = x, y = y, gap = gap or 8, row_h = row_h or T.m.row_h, line_h = 0 }, Flow)
end
function Flow:place(width, h)
    h = h or self.row_h
    if self.x > self.x0 and self.x + width > self.x0 + self.w then self:newline() end
    local px, py = self.x, self.y
    self.x = self.x + width + self.gap
    self.line_h = max(self.line_h, h)
    return px, py
end
function Flow:newline()
    self.y = self.y + max(self.line_h, self.row_h) + 4
    self.x, self.line_h = self.x0, 0
end
function Flow:remaining() return self.x0 + self.w - self.x end
function Flow:height() return self.y - self.y0 + (self.x > self.x0 and max(self.line_h, self.row_h) or 0) end
-- 常用组合
function Flow:button(label, opt)
    opt = opt or {}
    opt.font = opt.font or small()
    local bw = W.button_w(label, opt)
    local bx, by = self:place(bw, 26)
    return (W.button(label, bx, by + (self.row_h - 26) / 2, bw, 26, opt))
end
function Flow:text(s, color, f)
    f = f or small()
    local tw = D.measure(f, s)
    local maxw = self.w
    if tw > maxw then tw = maxw end
    local bx, by = self:place(tw, self.row_h)
    D.text_mid(s, bx, by, self.row_h, color or C.muted, f, maxw)
end
function Flow:tag(s, color)
    local tw = W.tag_w(s)
    local bx, by = self:place(tw, self.row_h)
    W.tag(s, bx, by + (self.row_h - 20) / 2, color)
end
function Flow:toggle(label, value, opt)
    local tw = W.toggle_w(label, (opt and opt.font) or body())
    local bx, by = self:place(tw, self.row_h)
    local changed, v = W.toggle(label, bx, by, value, opt)
    return changed, v
end
function Flow:checkbox(label, value, opt)
    local tw = W.checkbox_w(label, (opt and opt.font) or body())
    local bx, by = self:place(tw, self.row_h)
    local changed, v = W.checkbox(label, bx, by, value, opt)
    return changed, v
end

-- 二次确认条:说明文字(折行)+ 确认 / 取消。返回 "yes" / "no" / nil 和高度
function W.confirm(x, y, w, text, yes_label, no_label, kind, color)
    local f = small()
    local lines = D.wrap(f, text, w - 24)
    local th = #lines * 18
    local h = th + 46
    D.rrect(x, y, w, h, 3, C.ink)
    D.outline(x, y, w, h, 3, 1, color or C.warn)
    for i, l in ipairs(lines) do D.text(l, x + 12, y + 8 + (i - 1) * 18, color or C.warn, f) end
    local res
    local bx = x + 12
    local c1, bw = W.button(yes_label, bx, y + th + 12, nil, 26, { kind = kind or "primary", font = f })
    if c1 then res = "yes" end
    if W.button(no_label, bx + bw + 8, y + th + 12, nil, 26, { font = f }) then res = "no" end
    return res, h + 6
end

-- 折行说明文字,返回高度
function W.note(text, x, y, w, color)
    return D.paragraph(text, x, y, w, color or C.muted, small(), 18)
end

-- ---------------------------------------------------------------- 滚动区
-- local y0 = W.begin_scroll(id, x, y, w, h) ... W.end_scroll(content_h)
function W.begin_scroll(id, x, y, w, h)
    local off = scroll[id] or 0
    scroll_stack[#scroll_stack + 1] = { id = id, x = x, y = y, w = w, h = h }
    D.push_clip(x, y, w, h)
    return y - off
end

function W.end_scroll(content_h)
    local s = table.remove(scroll_stack)
    D.pop_clip()
    local maxoff = max(0, content_h - s.h)
    local off = min(scroll[s.id] or 0, maxoff)
    if I.wheel ~= 0 and I.inside(s.x, s.y, s.w, s.h) and not I.over_overlay() then
        off = max(0, min(maxoff, off - I.wheel * 60))
        I.wheel = 0
    end
    if maxoff > 0 then
        local bx, bw = s.x + s.w - 6, 4
        local th = max(24, s.h * s.h / content_h)
        local ty = s.y + (s.h - th) * (off / maxoff)
        local key = "sb:" .. s.id
        if I.active == nil and I.click(bx - 4, s.y, bw + 8, s.h) then I.active = key end
        if I.active == key and I.down then
            off = max(0, min(maxoff, (I.my - s.y - th / 2) / (s.h - th) * maxoff))
            ty = s.y + (s.h - th) * (off / maxoff)
        end
        D.rrect(bx, ty, bw, th, 2, I.active == key and C.muted or C.faint)
    end
    scroll[s.id] = off
end

function W.reset_scroll(id) scroll[id] = 0 end

-- 可见性:在当前裁剪区里(行很多时跳过画不到的行)
function W.visible(y, h)
    local c = D.get_clip()
    return not c or (y + h >= c[2] and y <= c[4])
end

return W
