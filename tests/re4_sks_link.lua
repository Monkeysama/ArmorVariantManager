-- RE4 ShapeKeySystem 键组联动:配置里的 SKS 引用(清洗、按叠加顺序解算、改名 / 复制 / 删除跟着走、
-- OpsV3.set_sks_ref)和 SksLink 的发送规则(只发变了的、按角色合并、不在场不动、SKS 重置后重发、失败后扫描重试)。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

_G.sdk = { find_type_definition = function() return nil end, is_managed_object = function() return false end }
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local SksLink = require("ArmorVariantManager_Core.Games.RE4.SksLink")

-- ---------------------------------------------------------------- 清洗
local cfg = M3.normalize({
    base = { presets = { A = {}, B = {} }, order = { "A", "B" }, active = "A",
             sks = { A = { ["足部"] = "平底", ["胸"] = 0, Bad = 3, [""] = "x" }, B = {}, Gone = { ["足部"] = "高跟" } } },
    groups = {
        { name = "鞋", options = { Heel = {}, Flat = {} }, order = { "Heel", "Flat" }, active = "Heel",
          sks = { Heel = { ["足部"] = "高跟" }, Flat = { ["足部"] = "平底" } } },
        { name = "外套", options = { Off = {} }, order = { "Off" }, active = "",
          sks = { Off = { ["胸"] = "大" } } },
    },
})
local A = cfg.base.sks.A
assert(A["足部"] == "平底" and A["胸"] == 0, "string options and 0 are kept")
assert(A.Bad == nil and A[""] == nil, "other numbers and empty group names are dropped")
assert(cfg.base.sks.B == nil and cfg.base.sks.Gone == nil, "empty maps and dangling presets are dropped")
assert(M3.normalize({}).base.sks == nil, "configs without refs get nil")

-- ---------------------------------------------------------------- 解算:整套造型先写,状态组按顺序逐个键组覆盖
local shoe = cfg.groups[1]
local r = M3.sks_of(cfg, { base = "A" })
assert(r["足部"] == "平底" and r["胸"] == 0, "base preset refs")
r = M3.sks_of(cfg, { base = "A", ["group:鞋"] = "Heel" })
assert(r["足部"] == "高跟" and r["胸"] == 0, "group overrides one key group, keeps the others")
r = M3.sks_of(cfg, { base = "A", ["group:鞋"] = "Heel", ["group:外套"] = "Off" })
assert(r["足部"] == "高跟" and r["胸"] == "大", "later group wins for its own key group")
assert(M3.sks_of(cfg, { base = "B" }) == nil, "no layer writes a key group -> nil")
assert(M3.sks_of(cfg, { base = "B", ["group:鞋"] = "Flat" })["足部"] == "平底")

-- ---------------------------------------------------------------- OpsV3.set_sks_ref
assert(OpsV3.set_sks_ref(cfg, "base", "B", "足部", "高跟"), "set on base preset")
assert(cfg.base.sks.B["足部"] == "高跟")
assert(not OpsV3.set_sks_ref(cfg, "base", "B", "足部", "高跟"), "same value -> no change")
assert(OpsV3.set_sks_ref(cfg, "base", "B", "足部", 0) and cfg.base.sks.B["足部"] == 0, "0 = no option")
assert(OpsV3.set_sks_ref(cfg, "base", "B", "足部", "") and cfg.base.sks.B == nil, "\"\" clears; empty map removed")
assert(not OpsV3.set_sks_ref(cfg, "base", "Nope", "足部", "x"), "unknown preset rejected")
assert(not OpsV3.set_sks_ref(cfg, "鞋", "Heel", "", "x"), "empty group name rejected")
assert(not OpsV3.set_sks_ref(cfg, "鞋", "Heel", "足部", 2), "numbers other than 0 rejected")
assert(OpsV3.set_sks_ref(cfg, "鞋", "Heel", "腿", "长") and shoe.sks.Heel["腿"] == "长", "set on group option")

-- ---------------------------------------------------------------- 改名 / 复制 / 删除跟着走
assert(OpsV3.rename_option(cfg, "鞋", "Heel", "高跟鞋"))
assert(shoe.sks["高跟鞋"]["足部"] == "高跟" and shoe.sks.Heel == nil, "rename option moves refs")
local ok, _, copy = OpsV3.duplicate_option(cfg, "鞋", "高跟鞋")
assert(ok and shoe.sks[copy]["足部"] == "高跟", "duplicate copies refs")
shoe.sks[copy]["足部"] = "x"
assert(shoe.sks["高跟鞋"]["足部"] == "高跟", "duplicate is a deep copy")
assert(OpsV3.delete_option(cfg, "鞋", copy) and shoe.sks[copy] == nil, "delete option drops refs")
assert(OpsV3.rename_base(cfg, "A", "日常") and cfg.base.sks["日常"]["足部"] == "平底" and cfg.base.sks.A == nil,
    "rename base preset moves refs")

