-- RE4 配置 v3:规范化、v2 迁移(与 v2 逐层选择等价)、条件状态解算、OpsV3。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local Condition_HP = require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HP")
local TM = require("ArmorVariantManager_Core.Games.RE4.TransformManager")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")

-- 条件求值换成读 context 表:{ type = "x" } 成立 ⇔ ctx.x == true;血量读 ctx.hp
Registry.eval_condition = function(c, ctx) return ctx[c.type] == true end
Condition_HP.get = function(ctx) return ctx.hp end
local now = 0
M3.clock = function() return now end

local function snap(slot, mats) return {[slot] = {materials = mats}} end
local function rule(preset, flag, extra)
    local r = {preset = preset, logic = "AND", conditions = {{type = flag}}}
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

-- ============================================================ 规范化
do
    local cfg = M3.normalize({
        version = 3,
        base = {presets = {A = snap("body", {a = true, junk = 1})}, active = "missing"},
        groups = {
            {name = "G1", scope = {"head/x", "head/y", "bad"}, options = {o = snap("head", {x = true, z = false})}, active = "o"},
            {name = "G2", scope = {"head/y", "head/w"}, options = {p = snap("head", {y = true, w = false})}},
            {name = "G1", scope = {}, options = {}},
        },
        conditions = {states = {{name = "s", targets = {{group = "G1", option = "o"}, {group = "G1", option = "x"}}, fade_in = 99}}},
    })
    assert(cfg.base.active == "", "unknown base active falls back to none")
    S.equal(cfg.base.presets.A, {body = {materials = {a = true}}})
    assert(#cfg.groups == 2, "duplicate group names dropped")
    S.equal(cfg.groups[1].scope, {"head/x", "head/y"})
    S.equal(cfg.groups[1].options.o, {head = {materials = {x = true}}})
    S.equal(cfg.groups[2].scope, {"head/y", "head/w"}, "overlapping scopes are kept")
    S.equal(cfg.groups[2].options.p, {head = {materials = {y = true, w = false}}})
    S.equal(M3.groups_of(cfg)["head/y"], {"G1", "G2"})
    assert(cfg.conditions.auto == true)
    local st = cfg.conditions.states[1]
    assert(#st.targets == 1 and st.fade_in == 30 and st.enabled and not st.exclusive and st.logic == "AND")
end

-- ============================================================ v2 -> v3 迁移:每层选择与 v2 一致
local function v2_config()
    return {
        version = 2,
        base = {presets = {Full = snap("body", {a = true}), Shirt = snap("body", {a = false})},
            order = {"Full", "Shirt"}, active = "Full", auto = true,
            rules = {rule("Shirt", "boat", {dissolve_enabled = true, dissolve_hide_time = 0.8})}},
        axes = {
            Face = {presets = {Clean = snap("head", {b1 = false, b2 = false}), Hurt = snap("head", {b1 = true}),
                Bloody = snap("head", {b1 = true, b2 = true})},
                order = {"Hurt", "Bloody", "Clean"}, active = "", auto = true,
                rules = {rule("Bloody", "low"), rule("Hurt", "hit")}},
            Coat = {presets = {Wear = snap("body", {j = true, shared = true}), Torn = snap("body", {j = false, t = true})},
                order = {"Torn", "Wear"}, active = "Wear", auto = true,
                rules = {rule("Torn", "low"), rule("Wear", "battle")}},
            Gear = {presets = {Holster = snap("body", {h = true, shared = false}), Vest = snap("body", {v = true})},
                order = {"Holster", "Vest"}, active = "Holster", auto = false,
                rules = {rule("Vest", "battle")}},
            Plain = {presets = {On = snap("hair", {r = true})}, order = {"On"}, active = "On"},
        },
        axis_order = {"Coat", "Face", "Gear", "Plain"},
    }
end

do
    local v2 = v2_config()
    local apply = TM.axis_apply_order(v2)
    local priority = {}
    for i = #apply, 1, -1 do priority[#priority + 1] = apply[i] end
    local v3, report = M3.migrate_from_v2(v2_config(), priority, "Full outfit")

    -- Gear 和 Coat 都管 body/shared:重叠原样保留,groups 按 v2 的应用顺序排(Coat 是高级组,最后写)
    assert(report.overlaps == nil)
    local gear = M3.find_group(v3, "Gear")
    assert(gear.options.Holster.body.materials.shared == false, "overlapped material kept")
    local order = {}
    for i, g in ipairs(v3.groups) do order[i] = g.name end
    S.equal(order, apply, "groups follow the v2 apply order")
    S.equal(M3.groups_of(v3)["body/shared"], {"Gear", "Coat"})

    local base_state = v3.conditions.states[1]
    assert(base_state.base == "Shirt" and base_state.fade_in == 0.8 and base_state.fade_out == 0.5)
    local gear_state
    for _, st in ipairs(v3.conditions.states) do
        if st.targets[1] and st.targets[1].group == "Gear" then gear_state = st end
    end
    assert(gear_state and gear_state.enabled == false, "rules of an auto-off layer migrate disabled")

    local flags = {"boat", "low", "hit", "battle"}
    for mask = 0, 15 do
        local ctx = {}
        for b, f in ipairs(flags) do ctx[f] = (mask >> (b - 1)) & 1 == 1 end
        local r = M3.resolve(v3, ctx)
        local want_base = TM.pick_active_preset(v2.base, ctx)
        assert(r.picks.base == want_base, "base pick differs for mask " .. mask)
        for name, axis in pairs(v2.axes) do
            local want = TM.pick_active_preset(axis, ctx)
            assert(r.picks["group:" .. name] == want,
                ("group %s differs for mask %d: %s vs %s"):format(name, mask, tostring(r.picks["group:" .. name]), tostring(want)))
        end
    end

    -- 最终材质也和 v2 一致(包括重叠的 body/shared)
    local saved_all, saved_usable = Utils.all_enabled_preset, TM.usable_slots
    Utils.all_enabled_preset = function()
        return {body = {materials = {a = true, j = true, shared = true, t = true, h = true, v = true}},
            head = {materials = {b1 = true, b2 = true}}, hair = {materials = {r = true}}}
    end
    TM.usable_slots = function() return {body = true, head = true, hair = true} end
    v2.armor_mirrors_body, v3.armor_mirrors_body = false, false
    for mask = 0, 15 do
        local ctx = {}
        for b, f in ipairs(flags) do ctx[f] = (mask >> (b - 1)) & 1 == 1 end
        local want = TM.resolve("mig_v2_" .. mask, v2, ctx, nil)
        local got = TM.resolve("mig_v3_" .. mask, v3, ctx, nil)
        S.equal(got, want, "final materials differ for mask " .. mask)
    end
    Utils.all_enabled_preset, TM.usable_slots = saved_all, saved_usable
end

-- ============================================================ 重叠的状态组:靠后的覆盖靠前的
do
    local saved_all, saved_usable = Utils.all_enabled_preset, TM.usable_slots
    Utils.all_enabled_preset = function() return {body = {materials = {coat = true, torn = true}}} end
    TM.usable_slots = function() return {body = true} end
    -- 破损(按条件)在上,外套(手动)在下:脱下时两套都关;穿着对这两个材质是「-」,交给破损组
    local cfg = M3.normalize({
        version = 3, base = {presets = {}},
        groups = {
            {name = "Damage", scope = {"body/coat", "body/torn"},
                options = {Fine = snap("body", {coat = true, torn = false}), Torn = snap("body", {coat = false, torn = true})}, active = "Fine"},
            {name = "Coat", scope = {"body/coat", "body/torn"},
                options = {Wear = {}, Off = snap("body", {coat = false, torn = false})}, active = "Wear"},
        },
        conditions = {states = {{name = "hurt", conditions = {{type = "low"}}, targets = {{group = "Damage", option = "Torn"}}}}},
        armor_mirrors_body = false,
    })
    local function mats(ctx, tag) return (TM.resolve("ov_" .. tag, cfg, ctx, nil)).body.materials end
    S.equal(mats({}, 1), {coat = true, torn = false})
    S.equal(mats({low = true}, 2), {coat = false, torn = true}, "condition reaches the overlapped materials")
    M3.find_group(cfg, "Coat").active = "Off"
    S.equal(mats({low = true}, 3), {coat = false, torn = false}, "lower group wins")
    assert(OpsV3.move_group(cfg, "Coat", -1))
    S.equal(mats({low = true}, 4), {coat = false, torn = true}, "reordering changes who wins")
    Utils.all_enabled_preset, TM.usable_slots = saved_all, saved_usable
end

-- ============================================================ 条件状态解算
local function cfg3(states, extra)
    local cfg = {
        version = 3,
        base = {presets = {Full = snap("body", {a = true}), Shirt = snap("body", {a = false})}, active = "Full"},
        groups = {
            {name = "Face", scope = {"head/b1", "head/b2"}, options = {Hurt = snap("head", {b1 = true}), Bloody = snap("head", {b1 = true, b2 = true})}},
            {name = "Coat", scope = {"body/j"}, options = {Wear = snap("body", {j = true}), Torn = snap("body", {j = false})}, active = "Wear"},
        },
        conditions = {states = states},
    }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    return M3.normalize(cfg)
end
local function st(name, flag, targets, extra)
    local s = {name = name, conditions = {{type = flag}}, targets = targets}
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

do
    local cfg = cfg3({
        st("dying", "low", {{group = "Face", option = "Bloody"}, {group = "Coat", option = "Torn"}}, {exclusive = true}),
        st("hit", "hit", {{group = "Face", option = "Hurt"}}),
        st("fight", "battle", {{group = "Coat", option = "Wear"}}, {base = "Shirt"}),
        st("ghost", "battle", {{group = "Face", option = "Missing"}}),
        st("off", "battle", {{group = "Face", option = "Hurt"}}, {enabled = false}),
    })
    local r = M3.resolve(cfg, {})
    assert(r.picks.base == "Full" and r.picks["group:Face"] == nil and r.picks["group:Coat"] == "Wear", "manual picks")
    assert(r.status[1].kind == "idle" and r.status[5].kind == "off")

    r = M3.resolve(cfg, {hit = true, battle = true})
    assert(r.picks["group:Face"] == "Hurt" and r.picks.base == "Shirt" and r.picks["group:Coat"] == "Wear")
    assert(r.status[2].kind == "active" and r.status[3].kind == "active")
    assert(r.status[4].kind == "idle", "state with only broken targets is idle")
    assert(r.targets[4][1].kind == "broken")
    assert(r.layers["group:Face"].prio == 2 and r.layers.base.prio == 3 and r.layers["group:Coat"].prio == 3)

    -- 独占:下面的全部被覆盖
    r = M3.resolve(cfg, {low = true, hit = true, battle = true})
    assert(r.status[1].kind == "active")
    assert(r.status[2].kind == "outranked" and r.status[2].by == 1)
    assert(r.status[3].kind == "outranked" and r.targets[3].base.kind == "lose")
    assert(r.picks.base == "Full", "outranked state does not switch the full outfit")
    assert(r.picks["group:Face"] == "Bloody" and r.picks["group:Coat"] == "Torn")

    -- 不独占时:部分生效
    cfg.conditions.states[1].exclusive = false
    r = M3.resolve(cfg, {low = true, battle = true})
    assert(r.status[3].kind == "partial", "base won, coat lost")
    assert(r.targets[3].base.kind == "win" and r.targets[3][1].kind == "lose" and r.targets[3][1].by == 1)

    -- 总开关关闭
    cfg.conditions.auto = false
    r = M3.resolve(cfg, {low = true})
    assert(r.status[1].kind == "paused" and r.picks["group:Face"] == nil)
end

-- 保持:条件结束后继续 hold 秒
do
    local cfg = cfg3({st("hit", "hit", {{group = "Face", option = "Hurt"}}, {hold = 2})})
    now = 10
    assert(M3.resolve(cfg, {hit = true}).picks["group:Face"] == "Hurt")
    now = 11.5
    local r = M3.resolve(cfg, {})
    assert(r.picks["group:Face"] == "Hurt" and r.status[1].holding, "still held")
    now = 12.5
    assert(M3.resolve(cfg, {}).picks["group:Face"] == nil, "hold expired")
end

-- 按血量驱动:链按上限排序;更靠前的普通状态认领这一层时不驱动
do
    local cfg = cfg3({
        st("hit", "hit", {{group = "Face", option = "Hurt"}}),
        {name = "hp1", hp = {upper = 100, lower = 50}, targets = {{group = "Face", option = "Hurt"}}},
        {name = "hp2", hp = {upper = 50, lower = 0}, targets = {{group = "Face", option = "Bloody"}}},
    })
    local r = M3.resolve(cfg, {hp = 75})
    assert(r.drives["group:Face"] and math.abs(r.drives["group:Face"].chain - 0.5) < 1e-9)
    S.equal(r.drives["group:Face"].names, {"Hurt", "Bloody"})
    assert(r.status[2].kind == "active" and r.status[3].kind == "idle")
    r = M3.resolve(cfg, {hp = 25})
    assert(math.abs(r.drives["group:Face"].chain - 1.5) < 1e-9 and r.status[3].kind == "active")
    r = M3.resolve(cfg, {hp = 25, hit = true})
    assert(r.drives["group:Face"] == nil, "a higher normal state claims the layer")
    assert(r.targets[2][1].kind == "lose" and r.targets[2][1].by == 1)
end

-- ============================================================ OpsV3
do
    local cfg = cfg3({st("fight", "battle", {{group = "Coat", option = "Wear"}}, {base = "Shirt"})})
    -- 改名牵动引用
    assert(OpsV3.rename_group(cfg, "Coat", "Jacket"))
    assert(cfg.conditions.states[1].targets[1].group == "Jacket")
    assert(OpsV3.rename_option(cfg, "Jacket", "Wear", "On"))
    assert(cfg.conditions.states[1].targets[1].option == "On")
    local g = M3.find_group(cfg, "Jacket")
    assert(g.active == "On" and g.order[#g.order] == "On" or g.order[1] == "On")
    assert(OpsV3.rename_base(cfg, "Shirt", "T"))
    assert(cfg.conditions.states[1].base == "T" and cfg.base.presets.T)
    assert(not OpsV3.rename_group(cfg, "Jacket", "Face"), "name collision rejected")

    -- 作用域
    assert(OpsV3.scope_add(cfg, "Jacket", "head", "b1"), "a material may belong to several groups")
    assert(not OpsV3.scope_add(cfg, "Jacket", "head", "b1"), "already in scope")
    assert(OpsV3.scope_remove(cfg, "Jacket", "head", "b1"))
    assert(OpsV3.scope_add(cfg, "Jacket", "body", "sleeve"))
    assert(OpsV3.set_option_material(cfg, "Jacket", "On", "body", "sleeve", "on"))
    assert(g.options.On.body.materials.sleeve == true)
    assert(not OpsV3.set_option_material(cfg, "Jacket", "On", "hair", "x", "on"), "outside scope rejected")
    assert(OpsV3.scope_remove(cfg, "Jacket", "body", "sleeve"))
    assert(g.options.On.body.materials.sleeve == nil, "removing from scope clears option values")
    assert(OpsV3.set_option_material(cfg, "Jacket", "Torn", "body", "j", "none"))
    assert(g.options.Torn.body == nil, "empty slot table dropped")
    -- 批量改作用域
    local n0 = #g.scope
    assert(OpsV3.scope_set(cfg, "Jacket", { { slot = "head", material = "b1" }, { slot = "head", material = "b2" } }, {}))
    assert(#g.scope == n0 + 2)
    assert(not OpsV3.scope_set(cfg, "Jacket", { { slot = "head", material = "b1" } }, {}), "nothing new to add")
    assert(OpsV3.set_option_material(cfg, "Jacket", "On", "head", "b2", "on"))
    local changed, reapply = OpsV3.scope_set(cfg, "Jacket", {}, { { slot = "head", material = "b1" }, { slot = "head", material = "b2" } })
    assert(changed and reapply and #g.scope == n0)
    assert(g.options.On.head == nil, "bulk removal clears option values")
    assert(not OpsV3.scope_set(cfg, "Nope", {}, {}), "unknown group")

    -- 选项增删
    local _, _, name = OpsV3.new_option(cfg, "Face")
    assert(name == "1" and M3.find_group(cfg, "Face").active == "1")
    local _, _, dup = OpsV3.duplicate_option(cfg, "Face", "Hurt")
    assert(dup == "Hurt_1" and M3.find_group(cfg, "Face").options.Hurt_1.head.materials.b1 == true)
    assert(OpsV3.delete_option(cfg, "Face", "Hurt_1"))
    assert(OpsV3.set_manual(cfg, "Face", "Hurt") and M3.find_group(cfg, "Face").active == "Hurt")
    assert(not OpsV3.set_manual(cfg, "Face", "Missing"))
    assert(OpsV3.set_manual(cfg, "base", "Full"))

    -- 条件状态
    local _, _, idx = OpsV3.new_state(cfg, "new")
    assert(idx == 2)
    assert(OpsV3.add_condition(cfg, 2, {type = "hit"}))
    assert(OpsV3.set_state_target(cfg, 2, "Face", "Hurt"))
    assert(OpsV3.set_state_target(cfg, 2, "Face", "Bloody") and #cfg.conditions.states[2].targets == 1)
    assert(not OpsV3.change_target_group(cfg, 2, 1, "Missing"))
    assert(OpsV3.change_target_group(cfg, 2, 1, "Jacket"))
    S.equal(cfg.conditions.states[2].targets, {{group = "Jacket", option = g.order[1]}})
    assert(OpsV3.set_state_field(cfg, 2, "exclusive", true))
    assert(not OpsV3.set_state_field(cfg, 2, "logic", "XOR"))
    assert(OpsV3.set_state_field(cfg, 2, "fade_in", 99) and cfg.conditions.states[2].fade_in == 30)
    assert(OpsV3.set_state_hp(cfg, 2, {upper = 120, lower = -3}))
    S.equal(cfg.conditions.states[2].hp, {upper = 100, lower = 0, invert = false})
    assert(OpsV3.set_state_base(cfg, 2, "Full") and not OpsV3.set_state_base(cfg, 2, "Missing"))
    assert(OpsV3.move_state(cfg, 2, 1) and cfg.conditions.states[1].name == "new")
    assert(not OpsV3.move_state(cfg, 1, 5))
    assert(OpsV3.delete_condition(cfg, 1, 1) and #cfg.conditions.states[1].conditions == 0)
    assert(OpsV3.remove_state_target(cfg, 1, 1) and #cfg.conditions.states[1].targets == 0)
    assert(OpsV3.delete_state(cfg, 1) and #cfg.conditions.states == 1)
    assert(OpsV3.set_auto(cfg, false) and cfg.conditions.auto == false)
    assert(OpsV3.delete_group(cfg, "Face") and not M3.find_group(cfg, "Face"))
end

-- ============================================================ TransformManager.resolve 走 v3
do

    local saved_all, saved_usable = Utils.all_enabled_preset, TM.usable_slots
    Utils.all_enabled_preset = function()
        return {body = {materials = {a = true, j = true, x = true}}, head = {materials = {b1 = true, b2 = true}}}
    end
    TM.usable_slots = function() return {body = true, head = true} end
    local cfg = cfg3({
        st("fight", "battle", {{group = "Coat", option = "Torn"}}, {base = "Shirt", fade_in = 0.4, fade_out = 1}),
    }, {armor_mirrors_body = true})
    M3.find_group(cfg, "Face").active = "Hurt"
    local resolved, changed, info = TM.resolve("t1", cfg, {}, nil)
    S.equal(resolved.body.materials, {a = true, j = true, x = true})
    S.equal(resolved.head.materials, {b1 = true, b2 = true})
    S.equal(resolved.armor.materials, resolved.body.materials, "armor mirrors body")
    assert(changed and info.owner.head.b1 == "group:Face" and info.owner.body.j == "group:Coat")
    assert(info.layers["group:Face"].prio == nil, "manual pick has no priority")
    local _, again = TM.resolve("t1", cfg, {}, nil)
    assert(not again, "same picks = unchanged")

    resolved, changed, info = TM.resolve("t1", cfg, {battle = true}, nil)
    assert(changed and resolved.body.materials.a == false and resolved.body.materials.j == false)
    assert(info.owner.body.a == "base" and info.layers.base.prio == 1)
    local tr = info.layers.base.rule
    assert(tr.dissolve_enabled and tr.dissolve_hide_time == 0.4 and tr.dissolve_show_time == 1)
    assert(info.v3.status[1].kind == "active")
    Utils.all_enabled_preset, TM.usable_slots = saved_all, saved_usable
end

print("PASS: v3 normalize, v2 migration equivalence (16 condition combinations, picks and final materials), overlapping groups, claims / partial / exclusive / broken / paused, hold, HP chains and OpsV3 edits")
