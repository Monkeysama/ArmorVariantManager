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

-- layer:"base" 或状态组名;option:"" = （无）(整套造型也允许,= 全启用兜底)。
-- 复选组:option = 选项名时切换这个选项的开关,"" 时关掉全部选项
function OpsV3.set_manual(cfg, layer, option)
    if type(option) ~= "string" then return false end
    if layer == "base" then return Ops.set_active(cfg.base, option) end
    local g = M3.find_group(cfg, layer)
    if not g or (option ~= "" and not g.options[option]) then return false end
    if M3.is_multi(g) then
        if option == "" then
            if not (g.actives and g.actives[1]) then return false end
            g.actives = {}
            return true, true
        end
        return OpsV3.set_option_on(cfg, layer, option, not M3.is_on(g, option))
    end
    if g.active == option then return false end
    g.active = option
    return true, true
end

-- 复选组:打开 / 关闭一个选项(单选组拒绝)
function OpsV3.set_option_on(cfg, group, option, on)
    local g = M3.find_group(cfg, group)
    if not M3.is_multi(g) or type(option) ~= "string" or not g.options[option] then return false end
    on = on == true
    if M3.is_on(g, option) == on then return false end
    local list = {}
    for _, n in ipairs(g.actives or {}) do if n ~= option then list[#list + 1] = n end end
    if on then list[#list + 1] = option end
    g.actives = M3.clean_actives(list, g)
    return true, true
end

-- 选择方式:on = 复选。单选改复选时原来选中的选项保持打开;复选改单选时只保留顺序最靠后的已选选项
-- (它本来就是叠加结果里说了算的那个)。复选组没有轮换快捷键,改成复选时作废
function OpsV3.set_group_multi(cfg, group, on)
    local g = M3.find_group(cfg, group)
    if not g then return false end
    on = on == true
    if M3.is_multi(g) == on then return false end
    if on then
        g.multi = true
        g.actives = (g.active ~= "" and g.options[g.active]) and { g.active } or {}
        g.active = ""
    else
        local list = M3.clean_actives(g.actives, g)
        g.multi, g.actives = nil, nil
        g.active = list[#list] or ""
    end
    M3.clean_hotkey_table(cfg)
    return true, true
end

-- ============================================================ 快捷键(Alt + 数字,见 ModelV3 的 hotkeys)
-- 改名:单项绑定里的名字、轮换的 skip 里的名字跟着改。kind = "base" / "group" / "palette";group 只在 kind = group 时
local function hotkeys_rename_item(cfg, kind, group, old, new)
    for _, b in pairs(type(cfg.hotkeys) == "table" and cfg.hotkeys or {}) do
        if b.kind == kind and (kind ~= "group" or b.group == group) then
            if kind == "palette" then
                if b.scheme == old then b.scheme = new end
            elseif b.option == old then b.option = new end
            for i, n in ipairs(b.skip or {}) do if n == old then b.skip[i] = new end end
        end
    end
end

-- target = { kind, group?, option? / scheme? }(没有 option / scheme = 轮换整个结构);nil = 清掉这个键。
-- 这个设定原来占着别的键就移过来;绑轮换时清掉同一结构下的单项键;结构已有轮换键时不能给单项绑键。
-- 只是绑定,不用重写
function OpsV3.set_hotkey(cfg, digit, target)
    local d = math.tointeger(tonumber(digit))
    if not d or d < 0 or d > 9 then return false end
    local key = tostring(d)
    local keys = type(cfg.hotkeys) == "table" and cfg.hotkeys or {}
    if target == nil then
        if keys[key] == nil then return false end
        keys[key] = nil
        cfg.hotkeys = next(keys) and keys or nil
        return true, false
    end
    if type(target) ~= "table" then return false end
    local b = { kind = target.kind }
    if b.kind == "group" then b.group = target.group end
    if b.kind == "palette" then b.scheme = target.scheme else b.option = target.option end
    if (b.kind ~= "base" and b.kind ~= "group" and b.kind ~= "palette") or (b.kind == "group" and type(b.group) ~= "string") then return false end
    if b.option ~= nil and type(b.option) ~= "string" or b.scheme ~= nil and type(b.scheme) ~= "string" then return false end
    if not M3.hotkey_valid(cfg, b) then return false end
    local structure, target_key, cycle = M3.hotkey_structure(b), M3.hotkey_target(b), M3.hotkey_is_cycle(b)
    local cur = keys[key]
    if cur and M3.hotkey_target(cur) == target_key then return false end
    for k, x in pairs(keys) do
        if M3.hotkey_structure(x) == structure then
            if M3.hotkey_target(x) == target_key then
                if cycle then b.skip = x.skip end   -- 轮换键换到别的数字:跳过的项保留
                keys[k] = nil
            elseif cycle then
                keys[k] = nil                        -- 绑轮换:同一结构的单项键作废
            elseif M3.hotkey_is_cycle(x) then
                return false                         -- 结构已有轮换键:单项不能绑
            end
        end
    end
    keys[key] = b
    cfg.hotkeys = keys
    return true, false
end

-- 轮换里要不要包括 item("" = 状态组的「（无）」/ 调色的「初始」)。structure = { kind, group? }
function OpsV3.set_hotkey_skip(cfg, structure, item, included)
    if type(structure) ~= "table" or type(item) ~= "string" then return false end
    local want = M3.hotkey_structure(structure)
    for _, b in pairs(type(cfg.hotkeys) == "table" and cfg.hotkeys or {}) do
        if M3.hotkey_is_cycle(b) and M3.hotkey_structure(b) == want then
            local ok = false
            for _, n in ipairs(M3.hotkey_items(cfg, b) or {}) do if n == item then ok = true end end
            if not ok then return false end
            local skip, at = b.skip or {}, nil
            for i, n in ipairs(skip) do if n == item then at = i end end
            if included == true then
                if not at then return false end
                table.remove(skip, at)
            else
                if at then return false end
                skip[#skip + 1] = item
            end
            b.skip = next(skip) and skip or nil
            return true, false
        end
    end
    return false
end

-- ============================================================ 整套造型(只补牵动引用的)
function OpsV3.rename_base(cfg, old, new)
    local ok = Ops.rename_preset(cfg.base, old, new)
    if not ok then return false end
    for _, st in ipairs(cfg.conditions.states) do
        if st.base == old then st.base = new end
    end
    for _, g in ipairs(cfg.groups) do
        for i, n in ipairs(type(g.bases) == "table" and g.bases or {}) do if n == old then g.bases[i] = new end end
    end
    hotkeys_rename_item(cfg, "base", nil, old, new)
    return true, false
end

-- 删除后指向它的条件状态保留引用,显示为"引用失效"
function OpsV3.delete_base(cfg, name)
    local ok, reapply = Ops.delete_preset(cfg.base, name)
    if ok then
        M3.clean_hotkey_table(cfg)   -- 指向它的快捷键作废
        -- 造型归属里去掉它;列表删空后回到「全部」
        for _, g in ipairs(cfg.groups) do g.bases = M3.clean_bases(g.bases, cfg.base.presets) end
    end
    return ok, reapply
end

-- ============================================================ 状态组
function OpsV3.new_group(cfg, name)
    if not valid_name(name) or M3.find_group(cfg, name) then return false end
    table.insert(cfg.groups, { name = name, options = {}, order = {}, active = "" })
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
    for _, b in pairs(type(cfg.hotkeys) == "table" and cfg.hotkeys or {}) do
        if b.kind == "group" and b.group == old then b.group = new end
    end
    return true, false
end

function OpsV3.delete_group(cfg, name)
    local _, i = M3.find_group(cfg, name)
    if not i then return false end
    table.remove(cfg.groups, i)
    M3.clean_hotkey_table(cfg)
    return true, true
end

-- 造型归属:list = 整套造型预设名的列表;空表 / nil = 全部。不存在的名字丢掉
function OpsV3.set_group_bases(cfg, name, list)
    local g = M3.find_group(cfg, name)
    if not g then return false end
    local v = M3.clean_bases(type(list) == "table" and list or nil, cfg.base.presets)
    local old = g.bases or {}
    local same = #old == #(v or {})
    if same then for i, n in ipairs(v or {}) do if old[i] ~= n then same = false end end end
    if same then return false end
    g.bases = v
    return true, false
end

function OpsV3.move_group(cfg, name, offset)
    local _, from = M3.find_group(cfg, name)
    local to = from and from + (tonumber(offset) or 0)
    if not from or to == from or to < 1 or to > #cfg.groups then return false end
    table.insert(cfg.groups, to, table.remove(cfg.groups, from))
    return true, false
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
    if M3.is_multi(g) then
        local list = g.actives or {}
        list[#list + 1] = name
        g.actives = M3.clean_actives(list, g)
    else
        g.active = name
    end
    return true, true, name
end

function OpsV3.duplicate_option(cfg, group, name)
    local g, layer = group_layer(cfg, group)
    if not layer then return false end
    local ok, reapply, newn = Ops.duplicate_preset(layer, name)
    -- 复选组:复制出的选项和新建的一样直接打开(Ops 按单选写了 active,改回来)
    if ok and M3.is_multi(g) then
        g.active = ""
        local list = g.actives or {}
        list[#list + 1] = newn
        g.actives = M3.clean_actives(list, g)
    end
    return ok, reapply, newn
end

function OpsV3.rename_option(cfg, group, old, new)
    local _, layer = group_layer(cfg, group)
    if not layer or not Ops.rename_preset(layer, old, new) then return false end
    local g = M3.find_group(cfg, group)
    for i, n in ipairs(g.actives or {}) do if n == old then g.actives[i] = new end end
    for _, st in ipairs(cfg.conditions.states) do
        for _, t in ipairs(st.targets) do
            if t.group == group and t.option == old then t.option = new end
        end
    end
    hotkeys_rename_item(cfg, "group", group, old, new)
    return true, false
end

function OpsV3.delete_option(cfg, group, name)
    local _, layer = group_layer(cfg, group)
    if not layer then return false end
    local ok, reapply = Ops.delete_preset(layer, name)
    if ok then
        M3.clean_hotkey_table(cfg)
        local g = M3.find_group(cfg, group)
        if g.actives then g.actives = M3.clean_actives(g.actives, g) end
    end
    return ok, reapply
end

function OpsV3.move_option(cfg, group, name, offset)
    local _, layer = group_layer(cfg, group)
    if not layer then return false end
    local ok = Ops.move_preset(layer, name, offset)
    return ok, false
end

-- 选项里的单个材质:value = "none"(不管)/ "off" / "on"。任何材质都能写;
-- 几个组写同一个材质时靠后的组说了算(见 TransformManager.resolve_v3)
function OpsV3.set_option_material(cfg, group, option, slot, mat, value)
    local g = M3.find_group(cfg, group)
    if not g or not g.options[option] or type(slot) ~= "string" or type(mat) ~= "string" then return false end
    local ok = Ops.set_material(g.options[option], slot, mat, value, false)
    if not ok then return false end
    local data = g.options[option][slot]
    if data and next(data.materials) == nil then g.options[option][slot] = nil end
    return true, true
end

-- 一个部位的材质批量设置。layer = "base" 或状态组名;items = { { slot, material }, ... }(界面上这一段列出的材质);
-- op:none(全部「—」,只有状态组)/ off / on / invert。
-- 反选:开 ↔ 关;整套造型没存的按开算(和显示一致),状态组的「—」保持不动。
-- 一次只存一次盘、只重新应用一次。返回 changed, reapply
function OpsV3.bulk_materials(cfg, layer, option, items, op)
    local holder, is_base
    if layer == "base" then
        holder, is_base = cfg.base.presets[option], true
    else
        local g = M3.find_group(cfg, layer)
        holder = g and g.options[option]
    end
    if type(holder) ~= "table" or type(items) ~= "table" then return false end
    if op ~= "off" and op ~= "on" and op ~= "invert" and not (op == "none" and not is_base) then return false end
    local changed, touched = false, {}
    local TRI = { [true] = "on", [false] = "off" }
    for _, it in ipairs(items) do
        local slot = type(it) == "table" and it.slot or nil
        local mat = type(it) == "table" and it.material or nil
        if type(slot) == "string" and type(mat) == "string" then
            local data = holder[slot]
            local cur = nil    -- 没有这个部位 / 没存这个材质 = nil(不能用 and 链,部位不存在时会得到 false)
            if type(data) == "table" and type(data.materials) == "table" then
                local v = data.materials[mat]
                if v == true or v == false then cur = v end
            end
            local want
            if op == "on" then want = true
            elseif op == "off" then want = false
            elseif op == "invert" then
                if is_base then want = cur == false
                elseif cur ~= nil then want = not cur end    -- 「—」保持不动(want 留 nil)
            end
            if cur ~= want then
                if is_base then Ops.set_material(holder, slot, mat, want, true)
                else Ops.set_material(holder, slot, mat, want == nil and "none" or TRI[want], false); touched[slot] = true end
                changed = true
            end
        end
    end
    for slot in pairs(touched) do
        local data = holder[slot]
        if data and next(data.materials) == nil then holder[slot] = nil end
    end
    return changed, changed
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
-- 方案 = 一份覆盖表(见 Palette.lua),叠在初始(mdf2 原值)上;由整套造型的预设、状态组的选项、条件状态引用。
local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deep_copy(x) end
    return o
end

-- from:nil = 空方案(= 初始);方案名 = 复制那个方案。返回 changed, reapply, 新名字
function OpsV3.new_palette(cfg, name, from)
    if not M3.valid_palette_name(name) then return false end
    cfg.palettes = type(cfg.palettes) == "table" and cfg.palettes or {}
    if cfg.palettes[name] then return false end
    local src = {}
    if type(from) == "string" then
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
-- 没有选中方案(选着「初始」)时自动新建一个空方案并选中,用来接住在初始上做的修改。返回方案名
function OpsV3.ensure_palette(cfg, base_name)
    if type(cfg.palette_active) == "string" and type(cfg.palettes) == "table" and cfg.palettes[cfg.palette_active] then
        return cfg.palette_active
    end
    local stem = M3.valid_palette_name(base_name) and base_name or "1"
    local name, i = stem .. " 1", 2
    while type(cfg.palettes) == "table" and cfg.palettes[name] do name = stem .. " " .. i; i = i + 1 end
    OpsV3.new_palette(cfg, name)
    return name
end

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
    hotkeys_rename_item(cfg, "palette", nil, old, new)
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
    M3.clean_hotkey_table(cfg)
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

-- ============================================================ 溶解预设引用(预设在全局库,见 DissolveStyles)
-- 整套造型的预设 / 状态组的选项引用一个溶解预设:切到它时这次溶解用这个预设。preset = "" 清除。
-- 不检查名字是否存在(全局库可能在别处改过),解算时不存在就退回默认
function OpsV3.set_dissolve_ref(cfg, layer, option, preset)
    local holder, names
    if layer == "base" then
        holder, names = cfg.base, cfg.base.presets
    else
        local g = M3.find_group(cfg, layer)
        if not g then return false end
        holder, names = g, g.options
    end
    if type(option) ~= "string" or not names[option] or type(preset) ~= "string" then return false end
    local v = preset ~= "" and preset or nil
    local refs = type(holder.dissolves) == "table" and holder.dissolves or {}
    if refs[option] == v then return false end
    refs[option] = v
    holder.dissolves = next(refs) and refs or nil
    return true, false
end

function OpsV3.set_state_dissolve(cfg, i, preset)
    local st = cfg.conditions.states[tonumber(i) or -1]
    if not st or type(preset) ~= "string" then return false end
    local v = preset ~= "" and preset or nil
    if st.dissolve == v then return false end
    st.dissolve = v
    return true, false
end

-- ============================================================ SKS 键组引用(见 ModelV3 文件头、SksLink.lua)
-- 整套造型的预设 / 状态组的选项指定 SKS 某个键组用哪个选项。value:选项名;0 = 不选任何选项;
-- nil / "" = 这一层不写这个键组。不检查 SKS 里是否存在(SKS 可能没装、配置可能换了),发送时不存在就跳过
function OpsV3.set_sks_ref(cfg, layer, option, group, value)
    local holder, names
    if layer == "base" then
        holder, names = cfg.base, cfg.base.presets
    else
        local g = M3.find_group(cfg, layer)
        if not g then return false end
        holder, names = g, g.options
    end
    if type(option) ~= "string" or not names[option] or type(group) ~= "string" or group == "" then return false end
    if value == "" then value = nil end
    if value ~= nil and not M3.sks_value_ok(value) then return false end
    local refs = type(holder.sks) == "table" and holder.sks or {}
    local map = type(refs[option]) == "table" and refs[option] or {}
    if map[group] == value then return false end
    map[group] = value
    refs[option] = next(map) and map or nil
    holder.sks = next(refs) and refs or nil
    return true, false
end

-- 全局库里改名后,一份角色配置里的引用跟着改;返回有没有改动
function OpsV3.rename_dissolve_refs(cfg, old, new)
    local changed = false
    local function fix(refs)
        for k, v in pairs(type(refs) == "table" and refs or {}) do if v == old then refs[k] = new; changed = true end end
    end
    fix(type(cfg.base) == "table" and cfg.base.dissolves)
    for _, g in ipairs(type(cfg.groups) == "table" and cfg.groups or {}) do fix(g.dissolves) end
    local states = type(cfg.conditions) == "table" and cfg.conditions.states or {}
    for _, st in ipairs(states) do if st.dissolve == old then st.dissolve = new; changed = true end end
    return changed
end

-- 武器显示:mode = "stowed" / "all";nil / "" 表示不管(交给全局「隐藏收纳武器」)
function OpsV3.set_state_weapons(cfg, i, mode)
    local st = cfg.conditions.states[tonumber(i) or -1]
    if not st then return false end
    local v = (mode ~= nil and mode ~= "") and mode or nil
    if v ~= nil and not M3.WEAPON_MODES[v] then return false end
    if st.weapons == v then return false end
    st.weapons = v
    return true, false
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
