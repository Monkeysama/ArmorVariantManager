-- 网格可见性组(Viscon):改过的组记原值、按目标网格还原,阴影网格跟随;
-- 显隐下标里材质在前、组在后,RE4 要 2 个以上组才列出;认模型时不算组号。RE9 只列组。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

local Game = require("ArmorVariantManager_Core.Game")
local re9 = assert(Game.detect("re9"))
assert(re9.name == "RE9" and re9.standalone and not re9.wilds)
assert(re9.prefix == "ArmorVariantManager_Core.Games.RE9.")

-- 假网格:materials = 材质名列表;indices = 网格报告的启用组号(可重复、可越界),limit = 组数
local function mesh(materials, indices, limit)
    local m = { mat_on = {}, part_on = {}, valid = true }
    for i = 0, #materials - 1 do m.mat_on[i] = true end
    for i = 0, limit - 1 do m.part_on[i] = true end
    local go = { call = function(_, method) if method == "get_Valid" then return m.valid end end }
    function m:get_address() return tostring(self) end
    function m:call(method, a, b)
        if method == "get_MaterialNum" then return #materials
        elseif method == "getMaterialName" then return materials[a + 1]
        elseif method == "getMaterialsEnable" then return self.mat_on[a]
        elseif method == "setMaterialsEnable" then self.mat_on[a] = b
        elseif method == "getPartsEnableIndicesCount" then return #indices
        elseif method == "getPartsEnableIndices" then return indices[a + 1]
        elseif method == "getPartsEnableCount" then return limit
        elseif method == "getPartsEnable" then return self.part_on[a]
        elseif method == "setPartsEnable" then self.part_on[a] = b
        elseif method == "get_GameObject" then return go
        elseif method == "get_MeshReady" then return true end
    end
    return m
end

local Viscon = require("ArmorVariantManager_Core.Games.RE4.Viscon")
assert(Viscon.name(3) == "Viscon 003" and Viscon.is_name("Viscon 003"))
assert(not Viscon.is_name("Viscon 3") and not Viscon.is_name("Body"))

-- 组号去重、去掉越界的、排序
local body = mesh({}, { 3, 0, 3, 7, 1 }, 5)
local shadow = mesh({}, { 3, 0, 3, 7, 1 }, 5)
Viscon.add(shadow, "body.mesh")
Viscon.add(body, "body.mesh", { shadow })
assert(table.concat(Viscon.groups(body), ",") == "0,1,3")

-- 关掉组 3:阴影同步;重置时回到原值
Viscon.set(body, 3, false)
assert(body.part_on[3] == false and shadow.part_on[3] == false)
Viscon.set(body, 3, true)
Viscon.set(body, 3, false)
Viscon.reset()
assert(body.part_on[3] == true and shadow.part_on[3] == true)

-- refresh:没扫到的网格还原并移出;换了资源的只移出;读写时建的记录第一次 refresh 记下路径、原值保留
Viscon.add(body, "body.mesh")
Viscon.set(body, 0, false)
Viscon.refresh({})
assert(body.part_on[0] == true)
local hair = mesh({}, { 0, 1 }, 2)
Viscon.add(hair, "hair_a.mesh")
Viscon.set(hair, 0, false)
Viscon.refresh({ [hair:get_address()] = "hair_b.mesh" })
assert(hair.part_on[0] == false)
hair.part_on[0] = true
local lazy = mesh({}, { 0, 1 }, 2)
Viscon.set(lazy, 1, false)
Viscon.refresh({ [lazy:get_address()] = "lazy.mesh" })
assert(lazy.part_on[1] == false)
Viscon.refresh({})
assert(lazy.part_on[1] == true)

-- 读不到组(不是 Mesh)时是空表
assert(#Viscon.groups({ get_address = function() return "x" end, call = function() error("no method") end }) == 0)

-- RE4:材质在前、组在后;只有一个组的网格不列组
sdk = { is_managed_object = function(v) return type(v) == "table" end }
local GameProfile = require("ArmorVariantManager_Core.Games.RE4.GameProfile")
assert(GameProfile.name == "RE4" and GameProfile.materials and GameProfile.groups_min == 2)
local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
local Presets = require("ArmorVariantManager_Core.Games.RE4.Presets")

local vanilla = mesh({ "Skin", "Jacket" }, { 0 }, 256)
assert(Utils.visibility_count(vanilla) == 2)
assert(table.concat(Utils.get_material_names(vanilla), ",") == "Skin,Jacket")

local modded = mesh({ "Skin", "Jacket", "Belt" }, { 2, 0 }, 4)
assert(Utils.visibility_count(modded) == 5)
assert(table.concat(Utils.get_material_names(modded), ",") == "Skin,Jacket,Belt,Viscon 000,Viscon 002")
assert(Utils.visibility_kind(modded, 2) == "material" and Utils.visibility_kind(modded, 4) == "group")
assert(Utils.visibility_kind(modded, 5) == nil)

-- 组和材质各写各的开关
Utils.visibility_set(modded, 4, false)
assert(modded.part_on[2] == false and modded.mat_on[0] == true and modded.mat_on[2] == true)
Utils.visibility_set(modded, 1, false)
assert(modded.mat_on[1] == false and modded.part_on[1] == true)
Utils.apply_preset_to_slot(modded, { materials = { Jacket = true, ["Viscon 002"] = true, ["Viscon 000"] = false } })
assert(modded.mat_on[1] == true and modded.part_on[2] == true and modded.part_on[0] == false)
local states = Utils.current_material_states(modded)
assert(states.Jacket == true and states["Viscon 000"] == false and states["Viscon 002"] == true)
local captured = Utils.capture_current_as_preset({ body = modded })
assert(captured.body.materials["Viscon 000"] == false and captured.body.materials.Belt == true)
Viscon.reset()
assert(modded.part_on[0] == true and modded.part_on[2] == true)

-- 认模型时不算组号:只有材质的旧预设对加了组的网格仍是完全匹配
local old = { body = { materials = { Skin = true, Jacket = false, Belt = true } } }
assert(Utils.preset_slot_ratios({ body = modded }, old).body == 1)
assert(Utils.preset_match_ratio({ body = modded }, old) == 1)
local live = Presets.live_sets(Utils.all_enabled_preset({ body = modded }))
assert(live.body.Skin and live.body["Viscon 000"] == nil)
local fp = Presets.fingerprint({ base = { presets = { A = { body = { materials = { Skin = true, ["Viscon 002"] = false } } } } } })
assert(fp.body.Skin and fp.body["Viscon 002"] == nil)

-- RE9:只列组,单个组也列;认模型就靠组号
GameProfile.select("RE9")
assert(GameProfile.re9 and GameProfile.config_dir == "ArmorVariantManagerRE9")
assert(not GameProfile.materials and GameProfile.groups_min == 1)
local grace = mesh({ "Skin" }, { 0 }, 1)
assert(table.concat(Utils.get_material_names(grace), ",") == "Viscon 000")
Utils.visibility_set(grace, 0, false)
assert(grace.part_on[0] == false and grace.mat_on[0] == true)
local slots = Utils.slots({ body = grace, head = vanilla, mesh_60 = hair, mesh_50 = hair, resource_identity = "x" })
assert(table.concat(slots, ",") == "body,head,mesh_50,mesh_60", table.concat(slots, ","))
live = Presets.live_sets(Utils.all_enabled_preset({ body = grace }))
assert(live.body["Viscon 000"])
Viscon.reset()
assert(grace.part_on[0] == true)

print("PASS re4_viscon")
