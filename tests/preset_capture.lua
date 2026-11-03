package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local mesh_type = {get_method=function() return false end}
sdk = {is_managed_object=function() return true end}
local function mesh(enabled, materials)
    return {
        get_type_definition=function() return mesh_type end,
        call=function(_, method, index)
            if method == "get_Enabled" then return enabled end
            if method == "get_MaterialNum" then return #materials end
            if method == "getMaterialName" then return materials[index + 1][1] end
            if method == "getMaterialsEnable" then return materials[index + 1][2] end
            error(method)
        end,
    }
end
local a = mesh(false, {{"hide", false}, {"show", true}, {"intent", false}, {"excluded", true}})
local b = mesh(true, {{"show", false}, {"extra", true}})
local empty = mesh(true, {})
local parts = {[0]=a, [1]=b, [2]=empty, [4]=a, [5]=b}
local weapons = {a, b, empty}
local equipment = {
    parts=function() return parts end,
    weapons=function() return weapons end,
    mesh=function(object) return object end,
    weapon_id=function() return "wp00", weapons end,
}
local meshes = {
    first=function(object) return object end,
    part_meshes=function(_, index) return index == 0 and {a, b} or parts[index] and {parts[index]} or {} end,
}
local baseline = {["0"]={materials={intent=true, show=false}}, ["1"]={materials={extra=false}}}
local config = {groups={ordinary={mask={}}, global={is_global=true}}}
local function accepts(_, name) return name ~= "excluded" end
local wilds = require("ArmorVariantManager_Core.Games.Wilds.Capture").new(meshes, equipment)
local rise = require("ArmorVariantManager_Core.Games.Rise.Capture").new(equipment)
local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")

-- 对照两款游戏的旧捕获路径，覆盖普通/全局、意图值、多网格和空部件。
for _, game in ipairs({"wilds", "rise"}) do
    for _, weapon in ipairs({false, true}) do
        for _, group in ipairs({"", "ordinary", "global"}) do
            local env = setmetatable({
                current_group_name=group, current_config=config, is_weapon_mode=weapon, type_mesh=true,
                get_body_id=function() return "armor" end,
                get_primary_body_id=function() return "armor" end,
                get_local_player_character=function() return {} end,
                get_primary_player=function() return {} end,
                is_weapon_id=function() return weapon end,
                get_character_weapon_id=equipment.weapon_id,
                get_character_part=function(_, index) return parts[index] end,
                get_character_part_meshes=meshes.part_meshes,
                get_mesh_component_recursive=equipment.mesh,
                is_material_in_current_context=accepts,
                active_overrides={armor=baseline},
                SceneObject=SceneObject, Utils={get_current_weapon_parts=equipment.weapons},
            }, {__index=_G})
            local old = dofile("tests/fixtures/legacy/" .. game .. "_capture.lua")(env)("preset", "armor")
            local actual
            if game == "wilds" then actual = wilds({}, config, group, baseline, weapon, accepts)
            else actual = rise({}, {}, config, group, weapon, accepts) end
            S.equal(actual, old, game .. " " .. group .. " weapon=" .. tostring(weapon))
        end
    end
end

-- 装备适配器支持稀疏武器槽位，保存也必须覆盖第八槽位。
weapons = {[8]=a}
local sparse = rise({}, {}, config, "", true, accepts)
assert(sparse["7"] and sparse["7"].materials.hide == false and sparse["0"] == nil)
weapons = {mesh(true, {{"show", true}})}
S.equal(rise({}, {}, config, "global", true, accepts), {_empty=true})
assert(wilds({}, config, "global", nil, true, accepts)["0"].mesh_enabled == nil)

-- 崛起溶解期间的实际材质仍可见，保存必须读取 SceneObject 提供的意图值。
SceneObject.material_transition = {active={one=true}, get_material_enabled=function() return false end}
assert(rise({}, {}, config, "global", true, accepts)["0"].materials.show == false)
SceneObject.material_transition = nil
print("PASS: dual-game legacy preset capture, sparse weapon slots and dissolve intent")
