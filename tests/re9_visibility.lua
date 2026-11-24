-- RE9 显隐:按网格可见性组(Viscon)读写,记录原值以便还原;同一资源的阴影网格跟随;
-- RE4 模块经 GameProfile 改走这套显隐和动态槛位。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

local Game = require("ArmorVariantManager_Core.Game")
local re9 = assert(Game.detect("re9"))
assert(re9.name == "RE9" and re9.standalone and not re9.wilds)
assert(re9.prefix == "ArmorVariantManager_Core.Games.RE9.")

-- 假网格:indices 是网格报告的启用组号(可重复、可越界),limit 是组数
local function mesh(indices, limit)
    local m = { enabled = {}, valid = true }
    for i = 0, limit - 1 do m.enabled[i] = true end
    local go = { call = function(_, method) if method == "get_Valid" then return m.valid end end }
    function m:get_address() return tostring(self) end
    function m:call(method, a, b)
        if method == "getPartsEnableIndicesCount" then return #indices
        elseif method == "getPartsEnableIndices" then return indices[a + 1]
        elseif method == "getPartsEnableCount" then return limit
        elseif method == "getPartsEnable" then return self.enabled[a]
        elseif method == "setPartsEnable" then self.enabled[a] = b
        elseif method == "get_GameObject" then return go
        elseif method == "get_MeshReady" then return true end
    end
    return m
end

local Visibility = require("ArmorVariantManager_Core.Games.RE9.Visibility")

-- 组号去重、去掉越界的、排序;名字是组号
local body = mesh({ 3, 0, 3, 7, 1 }, 5)
local shadow = mesh({ 3, 0, 3, 7, 1 }, 5)
Visibility.add(shadow, "body.mesh")
Visibility.add(body, "body.mesh", { shadow })
assert(Visibility.count(body) == 3)
assert(Visibility.name(body, 0) == "Viscon 000" and Visibility.name(body, 2) == "Viscon 003")
assert(Visibility.name(body, 3) == nil)

-- 关掉组 3:阴影同步;还原时回到原值
Visibility.set(body, 2, false)
assert(body.enabled[3] == false and shadow.enabled[3] == false)
assert(Visibility.get(body, 2) == false)
Visibility.set(body, 2, true)
Visibility.set(body, 2, false)
Visibility.reset()
assert(body.enabled[3] == true and shadow.enabled[3] == true)

-- refresh:这一轮没扫到的网格还原并移出缓存,换了资源的只移出
Visibility.add(body, "body.mesh")
Visibility.set(body, 0, false)
Visibility.refresh({})
assert(body.enabled[0] == true)
local hair = mesh({ 0, 1 }, 2)
Visibility.add(hair, "hair_a.mesh")
Visibility.set(hair, 0, false)
Visibility.refresh({ [hair:get_address()] = "hair_b.mesh" })
assert(hair.enabled[0] == false)
Visibility.reset()

-- RE4 的 Utils 经 GameProfile 走 Viscon 显隐,槛位包含 mesh_YY
local GameProfile = require("ArmorVariantManager_Core.Games.RE4.GameProfile")
assert(GameProfile.name == "RE4" and not GameProfile.re9 and GameProfile.config_dir == "ArmorVariantManager")
GameProfile.select("RE9", Visibility)
assert(GameProfile.re9 and GameProfile.config_dir == "ArmorVariantManagerRE9")
sdk = { is_managed_object = function(v) return type(v) == "table" end }
local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
local head = mesh({ 0, 2 }, 3)
Visibility.add(head, "head.mesh")
local source = { body = body, head = head, mesh_60 = hair, mesh_50 = hair }
Visibility.add(body, "body.mesh")
Visibility.add(hair, "hair.mesh")
local slots = Utils.slots(source)
assert(table.concat(slots, ",") == "body,head,mesh_50,mesh_60", table.concat(slots, ","))
local states = Utils.current_material_states(head)
assert(states["Viscon 000"] == true and states["Viscon 002"] == true and states["Viscon 001"] == nil)
Utils.apply_preset_to_slot(head, { materials = { ["Viscon 002"] = false } })
assert(head.enabled[2] == false and head.enabled[0] == true)
Visibility.reset()
assert(head.enabled[2] == true)

print("PASS re9_visibility")
