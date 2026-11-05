-- RE4 调色盘:映射清洗与识别(主映射 + 附加映射、优先级、外部覆盖内置、generic 兜底)、
-- 配置的写入 / 取消 / 清洗,以及写到 mesh 上:原值缓存、只动改过的分量、取消后还原、Dissolve_Flag 同步。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

_G.sdk = { find_type_definition = function() return nil end, is_managed_object = function() return false end }
_G.Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
local Palette = require("ArmorVariantManager_Core.Games.RE4.Palette")
local Builtin = require("ArmorVariantManager_Core.Games.RE4.PaletteProfiles")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")

local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ---------------------------------------------------------------- 内置映射
local profiles, by_id = Palette.load_profiles(Builtin, {})
assert(by_id.re4_liltoon and by_id.re4_transparent and by_id.re4_dissolve, "three built-in profiles")
assert(by_id.re4_dissolve.addon and not by_id.re4_liltoon.addon)
local entries = 0
for _, g in ipairs(by_id.re4_liltoon.groups) do entries = entries + #g.params end
assert(entries == 114, "lilToon profile keeps all 114 entries, got " .. entries)
assert(#by_id.re4_liltoon.sections == 5 and by_id.re4_liltoon.groups[1].section == "color", "sections and group sections survive cleaning")
for _, p in ipairs(profiles) do
    local known = {}
    for _, s in ipairs(p.sections) do known[s.id] = true end
    for _, g in ipairs(p.groups) do assert(known[g.section], p.id .. ": group " .. g.id .. " has a declared section") end
end

local F, F4 = Palette.TYPE_FLOAT, Palette.TYPE_FLOAT4
local liltoon = { LIL_Switch = F4, BaseColor = F4, LIL_ShadowColor = F4, LIL_ShadowParam = F4, Metallic = F }
local lil_dis = { LIL_Switch = F4, BaseColor = F4, Dissolve_Rate = F4, Dissolve_Flag = F4, Dissolve_Edge = F4 }
local glass = { LIL_EmissionParam = F4, Bulb_Color = F4, BaseColor = F4, Alpha = F, Dissolve_Rate = F4, Dissolve_Flag = F4 }
local vanilla = { BaseColor = F4, RimColor = F4, Metallic = F, Wind_SpeedXYZ = F4 }

local main, addons = Palette.match(profiles, liltoon)
assert(main.id == "re4_liltoon" and #addons == 0, "plain lilToon")
main, addons = Palette.match(profiles, lil_dis)
assert(main.id == "re4_liltoon" and #addons == 1 and addons[1].id == "re4_dissolve", "dissolve lilToon gets the addon")
main, addons = Palette.match(profiles, glass)
assert(main.id == "re4_transparent" and #addons == 1, "transparent + dissolve addon")
main, addons = Palette.match(profiles, vanilla)
assert(main == nil and #addons == 0, "vanilla material has no profile")
local gen = Palette.generic(vanilla)
assert(#gen == 2 and gen[1] == "BaseColor" and gen[2] == "RimColor", "generic lists *Color float4 only, sorted")

-- 能不能用:类型要对得上
local e_color = { param = "BaseColor", kind = "color" }
local e_comp = { param = "LIL_ShadowParam", kind = "float", component = "x" }
local e_float = { param = "Metallic", kind = "float" }
assert(Palette.entry_usable(e_color, liltoon) and Palette.entry_usable(e_comp, liltoon) and Palette.entry_usable(e_float, liltoon))
assert(not Palette.entry_usable({ param = "Metallic", kind = "color" }, liltoon), "float param cannot be a colour")
assert(not Palette.entry_usable({ param = "BaseColor", kind = "float" }, liltoon), "float4 needs a component")
assert(not Palette.entry_usable(e_color, {}), "missing param")

-- 外部映射:同 id 覆盖内置;优先级更高的先命中;格式不对的丢掉
local custom = { id = "my_toon", priority = 200, match = { all = { "LIL_Switch" }, none = { "Dissolve_Rate" } },
    groups = { { id = "a", params = { { param = "BaseColor", kind = "color" }, { param = "X", kind = "nope" } } } } }
local override = { id = "re4_transparent", priority = 100, match = { all = { "Bulb_Color" } }, groups = { { id = "b", params = { { param = "Alpha", kind = "float" } } } } }
local broken = { id = "bad", match = {}, groups = {} }
local p2, by2 = Palette.load_profiles(Builtin, { custom, override, broken, "junk" })
assert(by2.my_toon and #by2.my_toon.groups[1].params == 1, "invalid entries are dropped, the profile is kept")
assert(by2.bad == nil, "a profile without match rules is rejected")
assert(by2.re4_transparent.source == "data" and #by2.re4_transparent.groups == 1, "data profile replaces the built-in one with the same id")
assert(Palette.match(p2, liltoon).id == "my_toon", "higher priority wins")
assert(Palette.match(p2, lil_dis).id == "re4_liltoon", "none rule excludes")

-- ---------------------------------------------------------------- 配置
local cfg = {}
assert(Palette.set(cfg, { slot = "body", material = "Skin", param = "BaseColor", component = "x", value = 0.5 }))
assert(Palette.set(cfg, { slot = "body", material = "Skin", param = "BaseColor", component = "y", value = 0.25 }))
assert(Palette.set(cfg, { slot = "body", material = "Skin", param = "Metallic", value = 0.123456789 }))
assert(not Palette.set(cfg, { slot = "body", material = "Skin", param = "Metallic", value = 0.123456789 }), "same value is a no-op")
assert(not Palette.set(cfg, { slot = "body", material = "Skin", param = "BaseColor", component = "q", value = 1 }), "bad component")
assert(not Palette.set(cfg, { slot = "body", material = "Skin", param = "BaseColor", component = "x", value = 0 / 0 }), "NaN rejected")
local skin = cfg.palette.body.Skin
assert(skin.BaseColor.x == 0.5 and skin.BaseColor.y == 0.25 and skin.BaseColor.z == nil, "float4 stores only the changed components")
assert(near(skin.Metallic, 0.12346), "values are rounded to 1e-5")
assert(Palette.reset(cfg, "body", "Skin", "BaseColor", "x") and skin.BaseColor.x == nil and skin.BaseColor.y == 0.25)
assert(Palette.reset(cfg, "body", "Skin", "BaseColor", "y") and skin.BaseColor == nil, "last component removes the param")
assert(not Palette.reset(cfg, "body", "Skin", "BaseColor"), "nothing left to reset")
assert(Palette.reset(cfg, "body", "Skin") and cfg.palette.body == nil, "reset the whole material and drop empty tables")
local cleaned = Palette.clean({ body = { Skin = { A = 1, B = { x = 1, y = "no" }, C = { y = 0 / 0 }, D = "x" } }, hair = {} })
assert(cleaned.body.Skin.A == 1 and cleaned.body.Skin.B.x == 1 and cleaned.body.Skin.B.y == nil and cleaned.body.Skin.C == nil and cleaned.body.Skin.D == nil and cleaned.hair == nil)
-- ModelV3 一起清洗,空的不留
assert(M3.normalize({ palette = { body = {} } }).palette == nil)
assert(M3.normalize({ palette = { body = { Skin = { A = 2 } } } }).palette.body.Skin.A == 2)

-- ---------------------------------------------------------------- 写到 mesh 上
local function fake_mesh(mats)
    local m = { mats = mats, writes = 0 }
    function m:call(method, j, k, v)
        if method == "get_MaterialNum" then return #self.mats end
        local mat = self.mats[j + 1]
        if false then
        elseif method == "getMaterialName" then return mat.name
        elseif method == "getMaterialVariableNum" then return #mat.vars
        elseif method == "getMaterialVariableName" then return mat.vars[k + 1].name
        elseif method == "getMaterialVariableType" then return mat.vars[k + 1].t
        elseif method == "getMaterialFloat" then return mat.vars[k + 1].v
        elseif method == "getMaterialFloat4" then local x = mat.vars[k + 1].v; return { x = x[1], y = x[2], z = x[3], w = x[4] }
        elseif method == "setMaterialFloat" then mat.vars[k + 1].v = v; self.writes = self.writes + 1
        elseif method == "setMaterialFloat4" then mat.vars[k + 1].v = { v.x, v.y, v.z, v.w }; self.writes = self.writes + 1
        end
    end
    return m
end
local function var(mesh, j, name) for _, x in ipairs(mesh.mats[j + 1].vars) do if x.name == name then return x.v end end end
local mesh = fake_mesh({
    { name = "Skin", vars = { { name = "BaseColor", t = F4, v = { 1, 1, 1, 1 } }, { name = "Metallic", t = F, v = 0.2 },
                              { name = "Dissolve_Flag", t = F4, v = { 1, 0, 0, 0 } } } },
    { name = "Hair", vars = { { name = "BaseColor", t = F4, v = { 0.5, 0.5, 0.5, 1 } } } },
    { name = "Skin", vars = { { name = "BaseColor", t = F4, v = { 1, 1, 1, 1 } } } },   -- 同名材质
})
local state, synced = {}, {}
local function apply(ov) Palette.apply_mesh(mesh, ov, state, function(_, j, p, v) synced[#synced + 1] = { j, p, v } end) end

apply(nil)
assert(mesh.writes == 0, "nothing to do without overrides")
local rev0 = Palette.revision()
apply({ Skin = { BaseColor = { x = 0.2, z = 0.4 }, Metallic = 0.9 } })
assert(Palette.revision() > rev0, "revision goes up when values are written (the preview copy re-copies on change)")
local bc = var(mesh, 0, "BaseColor")
assert(near(bc[1], 0.2) and near(bc[2], 1) and near(bc[3], 0.4) and near(bc[4], 1), "only the overridden components change")
assert(near(var(mesh, 0, "Metallic"), 0.9) and near(var(mesh, 2, "BaseColor")[1], 0.2), "float written; same-named materials both follow")
assert(near(var(mesh, 1, "BaseColor")[1], 0.5), "other materials untouched")

-- 别的系统(溶解动画之类)改了没覆盖的分量:重写时保持它
mesh.mats[1].vars[1].v[2] = 0.7
apply({ Skin = { BaseColor = { x = 0.3 }, Metallic = 0.9 } })
bc = var(mesh, 0, "BaseColor")
assert(near(bc[1], 0.3) and near(bc[2], 0.7) and near(bc[3], 1), "z returns to its original once no longer overridden; y keeps the live value")

-- 取消全部覆盖:写回原值,之后不再写
apply(nil)
bc = var(mesh, 0, "BaseColor")
assert(near(bc[1], 1) and near(bc[3], 1) and near(var(mesh, 0, "Metallic"), 0.2), "originals restored")
local writes, rev1 = mesh.writes, Palette.revision()
apply(nil)
assert(Palette.revision() == rev1, "no writes, no new revision")
assert(mesh.writes == writes and next(state[tostring(mesh)].touched) == nil, "nothing tracked after restoring")

-- Dissolve_Flag:写入时回调(Main 用它同步溶解过渡的底值)
apply({ Skin = { Dissolve_Flag = { x = 0 } } })
assert(var(mesh, 0, "Dissolve_Flag")[1] == 0, "flag x written")
local last = synced[#synced]
assert(last[2] == "Dissolve_Flag" and last[3][1] == 0, "on_write receives the full written value")

-- 草稿
local draft = Palette.draft(mesh, 0)
assert(draft.groups[1].params[1].param == "BaseColor" and draft.groups[1].params[1].kind == "color" and draft.groups[1].params[2].kind == "float")

-- prune:换装后旧 mesh 的状态丢掉
Palette.prune(state, {})
assert(next(state) == nil)

print("PASS: RE4 palette: built-in profiles (114 lilToon entries), main + addon matching, priority, data override, generic fallback, type checks, sparse overrides, reset/clean, mesh writes (components, same-named materials, live components kept, restore), Dissolve_Flag sync, draft export and prune")
