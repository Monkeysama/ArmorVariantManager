-- 快速切换页(对应 web/src/re4/Re4Quick.vue,外加原左侧栏的游戏状态 / 最终材质,两块默认收起)。
-- 被条件状态接管的层在这里锁定(只在这里锁,编辑页照常能改手动选择)。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local U = require("ArmorVariantManager_Core.Games.RE4.Panel.Common")
local R = require("ArmorVariantManager_Core.Games.RE4.Panel.Refs")

local C = T.c
local max = math.max
local Page = {}

local function owner(snap, i) return i and (snap.states[i] or {}).name or "" end

-- 复选组的一行:左边名字;右边先是「（无）」按钮(框同分段按钮,点一下关掉全部),
-- 后面各选项用勾选框紧凑排列,按各自的接管锁定。返回高度
local function multi_row(ctx, x, y, w, g)
    local snap, t = ctx.snap, ctx.t
    local name_w = math.min(180, w * 0.28)
    D.text_mid(g.name, x, y, 26, C.text, W.body(), name_w - 8)
    local any = false
    for _, o in ipairs(g.options) do if o.on then any = true end end
    local F = W.flow(x + name_w, y, w - name_w, 10, 26)
    local nw = D.measure(W.small(), t("none")) + 20
    local nx, ny = F:place(nw, 26)
    if W.button(t("none"), nx, ny, nw, 26, { font = W.small(), pressed = not any }) and any then
        ctx.act({ kind = "manual", layer = g.name, option = "" })
    end
    for _, o in ipairs(g.options) do
        local locked = o.fromState
        local on
        if locked then on = o.effective == true else on = o.on == true end
        local cw = 16 + 8 + D.measure(W.body(), o.name) + 6
        local bx, by = F:place(cw, 26)
        local ch = W.checkbox("", bx, by, on, { h = 26, disabled = locked ~= nil })
        if ch then ctx.act({ kind = "option-on", group = g.name, option = o.name, on = not o.on }) end
        D.text_mid(o.name, bx + 22, by, 26, (locked and on) and C.ok or (locked and C.muted or C.text), W.body())
        if locked then W.tooltip(t("lockedBy", owner(snap, locked)), bx, by, cw, 26) end
    end
    return max(26, F:height())
end