-- ---------------------------------------------------------------- SksLink:没装 SKS
_G.ShapeKeySystemAPI = nil
SksLink._reset()
assert(not SksLink.available())
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "高跟" }, player = true } })   -- 不报错
assert(SksLink.view("cha000_10") == nil, "no SKS -> view nil")

-- ---------------------------------------------------------------- SksLink:假的 SKS 1.1
local calls, scan_fns
local missing = {}   -- 当前配置没有的键组
local function fake_api()
    calls, scan_fns = {}, {}
    return {
        version = "1.1",
        on = function(ev, fn) if ev == "scan" then scan_fns[#scan_fns + 1] = fn end return #scan_fns end,
        actor_of = function(x) return ({ cha000_10 = "leon", cha800_10 = "ada" })[x] end,
        actors = function() return { { id = "leon", name = "Leon", folder = "leon_mod" }, { id = "ada", name = "Ada" } } end,
        select_group_option = function(owner, g, o, opts)
            calls[#calls + 1] = { owner = owner, group = g, option = o, actor = opts and opts.actor }
            if missing[g] then return false, "E_NOT_FOUND", "no such key group" end
            return true, nil, nil, { applied = true }
        end,
        key_groups = function(opts)
            if opts.actor ~= "leon" then return nil, "E_NOT_SCANNED" end
            return { { name = "足部", value = 2, options = { "平底", "高跟" } } }
        end,
        sculpt_presets = function(folder)
            assert(folder == "leon_mod", "presets filtered by the actor's folder")
            return { { name = "P1", key_groups = { { name = "足部", options = { "平底", "高跟", "赤足" } }, { name = "胸", options = { "小", "大" } } } } }
        end,
    }
end
_G.ShapeKeySystemAPI = fake_api()
SksLink._reset()
assert(SksLink.available())

local function find(group, actor)
    for _, c in ipairs(calls) do if c.group == group and (actor == nil or c.actor == actor) then return c end end
end

SksLink.push({ { head = "cha000_10", want = { ["足部"] = "高跟", ["胸"] = 0 }, player = true } })
assert(#calls == 2 and find("足部").option == "高跟" and find("胸").option == 0 and find("足部").actor == "leon")
assert(find("足部").owner == "ArmorVariantManager")
calls = {}
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "高跟", ["胸"] = 0 }, player = true } })
assert(#calls == 0, "unchanged -> nothing sent")
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "平底", ["胸"] = 0 }, player = true } })
assert(#calls == 1 and find("足部").option == "平底", "only the changed key group is sent")

-- 不再写到的键组还原成「（无）」(发一次 0);之后再写到时重新发送(哪怕和以前一样)
calls = {}
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "平底" }, player = true } })
assert(#calls == 1 and find("胸").option == 0, "dropped key group is reset to none once")
calls = {}
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "平底" }, player = true } })
assert(#calls == 0, "reset is sent only once")
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "平底", ["胸"] = "大" }, player = true } })
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "平底" }, player = true } })
assert(#calls == 2 and calls[1].option == "大" and calls[2].group == "胸" and calls[2].option == 0,
    "option then dropped -> back to none")
