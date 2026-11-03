package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S=dofile("tests/support.lua")
local prefix="ArmorVariantManager_Core."
local Parts=require(prefix.."UI.ImGui.Parts")
local Weapons=require(prefix.."Games.Rise.Weapons")
local Signals=require(prefix.."Games.Rise.Signals")
Signals.get_current_weapon_type=function() return 2 end
local legacy={Wilds=dofile("tests/fixtures/legacy/wilds_parts_ui.lua"),Rise=dofile("tests/fixtures/legacy/rise_parts_ui.lua")}
local source=S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local function fixture(game, modern, options)
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
    if options.empty then armor,weapons={},{} end
    if options.sparse then weapons={[8]=part("Weapon8",7)} end
    if options.invalid then weapons[1].dead=true end
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
    local env=setmetatable({get_player_handle=function() end, runtime=runtime,T=function(key) return key end,character={},primary={},body_id="armor",
        is_weapon_mode=options.weapon,active_overrides={armor=baseline},
        get_character_weapon_id=runtime.equipment.weapon_id,get_cached_weapon_parts=runtime.equipment.weapons,
        get_character_part=runtime.meshes.part,get_cached_character_part=runtime.meshes.part,
        get_character_part_meshes=runtime.meshes.part_meshes,get_mesh_component_recursive=runtime.meshes.first,
        safe_get_game_object=runtime.scene_object.game_object,is_player_face_object=runtime.meshes.is_face,
        safe_object_alive=alive,SceneObject={call=function(obj,method) return obj:call(method) end},
        Utils={get_current_weapon_type=Signals.get_current_weapon_type,get_weapon_part_name=Weapons.part_name},
        sdk={is_managed_object=alive}}, {__index=_G})
    env.imgui={tree_node=function(title) trace[#trace+1]={"tree",title};return not options.closed end,
        tree_pop=function() trace[#trace+1]={"pop"} end,
        text_colored=function(value,color) trace[#trace+1]={"text",value,color} end}
    env.draw_mesh_toggle=function(obj,label,id,index) trace[#trace+1]={"mesh",obj.name,label,id,index} end
    local draw
    if modern then
        runtime.part_view=require(prefix.."Games."..game..".PartView").new(runtime)
        if game=="Wilds" then
            draw=assert(load(S.section(source,"local draw_part_list =","-- =============================================================================\n-- 新UI")
                .."\nreturn function() "..S.section(source,"                    draw_part_list(character,","\n                    imgui.separator()").." end",
                "parts-entry","t",env))()
        else
            local panel=Parts.new(runtime.part_view,env.T,env.draw_mesh_toggle)
            draw=function() panel(env.primary,"armor",options.weapon,baseline) end
        end
    else draw=legacy[game](env) end
    return {trace=trace,env=env,runtime=runtime,draw=function() _G.sdk,_G.imgui=env.sdk,env.imgui;draw() end}
end
for _,game in ipairs({"Wilds","Rise"}) do
    for _,weapon in ipairs({false,true}) do
        for _,case in ipairs({"normal","no_mesh","empty","closed","invalid"}) do
            local opts={[case]=true,weapon=weapon}
            local old,new=fixture(game,false,opts),fixture(game,true,opts)
            old.draw();new.draw();S.equal(new.trace,old.trace,game.." "..case.." "..tostring(weapon))
        end
    end
end
-- 修复先前抽取后遗漏的脸部判定：缺网格的正常部件会进入该真实可达分支。
local broken=fixture("Wilds",false,{no_mesh=true});broken.env.is_player_face_object=nil
local ok,err=pcall(broken.draw);assert(not ok and tostring(err):find("is_player_face_object",1,true))
for _,case in ipairs({"face","no_target"}) do
    local old,new=fixture("Wilds",false,{[case]=true}),fixture("Wilds",true,{[case]=true})
    old.draw();new.draw();S.equal(new.trace,old.trace,"Wilds "..case)
end
-- 原崛起 ipairs 会遗漏首槽缺失的第八部件；新列表保留真实槽位编号。
local sparse=fixture("Rise",true,{weapon=true,sparse=true});sparse.draw()
assert(sparse.trace[9][1]=="mesh" and sparse.trace[9][5]==7)
assert(sparse.trace[9][2]=="Mesh_Weapon8")
local old_sparse=fixture("Rise",false,{weapon=true,sparse=true});old_sparse.draw()
for _,row in ipairs(old_sparse.trace) do assert(row[1]~="mesh") end
local rebuilding=fixture("Rise",true,{weapon=true,no_target=true});rebuilding.draw()
assert(rebuilding.trace[2][1]=="text" and rebuilding.trace[3][1]=="mesh")
local collapsed=fixture("Wilds",true,{closed=true,weapon=true});collapsed.runtime.equipment.weapon_id=function() error("closed panel queried engine") end
collapsed.draw()
print("PASS: both game part lists match legacy; face fallback, sparse weapons and rebuilding meshes remain usable")
