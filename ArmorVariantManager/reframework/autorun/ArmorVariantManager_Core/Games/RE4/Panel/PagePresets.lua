-- 预设页(对应 web/src/re4/Re4Presets.vue)。当前配置是唯一生效的那份,预设只是套用的来源;
-- 套用前当前配置进自动保存。模型变了时只提醒有没有更合适的预设,从不自动切换。可折叠的栏默认收起。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")

local C = T.c
local Page = {}

local FIT = { full = "fitFull", partial = "fitPartial", none = "fitNone" }
local FIT_COLOR = { full = C.ok, partial = C.warn }

local function time_text(s)
    if type(s) ~= "number" or s <= 0 then return "" end
    return os.date("%Y-%m-%d %H:%M", math.floor(s))
end

function Page.draw(ctx, x, y, w)
    local snap, t, st = ctx.snap, ctx.t, ctx.state
    local p = snap.presets
    st.drafts = st.drafts or {}
    local cy = y

    -- 更合适的预设提醒
    if p.current ~= "full" and #p.better > 0 and not p.dismissed then
        local names = {}
        for _, b in ipairs(p.better) do names[#names + 1] = "「" .. b.name .. "」" end
        local text = t("betterHint", #p.better, table.concat(names))
        local lines = D.wrap(W.small(), text, w - 130)
        local bh = math.max(40, #lines * 18 + 16)
        W.panel_box(x, cy, w, bh, C.signal)
        for i, l in ipairs(lines) do D.text(l, x + 12, cy + 9 + (i - 1) * 18, C.text, W.small()) end
        if W.button(t("notNow"), x + w - 100, cy + (bh - 26) / 2, 88, 26, { font = W.small() }) then
            ctx.act({ kind = "preset-dismiss" })
        end
        cy = cy + bh + 10
    end

    -- 当前配置
    W.h2(t("current"), x, cy)
    cy = cy + 26
    local F = W.flow(x, cy, w, 8, 26)
    F:text(p.source and t("fromPreset", p.source.name) or t("noSource"), C.text, W.body())
    if p.current then F:tag(t(FIT[p.current]), FIT_COLOR[p.current]) end
    cy = cy + F:height() + 6
    W.text_box("preset_new", x, cy, 220, 26, st.new_name or "", t("newPresetName"), function(v) st.new_name = v end)
    local name = (st.new_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local bx = x + 228
    local clicked, bw = W.button(t("saveAsPreset"), bx, cy, nil, 26, { kind = "primary", font = W.small(), disabled = name == "" })
    if clicked and ctx.act({ kind = "preset-save", name = name }) then st.new_name = "" end
    bx = bx + bw + 8
    if p.source and p.source.own then
        if W.button(t("saveBack", p.source.name), bx, cy, nil, 26, { font = W.small() }) then ctx.act({ kind = "preset-update" }) end
    end
    cy = cy + 40

    -- 预设库
    W.h2(t("library"), x, cy)
    cy = cy + 28
    local usable, unusable = {}, {}
    for _, e in ipairs(p.list) do
        if e.match == "none" then unusable[#unusable + 1] = e else usable[#usable + 1] = e end
    end
    if #usable == 0 then
        D.text_mid(t("noUsable"), x + 4, cy, 22, C.muted, W.small())
        cy = cy + 26
    end
    local function row(e)
        W.separator(x, cy, w)
        cy = cy + 4
        local RF = W.flow(x + 4, cy, w - 8, 8, 28)
        if st.renaming == e.id then
            local rx, ry = RF:place(200, 28)
            W.text_box("preset_rename", rx, ry + 1, 200, 26, st.rename_text or "", "", function(v) st.rename_text = v end)
            if RF:button(t("done"), { kind = "primary" }) then
                local nm = (st.rename_text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                st.renaming = nil
                if nm ~= "" and nm ~= e.name then ctx.act({ kind = "preset-rename", id = e.id, name = nm }) end
            end
            if RF:button(t("cancel")) then st.renaming = nil end
        else
            RF:text(e.name .. ((p.source and p.source.id == e.id) and ("（" .. t("isSource") .. "）") or ""), C.text, W.body())
        end
        RF:tag(e.source == "mod" and t("srcMod") or t("srcUser"))
        RF:tag(t(FIT[e.match]), FIT_COLOR[e.match])
        if RF:button(t("apply"), { disabled = e.match == "none" }) then st.applying, st.deleting = e.id, nil end
        if e.source == "user" and st.renaming ~= e.id then
            if RF:button(t("rename")) then st.renaming, st.rename_text = e.id, e.name end
            if RF:button(t("delete"), { kind = "danger" }) then st.deleting, st.applying = e.id, nil end
        end
        cy = cy + RF:height() + 4
        if st.applying == e.id then
            local r, ch = W.confirm(x + 16, cy, w - 20, t("applyWarn", e.name) .. (e.match == "partial" and (" " .. t("applyPartial")) or ""),
                t("confirmApply"), t("cancel"), "primary")
            if r then st.applying = nil end
            if r == "yes" then ctx.act({ kind = "preset-apply", id = e.id }) end
            cy = cy + ch
        end
        if st.deleting == e.id then
            local r, ch = W.confirm(x + 16, cy, w - 20, t("delete") .. "「" .. e.name .. "」？", t("confirmDelete"), t("cancel"), "danger", C.error)
            if r then st.deleting = nil end
            if r == "yes" then ctx.act({ kind = "preset-delete", id = e.id }) end
            cy = cy + ch
        end
    end
    for _, e in ipairs(usable) do row(e) end
    if #unusable > 0 then
        cy = cy + 4
        local c2, hh = W.header(t("unusable", #unusable), x, cy, w, st.unusable_open)
        if c2 then st.unusable_open = not st.unusable_open end
        cy = cy + hh + 4
        if st.unusable_open then for _, e in ipairs(unusable) do row(e) end end
    end
    cy = cy + 12

    -- 自动保存
    local c3, hh3 = W.header(t("autosaves", #p.autosaves), x, cy, w, st.autosave_open)
    W.tooltip(t("autosaveHint"), x, cy, w, hh3)
    if c3 then st.autosave_open = not st.autosave_open end
    cy = cy + hh3 + 4
    if st.autosave_open then
        if #p.autosaves == 0 then
            D.text_mid(t("noAutosaves"), x + 4, cy, 22, C.muted, W.small())
            cy = cy + 26
        end
        for k, a in ipairs(p.autosaves) do
            local RF = W.flow(x + 4, cy, w - 8, 8, 28)
            RF:text(a.name, C.text, W.body())
            RF:text(time_text(a.time))
            if RF:button(t("restore")) then ctx.act({ kind = "autosave-restore", index = k }) end
            if RF:button(t("promote")) then ctx.act({ kind = "autosave-promote", index = k, name = a.name }) end
            cy = cy + RF:height() + 4
        end
    end
    cy = cy + 8

    -- 还原点
    local c4, hh4 = W.header(t("restorePoints"), x, cy, w, st.restore_open)
    if c4 then st.restore_open = not st.restore_open end
    cy = cy + hh4 + 4
    if st.restore_open then
        local RF = W.flow(x + 4, cy, w - 8, 8, 28)
        local b = snap.backups or {}
        if RF:button(t("restoreBackup"), { disabled = not b.hasBackup }) then ctx.act({ kind = "restore", which = "backup" }) end
        if RF:button(t("restoreOnload"), { disabled = not b.hasOnload }) then ctx.act({ kind = "restore", which = "onload" }) end
        cy = cy + RF:height() + 4
    end
    return cy - y + 8
end

return Page
