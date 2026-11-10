-- REF 原生菜单(ImGui)里的 v3 面板:只管日常使用,完整编辑在 REFF 页面。
--   * 整套造型 / 各状态组的手动选择(被条件状态接管的层只显示,不给改)
--   * 条件切换总开关、各条件状态的启用勾选与当前结果(颜色 + 文字)
--   * 预设:当前配置的匹配程度与来源、更合适的预设提醒、套用(两步确认)、存为新预设、自动保存恢复
-- 放在单独的模块里,是因为 Main.start 的局部变量已经接近 Lua 的 200 个上限。
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")

local ImGuiV3 = {}

-- 0xAABBGGRR
local GREEN, RED, GREY = 0xFF6CC45C, 0xFF4848E0, 0xFF9A9A9A
local KIND = {
    active = { "v3_kind_active", GREEN }, partial = { "v3_kind_partial", GREEN },
    outranked = { "v3_kind_outranked", RED }, idle = { "v3_kind_idle", GREY },
    off = { "v3_kind_off", GREY }, paused = { "v3_kind_paused", GREY },
}
local FIT = { full = "v3_fit_full", partial = "v3_fit_partial", none = "v3_fit_none" }

local function colored(text, color)
    if imgui.text_colored then imgui.text_colored(text, color) else imgui.text(text) end
end

-- d = { T, config, kind_id, target, context, source, TM, commit(changed, reapply), ui(持久表),
--       ui_tree(label), ui_tree_pop(), ui_w(), preset_view, apply_preset, save_current_as_preset,
--       dismiss_preset_hint, restore_autosave, panel_key(独立面板快捷键文字,不可用时 nil), reff(是否加载了 REFF) }
function ImGuiV3.draw(d)
    local T, cfg, ui = d.T, d.config, d.ui
    local states = cfg.conditions.states
    local _, _, info = d.TM.resolve("imgui:" .. tostring(d.target.id), cfg, d.context, d.source)
    local v3 = info.v3
    -- 两个入口都没有时(REFramework 太旧且没装 REFF)只说这里能做什么,不指向用不了的界面
    if d.panel_key and d.reff then
        imgui.text(string.format(T("v3_imgui_hint_both"), d.panel_key))
    elseif d.panel_key then
        imgui.text(string.format(T("v3_imgui_hint_panel"), d.panel_key))
    elseif d.reff then
        imgui.text(T("v3_imgui_hint_reff"))
    else
        imgui.text(T("v3_imgui_hint_none"))
    end

    local function state_name(i) return (states[i] or {}).name or "?" end
    local function layer_combo(label, key, layer, options, active, with_none, claimed)
        if claimed then
            colored(string.format("%s: %s  (%s)", label, tostring(v3.picks[key] or T("v3_none")),
                string.format(T("v3_taken_by"), state_name(claimed))), GREEN)
            return
        end
        local labels, cur = {}, 1
        if with_none then labels[1] = T("v3_none") end
        for _, n in ipairs(options) do
            labels[#labels + 1] = n
            if n == active then cur = #labels end
        end
        if #labels == 0 then imgui.text(label .. ": " .. T("v3_none")); return end
        d.ui_w()
        local ch, idx = imgui.combo(label .. "###v3l_" .. key, cur, labels)
        if ch and idx ~= cur then
            local opt = with_none and (idx == 1 and "" or options[idx - 1]) or options[idx]
            d.commit(OpsV3.set_manual(cfg, layer, opt or ""))
        end
    end

    layer_combo(T("base_layer"), "base", "base", cfg.base.order, cfg.base.active, false, (info.layers.base or {}).prio)
    for _, g in ipairs(cfg.groups) do
        if M3.is_multi(g) then
            -- 复选组:每个选项一个勾选框;被条件状态接管的选项只显示
            imgui.text(g.name)
            for _, opt in ipairs(g.order) do
                local okey = M3.option_key(g.name, opt)
                local by = (info.layers[okey] or {}).prio
                imgui.same_line()
                if by then
                    colored(string.format("[%s] %s (%s)", v3.picks[okey] and "x" or " ", opt,
                        string.format(T("v3_taken_by"), state_name(by))), GREEN)
                else
                    local ch, on = imgui.checkbox(opt .. "###v3m_" .. okey, M3.is_on(g, opt))
                    if ch then d.commit(OpsV3.set_option_on(cfg, g.name, opt, on)) end
                end
            end
        else
            local key = M3.layer_key(g.name)
            layer_combo(g.name, key, g.name, g.order, g.active, true, (info.layers[key] or {}).prio)
        end
    end

    -- 条件状态
    local ch_auto, auto = imgui.checkbox(T("v3_auto") .. "###v3_auto", cfg.conditions.auto)
    if ch_auto then d.commit(OpsV3.set_auto(cfg, auto)) end
    for i, st in ipairs(states) do
        local ch, on = imgui.checkbox("###v3_st_" .. i, st.enabled)
        if ch then d.commit(OpsV3.set_state_field(cfg, i, "enabled", on)) end
        imgui.same_line()
        local s = v3.status[i] or { kind = "idle" }
        local k = KIND[s.kind] or KIND.idle
        local text = st.name .. "  -  " .. T(k[1])
        if s.kind == "outranked" and s.by then text = text .. " (" .. string.format(T("v3_covered_by"), state_name(s.by)) .. ")" end
        colored(text, k[2])
    end

    -- 预设
    if d.ui_tree(T("v3_presets") .. "###v3_presets") then
        local view = d.preset_view(d.kind_id, d.source)
        local line = view.source and string.format(T("v3_from_preset"), view.source.name) or T("v3_no_source")
        if view.current then line = line .. "  [" .. T(FIT[view.current]) .. "]" end
        imgui.text(T("v3_current") .. ": " .. line)
        if #view.better > 0 and not view.dismissed then
            local names = {}
            for _, e in ipairs(view.better) do names[#names + 1] = e.name end
            colored(string.format(T("v3_better"), table.concat(names, ", ")), GREEN)
            if imgui.button(T("v3_dismiss") .. "###v3_dismiss") then d.dismiss_preset_hint(d.kind_id, d.source) end
        end
        for _, r in ipairs(view.presets) do
            local e = r.entry
            imgui.text(string.format("%s  [%s]", e.name, T(FIT[r.match])))
            if r.match ~= "none" then
                imgui.same_line()
                if ui.apply_pending == e.id then
                    if imgui.button(T("v3_confirm_apply") .. "###v3_ca_" .. e.id) then
                        ui.apply_pending = nil
                        d.apply_preset(d.kind_id, e.id)
                    end
                    imgui.same_line()
                    if imgui.button(T("cancel_btn") .. "###v3_cx_" .. e.id) then ui.apply_pending = nil end
                elseif imgui.button(T("v3_apply") .. "###v3_ap_" .. e.id) then
                    ui.apply_pending = e.id
                end
            end
        end
        d.ui_w()
        local ch_n, name = imgui.input_text(T("v3_preset_name") .. "###v3_pname", ui.preset_name or "")
        if ch_n then ui.preset_name = name end
        if imgui.button(T("v3_save_as") .. "###v3_save") and (ui.preset_name or "") ~= "" then
            if d.save_current_as_preset(d.kind_id, ui.preset_name) then ui.preset_name = "" end
        end
        for k, a in ipairs(view.autosaves) do
            imgui.text(T("v3_autosave") .. ": " .. a.name)
            imgui.same_line()
            if imgui.button(T("v3_restore") .. "###v3_as_" .. k) then d.restore_autosave(d.kind_id, k) end
        end
        d.ui_tree_pop()
    end
end

return ImGuiV3
