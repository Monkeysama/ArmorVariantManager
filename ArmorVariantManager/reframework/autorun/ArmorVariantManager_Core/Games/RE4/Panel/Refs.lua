-- 独立面板里几处共用的小件(对应网页的 Re4HotkeyPick.vue、hotkeys.ts 和各页的引用下拉):
--   快捷键(Alt + 数字)的单项键 / 轮换键 / 「参与轮换」开关,调色方案 / 溶解预设的引用下拉,
--   SKS 键组折叠栏,以及「新版特性」关闭时的判断(相关控件灰掉、不可改)。
-- 每个函数都在流式排版 F(Widgets.flow)里放东西,返回值见各函数。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
local U = require("ArmorVariantManager_Core.Games.RE4.Panel.Common")

local C = T.c
local R = {}

-- 新版特性关闭(见 Main.features_on):快捷键、调色、溶解、模型高度、SKS、条件状态的武器显示都不生效
function R.nf_off(snap) return snap and snap.settings and snap.settings.newFeatures == false or false end

-- ---------------------------------------------------------------- 快捷键
local DIGITS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 }
local function structure_of(t) return t.kind == "group" and ("group:" .. tostring(t.group)) or t.kind end
local function is_cycle(t) return t.option == nil and t.scheme == nil end
local function item_of(t) if t.kind == "palette" then return t.scheme end return t.option end
local function same_target(a, b)
    return structure_of(a) == structure_of(b) and is_cycle(a) == is_cycle(b) and item_of(a) == item_of(b)
end
local function key_of(snap, target)
    for _, h in ipairs(snap.hotkeys or {}) do if same_target(h, target) then return h end end
end
function R.cycle_of(snap, target)
    for _, h in ipairs(snap.hotkeys or {}) do
        if h.cycle and structure_of(h) == structure_of(target) then return h end
    end
end
local function describe(snap, h, t)
    local where = h.kind == "base" and t("tabBase") or (h.kind == "group" and t("hotkeyGroup", U.group_label(snap, h.group or "")) or t("hotkeyPalette"))
    if is_cycle(h) then return where .. " · " .. t("hotkeyCycle") end
    local item = item_of(h) or ""
    if item == "" then item = h.kind == "palette" and t("paletteAlways") or t("none")
    elseif h.kind == "base" then item = U.base_label(snap, item)
    elseif h.kind == "group" then item = U.option_label(snap, h.group, item) end
    return where .. " · " .. item
end
local function digit_label(snap, d, self, t)
    for _, h in ipairs(snap.hotkeys or {}) do
        if h.digit == d and not same_target(h, self) then return t("hotkeyUsedBy", "Alt+" .. d, describe(snap, h, t)) end
    end
    return "Alt+" .. d
end

-- 一处快捷键设置。target 没有 option / scheme = 整个结构的轮换键;单项所在的结构绑了轮换键时
-- 换成「参与轮换」勾选框。label 省略时为「快捷键」
function R.hotkey(ctx, F, id, target, label)
    local snap, t = ctx.snap, ctx.t
    local disabled = R.nf_off(snap)
    local cycle = (not is_cycle(target)) and R.cycle_of(snap, target) or nil
    if cycle then
        local item = item_of(target) or ""
        local included = true
        for _, s in ipairs(cycle.skip or {}) do if s == item then included = false end end
        local ch, v = F:checkbox(t("hotkeyInclude"), included, { disabled = disabled, tip = t("hotkeyIncludeHint", "Alt+" .. cycle.digit) })
        if ch then
            ctx.act({ kind = "hotkey-skip", structure = { kind = target.kind, group = target.group }, item = item, included = v })
        end
        return
    end
    F:text(label or t("hotkeyRef"), disabled and C.faint or C.muted)
    local own = key_of(snap, target)
    local labels, index = { t("hotkeyNone") }, 1
    for i, d in ipairs(DIGITS) do
        labels[i + 1] = digit_label(snap, d, target, t)
        if own and own.digit == d then index = i + 1 end
    end
    local sx, sy = F:place(150, 26)
    local changed, picked = W.select("hk:" .. id, sx, sy + 1, 150, 24, labels, index,
        { disabled = disabled, popup_w = 300, tip = is_cycle(target) and t("hotkeyCycleHint") or t("hotkeyHint") })
    if changed and picked ~= index then
        if picked == 1 then
            if own then ctx.act({ kind = "hotkey-clear", digit = own.digit }) end
        else
            ctx.act({ kind = "hotkey-set", digit = DIGITS[picked - 1], target = target })
        end
    end
end

