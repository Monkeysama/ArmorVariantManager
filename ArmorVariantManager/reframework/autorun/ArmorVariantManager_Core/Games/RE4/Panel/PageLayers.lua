-- 整套造型 / 状态组的编辑页(两个页签共用,对应 web/src/re4/Re4Layers.vue)。可折叠的栏默认收起。
--   整套造型:完整快照,材质只有开 / 关;新建时抓当前外观。
--   状态组:先用「编辑范围」划定管哪些材质,选项在范围里设「- / 关 / 开」。几个组可以管同一个材质,
--   靠下的组覆盖靠上的(顺序就是叠加顺序,用 ▲▼ 调整);只提示取值不同的重叠。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local U = require("ArmorVariantManager_Core.Games.RE4.Panel.Common")
local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")

local C = T.c
local max, min = math.max, math.min
local Page = {}

local HEIGHT_MIN, HEIGHT_MAX = -10, 50
local ROW = 26

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function cm_text(v) return (v > 0 and "+" or "") .. U.num_text(v) end

-- 每帧算一次的派生数据(和 Vue 的 computed 对应)
local function derive(snap)
    local d = { notes = {}, owners = {}, writes = {}, index = {}, slots = {}, all_keys = {} }
    for _, s in ipairs(snap.slots or {}) do
        for _, m in ipairs(s.materials) do
            if m.note then d.notes[U.key_of(s.id, m.name)] = m.note end
        end
        if not s.mirrored then
            d.slots[#d.slots + 1] = s
            for _, m in ipairs(s.materials) do d.all_keys[#d.all_keys + 1] = U.key_of(s.id, m.name) end
        end
    end
    for i, g in ipairs(snap.groups or {}) do
        d.index[g.name] = i
        for _, k in ipairs(g.scope) do
            d.owners[k] = d.owners[k] or {}
            table.insert(d.owners[k], g.name)
        end
        local wr = {}
        for _, o in ipairs(g.options) do
            for k, v in pairs(o.values or {}) do
                if type(v) == "boolean" then
                    wr[k] = wr[k] or { on = false, off = false }
                    if v then wr[k].on = true else wr[k].off = true end
                end
            end
        end
        d.writes[g.name] = wr
    end
    -- 组与组之间取值不同的重叠:below = 被下面的组覆盖,above = 覆盖上面的组
    d.overlaps = {}
    local gs = snap.groups or {}
    local function clash(a, b, key)
        local x, y = d.writes[a][key], d.writes[b][key]
        return x and y and ((x.on and y.off) or (x.off and y.on))
    end
    for i, g in ipairs(gs) do
        local below, above = {}, {}
        local in_scope = {}
        for _, k in ipairs(g.scope) do in_scope[k] = true end
        for j, h in ipairs(gs) do
            if i ~= j then
                local n = 0
                for _, k in ipairs(h.scope) do if in_scope[k] and clash(g.name, h.name, k) then n = n + 1 end end
                if n > 0 then table.insert(j > i and below or above, { name = h.name, n = n }) end
            end
        end
        d.overlaps[g.name] = { below = below, above = above }
    end
    return d
end

local function others_of(d, key, self_name)
    local out = {}
    for _, n in ipairs(d.owners[key] or {}) do if n ~= self_name then out[#out + 1] = n end end
    return out
end

-- 这个选项在 key 上写的值,会被哪些更靠下的组写成相反的值
local function overriders(d, card, values, key)
    local v = values[key]
    if card.is_base or type(v) ~= "boolean" then return {} end
    local me = d.index[card.name] or 0
    local out = {}
    for _, n in ipairs(others_of(d, key, card.name)) do
        local wr = d.writes[n] and d.writes[n][key]
        if (d.index[n] or 0) > me and wr and ((v and wr.off) or (not v and wr.on)) then out[#out + 1] = n end
    end
    return out
end

local function counts(card, values)
    local on, off = 0, 0
    for _, k in ipairs(card.scope) do
        if values[k] == true then on = on + 1 elseif values[k] == false then off = off + 1 end
    end
    return on, off, #card.scope - on - off
end

local function value_of(values, key)
    if values[key] == true then return "on" elseif values[key] == false then return "off" end
    return "none"
end

local function cards_of(snap, t, mode, d)
    if mode == "base" then
        local b = snap.base
        return { { id = "base", is_base = true, name = t("tabBase"), active = b.active, effective = b.effective,
            from_state = b.fromState, scope = d.all_keys, options = b.presets } }
    end
    local out = {}
    for _, g in ipairs(snap.groups or {}) do
        out[#out + 1] = { id = "g:" .. g.name, is_base = false, name = g.name, active = g.active, effective = g.effective,
            from_state = g.fromState, scope = g.scope, options = g.options }
    end
    return out
end

-- 单选圆点 + 名字。返回 clicked、宽度
local function radio(label, x, y, on, disabled, color)
    local f = W.body()
    local w = 18 + D.measure(f, label)
    local cy = y + ROW / 2
    D.circle(x + 6, cy, 6, 1.2, on and C.brass or C.line)
    if on then D.fill_circle(x + 6, cy, 3, C.brass) end
    D.text_mid(label, x + 18, y, ROW, color or C.text, f)
    return not disabled and I.click(x, y, w, ROW), w
end

function Page.draw(ctx, x, y, w)
    local snap, t, st, mode = ctx.snap, ctx.t, ctx.state, ctx.mode
    st.open = st.open or {}
    st.scope_open = st.scope_open or {}
    st.drafts = st.drafts or {}
    local open, scope_open = st.open, st.scope_open
    local d = derive(snap)
    local cards = cards_of(snap, t, mode, d)
    local function state_name(i) return i and (snap.states[i] or {}).name or "" end
    local function act(card, kind, extra)
        local a = { kind = kind }
        if not card.is_base then a.group = card.name end
        for k, v in pairs(extra or {}) do a[k] = v end
        return ctx.act(a)
    end
    local function users(card, option) return U.users_of(snap, card.is_base and nil or card.name, option) end

    local cy = y
    local changed, v = W.toggle(t("notesMode"), x, cy, st.notes == true, { tip = t("notesHint") })
    if changed then st.notes = v end
    if mode == "groups" then
        D.text_mid(t("groupOrderPanel"), x + W.toggle_w(t("notesMode")) + 20, cy, 28, C.faint, W.small())
    end
    cy = cy + 36

    for ci, card in ipairs(cards) do
        local is_open = card.is_base or open[card.id]
        local top = cy
        -- ---------------------------------------------------- 标题行
        local acts = {}
        if card.is_base then acts = { { t("newBase"), "new" } }
        else acts = { { t("editScope"), "scope" }, { t("delete"), "delete", kind = "danger" } } end
        local aw = 0
        for _, a in ipairs(acts) do aw = aw + W.tbutton_w(a[1]) + 6 end
        local ax = x + w - aw - 8
        local hx = x + 10
        if not card.is_base then
            local mv = W.move_buttons(hx, cy + 7)
            if mv then ctx.act({ kind = "group-move", group = card.name, offset = mv }) end
            hx = hx + 50
            D.text_mid(tostring(ci), hx, cy + 4, ROW, C.faint, W.small())
            hx = hx + 16
            if W.caret(hx, cy + 4, is_open, ROW) then open[card.id] = not open[card.id] or nil end
            hx = hx + 20
        end
        local F = W.flow(hx, cy + 4, ax - hx - 8, 8, ROW)
        if not card.is_base and is_open then
            local nx, ny = F:place(min(200, F:remaining()), ROW)
            W.commit_box(st.drafts, "gname:" .. card.name, nx, ny + 1, min(200, ax - nx), 24, card.name, t("groupName"), function(name)
                name = trim(name)
                if name == "" or name == card.name then return end
                if ctx.act({ kind = "group-rename", group = card.name, name = name }) then
                    -- 展开状态按名字记,改名后跟着搬
                    local from, to = card.id, "g:" .. name
                    for _, set in ipairs({ open, scope_open }) do
                        local moved = {}
                        for k, val in pairs(set) do
                            if k == from then moved[to] = val; set[k] = nil
                            elseif k:sub(1, #from + 1) == from .. "|" then moved[to .. k:sub(#from + 1)] = val; set[k] = nil end
                        end
                        for k, val in pairs(moved) do set[k] = val end
                    end
                end
            end)
        else
            F:text(card.name, C.text, W.bold())
        end
        F:text(card.is_base and t("baseCount", #card.options)
            or (t("optionsCount", #card.options) .. " · " .. t("materialsCount", #card.scope)))
        if card.from_state then F:tag(t("takenOverBy", state_name(card.from_state)), C.ok) end
        if not card.is_base then
            local ov = d.overlaps[card.name] or { below = {}, above = {} }
            for _, o in ipairs(ov.below) do F:tag(t("overriddenBy", o.name, o.n), C.error) end
            for _, o in ipairs(ov.above) do F:tag(t("overrides", o.name, o.n)) end
        end
        local bx = ax
        for _, a in ipairs(acts) do
            local clicked, bw = W.tbutton(a[1], bx, cy + 6, { kind = a.kind })
            if clicked then
                if a[2] == "new" then
                    if ctx.act({ kind = "base-new" }) then open[card.id] = true end
                elseif a[2] == "scope" then
                    scope_open[card.id] = not scope_open[card.id] or nil
                    open[card.id] = true
                elseif a[2] == "delete" then st.confirming = card.id end
            end
            bx = bx + bw + 6
        end
        cy = cy + max(ROW + 8, F:height() + 8)

        if st.confirming == card.id then
            local u = users(card)
            local msg = t("delete") .. "「" .. card.name .. "」？" .. (#u > 0 and t("deleteWarnUsed", U.names(u)) or "") .. t("backupFirst")
            local r, h = W.confirm(x + 10, cy, w - 20, msg, t("confirmDelete"), t("cancel"), "danger", C.error)
            if r then st.confirming = nil end
            if r == "yes" then ctx.act({ kind = "group-delete", group = card.name }) end
            cy = cy + h
        end

        if is_open then
            -- ---------------------------------------------------- 编辑范围
            if scope_open[card.id] then
                local sx, sw = x + 10, w - 20
                local SF = W.flow(sx, cy, sw, 8, ROW)
                local fx, fy = SF:place(180, ROW)
                W.text_box("scope_filter", fx, fy + 1, 180, 24, st.scope_filter or "", t("scopeSearch"), function(v2) st.scope_filter = v2 end)
                local c2, v2 = SF:checkbox(t("scopeOnlyIn"), st.scope_only_in == true, { font = W.small() })
                if c2 then st.scope_only_in = v2 end
                SF:text(t("scopeCount", #card.scope, #d.all_keys))
                local q = trim(st.scope_filter):lower()
                local in_scope = {}
                for _, k in ipairs(card.scope) do in_scope[k] = true end
                local shown = {}
                for _, s in ipairs(d.slots) do
                    local mats = {}
                    for _, m in ipairs(s.materials) do
                        local key = U.key_of(s.id, m.name)
                        local ok = not (st.scope_only_in and not in_scope[key])
                        if ok and q ~= "" then
                            ok = m.name:lower():find(q, 1, true) ~= nil or (d.notes[key] or ""):lower():find(q, 1, true) ~= nil
                        end
                        if ok then mats[#mats + 1] = m end
                    end
                    if #mats > 0 then shown[#shown + 1] = { slot = s, materials = mats } end
                end
                local function bulk(list, add)
                    local picked = {}
                    for _, e in ipairs(list) do
                        for _, m in ipairs(e.materials) do
                            if (in_scope[U.key_of(e.slot.id, m.name)] == true) ~= add then
                                picked[#picked + 1] = { slot = e.slot.id, material = m.name }
                            end
                        end
                    end
                    if #picked == 0 then return end
                    ctx.act({ kind = "scope-set", group = card.name, add = add and picked or {}, remove = add and {} or picked })
                end
                if SF:button(q ~= "" and t("scopeAddShown") or t("scopeAddAll")) then bulk(shown, true) end
                if SF:button(q ~= "" and t("scopeClearShown") or t("scopeClearAll"), { tip = t("scopeHint") }) then bulk(shown, false) end
                if SF:button(t("done"), { kind = "primary" }) then scope_open[card.id] = nil end
                cy = cy + SF:height() + 6
                if #shown == 0 then
                    D.text_mid(t("scopeNoMatch"), sx, cy, 22, C.muted, W.small())
                    cy = cy + 24
                end
                for _, e in ipairs(shown) do
                    local n_in = 0
                    for _, k in ipairs(card.scope) do if U.split_key(k) == e.slot.id then n_in = n_in + 1 end end
                    local PF = W.flow(sx, cy, sw, 8, 24)
                    PF:text(U.short_slot(e.slot.label), C.text, W.bold())
                    PF:text(n_in .. " / " .. #e.slot.materials)
                    if PF:button(t("scopeAddPart")) then bulk({ e }, true) end
                    if PF:button(t("scopeClearPart"), { tip = t("scopeHint") }) then bulk({ e }, false) end
                    cy = cy + PF:height() + 2
                    local GF = W.flow(sx + 8, cy, sw - 8, 14, 24)
                    for _, m in ipairs(e.materials) do
                        local key = U.key_of(e.slot.id, m.name)
                        local label = m.name .. (d.notes[key] and ("  " .. d.notes[key]) or "")
                        local cw = min(W.checkbox_w(label, W.small()), sw - 8)
                        local mx, my = GF:place(cw, 24)
                        if W.visible(my, 24) then
                            local others = others_of(d, key, card.name)
                            local c3 = W.checkbox(label, mx, my, in_scope[key] == true, { font = W.small(), h = 24,
                                color = in_scope[key] and C.text or C.muted,
                                tip = #others > 0 and t("alsoIn", table.concat(others, "、")) or nil })
                            if c3 then
                                ctx.act({ kind = in_scope[key] and "scope-remove" or "scope-add", group = card.name,
                                    slot = e.slot.id, material = m.name })
                            end
                        end
                    end
                    cy = cy + GF:height() + 6
                end
                W.separator(sx, cy, sw)
                cy = cy + 8
            end

            -- ---------------------------------------------------- 选项列表
            local ox, ow = x + 10, w - 20
            if not card.is_base then
                local clicked = radio(t("none"), ox + 22, cy, card.active == "", false)
                if clicked then ctx.act({ kind = "manual", layer = card.name, option = "" }) end
                cy = cy + ROW + 2
            end
            for _, opt in ipairs(card.options) do
                local oid = card.id .. "|" .. opt.name
                local eff = card.from_state and card.effective == opt.name
                if W.caret(ox, cy, open[oid], ROW) then open[oid] = not open[oid] or nil end
                -- 右侧操作
                local renaming = st.renaming and st.renaming.id == oid
                local oacts = renaming and { { t("done"), "done", kind = "primary" }, { t("cancel"), "cancel" } }
                    or { { t("rename"), "rename" }, { t("delete"), "delete", kind = "danger" } }
                local oaw = 0
                for _, a in ipairs(oacts) do oaw = oaw + W.tbutton_w(a[1]) + 6 end
                local oax = ox + ow - oaw
                local OF = W.flow(ox + 22, cy, oax - ox - 30, 10, ROW)
                if renaming then
                    local rx, ry = OF:place(180, ROW)
                    W.text_box("opt_rename", rx, ry + 1, 180, 24, st.renaming.text, "", function(v2) st.renaming.text = v2 end)
                else
                    local label = opt.name
                    local rw = 18 + D.measure(W.body(), label)
                    local rx, ry = OF:place(rw, ROW)
                    local clicked = radio(label, rx, ry, card.active == opt.name, false, eff and C.ok or nil)
                    if clicked then ctx.act({ kind = "manual", layer = card.is_base and "base" or card.name, option = opt.name }) end
                end
                local on, off, ignore = counts(card, opt.values or {})
                OF:text(t("countOn", on), C.ok)
                OF:text(t("countOff", off), C.error)
                if not card.is_base and ignore > 0 then OF:text(t("countIgnore", ignore)) end
                if opt.match and opt.match.status == "mismatch" then OF:tag(t("mismatch"), C.error)
                elseif opt.match and opt.match.status == "partial" then OF:tag(t("partialSlots", table.concat(opt.match.skipped, "、")), C.warn) end
                local u = users(card, opt.name)
                if #u > 0 then OF:text(t("usedBy", U.names(u)), C.signal) end
                if opt.height ~= nil then OF:tag(t("heightTag", cm_text(opt.height))) end
                local bx2 = oax
                for _, a in ipairs(oacts) do
                    local clicked, bw = W.tbutton(a[1], bx2, cy + 2, { kind = a.kind })
                    if clicked then
                        if a[2] == "rename" then st.renaming = { id = oid, text = opt.name }; st.confirming = nil
                        elseif a[2] == "cancel" then st.renaming = nil
                        elseif a[2] == "done" then
                            local name = trim(st.renaming.text)
                            st.renaming = nil
                            if name ~= "" and name ~= opt.name then
                                if card.is_base then ctx.act({ kind = "base-rename", preset = opt.name, name = name })
                                else ctx.act({ kind = "option-rename", group = card.name, option = opt.name, name = name }) end
                            end
                        elseif a[2] == "delete" then st.confirming = oid end
                    end
                    bx2 = bx2 + bw + 6
                end
                cy = cy + max(ROW, OF:height()) + 4

                if st.confirming == oid then
                    local msg = t("delete") .. "「" .. opt.name .. "」？" .. (#u > 0 and t("deleteWarnUsed", U.names(u)) or "") .. t("backupFirst")
                    local r, h = W.confirm(ox + 22, cy, ow - 22, msg, t("confirmDelete"), t("cancel"), "danger", C.error)
                    if r then st.confirming = nil end
                    if r == "yes" then
                        if card.is_base then ctx.act({ kind = "base-delete", preset = opt.name })
                        else ctx.act({ kind = "option-delete", group = card.name, option = opt.name }) end
                    end
                    cy = cy + h
                end

                if open[oid] then
                    local mx0, mw = ox + 22, ow - 22
                    local TF = W.flow(mx0, cy, mw, 6, ROW)
                    local sel = card.is_base and { preset = opt.name } or { option = opt.name }
                    local prefix = card.is_base and "base" or "option"
                    local function with(extra) local a = {}; for k, v2 in pairs(sel) do a[k] = v2 end; for k, v2 in pairs(extra) do a[k] = v2 end; return a end
                    if TF:button(t("moveUp")) then act(card, prefix .. "-move", with({ offset = -1 })) end
                    if TF:button(t("moveDown")) then act(card, prefix .. "-move", with({ offset = 1 })) end
                    if TF:button(t("duplicate")) then act(card, prefix .. "-duplicate", sel) end
                    if card.is_base then
                        if st.confirming ~= "rc|" .. opt.name then
                            if TF:button(t("recapture")) then st.confirming = "rc|" .. opt.name end
                        else
                            if TF:button(t("confirmRecapture"), { kind = "danger" }) then
                                st.confirming = nil
                                ctx.act({ kind = "base-recapture", preset = opt.name })
                            end
                            if TF:button(t("cancel")) then st.confirming = nil end
                        end
                    end
                    TF:text(t("heightLabel"), C.muted)
                    local hx2, hy2 = TF:place(64, ROW)
                    W.num_box(st.drafts, "h:" .. oid, hx2, hy2 + 1, 64, opt.height,
                        { min = HEIGHT_MIN, max = HEIGHT_MAX, allow_empty = true, placeholder = t("heightUnset"), tip = t("heightHint") },
                        function(n)
                            local cm = n and math.floor(n * 10 + 0.5) / 10 or nil
                            if card.is_base then ctx.act({ kind = "base-height", preset = opt.name, cm = cm })
                            else ctx.act({ kind = "option-height", group = card.name, option = opt.name, cm = cm }) end
                        end)
                    TF:text("cm", C.muted)
                    if opt.height ~= nil and TF:button(t("heightClear"), { kind = "ghost" }) then
                        if card.is_base then ctx.act({ kind = "base-height", preset = opt.name })
                        else ctx.act({ kind = "option-height", group = card.name, option = opt.name }) end
                    end
                    cy = cy + TF:height() + 6
                    if #card.scope == 0 then
                        D.text_mid(t("emptyScope"), mx0, cy, 22, C.muted, W.small(), mw)
                        cy = cy + 26
                    end
                    local labels = { on = t("on"), off = t("off") }
                    local tri_w = card.is_base and 70 or 100
                    for _, key in ipairs(card.scope) do
                        if W.visible(cy, ROW) then
                            local slot, mat = U.split_key(key)
                            local val = value_of(opt.values or {}, key)
                            local nv = W.tri(mx0, cy + 2, val, labels, card.is_base, false)
                            if nv and nv ~= val then
                                if card.is_base then
                                    ctx.act({ kind = "base-material", preset = opt.name, slot = slot, material = mat, value = nv == "on" })
                                else
                                    ctx.act({ kind = "option-material", group = card.name, option = opt.name, slot = slot, material = mat, value = nv })
                                end
                            end
                            local nx = mx0 + tri_w + 8
                            local name_col = val == "on" and C.text or (val == "off" and C.muted or C.faint)
                            local nw = D.text_mid(mat, nx, cy, ROW, name_col, W.small(), 200)
                            W.tooltip(U.slot_label(snap, slot), nx, cy, nw, ROW)
                            nx = nx + max(nw, 120) + 10
                            if st.notes then
                                W.commit_box(st.drafts, "note:" .. key, nx, cy + 2, 160, 22, d.notes[key] or "", t("notePlaceholder"), function(text)
                                    ctx.act({ kind = "note", slot = slot, material = mat, text = text })
                                end)
                                nx = nx + 168
                                local c4, lw = W.tbutton(t("locate"), nx, cy + 2)
                                if c4 then ctx.act({ kind = "locate", slot = slot, material = mat }) end
                                nx = nx + lw + 8
                            elseif d.notes[key] then
                                nx = nx + D.text_mid(d.notes[key], nx, cy, ROW, C.muted, W.small(), 200) + 10
                            end
                            local ovr = overriders(d, card, opt.values or {}, key)
                            if #ovr > 0 then
                                local ow2 = D.text_mid(t("mayBeOverridden", table.concat(ovr, "、")), nx, cy, ROW, C.error, W.small(), max(40, mx0 + mw - nx))
                                W.tooltip(t("overlapHint"), nx, cy, ow2, ROW)
                            end
                        end
                        cy = cy + ROW
                    end
                    cy = cy + 6
                end
            end
            if not card.is_base then
                local clicked = W.tbutton(t("newOption"), ox, cy + 2, { kind = nil })
                if clicked and ctx.act({ kind = "option-new", group = card.name }) then open[card.id] = true end
                cy = cy + 30
            end
        end
        -- 卡片边框(画在内容之后:只描边,不盖住内容)
        D.outline(x, top, w, cy - top + 4, T.m.radius, 1, C.line)
        cy = cy + 12
    end

    if mode == "groups" then
        if #cards == 0 then
            D.text_mid(t("noGroups"), x, cy, 22, C.muted, W.small())
            cy = cy + 28
        end
        W.text_box("group_new", x, cy, 200, 26, st.new_group or "", t("groupName"), function(v2) st.new_group = v2 end)
        local name = trim(st.new_group)
        local clicked = W.button(t("newGroup"), x + 208, cy, nil, 26, { font = W.small(), disabled = name == "" })
        if clicked and ctx.act({ kind = "group-new", name = name }) then
            st.new_group = ""
            open["g:" .. name], scope_open["g:" .. name] = true, true
        end
        cy = cy + 36
    end
    return cy - y
end

return Page
