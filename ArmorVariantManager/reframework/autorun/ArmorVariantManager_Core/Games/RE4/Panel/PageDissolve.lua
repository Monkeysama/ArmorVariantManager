-- 溶解页(对应 web/src/re4/Re4Dissolve.vue):手动切换时的过渡、溶解预设库(默认预设、编辑 / 新建 / 改名 / 删除、
-- 形状与光边)、其他 mod 的效果。全是全局设置,不需要当前角色。光边颜色在这里用 R / G / B 三个数值框(不做取色器)。
-- 条件状态 / 整套造型 / 状态组里引用溶解预设只在 REFF 页面里做(同调色方案,独立面板不做引用)。
local T = require("ArmorVariantManager_Core.Games.RE4.Panel.Theme")
local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")
local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")

local C = T.c
local Page = {}

local function fmt(v)
    if type(v) ~= "number" then return "" end
    return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", ""))
end

local BUILTIN = "avm.builtin"
-- 提供者没给显示名时的中文兜底:社区测试包里那个提供者的效果 ID(同网页)
local KNOWN_ZH = { original = "原版紫焰", square = "方块紫焰", hex = "六边形紫焰", height_down = "上下高度扫描",
    violet_cosmos = "紫宙能量", rainbow_radiance = "虹彩辉光", stellar_nebula = "星云流光" }
local EDGE_TEXT = { color = { "edgeColor", "edgeColorHint" }, width = { "edgeWidth", "edgeWidthHint" },
    intensity = { "edgeIntensity", "edgeIntensityHint" }, border = { "edgeBorder", "edgeBorderHint" },
    noise_weight = { "edgeNoiseWeight", "edgeNoiseWeightHint" }, cell_size = { "edgeCellSize", "edgeCellSizeHint" },
    flow = { "edgeFlow", "edgeFlowHint" } }

