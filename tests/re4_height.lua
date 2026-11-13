-- RE4 模型高度:配置里的高度表(清洗、按叠加顺序解算、改名 / 复制 / 删除跟着走、OpsV3.set_height)
-- 和 HeightFix 的写入时机(动画前还原、LateUpdateBehavior 前抬高、PrepareRendering 前兜底)。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

_G.sdk = { find_type_definition = function() return nil end, is_managed_object = function() return false end }
_G.Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local HeightFix = require("ArmorVariantManager_Core.Games.RE4.HeightFix")

local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ---------------------------------------------------------------- 清洗
local cfg = M3.normalize({
    base = { presets = { A = {}, B = {} }, order = { "A", "B" }, active = "A",
             heights = { A = 8, B = "x", Gone = 5 } },
    groups = {
        { name = "鞋", scope = {}, options = { Heel = {}, Flat = {} }, order = { "Heel", "Flat" }, active = "Heel",
          heights = { Heel = 12.34, Flat = 0, Gone = 3 } },
        { name = "跪", scope = {}, options = { Down = {} }, order = { "Down" }, active = "",
          heights = { Down = 999 } },
    },
})
assert(cfg.base.heights.A == 8 and cfg.base.heights.B == nil and cfg.base.heights.Gone == nil,
    "base heights keep valid numbers for existing presets only")
local shoe, kneel = cfg.groups[1], cfg.groups[2]
assert(shoe.heights.Heel == 12.3, "heights are rounded to 0.1 cm")
assert(shoe.heights.Flat == 0 and shoe.heights.Gone == nil, "0 is a valid explicit height; dangling names dropped")
assert(kneel.heights.Down == M3.HEIGHT_MAX, "heights are clamped")
assert(M3.clamp_height(-99) == M3.HEIGHT_MIN and M3.clamp_height("abc") == nil and M3.clamp_height(0 / 0) == nil)
assert(M3.HEIGHT_MIN == -20 and M3.clamp_height(-15) == -15 and M3.clamp_height(-25) == -20, "lower bound is -20 cm")
assert(next(M3.normalize({}).base.heights) == nil, "configs without heights get an empty table")

-- ---------------------------------------------------------------- 解算:整套造型先写,状态组按顺序覆盖
assert(M3.height_of(cfg, { base = "A" }) == 8, "base preset height")
assert(M3.height_of(cfg, { base = "A", ["group:鞋"] = "Heel" }) == 12.3, "group overrides base")
assert(M3.height_of(cfg, { base = "A", ["group:鞋"] = "Flat" }) == 0, "an explicit 0 also overrides (flat shoes cancel the outfit lift)")
assert(M3.height_of(cfg, { base = "B", ["group:鞋"] = "Heel", ["group:跪"] = "Down" }) == M3.HEIGHT_MAX, "later group wins")
assert(M3.height_of(cfg, { base = "B" }) == nil, "no layer sets a height -> nil")
assert(M3.height_of(cfg, {}) == nil and M3.height_of(nil, {}) == nil)

-- 来源
local _, src = M3.height_of(cfg, { base = "A", ["group:鞋"] = "Heel" })
assert(src.layer == "鞋" and src.option == "Heel", "source names the winning group and option")
_, src = M3.height_of(cfg, { base = "A" })
assert(src.layer == "base" and src.option == "A")
assert(select(2, M3.height_of(cfg, { base = "B" })) == nil, "no source when nothing sets a height")

-- ---------------------------------------------------------------- 全局覆盖
local ov = M3.normalize({ base = { presets = { A = {} }, order = { "A" }, heights = { A = 8 } } })
assert(ov.height_override == nil, "no override unless set")
assert(OpsV3.set_height_override(ov, nil, 20.04) and ov.height_override.cm == 20 and ov.height_override.enabled == false,
    "setting the value alone keeps it off")
assert(M3.height_of(ov, { base = "A" }) == 8, "override off: layers decide")
local oc, orr = OpsV3.set_height_override(ov, true, nil)
assert(oc and orr and ov.height_override.enabled and ov.height_override.cm == 20, "turning it on keeps the value and reapplies")
local h, hs = M3.height_of(ov, { base = "A" })
assert(h == 20 and hs.layer == "override", "override on: ignores the layers")
assert(M3.height_of(ov, nil) == 20, "override works without picks")
assert(not OpsV3.set_height_override(ov, true, 20), "same state is a no-op")
assert(not OpsV3.set_height_override(ov, "yes", nil) and not OpsV3.set_height_override(ov, nil, "x"), "bad input rejected")
assert(OpsV3.set_height_override(ov, nil, 0) and M3.height_of(ov, {}) == 0, "override 0 forces no lift")
assert(OpsV3.set_height_override(ov, false, nil) and M3.height_of(ov, { base = "A" }) == 8 and ov.height_override.cm == 0,
    "turning it off returns control to the layers and keeps the value")
local n = M3.normalize({ height_override = { enabled = 1, cm = 999 } })
assert(n.height_override.enabled == false and n.height_override.cm == M3.HEIGHT_MAX, "override is cleaned")

