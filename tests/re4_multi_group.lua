-- RE4 复选状态组:规范化、解算(各选项各自一层,组内按选项顺序叠加)、条件状态只接管目标选项、
-- 高度 / SKS / 调色引用按打开的选项叠加、OpsV3 的开关 / 选择方式切换 / 新建 / 复制 / 改名 / 删除、快捷键。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = { find_type_definition = function() return nil end, is_managed_object = function() return false end }
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local TM = require("ArmorVariantManager_Core.Games.RE4.TransformManager")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")

Registry.eval_condition = function(c, ctx) return ctx[c.type] == true end
local now = 0
M3.clock = function() return now end

local function snap(slot, mats) return { [slot] = { materials = mats } } end

Utils.all_enabled_preset = function() return { body = { materials = { hat = true, scarf = true, coat = true } } } end
TM.usable_slots = function() return { body = true } end

local function new_cfg()
    return M3.normalize({
        version = 3, base = { presets = { A = {} }, order = { "A" }, active = "A" },
        groups = {
            { name = "配件", multi = true, order = { "无帽", "无围巾", "全关" },
              options = { ["无帽"] = snap("body", { hat = false }), ["无围巾"] = snap("body", { scarf = false }),
                          ["全关"] = snap("body", { hat = true, scarf = true, coat = false }) },
              actives = { "无围巾", "不存在", "无帽", "无帽" }, active = "无帽",
              heights = { ["无帽"] = 2, ["无围巾"] = 5 }, sks = { ["无帽"] = { ["头"] = "短发" }, ["无围巾"] = { ["头"] = "长发" } } },
            { name = "单", options = { X = {} }, order = { "X" }, active = "X" },
        },
        conditions = { states = { { name = "冷", conditions = { { type = "cold" } }, targets = { { group = "配件", option = "全关" } } } } },
        armor_mirrors_body = false,
    })
end

-- ---------------------------------------------------------------- 规范化
local cfg = new_cfg()
local g = M3.find_group(cfg, "配件")
assert(g.multi == true and g.active == "", "multi group keeps multi, active is always empty")
S.equal(g.actives, { "无帽", "无围巾" }, "actives: existing options only, deduplicated, in option order")
assert(M3.find_group(cfg, "单").multi == nil and M3.find_group(cfg, "单").actives == nil, "single groups have no actives")
assert(M3.parse_layer_key(M3.option_key("配件", "无帽")) == "配件")
assert(select(2, M3.parse_layer_key(M3.option_key("配件", "无帽"))) == "无帽")
assert(select(2, M3.parse_layer_key(M3.layer_key("单"))) == nil)

-- ---------------------------------------------------------------- 解算
local seq = 0
local function res(ctx)
    seq = seq + 1
    local resolved, _, info = TM.resolve("mg" .. seq, cfg, ctx or {}, nil)
    return resolved.body.materials, info
end
local m, info = res()
S.equal(m, { hat = false, scarf = false, coat = true }, "two options on at once")
S.equal(M3.group_picks(g, info.v3.picks), { "无帽", "无围巾" }, "group_picks in option order")
assert(M3.height_of(cfg, info.v3.picks) == 5, "heights stack in option order (later option wins)")
assert(M3.sks_of(cfg, info.v3.picks)["头"] == "长发", "SKS refs stack in option order")

-- 条件状态只接管目标选项:「全关」打开,写回 hat / scarf,其余选项照旧手动
m, info = res({ cold = true })
S.equal(m, { hat = true, scarf = true, coat = false }, "condition turns its option on; later option wins")
local okey = M3.option_key("配件", "全关")
assert(info.layers[okey].prio == 1 and info.layers[M3.option_key("配件", "无帽")].prio == nil,
    "only the target option is taken over")
S.equal(M3.group_picks(g, info.v3.picks), { "无帽", "无围巾", "全关" })

-- 选项顺序决定谁说了算
assert(OpsV3.move_option(cfg, "配件", "全关", -2))
m = res({ cold = true })
S.equal(m, { hat = false, scarf = false, coat = false }, "moving the option up lets the others win")

