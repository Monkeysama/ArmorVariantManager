package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local main = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local legacy = dofile("tests/fixtures/legacy/wilds_frame.lua")
local path = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Wilds/Runtime.lua"

local function session(modern, scenario)
    local trace, reset_count = {}, 0
    local function record(...) trace[#trace + 1] = {...} end
    local primary, other, dead = {name="local"}, {name="remote"}, {name="dead", dead=true}
    local list = scenario.listed and {primary, other, dead} or {other, dead}
    local managed = function(object) return not object.dead end
    local scene_object = {game_object=function(value) return value end}
    local equipment, meshes, materials, capture = {}, {}, {}, function() end
    local guard = {
        update=function() record("guard"); return scenario.suspended == true end,
        install_hooks=function() record("hooks") end,
    }
    local actors = {
        guard=guard,
        tick=function() record("scan"); return not scenario.scan_failed end,
        all=function() record("all"); return list end,
        local_player=function() record("local"); return not scenario.no_primary and primary or nil end,
    }
    local reset_callback
    local modules = {
        SceneObject={new=function() return scene_object end},
        Equipment={new=function(get_object, config, names)
            assert(get_object == scene_object.game_object and config.setting == 1 and names.preview)
            return equipment
        end},
        Meshes={new=function(get_object, get_type)
            assert(get_object == scene_object.game_object and get_type("mesh") == "type:mesh")
            return meshes
        end},
        Materials={new=function(actual_meshes, get_object)
            assert(actual_meshes == meshes and get_object == scene_object.game_object)
            return materials
        end},
        Capture={new=function(actual_meshes, actual_equipment)
            assert(actual_meshes == meshes and actual_equipment == equipment)
            return capture
        end},
        Store={load=function() end},
        Finder={new=function(actual_meshes, actual_equipment, files)
            assert(actual_meshes == meshes and actual_equipment == equipment and type(files.load) == "function")
            return function() end
        end},
        Actors={preview_names={preview=true}, new=function(config, objects, gear, parts, reset)
            assert(config.setting == 1 and objects == scene_object and gear == equipment and parts == meshes)
            reset_callback=reset
            return actors
        end},
    }
    local config={groups={Remember={}}, presets={}}
    local env=setmetatable({
        sdk={is_managed_object=managed}, runtime_guard=guard,
        tick_scanner=actors.tick, get_all_characters=actors.all, get_local_player_character=actors.local_player,
        variant_manager_ui={
            set_suspended=function(_, value) record("suspended",value) end,
            update=function() record("ui") end,
        },
        actor_runtime={retain=function(_, seen)
            local names={}
            for _, value in pairs(seen) do names[#names+1]=value end
            table.sort(names); record("retain",names)
        end},
        process_character=function(character) record("process",character.name); return character.name end,
        get_body_id=function() record("body"); return scenario.id end,
        last_body_id="previous", current_group_name="Old", current_config={},
        pending_mode_group_restore=scenario.restore == true,
        mode_group_selection={armor="Remember"},
        active_group_presets={armor={chosen="Keep"}}, active_overrides={armor={keep=true}},
        temp_applied_presets={armor="Temporary"}, group_names_list={"Remember"},
        selected_group_index=1,
        load_config_data=function(id) record("load",id); if not scenario.missing_config then return config end end,
        update_group_names_list=function() record("groups") end,
        update_preset_names_list=function() record("presets") end,
    }, {__index=_G})
    env.load_body_config=function(id) record("body_config",id); env.current_config=config end
    if scenario.stable then env.last_body_id=scenario.id end
    local frame, runtime
    if modern then
        local module_env=setmetatable({
            require=function(name) return assert(modules[name:match("([^.]+)$")],name) end,
            sdk={is_managed_object=managed, find_type_definition=function(name) return "type:"..name end},
        }, {__index=_G})
        runtime=assert(loadfile(path,"t",module_env))().new({setting=1}, {reset=function() reset_count=reset_count+1 end})
        assert(runtime.actors == actors and runtime.guard == guard and runtime.materials == materials
            and runtime.capture == capture and runtime.scene_object == scene_object)
        runtime.install_hooks()
        reset_callback(); assert(reset_count == 1)
        local body=S.section(main,"local frame_callbacks =", "re.on_frame(function()")
        local callbacks=assert(load(body.."\nreturn frame_callbacks","actual-frame-wiring","t",env))()
        frame=function() runtime.tick(callbacks) end
    else
        guard:install_hooks()
        frame=legacy(env)
    end
    frame(); frame()
    local state={}
    for _, key in ipairs({"last_body_id","current_group_name","current_config","pending_mode_group_restore",
        "active_group_presets","active_overrides","temp_applied_presets","selected_group_index"}) do
        state[key]=env[key]
    end
    return trace,state
end

local scenarios={
    {suspended=true}, {scan_failed=true}, {}, {no_primary=true},
    {id="armor"}, {id="armor",listed=true}, {id="armor",stable=true},
    {id="armor",restore=true}, {id="armor",restore=true,missing_config=true},
    {id="new",restore=true}, {id="armor",suspended=true},
}
for i, scenario in ipairs(scenarios) do
    local old_trace,old_state=session(false,scenario)
    local new_trace,new_state=session(true,scenario)
    S.equal(new_trace,old_trace,"frame calls "..i)
    S.equal(new_state,old_state,"UI state "..i)
end
print("PASS: Wilds runtime service wiring, hooks/reset, frame order, suspension, local inclusion and equipment UI state")