-- ---------------------------------------------------------------- OpsV3.set_height
local c, r = OpsV3.set_height(cfg, "base", "B", 4.26)
assert(c == true and r == true and cfg.base.heights.B == 4.3, "set base height (rounded, needs reapply)")
assert(not OpsV3.set_height(cfg, "base", "B", 4.3), "same value is a no-op")
assert(OpsV3.set_height(cfg, "base", "B", nil) and cfg.base.heights.B == nil, "nil clears")
assert(not OpsV3.set_height(cfg, "base", "B", nil), "clearing twice is a no-op")
assert(not OpsV3.set_height(cfg, "base", "Missing", 3), "unknown preset rejected")
assert(not OpsV3.set_height(cfg, "base", "A", "abc"), "non-number rejected")
assert(OpsV3.set_height(cfg, "鞋", "Flat", -2) and shoe.heights.Flat == -2, "set option height")
assert(not OpsV3.set_height(cfg, "没有", "Flat", 1), "unknown group rejected")
OpsV3.new_group(cfg, "新组"); OpsV3.new_option(cfg, "新组", "x")
assert(OpsV3.set_height(cfg, "新组", "x", 1) and M3.find_group(cfg, "新组").heights.x == 1,
    "a group created without a heights table gets one on first set")

-- ---------------------------------------------------------------- 改名 / 复制 / 删除跟着走
assert(OpsV3.rename_option(cfg, "鞋", "Heel", "高跟"))
assert(shoe.heights["高跟"] == 12.3 and shoe.heights.Heel == nil, "rename moves the option height")
assert(OpsV3.duplicate_option(cfg, "鞋", "高跟"))
assert(shoe.heights["高跟_1"] == 12.3, "duplicate copies the option height")
assert(OpsV3.delete_option(cfg, "鞋", "高跟_1") and shoe.heights["高跟_1"] == nil, "delete drops the option height")
assert(OpsV3.rename_base(cfg, "A", "日常") and cfg.base.heights["日常"] == 8 and cfg.base.heights.A == nil, "base rename")
assert(Ops.duplicate_preset(cfg.base, "日常") and cfg.base.heights["日常_1"] == 8, "base duplicate")
assert(OpsV3.delete_base(cfg, "日常_1") and cfg.base.heights["日常_1"] == nil, "base delete")
local v2layer = { presets = { P = {} }, order = { "P" }, active = "P", rules = {} }
assert(Ops.rename_preset(v2layer, "P", "Q") and Ops.duplicate_preset(v2layer, "Q") and Ops.delete_preset(v2layer, "Q"),
    "v2 layers without heights still work")
-- 深拷贝(预设库)后重新清洗,高度保留
local again = M3.normalize(M3.normalize(cfg))
assert(again.base.heights["日常"] == 8 and again.groups[1].heights["高跟"] == 12.3)

-- ---------------------------------------------------------------- HeightFix
local entries = {}
local fake_re = {
    on_pre_application_entry = function(name, fn) entries[name] = fn end,
    on_script_reset = function(fn) entries.reset = fn end,
}
local function joint(addr)
    local j = { addr = addr, origin = { x = 1, y = 2, z = 3 }, lp = { x = 0, y = 0, z = 0 }, sets = 0 }
    function j:get_address() return self.addr end
    function j:call(m, v)
        if m == "get_LocalPosition" then return { x = self.lp.x, y = self.lp.y, z = self.lp.z }
        elseif m == "set_LocalPosition" then self.lp = { x = v.x, y = v.y, z = v.z }
        elseif m == "get_Position" then return { x = self.origin.x + self.lp.x, y = self.origin.y + self.lp.y, z = self.origin.z + self.lp.z }
        elseif m == "set_Position" then
            self.sets = self.sets + 1
            self.lp = { x = v.x - self.origin.x, y = v.y - self.origin.y, z = v.z - self.origin.z }
        end
    end
    return j
