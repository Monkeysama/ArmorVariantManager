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
    F:text(p.source and p.source.name or t("noSource"), p.source and C.text or C.muted, W.body())
    if p.current then F:tag(t(FIT[p.current]), FIT_COLOR[p.current]) end
    if p.source and p.dirty then F:tag(t("unsavedTag"), C.warn) end
    cy = cy + F:height() + 6
    local bx = x
    if p.source and p.source.own then
        local c2, bw2 = W.button(t("savePreset"), bx, cy, nil, 26, { kind = "primary", font = W.small() })
        if c2 then
            if p.current == "full" then ctx.act({ kind = "preset-update" }) else st.saving_to, st.applying, st.deleting = "@current", nil, nil end
        end
        bx = bx + bw2 + 8
    end
    W.text_box("preset_new", bx, cy, 220, 26, st.new_name or "", t("newPresetName"), function(v) st.new_name = v end)
    local name = (st.new_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    bx = bx + 228
    local clicked, bw = W.button(t("saveAsPreset"), bx, cy, nil, 26, { font = W.small(), disabled = name == "" })
    if clicked and ctx.act({ kind = "preset-save", name = name }) then st.new_name = "" end
    bx = bx + bw + 8
    -- 新建空白配置:二次确认,默认同时抓取当前外观作为整套造型
    if W.button(t("newBlank"), bx, cy, nil, 26, { font = W.small() }) then st.blanking = not st.blanking end
    cy = cy + 34
    -- 保存至预设 = 用当前配置完全替换预设内容;完全适用的直接存,其他的先确认
    if st.saving_to == "@current" and p.source then
        local r, ch = W.confirm(x + 16, cy, w - 20, t("saveToWarn", p.source.name), t("confirmSave"), t("cancel"), "primary")
        if r then st.saving_to = nil end
        if r == "yes" then ctx.act({ kind = "preset-update" }) end
        cy = cy + ch
    end
    if st.blanking then
        if st.blank_capture == nil then st.blank_capture = true end
        local changed, v = W.checkbox(t("blankCapture"), x + 16, cy, st.blank_capture)
        if changed then st.blank_capture = v end
        cy = cy + 30
        local r, ch = W.confirm(x + 16, cy, w - 20, t("blankWarn"), t("confirmBlank"), t("cancel"), "primary")
        if r then st.blanking = nil end
        if r == "yes" then ctx.act({ kind = "preset-blank", capture = st.blank_capture }) end
        cy = cy + ch
    end
    cy = cy + 6

    -- 预设库
    W.h2(t("library"), x, cy)
    cy = cy + 28
    -- 分两类:模组自带(只能加载)和自定义;每类里不适用的收进折叠栏。没有模组自带的预设时不显示那一类
    local any_usable = false
    for _, e in ipairs(p.list) do if e.match ~= "none" then any_usable = true end end
    if not any_usable then
        D.text_mid(t("noUsable"), x + 4, cy, 22, C.muted, W.small())
        cy = cy + 26
    end
    local function row(e)
        W.separator(x, cy, w)
        cy = cy + 4
        local RF = W.flow(x + 4, cy, w - 8, 8, 28)
        -- 自定义预设的名字就是输入框(同状态组选项),离开即改名
        if e.source == "user" then
            local rx, ry = RF:place(180, 28)
            W.commit_box(st.drafts, "pname:" .. e.id, rx, ry + 1, 180, 26, e.name, t("rename"), function(name)
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if name ~= "" and name ~= e.name then ctx.act({ kind = "preset-rename", id = e.id, name = name }) end
            end)
        else
            RF:text(e.name, C.text, W.body())
        end
        if p.source and p.source.id == e.id then RF:text("（" .. t("isSource") .. "）") end
        RF:tag(t(FIT[e.match]), FIT_COLOR[e.match])
        if RF:button(t("apply"), { disabled = e.match == "none" }) then st.applying, st.deleting, st.saving_to = e.id, nil, nil end
        if e.source == "user" then
            if not (p.source and p.source.id == e.id) and RF:button(t("saveTo")) then
                if e.match == "full" then ctx.act({ kind = "preset-update", id = e.id })
                else st.saving_to, st.applying, st.deleting = e.id, nil, nil end
            end
            if RF:button(t("delete"), { kind = "danger" }) then st.deleting, st.applying, st.saving_to = e.id, nil, nil end
        end
        cy = cy + RF:height() + 4
        if st.applying == e.id then
            local r, ch = W.confirm(x + 16, cy, w - 20, t((not p.dirty) and "applyWarn" or (p.source and "applyDirty" or "applyUnsaved"), e.name) .. (e.match == "partial" and (" " .. t("applyPartial")) or ""),
                t("confirmApply"), t("cancel"), "primary")
            if r then st.applying = nil end
            if r == "yes" then ctx.act({ kind = "preset-apply", id = e.id }) end
            cy = cy + ch
        end
        if st.saving_to == e.id then
            local r, ch = W.confirm(x + 16, cy, w - 20, t("saveToWarn", e.name), t("confirmSave"), t("cancel"), "primary")
            if r then st.saving_to = nil end
            if r == "yes" then ctx.act({ kind = "preset-update", id = e.id }) end
            cy = cy + ch
        end
        if st.deleting == e.id then
            local r, ch = W.confirm(x + 16, cy, w - 20, t("delete") .. "「" .. e.name .. "」？", t("confirmDelete"), t("cancel"), "danger", C.error)
            if r then st.deleting = nil end
            if r == "yes" then ctx.act({ kind = "preset-delete", id = e.id }) end
            cy = cy + ch
        end
    end
    st.unusable_open = type(st.unusable_open) == "table" and st.unusable_open or {}
    st.cat_closed = st.cat_closed or {}
    for _, key in ipairs({ "mod", "user" }) do
        local usable, unusable = {}, {}
        for _, e in ipairs(p.list) do
            if e.source == key then
                if e.match == "none" then unusable[#unusable + 1] = e else usable[#usable + 1] = e end
            end
        end
        if key == "user" or #usable + #unusable > 0 then
            -- 每类可折叠,默认展开(cat_closed 记的是收起的类)
            local c1, h1 = W.header(t(key == "mod" and "catMod" or "catUser") .. "（" .. (#usable + #unusable) .. "）", x, cy, w,
                not st.cat_closed[key])
            if c1 then st.cat_closed[key] = not st.cat_closed[key] end
            cy = cy + h1 + 4
        end
        if (key == "user" or #usable + #unusable > 0) and not st.cat_closed[key] then
            if key == "user" and #usable + #unusable == 0 then
                D.text_mid(t("noCustom"), x + 4, cy, 22, C.muted, W.small())
                cy = cy + 26
            end
            for _, e in ipairs(usable) do row(e) end
            if #unusable > 0 then
                cy = cy + 4
                local c2, hh = W.header(t("unusable", #unusable), x, cy, w, st.unusable_open[key])
                if c2 then st.unusable_open[key] = not st.unusable_open[key] end
                cy = cy + hh + 4
                if st.unusable_open[key] then for _, e in ipairs(unusable) do row(e) end end
            end
            cy = cy + 10
        end
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
