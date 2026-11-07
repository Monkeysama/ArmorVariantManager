-- 合成条件:同一件事的几个阶段合成一个枚举(方案见本地 docs/RE4_CONDITION_MERGE.md,2026-11-07 定稿)。
--
-- 取值来自已有的布尔条件,按 rules 的顺序取第一个为真的;都不为真时是 0(无 / 静止 / 地面)。
-- 被合并的布尔条件照常注册、照常能求值(旧配置、SKS 公式里的 cond(旧 id) 都靠它),只是标成 legacy,
-- 不在条件下拉框里列出。
--
-- **互斥关系还没实测**:同一帧几个阶段同时亮时按优先级取一个,低优先级的那一档在重叠帧里查不到。
-- 所以旧配置只迁移语义完全等价的那几种(见 ModelV3 的条件迁移):每组优先级最高的一档(它为真 ⇔ 枚举等于它),
-- 「持械中」(= 持械 ~= 无,持械是举着移动 / 站定瞄准的严格超集,已测),血量变化(同一份采样,天然互斥)。
-- 实测确认互斥后再补其它档的迁移。
--
-- id 与取值整数和 SKS 共用,定下来就不要改(配置里存的是整数)。
local Merged = {}

local GROUPS = {
    {
        id = "hold_state", category = "combat",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "举着移动", en = "Raised, moving" },
            { v = 2, zh = "站定瞄准", en = "Raised, standing" },
            { v = 3, zh = "起手或放下", en = "Raising / lowering" },
        },
        -- is_holding 是 is_aiming ∪ is_wheel 的严格超集:前两档都不亮而它亮的,就是起手 / 停步 / 放下的过渡帧
        rules = { { 1, "is_aiming" }, { 2, "is_wheel" }, { 3, "is_holding" } },
        superset = "is_holding",
    },
    {
        id = "shoot_action", category = "combat",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "开火", en = "Firing" },
            { v = 2, zh = "空枪击发", en = "Dry fire" },
            { v = 3, zh = "拉栓", en = "Bolt cycle" },
        },
        rules = { { 1, "is_shooting" }, { 2, "is_shoot_dry_fire" }, { 3, "is_pump_action" } },
    },
    {
        id = "melee_action", category = "combat",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "近战攻击", en = "Melee attack" },
            { v = 2, zh = "处决踢", en = "Fatal kick" },
            { v = 3, zh = "处决回旋踢", en = "Fatal round kick" },
            { v = 4, zh = "处决击杀", en = "Fatal kill" },
        },
        -- 处决比普通近战优先(处决时近战标志亮不亮还没测)
        rules = { { 4, "is_fatal_kill" }, { 3, "is_fatal_round_kick" }, { 2, "is_fatal_kick" }, { 1, "is_combating" } },
    },
    {
        id = "parry", category = "combat",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "招架", en = "Parry" },
            { v = 2, zh = "完美招架", en = "Perfect parry" },
        },
        rules = { { 2, "is_big_parry" }, { 1, "is_parry" } },
    },
    {
        id = "weapon_op", category = "combat",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "换弹", en = "Reloading" },
            { v = 2, zh = "换武器", en = "Changing weapon" },
            { v = 3, zh = "投掷", en = "Throwing" },
        },
        rules = { { 3, "is_throwing" }, { 2, "is_weapon_changing" }, { 1, "is_reloading" } },
    },
    {
        id = "locomotion", category = "move",
        values = {
            { v = 0, zh = "静止", en = "Still" },
            { v = 1, zh = "行走", en = "Walking" },
            { v = 2, zh = "跑动", en = "Running" },
            { v = 3, zh = "快速转身", en = "Quick turn" },
        },
        rules = { { 3, "is_quick_turn" }, { 2, "is_run" }, { 1, "is_walk" } },
    },
    {
        id = "airborne", category = "move",
        values = {
            { v = 0, zh = "地面", en = "Grounded" },
            { v = 1, zh = "起跳", en = "Jumping" },
            { v = 2, zh = "下落", en = "Falling" },
            { v = 3, zh = "落地", en = "Landing" },
        },
        rules = { { 3, "is_landing" }, { 2, "is_falling" }, { 1, "is_jumping" } },
    },
    {
        id = "traversal", category = "move",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "爬梯", en = "Ladder" },
            { v = 2, zh = "钩索", en = "Hook shot" },
            { v = 3, zh = "乘船", en = "Boat" },
        },
        rules = { { 1, "is_ladder" }, { 2, "is_hook_shot" }, { 3, "is_boat" } },
    },
    {
        id = "hit", category = "damage",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "受击", en = "Hit" },
            { v = 2, zh = "上半身受击", en = "Upper body hit" },
        },
        -- 受击亮时上半身受击可以不亮(SKS 实测,着火时);反过来没测,所以上半身受击优先
        rules = { { 2, "is_upper_body_damage" }, { 1, "is_damaging" } },
    },
    {
        id = "hp_change", category = "hp",
        values = {
            { v = 0, zh = "无", en = "None" },
            { v = 1, zh = "减少", en = "Decreased" },
            { v = 2, zh = "增加", en = "Increased" },
        },
        -- 同一份血量采样的两个方向,天然互斥;瞬时值,照旧要配「保持」
        rules = { { 1, "hp_decreased" }, { 2, "hp_increased" } },
        exclusive = true,
    },
}
Merged.GROUPS = GROUPS

-- 旧 id → { group = 合成条件 id, value = 档位, exact = 迁移是否完全等价, superset = 是否表示「~= 0」}
Merged.LEGACY = {}
for _, g in ipairs(GROUPS) do
    for k, r in ipairs(g.rules) do
        local id = r[2]
        local entry = { group = g.id, value = r[1], exact = (k == 1) or g.exclusive == true }
        if g.superset == id then entry = { group = g.id, value = 0, exact = true, superset = true } end
        Merged.LEGACY[id] = entry
    end
end

-- registry_get(id) -> 已注册的 def(取被合并的布尔条件)
function Merged.defs(registry_get)
    local out = {}
    for _, g in ipairs(GROUPS) do
        local def = { id = g.id, kind = "enum", label_key = "cond_" .. g.id, category = g.category, merged = true }
        function def.options(_, lang)
            local list = {}
            for _, e in ipairs(g.values) do list[#list + 1] = { value = e.v, label = lang == "zh" and e.zh or e.en } end
            return list
        end
        function def.value_label(value, lang)
            for _, e in ipairs(g.values) do if e.v == tonumber(value) then return lang == "zh" and e.zh or e.en end end
            return tostring(value)
        end
        function def.get(context)
            if not context then return nil end
            local any = false
            for _, r in ipairs(g.rules) do
                local src = registry_get(r[2])
                if src then
                    local ok, v = pcall(src.get, context)
                    if ok and v == true then return r[1] end
                    if ok and v == false then any = true end
                end
            end
            return any and 0 or nil
        end
        out[#out + 1] = def
    end
    return out
end

return Merged