end
local function skeleton(j) return { call = function(_, m, n) if m == "getJointByName" and n == "root" then return j end end } end
local leon, ashley = joint(1), joint(2)
local skel = { leon = skeleton(leon), ashley = skeleton(ashley), shared = skeleton(leon) }
local errors = {}
local hf = HeightFix.new({ re = fake_re, skeleton_of = function(s) return skel[s] end,
    on_error = function(m) errors[#errors + 1] = m end })
assert(entries.UpdateMotion and entries.LateUpdateBehavior and entries.PrepareRendering and entries.reset,
    "restore before animation, lift before LateUpdateBehavior (camera sees the lifted pose), fallback before rendering")

local function frame(late, fallback)
    entries.UpdateMotion()
    if late ~= false then entries.LateUpdateBehavior() end
    if fallback ~= false then entries.PrepareRendering() end
end

hf.set_targets({ { source = "leon", cm = 10 }, { source = "ashley", cm = 0 }, { source = "shared", cm = 5 } })
frame()
assert(near(leon.lp.y, 0.10) and leon.sets == 1, "lifts root by 10 cm once; a second target on the same skeleton does not stack")
assert(ashley.sets == 0 and near(ashley.lp.y, 0), "0 cm targets are skipped")
frame()
assert(near(leon.lp.y, 0.10) and leon.sets == 2, "restored before animation and lifted again: no accumulation")

-- 动画把 root 改了(局部坐标不再是我们写的值):还原时不碰,兜底以新值为底再抬
entries.UpdateMotion()
entries.LateUpdateBehavior()
leon.lp = { x = 0, y = 0.5, z = 0 }        -- 别的东西在我们之后写了 root
entries.PrepareRendering()
assert(near(leon.lp.y, 0.6), "fallback re-lifts on top of whatever overwrote root")
entries.UpdateMotion()
assert(near(leon.lp.y, 0.5), "restore goes back to the overwritten base, not to zero")
leon.lp = { x = 0, y = 0, z = 0 }

-- 只在兜底时机才出现的目标(这一帧 LateUpdateBehavior 已过)
local before = leon.sets
frame(false, true)
assert(near(leon.lp.y, 0.10) and leon.sets == before + 1, "fallback lifts targets missed earlier in the frame")

-- 别人改了 root 时,还原不覆盖
entries.LateUpdateBehavior()
leon.lp = { x = 0, y = 0.33, z = 0 }
entries.UpdateMotion()
assert(near(leon.lp.y, 0.33), "restore leaves a root someone else changed alone")
leon.lp = { x = 0, y = 0, z = 0 }

-- 目标消失 / 高度清零:下一帧还原后不再抬
hf.set_targets({ { source = "leon", cm = 10 } }); frame()
hf.set_targets({}); frame()
assert(near(leon.lp.y, 0), "removed targets are restored and not lifted again")

-- 解析骨架出错只记一次日志,不影响其他目标
skel.broken = setmetatable({}, { __index = function() error("boom") end })
hf.set_targets({ { source = "broken", cm = 3 }, { source = "ashley", cm = 3 } })
frame(); frame()
assert(near(ashley.lp.y, 0.03) and #errors == 1, "one broken target does not stop the others and is reported once")

-- 脚本重置:还原并停止
entries.reset()
assert(near(ashley.lp.y, 0), "script reset restores")
entries.LateUpdateBehavior()
assert(near(ashley.lp.y, 0), "no lifting after shutdown")


-- ---------------------------------------------------------------- 脚锁定点(IkLeg2)
-- 引擎在抬高后的姿态上记锁定点(世界坐标);下一帧 UpdateMotion 之后、IK 之前要减掉上一帧的抬高量
local e2 = {}
local re2 = {
    on_pre_application_entry = function(name, fn) e2["pre" .. name] = fn end,
    on_application_entry = function(name, fn) e2["post" .. name] = fn end,
}
local function fake_ik(addr)
    local ik = { addr = addr, lock = { [0] = { x = 0, y = 0, z = 0 }, [1] = { x = 0, y = 0, z = 0 } }, sets = 0, parent_local = false }
    function ik:get_address() return self.addr end
    function ik:call(m, i, v)
        if m == "get_FootLockParentLocal" then return self.parent_local
        elseif m == "getFootLockPosition" then local l = self.lock[i]; return { x = l.x, y = l.y, z = l.z }
        elseif m == "setFootLockPosition" then self.sets = self.sets + 1; self.lock[i] = { x = v.x, y = v.y, z = v.z } end
    end
    return ik
end
local j2, ik2 = joint(10), fake_ik(20)
local hf2 = HeightFix.new({ re = re2, skeleton_of = function() return skeleton(j2) end, ik_of = function() return ik2 end })
local function frame2(capture)
    e2.preUpdateMotion(); e2.postUpdateMotion()   -- 还原,然后在 IK 之前修锁定点
    e2.preLateUpdateBehavior(); e2.prePrepareRendering()
    if capture then ik2.lock[0] = { x = 0, y = capture, z = 0 } end  -- 引擎在抬高后的姿态上新记了一次
end
hf2.set_targets({ { source = "x", cm = 5 } })
frame2(1.05)                                     -- 脚落地,锁定点记在抬高后的 1.05
frame2()
assert(near(ik2.lock[0].y, 1.00), "lock point captured on the lifted pose is moved back down by the lift")
local sets = ik2.sets
frame2(); frame2()
assert(near(ik2.lock[0].y, 1.00) and ik2.sets == sets, "an unchanged (already fixed) lock point is not lowered again")
frame2(1.25); frame2()
assert(near(ik2.lock[0].y, 1.20), "a newly captured lock point is fixed once")
hf2.set_targets({}); frame2(); local y = ik2.lock[0].y; frame2()
assert(near(ik2.lock[0].y, y), "no lift -> lock points left alone")
ik2.parent_local = true; hf2.set_targets({ { source = "x", cm = 5 } }); frame2(2.05); frame2()
assert(near(ik2.lock[0].y, 2.05), "parent-local lock points are not touched")

print("PASS: RE4 model height: config cleaning, stacking (group over base, later group wins, explicit 0), OpsV3.set_height, rename/duplicate/delete carry heights, HeightFix restore-before-motion / lift-before-LateUpdateBehavior / fallback, shared skeletons, foreign writes, errors and reset, IK foot-lock correction")
