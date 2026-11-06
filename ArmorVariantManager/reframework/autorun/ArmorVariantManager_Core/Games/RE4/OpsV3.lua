-- RE4 v3 配置的修改操作。ImGui 与 REFF 共用;和 Ops 一样只改内存里的配置,
-- 返回 changed, reapply[, 额外结果],存盘和重写由调用方负责。
--
-- 整套造型的预设本身和 v2 的主层同形(presets / order / active),新建、复制、排序、
-- 替换、改材质直接用 Ops;这里只补"会牵动条件状态引用"的那几个。
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")

local OpsV3 = {}

local function valid_name(n) return type(n) == "string" and n ~= "" end

-- ============================================================ 总开关 / 手动选择
function OpsV3.set_auto(cfg, on)
    cfg.conditions.auto = on == true
    return true, true
end

-- layer:"base" 或状态组名;option:"" = （无）(整套造型也允许,= 全启用兜底)
function OpsV3.set_manual(cfg, layer, option)
    if type(option) ~= "string" then return false end
    if layer == "base" then return Ops.set_active(cfg.base, option) end
    local g = M3.find_group(cfg, layer)
    if not g or (option ~= "" and not g.options[option]) then return false end
    if g.active == option then return false end
    g.active = option
    return true, true
end

-- ============================================================ 整套造型(只补牵动引用的)
function OpsV3.rename_base(cfg, old, new)
    local ok = Ops.rename_preset(cfg.base, old, new)
    if not ok then return false end
    for _, st in ipairs(cfg.conditions.states) do
        if st.base == old then st.base = new end
    end
    return true, false
end

-- 删除后指向它的条件状态保留引用,显示为"引用失效"
function OpsV3.delete_base(cfg, name) return Ops.delete_preset(cfg.base, name) end

-- ============================================================ 状态组
function OpsV3.new_group(cfg, name)
    if not valid_name(name) or M3.find_group(cfg, name) then return false end
    table.insert(cfg.groups, { name = name, scope = {}, options = {}, order = {}, active = "" })
    return true, false
end

function OpsV3.rename_group(cfg, old, new)
    if not valid_name(new) or old == new or M3.find_group(cfg, new) then return false end
    local g = M3.find_group(cfg, old)
    if not g then return false end
    g.name = new
    for _, st in ipairs(cfg.conditions.states) do
        for _, t in ipairs(st.targets) do
            if t.group == old then t.group = new end
        end
    end
    return true, false
end

function OpsV3.delete_group(cfg, name)
    local _, i = M3.find_group(cfg, name)
    if not i then return false end
    table.remove(cfg.groups, i)
    return true, true
end

function OpsV3.move_group(cfg, name, offset)
    local _, from = M3.find_group(cfg, name)
    local to = from and from + (tonumber(offset) or 0)
    if not from or to == from or to < 1 or to > #cfg.groups then return false end
    table.insert(cfg.groups, to, table.remove(cfg.groups, from))
    return true, false
end

-- 作用域:一个材质可以属于几个状态组,重叠部分由靠后的组覆盖(见 TransformManager.resolve_v3)
function OpsV3.scope_add(cfg, group, slot, mat)
    local g = M3.find_group(cfg, group)
    if not g or type(slot) ~= "string" or type(mat) ~= "string" then return false end
    local key = M3.key_of(slot, mat)
    for _, k in ipairs(g.scope) do if k == key then return false end end
    table.insert(g.scope, key)
    return true, false
end

-- 移出作用域时,各选项里这个材质的设置一起删掉
function OpsV3.scope_remove(cfg, group, slot, mat)
    local g = M3.find_group(cfg, group)
    if not g then return false end
    local key = M3.key_of(slot, mat)
    for i, k in ipairs(g.scope) do
        if k == key then
            table.remove(g.scope, i)
            for _, opt in pairs(g.options) do
                if type(opt[slot]) == "table" and type(opt[slot].materials) == "table" then
                    opt[slot].materials[mat] = nil
                    if next(opt[slot].materials) == nil then opt[slot] = nil end
                end
            end
            return true, true
        end
    end
    return false
end

-- 批量改作用域(编辑范围的全选 / 清空):add / remove 是 { {slot=, material=}, ... }
function OpsV3.scope_set(cfg, group, add, remove)
    if not M3.find_group(cfg, group) then return false end
    local changed, reapply = false, false
    for _, m in ipairs(type(add) == "table" and add or {}) do
        if type(m) == "table" and OpsV3.scope_add(cfg, group, m.slot, m.material) then changed = true end
    end
    for _, m in ipairs(type(remove) == "table" and remove or {}) do
        if type(m) == "table" then
            local c, r = OpsV3.scope_remove(cfg, group, m.slot, m.material)
            if c then changed = true end
            if r then reapply = true end
        end
    end
    return changed, reapply
