-- 条件状态页(对应 web/src/re4/Re4States.vue)。从上往下是优先级(用 ▲▼ 调整)。
-- 收起时一行;展开后左右两栏:左边触发条件,右边切换到(整套造型单独一行,下面是状态组)。
-- 窗口窄时两栏上下排。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local U = require("ArmorVariantManager_Core.Games.RE4.Panel.Common")
local R = require("ArmorVariantManager_Core.Games.RE4.Panel.Refs")

local C = T.c
local max, min = math.max, math.min
local Page = {}
local ROW = 26

local CATS = { "hp", "combat", "move", "damage", "other" }
local CAT_KEY = { hp = "catHp", combat = "catCombat", move = "catMove", damage = "catDamage", other = "catOther" }
local LEGEND = { "active", "partial", "outranked", "idle", "off" }
local RES_COLOR = { ok = C.ok, bad = C.error, broken = C.warn }

local function def_of(snap, id)
    for _, d in ipairs(snap.conditions or {}) do if d.id == id then return d end end
end

local function default_condition(def)
    if not def then return { type = "is_battle", value = true } end
    if def.kind == "number" then return { type = def.id, op = "<=", value = 50 } end
    if def.kind == "enum" then return { type = def.id, op = "==", value = (def.options and def.options[1] and def.options[1].value) or 0 } end
    return { type = def.id, value = true }
end

