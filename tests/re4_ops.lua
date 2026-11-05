-- RE4 共用操作：ImGui 与 REFF 共用的改配置语义（选择、自动、规则与条件、hold、溶解、血量驱动、全局设置）。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")

local function layer()
    return {presets = {Normal = {}, Hurt = {}, Low = {}}, order = {"Low", "Hurt", "Normal"},
        active = "", rules = {}, auto = true}
end
local function check(what, want_changed, want_reapply, changed, reapply)
    assert(changed == want_changed, what .. ": changed")
    assert((reapply == true) == want_reapply, what .. ": reapply")
end

-- 手动选择与自动
local l = layer()
check("select", true, true, Ops.set_active(l, "Hurt"))
assert(l.active == "Hurt")
check("select none", true, true, Ops.set_active(l, ""))
assert(l.active == "")
assert(not Ops.set_active(l, "Missing") and l.active == "", "unknown preset is rejected")
check("auto off", true, true, Ops.set_auto(l, false))
assert(l.auto == false)
Ops.set_auto(l, true)
assert(l.auto == true)

-- 条件：第一个条件建规则；再加条件时改整条规则的「关系」
local hp = Registry.get("hp_ratio")
local battle = Registry.get("is_battle")
assert(hp and battle, "known conditions are registered")
local c1 = Ops.make_condition(hp, "<=", "30")
S.equal(c1, {type = "hp_ratio", op = "<=", value = 30})
assert(Ops.make_condition(hp, "<=", "abc") == nil, "non-numeric value rejected")
assert(Ops.make_condition(hp, "!!", 30) == nil, "unknown numeric operator rejected")
S.equal(Ops.make_condition(battle, nil, true), {type = "is_battle", value = true})
check("first condition", true, true, Ops.add_condition(l, "Low", c1, "AND"))
assert(#l.rules == 1 and l.rules[1].preset == "Low" and l.rules[1].logic == "AND")
check("second condition", true, true, Ops.add_condition(l, "Low", Ops.make_condition(battle, nil, true), "OR"))
assert(#l.rules[1].conditions == 2 and l.rules[1].logic == "OR", "logic is shared by the whole rule")
assert(not Ops.add_condition(l, "Missing", c1, "AND"), "no rule for unknown preset")

-- hold：正数保留，0 / 非法值清掉
check("hold", true, true, Ops.set_hold(l, "Low", "2.5"))
assert(l.rules[1].hold == 2.5)
Ops.set_hold(l, "Low", "0")
assert(l.rules[1].hold == nil)
Ops.set_hold(l, "Low", "x")
assert(l.rules[1].hold == nil)
assert(not Ops.set_hold(l, "Normal", 1), "hold needs a rule")

-- 溶解过渡：开启时补默认时长；时长按 0.1 取整、限制在 0~10，只存盘不重写
check("dissolve on", true, false, Ops.set_dissolve(l, "Low", true))
assert(l.rules[1].dissolve_enabled == true and l.rules[1].dissolve_hide_time == 0.5 and l.rules[1].dissolve_show_time == 0.5)
check("dissolve time", true, false, Ops.set_dissolve_time(l, "Low", "dissolve_hide_time", 1.24))
assert(l.rules[1].dissolve_hide_time == 1.2)
Ops.set_dissolve_time(l, "Low", "dissolve_show_time", 99)
assert(l.rules[1].dissolve_show_time == 10)
assert(not Ops.set_dissolve_time(l, "Low", "hold", 1), "only dissolve time fields")
Ops.set_dissolve(l, "Low", false)
assert(l.rules[1].dissolve_enabled == nil and l.rules[1].dissolve_hide_time == 1.2, "times are kept when disabled")

-- 删条件：删光条件连规则一起删
check("delete condition", true, true, Ops.delete_condition(l, "Low", 2))
assert(#l.rules[1].conditions == 1)
Ops.delete_condition(l, "Low", 1)
assert(#l.rules == 0, "empty rule is removed")
assert(not Ops.delete_condition(l, "Low", 1))

-- 血量驱动：没有规则时建空规则；删光条件时保留；取消时空规则一并删
check("hp drive on", true, true, Ops.set_hp_driven(l, "Hurt", true))
local r = l.rules[1]
assert(r.preset == "Hurt" and r.dissolve_hp_driven and r.dissolve_hp_upper == 100 and r.dissolve_hp_lower == 0)
check("hp bound", true, false, Ops.set_hp_bound(l, "Hurt", "dissolve_hp_upper", 79.6))
assert(r.dissolve_hp_upper == 80)
Ops.set_hp_bound(l, "Hurt", "dissolve_hp_lower", -5)
assert(r.dissolve_hp_lower == 0)
check("hp invert", true, false, Ops.set_hp_invert(l, "Hurt", true))
assert(r.dissolve_hp_invert == true)
Ops.set_hp_invert(l, "Hurt", false)
assert(r.dissolve_hp_invert == nil)
Ops.add_condition(l, "Hurt", Ops.make_condition(battle, nil, true), "AND")
Ops.delete_condition(l, "Hurt", 1)
assert(#l.rules == 1 and l.rules[1] == r, "hp-driven rule survives losing its last condition")
Ops.set_hp_driven(l, "Hurt", false)
assert(#l.rules == 0, "the empty rule made for hp drive is removed")
Ops.add_condition(l, "Hurt", Ops.make_condition(battle, nil, true), "AND")
Ops.set_hp_driven(l, "Hurt", true)
Ops.set_hp_driven(l, "Hurt", false)
assert(#l.rules == 1 and l.rules[1].dissolve_hp_driven == nil, "a rule with conditions stays")
assert(not Ops.set_hp_driven(l, "Normal", false), "nothing to turn off")

-- 删规则
check("delete rule", true, true, Ops.delete_rule(l, 1))
assert(#l.rules == 0 and not Ops.delete_rule(l, 1))

-- 全局设置
local g = {language = "en"}
assert(Ops.set_global(g, "language", "zh") and g.language == "zh")
assert(not Ops.set_global(g, "language", "fr") and g.language == "zh")
assert(Ops.set_global(g, "weapon_hide_storage", true) and g.weapon_hide_storage == true)
assert(Ops.set_global(g, "ui_dissolve_enabled", false) and g.ui_dissolve_enabled == false)
assert(Ops.set_global(g, "ui_dissolve_time", 1.26) and g.ui_dissolve_time == 1.3)
assert(Ops.set_global(g, "ui_dissolve_time", 50) and g.ui_dissolve_time == 30)
assert(not Ops.set_global(g, "unknown", 1))
print("PASS: RE4 shared ops for selection, auto, rules/conditions, hold, dissolve, hp drive and global settings")

-- 第二阶段：预设 / 状态编辑、材质、批量、状态组、护甲镜像、备注
local p = Ops.new_layer()
S.equal(p, {presets = {}, active = "", rules = {}, order = {}, auto = true})
local ch, re, name = Ops.new_preset(p, {body = {materials = {Skin = true}}})
assert(ch and re and name == "1" and p.active == "1")
S.equal(p.order, {"1"})
_, _, name = Ops.new_preset(p, nil)
assert(name == "2" and p.active == "2" and next(p.presets["2"]) == nil, "axis presets start empty")
-- 复制：插在源后面、深拷贝、直接生效
ch, re, name = Ops.duplicate_preset(p, "1")
assert(ch and name == "1_1" and p.active == "1_1")
S.equal(p.order, {"1", "1_1", "2"})
p.presets["1_1"].body.materials.Skin = false
assert(p.presets["1"].body.materials.Skin == true, "duplicate is a deep copy")
_, _, name = Ops.duplicate_preset(p, "1")
assert(name == "1_2")
S.equal(p.order, {"1", "1_2", "1_1", "2"})
-- 改名：order 就地换名、手动选择与规则目标跟着改；撞名 / 空名拒绝；只存盘不重写
p.active = "1"; p.rules = {{conditions = {}, logic = "AND", preset = "1"}}
check("rename", true, false, Ops.rename_preset(p, "1", "Main"))
S.equal(p.order, {"Main", "1_2", "1_1", "2"})
assert(p.active == "Main" and p.rules[1].preset == "Main" and p.presets["1"] == nil)
assert(not Ops.rename_preset(p, "Main", "2") and not Ops.rename_preset(p, "Main", "") and not Ops.rename_preset(p, "x", "y"))
-- 移动 = 调优先级
check("move", true, true, Ops.move_preset(p, "2", -1))
S.equal(p.order, {"Main", "1_2", "2", "1_1"})
assert(not Ops.move_preset(p, "Main", -1) and not Ops.move_preset(p, "1_1", 1), "no move past the ends")
-- 删除：清掉手动选择，规则留成孤儿
check("delete preset", true, true, Ops.delete_preset(p, "Main"))
assert(p.presets.Main == nil and p.active == "" and p.rules[1].preset == "Main")
S.equal(p.order, {"1_2", "2", "1_1"})
assert(not Ops.delete_preset(p, "Main"))
check("replace", true, true, Ops.replace_preset(p, "2", {hair = {materials = {Hair = false}}}))
assert(p.presets["2"].hair.materials.Hair == false and not Ops.replace_preset(p, "missing", {}))

-- 材质：整套造型二值；状态组三态（none 不写进表）
local base_preset, axis_preset = {}, {}
check("base material", true, true, Ops.set_material(base_preset, "body", "Skin", false, true))
assert(base_preset.body.materials.Skin == false)
assert(not Ops.set_material(base_preset, "body", "Skin", "off", true), "base takes booleans only")
Ops.set_material(axis_preset, "hair", "Hair", "off", false)
assert(axis_preset.hair.materials.Hair == false)
Ops.set_material(axis_preset, "hair", "Hair", "on", false)
assert(axis_preset.hair.materials.Hair == true)
Ops.set_material(axis_preset, "hair", "Hair", "none", false)
assert(axis_preset.hair.materials.Hair == nil)
assert(not Ops.set_material(axis_preset, "hair", "Hair", true, false), "axis takes none/off/on")

-- 批量
local names = {"A", "B", "C"}
local bp = {body = {materials = {A = false}}}
Ops.bulk_slot(bp, "body", "invert", names, nil, true)
S.equal(bp.body.materials, {A = true, B = false, C = false})
Ops.bulk_slot(bp, "body", "all_off", names, nil, true)
S.equal(bp.body.materials, {A = false, B = false, C = false})
check("all on", true, true, Ops.bulk_slot(bp, "body", "all_on", names, nil, true))
S.equal(bp.body.materials, {A = true, B = true, C = true})
assert(not Ops.bulk_slot(bp, "body", "claim", names, {}, true), "claim is for state groups")
local ap = {}
Ops.bulk_slot(ap, "body", "claim", names, {A = false, B = true}, false)
S.equal(ap.body.materials, {A = false, B = true, C = true}, "unknown current state counts as shown")
Ops.bulk_slot(ap, "body", "release", names, nil, false)
S.equal(ap.body.materials, {})
assert(not Ops.bulk_slot(ap, "body", "all_on", names, nil, false), "all_on is for the full outfit")

-- 状态组
local cfg = {axes = {}, material_notes = {}}
check("new axis", true, true, Ops.new_axis(cfg, "Face"))
S.equal(cfg.axes.Face, {presets = {["1"] = {}}, active = "1", rules = {}, order = {"1"}, auto = true})
assert(not Ops.new_axis(cfg, "Face") and not Ops.new_axis(cfg, ""))
check("rename axis", true, false, Ops.rename_axis(cfg, "Face", "Expression"))
assert(cfg.axes.Face == nil and cfg.axes.Expression)
Ops.new_axis(cfg, "Hair")
assert(not Ops.rename_axis(cfg, "Expression", "Hair"), "no collision")
check("delete axis", true, true, Ops.delete_axis(cfg, "Hair"))
assert(cfg.axes.Hair == nil and not Ops.delete_axis(cfg, "Hair"))
check("armor mirror", true, true, Ops.set_armor_mirror(cfg, false))
assert(cfg.armor_mirrors_body == false)
check("note", true, false, Ops.set_note(cfg, "body", "Metal1", "Belt buckle"))
assert(cfg.material_notes.body.Metal1 == "Belt buckle")
Ops.set_note(cfg, "body", "Metal1", "")
assert(cfg.material_notes.body.Metal1 == nil, "empty note deletes it")
print("PASS: RE4 shared ops for preset/state editing, materials, bulk slot edits, state groups, armor mirror and notes")
