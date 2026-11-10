local TransformManager = {}
local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local Condition_HP = require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HP")
local ModelV3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")

TransformManager.Registry = Registry

function TransformManager.get_character_hp_percent(context) return Condition_HP.get(context) end
function TransformManager.set_character_hp_percent(context, percent) return Condition_HP.set_percent(context, percent) end

-- ============================================================
-- 层模型
--
-- 只有一种「层」,两个变体:
--   主层(base) —— 整份快照,就是"一整套造型"。同时只有一个预设生效。
--   轴(axis)   —— 稀疏,**只对自己动过的材质发言**。同时只有一个预设生效(所以组内天然互斥)。
--
-- 两者结构相同:{ presets = {...}, active = "", rules = {...} }。
-- 「常规组 / 条件组」不是两类东西,而是同一个层的两种**选择器**:
-- rules 命中就用规则的,否则用手动选的 active。
--
-- 轴之所以能独立叠加而不互相踩,靠的是**稀疏**:没在预设里出现的材质,这个轴不碰它。
-- (v0.2 的 groups 用整份快照当叠加层,必然互相覆盖 —— 那是设计错误,已在迁移里保留数据
--  并靠作用域冲突检测报出来。)
--
-- 每帧从基线整份重算,不依赖上一帧 —— 这也是"切换预设后残留上一个状态"那个 bug 的正解:
-- 不需要显式"复位",因为基线本身就是重新铺的。
-- ============================================================

local last_state_cache = {}
function TransformManager.clear_last_state_cache()
    last_state_cache = {}
end

-- 条件规则优先于手动选择。多条规则命中时,**列表里靠后的赢**。
-- 返回:预设名, 是否来自条件
-- 优先级 = **层里状态列表的顺序**(layer.order),从上往下第一个条件成立的赢。
--
-- 曾经是"遍历 rules 数组,靠后的覆盖靠前的",即 **最后命中的赢**。那套的问题不是结果不对,
-- 而是机制隐形:数组顺序就是"当初谁先被添加",UI 里没有任何地方能看见、更不能调整 ——
-- 把同一条规则删掉重加,优先级就悄悄变了。
--
-- 现在只有**一套**顺序,就是用户在状态组里看到的那份互斥列表,可以用上移/下移调。
-- 规律也好记:越瞬时/越特殊的状态放越上面(受伤 > 低血量),常态放下面。
--
-- layer.order 缺失时(没经过 normalize 的层)退回按名字排序,只为不崩,不是正式行为。
-- 「命中后保持 N 秒」的闩锁。
--
-- 为什么保持是**规则上的字段**而不是一个条件:"保持中"的真值取决于这条规则自己命中过没有,
-- 而规则是否命中又取决于它 —— 自我指涉。放进条件列表里跟谁组合都会退化:
--   * 和「且」组合:瞬时条件(掉血)只在那一帧为真,"保持中"要在之后才为真,
--     两者**永不同时成立**,保持根本不会发生。
--   * 和「或」组合:命中 → 刷新计时 → 下一帧"保持中"为真 → 又命中 → 再刷新 → **永远不灭**。
-- 做成字段就干净了:条件只回答"发生了吗",hold 只回答"亮多久"。
--
-- 计时状态**不进配置**:用规则表自己当 key 的弱表,配置重载 / 换角色时那批 rule 表被丢掉,
-- 闩锁跟着被 GC 回收,不会留下"上次没走完的计时"。配置里只存 `hold = N`。
--
-- 时间源是 os.clock(墙上时间),所以游戏暂停时计时照走。
-- 被更高优先级的状态压住时也照走 —— 它记的是"事件多久以前发生的",跟谁在显示无关。
local hold_until = setmetatable({}, { __mode = "k" })

