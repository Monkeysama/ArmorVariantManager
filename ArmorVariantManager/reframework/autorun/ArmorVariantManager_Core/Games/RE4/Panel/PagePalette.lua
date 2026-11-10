-- 调色页(对应 web/src/re4/Re4Palette.vue)。左边选材质(可多选,跨部位),右边按材质映射列出参数。
-- 多选时只列所有选中材质都有的项,改一次全部生效;「整体调色」对选中材质的颜色项转色相 / 调饱和度和明度。
-- 和网页的不同:没有取色器,颜色按 R / G / B 三个滑条调(线性值,可以超过 1);参数注释放在悬停提示里。
-- 拖动中实时写(live,只改内存),松手时再写一次存盘 —— 同 REFF 页。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local U = require("ArmorVariantManager_Core.Games.RE4.Panel.Common")
local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")
local R = require("ArmorVariantManager_Core.Games.RE4.Panel.Refs")

local C = T.c
local max, min, floor, abs = math.max, math.min, math.floor, math.abs
local Page = {}
local ROW = 26
local COMP = { "x", "y", "z", "w" }
local CI = { x = 1, y = 2, z = 3, w = 4 }

local function text(lang, v, fallback)
    if type(v) ~= "table" then return fallback or "" end
    if lang == "en" then return v.en or v.zh or fallback or "" end
    return v.zh or v.en or fallback or ""
end

local function contains(list, v) return U.contains(list, v) end

local function view(ctx, st, open)
    ctx.act({ kind = "palette-view", open = open, keys = open and st.sel or {}, solo = open and st.solo == true })
end

function Page.leave(ctx, st)
    if st.viewing then
        st.viewing = nil
        pcall(view, ctx, st, false)
    end
end

local function sig(e)
    return table.concat({ e.param, e.kind, e.component or "", e.kind == "color" and (e.channels or "rgb") or "" }, "|")