-- ---------------------------------------------------------------- OpsV3
cfg = new_cfg(); g = M3.find_group(cfg, "配件")
assert(OpsV3.set_option_on(cfg, "配件", "全关", true) and M3.is_on(g, "全关"))
assert(not OpsV3.set_option_on(cfg, "配件", "全关", true), "already on -> no change")
assert(OpsV3.set_option_on(cfg, "配件", "无帽", false) and not M3.is_on(g, "无帽"))
S.equal(g.actives, { "无围巾", "全关" }, "actives stay in option order")
assert(not OpsV3.set_option_on(cfg, "单", "X", true), "single groups reject set_option_on")
assert(OpsV3.set_manual(cfg, "配件", "无帽") and M3.is_on(g, "无帽"), "set_manual toggles on a multi group")
assert(OpsV3.set_manual(cfg, "配件", "无帽") and not M3.is_on(g, "无帽"), "and toggles back")
assert(OpsV3.set_manual(cfg, "配件", "") and #g.actives == 0, "\"\" turns every option off")
assert(not OpsV3.set_manual(cfg, "配件", ""), "already all off -> no change")

-- 新建 / 复制的选项直接打开;改名 / 删除跟着改
local ok, _, name = OpsV3.new_option(cfg, "配件", "新")
assert(ok and M3.is_on(g, "新") and g.active == "", "new option is switched on")
ok, _, name = OpsV3.duplicate_option(cfg, "配件", "新")
assert(ok and M3.is_on(g, name) and g.active == "", "duplicated option is switched on, active stays empty")
assert(OpsV3.rename_option(cfg, "配件", "新", "新2") and M3.is_on(g, "新2") and not M3.is_on(g, "新"), "rename follows")
assert(OpsV3.delete_option(cfg, "配件", "新2") and not M3.is_on(g, "新2"), "delete drops it from actives")

-- 选择方式切换
cfg = new_cfg(); g = M3.find_group(cfg, "配件")
assert(OpsV3.set_group_multi(cfg, "配件", false))
assert(g.multi == nil and g.actives == nil and g.active == "无围巾", "to single: keep the last enabled option in order")
assert(not OpsV3.set_group_multi(cfg, "配件", false), "same mode -> no change")
assert(OpsV3.set_group_multi(cfg, "配件", true))
assert(g.multi == true and g.active == "" and #g.actives == 1 and g.actives[1] == "无围巾", "to multi: the selected option stays on")
local single = M3.find_group(cfg, "单")
single.active = ""
assert(OpsV3.set_group_multi(cfg, "单", true) and #single.actives == 0, "(none) becomes all off")

-- 快捷键:复选组没有轮换,单项键切换开关
cfg = new_cfg(); g = M3.find_group(cfg, "配件")
cfg.hotkeys = { ["1"] = { kind = "group", group = "配件" }, ["2"] = { kind = "group", group = "配件", option = "全关" },
                ["3"] = { kind = "group", group = "单" } }
M3.clean_hotkey_table(cfg)
assert(cfg.hotkeys["1"] == nil and cfg.hotkeys["2"] ~= nil and cfg.hotkeys["3"] ~= nil, "cycle key dropped on multi groups only")
assert(OpsV3.set_group_multi(cfg, "单", true) and cfg.hotkeys["3"] == nil, "switching to multi drops the group's cycle key")

-- 旧配置(没有 multi)照旧是单选
local old = M3.normalize({ version = 3, base = { presets = {} }, groups = { { name = "G", options = { a = {} }, active = "a", actives = { "a" } } } })
assert(old.groups[1].multi == nil and old.groups[1].actives == nil and old.groups[1].active == "a", "configs without multi stay single")

-- 只有引用、没有材质的选项:REFramework 的 json 把空快照写成 null,读回来时按 order 补回,引用跟着保住
local reloaded = M3.normalize({ version = 3, base = { presets = { A = {} }, order = { "A", "B" }, sks = { B = { ["鞋跟"] = "高跟" } } },
    groups = { { name = "龙装", multi = true, order = { "半透", "胸前", "私处" }, options = { ["半透"] = snap("body", { a = false }) },
                 actives = { "胸前", "私处" }, sks = { ["胸前"] = { ["遮挡"] = "开" }, ["私处"] = { ["遮挡2"] = "开" } } } } })
local lg = reloaded.groups[1]
assert(lg.options["胸前"] and lg.options["私处"], "options saved as null come back from order")
S.equal(lg.order, { "半透", "胸前", "私处" }, "order kept")
S.equal(lg.actives, { "胸前", "私处" }, "their switches are kept")
assert(lg.sks["胸前"]["遮挡"] == "开" and lg.sks["私处"]["遮挡2"] == "开", "their SKS refs are kept")
assert(reloaded.base.presets.B and reloaded.base.sks.B["鞋跟"] == "高跟", "same for full-outfit presets")

print("PASS: RE4 multiple-selection state groups: cleaning, per-option layers stacked in option order, conditions take over only their option, height / SKS stacking, toggles, mode switches, new / duplicate / rename / delete, hotkeys")