end

-- ============================================================ 状态组的选项
local function group_layer(cfg, group)
    local g = M3.find_group(cfg, group)
    if not g then return nil end
    -- Ops 的预设函数认 presets / order / active 三个字段
    return g, setmetatable({}, {
        __index = function(_, k) if k == "presets" then return g.options end return g[k] end,
        __newindex = function(_, k, v) if k == "presets" then g.options = v else g[k] = v end end,
    })
end

-- 新建的选项是空的(全部"不管"),建完立刻设为手动选择
function OpsV3.new_option(cfg, group, name)
    local g = M3.find_group(cfg, group)
    if not g then return false end
    if name == nil then
        local n = 1
        while g.options[tostring(n)] do n = n + 1 end
        name = tostring(n)
    end
    if not valid_name(name) or g.options[name] then return false end
    g.options[name] = {}
    table.insert(g.order, name)
    g.active = name
    return true, true, name
end

function OpsV3.duplicate_option(cfg, group, name)
    local _, layer = group_layer(cfg, group)
    if not layer then return false end
    return Ops.duplicate_preset(layer, name)
end

function OpsV3.rename_option(cfg, group, old, new)
    local _, layer = group_layer(cfg, group)
    if not layer or not Ops.rename_preset(layer, old, new) then return false end
    for _, st in ipairs(cfg.conditions.states) do
        for _, t in ipairs(st.targets) do
            if t.group == group and t.option == old then t.option = new end
        end
    end
    return true, false
end

function OpsV3.delete_option(cfg, group, name)
    local _, layer = group_layer(cfg, group)
    if not layer then return false end
    return Ops.delete_preset(layer, name)
end

function OpsV3.move_option(cfg, group, name, offset)
    local _, layer = group_layer(cfg, group)
    if not layer then return false end
    local ok = Ops.move_preset(layer, name, offset)
    return ok, false
end

-- 选项里的单个材质:value = "none"(不管)/ "off" / "on"。只能写作用域里的材质
function OpsV3.set_option_material(cfg, group, option, slot, mat, value)
    local g = M3.find_group(cfg, group)
    if not g or not g.options[option] or type(slot) ~= "string" or type(mat) ~= "string" then return false end
    local key = M3.key_of(slot, mat)
    local inside = false
    for _, k in ipairs(g.scope) do if k == key then inside = true; break end end
    if not inside then return false end
    local ok = Ops.set_material(g.options[option], slot, mat, value, false)
    if not ok then return false end
    local data = g.options[option][slot]
    if data and next(data.materials) == nil then g.options[option][slot] = nil end
    return true, true
end

-- ============================================================ 模型高度
-- layer:"base" 或状态组名;option:预设 / 选项名;cm = nil 清除(这一层不管高度)。
-- 改了要重写:高度每帧由应用循环按解算结果交给 HeightFix
function OpsV3.set_height(cfg, layer, option, cm)
    local holder, names
    if layer == "base" then
        holder, names = cfg.base, cfg.base.presets
    else
        local g = M3.find_group(cfg, layer)
        if not g then return false end
        holder, names = g, g.options
    end
    if type(option) ~= "string" or not names[option] then return false end
    if type(holder.heights) ~= "table" then holder.heights = {} end
    local v = nil
    if cm ~= nil then
        v = M3.clamp_height(cm)
        if v == nil then return false end
    end
    if holder.heights[option] == v then return false end
    holder.heights[option] = v
    return true, true
end

-- 全局覆盖(快速切换页):enabled / cm 给哪个改哪个,另一个保持。关掉时保留数值,下次打开接着用
function OpsV3.set_height_override(cfg, enabled, cm)
    local cur = type(cfg.height_override) == "table" and cfg.height_override or { enabled = false, cm = 0 }
    local nxt = { enabled = cur.enabled == true, cm = cur.cm or 0 }
    if enabled ~= nil then
        if type(enabled) ~= "boolean" then return false end
        nxt.enabled = enabled
    end
    if cm ~= nil then
        local v = M3.clamp_height(cm)
        if v == nil then return false end
        nxt.cm = v
    end
    if type(cfg.height_override) == "table" and nxt.enabled == cur.enabled and nxt.cm == cur.cm then return false end
    cfg.height_override = nxt
    return true, true
end

-- ============================================================ 调色方案(子预设)
-- 方案本身的结构同 cfg.palette(见 Palette.lua);由整套造型的预设、状态组的选项、条件状态引用。
local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deep_copy(x) end
    return o