end
local function generic_entry(param) return { param = param, kind = "color", channels = "rgb", label = { zh = param, en = param } } end
local function profiles_of(m)
    local out = {}
    if m.main then out[#out + 1] = m.main end
    for _, a in ipairs(m.addons or {}) do out[#out + 1] = a end
    return out
end

local function entry_comps(e)
    if e.kind == "color" then return e.channels == "rgba" and "xyzw" or "xyz" end
    if e.kind == "vec" then return "xyzw" end
    return e.component or "x"
end

local function hsv(r, g, b)
    local mx, mn = max(r, g, b), min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    end
    h = h * 60
    if h < 0 then h = h + 360 end
    return h, mx > 0 and d / mx or 0, mx
end
local function from_hsv(h, s, v)
    local function f(n)
        local k = (n + h / 60) % 6
        return v - v * s * max(0, min(k, 4 - k, 1))
    end
    return f(5), f(3), f(1)
end
local function near(a, b) return a ~= nil and b ~= nil and abs(a - b) < 1e-4 end

function Page.draw(ctx, x, y, w)
    local snap, t, st = ctx.snap, ctx.t, ctx.state
    local lang = snap.language
    st.sel = st.sel or {}
    st.drafts = st.drafts or {}
    st.local_vals = st.local_vals or {}
    st.groups_open = st.groups_open or {}
    st.batch = st.batch or { hue = 0, sat = 100, val = 100 }
    if st.char ~= snap.character then st.char, st.sel = snap.character, {}; st.viewing = nil end
    if not st.viewing then
        st.viewing = true
        view(ctx, st, true)
        snap = ctx.snap
    end
    local pal = snap.palette
    local cy = y
    if not pal then
        D.text_mid(t("wait"), x, cy, 22, C.muted, W.small())
        return 30
    end
    if pal.error then
        cy = cy + W.note(pal.error, x, cy, w, C.error) + 6
    end
    if pal.errors and #pal.errors > 0 then
        cy = cy + W.note(t("paletteBadFiles", table.concat(pal.errors, "、")), x, cy, w, C.warn) + 6
    end
    if #st.sel == 0 and pal.selected and #pal.selected > 0 then
        for i, k in ipairs(pal.selected) do st.sel[i] = k end
    end
    local function select(keys)
        st.sel = keys
        st.local_vals = {}
        view(ctx, st, true)
    end

    local materials = pal.materials or {}
    local by_key = {}
    for _, m in ipairs(materials) do by_key[m.key] = m end
    local chosen = {}
    for _, k in ipairs(st.sel) do if by_key[k] then chosen[#chosen + 1] = by_key[k] end end

    -- ---------------------------------------------------- 调色方案(同网页):选择 / 新建 / 改名 / 删除,快捷键
    -- 选中就生效(存进配置),本页编辑选中的那一份;"" = 初始
    do
        local pl = snap.palettes or {}
        local list = type(pl.list) == "table" and pl.list or {}
        local scheme = type(pl.selected) == "string" and pl.selected or ""
        local active = {}
        for _, n in ipairs(type(pl.active) == "table" and pl.active or {}) do active[n] = true end
        local SF = W.flow(x, cy, w, 10, T.m.row_h)
        R.hotkey(ctx, SF, "pal|*", { kind = "palette" }, t("hotkeyCycleRef"))
        cy = cy + SF:height() + 4
        SF = W.flow(x, cy, w, 10, T.m.row_h)
        local labels, values, index = { t("paletteAlways") }, { "" }, 1
        for _, s in ipairs(list) do
            labels[#labels + 1] = s.name .. (active[s.name] and ("  · " .. t("paletteSchemeOn")) or "")
            values[#values + 1] = s.name
            if s.name == scheme then index = #labels end
        end
        local sx, sy = SF:place(220, T.m.row_h)
        local changed, picked = W.select("pal-scheme", sx, sy + 1, 220, 24, labels, index, { popup_w = 280 })
        if changed and picked ~= index and values[picked] ~= nil then
            st.local_vals = {}
            ctx.act({ kind = "palette-scheme-select", scheme = values[picked] })
            view(ctx, st, true)
        end
        if SF:button(t("paletteSchemeNew")) then
            st.scheme_edit = { mode = "new", name = "", copy = scheme ~= "" }; st.scheme_delete = nil
        end
        if scheme ~= "" then
            if SF:button(t("rename")) then st.scheme_edit = { mode = "rename", name = scheme }; st.scheme_delete = nil end
            if SF:button(t("delete"), { kind = "danger" }) then st.scheme_delete = scheme; st.scheme_edit = nil end
        end
        R.hotkey(ctx, SF, "pal|" .. scheme, { kind = "palette", scheme = scheme })
        cy = cy + SF:height() + 6
        -- 新建 / 改名:名字(64 字以内、不能重名),新建时可以复制当前方案
        local ed = st.scheme_edit
        if ed then
            local EF = W.flow(x + 16, cy, w - 16, 10, T.m.row_h)
            EF:text(ed.mode == "rename" and t("paletteSchemeRename") or t("paletteSchemeNew"), C.text, W.bold())
            local nx, ny = EF:place(200, T.m.row_h)
            W.text_box("pal-scheme-name", nx, ny + 1, 200, 24, ed.name, t("paletteSchemeName"), function(v) ed.name = v end)
            local name = (ed.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local taken = false
            for _, s in ipairs(list) do if s.name == name and not (ed.mode == "rename" and name == scheme) then taken = true end end
            if ed.mode == "new" and scheme ~= "" then
                local c2, v2 = EF:checkbox(t("paletteFromCurrent", scheme), ed.copy == true)
                if c2 then ed.copy = v2 end
            end
            if taken then EF:text(t("paletteSchemeTaken"), C.error) end
            local ok_name = name ~= "" and #name <= 64 and not taken
            if EF:button(t("confirm"), { kind = "primary", disabled = not ok_name }) then
                local done
                if ed.mode == "rename" then done = ctx.act({ kind = "palette-scheme-rename", scheme = scheme, name = name })
                else done = ctx.act({ kind = "palette-scheme-new", name = name, from = (ed.copy and scheme ~= "") and scheme or nil }) end
                if done then st.scheme_edit = nil; st.local_vals = {}; view(ctx, st, true) end
            end
            if EF:button(t("cancel")) then st.scheme_edit = nil end
            cy = cy + EF:height() + 6
        end
        if st.scheme_delete and st.scheme_delete == scheme then
            local used = 0
            for _, s in ipairs(list) do if s.name == scheme then used = tonumber(s.used) or 0 end end
            local r, h = W.confirm(x + 16, cy, w - 20, t("paletteSchemeDeleteBody", scheme, used), t("confirmDelete"), t("cancel"), "danger", C.error)
            if r then st.scheme_delete = nil end
            if r == "yes" then
                st.local_vals = {}
                ctx.act({ kind = "palette-scheme-delete", scheme = scheme })
                view(ctx, st, true)
            end
            cy = cy + h
        elseif st.scheme_delete then
            st.scheme_delete = nil
        end
    end

    -- 「仅显示选中部位」:开着时人物身上只留选中的材质(其余部位整个隐藏),跟着选择走,离开调色页自动关
    if st.solo == nil then st.solo = snap.solo == true end
    local sw = W.toggle_w(t("paletteSolo"))
    local ch_solo, v_solo = W.toggle(t("paletteSolo"), x + w - sw, cy, st.solo, { tip = t("paletteSoloHint") })
    if ch_solo then st.solo = v_solo; view(ctx, st, true) end
    cy = cy + T.m.row_h + 6

    -- ---------------------------------------------------- 左栏:材质
    local lw = min(260, floor(w * 0.32))
    local lx, top = x, cy
    local ly = cy
    D.text_mid(t("paletteMaterials"), lx, ly, 24, C.text, W.bold())
    local cw2 = W.tbutton_w(t("paletteClear"))
    if W.tbutton(t("paletteClear"), lx + lw - cw2, ly + 1, { disabled = #st.sel == 0 }) then select({}) end
    ly = ly + 30
    local last_slot
    for _, m in ipairs(materials) do
        if m.slot ~= last_slot then
            last_slot = m.slot
            D.text_mid(U.slot_label(snap, m.slot), lx, ly, 20, C.muted, W.small())
            -- 按部位整组:全选 / 反选 / 清空(保留其它部位的选择,新加的接在后面)
            local slot = m.slot
            local keys, picked = {}, 0
            for _, mm in ipairs(materials) do
                if mm.slot == slot then keys[#keys + 1] = mm.key; if contains(st.sel, mm.key) then picked = picked + 1 end end
            end
            local in_slot = {}
            for _, k in ipairs(keys) do in_slot[k] = true end
            local bx = lx + lw
            local function slot_btn(label, disabled)
                local bw = W.tbutton_w(label)
                bx = bx - bw
                local hit = W.tbutton(label, bx, ly - 1, { disabled = disabled })
                bx = bx - 6
                return hit
            end
            if slot_btn(t("paletteSlotClear"), picked == 0) then
                local out = {}
                for _, k in ipairs(st.sel) do if not in_slot[k] then out[#out + 1] = k end end
                select(out)
            elseif slot_btn(t("paletteSlotInvert"), false) then
                local out = {}
                for _, k in ipairs(st.sel) do if not in_slot[k] then out[#out + 1] = k end end
                for _, k in ipairs(keys) do if not contains(st.sel, k) then out[#out + 1] = k end end
                select(out)
            elseif slot_btn(t("paletteSlotAll"), picked == #keys) then
                local out = {}
                for _, k in ipairs(st.sel) do out[#out + 1] = k end
                for _, k in ipairs(keys) do if not contains(st.sel, k) then out[#out + 1] = k end end
                select(out)
            end
            ly = ly + 22
        end
        if W.visible(ly, 24) then
            local on = contains(st.sel, m.key)
            local c1 = W.checkbox("", lx + 4, ly, on, { h = 24 })
            if c1 then
                local keys = {}
                for _, k in ipairs(st.sel) do if k ~= m.key then keys[#keys + 1] = k end end
                if not on then keys[#keys + 1] = m.key end
                select(keys)
            end
            local label = m.material .. (m.note and ("  " .. m.note) or "")
            local tag_w = m.overridden > 0 and (W.tag_w(t("paletteChanged", m.overridden)) + 4) or 0
            local nw = lw - 26 - tag_w
            if on then D.rect(lx + 22, ly + 1, nw, 22, C.panel3) end
            D.text_mid(label, lx + 26, ly, 24, on and C.text or C.muted, W.small(), nw - 6)
            W.tooltip(t("paletteOnly"), lx + 22, ly, nw, 24)
            if I.click(lx + 22, ly, nw, 24) then select({ m.key }) end
            if tag_w > 0 then W.tag(t("paletteChanged", m.overridden), lx + lw - tag_w + 4, ly + 2, C.warn) end
        end
        ly = ly + 26
    end
    D.rect(lx + lw + 8, top, 1, max(ly - top, 80), C.line)

    -- ---------------------------------------------------- 右栏:参数
    local ex, ew = x + lw + 20, w - lw - 20
    local ey = top
    local title = #chosen > 0 and t("paletteSelected", #chosen) or t("paletteNothing")
    D.text_mid(title, ex, ey, 26, C.text, W.bold())
    local HF = W.flow(ex + D.measure(W.bold(), title) + 16, ey, ew - D.measure(W.bold(), title) - 16, 6, 26)
    -- 只选了一个材质时:导出 mdf2 材质预设(先填英文预设名)
    if #chosen == 1 then
        if HF:button(t("paletteExport")) then
            st.exporting = chosen[1].key
            st.preset_name = st.preset_name or (chosen[1].material:gsub("[^%w _%-]", "_"))
        end
        -- 替换 mdf:灰掉时只在悬停时说明原因;能用时先弹单独的确认框
        local state = chosen[1].replace
        local tip = state == "packed" and t("paletteReplacePacked") or (state == "plugin" and t("paletteReplacePlugin") or nil)
        if HF:button(t("paletteReplace"), { kind = "danger", disabled = state ~= "ok" or pal.replacing == true, tip = tip }) then
            local slot = chosen[1].slot
            ctx.confirm(t("paletteReplace"), t("paletteReplaceConfirm"), function() ctx.act({ kind = "palette-replace", slot = slot }) end)
        end
    end
    if HF:button(t("paletteReload")) then ctx.act({ kind = "palette-reload" }) end
    local any_override = false
    for _, m in ipairs(chosen) do if m.overridden > 0 then any_override = true end end
    if any_override and HF:button(t("paletteResetAll"), { kind = "danger" }) then
        local targets = {}
        for _, m in ipairs(chosen) do targets[#targets + 1] = { slot = m.slot, material = m.material } end
        ctx.act({ kind = "palette-reset", targets = targets })
    end
    ey = ey + max(30, HF:height() + 4)
    if st.exporting and (#chosen ~= 1 or chosen[1].key ~= st.exporting) then st.exporting = nil end
    if st.exporting then
        local name = st.preset_name or ""
        local ok = name:match("^[%w_%-][%w _%-]*$") ~= nil and #name <= 64 and not name:match("%s$")
        local EF = W.flow(ex, ey, ew, 8, 28)
        local nx, ny = EF:place(220, 28)
        W.text_box("palette_preset_name", nx, ny + 1, 220, 26, name, t("palettePresetName"), function(v) st.preset_name = v end)
        if EF:button(t("paletteExportConfirm"), { kind = "primary", disabled = not ok }) then
            if ctx.act({ kind = "palette-export", slot = chosen[1].slot, material = chosen[1].material, name = name }) then st.exporting = nil end
        end
        if EF:button(t("cancel")) then st.exporting = nil end
        EF:text(t("palettePresetNameHint"), (ok or name == "") and C.muted or C.error)
        ey = ey + EF:height() + 6
    end
    if #chosen == 0 then
        ey = ey + W.note(t("paletteHint"), ex, ey, ew) + 4
        return max(ly, ey) - y + 8
    end
    if #chosen > 1 then ey = ey + W.note(t("paletteCommon"), ex, ey, ew) + 4 end
    -- 颜色滑条用 RGB 还是 HSV:个人偏好,记在全局设置里
    local g = ctx.global_config or {}
    local hsv_mode = g.palette_sliders == "hsv"
    local mw = D.text_mid(t("paletteSliderMode"), ex, ey, 26, C.muted, W.small()) + 8
    local picked = W.segments(ex + mw, ey, 140, { { "RGB", "rgb" }, { "HSV", "hsv" } }, hsv_mode and "hsv" or "rgb")
    if picked and picked ~= (hsv_mode and "hsv" or "rgb") then
        g.palette_sliders = picked
        hsv_mode = picked == "hsv"
        st.local_vals = {}
        if ctx.save_global then ctx.save_global() end
    end
    ey = ey + 32
    ey = ey + W.note(t(hsv_mode and "paletteHsvHint" or "paletteRgbHint"), ex, ey, ew, C.faint) + 6

    -- 每个材质能用的项(签名集合)
    local sigs = {}
    for _, m in ipairs(materials) do
        local set = {}
        local missing = {}
        for _, p in ipairs(m.missing or {}) do missing[p] = true end
        for _, id in ipairs(profiles_of(m)) do
            for _, g in ipairs(((pal.profiles or {})[id] or {}).groups or {}) do
                for _, e in ipairs(g.params) do if not missing[e.param] then set[sig(e)] = true end end
            end
        end
        for _, p in ipairs(m.generic or {}) do set[sig(generic_entry(p))] = true end
        sigs[m.key] = set
    end
    local function usable_all(e)
        local s = sig(e)
        for _, m in ipairs(chosen) do if not (sigs[m.key] or {})[s] then return false end end
        return true
    end

    local first = chosen[1]
    local groups = {}
    local function add(profile_id, g, enums)
        local basic, extra = {}, {}
        for _, e in ipairs(g.params) do
            if usable_all(e) then
                local row = { entry = e, tier = e.tier or g.tier, options = e.options or (e.enum and enums[e.enum]) or nil }
                table.insert((g.tier == "basic" and row.tier == "more") and extra or basic, row)
            end
        end
        if #basic + #extra > 0 then
            local rows = {}
            for _, r in ipairs(basic) do rows[#rows + 1] = r end
            for _, r in ipairs(extra) do rows[#rows + 1] = r end
            groups[#groups + 1] = { key = (profile_id or "generic") .. ":" .. g.id, section = g.section or "other",
                label = text(lang, g.label, g.id), note = text(lang, g.note), tier = g.tier, rows = rows,
                extra_from = #extra > 0 and (#basic + 1) or nil }
        end
    end
    for _, id in ipairs(profiles_of(first)) do
        local p = (pal.profiles or {})[id]
        for _, g in ipairs(p and p.groups or {}) do add(id, g, p.enums or {}) end
    end
    if not first.main and first.generic and #first.generic > 0 then
        local params = {}
        for _, p in ipairs(first.generic) do params[#params + 1] = generic_entry(p) end
        add(nil, { id = "colors", tier = "basic", section = "color", label = { zh = "颜色", en = "Colours" }, params = params }, {})
    end

    -- 取值
    local values = pal.values or {}
    local function value_of(key, param) return (values[key] or {})[param] end
    local function num(key, e)
        local v = value_of(key, e.param)
        if type(v) == "number" then return v end
        if type(v) == "table" and e.component then return v[CI[e.component]] end
        return nil
    end
    local function override_of(key, param)
        local o = (pal.overrides or {})[key]
        return type(o) == "table" and o[param] or nil
    end
    local function modified(e)
        for _, m in ipairs(chosen) do
            local o = override_of(m.key, e.param)
            if o ~= nil then
                if type(o) == "number" then return true end
                local comps = e.kind == "color" and (e.channels == "rgba" and COMP or { "x", "y", "z" })
                    or (e.kind == "vec" and COMP or (e.component and { e.component } or {}))
                for _, c in ipairs(comps) do if o[c] ~= nil then return true end end
            end
        end
        return false
    end
    local function mixed(e)
        local k1 = chosen[1].key
        for _, m in ipairs(chosen) do
            if e.kind == "color" or e.kind == "vec" then
                local a, b = value_of(k1, e.param), value_of(m.key, e.param)
                if type(a) ~= "table" or type(b) ~= "table" then return true end
                for i = 1, 4 do if not near(a[i], b[i]) then return true end end
            elseif not near(num(m.key, e), num(k1, e)) then return true end
        end
        return false
    end
    local function dead_on(m, e)
        local dd = m.ineffective and m.ineffective[e.param]
        if not dd then return false end
        for ch in entry_comps(e):gmatch(".") do if not dd.comps:find(ch, 1, true) then return false end end
        return true
    end
    local function dead(e)
        for _, m in ipairs(chosen) do if not dead_on(m, e) then return false end end
        return true
    end
    local function dead_why(e)
        local dd = first.ineffective and first.ineffective[e.param]
        if not dd then return "" end
        local parts = {}
        for _, wy in ipairs(dd.why) do parts[#parts + 1] = wy.texture .. " = " .. (wy.null:match("[^/]+$") or wy.null) end
        return t("paletteDeadWhy", table.concat(parts, "；"))
    end

    -- 写入
    local function targets()
        local out = {}
        for _, m in ipairs(chosen) do out[#out + 1] = { slot = m.slot, material = m.material } end
        return out
    end
    local function write(list, live)
        local writes = {}
        for _, tg in ipairs(targets()) do
            for _, wr in ipairs(list) do
                writes[#writes + 1] = { slot = tg.slot, material = tg.material, param = wr.param, component = wr.component, value = wr.value }
            end
        end
        if #writes > 0 then ctx.act({ kind = "palette-set", writes = writes, live = live or nil }) end
    end
    local function reset(e)
        local comps = e.kind == "color" and (e.channels == "rgba" and COMP or { "x", "y", "z" }) or (e.kind == "vec" and { false } or { e.component or false })
        for _, c in ipairs(comps) do
            ctx.act({ kind = "palette-reset", targets = targets(), param = e.param, component = c or nil })
        end
    end

    -- 整体调色(作用于「基本」里的颜色项)
    local color_rows = {}
    for _, g in ipairs(groups) do
        if g.tier == "basic" then
            for _, r in ipairs(g.rows) do if r.tier == "basic" and r.entry.kind == "color" then color_rows[#color_rows + 1] = r end end
        end
    end
    if #color_rows > 0 then
        W.panel_box(ex, ey, ew, 104)
        D.text_mid(t("paletteBatch"), ex + 10, ey + 4, 22, C.text, W.bold())
        local b = st.batch
        local sw = ew - 140
        local function bslider(label, field, lo, hi, yy)
            D.text_mid(label, ex + 10, yy, 22, C.muted, W.small(), 110)
            local _, nv = W.slider("batch:" .. field, ex + 124, yy, sw - 10, 22, b[field], lo, hi, { step = 1, fmt = "%.0f" })
            b[field] = nv
        end
        bslider(t("paletteHue"), "hue", -180, 180, ey + 28)
        bslider(t("paletteSat"), "sat", 0, 200, ey + 52)
        bslider(t("paletteVal"), "val", 0, 200, ey + 76)
        local aw = W.tbutton_w(t("paletteApply"))
        local unchanged = b.hue == 0 and b.sat == 100 and b.val == 100
        if W.tbutton(t("paletteApply"), ex + ew - aw - 10, ey + 4, { kind = "primary", disabled = unchanged }) then
            local writes = {}
            for _, m in ipairs(chosen) do
                for _, r in ipairs(color_rows) do
                    local cur = value_of(m.key, r.entry.param)
                    if type(cur) == "table" then
                        local h, s, v = hsv(cur[1], cur[2], cur[3])
                        local o1, o2, o3 = from_hsv((h + b.hue + 360) % 360, max(0, min(1, s * b.sat / 100)), v * b.val / 100)
                        if not (near(o1, cur[1]) and near(o2, cur[2]) and near(o3, cur[3])) then
                            for i, comp in ipairs({ "x", "y", "z" }) do
                                writes[#writes + 1] = { slot = m.slot, material = m.material, param = r.entry.param,
                                    component = comp, value = ({ o1, o2, o3 })[i] }
                            end
                        end
                    end
                end
            end
            if #writes > 0 and ctx.act({ kind = "palette-set", writes = writes }) then st.batch = { hue = 0, sat = 100, val = 100 } end
        end
        ey = ey + 112
    end

    -- 版面:基本 / 进阶 / 其他,每块里按类别排组
    local function section_label(id)
        for _, p in pairs(pal.profiles or {}) do
            for _, s in ipairs(p.sections or {}) do if s.id == id then return text(lang, s.label, id) end end
        end
        return id == "color" and t("paletteSectionColor") or t("paletteSectionOther")
    end
    local fk = first.key
    local label_w = min(200, floor(ew * 0.34))
    local function draw_row(r)
        local e = r.entry
        local is_dead = dead(e)
        local lk = e.param .. "|" .. (e.component or "")
        local mod = modified(e)
        local lx2 = ex + 12
        if mod then D.fill_circle(lx2 - 6, ey + ROW / 2, 2.5, C.warn) end
        local label = text(lang, e.label, e.param)
        local nw = D.text_mid(label, lx2, ey, ROW, is_dead and C.faint or C.text, W.small(), label_w - 10)
        local tip = text(lang, e.note)
        if is_dead then tip = (tip ~= "" and (tip .. "\n") or "") .. dead_why(e) end
        if tip ~= "" then W.tooltip(tip, lx2, ey, nw, ROW) end
        local cx = ex + label_w
        local cw = ew - label_w - 12
        local rh = ROW
        -- 右端:多个值 / 恢复
        local tail = 0
        if mod then tail = W.tbutton_w(t("paletteRestore")) + 4 end
        if #chosen > 1 and mixed(e) then tail = tail + D.measure(W.small(), t("paletteMixed")) + 10 end
        if is_dead then tail = tail + W.tag_w(t("paletteDeadTag")) + 6 end
        local ctl_w = cw - tail
        if e.kind == "color" then
            local cur = value_of(fk, e.param)
            cur = type(cur) == "table" and cur or { 0, 0, 0, 1 }
            -- 拖动中用本地值(RGB 模式存 r, g, b;HSV 模式存 h, s, v —— 饱和度或明度拖到 0 时色相不能丢)
            local loc = st.local_vals[lk]
            local sliders, rgb_of
            if hsv_mode then
                local h, s, v = hsv(cur[1], cur[2], cur[3])
                sliders = loc or { h, s, v }
                rgb_of = function(vals) return { from_hsv(vals[1], vals[2], vals[3]) } end
            else
                sliders = loc or { cur[1], cur[2], cur[3] }
                rgb_of = function(vals) return { vals[1], vals[2], vals[3] } end
            end
            local shown = rgb_of(sliders)
            local function c255(v) return floor(max(0, min(1, v or 0)) * 255 + 0.5) end
            D.rrect(cx, ey + 3, 20, 20, 3, 0xFF000000 | (c255(shown[1]) << 16) | (c255(shown[2]) << 8) | c255(shown[3]))
            D.outline(cx, ey + 3, 20, 20, 3, 1, C.line)
            local sw = ctl_w - 28
            local any_released, live_change = false, false
            local names = hsv_mode and { "H", "S", "V" } or { "R", "G", "B" }
            local colors = hsv_mode and { C.signal, C.brass_dim, C.muted } or { 0xFFB04848, 0xFF48A048, 0xFF4870C0 }
            for i = 1, 3 do
                local sy = ey + (i - 1) * 22
                D.text_mid(names[i], cx + 28, sy, 22, C.muted, W.small())
                -- 线性颜色可以超过 1:RGB 各分量和 HSV 的明度,上限取 1 和当前值里大的那个
                local hi, fmt, step = max(1, sliders[i] or 0), "%.3f", nil
                if hsv_mode and i == 1 then hi, fmt, step = 360, "%.0f°", 1
                elseif hsv_mode and i == 2 then hi = 1 end
                local changed, nv, released = W.slider("pc:" .. lk .. i, cx + 42, sy, sw - 14, 22, sliders[i], 0, hi,
                    { fmt = fmt, step = step, color = colors[i] })
                if changed then
                    st.local_vals[lk] = st.local_vals[lk] or { sliders[1], sliders[2], sliders[3] }
                    st.local_vals[lk][i] = nv
                    live_change = true
                end
                if released then any_released = true end
            end
            local lv = st.local_vals[lk]
            if lv and (live_change or any_released) then
                local out = rgb_of(lv)
                write({ { param = e.param, component = "x", value = out[1] }, { param = e.param, component = "y", value = out[2] },
                    { param = e.param, component = "z", value = out[3] } }, not any_released)
                if any_released then st.local_vals[lk] = nil end
            end
            rh = 66
        elseif e.kind == "float" then
            local cur = num(fk, e)
            local lo, hi = e.min or 0, e.max or 1
            local step = e.step or ((hi - lo > 20) and 0.1 or 0.01)
            local shown = st.local_vals[lk] or max(lo, min(hi, cur or lo))
            local changed, nv, released = W.slider("pf:" .. lk, cx, ey, ctl_w - 80, ROW, shown, lo, hi, { step = step })
            if changed then st.local_vals[lk] = nv end
            if changed or released then
                local v = st.local_vals[lk] or nv
                write({ { param = e.param, component = e.component, value = v } }, not released)
                if released then st.local_vals[lk] = nil end
            end
            W.num_box(st.drafts, "pn:" .. lk, cx + ctl_w - 72, ey + 1, 68, cur, { min = e.hard_min, max = e.hard_max }, function(n)
                write({ { param = e.param, component = e.component, value = n } })
            end)
        elseif e.kind == "enum" then
            local ol, ov = {}, {}
            for _, o in ipairs(r.options or {}) do ol[#ol + 1] = text(lang, o.label, tostring(o.value)); ov[#ov + 1] = o.value end
            local cur = num(fk, e)
            local idx = 1
            for i, v in ipairs(ov) do if near(v, cur) then idx = i end end
            local changed, i = W.select("pe:" .. lk, cx, ey + 1, min(220, ctl_w), 24, ol, idx)
            if changed and ov[i] ~= nil then write({ { param = e.param, component = e.component, value = ov[i] } }) end
        elseif e.kind == "bool" then
            local changed, v = W.toggle("", cx, ey, (num(fk, e) or 0) >= 0.5)
            if changed then write({ { param = e.param, component = e.component, value = v and 1 or 0 } }) end
        else
            local names = (lang == "en" and e.labels and e.labels.en) or (e.labels and e.labels.zh) or { "X", "Y", "Z", "W" }
            local cur = value_of(fk, e.param)
            local bx = cx
            for i = 1, 4 do
                local nm = names[i] or COMP[i]:upper()
                bx = bx + D.text_mid(nm, bx, ey, ROW, C.muted, W.small()) + 4
                W.num_box(st.drafts, "pv:" .. lk .. i, bx, ey + 1, 58, type(cur) == "table" and cur[i] or nil, {}, function(n)
                    write({ { param = e.param, component = COMP[i], value = n } })
                end)
                bx = bx + 66
            end
        end
        local tx = cx + ctl_w + 4
        if is_dead then tx = tx + W.tag(t("paletteDeadTag"), tx, ey + 3, C.faint) + 6 end
        if #chosen > 1 and mixed(e) then tx = tx + D.text_mid(t("paletteMixed"), tx, ey, ROW, C.muted, W.small()) + 10 end
        if mod and W.tbutton(t("paletteRestore"), tx, ey + 2) then reset(e) end
        ey = ey + rh + 4
    end

    for _, tier in ipairs({ "basic", "more", "other" }) do
        local sections, order = {}, {}
        for _, g in ipairs(groups) do
            if g.tier == tier then
                if not sections[g.section] then sections[g.section] = {}; order[#order + 1] = g.section end
                table.insert(sections[g.section], g)
            end
        end
        if #order > 0 then
            local head = tier == "basic" and t("paletteBasic") or (tier == "more" and t("paletteAdvanced") or t("paletteOther"))
            local hw = D.text_mid(head, ex, ey, 26, C.brass, D.font(T.font.big, true))
            if tier == "other" then D.text_mid(t("paletteOtherHint"), ex + hw + 10, ey, 26, C.faint, W.small(), ew - hw - 10) end
            ey = ey + 30
            for _, sid in ipairs(order) do
                D.text_mid(section_label(sid), ex + 4, ey, 22, C.muted, W.small())
                ey = ey + 24
                for _, g in ipairs(sections[sid]) do
                    local is_open = st.groups_open[g.key]
                    local n_dead, n_mod = 0, false
                    for _, r in ipairs(g.rows) do
                        if dead(r.entry) then n_dead = n_dead + 1 end
                        if modified(r.entry) then n_mod = true end
                    end
                    local stat = tostring(#g.rows)
                    local stat_col
                    if n_dead == #g.rows then stat = stat .. "  " .. t("paletteDeadGroup"); stat_col = C.faint
                    elseif n_dead > 0 then stat = stat .. "  " .. t("paletteDeadSome", n_dead) end
                    local clicked, hh = W.header(g.label, ex + 6, ey, ew - 6, is_open, stat, stat_col)
                    if n_mod then D.fill_circle(ex + 2, ey + hh / 2, 2.5, C.warn) end
                    if g.note ~= "" then W.tooltip(g.note, ex + 6, ey, ew - 6, hh) end
                    if clicked then st.groups_open[g.key] = not is_open or nil end
                    ey = ey + hh + 2
                    if is_open then
                        for ri, r in ipairs(g.rows) do
                            if ri == g.extra_from then
                                D.text_mid(t("paletteAdvanced"), ex + 12, ey, 20, C.faint, W.small())
                                ey = ey + 22
                            end
                            draw_row(r)
                        end
                        ey = ey + 4
                    end
                end
            end
            ey = ey + 6
        end
    end
    if #groups == 0 then
        ey = ey + W.note(t("paletteNoEntries"), ex, ey, ew) + 4
    end
    return max(ly, ey) - y + 8
end

return Page