-- 一行:左边名字,右边分段按钮。返回高度
local function layer_row(ctx, x, y, w, label, layer, active, effective, locked, options, with_none)
    local snap, t = ctx.snap, ctx.t
    local name_w = math.min(180, w * 0.28)
    D.text_mid(label, x, y, 26, locked and C.muted or C.text, W.body(), name_w - 8)
    local items = {}
    if with_none then items[#items + 1] = { t("none"), "" } end
    for _, n in ipairs(options) do items[#items + 1] = { n, n, eff = locked and effective == n or nil } end
    local tip = locked and t("lockedBy", owner(snap, locked)) or nil
    local picked, h = W.segments(x + name_w, y, w - name_w, items, active, { disabled = locked ~= nil, tip = tip })
    if picked ~= nil then ctx.act({ kind = "manual", layer = layer, option = picked }) end
    return max(26, h)
end

local function hp_summary(snap, t)
    local hp = snap.status and snap.status.hp
    return hp and t("hpSummary", string.format("%.1f", hp)) or ""
end

function Page.draw(ctx, x, y, w)
    local snap, t, st = ctx.snap, ctx.t, ctx.state
    local cy = y

    -- 游戏状态(只读):HP + 当前成立的条件
    local clicked, hh = W.header(t("gameState"), x, cy, w, st.status_open, hp_summary(snap, t))
    if clicked then st.status_open = not st.status_open end
    cy = cy + hh + 4
    if st.status_open then
        local hp = snap.status and snap.status.hp
        if hp then
            D.text_mid(t("hp"), x + 4, cy, 22, C.muted, W.small())
            W.meter(x + 40, cy + 6, math.min(260, w - 120), 10, hp / 100, hp <= 30 and C.error or C.ok)
            D.text_mid(string.format("%.1f%%", hp), x + 48 + math.min(260, w - 120), cy, 22, C.text, W.small())
            cy = cy + 26
        end
        local F = W.flow(x + 4, cy, w - 8, 6, 22)
        local flags = (snap.status and snap.status.flags) or {}
        for _, f in ipairs(flags) do F:tag(f, C.ok) end
        if #flags == 0 then F:text(t("noTrue")) end
        cy = cy + F:height() + 8
    end

    -- 最终材质
    local on, off = 0, 0
    for _, r in ipairs(snap.look or {}) do if r.on then on = on + 1 else off = off + 1 end end
    clicked, hh = W.header(t("finalMaterials"), x, cy, w, st.look_open, t("lookSummary", on, off))
    if clicked then st.look_open = not st.look_open end
    cy = cy + hh + 4
    if st.look_open then
        if snap.locating then
            D.text_mid(t("locatingNow", snap.locating.material), x + 4, cy, 20, C.brass, W.small(), w - 8)
            cy = cy + 22
        end
        if snap.height and snap.height ~= 0 then
            local txt = t("heightNow", (snap.height > 0 and "+" or "") .. U.num_text(snap.height))
            if snap.settings.heightEnabled == false then txt = txt .. t("heightOff") end
            D.text_mid(txt, x + 4, cy, 20, snap.settings.heightEnabled == false and C.muted or C.text, W.small(), w - 8)
            cy = cy + 22
        end
        local notes = {}
        for _, s in ipairs(snap.slots or {}) do
            for _, m in ipairs(s.materials) do if m.note then notes[U.key_of(s.id, m.name)] = m.note end end
        end
        local last_slot
        local F
        for _, r in ipairs(snap.look or {}) do
            if r.slot ~= last_slot then
                if F then cy = cy + F:height() + 4 end
                last_slot = r.slot
                D.text_mid(U.slot_label(snap, r.slot), x + 4, cy, 20, C.muted, W.small())
                cy = cy + 20
                F = W.flow(x + 12, cy, w - 16, 14, 20)
            end
            local label = r.material
            local note = notes[U.key_of(r.slot, r.material)]
            if note then label = label .. "  " .. note end
            local tw = D.measure(W.small(), label) + 14
            local bx, by = F:place(math.min(tw, w - 16), 20)
            if r.on then D.fill_circle(bx + 4, by + 10, 3.5, C.ok) else D.circle(bx + 4, by + 10, 3.5, 1, C.faint) end
            D.text_mid(label, bx + 12, by, 20, r.on and C.text or C.faint, W.small(), w - 30)
        end
        if F then cy = cy + F:height() + 4 end
        cy = cy + 6
    end

    -- 整套造型
    cy = cy + 4
    local b = snap.base
    local names = {}
    for i, p in ipairs(b.presets) do names[i] = p.name end
    W.separator(x, cy, w)
    cy = cy + 8
    local h = layer_row(ctx, x, cy, w, t("tabBase"), "base", b.active, b.effective, b.fromState, names, false)
    cy = cy + h + 8
    W.separator(x, cy, w)
    cy = cy + 10

    -- 状态组(默认展开)
    clicked, hh = W.header(t("tabGroups"), x, cy, w, not st.groups_closed)
    if clicked then st.groups_closed = not st.groups_closed end
    cy = cy + hh + 4
    if not st.groups_closed then
        if #(snap.groups or {}) == 0 then
            D.text_mid(t("noGroups"), x + 12, cy, 22, C.muted, W.small())
            cy = cy + 26
        end
        -- 造型归属:当前整套造型不在这个状态组的归属里时不显示。
        -- 只有一个选项(不算「（无）」)的状态组用勾选框紧凑排在最后:勾上 = 选这个选项,取消 = 「（无）」
        local singles = {}
        for _, g in ipairs(snap.groups or {}) do
            if g.shown ~= false then
                if #g.options == 1 then
                    singles[#singles + 1] = g
                elseif g.multi then
                    cy = cy + multi_row(ctx, x + 12, cy, w - 24, g) + 6
                else
                    local opts = {}
                    for i, o in ipairs(g.options) do opts[i] = o.name end
                    local rh = layer_row(ctx, x + 12, cy, w - 24, g.name, g.name, g.active, g.effective, g.fromState, opts, true)
                    cy = cy + rh + 6
                end
            end
        end
        if #singles > 0 then
            local F = W.flow(x + 12, cy, w - 24, 10, 26)
            for _, g in ipairs(singles) do
                local opt = g.options[1].name
                local locked, on
                if g.multi then
                    local o = g.options[1]
                    locked = o.fromState
                    if locked then on = o.effective == true else on = o.on == true end
                else
                    locked = g.fromState
                    on = (locked and g.effective or g.active) == opt
                end
                local label = g.name
                local extra = opt ~= g.name and opt or nil
                local cw = 16 + 8 + D.measure(W.body(), label) + (extra and (8 + D.measure(W.small(), extra)) or 0) + 6
                local bx, by = F:place(cw, 26)
                local ch, v2 = W.checkbox("", bx, by, on, { h = 26, disabled = locked ~= nil })
                if ch then ctx.act({ kind = "manual", layer = g.name, option = v2 and opt or "" }) end
                local tx = bx + 22
                D.text_mid(label, tx, by, 26, (locked and on) and C.ok or (locked and C.muted or C.text), W.body())
                if extra then
                    D.text_mid(extra, tx + D.measure(W.body(), label) + 8, by, 26, C.muted, W.small())
                end
                if locked then W.tooltip(t("lockedBy", owner(snap, locked)), bx, by, cw, 26) end
            end
            cy = cy + F:height() + 6
        end
        cy = cy + 4
    end

    -- 条件切换:总开关 + 各条件状态的启用勾选与当前结果
    local changed, v = W.toggle(t("conditionSwitch"), x, cy, snap.auto, { tip = t("conditionSwitchHint"), font = W.bold() })
    if changed then ctx.act({ kind = "auto", enabled = v }) end
    cy = cy + 32
    local states = snap.states or {}
    if #states == 0 then
        D.text_mid(t("noStates"), x + 12, cy, 22, C.muted, W.small())
        cy = cy + 26
    else
        local F = W.flow(x + 12, cy, w - 24, 10, 26)
        for i, s in ipairs(states) do
            local label = s.name
            local cw = 16 + 16 + D.measure(W.body(), label) + 6
            local bx, by = F:place(cw, 26)
            local ch, on = W.checkbox("", bx, by, s.enabled, { h = 26 })
            if ch then ctx.act({ kind = "state-field", index = i, field = "enabled", value = on }) end
            W.status_dot(s.kind, bx + 24, by + 13, 5)
            D.text_mid(label, bx + 34, by, 26, s.enabled and C.text or C.muted, W.body())
            W.tooltip(U.kind_text(s, states, t) .. "\n" .. U.condition_sentence(s, t) .. " → " .. U.target_sentence(s, t),
                bx + 18, by, cw - 18, 26)
        end
        cy = cy + F:height() + 8
    end

    -- 调色方案:点一下就选中(选中就生效);"" = 初始。被引用、这一帧正在叠加生效的方案标成生效样式。
    -- 调色、模型高度属于新版特性:关闭时灰掉、不可改
    local nf_off = R.nf_off(snap)
    do
        local pl = snap.palettes or {}
        local selected = type(pl.selected) == "string" and pl.selected or ""
        local referenced = {}
        for _, n in ipairs(type(pl.active) == "table" and pl.active or {}) do referenced[n] = true end
        local name_w = math.min(180, w * 0.28)
        D.text_mid(t("paletteScheme"), x, cy + 4, 26, nf_off and C.faint or C.text, W.body(), name_w - 8)
        local items = { { t("paletteAlways"), "" } }
        for _, s in ipairs((type(pl.list) == "table" and pl.list) or {}) do
            local eff = selected ~= s.name and referenced[s.name] or nil
            items[#items + 1] = { s.name, s.name, eff = eff, tip = eff and t("paletteSchemeRefOn") or nil }
        end
        local picked, sh = W.segments(x + name_w, cy + 4, w - name_w, items, selected, { disabled = nf_off })
        if picked ~= nil and picked ~= selected then ctx.act({ kind = "palette-scheme-select", scheme = picked }) end
        cy = cy + max(26, sh) + 12
    end

    -- 模型高度
    cy = cy + 4
    D.text_mid(t("heightQuick"), x, cy, 26, C.text, W.bold())
    local hnow = (snap.height == nil or snap.height == 0) and t("heightNone")
        or ((snap.height > 0 and "+" or "") .. U.num_text(snap.height) .. " cm")
    local src = snap.heightSource
    local from
    if not src then from = t("heightNoSource")
    elseif src.layer == "override" then from = t("heightFromOverride")
    elseif src.layer == "base" then from = t("heightFromBase", src.option or "")
    else from = t("heightFromGroup", src.layer, src.option or "") end
    local F = W.flow(x + 140, cy, w - 140, 10, 26)
    F:text(hnow, snap.settings.heightEnabled == false and C.muted or C.text, W.bold())
    F:text(from)
    if snap.settings.heightEnabled == false then F:text(t("heightOff"), C.error) end
    cy = cy + F:height() + 6
    D.text_mid(t("heightOverride"), x, cy, 26, C.text, W.body())
    local ov = snap.heightOverride or { enabled = false, cm = 0 }
    changed, v = W.toggle("", x + 140, cy, ov.enabled, { disabled = nf_off })
    if changed then ctx.act({ kind = "height-override", enabled = v }) end
    st.drafts = st.drafts or {}
    W.num_box(st.drafts, "q_height", x + 180, cy + 1, 70, ov.cm, { min = -20, max = 50, disabled = nf_off }, function(n)
        ctx.act({ kind = "height-override", cm = n })
    end)
    D.text_mid("cm", x + 256, cy, 26, C.muted, W.small())
    D.paragraph(t("heightOverrideHint"), x + 284, cy + 5, w - 284, C.muted, W.small())
    cy = cy + 40
    return cy - y
end

return Page
