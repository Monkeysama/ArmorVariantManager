-- RE4 配置的共用操作:ImGui 面板和 REFF 网页都调用这里,保证两边改配置的语义一致。
--
-- 只改传进来的表,不读写文件、不碰引擎。返回 changed, reapply:
--   changed  这次调用改了配置(调用方据此 save_config)
--   reapply  需要重新把结果写到模型上(调用方据此 request_reapply)
-- 溶解时长、血量驱动的上下限这类字段只影响下一次过渡的参数,不改变当前该显示哪个状态,
-- 所以只存盘不重写(和面板上一直以来的行为一致)。
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")

local Ops = {}

-- 和面板一直以来的写法一致(先乘再除),避免 1.2000000000000002 这种值写进配置
local function round1(value) return math.floor(value * 10 + 0.5) / 10 end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

-- 一个状态(预设)最多一条规则;规则的优先级就是状态在列表里的顺序。
function Ops.rule_index(layer, preset)
    for i, rule in ipairs(layer.rules or {}) do
        if rule.preset == preset then return i end
    end
    return nil
end

function Ops.rule_for(layer, preset)
    local i = Ops.rule_index(layer, preset)
    return i and layer.rules[i] or nil, i
end

-- 手动选择。"" = (无):这一层不发言,听下面的。
function Ops.set_active(layer, name)
    if name ~= "" and not (layer.presets and layer.presets[name]) then return false end
    layer.active = name
    return true, true
end

-- 「自动」:关掉后规则暂停,手动选择生效。
function Ops.set_auto(layer, on)
    layer.auto = on == true
    return true, true
end

function Ops.delete_rule(layer, index)
    if not (layer.rules and layer.rules[index]) then return false end
    table.remove(layer.rules, index)
    return true, true
end

-- 删掉最后一个条件 = 这条规则不该继续存在(空条件永远不命中);
-- 血量驱动的规则不靠条件,删光条件也保留。
function Ops.delete_condition(layer, preset, index)
    local rule, rule_idx = Ops.rule_for(layer, preset)
    local conds = rule and rule.conditions
    if not (conds and conds[index]) then return false end
    table.remove(conds, index)
    if #conds == 0 and rule.dissolve_hp_driven ~= true then table.remove(layer.rules, rule_idx) end
    return true, true
end

-- 「关系」(且/或)是整条规则共用一个,加条件时一并改它。
-- 这个状态还没有规则时,加第一个条件才建。
function Ops.add_condition(layer, preset, cond, logic)
    if not (cond and layer.presets and layer.presets[preset]) then return false end
    logic = (logic == "OR") and "OR" or "AND"
    local rule = Ops.rule_for(layer, preset)
    if not rule then
        layer.rules = layer.rules or {}
        table.insert(layer.rules, { conditions = { cond }, logic = logic, preset = preset })
    else
        rule.conditions = rule.conditions or {}
        table.insert(rule.conditions, cond)
        rule.logic = logic
    end
    return true, true
end

-- 按条件定义把界面传来的值整理成规则里存的条件;值不合法时返回 nil。
-- 枚举的可选值随游戏数据变化(血量等级档位从引擎枚举反射),所以要传 context。
function Ops.make_condition(def, op, value, context, lang)
    if not def then return nil end
    if def.kind == "bool" then
        return { type = def.id, value = value == true }
    end
    if def.kind == "enum" then
        op = op or "=="
        local valid_op = false
        for _, o in ipairs(Registry.ENUM_OPS) do if o == op then valid_op = true end end
        if not valid_op then return nil end
        for _, o in ipairs(def.options and def.options(context, lang) or {}) do
            if o.value == value or tonumber(o.value) == tonumber(value) then
                return { type = def.id, op = op, value = o.value }
            end
        end
        return nil
    end
    local num = tonumber(value)
    if not num then return nil end
    op = op or "<="
    for _, o in ipairs(Registry.NUM_OPS) do
        if o == op then return { type = def.id, op = op, value = num } end
    end
    return nil
