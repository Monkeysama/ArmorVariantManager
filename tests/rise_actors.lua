package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local now = 10
local master, players, transforms, event_manager = nil, {}, {}, nil
local scan_starts, component_reads = 0, 0
local SceneObject = {}
function SceneObject.is_alive(obj) return obj ~= nil and not obj.dead end
function SceneObject.call(obj, method, ...)
    if not SceneObject.is_alive(obj) then return nil end
    return obj:call(method, ...)
end
local function array(values) return {get_elements=function() return values end} end
local list = {call=function(_, method, i)
    if method == "get_Count" then return #players end
    if method == "get_Item" then return players[i+1] end
    error(method)
end}
local manager = {call=function(_, method)
    if method == "findMasterPlayer()" or method == "getMasterPlayer" then return master end
    error(method)
end, get_field=function(_, field) assert(field == "PlayerList"); return list end}
local scene = {call=function(_, method)
    assert(method == "findComponents(System.Type)")
    scan_starts = scan_starts + 1
    return array(transforms)
end}
local get_go = {call=function(_, component)
    component_reads = component_reads + 1
    return component.go
end}
local get_item = {call=function(_, _, i) return players[i+1] end}
local sdk = {
    typeof=function(name) return name end,
    get_native_singleton=function() return {} end,
    call_native_func=function() return scene end,
    get_managed_singleton=function(name)
        if name == "snow.player.PlayerManager" then return manager end
        if name == "snow.eventcut.EventManager" then return event_manager end
        error(name)
    end,
    find_type_definition=function(name)
        if name == "via.Component" then return {get_method=function() return get_go end} end
        if name == "via.SceneManager" then return {} end
        if name == "snow.player.PlayerManager" then return {get_field=function()
            return {get_type=function() return {get_method=function() return get_item end} end}
        end} end
        error(name)
    end,
}
local config = {scene_scan_batch=4}
local env = setmetatable({sdk=sdk, os={clock=function() return now end},
    require=function(name)
        assert(name == "ArmorVariantManager_Core.Games.Rise.SceneObject")
        return SceneObject
    end,
}, {__index=_G})
local Actors = assert(loadfile("ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Rise/Actors.lua", "t", env))()
local actors = Actors.new(config)
local legacy_env = setmetatable({sdk=sdk, os=env.os, SceneObject=SceneObject,
    global_config=config, type_cache={via_transform="via.Transform"},
    method_cache={Component_get_GameObject=get_go}, playerListGetItem=get_item,
    get_player_manager=function() return manager end,
    Profiler={begin=function() end,finish=function() end,count=function() end,max_value=function() end},
}, {__index=_G})
local old = dofile("tests/fixtures/legacy/rise_actors.lua")(legacy_env)
local function go(name, has_body)
    local obj = {name=name}
    local body = {call=function(_, method) assert(method == "get_Name"); return "custom_body" end}
    local child = {call=function(_, method)
        if method == "get_GameObject" then return body end
        if method == "get_Next" then return nil end
        error(method)
    end}
    local tf = {call=function(_, method) assert(method == "get_Child"); return has_body and child or nil end}
    function obj:call(method)
        if method == "get_Name" then return self.name end
        if method == "get_Transform" then return tf end
        error(method)
    end
    return obj
end
local function player(obj, index)
    return {go=obj,index=index,call=function(self, method)
        if method == "get_GameObject" then return self.go end
        if method == "getPlayerIndex" then return self.index end
        error(method)
    end}