-- 带闩锁的命中判定。
--
-- **计时是从"条件不再成立"那一刻开始的,不是从第一次命中开始。** 实现方式是:条件成立的
-- 每一帧都把到期时间续到 `now + hold`,所以只要条件还成立就一直亮、不倒计时;
-- 最后一次续期发生在条件成立的最后一帧,于是它正好在"条件结束后 N 秒"到期。
-- (换句话说,条件持续 5 秒、hold 2 秒 = 一共亮 7 秒,不是 2 秒。)
--
-- **保持是整条规则的**,不是每个条件各自的:`eval_rule` 先把所有条件按且/或算完,
-- 闩锁包在那个结果外面。所以语义是「A 且 B,然后保持 N 秒」,
-- 不存在「A 保持 x 且 B 保持 y」那种组合 —— 那种东西没有使用场景,也说不清该谁赢。
--
-- **每帧会被调多次**(resolve、快速切换那一行、规则概览),重复续期是幂等的
-- (都续到 now + hold),所以不需要像 tick() 那样保证每帧只调一次。
function TransformManager.rule_hits(rule, context)
    if not rule then return false end
    if Registry.eval_rule(rule, context) then
        local hold = tonumber(rule.hold) or 0
        if hold > 0 then hold_until[rule] = os.clock() + hold end
        return true
    end
    local until_t = hold_until[rule]
    if until_t then
        if os.clock() < until_t then return true end
        hold_until[rule] = nil    -- 过期就清掉,别让弱表里堆着无用的键
    end
    return false
end

local function ordered_names(layer)
    local presets = layer.presets or {}
    local order = layer.order
    if type(order) == "table" and #order > 0 then return order end
    local names = {}
    for name, _ in pairs(presets) do table.insert(names, name) end
    table.sort(names)
    return names
end

-- layer.auto == false = **暂时别自动**:规则整层不参与求值,回落到手动选的那个状态。
--
-- 刻意不是"整层失效":真实需求(拍照、试装、换模型)是"把脸固定成正常",不是"让这组消失"。
-- "彻底不管任何材质"已经有入口了 —— 把 active 选成空(UI 上的「(无)」),
-- 所以开关只管"规则跑不跑",不新增第三种语义。
--
-- **nil 当 true**(老配置没这个字段),只有显式 false 才算关。
-- 第三个返回值:命中的那条规则(溶解过渡要读它的设置);手动选择时为 nil。
local function pick_active_preset(layer, context)
    if not layer then return nil, false end
    local presets = layer.presets or {}

    if layer.auto == false then
        local a = layer.active
        if a and a ~= "" and presets[a] then return a, false end
        return nil, false
    end

    -- 先把 rules 按目标状态归拢:一个状态理论上可以有多条规则(老配置/手改 json),
    -- 任一条命中就算这个状态成立。
    -- 血量驱动的规则(dissolve_hp_driven)不按条件命中,由 resolve 里的血量链单独处理
    local by_preset = {}
    for _, rule in ipairs(layer.rules or {}) do
        local p = rule.preset
        if p and p ~= "" and rule.dissolve_hp_driven ~= true then
            if not by_preset[p] then by_preset[p] = {} end
            table.insert(by_preset[p], rule)
        end
    end

    for _, name in ipairs(ordered_names(layer)) do
        if presets[name] and by_preset[name] then
            for _, rule in ipairs(by_preset[name]) do
                -- 保持中的状态**算命中**,所以照常参与优先级竞争
                -- (受伤保持那两秒里压住低血量,这正是想要的)
                if TransformManager.rule_hits(rule, context) then return name, true, rule end
            end
        end
    end

    local a = layer.active
    if a and a ~= "" and presets[a] then return a, false end
    return nil, false
end
TransformManager.pick_active_preset = pick_active_preset

-- ============================================================
-- 轴的两种顺序,**别混用**
--
--   get_axis_names   = 优先级顺序,**靠前的优先**(和层内 preset 的 order 一致)
--   axis_apply_order = 应用顺序,**和优先级相反**
--
-- 为什么相反:`resolve` 里是后写覆盖先写,所以"优先"意味着"最后写"。
-- 用户用名字前缀 `0 - ` / `1 - ` / `2 - ` 表达优先级,数字越小越优先 ——
-- 而字母序会把 `0 - Nake` 排在最前、于是最先被写、被后面所有轴覆盖,
-- **实际优先级恰好反了**。这个 bug 一直是潜伏的:所有 body 轴都只写 false,
-- false 盖 false 是幂等的(实测 30 处重叠、true 全为 0)。一旦某个部位轴加了
-- 「显示」状态(写 true),它立刻发作。
--
-- 另外:**高级状态组(有规则=条件驱动)整体优先于基础状态组**。
-- 掉血爆衣这类反应式状态应该盖掉手动摆的造型,而不是被它盖掉。
-- ============================================================