function Page.draw(ctx, x, y, w)
    local snap, t, st = ctx.snap, ctx.t, ctx.state
    st.drafts = st.drafts or {}
    local s = snap.settings or {}
    local zh = snap.language ~= "en"
    local cy = y

    local function pick(label)
        if type(label) == "string" then return label end
        if type(label) ~= "table" then return nil end
        return zh and (label["zh-CN"] or label["en-US"]) or (label["en-US"] or label["zh-CN"])
    end
    local function label_row(text)
        return x + D.text_mid(text, x, cy, 28, C.text, W.body()) + 12
    end
    local function hint_after(ex, text)
        cy = cy + math.max(30, (text ~= "" and W.note(text, ex, cy + 5, w - (ex - x)) or 0) + 10) + 4
    end

    -- 过渡
    W.h2(t("dissolveTransition"), x, cy)
    cy = cy + 28
    local changed, v, tw = W.toggle(t("uiDissolve"), x, cy, s.uiDissolveEnabled ~= false)
    if changed then ctx.act({ kind = "setting", id = "ui_dissolve_enabled", value = v }) end
    local lx = x + tw + 16
    lx = lx + D.text_mid(t("uiDissolveTime"), lx, cy, 28, C.muted, W.small()) + 8
    W.num_box(st.drafts, "dis_time", lx, cy + 2, 70, s.uiDissolveTime, { min = 0, max = 30 }, function(n)
        ctx.act({ kind = "setting", id = "ui_dissolve_time", value = n })
    end)
    D.text_mid(t("seconds"), lx + 78, cy, 28, C.muted, W.small())
    cy = cy + 44

    -- 溶解预设库
    local lib = type(s.dissolvePresets) == "table" and s.dissolvePresets or nil
    if lib then
        local list = type(lib.list) == "table" and lib.list or {}
        local shapes = type(lib.shapes) == "table" and lib.shapes or {}
        local names = {}
        for _, p in ipairs(list) do names[#names + 1] = p.name end
        -- 正在编辑哪个:没选过 / 被删了 → 默认那个,默认是随机或空就第一个
        local current
        for _, p in ipairs(list) do if p.name == st.dis_edit then current = p end end
        if not current then
            for _, p in ipairs(list) do if p.name == lib.default then current = p end end
            current = current or list[1]
            st.dis_edit = current and current.name or nil
        end

        W.h2(t("dissolvePresets"), x, cy)
        cy = cy + 26
        cy = cy + W.note(t("dissolvePresetsLead"), x, cy, w) + 6

        -- 默认预设(含随机)
        local ex = label_row(t("dissolveDefault"))
        local dvals, dlabels, di = { "random" }, { t("dissolveDefaultRandom") }, 1
        for _, n in ipairs(names) do
            dvals[#dvals + 1] = n; dlabels[#dlabels + 1] = n
            if n == lib.default then di = #dvals end
        end
        if lib.default ~= "random" and di == 1 then di = nil end
        local ch, i = W.select("dis_default", ex, cy + 2, 180, 24, dlabels, di)
        if ch and dvals[i] then ctx.act({ kind = "dissolve-default", preset = dvals[i] }) end
        hint_after(ex + 192, t("dissolveDefaultHint"))

        -- 编辑哪个 + 新建 / 改名 / 删除
        ex = label_row(t("dissolvePresetEdit"))
        if #names > 0 then
            local ei = 1
            for k, n in ipairs(names) do if n == st.dis_edit then ei = k end end
            local ch2, i2 = W.select("dis_edit", ex, cy + 2, 180, 24, names, ei)
            if ch2 and names[i2] then st.dis_edit = names[i2]; st.dis_naming = nil end
            ex = ex + 192
        else
            ex = ex + D.text_mid(t("dissolveNone"), ex, cy, 28, C.muted, W.small()) + 12
        end
        local clicked, bw = W.button(t("dissolvePresetNew"), ex, cy + 1, nil, 26, { font = W.small() })
        if clicked then st.dis_naming = { mode = "new" } end
        ex = ex + bw + 6
        if current then
            local c2, bw2 = W.button(t("rename"), ex, cy + 1, nil, 26, { font = W.small() })
            if c2 then st.dis_naming = { mode = "rename" } end
            ex = ex + bw2 + 6
            local c3 = W.button(t("delete"), ex, cy + 1, nil, 26, { kind = "danger", font = W.small() })
            if c3 then
                local name = current.name
                ctx.confirm(t("dissolvePresetDelete"), t("dissolvePresetDeleteBody", name), function()
                    ctx.act({ kind = "dissolve-preset-delete", preset = name })
                end)
            end
        end
        cy = cy + 34

        -- 新建 / 改名:输入名字回车提交(新建时复制正在编辑的预设)
        if st.dis_naming then
            local mode = st.dis_naming.mode
            local nx = label_row(mode == "rename" and t("dissolvePresetRename") or t("dissolvePresetNew"))
            W.commit_box(st.drafts, "dis_name_" .. mode, nx, cy + 2, 200, 24, mode == "rename" and (current and current.name or "") or "",
                t("dissolvePresetName"), function(raw)
                    local name = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    if name == "" then return end
                    local ok
                    if mode == "rename" then
                        ok = current and ctx.act({ kind = "dissolve-preset-rename", preset = current.name, name = name })
                    else
                        ok = ctx.act({ kind = "dissolve-preset-new", name = name, from = current and current.name or nil })
                    end
                    if ok then st.dis_edit = name; st.dis_naming = nil end
                end)
            local cc = W.button(t("cancel"), nx + 210, cy + 1, nil, 26, { font = W.small() })
            if cc then st.dis_naming = nil end
            cy = cy + 34
        end
        cy = cy + 6

        if current then
            -- 形状
            W.h2(t("dissolveShape"), x, cy)
            cy = cy + 26
            cy = cy + W.note(t("dissolveShapeLead"), x, cy, w) + 6
            local sx = label_row(t("dissolveShape"))
            local svals, slabels, si = { "random" }, { t("effectRandom") }, 1
            for _, sh in ipairs(shapes) do
                svals[#svals + 1] = sh.id; slabels[#slabels + 1] = pick(sh.label) or sh.id
                if sh.id == current.shape then si = #svals end
            end
            local ch3, i3 = W.select("dis_shape", sx, cy + 2, 160, 24, slabels, si)
            if ch3 and svals[i3] then ctx.act({ kind = "dissolve-preset-shape", preset = current.name, shape = svals[i3] }) end
            cy = cy + 40

            -- 光边
            local edges = type(current.edge) == "table" and current.edge or {}
            W.h2(t("dissolveEdge"), x, cy)
            cy = cy + 26
            cy = cy + W.note(t("dissolveEdgeLead"), x, cy, w) + 6
            local label_w = 0
            for _, e in ipairs(edges) do
                local txt = EDGE_TEXT[e.key] and t(EDGE_TEXT[e.key][1]) or e.key
                label_w = math.max(label_w, W.toggle_w(txt))
            end
            local preset = current.name
            for _, e in ipairs(edges) do
                local txt = EDGE_TEXT[e.key] and t(EDGE_TEXT[e.key][1]) or e.key
                local hint = EDGE_TEXT[e.key] and t(EDGE_TEXT[e.key][2]) or ""
                local ch4, on = W.toggle(txt, x, cy, e.on == true)
                if ch4 then ctx.act({ kind = "dissolve-edge", preset = preset, key = e.key, on = on }) end
                local vx = x + label_w + 12
                -- 关着时只显示当前值(灰字),打开才能编辑
                local function value_box(id, bw3, val, lo, hi, commit)
                    if e.on == true then
                        W.num_box(st.drafts, id, vx, cy + 2, bw3, val, { min = lo, max = hi }, commit)
                    else
                        D.text_mid(fmt(val), vx + 6, cy, 28, C.faint, W.small(), bw3 - 6)
                    end
                    vx = vx + bw3 + 6
                end
                if e.kind == "color" then
                    local rgb = type(e.value) == "table" and e.value or { 1, 1, 1 }
                    for k = 1, 3 do
                        value_box("dis_edge_color_" .. preset .. "_" .. k, 56, tonumber(rgb[k]), 0, 1, function(n)
                            local nv = { rgb[1], rgb[2], rgb[3] }
                            nv[k] = n
                            ctx.act({ kind = "dissolve-edge", preset = preset, key = e.key, value = nv })
                        end)
                    end
                else
                    value_box("dis_edge_" .. preset .. "_" .. e.key, 70, tonumber(e.value), e.min, e.max,
                        function(n) ctx.act({ kind = "dissolve-edge", preset = preset, key = e.key, value = n }) end)
                end
                hint_after(vx + 4, hint)
            end
            cy = cy + 8
        end
    end

    -- 其他 mod 的效果
    local others = {}
    for _, p in ipairs(type(snap.effectProviders) == "table" and snap.effectProviders or {}) do
        if p.id ~= BUILTIN then others[#others + 1] = p end
    end
    if #others > 0 then
        W.h2(t("dissolveOthers"), x, cy)
        cy = cy + 26
        cy = cy + W.note(t("dissolveOthersLead"), x, cy, w) + 6
        for _, p in ipairs(others) do
            local ex = label_row(pick(p.name) or tostring(p.id))
            local values, labels, cur_i = { "random" }, { t("effectRandom") }, 1
            for _, id in ipairs(p.effects or {}) do
                values[#values + 1] = id
                labels[#labels + 1] = (type(p.labels) == "table" and pick(p.labels[id])) or (zh and KNOWN_ZH[id]) or id
                if id == p.mode then cur_i = #values end
            end
            local ch5, i5 = W.select("dis_other_" .. tostring(p.id), ex, cy + 2, 160, 24, labels, cur_i)
            if ch5 and values[i5] then ctx.act({ kind = "effect-select", provider = p.id, effect = values[i5] }) end
            hint_after(ex + 172, t("dissolveEffectHint"))
        end
    end
    return cy - y + 8
end

return Page
