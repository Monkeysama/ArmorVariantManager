package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S=dofile("tests/support.lua")
local prefix="ArmorVariantManager_Core."
local Parts=require(prefix.."UI.ImGui.Parts")
local Signals=require(prefix.."Games.Rise.Signals")
Signals.get_current_weapon_type=function() return 2 end
local function fixture(game, options)
    local trace={}
    local td={get_method=function() return nil end}
    local function object(name)
        local obj={name=name,get_type_definition=function() return td end}
        function obj:call(method)
            if method=="get_Name" then return self.name end
            if method=="get_GameObject" then return self.target end
            error(method)
        end
        return obj
    end
    local armor,weapons={},{}
    local function part(name, index)
        local obj=object(name)
        obj.mesh=object("Mesh");obj.mesh.target=object("Mesh_"..name)
        if options.no_mesh and index==0 then obj.mesh=nil end
        if options.no_target and index==0 then obj.mesh.target=nil end
        if options.face and index==0 then obj.name="Player_Face";obj.mesh=nil end
        return obj
    end
    for index=0,5 do armor[index]=part("Armor"..index,index) end
    for index=1,2 do weapons[index]=part("Weapon"..index,index-1) end
    if options.sparse then weapons={[8]=part("Weapon8",7)} end
    local function alive(obj) return obj and not obj.dead end
    local runtime={equipment={},meshes={},scene_object={game_object=function(mesh) return mesh.target end}}
    runtime.equipment.weapon_id=function() return "weapon",weapons end
    runtime.equipment.weapons=function() return weapons end
    runtime.equipment.parts=function() return armor end
    runtime.equipment.mesh=function(obj) return obj.mesh end
    runtime.meshes.part=function(_,index) return armor[index] end
    runtime.meshes.part_meshes=function(_,index,baseline)
        assert(baseline and baseline.index==index)
        return {armor[index] and armor[index].mesh}
    end
    runtime.meshes.first=function(obj) return obj.mesh end
    -- 测试与真正网格服务一致的 Player_Face 排除条件。
    runtime.meshes.is_face=require(prefix.."Games.Wilds.Meshes").new(function() end,function() end).is_face
    local baseline={};for i=0,5 do baseline[tostring(i)]={index=i} end
    local actor={}
    local ui={tree_node=function(title) trace[#trace+1]={"tree",title};return not options.closed end,
        tree_pop=function() trace[#trace+1]={"pop"} end,
        text_colored=function(value,color) trace[#trace+1]={"text",value,color} end}
    runtime.part_view=require(prefix.."Games."..game..".PartView").new(runtime)
    local panel=Parts.new(runtime.part_view,function(key) return key end,
        function(obj,label,id,index) trace[#trace+1]={"mesh",obj.name,label,id,index} end)
    return {trace=trace,runtime=runtime,draw=function()
        _G.sdk,_G.imgui={is_managed_object=alive},ui
        panel(actor,"armor",options.weapon,baseline)
    end}
end
for _, game in ipairs({"Wilds","Rise"}) do
    local armor=fixture(game,{}); armor.draw()
    local indices={}
    for _, row in ipairs(armor.trace) do if row[1]=="mesh" then indices[#indices+1]=row[5] end end
    S.equal(indices,game=="Wilds" and {0,1,2,3,4,5} or {2,1,0,4,3},game.." armor order")
    local missing=fixture(game,{no_mesh=true}); missing.draw()
    local draws=0
    for _, row in ipairs(missing.trace) do if row[1]=="mesh" then draws=draws+1 end end
    assert(draws==(game=="Wilds" and 5 or 4))
    local collapsed=fixture(game,{closed=true,weapon=true})
    collapsed.runtime.equipment.weapon_id=function() error("closed panel queried engine") end
    collapsed.runtime.equipment.weapons=collapsed.runtime.equipment.weapon_id
    collapsed.draw(); assert(#collapsed.trace==1)
end
local face=fixture("Wilds",{face=true}); face.draw()
assert(face.trace[2][1]=="text" and face.trace[2][2]=="helm not_equipped")
-- 崛起首槽缺失不能截断后面的合法武器部件，行号保持真实槽位。
local sparse=fixture("Rise",{weapon=true,sparse=true}); sparse.draw()
assert(sparse.trace[9][1]=="mesh" and sparse.trace[9][5]==7 and sparse.trace[9][2]=="Mesh_Weapon8")
local rebuilding=fixture("Rise",{weapon=true,no_target=true}); rebuilding.draw()
assert(rebuilding.trace[2][1]=="text" and rebuilding.trace[3][1]=="mesh")
print("PASS: native armor order, face/missing-mesh fallback, sparse weapons and closed-panel engine isolation")