-- 条件类型下拉:按类别分组(组名是不可选的标题)
local function type_choices(snap, t, cond)
    local labels, values, headers = {}, {}, {}
    if not cond.known then
        labels[#labels + 1] = t("unknownCondition") .. " " .. tostring(cond.type)
        values[#labels] = cond.type
    end
    for _, cat in ipairs(CATS) do
        local first = true
        for _, d in ipairs(snap.conditions or {}) do
            -- 被合成条件取代的旧布尔不列,除非这一条正用着它
            if d.category == cat and (not d.legacy or d.id == cond.type) then
                if first then
                    labels[#labels + 1] = t(CAT_KEY[cat])
                    headers[#labels] = true
                    first = false
                end
                labels[#labels + 1] = d.label
                values[#labels] = d.id
            end
        end
    end
    local cur = 1
    for i, v in pairs(values) do if v == cond.type then cur = i end end
    return labels, values, headers, cur
end

local function select_values(id, x, y, w, labels, values, current, opt, on_pick)
    local cur = 1
    for i, v in ipairs(values) do if v == current then cur = i end end
    local changed, i = W.select(id, x, y, w, 24, labels, cur, opt)
    if changed and values[i] ~= nil then on_pick(values[i]) end
end

-- 左栏:触发条件。返回高度
local function draw_trigger(ctx, k, st, x, y, w)
    local snap, t, ps = ctx.snap, ctx.t, ctx.state
    local cy = y
    D.text_mid(t("trigger"), x, cy, 22, C.brass, W.bold())
    cy = cy + 26
    local changed, v = W.checkbox(t("hpDrive"), x, cy, st.hp ~= nil, { tip = t("hpHint"), font = W.small() })
    if changed then
        ctx.act({ kind = "state-hp", index = k, hp = v and { upper = 100, lower = 0, invert = false } or nil })
    end
    cy = cy + ROW + 4
    if st.hp then
        local F = W.flow(x, cy, w, 8, ROW)
        local function hp_field(label, field, lo, hi)
            F:text(label)
            local fx, fy = F:place(60, ROW)
            W.num_box(ps.drafts, "hp" .. field .. ":" .. k, fx, fy + 1, 60, st.hp[field], { min = lo, max = hi }, function(n)
                local hp = { upper = st.hp.upper, lower = st.hp.lower, invert = st.hp.invert }
                hp[field] = n
                ctx.act({ kind = "state-hp", index = k, hp = hp })
            end)
        end
        hp_field(t("hpUpper"), "upper", 0, 100)
        hp_field(t("hpLower"), "lower", 0, 100)
        local c2, inv = F:checkbox(t("hpInvert"), st.hp.invert == true, { font = W.small() })
        if c2 then ctx.act({ kind = "state-hp", index = k, hp = { upper = st.hp.upper, lower = st.hp.lower, invert = inv } }) end
        cy = cy + F:height() + 4
        return cy - y
    end
    if #st.conditions == 0 then
        D.text_mid(t("noConditions"), x, cy, 22, C.muted, W.small(), w)
        cy = cy + 26
    end
    for ci, cond in ipairs(st.conditions) do
        local def = def_of(snap, cond.type)
        local cx = x
        if cond.met then D.rect(x - 4, cy, 2, ROW, C.ok) end
        if ci == 1 then
            D.text_mid(t("when"), cx, cy, ROW, C.muted, W.small())
        else
            select_values("logic:" .. k, cx, cy + 1, 56, { t("andShort"), t("orShort") }, { "AND", "OR" }, st.logic, nil, function(val)
                ctx.act({ kind = "state-field", index = k, field = "logic", value = val })
            end)
        end
        cx = cx + 62
        local labels, values, headers, cur = type_choices(snap, t, cond)
        local tw = min(170, w - 62 - 150)
        local changed_t, i = W.select("ctype:" .. k .. ":" .. ci, cx, cy + 1, tw, 24, labels, cur,
            { headers = headers, popup_w = 220, color = cond.known and C.text or C.warn })
        if changed_t and values[i] and values[i] ~= cond.type then
            ctx.act({ kind = "condition-set", index = k, condition_index = ci, condition = default_condition(def_of(snap, values[i])) })
        end
        cx = cx + tw + 6
        local function set(patch)
            local c = { type = cond.type, op = cond.op, value = cond.value }
            for kk, vv in pairs(patch) do c[kk] = vv end
            ctx.act({ kind = "condition-set", index = k, condition_index = ci, condition = c })
        end
        if def and def.kind == "number" then
            select_values("cop:" .. k .. ":" .. ci, cx, cy + 1, 48, def.ops or {}, def.ops or {}, cond.op, nil, function(op) set({ op = op }) end)
            cx = cx + 54
            W.num_box(ps.drafts, "cval:" .. k .. ":" .. ci, cx, cy + 1, 56, tonumber(cond.value), {}, function(n) set({ value = n }) end)
            cx = cx + 62
        elseif def and def.kind == "enum" then
            select_values("cop:" .. k .. ":" .. ci, cx, cy + 1, 44, { "=", "≠" }, { "==", "~=" }, cond.op, nil, function(op) set({ op = op }) end)
            cx = cx + 50
            local ol, ov = {}, {}
            for _, o in ipairs(def.options or {}) do ol[#ol + 1] = o.label; ov[#ov + 1] = o.value end
            select_values("cenum:" .. k .. ":" .. ci, cx, cy + 1, 110, ol, ov, cond.value, { popup_w = 160 }, function(val) set({ value = val }) end)
            cx = cx + 116
        else
            select_values("cbool:" .. k .. ":" .. ci, cx, cy + 1, 56, { t("yes"), t("no") }, { true, false }, cond.value ~= false, nil,
                function(val) set({ value = val }) end)
            cx = cx + 62
        end
        local now = U.current_value_text(def, t)
        local xb = x + w - 22
        if now ~= "" then D.text_mid(t("now", now), cx, cy, ROW, cond.met and C.ok or C.faint, W.small(), max(0, xb - cx - 4)) end
        if W.x_button(xb, cy + 2, 22) then ctx.act({ kind = "condition-delete", index = k, condition_index = ci }) end
        cy = cy + ROW + 4
    end
    if W.tbutton(t("addCondition"), x, cy + 2, { kind = nil }) then
        ctx.act({ kind = "condition-add", index = k, condition = default_condition(def_of(snap, "is_battle")) })
    end
    cy = cy + 30
    local F = W.flow(x, cy, w, 6, ROW)
    F:text(t("holdLabel"))
    local fx, fy = F:place(60, ROW)
    W.num_box(ps.drafts, "hold:" .. k, fx, fy + 1, 60, st.hold, { min = 0, max = 3600 }, function(n)
        ctx.act({ kind = "state-field", index = k, field = "hold", value = n })
    end)
    F:text(t("seconds"))
    cy = cy + F:height() + 4
    return cy - y
end

-- 右栏:切换到。返回高度
local function draw_targets(ctx, k, st, x, y, w)
    local snap, t = ctx.snap, ctx.t
    local states = snap.states
    local cy = y
    D.text_mid(t("switchTo"), x, cy, 22, C.brass, W.bold())
    cy = cy + 26
    local sel_w = min(150, (w - 120) / 2)
    -- 整套造型
    D.text_mid(t("baseTarget"), x, cy, ROW, C.muted, W.small(), sel_w)
    local bl, bv = { t("noSwitch") }, { "" }
    local names = {}
    for _, p in ipairs(snap.base.presets) do names[p.name] = true end
    if st.base and not names[st.base] then bl[#bl + 1] = st.base .. " · " .. t("moved"); bv[#bv + 1] = st.base end
    for _, p in ipairs(snap.base.presets) do bl[#bl + 1] = p.name; bv[#bv + 1] = p.name end
    local bx = x + sel_w + 6
    select_values("sbase:" .. k, bx, cy + 1, sel_w, bl, bv, st.base or "", nil, function(val)
        ctx.act({ kind = "state-base", index = k, preset = val ~= "" and val or nil })
    end)
    local rt, rc = U.result_text(st.baseResult, states, t)
    if rt ~= "" then D.text_mid(rt, bx + sel_w + 8, cy, ROW, RES_COLOR[rc] or C.muted, W.small(), max(0, x + w - bx - sel_w - 8)) end
    cy = cy + ROW + 6
    -- 调色方案、溶解预设、武器显示属于新版特性:关闭时灰掉、不可改
    local nf_off = R.nf_off(snap)
    local function ref_row(id, label, names, current, none_label, broken_label, on_pick, result)
        D.text_mid(label, x, cy, ROW, nf_off and C.faint or C.muted, W.small(), sel_w)
        local l, v = { none_label }, { "" }
        local found = false
        for _, n in ipairs(names) do l[#l + 1] = n; v[#v + 1] = n; if n == current then found = true end end
        if current and current ~= "" and not found then l[#l + 1] = broken_label .. "：" .. current; v[#v + 1] = current end
        select_values(id, bx, cy + 1, sel_w, l, v, current or "", { disabled = nf_off }, on_pick)
        if current and result then
            local rt2, rc2 = U.result_text(result, states, t)
            if rt2 ~= "" then D.text_mid(rt2, bx + sel_w + 8, cy, ROW, RES_COLOR[rc2] or C.muted, W.small(), max(0, x + w - bx - sel_w - 8)) end
        end
        cy = cy + ROW + 6
    end
    ref_row("spal:" .. k, t("paletteRef"), R.scheme_names(snap), st.palette, t("paletteRefNone"), t("paletteRefBroken"),
        function(val) ctx.act({ kind = "state-palette", index = k, scheme = val }) end, st.paletteResult)
    ref_row("sdis:" .. k, t("dissolveRef"), R.dissolve_names(snap), st.dissolve, t("dissolveRefNone"), t("dissolveRefBroken"),
        function(val) ctx.act({ kind = "state-dissolve", index = k, preset = val }) end)
    -- 武器显示
    D.text_mid(t("weaponsTarget"), x, cy, ROW, nf_off and C.faint or C.muted, W.small(), sel_w)
    select_values("sweap:" .. k, bx, cy + 1, sel_w, { t("weaponsKeep"), t("weaponsStowed"), t("weaponsAll") },
        { "", "stowed", "all" }, st.weapons or "", { disabled = nf_off }, function(val)
            ctx.act({ kind = "state-weapons", index = k, mode = val })
        end)
    if st.weapons then
        local wt, wc = U.result_text(st.weaponsResult, states, t)
        if wt ~= "" then D.text_mid(wt, bx + sel_w + 8, cy, ROW, RES_COLOR[wc] or C.muted, W.small(), max(0, x + w - bx - sel_w - 8)) end
    end
    cy = cy + ROW + 6
    -- 状态组
    local groups = snap.groups or {}
    for ti, tg in ipairs(st.targets) do
        local gl, gv = {}, {}
        local found
        for _, g in ipairs(groups) do if g.name == tg.group then found = g end end
        if not found then gl[#gl + 1] = tg.group .. " · " .. t("moved"); gv[#gv + 1] = tg.group end
        for _, g in ipairs(groups) do gl[#gl + 1] = g.name; gv[#gv + 1] = g.name end
        select_values("tgroup:" .. k .. ":" .. ti, x, cy + 1, sel_w, gl, gv, tg.group, nil, function(val)
            ctx.act({ kind = "state-target-group", index = k, target = ti, group = val })
        end)
        D.text_mid("→", x + sel_w + 2, cy, ROW, C.muted, W.small())
        local ol, ov = {}, {}
        local has = false
        for _, o in ipairs(found and found.options or {}) do
            ol[#ol + 1] = o.name; ov[#ov + 1] = o.name
            if o.name == tg.option then has = true end
        end
        if not has then table.insert(ol, 1, tg.option .. " · " .. t("moved")); table.insert(ov, 1, tg.option) end
        select_values("topt:" .. k .. ":" .. ti, bx, cy + 1, sel_w, ol, ov, tg.option, nil, function(val)
            ctx.act({ kind = "state-target", index = k, group = tg.group, option = val })
        end)
        local xb = x + w - 22
        local r2, c2 = U.result_text(tg.result, states, t)
        if r2 ~= "" then D.text_mid(r2, bx + sel_w + 8, cy, ROW, RES_COLOR[c2] or C.muted, W.small(), max(0, xb - bx - sel_w - 12)) end
        if W.x_button(xb, cy + 2, 22) then ctx.act({ kind = "state-target-remove", index = k, target = ti }) end
        cy = cy + ROW + 6
    end
    local used = {}
    for _, tg in ipairs(st.targets) do used[tg.group] = true end
    local free
    for _, g in ipairs(groups) do if not used[g.name] and #g.options > 0 then free = free or g end end
    if W.tbutton(t("addGroupTarget"), x, cy + 2, { disabled = free == nil }) and free then
        ctx.act({ kind = "state-target", index = k, group = free.name, option = free.options[1].name })
    end
    cy = cy + 30
    return cy - y
end

function Page.draw(ctx, x, y, w)
    local snap, t, ps = ctx.snap, ctx.t, ctx.state
    ps.open = ps.open or {}
    ps.drafts = ps.drafts or {}
    local open = ps.open
    local states = snap.states or {}
    local cy = y

    -- 顶栏
    local F = W.flow(x, cy, w, 10, 28)
    local changed, v = F:toggle(t("conditionSwitch"), snap.auto, { tip = t("conditionSwitchHint"), font = W.bold() })
    if changed then ctx.act({ kind = "auto", enabled = v }) end
    for _, kind in ipairs(LEGEND) do
        local label = t(U.KIND_KEY[kind])
        local lx, ly = F:place(16 + D.measure(W.small(), label), 28)
        W.status_dot(kind, lx + 5, ly + 14, 4.5)
        D.text_mid(label, lx + 14, ly, 28, C.muted, W.small())
    end
    if F:button(t("expandAll")) then for i = 1, #states do open[i] = true end end
    if F:button(t("collapseAll")) then ps.open = {}; open = ps.open end
    if F:button(t("newState"), { kind = "primary" }) then
        local n = #states + 1
        local base = t("newState")
        local taken = {}
        for _, s in ipairs(states) do taken[s.name] = true end
        while taken[base .. " " .. n] do n = n + 1 end
        if ctx.act({ kind = "state-new", name = base .. " " .. n }) then open[#states + 1] = true end
    end
    cy = cy + F:height() + 4
    D.text_mid(t("orderHintPanel"), x, cy, 20, C.faint, W.small())
    cy = cy + 26
    if #states == 0 then
        D.text_mid(t("noStates"), x, cy, 22, C.muted, W.small())
        cy = cy + 28
    end

    for k, st in ipairs(states) do
        local top = cy
        local is_open = open[k]
        local hx = x + 8
        local mv = W.move_buttons(hx, cy + 7)
        if mv then
            local to = k + mv
            if to >= 1 and to <= #states then
                if ctx.act({ kind = "state-move", from = k, to = to }) then open[k], open[to] = open[to], open[k] end
            end
        end
        hx = hx + 50
        if is_open then D.text_mid(tostring(k), hx, cy + 4, ROW, C.faint, W.small()); end
        hx = hx + 16
        if W.caret(hx, cy + 4, is_open, ROW) then open[k] = not open[k] or nil end
        hx = hx + 20
        W.status_dot(st.kind, hx + 6, cy + 4 + ROW / 2, 5)
        W.tooltip(U.kind_text(st, states, t), hx, cy + 4, 14, ROW)
        hx = hx + 18
        -- 右侧:启用开关(展开时还有删除)
        local right = x + w - 8
        if is_open then
            local dw = W.tbutton_w(t("delete"))
            if W.tbutton(t("delete"), right - dw, cy + 6, { kind = "danger" }) then ps.confirming = k end
            right = right - dw - 8
        end
        local tw = W.toggle_w(is_open and t("enabled") or "", W.small())
        local c2, en = W.toggle(is_open and t("enabled") or "", right - tw, cy + 4, st.enabled, { font = W.small() })
        if c2 then ctx.act({ kind = "state-field", index = k, field = "enabled", value = en }) end
        right = right - tw - 10
        if not is_open then
            local nw = D.text_mid(st.name, hx, cy + 4, ROW, st.enabled and C.text or C.muted, W.bold(), 200)
            local sx = hx + nw + 10
            if st.exclusive then sx = sx + W.tag(t("exclusive"), sx, cy + 7, C.brass) + 8 end
            local sum = U.condition_sentence(st, t) .. "　→　" .. U.target_sentence(st, t)
            local sw = D.text_mid(sum, sx, cy + 4, ROW, C.muted, W.small(), max(0, right - sx))
            W.tooltip(sum, sx, cy + 4, sw, ROW)
            cy = cy + ROW + 8
        else
            local HF = W.flow(hx, cy + 4, right - hx, 8, ROW)
            local nx, ny = HF:place(min(200, HF:remaining()), ROW)
            W.commit_box(ps.drafts, "sname:" .. k, nx, ny + 1, min(200, right - nx), 24, st.name, t("stateName"), function(name)
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if name ~= "" and name ~= st.name then ctx.act({ kind = "state-rename", index = k, name = name }) end
            end)
            local ew = W.tbutton_w(t("exclusive"))
            local ex, ey = HF:place(ew, ROW)
            if W.tbutton(t("exclusive"), ex, ey + 2, { pressed = st.exclusive, tip = t("exclusiveHint") }) then
                ctx.act({ kind = "state-field", index = k, field = "exclusive", value = not st.exclusive })
            end
            -- 渐入 / 渐出(溶解过渡)属于新版特性:关闭时灰掉、不可改
            local fade_off = R.nf_off(snap)
            local function fade(label, field, value)
                HF:text(label, fade_off and C.faint or nil)
                local fx, fy = HF:place(50, ROW)
                W.num_box(ps.drafts, field .. ":" .. k, fx, fy + 1, 50, value, { min = 0, max = 30, disabled = fade_off }, function(n)
                    ctx.act({ kind = "state-field", index = k, field = field, value = n })
                end)
            end
            fade(t("fadeIn"), "fade_in", st.fadeIn)
            fade(t("fadeOut"), "fade_out", st.fadeOut)
            HF:text(t("seconds"))
            cy = cy + max(ROW, HF:height()) + 10
        end

        if ps.confirming == k then
            local r, h = W.confirm(x + 10, cy, w - 20, t("delete") .. "「" .. st.name .. "」？", t("confirmDelete"), t("cancel"), "danger", C.error)
            if r then ps.confirming = nil end
            if r == "yes" then
                if ctx.act({ kind = "state-delete", index = k }) then
                    -- 下面的条件状态上移一位,展开状态跟着移
                    local moved = {}
                    for i, val in pairs(open) do if i < k then moved[i] = val elseif i > k then moved[i - 1] = val end end
                    ps.open = moved
                    open = moved
                end
            end
            cy = cy + h
        end

        if is_open then
            W.separator(x + 8, cy, w - 16)
            cy = cy + 8
            local bx, bw = x + 14, w - 28
            if bw >= 760 then
                local lw = math.floor(bw * 0.54)
                local h1 = draw_trigger(ctx, k, st, bx, cy, lw - 12)
                D.rect(bx + lw - 4, cy, 1, max(h1, 60), C.line)
                local h2 = draw_targets(ctx, k, st, bx + lw + 8, cy, bw - lw - 8)
                cy = cy + max(h1, h2) + 4
            else
                cy = cy + draw_trigger(ctx, k, st, bx, cy, bw) + 6
                cy = cy + draw_targets(ctx, k, st, bx, cy, bw) + 4
            end
        end
        local border = st.kind == "active" and C.ok or (st.kind == "outranked" and C.error or C.line)
        D.outline(x, top, w, cy - top, T.m.radius, 1, border)
        cy = cy + 8
    end
    return cy - y
end

return Page