end

-- 命中后保持多少秒。0 / 负数 / 非数字一律当"不保持"。
function Ops.set_hold(layer, preset, value)
    local rule = Ops.rule_for(layer, preset)
    if not rule then return false end
    local n = tonumber(value)
    rule.hold = (n and n > 0) and n or nil
    return true, true
end

-- 溶解过渡:进入 / 离开这个状态时按时长溶解。只作用于带 Dissolve_Rate 的溶解模板材质。
function Ops.set_dissolve(layer, preset, enabled)
    local rule = Ops.rule_for(layer, preset)
    if not rule then return false end
    rule.dissolve_enabled = enabled == true or nil
    if enabled == true then
        rule.dissolve_hide_time = rule.dissolve_hide_time or 0.5
        rule.dissolve_show_time = rule.dissolve_show_time or 0.5
    end
    return true, false
end

local DISSOLVE_TIMES = { dissolve_hide_time = true, dissolve_show_time = true }
function Ops.set_dissolve_time(layer, preset, field, value)
    local rule = Ops.rule_for(layer, preset)
    local n = tonumber(value)
    if not (rule and DISSOLVE_TIMES[field] and n) then return false end
    rule[field] = round1(clamp(n, 0, 10))
    return true, false
end

-- 按血量驱动:不看条件,溶解进度直接跟血量走。没有规则时建一条空条件的规则来挂;
-- 取消时,只为它建的空规则一并删掉(空条件永远不命中)。
function Ops.set_hp_driven(layer, preset, enabled)
    if not (layer.presets and layer.presets[preset]) then return false end
    local rule, rule_idx = Ops.rule_for(layer, preset)
    if enabled == true then
        if not rule then
            rule = { conditions = {}, logic = "AND", preset = preset }
            layer.rules = layer.rules or {}
            table.insert(layer.rules, rule)
        end
        rule.dissolve_hp_driven = true
        rule.dissolve_hp_upper = rule.dissolve_hp_upper or 100
        rule.dissolve_hp_lower = rule.dissolve_hp_lower or 0
    elseif rule then
        rule.dissolve_hp_driven = nil
        if #(rule.conditions or {}) == 0 then table.remove(layer.rules, rule_idx) end
    else
        return false
    end
    return true, true
end

local HP_BOUNDS = { dissolve_hp_upper = true, dissolve_hp_lower = true }
function Ops.set_hp_bound(layer, preset, field, value)
    local rule = Ops.rule_for(layer, preset)
    local n = tonumber(value)
    if not (rule and rule.dissolve_hp_driven == true and HP_BOUNDS[field] and n) then return false end
    rule[field] = math.floor(clamp(n, 0, 100) + 0.5)
    return true, false
end

-- 方向:默认"血量越低越接近此状态";反向 = 血量越高越接近。
function Ops.set_hp_invert(layer, preset, invert)
    local rule = Ops.rule_for(layer, preset)
    if not (rule and rule.dissolve_hp_driven == true) then return false end
    rule.dissolve_hp_invert = invert == true or nil
    return true, false
end

-- 全局设置。界面切换溶解时长按 0.1 秒取整,范围 0~30。
function Ops.set_global(global_config, id, value)
    if id == "language" then
        if value ~= "zh" and value ~= "en" then return false end
        global_config.language = value
    elseif id == "weapon_hide_storage" or id == "ui_dissolve_enabled" or id == "portrait_enabled" or id == "block_game_mouse"
        or id == "height_enabled" then
        global_config[id] = value == true
    elseif id == "portrait_distance" or id == "portrait_height" then
        local n = tonumber(value)
        if not n then return false end
        global_config[id] = id == "portrait_distance" and round1(clamp(n, 1.2, 8)) or round1(clamp(n, -1, 1))
    elseif id == "ui_dissolve_time" then
        local n = tonumber(value)
        if not n then return false end
        global_config.ui_dissolve_time = round1(clamp(n, 0, 30))
    else
        return false
    end
    return true
end

