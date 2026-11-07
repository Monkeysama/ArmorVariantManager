-- RE4 配置 v3:整套造型 + 平铺的状态组 + 独立的条件状态。
--
-- 和 v2 的区别只在"每一层选哪个":v2 的规则挂在各层自己的选项上(layer.rules),
-- 一条规则只能驱动一层;v3 把规则收成一张按优先级排列的条件状态表,一个条件状态可以同时
-- 切换整套造型和若干状态组。叠加、溶解、护甲镜像仍由 TransformManager 负责。
--
--   cfg = {
--     version = 3,
--     base   = { presets = {名 -> 快照}, order = {...}, active = "名" | "" },
--     groups = { { name, options = {名 -> 稀疏快照}, order, active }, ... },
--              -- 数组顺序就是叠加顺序:靠后的组覆盖靠前的。选项可以写任何材质,几个组写同一个材质时靠后的说了算
--              -- (2026-11-07 前还有 scope 作用域限制能写哪些材质,读入时丢掉)
--     conditions = { auto = true, states = { 条件状态, ... } },   -- 数组顺序就是优先级
--     material_notes = { [slot] = { [材质] = "备注" } }, armor_mirrors_body = true, source_preset = nil,
--   }
--   快捷键(可选):hotkeys = { ["0".."9"] = 绑定 } —— Alt + 数字,按键处理见 Hotkeys.lua。所有设定共用这十个键。
--     绑定 = { kind = "base" | "group" | "palette", group = 状态组名(kind = group 时),
--              option = 预设 / 选项名 或 scheme = 方案名(单项;"" = 状态组的「（无）」/ 调色的「初始」),
--              skip = { 名字, ... }(只有轮换:不参与轮换的项) }
--     没有 option / scheme = 轮换整个结构(按一下切到下一项,到末尾回到开头)。一个键一个设定、一个设定一个键;
--     结构绑了轮换键时,它下面的项不能再单独绑(清洗时去掉)。旧的 base.hotkeys(整套造型单项)读入时迁移过来。
--   模型高度(可选):base.heights = { [预设名] = 厘米 },groups[i].heights = { [选项名] = 厘米 }。
--     不放进快照(快照顶层键都是槛位,预设指纹按它算)。解算见 height_of:按叠加顺序,后写覆盖先写。
--   height_override = { enabled, cm }:全局覆盖(快速切换页),打开时无视各层,统一用 cm。
--   调色的底是「初始」= mdf2 里的原值,只读,不存在配置里。
--   palettes = { [方案名] = { [slot] = { [材质] = { [参数] = 数值 | {x..w} } } } }(见 Palette.lua),
--     palette_order = { 方案名, ... }:调色方案(子预设),
--     palette_order 是新建的先后,只用来排列表(不影响叠加)。
--     palette_active = 方案名:调色页里选中的方案,选中就一直生效(相当于调色的手动选择)。
--     另外可以被引用:base.palettes = { [预设名] = 方案名 },groups[i].palettes = { [选项名] = 方案名 },
--     条件状态的 palette = 方案名。叠加顺序见 palette_layers。引用到不存在的方案时保留原样,解算时跳过。
--   条件状态 = { name, enabled, exclusive, logic, conditions, hold, fade_in, fade_out,
--               hp = nil | { upper, lower, invert }, base = nil | "整套造型名",
--               targets = { { group, option }, ... }, palette = nil | "调色方案名" }
--
-- 状态组以名字为标识;改名统一走 OpsV3,顺带更新条件状态里的引用。引用到不存在的组 / 选项时
-- 保留原样,解算时当作"引用失效"跳过,界面上能看见、能删。
local M = {}
M.VERSION = 3

local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local Condition_HP = require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HP")
local Palette = require("ArmorVariantManager_Core.Games.RE4.Palette")

local function is_tbl(v) return type(v) == "table" end

function M.key_of(slot, mat) return slot .. "/" .. mat end
function M.split_key(k)
    if type(k) ~= "string" then return nil end
    return k:match("^([^/]+)/(.+)$")
end
function M.layer_key(group_name) return "group:" .. group_name end
function M.is_v3(cfg) return is_tbl(cfg) and cfg.version == M.VERSION end

function M.find_group(cfg, name)
    for i, g in ipairs(cfg.groups or {}) do
        if g.name == name then return g, i end
    end
    return nil
end

-- 一个状态组的选项里写到过的材质键(任一选项写了开或关就算)
function M.group_keys(g)
    local set = {}
    for _, opt in pairs(is_tbl(g) and is_tbl(g.options) and g.options or {}) do
        for slot, data in pairs(is_tbl(opt) and opt or {}) do
            if type(slot) == "string" and is_tbl(data) and is_tbl(data.materials) then
                for m in pairs(data.materials) do
                    if type(m) == "string" then set[M.key_of(slot, m)] = true end
                end
            end
        end
    end
    return set
end

