-- 条件注册表。
--
-- 加一个新条件要做的事:
--   * 布尔类(PlayerBaseContext 上的 get_IsXxx 之类)——往 PlayerBools.lua 的表里加一行,
--     再在 Localization.lua 里补一个 cond_<id> 文案。就这两步,不用碰这个文件。
--   * 数值/枚举类——照 Condition_HP.lua 写一个模块(暴露 id / kind / label_key / get),
--     然后在本文件底部 register 一下。
--
-- 条件定义(def)的形状:
--   id        唯一 id,存进配置文件里的就是它,**不要改**(改了旧配置就失配)
--   kind      "bool" | "number" | "enum"   决定 UI 给什么控件、比较时走哪套算子
--             enum 的 def 还要给 options(context, lang) 和 value_label(value, lang),
--             档位列表由 def 自己提供(通常从引擎枚举反射出来),Registry 不认识具体档位
--   label_key Localization 的 key
--   get(ctx)  读当前值;读不到返回 nil(nil 一律当"条件不成立",不当 false)

local Registry = {}

local defs = {}
local order = {}

function Registry.register(def)
    if not def or not def.id then return end
    if defs[def.id] then return end
    defs[def.id] = def
    table.insert(order, def)
end

function Registry.get(id) return defs[id] end

-- 按注册顺序返回,UI 里的下拉框顺序就是这个顺序(稳定,不受 pairs 随机化影响)
function Registry.all() return order end

-- 下拉框里列的:去掉被合成条件取代的旧布尔(legacy;它们照常能求值,见 Merged.lua)
function Registry.visible()
    local out = {}
    for _, def in ipairs(order) do if not def.legacy then out[#out + 1] = def end end
    return out
end

local NUM_OPS = { "<=", "<", ">=", ">", "==" }
Registry.NUM_OPS = NUM_OPS

-- 枚举只有"是这一档"和"不是这一档"两种问法 —— 枚举值之间的大小没有意义
-- (Vital 的 0/2 不是有序刻度,是标签),所以不给 < > 这些。
local ENUM_OPS = { "==", "~=" }
Registry.ENUM_OPS = ENUM_OPS

local function num_cmp(a, op, b)
    if op == "<=" then return a <= b
    elseif op == "<"  then return a <  b
    elseif op == ">=" then return a >= b
    elseif op == ">"  then return a >  b
    elseif op == "==" then return a == b
    end
    return false
end

-- cond: { type = <id>, op = <算子,仅 number 用>, value = <bool 或 number> }
function Registry.eval_condition(cond, context)
    if not cond or not cond.type then return false end
    local def = defs[cond.type]
    if not def then return false end
    local cur = def.get(context)
    if cur == nil then return false end

    if def.kind == "bool" then
        return cur == (cond.value == true)
    end

    if def.kind == "enum" then
        local a, b = tonumber(cur), tonumber(cond.value)
        if not a or not b then return false end
        if (cond.op or "==") == "~=" then return a ~= b end
        return a == b
    end

    local a, b = tonumber(cur), tonumber(cond.value)
    if not a or not b then return false end
    return num_cmp(a, cond.op or "<=", b)
end

-- rule: { conditions = { cond, ... }, logic = "AND"|"OR", preset = <预设名> }
-- 空条件列表**不算命中**——否则一条还没配完的规则会无条件生效。
function Registry.eval_rule(rule, context)
    if not rule then return false end
    local conds = rule.conditions
    if not conds or #conds == 0 then return false end
    local is_and = (rule.logic or "AND") == "AND"
    for _, c in ipairs(conds) do
        local ok = Registry.eval_condition(c, context)
        if is_and and not ok then return false end
        if (not is_and) and ok then return true end
    end
    return is_and
end

-- 有状态的条件(比如"血量比上一帧少了")需要每帧维护自己的状态。
-- **每帧只能调一次**,所以放在 on_frame 里,而不是塞进 get() ——
-- get() 每帧会被调用多次(规则求值、UI 显示),塞进去就会把上一帧的基线冲掉。
--
-- 帧号会传给 tick:**多个 def 共享同一个 tick 函数**时(比如血量减少/增加是同一份
-- 血量历史的两个视角),它们各自会被调一次,靠帧号去重才能只采样一次。
-- def 自己数帧是不行的 —— 那分不清"新的一帧"和"同一帧里的第二次调用"。
Registry.frame = 0
function Registry.tick(context)
    Registry.frame = Registry.frame + 1
    for _, def in ipairs(order) do
        if def.tick then pcall(def.tick, context, Registry.frame) end
    end
end

Registry.register(require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HP"))
Registry.register(require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_Vital"))
Registry.register(require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HasArmor"))
Registry.register(require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_WeaponKind"))
for _, def in ipairs(require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HPChange")) do
    Registry.register(def)
end
for _, def in ipairs(require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_Enums")) do
    Registry.register(def)
end
for _, def in ipairs(require("ArmorVariantManager_Core.Games.RE4.Conditions.PlayerBools")) do
    Registry.register(def)
end

-- 合成条件(按功能合并的枚举),取值来自上面的布尔条件;被合并的布尔标成 legacy
local Merged = require("ArmorVariantManager_Core.Games.RE4.Conditions.Merged")
for _, def in ipairs(Merged.defs(Registry.get)) do Registry.register(def) end
for id in pairs(Merged.LEGACY) do if defs[id] then defs[id].legacy = true end end
Registry.LEGACY = Merged.LEGACY

return Registry
