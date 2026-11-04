local Actors = require("ArmorVariantManager_Core.Games.Rise.Actors")
local Equipment = require("ArmorVariantManager_Core.Games.Rise.Equipment")
local Materials = require("ArmorVariantManager_Core.Games.Rise.Materials")
local Rules = require("ArmorVariantManager_Core.Games.Rise.Rules")
local Signals = require("ArmorVariantManager_Core.Games.Rise.Signals")
local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Dissolve = require("ArmorVariantManager_Core.Games.Rise.DissolveTransition")
local Scheduler = require("ArmorVariantManager_Core.Runtime.Scheduler")
local Runtime = {}

-- 生命周期由运行会话统一管理；callbacks 只处理应用状态，不接管引擎缓存。
-- process(entry, is_event, runtime)、reset(reason)、forget_actor(object)。
function Runtime.new(config, callbacks)
    local runtime = { actors = Actors.new(config), equipment = Equipment.new() }
    runtime.materials = Materials.new(runtime.equipment, Rules.capture_mesh)
    runtime.capture = require("ArmorVariantManager_Core.Games.Rise.Capture").new(runtime.equipment)
    runtime.part_view = require("ArmorVariantManager_Core.Games.Rise.PartView").new(runtime)
    runtime.find_preset = require("ArmorVariantManager_Core.Games.Rise.Finder").new(
        runtime.equipment, {fs = fs, load = require("ArmorVariantManager_Core.Config.Store").load})
    runtime.transition = Dissolve.new({valid = SceneObject.is_alive})
    SceneObject.material_transition = runtime.transition
    runtime.scheduler, runtime.cg_scheduler = Scheduler.new(), Scheduler.new()
    local frame, pending_reset = 0, false
    local events, has_events, last_has_events = {}, false, nil
    local processed = {}

    -- 切场景只弃引用；过场切换和脚本退出仍可结束有效材质的动画。
    local function clear(reason)
        if reason == "scene" then runtime.transition:abandon()
        else runtime.transition:finish_all() end
        runtime.actors.reset()
        runtime.equipment.clear()
        runtime.materials.clear()
        Signals.clear()
        Rules.clear_cache(nil, nil, true)
        runtime.scheduler, runtime.cg_scheduler = Scheduler.new(), Scheduler.new()
        processed = {}
        callbacks.reset(reason)
    end

    -- 任务状态钩子只置标志，所有清理延后至 Lua 帧入口。
    function runtime.request_reset() pending_reset = true end

    -- 与旧入口相同的任务状态事件；钩子中不访问或释放场景对象。
    function runtime.install_hooks()
        local definition = sdk.find_type_definition("snow.QuestManager")
        local method = definition and definition:get_method("onChangedGameStatus")
        if method then
            sdk.hook(method, runtime.request_reset, function(value) return value end)
        end
        -- 过场保持装备可见；目标不可用时沿用旧入口的可选失败边界。
        if not pcall(function()
            local loader = sdk.find_type_definition("snow.eventcut.EventPlayerLoader")
            local equip = loader:get_method("<reqStandby>g__set_equip_index|88_0(snow.player.PlayerRequestEquipsData.EquipPack, System.Int32, System.Boolean, snow.eventcut.EventPlayerLoader.<>c__DisplayClass88_0)")
            sdk.hook(equip, function(args) args[4] = sdk.to_ptr(false) end,
                function(value) return value end)
        end) then
            log.debug("[ArmorVariantManager] Failed to hook EventPlayerLoader")
        end
        re.on_script_reset(runtime.stop)
    end

    function runtime.stop()
        clear(pending_reset and "scene" or "script")
        events, has_events, last_has_events = {}, false, nil
        pending_reset = false
        if SceneObject.material_transition == runtime.transition then
            SceneObject.material_transition = nil
        end
    end

    local function process(entry, is_event)
        if not SceneObject.is_alive(entry.obj) then return false end
        if entry.player and not SceneObject.is_alive(entry.player) then return false end
        Signals.bind_actor(entry.player, entry.obj)
        processed[entry.obj] = true
        callbacks.process(entry, is_event, runtime)
        return true
    end

    -- 编辑后的即时应用复用正常角色入口，不推进调度器，也不越过切场景暂停。
    function runtime.refresh(object)
        if pending_reset then return false end
        object = object or runtime.actors.local_player()
        if not object then return false end
        if has_events then
            for _, actor in ipairs(events) do
                if actor == object then return process({obj = actor, is_event = true}, true) end
            end
            return false
        end
        for _, entry in ipairs(runtime.actors.get().entries) do
            if entry.obj == object then return process(entry, false) end
        end
        if object == runtime.actors.local_player() then
            return process({obj = object, is_local = true}, false)
        end
        return false
    end

    -- 保留完整在场名单，不能把本帧未获多人预算的角色当作离场。
    local function prune(entries)
        local seen = {}
        for _, entry in ipairs(entries) do seen[entry.obj] = true end
        for object in pairs(processed) do
            if not seen[object] then
                runtime.equipment.clear(object)
                runtime.materials.clear(object)
                Rules.forget_actor(tostring(object))
                Signals.forget_actor(object)
                callbacks.forget_actor(object)
                processed[object] = nil
            end
        end
    end

    -- 本地角色每帧处理；队友与过场演员各用独立的轮询通道。
    function runtime.is_suspended() return pending_reset end

    function runtime.tick(ui)
        if pending_reset then
            if ui and ui.suspended then ui.suspended(true) end
            pending_reset = false
            clear("scene")
            events, has_events, last_has_events = {}, false, nil
            -- 当前拍不再采样或写材质，下一拍重新发现场景角色。
            return
        end
        frame = frame + 1
        Signals.begin_frame(frame)
        runtime.equipment.begin_frame(frame)
        runtime.transition:tick()
        runtime.actors.tick()
        if ui and ui.suspended then ui.suspended(false) end
        if ui then ui.update() end

        if frame % 5 == 0 then
            local next_events = runtime.actors.events()
            local next_has_events = #next_events > 0
            if next_has_events ~= last_has_events then
                clear("event")
                last_has_events = next_has_events
                Signals.begin_frame(frame)
                runtime.equipment.begin_frame(frame)
            end
            events, has_events = next_events, next_has_events
        end
        local now = os.clock()
        runtime.scheduler:begin_frame(now)
        runtime.cg_scheduler:begin_frame(now)

        local roster
        if has_events then
            roster = {}
            for _, object in ipairs(events) do
                roster[#roster + 1] = {obj = object, is_local = false, is_event = true}
            end
            runtime.cg_scheduler:run(roster, function(entry) process(entry, true) end, 0, 1)
        else
            local directory = runtime.actors.get()
            local entry = directory.local_entry
            roster = directory.entries
            if not entry then
                local object = runtime.actors.local_player()
                if object then
                    entry = {obj = object, is_local = true}
                    roster = {table.unpack(roster)}
                    roster[#roster + 1] = entry
                end
            end
            local started = os.clock()
            if entry then process(entry, false) end
            local cost = os.clock() - started
            if config.enable_multiplayer ~= false then
                runtime.scheduler:run(directory.others, function(other) process(other, false) end,
                    cost, tonumber(config.multiplayer_players_per_tick) or 1)
            end
        end
        if frame % 120 == 0 then prune(roster) end
    end

    return runtime
end

return Runtime
