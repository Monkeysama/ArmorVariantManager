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

-- 明确捕获结果，独立覆盖多网格、草稿意图、空部件和全局组策略。
local normal_a={mesh_enabled=false,materials={hide=false,show=true,intent=false}}
local normal_b={mesh_enabled=true,materials={show=false,extra=true}}
local wilds_union={mesh_enabled=false,materials={hide=false,show=false,intent=true,extra=true}}
for _,game in ipairs({"wilds","rise"}) do
    for _,weapon in ipairs({false,true}) do
        for _,group in ipairs({"","ordinary","global"}) do
            local expected={["0"]=S.copy(normal_a),["1"]=S.copy(normal_b),["2"]={mesh_enabled=true,materials={}}}
            if not weapon then
                expected["4"]=S.copy(normal_a)
                if game=="wilds" then expected["0"]=S.copy(wilds_union); expected["5"]=S.copy(normal_b) end
            elseif game=="wilds" then expected["0"].materials.intent=true end
            if group=="global" then
                expected["2"]=nil
                for _,part in pairs(expected) do
                    if game=="wilds" then part.mesh_enabled=nil
                    else
                        for name,visible in pairs(part.materials) do
                            if visible then part.materials[name]=nil end
                        end
                    end
                end
            elseif game=="wilds" and group=="ordinary" then expected["2"]=nil end
            local actual
            if game=="wilds" then actual=wilds({},config,group,baseline,weapon,accepts)
            else actual=rise({},{},config,group,weapon,accepts) end
            S.equal(actual,expected,game.." "..group.." weapon="..tostring(weapon))
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
print("PASS: dual-game preset capture, sparse weapon slots and dissolve intent")