-- ============================================================
-- 预设 / 状态的编辑。整套造型与状态组共用这一组(层结构相同),
-- 材质的取值形态不同:整套造型是二值整份快照,状态组是三态稀疏表(不写 = 不管)。
-- 抓取当前外观(Utils.capture_*)要读引擎,由调用方算好传进来。
-- ============================================================

-- 层的初始形态。order = 状态的优先级顺序,靠前的优先。
function Ops.new_layer() return { presets = {}, active = "", rules = {}, order = {}, auto = true } end

local function order_index(layer, name)
    for i, n in ipairs(layer.order or {}) do
        if n == name then return i end
    end
    return nil
end

-- 新建:自动取名 1、2、3…,排在最后(优先级最低),建完立刻生效 ——
-- 编辑的必须是生效中的那个,否则改动会被 resolve 按别的预设盖掉。
function Ops.new_preset(layer, data)
    local n = 1
    while layer.presets[tostring(n)] do n = n + 1 end
    local name = tostring(n)
    layer.presets[name] = data or {}
    layer.order = layer.order or {}
    table.insert(layer.order, name)
    layer.active = name
    return true, true, name
end

-- 复制:后缀 _1 / _2…,插在源的紧后面(副本是源的变体,优先级也该紧邻),复制完直接生效。
function Ops.duplicate_preset(layer, name)
    local src = layer.presets[name]
    if not src then return false end
    local i, newn = 1, name .. "_1"
    while layer.presets[newn] do i = i + 1; newn = name .. "_" .. i end
    local dst = {}
    for slot, data in pairs(src) do
        if type(data) == "table" then
            dst[slot] = { materials = {} }
            for m, v in pairs(data.materials or {}) do dst[slot].materials[m] = v end
        end
    end
    layer.presets[newn] = dst
    -- v3 的模型高度(layer.heights,可能没有)跟着预设走
    if type(layer.heights) == "table" and layer.heights[name] then layer.heights[newn] = layer.heights[name] end
    local at = (order_index(layer, name) or #layer.order) + 1
    table.insert(layer.order, at, newn)
    layer.active = newn
    return true, true, newn
end

-- 改名要连带改掉引用旧名字的地方:order 就地换名(只删不加会被当成新名字补到末尾,
-- 改个名字优先级就变了)、手动选择、规则目标。名字为空或撞名时拒绝。
function Ops.rename_preset(layer, old, new)
    if type(new) ~= "string" or new == "" or old == new then return false end
    if not layer.presets[old] or layer.presets[new] then return false end
    layer.presets[new] = layer.presets[old]
    layer.presets[old] = nil
    if type(layer.heights) == "table" then layer.heights[new], layer.heights[old] = layer.heights[old], nil end
    local i = order_index(layer, old)
    if i then layer.order[i] = new end
    if layer.active == old then layer.active = new end
    for _, rule in ipairs(layer.rules or {}) do
        if rule.preset == old then rule.preset = new end
    end
    return true, false
end

-- 删除:不可逆,调用方先 snapshot_before_destructive 留一份。指向它的规则保留成孤儿,
-- 界面上看得见、删得掉(和一直以来的行为一致)。
function Ops.delete_preset(layer, name)
    if not layer.presets[name] then return false end
    layer.presets[name] = nil
    if type(layer.heights) == "table" then layer.heights[name] = nil end
    local i = order_index(layer, name)
    if i then table.remove(layer.order, i) end
    if layer.active == name then layer.active = "" end
    return true, true
end

-- 上移 / 下移 = 调优先级。顺序变了可能立刻换成另一个状态,所以要重写。
function Ops.move_preset(layer, name, offset)
    local from = order_index(layer, name)
    local to = from and from + (tonumber(offset) or 0)
    if not from or to == from or to < 1 or to > #layer.order then return false end
    table.insert(layer.order, to, table.remove(layer.order, from))
    return true, true
end

-- 用新抓的内容整份替换(「从当前模型重新抓取」)。调用方先留备份,并负责逐槛位保留对不上的部分。
function Ops.replace_preset(layer, name, data)
    if not layer.presets[name] or type(data) ~= "table" then return false end
    layer.presets[name] = data
    return true, true
end

local function slot_table(preset, slot)
    if type(preset[slot]) ~= "table" then preset[slot] = { materials = {} } end
    preset[slot].materials = preset[slot].materials or {}
    return preset[slot].materials
end

-- 单个材质。整套造型:true / false;状态组:"none"(不管,不写进表)/ "off" / "on"。
local TRI = { none = "none", off = false, on = true }
function Ops.set_material(preset, slot, material, value, is_base)
    if type(preset) ~= "table" or type(slot) ~= "string" or type(material) ~= "string" then return false end
    local materials = slot_table(preset, slot)
    if is_base then
        if type(value) ~= "boolean" then return false end
        materials[material] = value
    else
        local v = TRI[value]
        if v == nil then return false end
        if v == "none" then materials[material] = nil else materials[material] = v end
    end
    return true, true
end

-- 一个槛位的批量操作。names = 这个槛位当前的材质名(按引擎顺序),current = 名字 -> 当前显示状态。
--   整套造型:all_on / all_off / invert(按预设里存的值取反,没存的算开)
--   状态组:  claim(整块纳入:按当前显示状态写下每个材质 = 这个状态接管整个部位)/ release(全部释放)
function Ops.bulk_slot(preset, slot, op, names, current, is_base)
    if type(preset) ~= "table" or type(names) ~= "table" then return false end
    if is_base and (op == "all_on" or op == "all_off" or op == "invert") then
        local materials = slot_table(preset, slot)
        for _, n in ipairs(names) do
            if op == "invert" then materials[n] = not (materials[n] ~= false)
            else materials[n] = (op == "all_on") end
        end
    elseif not is_base and op == "claim" then
        local materials = slot_table(preset, slot)
        for _, n in ipairs(names) do
            local v = current and current[n]
            -- 读不到当前状态时按显示处理(同 capture_current_as_preset 的约定)。
            -- 不能写成 `type(v) == "boolean" and v or true`:v=false 时会算成 true
            if type(v) ~= "boolean" then v = true end
            materials[n] = v
        end
    elseif not is_base and op == "release" then
        if type(preset[slot]) == "table" then preset[slot].materials = {} end
    else
        return false
    end
    return true, true
end

-- 状态组的新建 / 改名 / 删除。新建时顺手带一份空状态并选中:
-- 绝大多数状态组就是个开关,只要一个状态。状态组名没有跨引用(规则在组内部),挪 key 就够。
function Ops.new_axis(config, name)
    if type(name) ~= "string" or name == "" or config.axes[name] then return false end
    local layer = Ops.new_layer()
    layer.presets["1"] = {}
    layer.order = { "1" }
    layer.active = "1"
    config.axes[name] = layer
    return true, true
end

function Ops.rename_axis(config, old, new)
    if type(new) ~= "string" or new == "" or old == new then return false end
    if not config.axes[old] or config.axes[new] then return false end
    config.axes[new] = config.axes[old]
    config.axes[old] = nil
    return true, false
end

function Ops.delete_axis(config, name)
    if not config.axes[name] then return false end
    config.axes[name] = nil
    return true, true
end

-- 护甲槛位直接照抄 body 的最终结果(护甲是 body 完整重导出时用)。角色级设置。
function Ops.set_armor_mirror(config, on)
    config.armor_mirrors_body = on == true
    return true, true
end

-- 材质备注:角色级,不属于任何预设。空字符串 = 删除备注。只影响显示,不需要重写。
function Ops.set_note(config, slot, material, text)
    if type(slot) ~= "string" or type(material) ~= "string" then return false end
    config.material_notes = config.material_notes or {}
    config.material_notes[slot] = config.material_notes[slot] or {}
    text = type(text) == "string" and text or ""
    config.material_notes[slot][material] = (text ~= "") and text or nil
    return true, false
end

return Ops
