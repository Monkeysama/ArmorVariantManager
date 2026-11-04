package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local original_call = SceneObject.call
SceneObject.call = function(object, ...) return object:call(...) end
sdk = {is_managed_object=function(object) return not object.dead end}
local Search = require("ArmorVariantManager_Core.Games.Rise.PresetSearch")
assert(require("ArmorVariantManager_Core.PresetAutoFinder") == Search)

local function mesh(names)
    return {call=function(_, method, index)
        if method == "get_MaterialNum" then return #names end
        if method == "getMaterialName" then return names[index + 1] end
        error(method)
    end}
end
local function preset(part, names)
    local materials = {}
    for _, name in ipairs(names) do materials[name] = false end
    return {presets={one={[tostring(part)]={materials=materials}}}, custom={keep=9}}
end
local function fixture(game, scenario)
    local disk, files, io_trace = {}, {}, {}
    for _, candidate in ipairs(scenario.files or {}) do
        files[#files + 1] = candidate[1]
        disk[candidate[1]] = S.copy(candidate[2])
        local relative = candidate[1]:gsub("\\", "/"):gsub("^reframework/data/", "")
        disk[relative] = disk[candidate[1]]
    end
    local calls = 0
    local storage = {
        fs=scenario.no_fs and nil or {glob=function(pattern)
            io_trace[#io_trace + 1] = {"glob",pattern}
            calls = calls + 1
            return (calls == 1 or scenario.duplicates) and files or {}
        end},
        load=function(path)
            io_trace[#io_trace + 1] = {"load",path}
            return disk[path]
        end,
    }
    if scenario.no_fs then storage.fs = nil end
    local body = not scenario.no_part and mesh(scenario.materials or {"A", "B"}) or nil
    local head = mesh({"head"})
    local character = not scenario.no_character and {dead=scenario.dead} or nil
    local player = {}
    local weapons = scenario.sparse and {[8]=mesh({"special"})} or {mesh({"A"}),mesh({"B"})}
    if scenario.no_weapon then weapons = nil end
    local equipment = {
        parts=function(actual) assert(actual==character); return {[0]=head, [1]=body} end,
        mesh=function(object) if not scenario.no_mesh then return object end end,
        weapon_id=function() return scenario.wrong_weapon and "wp99" or scenario.id, weapons end,
        weapons=function(actual, handle) assert(actual==character and handle==player); return weapons end,
    }
    local meshes = {first=equipment.mesh,part=function(_, index) return ({[0]=head,[1]=body})[index] end}
    local data,message
    if game=="wilds" then
        data,message=require("ArmorVariantManager_Core.Games.Wilds.Finder").new(meshes,equipment,storage)(scenario.id,character)
    else
        data,message=require("ArmorVariantManager_Core.Games.Rise.Finder").new(equipment,storage)(scenario.id,character,player,scenario.weapon)
    end
    return {data=data,message=message,trace=io_trace}
end

-- 查找结果、诊断、路径回退及扫描顺序保持原游戏行为。
local scenarios = {
    {id="armor",files={{"ArmorVariantManager/source.json",preset(1,{"A"})}}},
    {id="armor",duplicates=true,files={{"reframework/data/ArmorVariantManager/source.json",preset(1,{"A","B"})}}},
    {id="armor",files={{"reframework\\data\\ArmorVariantManager\\source.json",preset(1,{"A"})}}},
    {id="armor",files={{"ArmorVariantManager/source.json",preset(1,{"missing"})}}},
    {id="armor",files={{"ArmorVariantManager/armor.json",preset(1,{"A"})}}},
    {id="armor",materials={},files={{"ArmorVariantManager/armor.json",preset(1,{"A"})}}},
    {id="armor",files={{"ArmorVariantManager/source.json",{groups={global={is_global=true,mask={["0"]={head=true}},presets={}}}}}}},
    {id="armor",files={{"ArmorVariantManager/backup/source.json",preset(1,{"A"})},{"ArmorVariantManager/other.json",preset(1,{"A","B"})}}},
    {id="armor",no_fs=true}, {id="armor"}, {id="armor",no_part=true},
    {id="armor",no_mesh=true}, {id="armor",no_character=true}, {},
    {id="wp00_current",weapon=true,files={{"ArmorVariantManager/wp01.json",preset(0,{"A"})}}},
    {id="wp00_current",weapon=true,files={{"ArmorVariantManager/armor.json",preset(0,{"A"})}}},
    {id="wp00_current",weapon=true,files={{"ArmorVariantManager/wp01.json",preset(1,{"A"})}}},
    {id="wp00_current",weapon=true,no_weapon=true},
    {id="wp00_current",weapon=true,wrong_weapon=true},
}
local winners={
    wilds={1,1,1,false,false,false,false,1,false,false,false,false,false,false,1,false,false,false,false},
    rise={1,1,1,false,1,1,1,2,false,false,false,false,false,false,1,1,1,false,false},
}
local reads={
    wilds={6,6,7,6,5,0,6,6,0,5,0,0,0,0,6,6,6,0,0},
    rise={9,9,9,8,9,9,9,10,0,7,7,7,0,0,9,9,9,7,7},
}
local failures={
    wilds={[4]="No matching preset found",[5]="No matching preset found",[6]="No materials on Body",
        [7]="No matching preset found",[9]="fs.glob missing",[10]="No preset files found",
        [11]="Body part not found",[12]="Mesh not found",[13]="No Character",[14]="No Body ID",
        [16]="No matching preset found",[17]="No matching preset found",[18]="Weapon not found",[19]="Weapon not found"},
    rise={[4]="没有匹配的预设",[9]="未读取到任何预设文件",[10]="未读取到任何预设文件",
        [11]="未读取到任何预设文件",[12]="未读取到任何预设文件",[13]="No Character",[14]="No Body ID",
        [18]="未找到武器部件",[19]="未读取到任何预设文件"},
}
for _,game in ipairs({"wilds","rise"}) do
    for index,scenario in ipairs(scenarios) do
        local actual=fixture(game,scenario)
        local winner=winners[game][index]
        S.equal(actual.data,winner and scenario.files[winner][2] or nil,game.." lookup "..index)
        assert(#actual.trace==reads[game][index],game.." lookup I/O "..index)
        if winner then
            local matched=scenario.files[winner][1]
            assert(actual.message:find(game=="wilds" and matched or (matched:match("([^/\\]+)%.json$")),1,true))
        else assert(actual.message:find(failures[game][index],1,true)) end
    end
end

-- 缺少首部件的武器是受支持输入；第八槽仍应参与查找，而非退化成同名匹配。
local sparse={id="weapon",weapon=true,sparse=true,files={{"ArmorVariantManager/other.json",preset(7,{"special"})}}}
assert(fixture("rise",sparse).data.custom.keep==9)

-- 评分以材质命中为先；同分才考虑当前编号、覆盖率、非备份和路径顺序。
local rank={id="armor",files={{"ArmorVariantManager/armor.json",preset(1,{"A"})},{"ArmorVariantManager/better.json",preset(1,{"A","B"})}}}
assert(fixture("rise",rank).message:find("已匹配: better",1,true))
rank.files[2][2]=preset(1,{"A"})
assert(fixture("rise",rank).message:find("已匹配: armor",1,true))

-- 正式入口导入成功才刷新列表；主文件保存失败恢复当前配置及会话缓存。
local Fixture=dofile("tests/app_fixture.lua")
for _,failure in ipairs({"none","find","save"}) do
    local previous,cache,candidate={old=true},{old_cache=true},{presets={},unknown=true}
    local events={}
    local env=setmetatable({current_config=previous,loaded_configs={armor=cache},
        get_local_player_character=function() return "actor" end,
        get_player_handle=function() end,
        runtime={find_preset=function(id,actor)
            assert(id=="armor" and actor=="actor")
            return failure~="find" and candidate or nil,"lookup message"
        end},
        update_preset_names_list=function() events[#events+1]="refresh" end,
    },{__index=_G})
    env.save_current_config_to_file=function(id)
        assert(env.current_config==candidate)
        env.loaded_configs[id]=candidate
        events[#events+1]="save"
        return failure~="save"
    end
    local app=Fixture.new("Wilds", {session={cache=env.loaded_configs}})
    app.runtime.find_preset=env.runtime.find_preset
    app.runtime.actors.local_player=env.get_local_player_character
    app.workspace.config=previous
    app.workspace.update_preset_names_list=env.update_preset_names_list
    app.backend.save=function(id, data)
        env.current_config=data
        return env.save_current_config_to_file(id)
    end
    local ok,message=app.find_auto_preset("armor")
    env.current_config=app.workspace.config
    assert(ok==(failure=="none"))
    if ok then
        assert(env.current_config==candidate and env.loaded_configs.armor==candidate)
        S.equal(events,{"save","refresh"})
    else
        assert(env.current_config==previous and env.loaded_configs.armor==cache)
        S.equal(events,failure=="save" and {"save"} or {})
        assert(message==(failure=="save" and "Failed to save matched preset" or "lookup message"))
    end
end
SceneObject.call=original_call
print("PASS: dual-game preset lookup, ranking, sparse weapons and import rollback")
