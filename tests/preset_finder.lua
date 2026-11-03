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
local function fixture(modern, game, scenario)
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
    local env = setmetatable({
        fs=storage.fs, safe_json_load=storage.load, json={load_file=storage.load},
        get_local_player_character=function() return character end,
        get_primary_player=function() return character end,
        get_character_part=meshes.part, get_mesh_component_recursive=equipment.mesh,
        get_character_weapon_id=equipment.weapon_id,
        is_weapon_id=function(id) return id:match("^wp%d%d") or id:match("^it%d%d%d%d") end,
        is_weapon_mode=scenario.weapon, SceneObject=SceneObject,
        Utils={get_current_weapon_parts=function() return weapons end},
        Profiler={begin=function() end,finish=function() end},
        PresetAutoFinder=dofile("tests/fixtures/legacy/rise_preset_search.lua"),
        save_current_config_to_file=function() end,
        update_preset_names_list=function() end, update_group_names_list=function() end,
        apply_all_defaults=function() end,
    }, {__index=_G})
    local data, message
    if modern then
        if game=="wilds" then
            data,message=require("ArmorVariantManager_Core.Games.Wilds.Finder").new(meshes,equipment,storage)(scenario.id,character)
        else
            data,message=require("ArmorVariantManager_Core.Games.Rise.Finder").new(equipment,storage)(scenario.id,character,player,scenario.weapon)
        end
        assert(env.current_config==nil, "Lookup must not install a configuration")
    else
        local ok
        ok,message=dofile("tests/fixtures/legacy/"..game.."_finder.lua")(env)(scenario.id)
        if ok then data=env.current_config end
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
for _, game in ipairs({"wilds","rise"}) do
    for index,scenario in ipairs(scenarios) do
        S.equal(fixture(true,game,scenario),fixture(false,game,scenario),game.." lookup "..index)
    end
end

-- 缺少首部件的武器是受支持输入；第八槽仍应参与查找，而非退化成同名匹配。
local sparse={id="weapon",weapon=true,sparse=true,files={{"ArmorVariantManager/other.json",preset(7,{"special"})}}}
assert(fixture(false,"rise",sparse).data==nil, "Old sparse-slot omission must reproduce")
assert(fixture(true,"rise",sparse).data.custom.keep==9)

-- 评分以材质命中为先；同分才考虑当前编号、覆盖率、非备份和路径顺序。
local rank={id="armor",files={{"ArmorVariantManager/armor.json",preset(1,{"A"})},{"ArmorVariantManager/better.json",preset(1,{"A","B"})}}}
assert(fixture(true,"rise",rank).message:find("已匹配: better",1,true))
rank.files[2][2]=preset(1,{"A"})
assert(fixture(true,"rise",rank).message:find("已匹配: armor",1,true))

-- 正式入口导入成功才刷新列表；主文件保存失败恢复当前配置及会话缓存。
local main=S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local wrapper=S.section(main,"local function find_auto_preset(","local draw_material_panel =")
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
    local ok,message=assert(load(wrapper.."\nreturn find_auto_preset", "entry-import","t",env))()("armor")
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