-- 材质 -> 写它的状态组名列表(按叠加顺序,最后一个说了算)
function M.groups_of(cfg)
    local map = {}
    for _, g in ipairs(cfg.groups or {}) do
        for k in pairs(M.group_keys(g)) do
            map[k] = map[k] or {}
            table.insert(map[k], g.name)
        end
    end
    return map
end

-- order 和表对齐:保留原顺序,缺的按名字补在末尾
function M.reconcile_order(order, map)
    local out, seen = {}, {}
    if is_tbl(order) then
        for _, n in ipairs(order) do
            if type(n) == "string" and map[n] ~= nil and not seen[n] then seen[n] = true; out[#out + 1] = n end
        end
    end
    local rest = {}
    for n in pairs(map) do if type(n) == "string" and not seen[n] then rest[#rest + 1] = n end end
    table.sort(rest)
    for _, n in ipairs(rest) do out[#out + 1] = n end
    return out
end

-- 快照清洗:只留 { slot = { materials = { 名 = bool } } };allowed 给了就只留这些材质;
-- sparse = 稀疏快照(状态组选项),空槛位不留
local function clean_snapshot(snap, allowed, sparse)
    local out = {}
    if not is_tbl(snap) then return out end
    for slot, data in pairs(snap) do
        if type(slot) == "string" and is_tbl(data) then
            local mats = {}
            for m, v in pairs(is_tbl(data.materials) and data.materials or {}) do
                if type(m) == "string" and type(v) == "boolean" and (not allowed or allowed[M.key_of(slot, m)]) then
                    mats[m] = v
                end
            end
            if next(mats) or not (allowed or sparse) then out[slot] = { materials = mats } end
        end
    end
    return out
end
M.clean_snapshot = clean_snapshot

local function num(v, default, lo, hi)
    v = tonumber(v) or default
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

-- 模型高度(厘米):范围同 Wilds 的陷地修复,0.1 厘米取整
M.HEIGHT_MIN, M.HEIGHT_MAX = -10, 50
function M.clamp_height(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    v = math.max(M.HEIGHT_MIN, math.min(M.HEIGHT_MAX, v))
    return math.floor(v * 10 + 0.5) / 10
end

-- 只留指向现有预设 / 选项的合法数值
local function clean_heights(h, names)
    local out = {}
    for n, v in pairs(is_tbl(h) and h or {}) do
        local cm = names[n] ~= nil and M.clamp_height(v)
        if cm then out[n] = cm end
    end
    return out
end

-- 调色方案引用:{ [预设 / 选项名] = 方案名 },只留指向现有预设 / 选项的;方案不存在也保留(显示为引用失效)。
-- 空表返回 nil,省得每份配置都多一个字段
local function clean_palette_refs(refs, names)
    local out = {}
    for n, v in pairs(is_tbl(refs) and refs or {}) do
        if names[n] ~= nil and type(v) == "string" and v ~= "" then out[n] = v end
    end
    return next(out) and out or nil
end

-- ============================================================ 快捷键绑定
-- 结构键:同一个结构的轮换和单项共用(用来判断互斥);目标键:一个设定只占一个键
function M.hotkey_structure(b) return b.kind == "group" and ("group:" .. tostring(b.group)) or b.kind end
function M.hotkey_is_cycle(b) return b.option == nil and b.scheme == nil end
function M.hotkey_target(b)
    return M.hotkey_structure(b) .. "|" .. (M.hotkey_is_cycle(b) and "*" or ("=" .. tostring(b.option or b.scheme)))
end

-- 结构里能轮换的项(按显示顺序):整套造型 = 各预设;状态组 = 「（无）」("")+ 各选项;调色 = 「初始」("")+ 各方案
function M.hotkey_items(cfg, b)
    if b.kind == "base" then
        local out = {}
        for _, n in ipairs((cfg.base or {}).order or {}) do out[#out + 1] = n end
        return out
    elseif b.kind == "group" then
        local g = M.find_group(cfg, b.group)
        if not g then return nil end
        local out = { "" }
        for _, n in ipairs(g.order or {}) do out[#out + 1] = n end
        return out
    elseif b.kind == "palette" then
        local out = { "" }
        for _, n in ipairs(cfg.palette_order or {}) do out[#out + 1] = n end
        return out
    end
    return nil
end

-- 这个绑定还指得到东西吗
function M.hotkey_valid(cfg, b)
    local items = M.hotkey_items(cfg, b)
    if not items then return false end
    if M.hotkey_is_cycle(b) then return true end
    local want = b.kind == "palette" and b.scheme or b.option
    if b.kind == "base" and want == "" then return false end
    for _, n in ipairs(items) do if n == want then return true end end
    return false
end

-- 轮换:当前手动选择的下一项(跳过 skip 里的);当前不在列表里就从第一项开始。没有可轮换的返回 nil
function M.hotkey_next(cfg, b)
    local items = M.hotkey_items(cfg, b) or {}
    local skip = {}
    for _, n in ipairs(b.skip or {}) do skip[n] = true end
    local list = {}
    for _, n in ipairs(items) do if not skip[n] then list[#list + 1] = n end end
    if #list == 0 then return nil end
    local cur
    if b.kind == "base" then cur = (cfg.base or {}).active
    elseif b.kind == "group" then cur = (M.find_group(cfg, b.group) or {}).active
    else cur = cfg.palette_active or "" end
    for i, n in ipairs(list) do
        if n == cur then return list[i % #list + 1] end
    end
    return list[1]
end

-- 清洗:键只认 0~9;目标要存在;skip 只留现有的项;一个设定只留一个键(数字小的留下);
-- 结构有轮换键时去掉它下面的单项键;旧的 base.hotkeys 迁移过来(键没被占才迁)。空了返回 nil
function M.clean_hotkey_table(cfg)
    local src = is_tbl(cfg.hotkeys) and cfg.hotkeys or {}
    local legacy = is_tbl(cfg.base) and cfg.base.hotkeys or nil
    local raw = {}
    for d = 0, 9 do
        local b = src[tostring(d)] or src[d]
        if is_tbl(b) then raw[d] = b end
    end
    if is_tbl(legacy) then
        local names = {}
        for n in pairs(legacy) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            local d = math.tointeger(tonumber(legacy[n]))
            if type(n) == "string" and d and d >= 0 and d <= 9 and not raw[d] then raw[d] = { kind = "base", option = n } end
        end
    end
    if is_tbl(cfg.base) then cfg.base.hotkeys = nil end
    local list = {}
    for d = 0, 9 do
        local b = raw[d]
        if b and (b.kind == "base" or b.kind == "group" or b.kind == "palette") then
            local c = { kind = b.kind }
            if b.kind == "group" then c.group = type(b.group) == "string" and b.group or nil end
            if b.kind == "palette" then c.scheme = type(b.scheme) == "string" and b.scheme or nil
            else c.option = type(b.option) == "string" and b.option or nil end
            if (b.kind ~= "group" or c.group) and M.hotkey_valid(cfg, c) then
                if M.hotkey_is_cycle(c) then
                    local items, skip = {}, {}
                    for _, n in ipairs(M.hotkey_items(cfg, c) or {}) do items[n] = true end
                    for _, n in ipairs(is_tbl(b.skip) and b.skip or {}) do
                        if type(n) == "string" and items[n] and not skip[n] then skip[n] = true; c.skip = c.skip or {}; c.skip[#c.skip + 1] = n end
                    end
                end
                list[#list + 1] = { d = d, b = c }
            end
        end
    end
    local cycles, seen, out = {}, {}, {}
    for _, e in ipairs(list) do if M.hotkey_is_cycle(e.b) then cycles[M.hotkey_structure(e.b)] = true end end
    for _, e in ipairs(list) do
        local t = M.hotkey_target(e.b)
        local blocked = not M.hotkey_is_cycle(e.b) and cycles[M.hotkey_structure(e.b)]
        if not blocked and not seen[t] then seen[t] = true; out[tostring(e.d)] = e.b end
    end
    cfg.hotkeys = next(out) and out or nil
    return cfg.hotkeys
end

M.PALETTE_NAME_MAX = 64
M.LEGACY_PALETTE = "常驻"   -- 旧的常驻调色迁移成的方案名
function M.valid_palette_name(n)
    return type(n) == "string" and n ~= "" and #n <= M.PALETTE_NAME_MAX and not n:match("^%s") and not n:match("%s$")
end

-- 这一帧的模型高度:全局覆盖打开时直接用它;否则整套造型先写,再按状态组顺序覆盖;
-- 没有任何一层设过 → nil(不抬高)。第二个返回值是来源:
--   { layer = "override" } / { layer = "base", option = 预设名 } / { layer = 状态组名, option = 选项名 }
function M.height_of(cfg, picks)
    if not is_tbl(cfg) then return nil end
    local o = cfg.height_override
    if is_tbl(o) and o.enabled == true then return M.clamp_height(o.cm) or 0, { layer = "override" } end
    if not is_tbl(picks) then return nil end
    local cm, src = nil, nil
    local base = cfg.base or {}
    if picks.base and base.heights and base.heights[picks.base] then
        cm, src = base.heights[picks.base], { layer = "base", option = picks.base }
    end
    for _, g in ipairs(cfg.groups or {}) do
        local pick = picks[M.layer_key(g.name)]
        if pick and g.heights and g.heights[pick] then cm, src = g.heights[pick], { layer = g.name, option = pick } end
    end
    return cm, src
end

-- 旧布尔条件 → 合成条件(Conditions/Merged.lua)。只迁移语义完全等价的(Merged.LEGACY[id].exact):
-- 每组优先级最高的一档、「持械中」(= 持械 ~= 无)、血量变化;其余照旧用旧 id(它们一直能求值)。
-- 确定性:迁移过的不会再变,同一份配置迁移两次结果一样。返回新表或原表
function M.migrate_condition(c)
    local m = (Registry.LEGACY or {})[c.type]
    if not m or not m.exact or type(c.value) ~= "boolean" then return c end
    local on = c.value
    if m.superset then
        return { type = m.group, op = on and "~=" or "==", value = 0 }
    end
    return { type = m.group, op = on and "==" or "~=", value = m.value }
end

function M.normalize_state(st)
    st.name = (type(st.name) == "string" and st.name ~= "") and st.name or "?"
    st.enabled = st.enabled ~= false
    st.exclusive = st.exclusive == true
    st.logic = st.logic == "OR" and "OR" or "AND"
    local conds = {}
    for _, c in ipairs(is_tbl(st.conditions) and st.conditions or {}) do
        if is_tbl(c) and type(c.type) == "string" then conds[#conds + 1] = M.migrate_condition(c) end
    end
    st.conditions = conds
    st.hold = num(st.hold, 0, 0, 3600)
    st.fade_in = num(st.fade_in, 0, 0, 30)
    st.fade_out = num(st.fade_out, 0, 0, 30)
    if is_tbl(st.hp) then
        st.hp = { upper = num(st.hp.upper, 100, 0, 100), lower = num(st.hp.lower, 0, 0, 100), invert = st.hp.invert == true }
    else
        st.hp = nil
    end
    if type(st.base) ~= "string" or st.base == "" then st.base = nil end
    local targets, seen = {}, {}
    for _, t in ipairs(is_tbl(st.targets) and st.targets or {}) do
        if is_tbl(t) and type(t.group) == "string" and type(t.option) == "string" and not seen[t.group] then
            seen[t.group] = true
            targets[#targets + 1] = { group = t.group, option = t.option }
        end
    end
    st.targets = targets
    if type(st.palette) ~= "string" or st.palette == "" then st.palette = nil end
    return st
end

function M.new_state(name)
    return M.normalize_state({ name = name, conditions = {}, targets = {} })
end

function M.normalize(cfg)
    cfg.version = M.VERSION
    local base = is_tbl(cfg.base) and cfg.base or {}
    local presets = {}
    for n, p in pairs(is_tbl(base.presets) and base.presets or {}) do
        if type(n) == "string" then presets[n] = clean_snapshot(p) end
    end
    base.presets = presets
    base.order = M.reconcile_order(base.order, presets)
    if type(base.active) ~= "string" or (base.active ~= "" and not presets[base.active]) then base.active = "" end
    base.rules, base.auto = nil, nil
    base.heights = clean_heights(base.heights, presets)
    base.palettes = clean_palette_refs(base.palettes, presets)
    cfg.base = base

    local groups, names = {}, {}
    for _, g in ipairs(is_tbl(cfg.groups) and cfg.groups or {}) do
        if is_tbl(g) and type(g.name) == "string" and g.name ~= "" and not names[g.name] then
            names[g.name] = true
            -- 旧配置里的 scope(作用域)在这里丢掉:状态组不再限制能写哪些材质(2026-11-07)
            local options = {}
            for n, p in pairs(is_tbl(g.options) and g.options or {}) do
                if type(n) == "string" then options[n] = clean_snapshot(p, nil, true) end
            end
            groups[#groups + 1] = {
                name = g.name, options = options,
                order = M.reconcile_order(g.order, options),
                active = (type(g.active) == "string" and options[g.active]) and g.active or "",
                heights = clean_heights(g.heights, options),
                palettes = clean_palette_refs(g.palettes, options),
            }
        end
    end
    cfg.groups = groups

    local cond = is_tbl(cfg.conditions) and cfg.conditions or {}
    cond.auto = cond.auto ~= false
    local states = {}
    for _, st in ipairs(is_tbl(cond.states) and cond.states or {}) do
        if is_tbl(st) then states[#states + 1] = M.normalize_state(st) end
    end
    cond.states = states
    cfg.conditions = cond

    cfg.axes, cfg.axis_order = nil, nil
    if is_tbl(cfg.height_override) then
        cfg.height_override = { enabled = cfg.height_override.enabled == true, cm = M.clamp_height(cfg.height_override.cm) or 0 }
    else
        cfg.height_override = nil
    end
    if not is_tbl(cfg.material_notes) then cfg.material_notes = {} end
    if cfg.armor_mirrors_body ~= false then cfg.armor_mirrors_body = true end
    -- 调色方案:空方案也保留(刚建好还没调的)
    local schemes = {}
    for n, pal in pairs(is_tbl(cfg.palettes) and cfg.palettes or {}) do
        if M.valid_palette_name(n) then schemes[n] = Palette.clean(pal) end
    end
    -- 旧的「常驻」调色(cfg.palette,一直生效、垫在方案下面)→ 一个叫「常驻」的方案,外观不变:
    -- 没选方案时选中它;已经选了别的方案时,把选中方案没写的参数从常驻补进去(原来就是叠在常驻上的)
    local legacy = Palette.clean(cfg.palette)
    if next(legacy) then
        local active = type(cfg.palette_active) == "string" and schemes[cfg.palette_active] or nil
        if active then
            schemes[cfg.palette_active] = Palette.merge({ legacy, active })
        else
            local name, i = M.LEGACY_PALETTE, 2
            while schemes[name] do name = M.LEGACY_PALETTE .. " " .. i; i = i + 1 end
            schemes[name] = legacy
            cfg.palette_active = name
            local order = is_tbl(cfg.palette_order) and cfg.palette_order or {}
            table.insert(order, 1, name)
            cfg.palette_order = order
        end
    end
    cfg.palette = nil
    if next(schemes) then
        cfg.palettes = schemes
        cfg.palette_order = M.reconcile_order(cfg.palette_order, schemes)
    else
        cfg.palettes, cfg.palette_order = nil, nil
    end
    if type(cfg.palette_active) ~= "string" or not schemes[cfg.palette_active] then cfg.palette_active = nil end
    -- 快捷键要在整套造型、状态组、调色方案都清洗完之后
    M.clean_hotkey_table(cfg)
    if type(cfg.source_preset) ~= "string" then cfg.source_preset = nil end
    return cfg
end

function M.new_config()
    return M.normalize({ version = M.VERSION })
end

-- ============================================================
-- v2 -> v3
--
-- axis_priority:v2 的状态组名,**优先级从高到低**(高级组在前,各档内按 axis_order)。
-- 由调用方给,因为 v2 的排序规则在 TransformManager 里。
--
-- 结果等价性:每条 v2 规则变成一个只指向原来那一层的条件状态,排列顺序 = 整套造型的规则,
-- 再按状态组优先级、组内按 order。v2 里各层互不影响、每层取第一条命中的规则;v3 里每个状态
-- 只认领一层,同一层上仍是排在前面的先认领 —— 所以各层的选择和 v2 一致。全部不独占。
-- 作用域重叠原样保留:groups 按优先级**倒序**排(= v2 的应用顺序,优先级高的最后写),
-- 后写覆盖先写,所以重叠材质的结果也和 v2 一致。
-- ============================================================
function M.migrate_from_v2(v2, axis_priority, base_label)
    local axes = is_tbl(v2.axes) and v2.axes or {}
    local b = is_tbl(v2.base) and v2.base or {}
    local out = {
        version = M.VERSION,
        base = { presets = b.presets, order = b.order, active = b.active },
        material_notes = v2.material_notes,
        armor_mirrors_body = v2.armor_mirrors_body,
    }
    local report = {}

    out.groups = {}
    for i = #axis_priority, 1, -1 do
        local name = axis_priority[i]
        local axis = axes[name]
        if is_tbl(axis) then
            out.groups[#out.groups + 1] = { name = name, options = axis.presets,
                order = axis.order, active = axis.active }
        end
    end

    local states, used = {}, {}
    local function unique(n)
        local x, i = n, 2
        while used[x] do x = n .. " (" .. i .. ")"; i = i + 1 end
        used[x] = true
        return x
    end
    local function add_rules(layer, label, set_target)
        local by = {}
        for _, r in ipairs(is_tbl(layer.rules) and layer.rules or {}) do
            if is_tbl(r) and type(r.preset) == "string" and r.preset ~= "" then
                by[r.preset] = by[r.preset] or {}
                table.insert(by[r.preset], r)
            end
        end
        local names, seen = {}, {}
        for _, n in ipairs(is_tbl(layer.order) and layer.order or {}) do
            if by[n] and not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
        local rest = {}
        for n in pairs(by) do if not seen[n] then rest[#rest + 1] = n end end
        table.sort(rest)
        for _, n in ipairs(rest) do names[#names + 1] = n end
        for _, pname in ipairs(names) do
            for _, r in ipairs(by[pname]) do
                local dissolve = r.dissolve_enabled == true
                local st = {
                    name = unique(label .. " · " .. pname),
                    enabled = layer.auto ~= false,
                    logic = r.logic, conditions = r.conditions, hold = r.hold,
                    fade_in = dissolve and (tonumber(r.dissolve_hide_time) or 0.5) or 0,
                    fade_out = dissolve and (tonumber(r.dissolve_show_time) or 0.5) or 0,
                    targets = {},
                }
                if r.dissolve_hp_driven == true then
                    st.hp = { upper = r.dissolve_hp_upper, lower = r.dissolve_hp_lower, invert = r.dissolve_hp_invert }
                end
                set_target(st, pname)
                states[#states + 1] = st
            end
        end
    end
    add_rules(b, base_label or "Full outfit", function(st, p) st.base = p end)
    for _, name in ipairs(axis_priority) do
        if is_tbl(axes[name]) then
            add_rules(axes[name], name, function(st, p) st.targets = { { group = name, option = p } } end)
        end
    end
    out.conditions = { auto = true, states = states }
    return M.normalize(out), report
end

-- ============================================================
-- 解算:每一层选哪个
-- ============================================================

-- 测试可以替换这三个
M.eval = function(st, context) return Registry.eval_rule(st, context) end
M.clock = os.clock
M.hp_of = function(context) return Condition_HP.get(context) end

-- 「命中后保持 N 秒」:计时从条件不再成立那一刻开始(成立的每一帧都续到 now + hold)。
-- 计时状态不进配置,以状态表为键放在弱表里,配置重载后自然丢掉。语义同 v2 的 rule_hits。
local hold_until = setmetatable({}, { __mode = "k" })
function M.hits(st, context)
    if M.eval(st, context) then
        if st.hold > 0 then hold_until[st] = M.clock() + st.hold end
        return true, false
    end
    local u = hold_until[st]
    if u then
        if M.clock() < u then return true, true end
        hold_until[st] = nil
    end
    return false, false
end

-- Main 选溶解过渡时读的字段沿用 v2 规则的名字:进入状态用 hide_time,离开用 show_time
local function transition_of(st)
    return { dissolve_enabled = st.fade_in > 0 or st.fade_out > 0,
             dissolve_hide_time = st.fade_in, dissolve_show_time = st.fade_out }
end

-- 血量驱动链:同 v2,上限从高到低(全部反向时按下限从低到高;方向混用时按条件状态顺序)
local function hp_chain(items, hp)
    local inverted, normal = 0, 0
    for _, it in ipairs(items) do
        if it.st.hp.invert then inverted = inverted + 1 else normal = normal + 1 end
    end
    if inverted == 0 then
        table.sort(items, function(a, c)
            if a.st.hp.upper ~= c.st.hp.upper then return a.st.hp.upper > c.st.hp.upper end
            return a.i < c.i
        end)
    elseif normal == 0 then
        table.sort(items, function(a, c)
            if a.st.hp.lower ~= c.st.hp.lower then return a.st.hp.lower < c.st.hp.lower end
            return a.i < c.i
        end)
    else
        table.sort(items, function(a, c) return a.i < c.i end)
    end
    local chain, names = 0, {}
    for k, it in ipairs(items) do names[k] = it.option end
    for k = #items, 1, -1 do
        local h = items[k].st.hp
        local p
        if h.upper > h.lower then
            p = math.max(0, math.min(1, (h.upper - hp) / (h.upper - h.lower)))
        else
            p = hp <= h.upper and 1 or 0
        end
        if h.invert then p = 1 - p end
        if p > 0 then chain = (k - 1) + p; break end
    end
    return { chain = chain, names = names }, items
end

-- 血量状态的进度(0~1),同 hp_chain 里单个状态的算法;> 0 表示这个状态在起作用
local function hp_progress(h, hp)
    local p
    if h.upper > h.lower then
        p = math.max(0, math.min(1, (h.upper - hp) / (h.upper - h.lower)))
    else
        p = hp <= h.upper and 1 or 0
    end
    if h.invert then p = 1 - p end
    return p
end

-- 返回:
--   picks   { base = 名 | nil, ["group:<组名>"] = 名 | nil }   各层这一帧的选择
--   layers  { [层键] = { name, rule = 过渡设置 | nil, prio = 条件状态序号 | nil } }
--   drives  { [层键] = { chain, names } }   血量驱动(同 v2)
--   status  { [i] = { kind = "active"|"partial"|"outranked"|"idle"|"off"|"paused", by = 序号, holding } }
--   targets { [i] = { base = 认领结果 | nil, palette = 认领结果 | nil, [j] = 认领结果 } }
--           认领结果 = false(没命中)| { kind = "win"|"lose"|"broken", by }
--   调色方案不独占:命中的状态各自生效,按优先级叠加(见 palette_layers),只有独占状态能挡住后面的。
--   血量状态的调色在血量进入它的区间(进度 > 0)时生效。
function M.resolve(cfg, context)
    local base = cfg.base
    local cond = cfg.conditions
    local groups = {}
    for _, g in ipairs(cfg.groups) do groups[g.name] = g end

    local claims, status, targets, hp_items = {}, {}, {}, {}
    local stop = nil
    local schemes = cfg.palettes or {}
    local hp, touched = nil, {}
    local palette_hp = {}
    local function get_hp()
        if hp == nil then hp = M.hp_of(context) or false end
        return hp
    end
    for i, st in ipairs(cond.states) do
        local list = {}
        if st.base then list[#list + 1] = { key = "base", option = st.base, valid = base.presets[st.base] ~= nil, is_base = true } end
        for _, t in ipairs(st.targets) do
            local g = groups[t.group]
            list[#list + 1] = { key = M.layer_key(t.group), option = t.option, valid = g ~= nil and g.options[t.option] ~= nil }
        end
        -- 调色方案放在最后,不影响状态组目标的序号(血量驱动那里按序号回填)
        if st.palette then list[#list + 1] = { key = "palette", option = st.palette, valid = schemes[st.palette] ~= nil, is_palette = true } end
        local ts = {}
        for j, x in ipairs(list) do ts[j] = (not x.valid) and { kind = "broken" } or false end

        if not st.enabled then
            status[i] = { kind = "off" }
        elseif not cond.auto then
            status[i] = { kind = "paused" }
        elseif st.hp then
            if stop then
                status[i] = { kind = "outranked", by = stop }
                for j in ipairs(list) do if not ts[j] then ts[j] = { kind = "lose", by = stop } end end
            else
                status[i] = { kind = "idle" }
                for j, x in ipairs(list) do
                    if x.is_palette then
                        if not ts[j] then
                            -- 血量状态的调色方案按血量进度加权叠加(进度 0 不生效,1 完全生效),见 palette_sources
                            local v = get_hp()
                            local p = type(v) == "number" and hp_progress(st.hp, v) or 0
                            palette_hp[i] = p
                            ts[j] = p > 0 and { kind = "win" } or false
                            if p > 0 then touched[i] = true end
                        end
                    elseif not ts[j] then
                        hp_items[x.key] = hp_items[x.key] or {}
                        table.insert(hp_items[x.key], { st = st, i = i, j = j, option = x.option })
                    end
                end
            end
        else
            local hit, holding = M.hits(st, context)
            if not hit then
                status[i] = { kind = "idle" }
            elseif stop then
                for j in ipairs(list) do if not ts[j] then ts[j] = { kind = "lose", by = stop } end end
                status[i] = { kind = "outranked", by = stop, holding = holding }
            else
                local won, valid, by = 0, 0, nil
                for j, x in ipairs(list) do
                    if not ts[j] and x.is_palette then
                        valid, won = valid + 1, won + 1
                        ts[j] = { kind = "win" }
                    elseif not ts[j] then
                        valid = valid + 1
                        local c = claims[x.key]
                        if c == nil then
                            claims[x.key] = { i = i, option = x.option }
                            won = won + 1
                            ts[j] = { kind = "win" }
                        else
                            ts[j] = { kind = "lose", by = c.i }
                            by = by or c.i
                        end
                    end
                end
                status[i] = {
                    kind = (valid == 0 and "idle") or (won == 0 and "outranked") or (won < valid and "partial") or "active",
                    by = won == 0 and by or nil, holding = holding,
                }
                if st.exclusive then stop = i end
            end
        end
        local out = {}
        for j, x in ipairs(list) do
            if x.is_base then out.base = ts[j] elseif x.is_palette then out.palette = ts[j] else out[#out + 1] = ts[j] end
        end
        targets[i] = out
    end

    local picks, layers = {}, {}
    local function pick(key, manual)
        local c = claims[key]
        if c then
            picks[key] = c.option
            layers[key] = { name = c.option, rule = transition_of(cond.states[c.i]), prio = c.i }
        else
            picks[key] = (type(manual) == "string" and manual ~= "") and manual or nil
            layers[key] = { name = picks[key] }
        end
    end
    pick("base", base.active)
    for _, g in ipairs(cfg.groups) do pick(M.layer_key(g.name), g.active) end

    -- 血量驱动:每层一条链。排在第一个血量状态之前的普通状态认领了这一层时,这一层不驱动
    local drives = {}
    for key, items in pairs(hp_items) do
        local first = math.huge
        for _, it in ipairs(items) do first = math.min(first, it.i) end
        local c = claims[key]
        if c and c.i < first then
            for _, it in ipairs(items) do
                local tsl = targets[it.i]
                local r = { kind = "lose", by = c.i }
                if it.st.base and key == "base" then tsl.base = r else
                    local idx = it.j - (it.st.base and 1 or 0)
                    tsl[idx] = r
                end
            end
        else
            get_hp()
            if type(hp) == "number" then
                local d, sorted = hp_chain(items, hp)
                drives[key] = d
                for k, it in ipairs(sorted) do
                    local driving = d.chain > (k - 1)
                    local tsl = targets[it.i]
                    local r = driving and { kind = "win" } or false
                    if key == "base" then tsl.base = r else tsl[it.j - (it.st.base and 1 or 0)] = r end
                    if driving then touched[it.i] = true end
                end
            end
        end
    end
    for i, st in ipairs(cond.states) do
        if st.hp and status[i].kind == "idle" and touched[i] then status[i] = { kind = "active" } end
    end

    return { picks = picks, layers = layers, drives = drives, status = status, targets = targets, palette_hp = palette_hp }
end

-- ============================================================
-- 调色方案:这一帧哪些方案生效、按什么顺序叠加
--
-- 从下到上:初始(mdf2 原值,不在返回的名字里)→ 调色页选中的方案(palette_active)→ 整套造型的选择
-- 引用的方案 → 状态组按叠加顺序各自的选择引用的方案 → 条件状态(优先级低的先叠,高的盖在上面)。
-- 选中的方案和状态组的手动选择一样,会被引用(按条件切换的)盖住。返回方案名列表;不存在的方案跳过。
-- ============================================================
function M.palette_layers(cfg, r)
    -- 血量进度为 0 的(还没进区间)不算生效
    local names, _, hp = M.palette_sources(cfg, r)
    local out = {}
    for i, n in ipairs(names) do if hp[i] == nil or hp[i] > 0 then out[#out + 1] = n end end
    return out
end

-- 同 palette_layers,另外返回每个方案的来源(渐变用):src[i] = 条件状态序号(由条件状态带来:它自己引用的,
-- 或者它认领的整套造型 / 状态组选项引用的)| false(手动选择带来的);
-- hp[i] = 血量进度(0~1,这个方案由带血量区间的条件状态带来,按进度加权叠加)| nil(完全生效)。
-- 血量状态进度为 0 时也列出来(权重 0),好让平滑后的权重能渐渐退到 0
function M.palette_sources(cfg, r)
    local names, src, hp = {}, {}, {}
    local schemes = cfg.palettes or {}
    local function add(n, by, w)
        if type(n) == "string" and schemes[n] then
            names[#names + 1] = n; src[#src + 1] = by or false; hp[#names] = w
        end
    end
    add(cfg.palette_active, false)
    local picks = r and r.picks or {}
    local layers = r and r.layers or {}
    local base = cfg.base or {}
    if picks.base then add((base.palettes or {})[picks.base], (layers.base or {}).prio) end
    for _, g in ipairs(cfg.groups or {}) do
        local key = M.layer_key(g.name)
        local pick = picks[key]
        if pick then add((g.palettes or {})[pick], (layers[key] or {}).prio) end
    end
    local states = (cfg.conditions or {}).states or {}
    for i = #states, 1, -1 do
        local t = r and r.targets and r.targets[i]
        local w = r and r.palette_hp and r.palette_hp[i]
        if w ~= nil then add(states[i].palette, i, w)
        elseif t and t.palette and t.palette.kind == "win" then add(states[i].palette, i) end
    end
    -- 血量方案之间按区间深浅叠:越深的区间(普通 = 上限越低,反向 = 下限越高)盖在越上面,
    -- 这样绿 → 黄 → 红不依赖条件状态的先后。它们仍占原来的叠加位置,和其它方案的相对顺序不变
    local slots, items = {}, {}
    for k = 1, #names do
        local st = src[k] and states[src[k]]
        if hp[k] ~= nil and st and st.hp then
            local depth = st.hp.invert and st.hp.lower or (100 - st.hp.upper)
            slots[#slots + 1] = k
            items[#items + 1] = { n = names[k], s = src[k], w = hp[k], depth = depth, k = k }
        end
    end
    if #items > 1 then
        table.sort(items, function(a, b) if a.depth ~= b.depth then return a.depth < b.depth end return a.k < b.k end)
        for idx, k in ipairs(slots) do
            local it = items[idx]
            names[k], src[k], hp[k] = it.n, it.s, it.w
        end
    end
    return names, src, hp
end

-- 调色方案组合从 prev 变成 cur 时渐变多久(秒)。prev / cur = { names, src, states }(states = 当时的条件状态表)。
-- 进来的方案用带来它的条件状态的 fade_in,离开的用 fade_out,手动选择带来的用 manual(界面溶解时间,关掉时为 0);
-- 取最长的。只是顺序变了也算变化(叠加结果可能不同)
function M.palette_fade_time(prev, cur, manual)
    if not prev or not cur then return 0 end
    local function count(list)
        local c = {}
        for _, n in ipairs(list.names or {}) do c[n] = (c[n] or 0) + 1 end
        return c
    end
    local pc, cc = count(prev), count(cur)
    local function time_of(list, k, field)
        local by = list.src and list.src[k]
        local st = by and list.states and list.states[by]
        if st then return tonumber(st[field]) or 0 end
        return manual or 0
    end
    local t, any = 0, false
    for k, n in ipairs(cur.names or {}) do
        if (pc[n] or 0) < (cc[n] or 0) or prev.names[k] ~= n then any = true; t = math.max(t, time_of(cur, k, "fade_in")) end
    end
    for k, n in ipairs(prev.names or {}) do
        if (cc[n] or 0) < (pc[n] or 0) or cur.names[k] ~= n then any = true; t = math.max(t, time_of(prev, k, "fade_out")) end
    end
    return any and t or 0
end

-- 护甲同步身体外观:护甲的调色照抄身体的(按材质名,同材质开关的镜像)。
-- 护甲自己调过的值留在配置里,关掉同步后恢复;返回新表,不改输入
function M.mirror_palette(pal, on)
    if not on or not is_tbl(pal) then return pal end
    local copy = {}
    for slot, mats in pairs(pal) do copy[slot] = mats end
    copy.armor = copy.body
    return copy
end

-- 带权重叠加(血量驱动的方案):weights[i] 缺省 1;original / discrete 见 Palette.blend
function M.palette_blend_of(cfg, names, weights, original, discrete)
    local list = {}
    for _, n in ipairs(names or {}) do list[#list + 1] = (cfg.palettes or {})[n] end
    return Palette.blend(list, weights, original, discrete)
end

-- 叠好的覆盖表(交给 Palette.apply_mesh)
function M.palette_of(cfg, names)
    local list = {}
    for _, n in ipairs(names or {}) do list[#list + 1] = (cfg.palettes or {})[n] end
    return Palette.merge(list)
end

return M
