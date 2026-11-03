-- 使用实际扫描器和场景保护器验证：局部销毁不重置 UI，真正换场景仍隔离旧对象。
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local file = assert(io.open("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua", "r"))
local source = file:read("a"); file:close()
local first = assert(source:find("local function flush_scene_reset(", 1, true))
local last = assert(source:find("\nlocal function get_all_characters()", first, true))
local now, invalidations, transform_reads = 10, 0, 0
local equipment_clears, mesh_clears = 0, 0
local loading, menu, scene_key = false, false, "scene-a"
local loading_method = { call = function() return loading end }
local quest_parts = { call = function() return menu end }
local gui = { get_field = function() return quest_parts end }
local gui_manager = { call = function() return menu and gui or nil end }
local sdk_mock = {
    is_managed_object = function(obj) return obj.valid ~= false end,
    find_type_definition = function(name)
        if name == "app.GameFlowManager" then return { get_method = function() return loading_method end } end
        if name == "app.GUIID.ID" then return { get_field = function() return { get_data = function() return 1 end } end } end
    end,
    get_managed_singleton = function(name) return name == "app.GUIManager" and gui_manager or {} end
}
local guard_env = setmetatable({ sdk = sdk_mock }, { __index = _G })
local guard_module = assert(loadfile("ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/RuntimeGuard.lua", "t", guard_env))()
local preserved = { keep = true }
local env = setmetatable({
    scanner = { state = "IDLE", force_rescan = true, last_scan_time = 0 },
    actor_runtime = require("ArmorVariantManager_Core.Runtime.State").new(),
    RuntimeGuard = guard_module, sdk = sdk_mock, os = { clock = function() return now end },
    global_config = { scanner_batch_size = 200, scan_interval = 0.5 },
    character_cache = preserved,
    equipment = { clear = function() equipment_clears = equipment_clears + 1 end, prune = function() end },
    meshes = { clear = function() mesh_clears = mesh_clears + 1 end },
    active_overrides = { keep = true }, active_group_presets = { keep = true }, current_config = { keep = true },
    preview_character_names = {}, clear_dead_object_marks = function() end,
    variant_manager_ui = { invalidate_context = function() invalidations = invalidations + 1 end },
    safe_get_game_object = function(obj, origin)
        if origin == "scanner_transform" then transform_reads = transform_reads + 1 end
        if obj.dead then return nil end
        return obj
    end,
    get_character_body_id = function() return "ch03_001_0000" end,
    type_cache = { app_character = { get_runtime_type = function() return {} end }, via_transform = {} },
    method_cache = {
        GameObject_get_Name = { call = function(_, obj)
            if obj.bad_name then error("destroyed name") end
            return obj.name or "Pl000_00"
        end },
        GameObject_getComponent = { call = function(_, obj)
            if obj.bad_component then error("destroyed component") end
            return obj
        end }
    }
}, { __index = _G })
local function object(fields)
    fields = fields or {}
    fields.call = function(self, name)
        if name == "get_Draw" then return true end
        if name == "get_Name" then
            if self.bad_cache then error("destroyed character") end
            return "Pl000_00"
        end
        error(name)
    end
    return fields
end
local scene = { call = function() return { get_elements = function() return {} end } end }
local tick = assert(load(source:sub(first, last - 1) .. "\nreturn tick_scanner", "actual-scanner", "t", env))()
env.runtime_guard.get_scene = function() return scene_key ~= "" and scene or nil, scene_key end
assert(env.runtime_guard:accept_scene(scene_key))
local function batch(items)
    env.scanner.state, env.scanner.transforms = "PROCESSING", items
    env.scanner.count, env.scanner.index = #items, 1
    env.scanner.scene_key, env.scanner.generation = scene_key, env.runtime_guard.generation
end
local good = object()
local runtime_config = {}
env.actor_runtime:get("old-scene-actor", "armor", "armor", runtime_config).overrides = {}
batch({ object({ dead = true }), object({ bad_name = true }), object({ bad_component = true }),
    object({ valid = false }), object({ bad_cache = true }), good })
assert(tick() and not env.runtime_guard.suspended)
assert(env.character_cache == preserved and env.character_cache[tostring(good)])
assert(invalidations == 0 and env.scanner.state == "IDLE", "Local faults must not reset UI or discard valid players")
local dead = {}; for i = 1, 200 do dead[i] = object({ dead = true }) end
local reads = transform_reads
batch(dead); assert(tick())
assert(transform_reads - reads == 8, "Bound native failure count per scan")
assert(env.scanner.state == "IDLE" and not env.scanner.force_rescan and invalidations == 0)
env.method_cache.Scene_findComponents = { call = function() error("enumeration failed") end }
assert(tick(), "Retry interval must avoid immediate rescans")
now = now + 1
assert(tick() and not env.runtime_guard.suspended and invalidations == 0, "Enumeration failure in same scene preserves UI")
local valid_character = object()
scene.call = function() return { get_elements = function() return { object({ bad_cache = true }), valid_character } end } end
env.method_cache.Scene_findComponents = nil
now = now + 1; assert(tick())
assert(env.character_cache[tostring(valid_character)], "Dead app.Character must not prevent later valid entries")
batch({ good }); local old_reads = transform_reads
scene_key = "scene-b"
assert(not tick() and env.runtime_guard.suspended)
assert(transform_reads == old_reads and invalidations == 0, "Changed scene never reads old snapshot; cleanup stays deferred")
assert(not env.runtime_guard:update())
assert(invalidations == 1 and env.character_cache ~= preserved)
assert(env.actor_runtime:peek("old-scene-actor", "armor", "armor", runtime_config) == nil, "Scene cleanup releases actor results")
assert(env.active_overrides.keep and env.active_group_presets.keep and env.current_config.keep, "Scene cleanup preserves JSON and preset selections")
assert(tick())
batch({ good }); old_reads = transform_reads; scene_key = ""
assert(not tick() and env.runtime_guard.suspended and env.scanner.force_rescan)
assert(not env.runtime_guard:update()); assert(not tick())
assert(transform_reads == old_reads and invalidations == 1, "Missing scene pauses safely without destroying UI state")
scene_key = "scene-b"
assert(not env.runtime_guard:update()); assert(tick())
loading = true; assert(env.runtime_guard:update())
assert(env.runtime_guard.scene_suspended, "Loading also pauses display skeletons")
assert(invalidations == 2, "Actual loading must still flush object caches")
loading = false; assert(not env.runtime_guard:update())
menu = true; assert(env.runtime_guard:update())
assert(not env.runtime_guard.scene_suspended, "Quest menu pauses material scanning, not display skeletons")
menu = false; assert(not env.runtime_guard:update())
assert(invalidations == 2, "Menu pause must not clear caches")
env.runtime_guard:begin_transition(true); assert(env.runtime_guard:update())
env.runtime_guard:mark_load_end(false); assert(env.runtime_guard:update(), "Fast travel waits for fade-in")
env.runtime_guard:mark_load_end(true); assert(not env.runtime_guard:update())
assert(invalidations == 3)
assert(equipment_clears == 3 and mesh_clears == 3, "Scene cleanup releases adapter-owned object caches")
local ui_start = assert(source:find("re.on_draw_ui(function()", 1, true))
local tree = assert(source:find('imgui.tree_node(T("mod_name"))', ui_start, true))
local pause = assert(source:find("if runtime_guard.suspended then", ui_start, true))
assert(tree < pause, "Legacy UI entry remains present while suspended")
print("PASS: isolated object/character failures, bounded burst, rescan interval, preserved UI/cache, scene changes, missing scene, loading, menus, fast-travel fade-in and legacy UI entry")