end

-- from:nil = 空方案;"" = 复制常驻调色;方案名 = 复制那个方案。返回 changed, reapply, 新名字
function OpsV3.new_palette(cfg, name, from)
    if not M3.valid_palette_name(name) then return false end
    cfg.palettes = type(cfg.palettes) == "table" and cfg.palettes or {}
    if cfg.palettes[name] then return false end
    local src = {}
    if from == "" then src = deep_copy(cfg.palette or {})
    elseif type(from) == "string" then
        if not cfg.palettes[from] then return false end
        src = deep_copy(cfg.palettes[from])
    end
    cfg.palettes[name] = src
    cfg.palette_order = type(cfg.palette_order) == "table" and cfg.palette_order or {}
    table.insert(cfg.palette_order, name)
    -- 新建的方案直接选中(选中就生效)
    cfg.palette_active = name
    return true, true, name
end

-- 选中一个方案(选中就生效);"" / nil = 只用常驻调色
function OpsV3.set_palette_active(cfg, name)
    local v = (name ~= "" and name) or nil
    if v ~= nil and (type(cfg.palettes) ~= "table" or not cfg.palettes[v]) then return false end
    if cfg.palette_active == v then return false end
    cfg.palette_active = v
    return true, true
end

-- 改名连带改掉所有引用
function OpsV3.rename_palette(cfg, old, new)
    local schemes = cfg.palettes
    if type(schemes) ~= "table" or not schemes[old] or not M3.valid_palette_name(new) or schemes[new] then return false end
    schemes[new], schemes[old] = schemes[old], nil
    if cfg.palette_active == old then cfg.palette_active = new end
    for i, n in ipairs(cfg.palette_order or {}) do if n == old then cfg.palette_order[i] = new end end
    local function fix(refs)
        for k, v in pairs(type(refs) == "table" and refs or {}) do if v == old then refs[k] = new end end
    end
    fix(cfg.base.palettes)
    for _, g in ipairs(cfg.groups) do fix(g.palettes) end
    for _, st in ipairs(cfg.conditions.states) do if st.palette == old then st.palette = new end end
    return true, false
end

-- 删除后引用保留,显示为「引用失效」(同删除整套造型 / 状态组);调用方先留还原点
function OpsV3.delete_palette(cfg, name)
    local schemes = cfg.palettes
    if type(schemes) ~= "table" or not schemes[name] then return false end
    schemes[name] = nil
    if cfg.palette_active == name then cfg.palette_active = nil end
    for i, n in ipairs(cfg.palette_order or {}) do
        if n == name then table.remove(cfg.palette_order, i); break end
    end
    if next(schemes) == nil then cfg.palettes, cfg.palette_order = nil, nil end
    return true, true
end

local function scheme_ok(cfg, scheme)
    return scheme == nil or scheme == "" or (type(scheme) == "string" and type(cfg.palettes) == "table" and cfg.palettes[scheme] ~= nil)
end

-- 整套造型的预设 / 状态组的选项引用哪个方案。layer:"base" 或状态组名;scheme = nil / "" 取消引用
function OpsV3.set_palette_ref(cfg, layer, option, scheme)
    local holder, names
    if layer == "base" then
        holder, names = cfg.base, cfg.base.presets
    else
        local g = M3.find_group(cfg, layer)
        if not g then return false end
        holder, names = g, g.options
    end
    if type(option) ~= "string" or not names[option] or not scheme_ok(cfg, scheme) then return false end
    local v = (scheme ~= "" and scheme) or nil
    local refs = type(holder.palettes) == "table" and holder.palettes or {}
    if refs[option] == v then return false end
    refs[option] = v
    holder.palettes = next(refs) and refs or nil
    return true, true
end

function OpsV3.set_state_palette(cfg, i, scheme)
    local st = cfg.conditions.states[tonumber(i) or -1]
    if not st or not scheme_ok(cfg, scheme) then return false end
    local v = (scheme ~= "" and scheme) or nil
    if st.palette == v then return false end
    st.palette = v
    return true, true
end

-- ============================================================ 条件状态
local function state_at(cfg, i)
    return cfg.conditions.states[tonumber(i) or -1]
end

function OpsV3.new_state(cfg, name)
    if not valid_name(name) then return false end
    table.insert(cfg.conditions.states, M3.new_state(name))
    return true, false, #cfg.conditions.states
end

function OpsV3.delete_state(cfg, i)
    if not state_at(cfg, i) then return false end
    table.remove(cfg.conditions.states, tonumber(i))
    return true, true
end

