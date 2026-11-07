-- 合成条件(Conditions/Merged.lua):按优先级取值、旧布尔隐藏但照常求值、旧配置的等价迁移。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = { find_type_definition = function() return nil end, is_managed_object = function() return false end }
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local Merged = require("ArmorVariantManager_Core.Games.RE4.Conditions.Merged")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")

-- 假的 PlayerBaseContext:flags[方法名] = 布尔
local METHOD = {
    is_aiming = "get_IsAiming", is_wheel = "get_IsWheel", is_holding = "get_IsHolding",
    is_shooting = "get_IsShooting", is_shoot_dry_fire = "get_IsShootDryFire", is_pump_action = "get_IsPumpAction",
    is_combating = "get_IsCombating", is_fatal_kick = "get_IsFatalKick", is_fatal_round_kick = "get_IsFatalRoundKick",
    is_fatal_kill = "get_IsFatalKill", is_parry = "get_IsParry", is_big_parry = "get_IsBigParry",
    is_reloading = "get_IsReloading", is_weapon_changing = "get_IsWeaponChanging", is_throwing = "get_IsThrowing",
    is_walk = "get_IsWalk", is_run = "get_IsRun", is_quick_turn = "get_IsQuickTurn",
    is_jumping = "get_IsJumping", is_falling = "get_IsFalling", is_landing = "get_IsLanding",
    is_ladder = "get_IsLadder", is_hook_shot = "get_IsHookShot", is_boat = "get_IsBoat",
    is_damaging = "get_IsDamaging", is_upper_body_damage = "get_IsUpperBodyDamage",
}
local function ctx(on)
    local flags = {}
    for id, v in pairs(on or {}) do flags[METHOD[id]] = v end
    return { call = function(_, m)
        if m == "get_BodyUpdater" then return nil end
        local v = flags[m]
        if v == nil then return false end
        return v
    end }
end
local function get(id, on) return Registry.get(id).get(ctx(on)) end

-- 注册与可见性
for _, g in ipairs(Merged.GROUPS) do
    local def = Registry.get(g.id)
    assert(def and def.kind == "enum" and def.merged, g.id .. " registered as enum")
    assert(#def.options(nil, "zh") == #g.values)
end
for id in pairs(Merged.LEGACY) do
    assert(Registry.get(id) and Registry.get(id).legacy, id .. " still registered, marked legacy")
end
local visible = {}
for _, def in ipairs(Registry.visible()) do visible[def.id] = true end
assert(visible.hold_state and visible.is_pull_trigger and visible.is_battle and visible.is_burning)
assert(not visible.is_aiming and not visible.is_holding and not visible.hp_decreased, "replaced booleans hidden")

-- 取值与优先级
assert(get("hold_state", {}) == 0)
assert(get("hold_state", { is_holding = true }) == 3, "holding without aim / wheel = raising or lowering")
assert(get("hold_state", { is_holding = true, is_wheel = true }) == 2)
assert(get("hold_state", { is_holding = true, is_aiming = true, is_wheel = true }) == 1, "moving aim wins")
assert(get("melee_action", { is_combating = true, is_fatal_kick = true }) == 2, "fatal kick over plain melee")
assert(get("parry", { is_parry = true, is_big_parry = true }) == 2)
assert(get("hit", { is_damaging = true }) == 1 and get("hit", { is_damaging = true, is_upper_body_damage = true }) == 2)
assert(get("locomotion", { is_walk = true }) == 1 and get("airborne", { is_falling = true }) == 2)
assert(Registry.get("hold_state").get(nil) == nil, "no context")
assert(Registry.get("hold_state").value_label(2, "zh") == "站定瞄准")
-- 旧 id 照常求值
assert(Registry.eval_condition({ type = "is_wheel", value = true }, ctx({ is_wheel = true })))
assert(Registry.eval_condition({ type = "hold_state", op = "~=", value = 0 }, ctx({ is_holding = true })))

-- 迁移:只迁移等价的;其余原样
S.equal(M3.migrate_condition({ type = "is_holding", value = true }), { type = "hold_state", op = "~=", value = 0 })
S.equal(M3.migrate_condition({ type = "is_holding", value = false }), { type = "hold_state", op = "==", value = 0 })
S.equal(M3.migrate_condition({ type = "is_aiming", value = true }), { type = "hold_state", op = "==", value = 1 })
S.equal(M3.migrate_condition({ type = "is_fatal_kill", value = false }), { type = "melee_action", op = "~=", value = 4 })
S.equal(M3.migrate_condition({ type = "hp_increased", value = true }), { type = "hp_change", op = "==", value = 2 })
S.equal(M3.migrate_condition({ type = "is_wheel", value = true }), { type = "is_wheel", value = true }, "not proven exclusive: kept")
S.equal(M3.migrate_condition({ type = "is_combating", value = true }), { type = "is_combating", value = true })
S.equal(M3.migrate_condition({ type = "is_pull_trigger", value = true }), { type = "is_pull_trigger", value = true })
S.equal(M3.migrate_condition({ type = "hp_ratio", op = "<=", value = 30 }), { type = "hp_ratio", op = "<=", value = 30 })
local once = M3.migrate_condition({ type = "is_holding", value = true })
S.equal(M3.migrate_condition(once), once, "migrating twice changes nothing")

-- 等价性:每个被迁移的旧条件,在所有标志组合下(持械 ⊇ 举着移动 ∪ 站定瞄准,已测)判断结果和迁移前一样
for id, m in pairs(Merged.LEGACY) do
    if m.exact and METHOD[id] then
        local group
        for _, g in ipairs(Merged.GROUPS) do if g.id == m.group then group = g end end
        local ids = {}
        for _, r in ipairs(group.rules) do ids[#ids + 1] = r[2] end
        for mask = 0, (1 << #ids) - 1 do
            local on = {}
            for k, rid in ipairs(ids) do on[rid] = (mask >> (k - 1)) & 1 == 1 end
            local valid = not (group.superset and (on.is_aiming or on.is_wheel) and not on.is_holding)
            if valid then
                for _, val in ipairs({ true, false }) do
                    local old = { type = id, value = val }
                    local new = M3.migrate_condition(old)
                    assert(Registry.eval_condition(old, ctx(on)) == Registry.eval_condition(new, ctx(on)),
                        ("%s=%s differs after migration at mask %d"):format(id, tostring(val), mask))
                end
            end
        end
    end
end

-- 规范化 v3 配置时迁移条件状态里的条件
local cfg = M3.normalize({ version = 3, base = { presets = { A = {} }, order = { "A" }, active = "A" },
    conditions = { states = { { name = "s", conditions = { { type = "is_holding", value = true }, { type = "is_wheel", value = true } }, targets = {} } } } })
S.equal(cfg.conditions.states[1].conditions, {
    { type = "hold_state", op = "~=", value = 0 }, { type = "is_wheel", value = true },
})

print("PASS: RE4 merged conditions: enums by priority, replaced booleans hidden but still evaluated, exact-only migration (equivalent on every flag combination)")
