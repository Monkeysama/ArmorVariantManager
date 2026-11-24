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

-- 组开关只负责藏:「开」只放回 AVM 自己关掉的;游戏自己关掉的不强行打开,AVM 关掉后游戏又打开的也不再动
local game = mesh({}, { 0, 1, 2 }, 3)
game.part_on[1] = false
Viscon.set(game, 1, true)
assert(game.part_on[1] == false)
Viscon.set(game, 0, false)
assert(game.part_on[0] == false)
Viscon.set(game, 0, true)
assert(game.part_on[0] == true)
Viscon.set(game, 2, false)
game.part_on[2] = true
Viscon.set(game, 2, false)
assert(game.part_on[2] == false)
game.part_on[2] = true
Viscon.set(game, 2, true)
assert(game.part_on[2] == true)
Viscon.reset()
assert(game.part_on[1] == false and game.part_on[0] == true)

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

-- 哪一类被预设用到:整套造型里出现「关」才算,状态组写了就算;默认展开只展开用到的那类,都没用到时展开材质
local function usage(full, sparse) return { Viscon.usage(full, sparse) } end
local u = usage({ { Skin = true, ["Viscon 000"] = true } }, {})
assert(u[1] == false and u[2] == false)
u = usage({ { Skin = false, ["Viscon 000"] = true } }, {})
assert(u[1] == true and u[2] == false)
u = usage({ { Skin = true } }, { { ["Viscon 001"] = true } })
assert(u[1] == false and u[2] == true)
u = usage({ { Skin = false, ["Viscon 002"] = false } }, {})
assert(u[1] == true and u[2] == true)
local function open(mu, gu) return { Viscon.default_open(mu, gu) } end
assert(open(true, false)[1] == true and open(true, false)[2] == false)
assert(open(false, true)[1] == false and open(false, true)[2] == true)
assert(open(true, true)[1] == true and open(true, true)[2] == true)
assert(open(false, false)[1] == true and open(false, false)[2] == false)

-- 分段的「全部释放」只释放自己那段;原来的 release 整个部位清空
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local axis = { body = { materials = { Skin = false, Gone = true, ["Viscon 001"] = false } } }
assert(Ops.bulk_slot(axis, "body", "release_names", { "Viscon 001" }, nil, false))
assert(axis.body.materials.Skin == false and axis.body.materials.Gone == true and axis.body.materials["Viscon 001"] == nil)
assert(Ops.bulk_slot(axis, "body", "release", { "Skin" }, nil, false))
assert(next(axis.body.materials) == nil)

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

-- 认模型时两边只比同一类开关:只有材质的旧预设对加了组的网格仍是完全匹配
local old = { body = { materials = { Skin = true, Jacket = false, Belt = true } } }
assert(Utils.preset_slot_ratios({ body = modded }, old).body == 1)
assert(Utils.preset_match_ratio({ body = modded }, old) == 1)
local live = Presets.live_sets(Utils.all_enabled_preset({ body = modded }))
assert(live.body.Skin and live.body["Viscon 000"])
local cfg = { base = { presets = { A = { body = { materials = { Skin = true, Jacket = true, Belt = true } } } } } }
assert(Presets.match(cfg, live) == "full")
-- 只存了组的预设(RE9 移植版)按组比
local by_groups = { body = { materials = { ["Viscon 000"] = true, ["Viscon 002"] = false } } }
assert(Utils.preset_slot_ratios({ body = modded }, by_groups).body == 1)
local cfg_groups = { base = { presets = { A = by_groups } } }
assert(Presets.match(cfg_groups, live) == "full")
-- 指纹里没有的部位照原样比,不会因为过滤成两边都空而算作相同
assert(Presets.match(cfg, { body = live.body, hair = { Hair = true } }) ~= "full")

-- RE9:组单个也列;材质走 Mesh 里的位图(组位图后面紧跟 32 字节材质位图),写完重建组件才生效
GameProfile.select("RE9")
assert(GameProfile.re9 and GameProfile.config_dir == "ArmorVariantManagerRE9")
assert(GameProfile.materials and GameProfile.material_bits and GameProfile.groups_min == 1)