local function axis_names_alpha(config)
    local names = {}
    for name, _ in pairs(config.axes or {}) do table.insert(names, name) end
    table.sort(names)
    return names
end

-- 优先级顺序。有 config.axis_order 就按它,缺的补在末尾(优先级最低);
-- 没有这个字段就退回字母序 —— 用户的数字前缀本身就是排好的,所以不填也对。
function TransformManager.get_axis_names(config)
    local order = (config or {}).axis_order
    local alpha = axis_names_alpha(config)
    if type(order) ~= "table" or #order == 0 then return alpha end
    local out, seen = {}, {}
    for _, n in ipairs(order) do
        if (config.axes or {})[n] and not seen[n] then
            seen[n] = true; table.insert(out, n)
        end
    end
    for _, n in ipairs(alpha) do
        if not seen[n] then table.insert(out, n) end
    end
    return out
end

-- 有规则 = 条件驱动 = 面板上的「高级状态组」。分档用的判据和 UI 一致,
-- 这样"面板把它放在哪一栏"和"它的优先级归哪一档"永远不会不一致。
function TransformManager.axis_is_advanced(layer)
    return #(((layer or {}).rules) or {}) > 0
end

function TransformManager.axis_apply_order(config)
    local basic, adv = {}, {}
    for _, name in ipairs(TransformManager.get_axis_names(config)) do
        local bucket = TransformManager.axis_is_advanced((config.axes or {})[name]) and adv or basic
        table.insert(bucket, name)
    end
    -- 各档内部倒序(优先级高的最后写),基础档整体排在高级档前面
    local out = {}
    for i = #basic, 1, -1 do table.insert(out, basic[i]) end
    for i = #adv, 1, -1 do table.insert(out, adv[i]) end
    return out
end

-- 找真正会打架的材质。
--
-- 只看"作用域重叠"是**过度报警**:两个状态都把同一个材质写成 `关`(比如「隐藏上半身衣服」
-- 和「隐藏腰带」都要关掉某块共用材质),那不管谁先谁后结果都一样 —— 它们本来就兼容。
-- 真正的冲突判据是**能写出不同的取值**:所有写这个材质的状态里,既有人会写 `开`、
-- 又有人会写 `关`,结果才会取决于叠加顺序。
--
-- 取值是按**状态的全部预设**统计的(不是只看当前生效那个):一个状态换个预设就可能改写法,
-- 所以只要存在某种组合会打架,就该报。这也让判据与"这个状态是手动还是被规则驱动"无关。
--
-- 返回 { { key = "slot/mat", parts = { { axis=名, on=bool, off=bool }, ... } }, ... }
function TransformManager.find_scope_conflicts(config)
    local map = {}   -- key -> { [axis名] = { on=, off= } }
    for _, name in ipairs(TransformManager.get_axis_names(config)) do
        for _, preset in pairs(config.axes[name].presets or {}) do
            for slot, data in pairs(preset) do
                if type(data) == "table" and type(data.materials) == "table" then
                    for m, v in pairs(data.materials) do
                        local key = slot .. "/" .. m
                        map[key] = map[key] or {}
                        local e = map[key][name]
                        if not e then e = { on = false, off = false }; map[key][name] = e end
                        if v == true then e.on = true
                        elseif v == false then e.off = true end
                    end
                end
            end
        end
    end

    local conflicts = {}
    for key, by_axis in pairs(map) do
        local names = {}
        for n, _ in pairs(by_axis) do table.insert(names, n) end
        if #names > 1 then
            table.sort(names)
            local any_on, any_off = false, false
            for _, n in ipairs(names) do
                if by_axis[n].on then any_on = true end
                if by_axis[n].off then any_off = true end
            end
            -- 全都只写同一个值 = 兼容,不报
            if any_on and any_off then
                local parts = {}
                for _, n in ipairs(names) do
                    table.insert(parts, { axis = n, on = by_axis[n].on, off = by_axis[n].off })
                end
                table.insert(conflicts, { key = key, parts = parts })
            end
        end
    end
    table.sort(conflicts, function(a, b) return a.key < b.key end)
    return conflicts
end