end
local function compare()
    local actual, expected = actors.get(), old.get()
    assert(#actual.entries == #expected.entries and #actual.others == #expected.others)
    assert(actual.local_index == expected.local_index)
    for i, entry in ipairs(actual.entries) do
        local prior = expected.entries[i]
        for _, key in ipairs({"player","obj","index","is_local","name","from_scan","from_master"}) do
            assert(entry[key] == prior[key], "entry " .. i .. " " .. key)
        end
    end
    assert(actors.local_player() == old.local_player())
    return actual
end
local function reset() actors.reset(); old.reset() end
local function tick()
    actors.tick()
    if not old.state.local_entry or not SceneObject.is_alive(old.state.local_entry.obj) then old.state.scan_tick() end
end

-- 本地主角可排在列表末尾；名字与加入顺序不改变身份。
local local_go, remote = go("player03", true), go("player00", true)
master = player(local_go, 3)
players = {player(remote, 0), master}
local dir = compare()
assert(dir.local_entry.obj == local_go and dir.others[1].obj == remote)
local scans_before = scan_starts
tick()
assert(scan_starts == scans_before, "master present: do not scan scene")

-- 不同包装对象以索引识别；主角不在 PlayerList 时仍可从管理器取得。
master = player(local_go, 3)
reset(); compare()
players = {player(remote, 0)}
reset(); dir = compare()
assert(dir.local_entry.from_master and dir.entries[1].obj == local_go)

-- 列表标准调用失败时使用缓存方法，不把队友当主角。
list.call = function(_, method)
    if method == "get_Count" then return #players end
    error("standard list item unavailable")
end
players = {player(remote, 0), master}
reset(); compare()
list.call = function(_, method, i)
    if method == "get_Count" then return #players end
    if method == "get_Item" then return players[i+1] end
    error(method)
end
master, players = nil, {player(remote, 0), player(local_go, 3)}
reset(); dir = compare()
assert(dir.local_entry == nil and #dir.others == 2)

-- 已确认主角短暂失联保留一秒，销毁则立即停止使用。
master, players = player(local_go, 3), {}
reset(); compare()
master = nil
now = now + .6
compare()
assert(actors.local_player() == local_go)
now = now + .5
compare()
assert(actors.local_player() == nil)
master = player(local_go, 3)
reset(); compare()
local_go.dead = true
master = nil
compare()
assert(actors.local_player() == nil)
local_go.dead = nil

-- 菜单角色仅在目录无候选时通过增量扫描回退。
local preview = go("FemalePreview", true)
transforms = {}
for i=1,7 do transforms[i] = {go=go("prop" .. i)} end
transforms[8] = {go=preview}
reset(); dir = compare()
assert(dir.local_entry == nil)
local reads_before = component_reads
tick()
assert(component_reads - reads_before == 8, "each directory handles only four objects per batch")
tick(); dir = compare()
assert(dir.local_entry.from_scan and actors.local_player() == preview)
local previous_scans = scan_starts
tick(); compare()
assert(scan_starts == previous_scans)

-- 场景切换后失效的数组下标也要丢弃，不能永远停在同一批。
transforms = setmetatable({}, {__len=function() return 1 end,
    __index=function() error("stale Transform array") end})
reset(); compare(); tick()
assert(actors.get().scan.transforms == nil and old.state.scan.transforms == nil)
local attempts = scan_starts
tick()
assert(scan_starts == attempts)
transforms = {{go=preview}}
now = now + .11
tick(); tick(); compare()
assert(actors.local_player() == preview)

-- 单元素 REF 栈不能漏首项；两种事件列表路径都保留。
local event_a, event_b = go("event_a"), go("event_b")
local function event_list(items, to_array)
    return {call=function(_, method, index)
        if method == "get_Count" then if to_array then error("no count") end; return #items end
        if method == "get_Item" then return items[index+1] end
        if method == "ToArray" then return array(items) end
        error(method)
    end}
end
local function handler(items)
    local unique = {call=function(_, method) assert(method == "get_EventPlayerList"); return items end}
    return {call=function(_, method) assert(method == "findUniqueEventManager"); return unique end}
end
local handlers = {handler(event_list({player(event_a, 0)}, false))}
event_manager = {call=function(_, method) assert(method == "get_LoadHandlerStack"); return array(handlers) end}
local function compare_events()
    local actual, expected = actors.events(), old.events()
    assert(#actual == #expected)
    for i, value in ipairs(actual) do assert(value == expected[i]) end
    return actual
end
assert(compare_events()[1] == event_a)
handlers[2] = handler(event_list({player(event_b, 1)}, true))
assert(compare_events()[2] == event_b)
event_manager = nil
assert(#compare_events() == 0)
reset()
assert(old.state.last_local_obj == nil)
print("PASS: Rise actor directory, fallback scanner and event actors match legacy behavior")