-- 假的 RE9 网格:没有 get/setMaterialsEnable;组开关在 PARTS 处的位图里,材质位图紧跟其后
local PARTS = 0x2C8
local function re9_mesh(materials, indices)
    local m = mesh(materials, indices, 256)
    local mem = {}
    for off = 0x100, 0x5EF do mem[off] = 0 end
    for off = PARTS, PARTS + 63 do mem[off] = 0xFF end
    mem[0x200] = 0x3C                      -- 无关字段
    m.mem, m.enabled, m.rebuilds = mem, true, 0
    local base_call = m.call
    function m:read_byte(off) return assert(self.mem[off], "read out of range") end
    function m:write_byte(off, v) self.mem[off] = v end
    function m:call(method, a, b)
        if method == "getMaterialsEnable" or method == "setMaterialsEnable" then error("not in TDB") end
        if method == "getPartsEnable" then return (self.mem[PARTS + a // 8] >> (a % 8)) & 1 == 1 end
        if method == "setPartsEnable" then
            local off = PARTS + a // 8
            self.mem[off] = b and (self.mem[off] | (1 << (a % 8))) or (self.mem[off] & ~(1 << (a % 8)) & 0xFF)
            self.mem[0x200] = (self.mem[0x200] + 1) & 0xFF     -- 渲染线程同时改的字段:校准要忽略它
            return
        end
        if method == "get_Enabled" then return self.enabled end
        if method == "set_Enabled" then
            if a == true and not self.enabled then self.rebuilds = self.rebuilds + 1 end
            self.enabled = a
            return
        end
        return base_call(self, method, a, b)
    end
    return m
end

Viscon.reset()
local hair9 = re9_mesh({ "Clothes", "Ear", "Hair" }, { 0, 3 })
local shadow9 = re9_mesh({ "Clothes", "Ear", "Hair" }, { 0, 3 })
Viscon.add(shadow9, "hair.mesh")
Viscon.add(hair9, "hair.mesh", { shadow9 })
assert(table.concat(Utils.get_material_names(hair9), ",") == "Clothes,Ear,Hair,Viscon 000,Viscon 003")
assert(Viscon.material_error() == nil)
assert(hair9.mem[PARTS + 31] == 0xFF, "calibration probe restored")
assert(Utils.visibility_get(hair9, 2) == true and Utils.visibility_kind(hair9, 2) == "material")

-- 关 Hair:只改材质位图第 2 位,阴影跟着改;帧末每个网格只重建一次
Utils.visibility_set(hair9, 2, false)
Utils.visibility_set(hair9, 1, false)
assert(hair9.mem[PARTS + 32] == 0xF9 and shadow9.mem[PARTS + 32] == 0xF9)
assert(hair9.mem[PARTS] == 0xFF, "group bitmap untouched")
assert(hair9.rebuilds == 0)
Viscon.flush()
assert(hair9.rebuilds == 1 and shadow9.rebuilds == 1 and hair9.enabled)
Viscon.flush()
assert(hair9.rebuilds == 1)
assert(Utils.visibility_get(hair9, 2) == false)
assert(Utils.current_material_states(hair9).Hair == false)

-- 游戏关掉的组件不会被重建打开
Utils.visibility_set(hair9, 0, false)
hair9.enabled = false
Viscon.flush()
assert(hair9.enabled == false and hair9.rebuilds == 1)
hair9.enabled = true

-- 溶解在 RE9 也改材质位图(RE9 没有 setMaterialsEnable):没有 Dissolve_Rate 的材质直接切
local Dissolve = require("ArmorVariantManager_Core.Games.RE4.Dissolve")
Dissolve.set_material(hair9, 2, true, false)
assert(Utils.visibility_get(hair9, 2) == true)

-- 脚本重置还原原值并重建
Viscon.reset()
assert(hair9.mem[PARTS + 32] == 0xFF and hair9.rebuilds == 2)

-- 校准不出来(读不到内存)时不列材质,只列组
local grace = mesh({ "Skin" }, { 0 }, 1)
assert(table.concat(Utils.get_material_names(grace), ",") == "Viscon 000")
assert(Viscon.material_error() ~= nil)
Utils.visibility_set(grace, 0, false)
assert(grace.part_on[0] == false and grace.mat_on[0] == true)
local slots = Utils.slots({ body = grace, head = vanilla, mesh_60 = hair, mesh_50 = hair, resource_identity = "x" })
assert(table.concat(slots, ",") == "body,head,mesh_50,mesh_60", table.concat(slots, ","))
-- 顺序:身体、头部、头发,左手、右手、下半身,其他部件按编号,饰品最后
local m = vanilla
slots = Utils.slots({ mesh_15 = m, mesh_45 = m, mesh_01 = m, hair = m, mesh_09 = m, mesh_02 = m, body = m, mesh_50 = m,
    mesh_08 = m, head = m, mesh_42 = m })
assert(table.concat(slots, ",") == "body,head,hair,mesh_02,mesh_01,mesh_50,mesh_08,mesh_45,mesh_09,mesh_15,mesh_42", table.concat(slots, ","))
Viscon.reset()
assert(grace.part_on[0] == true)

print("PASS re4_viscon")