-- **逐槛位**的匹配度阈值。注意它比原来那个聚合阈值(0.5)低,这不是放松标准 ——
-- 换了分母之后,分布本身就不一样了。
--
-- 实测到的逐槛位取值(同一个 mod,玩家/傀儡/雕像三类目标):
--   真正对不上的槛位:**0.000**
--     (Figure10_010 的 body 是 cha004_00_TU1,没被 mod 替换,材质名和预设零交集)
--   应该生效的槛位:  **0.417 … 1.000**
--     (最低那个是 Default 预设的 head —— 存的是 11 材质版、活体只有 6 个,
--      交集 5 / 并集 12。偏旧但仍然是同一个头)
--
-- 0.000 和 0.417 之间空得很大,阈值放这个区间里都行。取 0.25:
-- 是"通用材质名偶然撞上"那个量级(3/37 ≈ 0.08)的三倍,又只有真实下界的 0.6 倍。
--
-- 用 0.5 会**误杀** Default 预设的 head(踩过:改成逐槛位之后先用的 0.5,
-- 拿实测数据一算才发现它把原来靠聚合托着的槛位切掉了)。
--
-- 数据只来自一套 mod、几个模型,所以这个数字是**可疑的**;要动的话看上面那两簇。
TransformManager.SLOT_MATCH_THRESHOLD = 0.25

-- 逐槛位判定:哪些槛位上这份整套造型预设是可用的。
--
-- **从聚合改成逐槛位是为了修一个踩过三次的 bug**:一个坏槛位会否掉整份预设。
-- 实测 Figure10_010 对 Human 预设 —— body 0.000 / head 0.909 / hair 0.692,
-- 聚合 0.292 ⇒ 整份不可用,而 head/hair 明明完好。另两次是 v0.3.7 的护甲
-- 和 Jacket→armor。现在 body 被跳过、head/hair 照常生效。
function TransformManager.usable_slots(source, preset)
    local out = {}
    if not preset then return out end
    for slot, ratio in pairs(Utils.preset_slot_ratios(source, preset)) do
        if ratio >= TransformManager.SLOT_MATCH_THRESHOLD then out[slot] = true end
    end
    return out
end

-- 「这份预设完全没法用吗」。UI 上那个「材质不匹配,已跳过」标记用它 ——
-- 现在只有**一个槛位都对不上**才算完全不可用;部分可用的走 partial 标记。
function TransformManager.is_base_preset_usable(source, preset)
    if not preset then return false end
    return next(TransformManager.usable_slots(source, preset)) ~= nil
end

-- 血量驱动(溶解):一层里勾了 dissolve_hp_driven 的规则组成一条链。每条把血量在自己的上限 / 下限之间
-- 映射成进度 0..1;第 k 段从第 k-1 条的状态(k = 1 时是没有血量驱动时这一层原本的选择)溶解到第 k 条的状态。
-- 链的顺序跟着血量走:上限从高到低(全部反向时按下限从低到高;方向混用时按规则列表顺序)。
-- 返回 { chain = (k-1) + 最后一条已开始的进度(0..条数), names = 链上各状态名 },不驱动时返回 nil。
-- 不驱动的情形:这一层关了自动;读不到血量;或者有条**优先级更高**的普通规则命中(受伤这类瞬时状态照常压住)。
local function hp_chain(layer, context, normal_name, normal_rule)
    if not layer or layer.auto == false then return nil end
    local presets = layer.presets or {}
    local items, inverted, normal = {}, 0, 0
    for index, rule in ipairs(layer.rules or {}) do
        if rule.dissolve_hp_driven == true and rule.preset and presets[rule.preset] then
            table.insert(items, { rule = rule, index = index,
                upper = tonumber(rule.dissolve_hp_upper) or 100, lower = tonumber(rule.dissolve_hp_lower) or 0 })
            if rule.dissolve_hp_invert == true then inverted = inverted + 1 else normal = normal + 1 end
        end
    end
    if #items == 0 then return nil end
    if normal_rule then
        local pos = {}
        for i, n in ipairs(ordered_names(layer)) do pos[n] = i end
        local first = math.huge
        for _, it in ipairs(items) do first = math.min(first, pos[it.rule.preset] or math.huge) end
        if (pos[normal_name] or math.huge) < first then return nil end
    end
    local hp = Condition_HP.get(context)
    if type(hp) ~= "number" then return nil end
    if inverted == 0 then
        table.sort(items, function(a, b)
            if a.upper ~= b.upper then return a.upper > b.upper end
            return a.index < b.index
        end)
    elseif normal == 0 then
        table.sort(items, function(a, b)
            if a.lower ~= b.lower then return a.lower < b.lower end
            return a.index < b.index
        end)
    end
    local chain, names = 0, {}
    for k, it in ipairs(items) do names[k] = it.rule.preset end
    for k = #items, 1, -1 do
        local it = items[k]
        local p
        if it.upper > it.lower then
            p = math.max(0, math.min(1, (it.upper - hp) / (it.upper - it.lower)))
        else
            p = hp <= it.upper and 1 or 0
        end
        if it.rule.dissolve_hp_invert == true then p = 1 - p end
        if p > 0 then chain = (k - 1) + p; break end
    end
    return { chain = chain, names = names }