calls = {}
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "平底", ["胸"] = 0 }, player = true } })
assert(#calls == 1 and find("胸").option == 0, "key group written again is re-sent")

-- 同一个人:玩家说了算;另一个人各发各的
calls = {}
SksLink.push({
    { head = "cha000_10", want = { ["足部"] = "高跟" }, player = false },
    { head = "cha000_10", want = { ["足部"] = "赤足" }, player = true },
    { head = "cha800_10", want = { ["足部"] = "高跟" }, player = false },
    { head = "cha100_00", want = { ["足部"] = "高跟" }, player = false },   -- SKS 认不出(阿什莉)
})
assert(#calls == 3 and find("足部", "leon").option == "赤足" and find("足部", "ada").option == "高跟"
    and find("胸", "leon").option == 0, "player wins per actor; unknown actors skipped; leon's dropped key group reset")

-- 不在场的角色不动它的记录:回来时一样的值不重发
calls = {}
SksLink.push({})
SksLink.push({ { head = "cha800_10", want = { ["足部"] = "高跟" }, player = true } })
assert(#calls == 0, "absent actor keeps its record")

-- 发送失败的键组被丢掉时不发「（无）」
missing["腰"] = true
SksLink.push({ { head = "cha800_10", want = { ["足部"] = "高跟", ["腰"] = "细" }, player = true } })
calls = {}
SksLink.push({ { head = "cha800_10", want = { ["足部"] = "高跟" }, player = true } })
assert(#calls == 0, "a key group that never applied is not reset")
missing["腰"] = nil

-- 发送失败:记下错误码;SKS 扫描后重试
missing["胸"] = true
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "赤足", ["胸"] = "大" }, player = true } })
local v = SksLink.view("cha000_10")
assert(v.actor == "leon" and v.errors["胸"] == "E_NOT_FOUND", "failure is reported in the view")
calls = {}
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "赤足", ["胸"] = "大" }, player = true } })
assert(#calls == 0, "failed key group is not retried every frame")
missing["胸"] = nil
for _, fn in ipairs(scan_fns) do fn() end
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "赤足", ["胸"] = "大" }, player = true } })
assert(#calls == 1 and find("胸").option == "大", "failed key group is retried after an SKS scan")
assert(next(SksLink.view("cha000_10").errors) == nil, "error cleared after success")

-- 编辑界面:当前配置的键组 + 所有配置的并集
v = SksLink.view("cha000_10")
assert(v.name == "Leon" and #v.groups == 2)
local foot, chest = v.groups[1], v.groups[2]
assert(foot.name == "足部" and foot.inCurrent and foot.value == "高跟" and #foot.options == 3, "union of options")
assert(chest.name == "胸" and not chest.inCurrent and chest.value == nil)
assert(SksLink.view("cha100_00").actor == nil, "actor SKS does not know -> available, no actor")

-- SKS 重置(接口换成新表)后全部重发
_G.ShapeKeySystemAPI = fake_api()
SksLink.push({ { head = "cha000_10", want = { ["足部"] = "赤足", ["胸"] = "大" }, player = true } })
assert(#calls == 2, "new API table -> everything re-sent")

-- SKS 早于 1.1(没有 select_group_option):当作没装
_G.ShapeKeySystemAPI = { version = "1.0", set = function() end }
assert(not SksLink.available())

_G.ShapeKeySystemAPI = nil

-- ---------------------------------------------------------------- 造型归属(groups[i].bases,只影响快速切换页)
local c2 = M3.normalize({
    base = { presets = { Day = {}, Night = {}, Swim = {} }, order = { "Day", "Night", "Swim" }, active = "Day" },
    groups = { { name = "鞋", options = { Heel = {} }, order = { "Heel" }, active = "", bases = { "Day", "Gone", "Day", 3 } },
               { name = "帽", options = {}, order = {}, active = "", bases = {} } },
})
local g1, g2 = c2.groups[1], c2.groups[2]
assert(#g1.bases == 1 and g1.bases[1] == "Day", "bases keep existing preset names, deduplicated")
assert(g2.bases == nil, "empty list = all")
assert(M3.group_shown_for(g1, "Day") and not M3.group_shown_for(g1, "Night"), "shown only for listed outfits")
assert(M3.group_shown_for(g2, "Night") and M3.group_shown_for(g2, nil), "no scope = always shown")
assert(OpsV3.set_group_bases(c2, "鞋", { "Day", "Night" }) and #g1.bases == 2)
assert(not OpsV3.set_group_bases(c2, "鞋", { "Day", "Night" }), "same list -> no change")
assert(not OpsV3.set_group_bases(c2, "无", { "Day" }), "unknown group rejected")
assert(OpsV3.rename_base(c2, "Night", "夜") and g1.bases[2] == "夜", "rename outfit updates scopes")
assert(OpsV3.delete_base(c2, "Day") and #g1.bases == 1 and g1.bases[1] == "夜", "delete outfit removes it from scopes")
assert(OpsV3.delete_base(c2, "夜") and g1.bases == nil, "scope emptied by deletes falls back to all")
assert(OpsV3.set_group_bases(c2, "鞋", { "Swim" }) and OpsV3.set_group_bases(c2, "鞋", {}) and g1.bases == nil, "{} clears")

print("re4_sks_link ok")
