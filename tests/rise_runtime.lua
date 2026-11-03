package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Scheduler = require("ArmorVariantManager_Core.Runtime.Scheduler")
local LegacyScheduler = dofile("tests/fixtures/legacy/rise_scheduler.lua")
assert(require("ArmorVariantManager_Core.RuntimeScheduler") == Scheduler)
local original_clock = os.clock
local now = 0
os.clock = function() return now end

-- 同一时钟/名单/前台负载对照旧调度器，覆盖预算债务、暂停与名单变化。
local function schedule(module, fps)
    now = 0
    local scheduler, trace = module.new(), {}
    for frame = 1, 600 do
        now = now + 1 / fps
        scheduler:begin_frame(now)
        local entries = {{obj="a"}, {obj="b"}, {obj="c"}}
        if frame > 200 then entries[2] = {obj="d"} end
        if frame > 400 then entries = {} end
        scheduler:run(entries, function(entry)
            trace[#trace + 1] = {frame, entry.obj}
            now = now + (frame % 7 == 0 and .002 or .0001)
        end, frame > 50 and frame < 150 and .004 or 0,
            frame > 300 and frame < 320 and 0 or 3)
    end
    return {trace=trace, calls=scheduler.calls, deferred=scheduler.deferred,
        debt=scheduler.debt, max_wait=scheduler.max_wait, records=scheduler.records}
end
for _, fps in ipairs({30, 60, 144}) do
    S.equal(schedule(Scheduler, fps), schedule(LegacyScheduler, fps), "scheduler " .. fps)
end

local prefix = "ArmorVariantManager_Core.Games.Rise."
local log, directory, event_objects, fallback, reset_hook, pre_hook, post_hook
local function record(name, object) log[#log + 1] = {name, object} end
local SceneObject = {is_alive = function(object) return object and not object.dead end}
package.loaded[prefix .. "SceneObject"] = SceneObject
package.loaded[prefix .. "Actors"] = {new = function()
    return {
        get = function() record("directory"); return directory end,
        local_player = function() return fallback end,
        events = function() record("events"); return event_objects end,
        tick = function() record("scan") end,
        reset = function() record("actors.clear") end,
    }
end}
package.loaded[prefix .. "Equipment"] = {new = function()
    return {
        begin_frame = function(epoch) record("equipment.frame", epoch) end,
        clear = function(object) record("equipment.clear", object) end,
    }
end}
package.loaded[prefix .. "Materials"] = {new = function(equipment, capture)
    assert(type(equipment.begin_frame) == "function" and type(capture) == "function")
    return {clear = function(object) record("materials.clear", object) end}
end}
package.loaded[prefix .. "Rules"] = {
    capture_mesh = function() end,
    clear_cache = function(a, b, keep) assert(a == nil and b == nil and keep); record("rules.clear") end,
    forget_actor = function(object) record("rules.forget", object) end,
}
package.loaded[prefix .. "DissolveTransition"] = {new = function(deps)
    assert(deps.valid == SceneObject.is_alive)
    return {
        tick = function() record("dissolve.tick") end,
        abandon = function() record("dissolve.abandon") end,
        finish_all = function() record("dissolve.finish") end,
    }
end}
sdk = {
    find_type_definition = function(name)
        assert(name == "snow.QuestManager")
        return {get_method = function(_, method) assert(method == "onChangedGameStatus"); return "flow" end}
    end,
    hook = function(method, before, after) assert(method == "flow"); pre_hook, post_hook = before, after end,
}
re = {on_script_reset = function(callback) reset_hook = callback end}
local Signals = require(prefix .. "Signals")
local Runtime = require(prefix .. "Runtime")
local local_obj, remote_a, remote_b, remote_c = {}, {}, {}, {}
local local_player, player_a = {}, {}
local calls, forgotten, resets, foreground_cost
local function count(object, first)
    local value = 0
    for i = first or 1, #calls do if calls[i].obj == object then value = value + 1 end end
    return value
end
local function make(config)
    now, log, calls, forgotten, resets, foreground_cost = 0, {}, {}, {}, {}, 0
    directory = {local_entry={obj=local_obj, player=local_player, is_local=true},
        others={{obj=remote_a, player=player_a}, {obj=remote_b}, {obj=remote_c}}}
    directory.entries = {directory.local_entry, table.unpack(directory.others)}
    event_objects, fallback = {}, nil
    return Runtime.new(config or {}, {
        process = function(entry, event, runtime)
            calls[#calls + 1] = {obj=entry.obj, event=event, at=now}
            assert(runtime.equipment and runtime.materials and runtime.actors)
            if entry.is_local then now = now + foreground_cost end
        end,
        reset = function(reason) resets[#resets + 1] = reason; record("app.reset", reason) end,
        forget_actor = function(object) forgotten[object] = true; record("app.forget", object) end,
    })
end
local function advance(runtime, frames)
    for _ = 1, frames do now = now + 1/60; runtime.tick() end
end

local runtime = make()
foreground_cost = .004
advance(runtime, 180)
assert(count(local_obj) == 180, "local player delayed by optional budget")
for _, object in ipairs({remote_a, remote_b, remote_c}) do
    assert(count(object) > 8, "optional player starved")
    assert(not forgotten[object], "unprocessed this frame is not departed")
end
assert(count(remote_a) + count(remote_b) + count(remote_c) <= 180)
assert(runtime.scheduler.deferred > 0, "foreground cost must defer optional work")

-- 关闭多人只停可选通道，零预算也不改变本地响应。
runtime = make({enable_multiplayer=false})
advance(runtime, 20)
assert(count(local_obj) == 20 and #calls == 20)
runtime = make({multiplayer_players_per_tick=0})
advance(runtime, 20)
assert(count(local_obj) == 20 and #calls == 20)

-- 每五帧切换过场；独立轮询不继承上一批演员的预算，回调明确禁止规则评估。
runtime = make()
advance(runtime, 4)
local cg_a, cg_b = {}, {}
event_objects = {cg_a, cg_b}
local start = #calls + 1
advance(runtime, 1)
assert(calls[start].obj == cg_a and calls[start].event)
advance(runtime, 19)
for i = start, #calls do assert(calls[i].event and calls[i].obj ~= local_obj) end
assert(count(cg_b) > 0)
event_objects = {}
advance(runtime, 1)
assert(calls[#calls - 1].obj == local_obj or calls[#calls].obj == local_obj)
assert(resets[#resets] == "event")

-- 场景钩子只置脏；下一拍先放弃动画，不触碰旧网格，也不执行更新回调。
runtime = make()
runtime.install_hooks()
advance(runtime, 6)
local call_count = #calls
log = {}
pre_hook({})
assert(#log == 0 and post_hook(123) == 123)
advance(runtime, 1)
assert(#calls == call_count and log[1][1] == "dissolve.abandon")
for _, item in ipairs(log) do
    assert(item[1] ~= "dissolve.tick" and item[1] ~= "dissolve.finish" and item[1] ~= "directory")
end
assert(resets[#resets] == "scene")
advance(runtime, 1)
assert(#calls > call_count, "new scene must resume")
log = {}
reset_hook()
assert(log[1][1] == "dissolve.finish" and SceneObject.material_transition == nil)
runtime = make()
runtime.install_hooks()
pre_hook({})
log = {}
reset_hook()
assert(log[1][1] == "dissolve.abandon", "reset during scene change must not finish old materials")

-- 离场按完整名册清理；有效本地宽限对象仍保留，死亡玩家不得传给业务层。
runtime = make()
advance(runtime, 10)
directory.others = {directory.others[2], directory.others[3]}
directory.entries = {directory.local_entry, table.unpack(directory.others)}
advance(runtime, 110)
assert(forgotten[remote_a] and not forgotten[remote_b] and not forgotten[local_obj])
runtime = make()
fallback = local_obj
directory.local_entry = nil
directory.entries = directory.others
advance(runtime, 120)
assert(count(local_obj) == 120 and not forgotten[local_obj])
runtime = make()
local_player.dead, player_a.dead, remote_b.dead = true, true, true
advance(runtime, 12)
assert(count(local_obj) == 0 and count(remote_a) == 0 and count(remote_b) == 0)
local_player.dead, player_a.dead, remote_b.dead = nil, nil, nil

-- 清理信号别名后不能复用旧玩家的条件采样。
Signals.clear()
Signals.begin_frame(1)
Signals.bind_actor(local_player, local_obj)
local samples = 0
local condition = {get_state = function() samples = samples + 1; return samples end}
assert(Signals.sample_condition("test", condition, local_obj) == 1)
assert(Signals.sample_condition("test", condition, local_obj, local_player) == 1)
Signals.forget_actor(local_obj)
assert(Signals.sample_condition("test", condition, local_obj) == 2)
Signals.clear()
assert(Signals.sample_condition("test", condition, local_obj) == 3)
-- UI 先接收暂停状态；正常帧必须扫描后更新 UI，切场景帧不执行更新。
runtime = make()
local ui_trace = {}
local ui = {
    suspended = function(value) ui_trace[#ui_trace + 1] = value and "paused" or "ready" end,
    update = function()
        assert(log[#log][1] == "scan")
        assert(#calls == 0)
        ui_trace[#ui_trace + 1] = "update"
    end,
}
assert(not runtime.is_suspended())
runtime.tick(ui)
S.equal(ui_trace, {"ready", "update"}, "normal UI frame")
assert(#calls > 0)
local previous_calls = #calls
runtime.request_reset()
assert(runtime.is_suspended())
runtime.tick(ui)
S.equal(ui_trace, {"ready", "update", "paused"}, "scene UI frame")
assert(#calls == previous_calls)
os.clock = original_clock
print("PASS: Rise scheduling, local priority, event actors, deferred scene cleanup and actor retirement")