-- 拖动 / 上移下移:把第 from 个移到第 to 个的位置
function OpsV3.move_state(cfg, from, to)
    local states = cfg.conditions.states
    from, to = tonumber(from), tonumber(to)
    if not from or not to or not states[from] or to < 1 or to > #states or from == to then return false end
    table.insert(states, to, table.remove(states, from))
    return true, true
end

function OpsV3.rename_state(cfg, i, name)
    local st = state_at(cfg, i)
    if not st or not valid_name(name) or st.name == name then return false end
    st.name = name
    return true, false
end

-- 简单字段:enabled / exclusive(布尔)、logic("AND" / "OR")、hold / fade_in / fade_out(秒)
local LIMITS = { hold = 3600, fade_in = 30, fade_out = 30 }
function OpsV3.set_state_field(cfg, i, field, value)
    local st = state_at(cfg, i)
    if not st then return false end
    if field == "enabled" or field == "exclusive" then
        if type(value) ~= "boolean" or st[field] == value then return false end
        st[field] = value
        return true, true
    elseif field == "logic" then
        if (value ~= "AND" and value ~= "OR") or st.logic == value then return false end
        st.logic = value
        return true, true
    elseif LIMITS[field] then
        local v = tonumber(value)
        if not v then return false end
        v = math.max(0, math.min(LIMITS[field], math.floor(v * 10 + 0.5) / 10))
        if st[field] == v then return false end
        st[field] = v
        return true, field == "hold"
    end
    return false
end

-- 按血量驱动:hp = nil 关闭;{ upper, lower, invert } 打开 / 修改
function OpsV3.set_state_hp(cfg, i, hp)
    local st = state_at(cfg, i)
    if not st then return false end
    if hp == nil then
        if st.hp == nil then return false end
        st.hp = nil
        return true, true
    end
    if type(hp) ~= "table" then return false end
    local function clamp(v, d) v = tonumber(v) or d; return math.max(0, math.min(100, math.floor(v * 10 + 0.5) / 10)) end
    st.hp = { upper = clamp(hp.upper, 100), lower = clamp(hp.lower, 0), invert = hp.invert == true }
    return true, true
end

-- 整套造型目标:name = nil / "" 表示不切换
function OpsV3.set_state_base(cfg, i, name)
    local st = state_at(cfg, i)
    if not st then return false end
    if name == nil or name == "" then
        if st.base == nil then return false end
        st.base = nil
        return true, true
    end
    if not cfg.base.presets[name] or st.base == name then return false end
    st.base = name
    return true, true
end

-- 状态组目标:一组只能有一条;同一组再设一次就改选项
function OpsV3.set_state_target(cfg, i, group, option)
    local st = state_at(cfg, i)
    local g = M3.find_group(cfg, group)
    if not st or not g or not g.options[option] then return false end
    for _, t in ipairs(st.targets) do
        if t.group == group then
            if t.option == option then return false end
            t.option = option
            return true, true
        end
    end
    table.insert(st.targets, { group = group, option = option })
    return true, true
end

-- 把第 j 条目标换成另一个组(界面上的"组"下拉框);选项取那个组的第一个
function OpsV3.change_target_group(cfg, i, j, group)
    local st = state_at(cfg, i)
    local g = M3.find_group(cfg, group)
    j = tonumber(j)
    if not st or not g or not j or not st.targets[j] or st.targets[j].group == group then return false end
    for k, t in ipairs(st.targets) do
        if k ~= j and t.group == group then return false end
    end
    st.targets[j] = { group = group, option = g.order[1] or "" }
    return true, true
end

function OpsV3.remove_state_target(cfg, i, j)
    local st = state_at(cfg, i)
    j = tonumber(j)
    if not st or not j or not st.targets[j] then return false end
    table.remove(st.targets, j)
    return true, true
end

-- 条件:cond 由 Ops.make_condition 构造并校验
function OpsV3.add_condition(cfg, i, cond)
    local st = state_at(cfg, i)
    if not st or type(cond) ~= "table" or type(cond.type) ~= "string" then return false end
    table.insert(st.conditions, cond)
    return true, true
end

function OpsV3.set_condition(cfg, i, ci, cond)
    local st = state_at(cfg, i)
    ci = tonumber(ci)
    if not st or not ci or not st.conditions[ci] or type(cond) ~= "table" or type(cond.type) ~= "string" then return false end
    st.conditions[ci] = cond
    return true, true
end

function OpsV3.delete_condition(cfg, i, ci)
    local st = state_at(cfg, i)
    ci = tonumber(ci)
    if not st or not ci or not st.conditions[ci] then return false end
    table.remove(st.conditions, ci)
    return true, true
end

return OpsV3
