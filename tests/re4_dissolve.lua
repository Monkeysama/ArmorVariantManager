-- RE4 溶解:出现 = 消失倒放(比例 1 → 0,y 固定 0),先写全消失再开材质;消失结束关材质;
-- 中途反向从当前比例接着走;结束恢复 mdf2 的值;没有 Dissolve_Rate 的材质瞬间开关。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

_G.Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
local now = 0
os.clock = function() return now end
local Dissolve = require("ArmorVariantManager_Core.Games.RE4.Dissolve")

local function fake(vars)
    local m = { enabled = {}, values = {}, log = {} }
    local names = {}
    for i, n in ipairs(vars) do names[i - 1] = n end
    m.values[1] = { x = 1, y = 0, z = 0, w = 0 }   -- Dissolve_Flag 的 mdf2 默认
    m.values[0] = { x = 0, y = 0, z = 0, w = 0 }
    function m:call(method, j, a, b)
        if method == "getMaterialName" then return "mat" .. j
        elseif method == "get_MaterialNum" then return 1
        elseif method == "getMaterialVariableNum" then return #vars
        elseif method == "getMaterialVariableName" then return names[a]
        elseif method == "getMaterialFloat4" then return self.values[a]
        elseif method == "setMaterialFloat4" then
            self.values[a] = b
            self.log[#self.log + 1] = { "f4", a, b.x, b.y }
        elseif method == "setMaterialsEnable" then
            self.enabled[j] = a
            self.log[#self.log + 1] = { "en", a }
        end
    end
    return m
end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function tick(dt) now = now + dt; Dissolve.update() end
local ON = { enabled = true, dur = 1.0, forward = true }

-- 出现:先写成全消失(比例 1、y 0),然后才打开材质;比例一路降到 0,结束恢复原值
local m = fake({ "Dissolve_Rate", "Dissolve_Flag" })
m.enabled[0] = false
Dissolve.use(ON); Dissolve.set_material(m, 0, true, false); Dissolve.use(nil)
assert(m.log[1][1] == "f4" and m.log[1][2] == 0 and near(m.log[1][3], 1), "show must start fully dissolved")
assert(m.log[2][1] == "f4" and m.log[2][2] == 1 and m.log[2][4] == 0, "IsMorphed stays 0")
assert(m.log[3][1] == "en" and m.log[3][2] == true, "material enabled only after hidden start is written")
tick(0.05); tick(0.05); tick(0.1); tick(0.1); tick(0.1)   -- 0.4 秒
assert(near(m.values[0].x, 0.6), "show progresses from 1 toward 0: " .. m.values[0].x)
for _ = 1, 10 do tick(0.1) end
assert(m.enabled[0] == true and near(m.values[0].x, 0) and m.values[1].x == 1 and m.values[1].y == 0, "show ends visible and restored")
assert(not Dissolve.is_animating(m, 0))

-- 消失:比例 0 → 1,结束关材质;中途反向从当前比例接着走
Dissolve.use(ON); Dissolve.set_material(m, 0, false, true); Dissolve.use(nil)
assert(m.enabled[0] == true and near(m.values[0].x, 0), "hide starts intact")
tick(0.1); tick(0.1); tick(0.1)
assert(near(m.values[0].x, 0.3))
Dissolve.use(ON); Dissolve.set_material(m, 0, true, true); Dissolve.use(nil)
assert(near(m.values[0].x, 0.3), "reversal continues from the current amount")
tick(0.1)
assert(near(m.values[0].x, 0.2), "reversed show keeps shrinking the dissolved amount")
Dissolve.use(ON); Dissolve.set_material(m, 0, false, true); Dissolve.use(nil)
for _ = 1, 12 do tick(0.1) end
assert(m.enabled[0] == false and near(m.values[0].x, 0), "hide ends disabled and restored")

-- 方向只影响 w(溶解图走向),不影响出现 / 消失
Dissolve.use({ enabled = true, dur = 1.0, forward = false }); Dissolve.set_material(m, 0, true, false); Dissolve.use(nil)
assert(near(m.values[0].x, 1) and m.values[0].w == 1, "reverse direction still starts the show fully dissolved")
for _ = 1, 12 do tick(0.1) end

-- 血量驱动:出现方按进度 p 溶掉 1 - p
local d = fake({ "Dissolve_Rate", "Dissolve_Flag" })
Dissolve.drive_material(d, 0, true, 0.25, false)
assert(d.enabled[0] == true and near(d.values[0].x, 0.75), "driven show at p=0.25 is 75% dissolved")
Dissolve.drive_material(d, 0, false, 0.3, true)
assert(near(d.values[0].x, 0.3), "driven hide at p=0.3 is 30% dissolved")

-- 没有溶解变量:瞬间开关
local plain = fake({ "BaseColor" })
plain.enabled[0] = false
Dissolve.use(ON); Dissolve.set_material(plain, 0, true, false); Dissolve.use(nil)
assert(plain.enabled[0] == true and #plain.log == 1, "plain materials switch instantly")

-- 用哪一层的过渡:状态组选回"无"时材质交还整套造型,要带上放手那一层的过渡
local T = { ["group:脱"] = ON }
assert(Dissolve.transition_layer("group:脱", "base", T) == "group:脱", "owner with a transition wins")
assert(Dissolve.transition_layer("base", "group:脱", T) == "group:脱", "released layer's transition is used when the new owner has none")
assert(Dissolve.transition_layer("base", "base", T) == "base")
assert(Dissolve.transition_layer("base", "group:脱", nil) == "base", "no transitions (fresh apply): instant via owner")
assert(Dissolve.transition_layer(nil, "group:脱", T) == "group:脱", "unowned material falls back to the previous writer")
assert(Dissolve.transition_layer("base", "group:脱", { base = ON, ["group:脱"] = ON }) == "base", "owner's own transition first")
-- 两层都有过渡时用最近换过的那层:整套造型的旧过渡(seq 1)不能盖过状态组刚放手的过渡(seq 2)
assert(Dissolve.transition_layer("base", "group:脱", { base = { enabled = true, dur = 1, seq = 1 },
    ["group:脱"] = { enabled = true, dur = 0, seq = 2 } }) == "group:脱", "most recent transition wins")
assert(Dissolve.transition_layer("base", "group:脱", { base = { enabled = true, dur = 1, seq = 3 },
    ["group:脱"] = { enabled = true, dur = 0, seq = 2 } }) == "base", "owner wins when it changed more recently")

-- 定位预览:reset_mesh 停掉这个 mesh 上的定时过渡和血量驱动,变量恢复成 mdf2 的值
local r = fake({ "Dissolve_Rate", "Dissolve_Flag" })
r.enabled[0] = true
Dissolve.use(ON); Dissolve.set_material(r, 0, false, true); Dissolve.use(nil)
tick(0.1); tick(0.1); tick(0.1)
assert(Dissolve.is_animating(r, 0) and near(r.values[0].x, 0.3))
Dissolve.reset_mesh(r)
assert(not Dissolve.is_animating(r, 0) and near(r.values[0].x, 0) and r.values[1].y == 0 and r.enabled[0] == true,
    "reset_mesh stops the timed hide and restores the mdf2 values without toggling the material")
for _ = 1, 12 do tick(0.1) end
assert(r.enabled[0] == true, "a reset animation no longer disables the material later")
local rd = fake({ "Dissolve_Rate", "Dissolve_Flag" })
Dissolve.drive_material(rd, 0, true, 0.4, false)
assert(Dissolve.is_animating(rd, 0))
Dissolve.reset_mesh(rd)
assert(not Dissolve.is_animating(rd, 0) and near(rd.values[0].x, 0), "reset_mesh also ends HP-driven dissolve")
local other = fake({ "Dissolve_Rate", "Dissolve_Flag" })
Dissolve.use(ON); Dissolve.set_material(other, 0, false, true); Dissolve.use(nil)
Dissolve.reset_mesh(r)
assert(Dissolve.is_animating(other, 0), "other meshes are untouched")

print("PASS: RE4 dissolve show = reversed hide (fully dissolved before enable, IsMorphed 0), hide disables, mid-way reversal, direction, HP drive, plain materials, released-layer transitions and preview reset")