-- ---------------------------------------------------------------- 引用下拉
-- names:可选的名字;current:当前引用(nil / "" = 不引用);none_label:「—」之类;broken_label:引用的名字不存在时
-- 的说明。on_pick(name)("" = 取消引用)。返回 nothing
function R.ref_select(ctx, F, id, label, names, current, none_label, broken_label, on_pick, opt)
    opt = opt or {}
    local disabled = opt.disabled
    F:text(label, disabled and C.faint or C.muted)
    local labels, values, index = { none_label }, { "" }, 1
    for _, n in ipairs(names) do
        labels[#labels + 1] = n; values[#values + 1] = n
        if n == current then index = #labels end
    end
    if current and current ~= "" and index == 1 then
        labels[#labels + 1] = (broken_label or "") .. "：" .. current
        values[#values + 1] = current
        index = #labels
    end
    local w = opt.w or 130
    local sx, sy = F:place(w, 26)
    local changed, picked = W.select("ref:" .. id, sx, sy + 1, w, 24, labels, index,
        { disabled = disabled, popup_w = math.max(w, 200), tip = opt.tip })
    if changed and picked ~= index and values[picked] ~= nil then on_pick(values[picked]) end
end

function R.scheme_names(snap)
    local out = {}
    for _, s in ipairs((snap.palettes and snap.palettes.list) or {}) do out[#out + 1] = s.name end
    return out
end
function R.dissolve_names(snap)
    local out = {}
    local p = snap.settings and snap.settings.dissolvePresets
    for _, s in ipairs((p and p.list) or {}) do out[#out + 1] = s.name end
    return out
end

-- ---------------------------------------------------------------- SKS 键组折叠栏(同网页 Re4Layers 的「形态键（SKS）」)
-- refs:这一项的 { 键组 -> 选项 | 0 };on_set(group, value)(value = 选项名 / 0 / "")。
-- st:页面状态(折叠、显示全部按 id 记)。返回用掉的高度;SKS 不驱动这个角色时返回 0
function R.sks_box(ctx, st, id, x, y, w, refs, on_set)
    local snap, t = ctx.snap, ctx.t
    local sks = snap.sks
    if not (sks and sks.actor) then return 0 end
    refs = type(refs) == "table" and refs or {}
    local disabled = R.nf_off(snap)
    st.sks_closed = st.sks_closed or {}
    st.sks_all = st.sks_all or {}
    local all = st.sks_all[id] == true
    local known = type(sks.groups) == "table" and sks.groups or {}
    local function rows(show_all)
        local out, seen = {}, {}
        for _, g in ipairs(known) do
            if show_all or g.inCurrent or refs[g.name] ~= nil then
                out[#out + 1] = { name = g.name, options = type(g.options) == "table" and g.options or {}, inCurrent = g.inCurrent }
                seen[g.name] = true
            end
        end
        for name in pairs(refs) do
            if not seen[name] then out[#out + 1] = { name = name, options = {}, inCurrent = false } end
        end
        return out
    end
    local list, full = rows(all), rows(true)
    if #full == 0 then return 0 end
    local hidden = #full - #rows(false)
    local set_count = 0
    for _ in pairs(refs) do set_count = set_count + 1 end

    local cy = y
    local closed = st.sks_closed[id] == true
    if W.caret(x, cy, not closed, 26) then st.sks_closed[id] = (not closed) or nil end
    local HF = W.flow(x + 20, cy, w - 20, 8, 26)
    HF:text(t("sksRef"), disabled and C.faint or C.muted)
    if set_count > 0 then HF:text(t("sksSetCount", set_count), C.faint) end
    if not closed and (hidden > 0 or all) then
        if HF:button(all and t("sksShowCurrent") or t("sksShowAll", hidden), { kind = "ghost", disabled = disabled }) then
            st.sks_all[id] = (not all) or nil
        end
    end
    cy = cy + HF:height() + 4
    if closed then return cy - y end

    local F = W.flow(x + 20, cy, w - 20, 10, 26)
    if #list == 0 then F:text(t("sksNoCurrent")) end
    local errors = type(sks.errors) == "table" and sks.errors or {}
    for _, row in ipairs(list) do
        local cur = refs[row.name]
        local err = cur ~= nil and errors[row.name] or nil
        local label = row.name .. (row.inCurrent and "" or " *")
        F:text(label, disabled and C.faint or (err and C.error or C.muted))
        local labels, values, index = { t("sksUnset"), t("sksNoneOption") }, { "", 0 }, 1
        if cur == 0 then index = 2 end
        for _, o in ipairs(row.options) do
            labels[#labels + 1] = o; values[#values + 1] = o
            if o == cur then index = #labels end
        end
        if type(cur) == "string" and index == 1 then
            labels[#labels + 1] = t("sksMissingOption") .. "：" .. cur; values[#values + 1] = cur; index = #labels
        end
        local tip = err and t("sksError", err) or ((not row.inCurrent) and t("sksNotInCurrent") or t("sksHint"))
        local sx, sy = F:place(120, 26)
        local changed, picked = W.select("sks:" .. id .. "|" .. row.name, sx, sy + 1, 120, 24, labels, index,
            { disabled = disabled, popup_w = 200, tip = tip })
        if changed and picked ~= index then on_set(row.name, values[picked]) end
    end
    cy = cy + F:height() + 4
    return cy - y
end

return R
