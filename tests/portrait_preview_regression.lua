package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local Preview = require("ArmorVariantManager_Core.Games.Wilds.PortraitPreview")
local function same(a, b, message) assert(a == b, (message or "mismatch") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local now, in_game, visible, live, identity, hdr = 0, false, true, true, "first", 0
local camera = { fov = 17, x = 0, y = 0.06, z = 1 }
local camera2 = { fov = 20, x = 0.1, y = 0.2, z = 1.2 }
local reads, active, updates, offset_fault, restore_fault, offset_attempts = 0, false, 0, false, false, 0
local native_state, source_result, native_available = 1, 0, true
local native = {
    portrait_version = function() return 3 end, portrait_ready = function() return 1 end,
    portrait_state = function() return native_state end, portrait_error = function() return "native fault" end,
    portrait_output = function(value) assert(in_game); return value == 0 and 0 or -1 end,
    portrait_alpha = function() assert(in_game); return 0 end,
    portrait_update = function(_, enabled, x, y, w, h)
        assert(in_game, "Native mutations must run on game callback")
        active, updates = enabled == 1 and source_result == 0, updates + 1
        if active then same(x, 30); same(y, 50); same(w, 220); same(h, 240) end
        return enabled == 1 and source_result or 0
    end
}
local function game_only() assert(in_game, "SDK access from render callback"); reads = reads + 1 end
local adapter = {
    current = function() game_only(); return live and {} or nil end,
    identity = function() game_only(); return identity end,
    holder = function() game_only(); return 123456 end,
    output = function() game_only(); return hdr, 1 end,
    argument = function() game_only(); return identity == "first" and camera or camera2 end,
    read = function(a) game_only(); return { fov = a.fov, x = a.x, y = a.y, z = a.z } end,
    fov = function(a, value)
        game_only()
        if restore_fault and value == 17 then error("restore fov fault") end
        a.fov = value
    end,
    offset = function(a, value)
        game_only(); offset_attempts = offset_attempts + 1
        if offset_fault then offset_fault = false; error("offset fault") end
        a.x, a.y, a.z = value.x, value.y, value.z
    end
}
local p = Preview.new({ register = false, adapter = adapter, clock = function() return now end,
    bridge = function() return native_available and native or nil end, should_show = function() return visible end })
local function step(refresh)
    now = now + 0.11
    if refresh ~= false then p.set_rectangle({ x = 30, y = 50, w = 220, h = 240 }) end
    in_game = true; p.tick(); in_game = false
end
step(); same(reads, 0, "Default off must not inspect game objects")
same(updates, 0, "Idle controller must not stop another producer")
active = true
for _ = 1, 10 do step() end
same(active, true, "Idle ticks must preserve external preview requests")
same(updates, 0)
active = false
p.set_enabled(true); same(reads, 0, "Enabling in draw only records intent")
step(); same(camera.fov, 40); same(camera.y, 0.06 - 0.75); same(camera.z, 2.8); same(p.status, "preview_live")
-- 网页只请求切换宿主；停绘、还原与重建仍在游戏回调执行。
local host_calls = {}
native.portrait_reff_ready = function() return 1 end
native.portrait_reff = function(value) assert(in_game); host_calls[#host_calls + 1] = value; return 0 end
local before_switch = updates
p.set_host("reff"); same(updates, before_switch); same(#host_calls, 0)
step(); same(host_calls[1], 1); same(p.host, "reff"); same(camera.fov, 40)
p.set_host("legacy"); same(#host_calls, 1)
step(); same(host_calls[2], 0); same(p.host, "legacy"); same(camera.fov, 40)
native.portrait_reff_ready, native.portrait_reff = nil, nil
-- 面板拖动必须立即更新绘制矩形，不等待100ms的游戏对象检查，也不能触碰SDK。
local moved = 0
native.portrait_rectangle = function(x,y,w,h)
    assert(not in_game); same(x,42); same(y,61); same(w,220); same(h,240)
    moved = moved + 1; return 0
end
p.set_rectangle({x=42,y=61,w=220,h=240}); same(moved,1,"Drag rectangle must reach native in the draw callback")
native.portrait_rectangle = nil
for _ = 1, 1000 do step() end
same(camera.y, 0.06 - 0.75, "No cumulative camera displacement")
visible = false; step(); same(camera.fov, 17); same(camera.y, 0.06); same(active, false)
local stopped_updates = updates
step(); same(updates, stopped_updates, "Owned preview stops once while hidden")
visible = true; step(); same(camera.fov, 40)
live = false; step(); same(camera.fov, 17); same(p.status, "preview_waiting")
live = true; step(); same(camera.fov, 40)
identity = "second"; step(); same(camera.fov, 17); same(camera2.fov, 20)
step(); same(camera2.fov, 40); same(camera2.y, 0.2 - 0.75)
hdr = 1; step(); same(camera2.fov, 20); same(active, false); same(p.status, "preview_output_unsupported")
hdr = 0; identity = "first"; step(); same(camera.fov, 40)
for _ = 1, 6 do step(false) end
same(camera.fov, 17, "Stale drawing must restore camera")
step(); same(camera.fov, 40)
local old_reads = reads
p.set_enabled(false); same(reads, old_reads, "Closing in draw cannot touch SDK")
step(); same(camera.fov, 17); same(camera.z, 1); same(active, false)
-- 渲染线程故障要在下一游戏帧停绘并还原，不能自动反复操作原生对象。
p.set_enabled(true); step(); same(camera.fov, 40)
native_state = -1; step()
same(camera.fov, 17); same(camera.y, 0.06); same(active, false); same(p.status, "preview_error")
old_reads = reads; step(); same(reads, old_reads, "Native fault must latch without repeated SDK access")
native_state = 1; p.set_enabled(true); step(); same(camera.fov, 40)
source_result = -1; step()
same(camera.fov, 17); same(active, false); same(p.status, "preview_error")
source_result = 0; p.set_enabled(true); step(); same(camera.fov, 40)
native_available = false; step()
same(camera.fov, 17); same(p.status, "preview_native_missing")
native_available = true; step(); same(camera.fov, 40)
p.set_enabled(false); step(); same(camera.fov, 17)

offset_fault = true; p.set_enabled(true); step()
same(camera.fov, 17, "Partial write failure restores FOV"); same(camera.y, 0.06); same(p.status, "preview_error")
old_reads = reads; step(); same(reads, old_reads, "Error latch must not repeat native discovery")
p.set_enabled(true); step(); same(camera.fov, 40)
restore_fault = true; local attempts = offset_attempts
p.set_enabled(false); step(); same(p.status, "preview_restore_error")
assert(offset_attempts > attempts, "Offset must be attempted even when FOV restoration fails")
same(camera.y, 0.06)
p.set_enabled(true); step(); same(p.enabled, false, "Pending restore must prevent a replacement snapshot")
restore_fault = false; step(); same(camera.fov, 17)
p.set_enabled(true); step(); same(camera.fov, 40)
in_game = true; p.shutdown(); in_game = false
same(camera.fov, 17); same(camera.y, 0.06); same(active, false)
old_reads = reads; step(); same(reads, old_reads, "Shutdown callbacks must remain inert")

for _, width in ipairs({ 1100, 1280, 1366, 1920, 2560 }) do
    local panel, card = Preview.widths(width, true)
    same(panel, math.min(1160, width - 70 - card), "Do not reserve the removed preview gap")
    assert(panel + card + 70 <= width, "Reserved card must fit beside original content")
    assert(panel >= 800 and card >= 198, "Keep main editor and preview usable")
end
local panel, card = Preview.widths(1000, true)
same(card, 0); same(panel, 930)
same(select(2, Preview.widths(1920, false)), 0)
-- 正式独立相机使用游戏 UpdateBehavior；旧菜单适配器仍保留 on_frame 入口。
local frame_callbacks, update_callbacks, reset_callbacks, late_callbacks = {}, {}, {}, {}
re = {
    on_frame = function(callback) frame_callbacks[#frame_callbacks + 1] = callback end,
    on_application_entry = function(name, callback)
        if name == "LateUpdateBehavior" then late_callbacks[#late_callbacks + 1] = callback
        else same(name, "UpdateBehavior"); update_callbacks[#update_callbacks + 1] = callback end
    end,
    on_script_reset = function(callback) reset_callbacks[#reset_callbacks + 1] = callback end,
}
local dedicated = Preview.new({ adapter = { independent = true } })
same(#frame_callbacks, 0); same(update_callbacks[1], dedicated.tick); same(reset_callbacks[1], dedicated.shutdown)
same(late_callbacks[1], dedicated.frame)
local menu = Preview.new({ adapter = {} })
same(frame_callbacks[1], menu.tick); same(#update_callbacks, 1); same(reset_callbacks[2], menu.shutdown)
-- 新预览插件独立于 UI 桥；仅安装旧插件时仍可使用原有入口。
local dedicated_reads, legacy_reads = 0, 0
avm_portrait = { portrait_version = function() dedicated_reads = dedicated_reads + 1; return 4 end,
    portrait_ready = function() return 0 end }
avm_bridge = { portrait_version = function() legacy_reads = legacy_reads + 1; return 4 end,
    portrait_ready = function() return 0 end }
local function probe_bridge()
    local value = Preview.new({ adapter = {}, register = false })
    value.set_enabled(true); value.set_rectangle({x=1,y=1,w=100,h=100}); value.tick()
    same(value.status, "preview_native_missing")
end
probe_bridge(); same(dedicated_reads, 1); same(legacy_reads, 0)
avm_portrait = nil
probe_bridge(); same(legacy_reads, 1)
avm_bridge = nil
print("PASS: game-thread SDK access, 1000-frame stability, visibility/context/stale/reset restore, native/source/bridge faults, HDR rejection, partial writes, restoration retry, independent bridge and reserved layout")