end

-- 叠加:全启用铺底 → 整套造型(逐槛位判可用)→ 稀疏层按 sparse 的顺序后写覆盖先写 → 护甲镜像。
-- sparse = { { key = 层键, presets = { 名 -> 稀疏快照 } }, ... },**应用顺序**(不是优先级顺序)。
-- v2 和 v3 共用这一份,区别只在 picks 怎么来、sparse 怎么排。
local function make_build(base, sparse, mirror, body_updater)
    local baseline = Utils.all_enabled_preset(body_updater)
    local usable_cache = {}
    local function usable_of(name)
        if not name or not (base.presets or {})[name] then return {} end
        if not usable_cache[name] then
            usable_cache[name] = TransformManager.usable_slots(body_updater, base.presets[name])
        end
        return usable_cache[name]
    end

    return function(picks)
        local resolved, owner = {}, {}
        local function write(slot, mat, val, key)
            if val == nil then return end
            resolved[slot] = resolved[slot] or { materials = {} }
            resolved[slot].materials[mat] = val
            owner[slot] = owner[slot] or {}
            owner[slot][mat] = key
        end

        -- 基线。
        -- 选了整套造型预设、且它跟当前模型的材质对得上,就用它;否则全启用兜底
        -- (= 模型作者原本的样子)。对不上时**宁可什么都不做,也不要套出个半残的**。
        --
        -- 全启用先铺一层:预设里没提到的材质(modder 后来新加的)才有确定值,
        -- 而不是保留游戏当时的残留状态。这一层刻意对所有槛位无条件铺开;
        -- 预设的覆盖才是逐槛位的(见 usable_slots)。
        for slot, data in pairs(baseline) do
            for m, v in pairs(data.materials) do write(slot, m, v, nil) end
        end
        local base_name = picks.base
        local usable = usable_of(base_name)
        if base_name and (base.presets or {})[base_name] then
            for slot, data in pairs(base.presets[base_name]) do
                if usable[slot] and type(data) == "table" then
                    for m, v in pairs(data.materials or {}) do write(slot, m, v, "base") end
                end
            end
        end

        -- 稀疏层:只对自己点名的材质发言,后写的覆盖先写的(v2 按 axis_apply_order,v3 按 groups 顺序)。
        for _, layer in ipairs(sparse) do
            local pname = picks[layer.key]
            local preset = pname and (layer.presets or {})[pname]
            if preset then
                for slot, data in pairs(preset) do
                    if type(data) == "table" then
                        for m, v in pairs(data.materials or {}) do write(slot, m, v, layer.key) end
                    end
                end
            end
        end

        -- 护甲镜像:把 body 的最终结果整份复制给 armor,按材质名对应。
        --
        -- 放在最后,是因为要跟随**任何来源**算出的 body 结果。**完全覆盖,不是"填默认值"**:
        -- armor 上此前单独写过的材质全部作废,直接换成 body 的整份结果 —— 半镜像半自定义的
        -- 状态没法一眼看出哪块是镜像的;想给 armor 单独配点什么,必须先关掉这个开关。
        if mirror then
            local mirrored, mirrored_owner = { materials = {} }, {}
            for m, v in pairs((resolved.body and resolved.body.materials) or {}) do
                mirrored.materials[m] = v
                mirrored_owner[m] = owner.body and owner.body[m]
            end
            resolved.armor = mirrored
            owner.armor = mirrored_owner
        end
        return resolved, owner, usable
    end
end

