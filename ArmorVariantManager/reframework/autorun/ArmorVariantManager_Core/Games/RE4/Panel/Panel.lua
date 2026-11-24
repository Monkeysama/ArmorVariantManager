-- 没有 REFF 时的兜底图形界面:一个独立窗口,画在 ImGui 背景绘制列表上(外观和交互照 SKS 的面板)。
--
-- 数据和 REFF 页面同一份:Reff.lua 的控制器 snapshot() / action()(不依赖 REFF 本身)。
-- 所以两个界面的语义、校验和"换了角色就拒绝"的保护完全一致;这里只是 Lua 版的前端。
--
-- 砍掉的:全身预览(画不了 render target)、拖动排序(换成 ▲▼ 按钮)、左侧常驻栏
-- (游戏状态 / 最终材质只放在快速切换页)。
--
-- 每帧(Main 的 re.on_frame 里):frame() 采样输入 → draw() 布局并绘制 → draw_inputs() 画原位输入框。
-- 窗口打开时 InputGuard 屏蔽游戏鼠标、放开光标(和 REFF 同一套)。

local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local TextInput = require("ArmorVariantManager_Core.Games.RE4.Panel.TextInput")
local Text = require("ArmorVariantManager_Core.Games.RE4.Panel.Text")

-- REFramework 只在加载脚本时解析 autorun 模块:页面要在这里先 require,绘制回调里懒加载会找不到
local PAGES = {
    { key = "quick",   label = "tabQuick",   mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PageQuick") },
    { key = "base",    label = "tabBase",    mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PageLayers"), mode = "base" },
    { key = "groups",  label = "tabGroups",  mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PageLayers"), mode = "groups" },
    { key = "states",  label = "tabStates",  mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PageStates") },
    { key = "palette", label = "tabPalette", mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PagePalette"), nf_page = true },
    { key = "presets", label = "tabPresets", mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PagePresets") },
    { key = "dissolve", label = "tabDissolve", mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PageDissolve"), nf_page = true },
    { key = "misc",    label = "tabMisc",    mod = require("ArmorVariantManager_Core.Games.RE4.Panel.PageMisc") },
}

local C, M = T.c, T.m
local max, min, floor = math.max, math.min, math.floor

local Panel = {}

local SNAPSHOT_EVERY = 6     -- 帧;快照要解算一遍配置,不必每帧取

-- deps:
--   controller            Reff.new 的控制器(snapshot / action / documentation)
--   global_config, save_global_settings
--   set_language(lang)    改界面语言并存盘
--   version
--   hotkeys               可选的快捷键主键(Ops.PANEL_KEYS)
--   entry_enabled()       可选,入口(按钮和快捷键)是否可用;不给时总是可用
function Panel.new(deps)
    local self = { open = false }
    I.install()   -- 位移 / 滚轮在 UpdateMotionFrame 之前采样(见 Input.lua)
    local ui = { page = "quick", toasts = {}, page_state = {}, win = nil, drag = nil }
    local snap, snap_age, snap_err = nil, SNAPSHOT_EVERY, nil
    local docs = nil
    local t = Text.translator("en")
    local sks_was = false
    local toast_seq = 0
    local ctx   -- 交给页面的上下文(下面定义;act 里要更新它的快照)

    local function toast(level, text)
        toast_seq = toast_seq + 1
        ui.toasts[#ui.toasts + 1] = { id = toast_seq, level = level, text = tostring(text), until_t = os.clock() + 6 }
        if #ui.toasts > 4 then table.remove(ui.toasts, 1) end
    end

    local function refresh()
        local ok, s = pcall(deps.controller.snapshot)
        if ok and type(s) == "table" then snap, snap_err = s, nil else snap_err = tostring(s) end
        snap_age = 0
    end

    -- 一次操作;失败(包括控制器拒绝)时提示,返回是否成功
    local function act(a)
        if type(a) ~= "table" then return false end
        if a.kind ~= "character" and a.kind ~= "setting" and a.character == nil and snap then a.character = snap.character end
        local ok, res = pcall(deps.controller.action, a)
        -- 调色拖动中的写入只回 { live = true }(不是快照),保留当前快照
        if ok and type(res) == "table" and res.live == true and res.game == nil then return true end
        if ok and type(res) == "table" then
            snap, snap_age = res, 0
            ctx.snap = res
            if res.notice then
                local n = res.notice
                if n.kind == "migrated" then
                    toast("info", t("migrated") .. ((n.presets or 0) > 0 and (" " .. t("migratedPresets", n.presets)) or ""))
                elseif n.kind == "mdf-replaced" then toast("info", t("paletteReplaced", n.path))
                elseif n.kind == "palette-exported" then
                    toast(n.exact == false and "warn" or "info", t("paletteExported", n.path)
                        .. (n.exact == false and (" " .. t("paletteExportedApprox", n.reason or "")) or ""))
                end
            end
            return true
        end
        -- 去掉 error() 加上的源码位置(可能套了几层),只留原因
        local msg, n = tostring(res), 1
        while n > 0 do msg, n = msg:gsub("^.-%.lua:%d+: ", "") end
        toast("error", t("actionFailed", msg))
        refresh()
        return false
    end

    local function documentation()
        if not docs then
            local ok, d = pcall(deps.controller.documentation)
            docs = ok and d or { sections = {} }
        end
        return docs
    end

    local function page_state(key)
        local s = ui.page_state[key]
        if not s then s = {}; ui.page_state[key] = s end
        return s
    end

    -- 单独的确认弹窗(危险操作):on_yes 在点「确定」时调用
    local function confirm(title, text, on_yes) ui.modal = { title = title, text = text, on_yes = on_yes } end
    ctx = { act = act, toast = toast, documentation = documentation, confirm = confirm, global_config = deps.global_config,
        hotkeys = deps.hotkeys or { "F8" }, save_global = function() pcall(deps.save_global_settings) end }

    local function page_of(key)
        for _, p in ipairs(PAGES) do if p.key == key then return p end end
        return PAGES[1]
    end

    local function leave_page(key)
        local p = page_of(key)
        if p.mod.leave then pcall(p.mod.leave, ctx, page_state(key), p.mode) end
    end

    local function goto_page(key)
        if key == ui.page then return end
        leave_page(ui.page)
        ui.page = key
        W.open_select = nil
        TextInput.clear()
    end
    ctx.goto_page = goto_page

    -- ---------------------------------------------------------------- 窗口几何
    local function window()
        if not ui.win then
            local w = type(deps.global_config.panel_window) == "table" and deps.global_config.panel_window or {}
            ui.win = { x = tonumber(w.x) or 120, y = tonumber(w.y) or 120, w = tonumber(w.w) or 960, h = tonumber(w.h) or 680 }
        end
        return ui.win
    end
    local function clamp_window(win)
        local sw, sh = D.surface_size()
        win.w = max(M.min_w, min(win.w, sw - 20))
        win.h = max(M.min_h, min(win.h, sh - 20))
        win.x = max(0, min(win.x, sw - 80))
        win.y = max(0, min(win.y, sh - 40))
    end
    local function save_window()
        local win = ui.win
        deps.global_config.panel_window = { x = floor(win.x), y = floor(win.y), w = floor(win.w), h = floor(win.h) }
        pcall(deps.save_global_settings)
    end

    -- ---------------------------------------------------------------- 外框
    local function draw_titlebar(x, y, w)
        local h = M.title_h
        D.rect(x, y, w, h, C.panel2)
        D.rect(x, y, w, 2, C.brass_dim)
        D.rect(x, y + h - 1, w, 1, C.line)
        local bw = D.text_mid(t("panelBrand"), x + 14, y, h, C.brass, D.font(T.font.title, true))
        local sw = D.text_mid(t("panelSub"), x + 22 + bw, y + 1, h, C.muted, W.small())
        local left = x + 22 + bw + sw + 16
        local rx = x + w - 12 - 26
        if W.close_button(rx, y + 7, 26) then self.set_open(false) end
        -- 语言按钮写的是另一种语言自己的名字:看不懂当前语言的人也认得出来
        local other = t("langOther")
        local lw = D.measure(W.small(), other) + 18
        rx = rx - 12 - lw
        if W.button(other, rx, y + 9, lw, 22, { kind = "ghost", font = W.small() }) then
            deps.set_language(snap and snap.language == "zh" and "en" or "zh")
            docs = nil
            refresh()
        end
        -- 角色:场上不止一个时可选
        if snap and #snap.characters > 0 then
            local labels, cur = {}, 1
            for i, c in ipairs(snap.characters) do
                labels[i] = c.label .. (c.configured and "" or (" · " .. t("noConfig")))
                if c.id == snap.character then cur = i end
            end
            local aw = min(280, rx - 16 - left)
            if aw >= 120 then
                if #labels > 1 then
                    local changed, i = W.select("character", left, y + 7, aw, 26, labels, cur)
                    if changed and snap.characters[i] then act({ kind = "character", id = snap.characters[i].id }) end
                else
                    D.text_mid(t("character") .. "：" .. labels[1], left, y, h, C.text, W.body(), aw)
                end
                local ch = snap.characters[cur]
                if ch and #ch.targets > 0 then
                    W.tooltip(t("onField") .. "：" .. table.concat(ch.targets, "、"), left, y + 7, aw, 26)
                end
            end
        end
        return rx - 10
    end

    local function preset_dot()
        local p = snap and snap.presets
        return p and p.current ~= "full" and #p.better > 0 and not p.dismissed
    end

    local function draw_rail(x, y, h)
        local w = M.rail_w
        D.rect(x, y, w, h, C.panel)
        D.rect(x + w - 1, y, 1, h, C.line)
        local cy = y + 10
        for _, p in ipairs(PAGES) do
            local cur = ui.page == p.key
            local ih = 32
            local hover = I.hit(x, cy, w - 1, ih)
            if cur or hover then D.rect(x, cy, w - 1, ih, C.panel2) end
            if cur then D.rect(x, cy, 2, ih, C.brass) end
            D.text_mid(t(p.label), x + 14, cy, ih, (cur or hover) and C.text or C.muted, W.body(), w - 30)
            if p.key == "presets" and preset_dot() then D.fill_circle(x + w - 16, cy + ih / 2, 3, C.warn) end
            if I.click(x, cy, w - 1, ih) then goto_page(p.key) end
            cy = cy + ih + 2
        end
    end

    local function draw_statusbar(x, y, w)
        local h = M.status_h
        D.rect(x, y, w, h, C.panel)
        D.rect(x, y, w, 1, C.line)
        local text = "v" .. tostring(deps.version or "") .. " · " .. t("statusStandalone")
        D.text_mid(text, x + 12, y, h, C.muted, W.small(), w - 24)
    end

    local function draw_notices(x, y, w)
        local now_c = os.clock()
        for i = #ui.toasts, 1, -1 do
            if ui.toasts[i].until_t < now_c then table.remove(ui.toasts, i) end
        end
        local cy = y
        for i, n in ipairs(ui.toasts) do
            local col = n.level == "error" and C.error or (n.level == "warn" and C.warn or C.signal)
            local f = W.small()
            local lines = D.wrap(f, n.text, w - 50)
            local hh = max(26, #lines * 18 + 8)
            D.rrect(x, cy, w, hh, 3, C.ink)
            D.outline(x, cy, w, hh, 3, 1, col)
            for k, l in ipairs(lines) do D.text(l, x + 10, cy + 5 + (k - 1) * 18, col, f) end
            if W.close_button(x + w - 25, cy + 3, 20) then table.remove(ui.toasts, i); break end
            cy = cy + hh + 4
        end
        return cy - y
    end

    -- 自己画光标:REF 菜单关着时游戏不显示系统光标(REF 菜单开着时 ImGui 自己会画)
    local function draw_cursor()
        local ok, menu = pcall(function() return reframework:is_drawing_ui() end)
        if ok and menu then return end
        local x, y = I.mx, I.my
        if x < 0 then return end
        D.quad(x, y, x, y + 17, x + 4.5, y + 13, x + 11, y + 12, C.ink)
        D.quad(x + 1.2, y + 2.5, x + 1.2, y + 14.5, x + 4.6, y + 11.6, x + 9, y + 11, C.text)
    end

    -- 页面上方的横幅(没有角色 / 旧版配置)。返回用掉的高度,和是否还要画页面
    local function draw_banner(x, y, w)
        if not snap then
            D.text_mid(snap_err or t("wait"), x, y, 28, C.muted, W.body(), w)
            return 36, false
        end
        if ui.page == "misc" or ui.page == "dissolve" then return 0, true end
        if snap.character == "" then
            W.panel_box(x, y, w, 40)
            D.text_mid(t("noCharacter"), x + 12, y, 40, C.muted, W.body(), w - 24)
            return 48, false
        end
        if snap.configVersion ~= 3 then
            W.panel_box(x, y, w, 40, C.warn)
            local tw = D.text_mid(t("needMigration"), x + 12, y, 40, C.text, W.body(), w - 140)
            if W.button(t("goMigrate"), x + 24 + tw, y + 7, nil, 26, { kind = "primary", font = W.small() }) then goto_page("misc") end
            return 48, false
        end
        return 0, true
    end

    -- ---------------------------------------------------------------- 开关 / 每帧
    function self.is_open() return self.open end
    function self.available() return D.available() end

    function self.set_open(on)
        on = on == true
        if on == self.open then return end
        if on and not D.available() then return end
        self.open = on
        I.reset()
        I.set_enabled(on)
        W.open_select = nil
        if on then
            docs = nil
            refresh()
        else
            leave_page(ui.page)
            TextInput.clear()
            if ui.win and ui.dirty_window then ui.dirty_window = false; save_window() end
        end
    end

    function self.toggle() self.set_open(not self.open) end

    function self.entry_enabled() return deps.entry_enabled == nil or deps.entry_enabled() == true end
    local function hotkey() return deps.global_config.panel_hotkey or "F8" end
    local function hotkey_mod()
        local m = deps.global_config.panel_hotkey_mod
        return (m == "Ctrl" or m == "Shift" or m == "Alt") and m or nil
    end
    function self.hotkey_text() return (hotkey_mod() and (hotkey_mod() .. "+") or "") .. hotkey() end

    -- re.on_frame:输入采样;SKS 打开了它的面板就让位(新打开的优先,和 SKS 那边的规则对称)
    function self.frame()
        local reg = rawget(_G, "__AVM_UI_INPUT_BLOCKER_STATES")
        local sks = type(reg) == "table" and reg.ShapeKeySystem == true
        if self.open and sks and not sks_was then
            self.set_open(false)
            toast("warn", t("sksOpened"))
        end
        sks_was = sks
        -- 快捷键:每帧都查(要认出"刚按下");正在输入框里打字时不响应
        local pressed = I.key_pressed(hotkey(), hotkey_mod())
        if pressed and self.entry_enabled() and TextInput.active == nil then self.toggle() end
        if self.open then I.capture() end
    end

    local function draw()
        TextInput.begin_layout()
        if not self.open then return end
        snap_age = snap_age + 1
        if not snap or snap_age >= SNAPSHOT_EVERY then refresh() end
        t = Text.translator(snap and snap.language or (deps.global_config.language == "zh" and "zh" or "en"))
        ctx.t, ctx.snap = t, snap
        if not D.reset_frame(1.0, 1.0) then return end
        I.begin_frame()
        local win = window()
        clamp_window(win)
        local x, y, w, h = win.x, win.y, win.w, win.h

        -- 拖动 / 缩放窗口(在控件之前处理,拖动时不点穿)
        if ui.drag then
            if I.down then
                local d = ui.drag
                if d.kind == "move" then win.x, win.y = I.mx - d.ox, I.my - d.oy
                else win.w, win.h = max(M.min_w, d.w0 + I.mx - d.mx0), max(M.min_h, d.h0 + I.my - d.my0) end
                clamp_window(win)
                x, y, w, h = win.x, win.y, win.w, win.h
            else
                ui.drag = nil
                I.active = nil
                save_window()
            end
        end

        D.rect(x + 4, y + 6, w, h, 0x55000000)
        D.rrect(x, y, w, h, M.radius, C.panel)
        D.outline(x, y, w, h, M.radius, 1, C.line)

        local drag_right = draw_titlebar(x, y, w)
        if not ui.drag and I.active == nil and I.clicked and I.hit(x, y, drag_right - x, M.title_h) then
            I.consume(); I.active = "window"
            ui.drag = { kind = "move", ox = I.mx - x, oy = I.my - y }
        end

        local body_y, body_h = y + M.title_h, h - M.title_h - M.status_h
        draw_rail(x, body_y, body_h)
        draw_statusbar(x, y + h - M.status_h, w)

        local cx, cw = x + M.rail_w + M.pad, w - M.rail_w - 2 * M.pad
        local cy = body_y + 10
        cy = cy + draw_notices(cx, cy, cw)
        local ch = body_y + body_h - cy - 6
        local p = page_of(ui.page)
        local scroll_id = "page:" .. ui.page
        local y0 = W.begin_scroll(scroll_id, cx - 4, cy, cw + 8, ch)
        local bh, go = draw_banner(cx, y0 + 4, cw)
        local used = bh
        if go then
            ctx.state, ctx.view_h, ctx.scroll_id, ctx.mode = page_state(ui.page), ch, scroll_id, p.mode
            -- 新版特性关闭时,调色页、溶解页整页灰掉、不可改:上面一条说明,页面照画,输入锁住,再盖一层半透明
            local locked = p.nf_page and ctx.snap and ctx.snap.settings and ctx.snap.settings.newFeatures == false
            if locked then
                bh = bh + W.note(ctx.t("newFeaturesOffPage"), cx, y0 + 4 + bh, cw, C.warn) + 8
            end
            I.locked = locked == true
            local ok, res = pcall(p.mod.draw, ctx, cx, y0 + 4 + bh, cw)
            I.locked = false
            if locked and ok then
                D.rect(cx - 4, y0 + 4 + bh, cw + 8, tonumber(res) or 0, (C.panel & 0x00FFFFFF) | 0xA0000000)
            end
            if ok then used = bh + (tonumber(res) or 0)
            else
                local e = tostring(res)
                D.text(e, cx, y0 + 4 + bh, C.error, W.small(), cw)
                used = bh + 40
                if ctx.state.last_err ~= e then
                    ctx.state.last_err = e
                    if log and log.warn then log.warn("[AVM] panel page " .. ui.page .. ": " .. e) end
                end
            end
        end
        W.end_scroll(used + 16)

        -- 右下角缩放把手
        local gx, gy = x + w - 16, y + h - 16
        D.line(gx + 4, gy + 14, gx + 14, gy + 4, 1, C.faint)
        D.line(gx + 9, gy + 14, gx + 14, gy + 9, 1, C.faint)
        if not ui.drag and I.active == nil and I.click(gx, gy, 16, 16) then
            I.active = "window"
            ui.drag = { kind = "size", w0 = w, h0 = h, mx0 = I.mx, my0 = I.my }
        end

        -- 这次点击没落在输入框上、又有输入框正在编辑:让它失焦(光标被钉住时 ImGui 自己判断不了)
        if I.frame_clicked and not W.text_clicked and TextInput.active then TextInput.request_blur() end
        W.text_clicked = false
        -- 确认弹窗:盖住整个窗口,挡住下面页面的点击(浮层登记在下一次绘制生效,所以每帧都登记)
        if ui.modal then
            local m = ui.modal
            I.add_overlay(x, y, w, h)
            D.defer(function()
                I.in_overlay = true
                D.rrect(x, y, w, h, M.radius, 0xB0000000)
                local f = W.body()
                local bw = math.min(440, w - 40)
                local lines = D.wrap(f, m.text, bw - 32)
                local bh = 64 + #lines * 20 + 44
                local bx, by = x + (w - bw) / 2, y + (h - bh) / 2
                D.rrect(bx, by, bw, bh, 6, C.panel2)
                D.outline(bx, by, bw, bh, 6, 1, C.error)
                D.text(m.title, bx + 16, by + 14, C.text, W.bold())
                for k, l in ipairs(lines) do D.text(l, bx + 16, by + 44 + (k - 1) * 20, C.text, f) end
                local yb = by + bh - 40
                local cw2 = W.button_w(t("confirm"), { font = W.small() })
                local nw = W.button_w(t("cancel"), { font = W.small() })
                if W.button(t("confirm"), bx + bw - 16 - cw2, yb, cw2, 26, { kind = "danger", font = W.small() }) then
                    ui.modal = nil
                    pcall(m.on_yes)
                elseif W.button(t("cancel"), bx + bw - 24 - cw2 - nw, yb, nw, 26, { font = W.small() }) then
                    ui.modal = nil
                end
                I.in_overlay = false
            end)
        end
        if W.open_select then TextInput.draw_static() end
        D.flush_deferred()
        if W.open_select or not self.open then TextInput.clear() end
        draw_cursor()
    end

    function self.draw()
        if not self.open then TextInput.begin_layout(); return end
        local ok, err = pcall(draw)
        if not ok then
            if log and log.warn then log.warn("[AVM] panel draw: " .. tostring(err)) end
        end
    end

    function self.draw_inputs()
        if not self.open then return end
        local ok, e = pcall(TextInput.draw)
        if not ok then TextInput.clear(); toast("error", tostring(e)) end
    end

    -- 测试用
    self._ui, self._ctx = ui, ctx
    function self._snapshot() return snap end

    return self
end

return Panel
