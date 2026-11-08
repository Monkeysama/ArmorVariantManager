-- 杂项页(对应 web/src/re4/Re4Misc.vue,溶解相关的在 PageDissolve):旧配置迁移(只有检测到旧配置时按钮才能点)、设置、帮助(默认收起)。
-- 全身预览的镜头设置不放:独立面板没有预览。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")

local C = T.c
local Page = {}

function Page.draw(ctx, x, y, w)
    local snap, t, st = ctx.snap, ctx.t, ctx.state
    st.drafts = st.drafts or {}
    local cy = y

    -- 迁移
    W.h2(t("migrateTitle"), x, cy)
    cy = cy + 26
    cy = cy + W.note(t("migrateLead"), x, cy, w) + 4
    local old = snap.configVersion == 2
    local clicked, bw = W.button(t("migrateButton"), x, cy, nil, 26,
        { kind = "primary", font = W.small(), disabled = not old or snap.character == "" })
    if clicked then st.confirm_migrate = true end
    D.text_mid(old and t("detectedOld") or t("alreadyNew"), x + bw + 10, cy, 26, C.muted, W.small())
    cy = cy + 32
    if st.confirm_migrate and old then
        local r, h = W.confirm(x, cy, w, t("migrateLead"), t("migrateButton"), t("cancel"), "primary")
        if r then st.confirm_migrate = nil end
        if r == "yes" then ctx.act({ kind = "migrate" }) end
        cy = cy + h
    end
    cy = cy + 12

    -- 设置
    W.h2(t("settings"), x, cy)
    cy = cy + 28
    local function setting_row(label, value, hint, on_change)
        local changed, v, tw = W.toggle(label, x, cy, value)
        if changed then on_change(v) end
        local used = 30
        if hint then
            local nh = W.note(hint, x + tw + 12, cy + 5, w - tw - 12)
            used = math.max(used, nh + 10)
        end
        cy = cy + used + 2
    end
    local s = snap.settings
    if snap.configVersion == 3 then
        setting_row(t("armorMirror"), snap.armorMirror == true, t("armorMirrorHint"),
            function(v) ctx.act({ kind = "armor-mirror", enabled = v }) end)
    end
    setting_row(t("blockGameMouse"), s.blockGameMouse ~= false, t("blockGameMouseHint"),
        function(v) ctx.act({ kind = "setting", id = "block_game_mouse", value = v }) end)
    setting_row(t("heightEnabled"), s.heightEnabled ~= false, t("heightEnabledHint"),
        function(v) ctx.act({ kind = "setting", id = "height_enabled", value = v }) end)
    setting_row(t("weaponHide"), s.weaponHideStorage == true, nil,
        function(v) ctx.act({ kind = "setting", id = "weapon_hide_storage", value = v }) end)
    -- 溶解相关的设置在「溶解」页(PageDissolve.lua)
    -- 打开 / 关闭独立面板的快捷键(主键 + 可选修饰键)
    local g = ctx.global_config or {}
    local hx = x + D.text_mid(t("hotkeyLabel"), x, cy, 28, C.text, W.body()) + 12
    local keys = ctx.hotkeys or { "F8" }
    local cur = 1
    for i, k in ipairs(keys) do if k == (g.panel_hotkey or "F8") then cur = i end end
    local c1, i1 = W.select("misc_hotkey", hx, cy + 2, 80, 24, keys, cur)
    if c1 and keys[i1] then ctx.act({ kind = "setting", id = "panel_hotkey", value = keys[i1] }) end
    hx = hx + 92
    hx = hx + D.text_mid(t("hotkeyMod"), hx, cy, 28, C.muted, W.small()) + 8
    local mods = { "", "Ctrl", "Shift", "Alt" }
    local mod_labels = { t("hotkeyNone"), "Ctrl", "Shift", "Alt" }
    local mcur = 1
    for i, m in ipairs(mods) do if m == (g.panel_hotkey_mod or "") then mcur = i end end
    local c2, i2 = W.select("misc_hotkey_mod", hx, cy + 2, 90, 24, mod_labels, mcur)
    if c2 and mods[i2] then ctx.act({ kind = "setting", id = "panel_hotkey_mod", value = mods[i2] }) end
    hx = hx + 102
    cy = cy + math.max(30, W.note(t("hotkeyHint"), hx, cy + 5, w - (hx - x)) + 10) + 10

    -- 帮助
    local c2, hh = W.header(t("help"), x, cy, w, st.help_open)
    if c2 then st.help_open = not st.help_open end
    cy = cy + hh + 6
    if st.help_open then
        local docs = ctx.documentation()
        if #(docs.sections or {}) == 0 then
            D.text_mid(t("noHelp"), x, cy, 22, C.muted, W.small())
            cy = cy + 26
        end
        for _, section in ipairs(docs.sections or {}) do
            W.h2(section.title, x, cy)
            cy = cy + 26
            for _, entry in ipairs(section.entries) do
                D.text(entry.title, x + 4, cy, C.brass, W.bold())
                cy = cy + 22
                for _, para in ipairs(entry.paragraphs) do
                    if W.visible(cy, 400) then
                        cy = cy + D.paragraph(para, x + 4, cy, w - 8, C.text, W.small(), 18) + 6
                    else
                        cy = cy + #D.wrap(W.small(), para, w - 8) * 18 + 6
                    end
                end
            end
            cy = cy + 8
        end
    end
    return cy - y + 8
end

return Page