-- 变化检测:**只记决策结果,不记条件原始值**。输出完全由"各层最终选了哪个预设"决定;
-- 原始值进签名会让"距今多少秒"这类条件每帧都改签名,门控彻底失效。
-- 签名里要带**哪些槛位生效了**:穿脱护甲会让 usable 变而 base_name 不变,只记名字就漏掉那次重写。
-- (血量驱动的进度不进签名:驱动期间调用方每帧都会重写。)
local function signature(picks, usable, sparse)
    local usable_sig = ""
    for _, slot in ipairs(Utils.MESH_SLOTS) do
        if usable[slot] then usable_sig = usable_sig .. slot .. "," end
    end
    local sig = "base=" .. tostring(picks.base) .. "[" .. usable_sig .. "]"
    for _, layer in ipairs(sparse) do
        sig = sig .. "|" .. layer.key .. "=" .. tostring(picks[layer.key])
    end
    return sig
end

local function changed_since_last(char_addr, config, sig)
    -- resolve 的第一个参数只是缓存键,必须按目标唯一
    local cache_key = char_addr .. "_" .. tostring(config)
    local changed = (last_state_cache[cache_key] ~= sig)
    last_state_cache[cache_key] = sig
    return changed
end

-- v3:各层的选择来自条件状态表(ModelV3.resolve),叠加和 v2 共用 make_build。
-- 状态组的叠加顺序就是 groups 的顺序:几个组可以写同一个材质,靠后的组覆盖靠前的。
-- 复选组的每个选项各是一层(ModelV3.group_layers),组内按选项顺序叠加。
local function resolve_v3(char_addr, config, context, body_updater)
    local sparse = {}
    for _, g in ipairs(config.groups or {}) do
        for _, l in ipairs(ModelV3.group_layers(g)) do
            sparse[#sparse + 1] = { key = l.key, presets = g.options }
        end
    end
    local r = ModelV3.resolve(config, context)
    local build = make_build(config.base or {}, sparse, config.armor_mirrors_body, body_updater)
    for key, d in pairs(r.drives) do d.base_name = r.picks[key] end
    local resolved, owner, usable = build(r.picks)
    local changed = changed_since_last(char_addr, config, signature(r.picks, usable, sparse))
    return resolved, changed, { layers = r.layers, owner = owner, picks = r.picks, drives = r.drives,
        build = build, v3 = r }
end

-- 解算最终状态。
-- 返回:
--   resolved  { [slot] = { materials = { [mat] = bool } } }   最终要写进 mesh 的
--   changed   跟上次相比状态变了没(用来省掉无谓的重写)
--   info      溶解要用的:{ layers = { [层键] = { name, rule, prio } }, owner = { [slot] = { [mat] = 层键 } },
--             picks = { [层键] = 状态名 }, drives = { [层键] = hp_chain 的结果 + base_name }, build = function(picks) }
--             层键:"base";v2 的状态组是 "axis:<名>",v3 的是 "group:<名>"。v3 另有 info.v3 = ModelV3.resolve 的结果
function TransformManager.resolve(char_addr, config, context, body_updater)
    if ModelV3.is_v3(config) then return resolve_v3(char_addr, config, context, body_updater) end

    local base = config.base or {}
    local axis_names = TransformManager.axis_apply_order(config)
    local sparse = {}
    for _, name in ipairs(axis_names) do
        sparse[#sparse + 1] = { key = "axis:" .. name, presets = config.axes[name].presets }
    end
    local build = make_build(base, sparse, config.armor_mirrors_body, body_updater)

    -- 各层这一帧的选择(血量驱动的规则不参与,见 pick_active_preset)
    local layers, picks, drives = {}, {}, {}
    local function pick_layer(key, layer)
        local name, _, rule = pick_active_preset(layer, context)
        layers[key] = { name = name, rule = rule }
        picks[key] = name
        local d = hp_chain(layer, context, name, rule)
        if d then
            d.base_name = name
            drives[key] = d
        end
    end
    pick_layer("base", base)
    for _, name in ipairs(axis_names) do pick_layer("axis:" .. name, config.axes[name]) end

    local resolved, owner, usable = build(picks)
    local changed = changed_since_last(char_addr, config, signature(picks, usable, sparse))
    return resolved, changed, { layers = layers, owner = owner, picks = picks, drives = drives, build = build }
end

return TransformManager
