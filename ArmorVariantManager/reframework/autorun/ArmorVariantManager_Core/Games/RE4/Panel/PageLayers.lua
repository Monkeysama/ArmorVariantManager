-- 整套造型 / 状态组的编辑页(两个页签共用,对应 web/src/re4/Re4Layers.vue)。可折叠的栏默认收起。
--   整套造型:完整快照,材质只有开 / 关;新建时抓取当前外观。
--   状态组:选项列出当前模型的全部材质,每个设「- / 关 / 开」(没有范围限制)。几个组可以写同一个材质,
--   靠下的组覆盖靠上的(顺序就是叠加顺序,用 ▲▼ 调整);只提示取值不同的重叠。
--   材质按部位分段,每段三列排列(宽度不够时减列)。状态组的选项名点上就能改。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local U = require("ArmorVariantManager_Core.Games.RE4.Panel.Common")
local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")
local R = require("ArmorVariantManager_Core.Games.RE4.Panel.Refs")

local C = T.c
local max, min = math.max, math.min
local Page = {}

local HEIGHT_MIN, HEIGHT_MAX = -10, 50
local ROW = 26

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function cm_text(v) return (v > 0 and "+" or "") .. U.num_text(v) end

-- 每帧算一次的派生数据(和 Vue 的 computed 对应)
local function derive(snap)
    local d = { notes = {}, owners = {}, writes = {}, index = {}, slots = {}, all_keys = {}, set_count = {} }
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
        -- 材质 -> 写它的组(按叠加顺序)
        local ks = {}
        for k in pairs(wr) do ks[#ks + 1] = k end
        table.sort(ks)
        d.set_count[g.name] = #ks
        for _, k in ipairs(ks) do
            d.owners[k] = d.owners[k] or {}
            table.insert(d.owners[k], g.name)
        end
    end
    d.known = {}
    for _, k in ipairs(d.all_keys) do d.known[k] = true end
    -- 组与组之间取值不同的重叠:below = 被下面的组覆盖,above = 覆盖上面的组
    d.overlaps = {}
    local gs = snap.groups or {}
    local function clash(a, b, key)
        local x, y = d.writes[a][key], d.writes[b][key]
        return x and y and ((x.on and y.off) or (x.off and y.on))
    end
    for i, g in ipairs(gs) do
        local below, above = {}, {}
        for j, h in ipairs(gs) do
            if i ~= j then
                local n = 0
                for k in pairs(d.writes[g.name]) do if clash(g.name, h.name, k) then n = n + 1 end end
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

-- 整套造型只数当前模型上的材质;状态组数选项写了的材质
local function counts(d, card, values)
    local on, off = 0, 0
    local function add(v) if v == true then on = on + 1 elseif v == false then off = off + 1 end end
    if card.is_base then
        for _, k in ipairs(d.all_keys) do add(values[k]) end
    else
        for _, v in pairs(values) do add(v) end
    end
    return on, off
end

-- 选项展开后的材质:按部位分段;状态组写了、但当前模型上没有的材质另列一段(可以改成「-」清掉)
local function sections(d, t, card, values)
    local out = {}
    for _, s in ipairs(d.slots) do
        if #s.materials > 0 then
            local keys = {}
            for _, m in ipairs(s.materials) do keys[#keys + 1] = U.key_of(s.id, m.name) end
            out[#out + 1] = { id = s.id, label = U.short_slot(s.label), keys = keys }
        end
    end
    if not card.is_base then
        local extra = {}
        for k in pairs(values) do if not d.known[k] then extra[#extra + 1] = k end end
        table.sort(extra)
        if #extra > 0 then out[#out + 1] = { id = "", label = t("notOnModel"), keys = extra } end
    end
    return out
end

local function value_of(values, key)
    if values[key] == true then return "on" elseif values[key] == false then return "off" end
    return "none"
end

local function cards_of(snap, t, mode, d)
    if mode == "base" then
        local b = snap.base
        return { { id = "base", is_base = true, name = t("tabBase"), active = b.active, effective = b.effective,
            from_state = b.fromState, options = b.presets } }
    end
    local out = {}
    for _, g in ipairs(snap.groups or {}) do
        out[#out + 1] = { id = "g:" .. g.name, is_base = false, name = g.name, active = g.active, effective = g.effective,
            from_state = g.fromState, options = g.options, multi = g.multi == true,
            bases = type(g.bases) == "table" and g.bases or {} }
    end
    return out
end

-- 复选组用的方框(样式同 W.checkbox,行高同 radio)。返回 clicked、宽度
local function checkmark(label, x, y, on, disabled, color)
    local f = W.body()
    local w = 18 + D.measure(f, label)
    local by = y + (ROW - 14) / 2
    D.rrect(x, by, 14, 14, 2, C.ink)
    D.outline(x, by, 14, 14, 2, 1, on and C.brass or C.line)
    if on then D.rrect(x + 3, by + 3, 8, 8, 1, disabled and C.faint or C.brass) end
    D.text_mid(label, x + 18, y, ROW, color or C.text, f)
    return not disabled and I.click(x, y, w, ROW), w
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
    st.drafts = st.drafts or {}
    local open = st.open
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
        else acts = { { t("delete"), "delete", kind = "danger" } } end
        local aw = 0
        for _, a in ipairs(acts) do aw = aw + W.tbutton_w(a[1]) + 6 end
        -- 选择方式(单选 / 复选):放在操作按钮左边
        local mode_items, mode_w = nil, 0
        if not card.is_base then
            mode_items = { { t("groupSingle"), false, tip = t("groupModeHint") }, { t("groupMulti"), true, tip = t("groupModeHint") } }
            for _, it in ipairs(mode_items) do mode_w = mode_w + D.measure(W.small(), it[1]) + 24 end
        end
        local ax = x + w - aw - 8 - mode_w
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
                    local moved = {}
                    for k, val in pairs(open) do
                        if k == from then moved[to] = val; open[k] = nil
                        elseif k:sub(1, #from + 1) == from .. "|" then moved[to .. k:sub(#from + 1)] = val; open[k] = nil end
                    end
                    for k, val in pairs(moved) do open[k] = val end
                end
            end)
        else
            F:text(card.name, C.text, W.bold())
        end
        -- 状态组的选项数、材质数不占标题栏(窄时挤掉名字);整套造型照旧显示预设数
        if card.is_base then F:text(t("baseCount", #card.options)) end
        if card.from_state then F:tag(t("takenOverBy", state_name(card.from_state)), C.ok) end
        if not card.is_base then
            local ov = d.overlaps[card.name] or { below = {}, above = {} }
            for _, o in ipairs(ov.below) do F:tag(t("overriddenBy", o.name, o.n), C.error) end
            for _, o in ipairs(ov.above) do F:tag(t("overrides", o.name, o.n)) end
        end
        local bx = ax
        if mode_items then
            local picked = W.segments(bx, cy + 5, mode_w, mode_items, card.multi, { h = 24 })
            if picked ~= nil and picked ~= card.multi then ctx.act({ kind = "group-multi", group = card.name, on = picked }) end
            bx = bx + mode_w
        end
        for _, a in ipairs(acts) do
            local clicked, bw = W.tbutton(a[1], bx, cy + 6, { kind = a.kind })
            if clicked then
                if a[2] == "new" then
                    if ctx.act({ kind = "base-new" }) then open[card.id] = true end
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
            local ox, ow = x + 10, w - 20
            local nf_off = R.nf_off(snap)
            -- ---------------------------------------------------- 卡片设置行:轮换快捷键、造型归属(简化版)
            do
                local SF = W.flow(ox + 22, cy, ow - 22, 10, ROW)
                local structure = card.is_base and { kind = "base" } or { kind = "group", group = card.name }
                if not card.multi then R.hotkey(ctx, SF, card.id .. "|*", structure, t("hotkeyCycleRef")) end
                if not card.is_base then
                    -- 造型归属:按钮显示当前归属,点开后每个整套造型一个勾选框;全不勾 = 全部
                    local names = {}
                    for _, p in ipairs((snap.base and snap.base.presets) or {}) do names[#names + 1] = p.name end
                    local label = #card.bases == 0 and t("groupBasesAll") or table.concat(card.bases, "、")
                    st.bases_open = st.bases_open or {}
                    if SF:button(t("groupBases") .. "：" .. label, { tip = t("groupBasesHint") }) then
                        st.bases_open[card.id] = (not st.bases_open[card.id]) or nil
                    end
                    if st.bases_open[card.id] then
                        cy = cy + SF:height() + 4
                        SF = W.flow(ox + 40, cy, ow - 40, 10, ROW)
                        local chosen = {}
                        for _, n in ipairs(card.bases) do chosen[n] = true end
                        for _, n in ipairs(names) do
                            local ch, v = SF:checkbox(n, chosen[n] == true)
                            if ch then
                                local list = {}
                                for _, m in ipairs(names) do
                                    if (m == n and v) or (m ~= n and chosen[m]) then list[#list + 1] = m end
                                end
                                ctx.act({ kind = "group-bases", group = card.name, bases = list })
                            end
                        end
                        if #names == 0 then SF:text(t("baseCount", 0)) end
                    end
                end
                cy = cy + SF:height() + 4
            end
            -- ---------------------------------------------------- 选项列表
            if not card.is_base then
                -- 复选组的「（无）」= 全部关掉(已经全关时不可点)
                local none_on = card.active == ""
                if card.multi then
                    none_on = true
                    for _, o in ipairs(card.options) do if o.on then none_on = false end end
                end
                local clicked
                if card.multi then clicked = checkmark(t("none"), ox + 22, cy, none_on, none_on)
                else clicked = radio(t("none"), ox + 22, cy, none_on, false) end
                if clicked then ctx.act({ kind = "manual", layer = card.name, option = "" }) end
                -- 「（无）」的单项快捷键(同网页放在行右侧)
                local NF = W.flow(ox + ow - 300, cy, 300, 6, ROW)
                R.hotkey(ctx, NF, card.id .. "|", { kind = "group", group = card.name, option = "" })
                cy = cy + max(ROW, NF:height()) + 2
            end
            for _, opt in ipairs(card.options) do
                local oid = card.id .. "|" .. opt.name
                local eff
                if card.multi then eff = opt.fromState ~= nil and opt.effective == true
                else eff = card.from_state and card.effective == opt.name end
                if W.caret(ox, cy, open[oid], ROW) then open[oid] = not open[oid] or nil end
                -- 右侧操作
                -- 整套造型的预设和状态组的选项都是名字点上就能改(没有单独的重命名按钮)
                local oacts = { { t("delete"), "delete", kind = "danger" } }
                local oaw = 0
                for _, a in ipairs(oacts) do oaw = oaw + W.tbutton_w(a[1]) + 6 end
                local oax = ox + ow - oaw
                local OF = W.flow(ox + 22, cy, oax - ox - 30, 10, ROW)
                do
                    local rx, ry = OF:place(18 + 160, ROW)
                    if card.multi then
                        if checkmark("", rx, ry, opt.on == true, false, eff and C.ok or nil) then
                            ctx.act({ kind = "option-on", group = card.name, option = opt.name, on = not opt.on })
                        end
                    elseif radio("", rx, ry, card.active == opt.name, false, eff and C.ok or nil) then
                        ctx.act({ kind = "manual", layer = card.is_base and "base" or card.name, option = opt.name })
                    end
                    W.commit_box(st.drafts, "oname:" .. oid, rx + 18, ry + 1, 160, 24, opt.name, t("rename"), function(name)
                        name = trim(name)
                        if name == "" or name == opt.name then return end
                        local ok
                        if card.is_base then ok = ctx.act({ kind = "base-rename", preset = opt.name, name = name })
                        else ok = ctx.act({ kind = "option-rename", group = card.name, option = opt.name, name = name }) end
                        if ok and open[oid] then
                            open[oid] = nil
                            open[card.id .. "|" .. name] = true
                        end
                    end)
                end
                local on, off = counts(d, card, opt.values or {})
                OF:text(t("countOn", on), C.ok)
                OF:text(t("countOff", off), C.error)
                if opt.match and opt.match.status == "mismatch" then OF:tag(t("mismatch"), C.error)
                elseif opt.match and opt.match.status == "partial" then OF:tag(t("partialSlots", table.concat(opt.match.skipped, "、")), C.warn) end
                local u = users(card, opt.name)
                if #u > 0 then OF:text(t("usedBy", U.names(u)), C.signal) end
                if opt.height ~= nil then OF:tag(t("heightTag", cm_text(opt.height))) end
                if opt.palette then OF:tag("◆ " .. opt.palette) end
                if opt.dissolve then OF:tag("✦ " .. opt.dissolve) end
                -- 单项快捷键放在选项行上(同「（无）」);所在结构有轮换键时是「参与轮换」
                R.hotkey(ctx, OF, oid, card.is_base and { kind = "base", option = opt.name }
                    or { kind = "group", group = card.name, option = opt.name })
                local bx2 = oax
                for _, a in ipairs(oacts) do
                    local clicked, bw = W.tbutton(a[1], bx2, cy + 2, { kind = a.kind })
                    if clicked then
                        if a[2] == "delete" then st.confirming = oid end
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
                    -- 模型高度、调色方案、溶解预设、形态键属于新版特性:关闭时灰掉、不可改
                    TF:text(t("heightLabel"), nf_off and C.faint or C.muted)
                    local hx2, hy2 = TF:place(64, ROW)
                    W.num_box(st.drafts, "h:" .. oid, hx2, hy2 + 1, 64, opt.height,
                        { min = HEIGHT_MIN, max = HEIGHT_MAX, allow_empty = true, placeholder = t("heightUnset"), tip = t("heightHint"),
                          disabled = nf_off },
                        function(n)
                            local cm = n and math.floor(n * 10 + 0.5) / 10 or nil
                            if card.is_base then ctx.act({ kind = "base-height", preset = opt.name, cm = cm })
                            else ctx.act({ kind = "option-height", group = card.name, option = opt.name, cm = cm }) end
                        end)
                    TF:text("cm", C.muted)
                    if opt.height ~= nil and TF:button(t("heightClear"), { kind = "ghost", disabled = nf_off }) then
                        if card.is_base then ctx.act({ kind = "base-height", preset = opt.name })
                        else ctx.act({ kind = "option-height", group = card.name, option = opt.name }) end
                    end
                    local layer = card.is_base and "base" or card.name
                    R.ref_select(ctx, TF, "pal:" .. oid, t("paletteRef"), R.scheme_names(snap), opt.palette,
                        t("paletteRefNone"), t("paletteRefBroken"),
                        function(v) ctx.act({ kind = "palette-ref", layer = layer, option = opt.name, scheme = v }) end,
                        { disabled = nf_off, tip = (not card.is_base) and t("paletteRefOptionHint") or nil })
                    R.ref_select(ctx, TF, "dis:" .. oid, t("dissolveRef"), R.dissolve_names(snap), opt.dissolve,
                        t("dissolveRefNone"), t("dissolveRefBroken"),
                        function(v) ctx.act({ kind = "dissolve-ref", layer = layer, option = opt.name, preset = v }) end,
                        { disabled = nf_off })
                    cy = cy + TF:height() + 6
                    cy = cy + R.sks_box(ctx, st, oid, mx0, cy, mw, opt.sks, function(group, value)
                        ctx.act({ kind = "sks-ref", layer = layer, option = opt.name, group = group, value = value })
                    end)
                    local secs = sections(d, t, card, opt.values or {})
                    if #secs == 0 then
                        D.text_mid(t("noMaterials"), mx0, cy, 22, C.muted, W.small(), mw)
                        cy = cy + 26
                    end
                    local labels = { on = t("on"), off = t("off") }
                    local tri_w = card.is_base and 70 or 100
                    -- 三列排列(备注模式一行要放输入框和定位按钮,只排一列);列宽放不下就减列
                    local gap = 16
                    local cols = st.notes and 1 or 3
                    while cols > 1 and (mw - gap * (cols - 1)) / cols < tri_w + 90 do cols = cols - 1 end
                    local col_w = (mw - gap * (cols - 1)) / cols
                    for _, sec in ipairs(secs) do
                        D.text_mid(sec.label, mx0, cy, 22, sec.id == "" and C.error or C.muted, W.bold())
                        cy = cy + 22
                        for i, key in ipairs(sec.keys) do
                            local col = (i - 1) % cols
                            local rx = mx0 + col * (col_w + gap)
                            if W.visible(cy, ROW) then
                                local slot, mat = U.split_key(key)
                                local val = value_of(opt.values or {}, key)
                                local nv = W.tri(rx, cy + 2, val, labels, card.is_base, false)
                                if nv and nv ~= val then
                                    if card.is_base then
                                        ctx.act({ kind = "base-material", preset = opt.name, slot = slot, material = mat, value = nv == "on" })
                                    else
                                        ctx.act({ kind = "option-material", group = card.name, option = opt.name, slot = slot, material = mat, value = nv })
                                    end
                                end
                                local nx = rx + tri_w + 8
                                local right = rx + col_w
                                local ovr = overriders(d, card, opt.values or {}, key)
                                local warn_w = #ovr > 0 and 16 or 0
                                local name_col = val == "on" and C.text or (val == "off" and C.muted or C.faint)
                                local name_w = st.notes and 200 or max(20, right - nx - warn_w)
                                local nw = D.text_mid(sec.id == "" and key or mat, nx, cy, ROW, name_col, W.small(), name_w)
                                -- 提示:全名 + 备注 + 也写了它的其他组
                                local tip = { mat }
                                if d.notes[key] then tip[#tip + 1] = d.notes[key] end
                                local others = card.is_base and {} or others_of(d, key, card.name)
                                if #others > 0 then tip[#tip + 1] = t("alsoIn", table.concat(others, "、")) end
                                W.tooltip(table.concat(tip, "\n"), nx, cy, nw, ROW)
                                nx = nx + (st.notes and max(nw, 120) or nw) + 8
                                if st.notes then
                                    W.commit_box(st.drafts, "note:" .. key, nx, cy + 2, 160, 22, d.notes[key] or "", t("notePlaceholder"), function(text)
                                        ctx.act({ kind = "note", slot = slot, material = mat, text = text })
                                    end)
                                    nx = nx + 168
                                    local c4, lw = W.tbutton(t("locate"), nx, cy + 2)
                                    if c4 then ctx.act({ kind = "locate", slot = slot, material = mat }) end
                                    nx = nx + lw + 8
                                elseif d.notes[key] and right - warn_w - nx > 24 then
                                    nx = nx + D.text_mid(d.notes[key], nx, cy, ROW, C.muted, W.small(), right - warn_w - nx) + 6
                                end
                                if #ovr > 0 then
                                    local wx = st.notes and nx or (right - warn_w)
                                    D.text_mid("!", wx + 4, cy, ROW, C.error, W.bold())
                                    W.tooltip(t("mayBeOverridden", table.concat(ovr, "、")) .. "\n" .. t("overlapHint"), wx, cy, 16, ROW)
                                end
                            end
                            if col == cols - 1 or i == #sec.keys then cy = cy + ROW end
                        end
                        cy = cy + 4
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
            open["g:" .. name] = true
        end
        cy = cy + 36
    end
    return cy - y
end

return Page
