-- RE4 InputGuard:面板显示时清零鼠标字段、接管光标;关闭后等鼠标键松开才放行;别的面板在用时不还原光标。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

-- ---------- 引擎替身 ----------
local physical = { button = 0, up = 0 }
local mouse_state = { AbsoluteMode = false, ClipCursorToScreen = true }
local hooks, frames, resets = {}, {}, {}
local storage = {}

local FIELDS = {
    MouseButtonTrigger = { "via.hid.MouseButton", 4, 0x198 }, MouseButtonDown = { "via.hid.MouseButton", 4, 0x19C },
    MouseButtonRelease = { "via.hid.MouseButton", 4, 0x1A0 }, MouseButtonRepeat = { "via.hid.MouseButton", 4, 0x1A4 },
    Wheel = { "System.Single", 4, 0x190 }, WheelDelta = { "System.Single", 4, 0x194 },
    MovePosition = { "via.Point", 8, 0x180 }, RawMovePosition = { "via.Point", 8, 0x188 },
}
local device_type
device_type = {
    get_size = function() return 464 end,
    get_field = function(_, name)
        local key = name:match("^<(.+)>k__BackingField$")
        local f = key and FIELDS[key]
        if not f then return nil end
        return { is_static = function() return false end, get_offset_from_base = function() return f[3] end,
            get_type = function() return { get_full_name = function() return f[1] end, get_valuetype_size = function() return f[2] end } end }
    end,
    get_method = function(_, sig) return sig == "update()" and "Device.update" or nil end,
}
local mouse_type = {}
local device_bytes = {}
local device = {
    get_type_definition = function() return { is_a = function(_, t) return t == device_type end } end,
    write_byte = function(_, offset, value) device_bytes[offset] = value end,
}
_G.sdk = {
    find_type_definition = function(name)
        if name == "via.hid.Mouse" then return mouse_type end
        if name == "share.hid.Device" then return device_type end
    end,
    get_native_singleton = function() return {} end,
    call_native_func = function(_, _, name, value)
        if name == "get_Device()" then
            return { call = function(_, m) return m == "get_Button()" and physical.button or physical.up end }
        end
        local getter = name:match("^get_(%w+)%(%)$")
        if getter then return mouse_state[getter] end
        local setter = name:match("^set_(%w+)%(")
        if setter then mouse_state[setter] = value end
    end,
    hook = function(method, pre, post) hooks[method] = { pre = pre, post = post } end,
    to_managed_object = function(p) return p end,
}
_G.thread = { get_hook_storage = function() return storage end }
_G.re = { on_frame = function(f) frames[#frames + 1] = f end, on_script_reset = function(f) resets[#resets + 1] = f end }

local InputGuard = require("ArmorVariantManager_Core.Games.RE4.InputGuard")
local visible = false
assert(InputGuard.install(function() return visible end), "device hook installed")

local function frame() for _, f in ipairs(frames) do f() end end
local function device_update()
    for k in pairs(device_bytes) do device_bytes[k] = nil end
    local h = hooks["Device.update"]
    h.pre({ nil, device })
    h.post("ret")
end
local function cleared() return device_bytes[0x19C] == 0 and device_bytes[0x198] == 0 and device_bytes[0x187] == 0 end

-- 面板关:不碰设备、不碰光标
frame(); device_update()
assert(next(device_bytes) == nil and mouse_state.AbsoluteMode == false and mouse_state.ClipCursorToScreen == true)

-- 面板开:清零鼠标字段,切到绝对模式、不裁剪,并登记
visible = true; frame(); device_update()
assert(cleared(), "mouse fields zeroed while the panel is visible")
assert(mouse_state.AbsoluteMode == true and mouse_state.ClipCursorToScreen == false, "cursor released")
assert(_G.__AVM_UI_INPUT_BLOCKER_STATES.ArmorVariantManager == true and _G.__AVM_REFD2D_INPUT_BLOCKED == true)

-- 关闭时左键还按着:继续屏蔽,光标不还原
physical.button = 1
visible = false; frame(); device_update()
assert(cleared(), "still blocking until the button is released")
assert(mouse_state.AbsoluteMode == true, "cursor kept until release")

-- 松开后放行并还原光标
physical.button = 0; frame(); device_update()
assert(next(device_bytes) == nil, "released: device untouched")
assert(mouse_state.AbsoluteMode == false and mouse_state.ClipCursorToScreen == true, "cursor restored")
assert(_G.__AVM_UI_INPUT_BLOCKER_STATES.ArmorVariantManager == false)

-- 别的面板(SKS)还在屏蔽时,AVM 关闭不还原光标
visible = true; frame()
_G.__AVM_UI_INPUT_BLOCKER_STATES.ShapeKeySystem = true
visible = false; frame()
assert(mouse_state.AbsoluteMode == true, "another panel still blocking: cursor left alone")
_G.__AVM_UI_INPUT_BLOCKER_STATES.ShapeKeySystem = false; frame()
assert(mouse_state.AbsoluteMode == false, "restored once the other panel is done")

-- 两边同一帧都登记了屏蔽、谁都还没接管(SKS 的规则是"有别的面板屏蔽就不接管"):
-- 以前 AVM 也让路,结果谁都不切绝对模式,引擎一直把光标拉回中间。现在没人接管时 AVM 接管
assert(mouse_state.AbsoluteMode == false)
_G.__AVM_UI_INPUT_BLOCKER_STATES.ShapeKeySystem = true
visible = true; frame()
assert(mouse_state.AbsoluteMode == true and mouse_state.ClipCursorToScreen == false, "nobody had taken over: AVM takes over despite another blocker")
_G.__AVM_UI_INPUT_BLOCKER_STATES.ShapeKeySystem = false
visible = false; frame()
assert(mouse_state.AbsoluteMode == false and mouse_state.ClipCursorToScreen == true, "AVM restores what it recorded")

-- 别的面板先接管了(光标已是绝对模式):AVM 只帮着保持,不记原值、不还原,留给接管的那个面板
mouse_state.AbsoluteMode, mouse_state.ClipCursorToScreen = true, false   -- SKS 已经切过
_G.__AVM_UI_INPUT_BLOCKER_STATES.ShapeKeySystem = true
visible = true; frame()
mouse_state.AbsoluteMode = false; frame()     -- 引擎改回相对模式:AVM 也会拉回来
assert(mouse_state.AbsoluteMode == true, "joined: still holds absolute mode")
visible = false; frame()
assert(mouse_state.AbsoluteMode == true, "joined: AVM does not restore, the other panel does")
_G.__AVM_UI_INPUT_BLOCKER_STATES.ShapeKeySystem = false; frame()
assert(mouse_state.AbsoluteMode == true, "joined: even after the other panel is done, AVM leaves the restore to it")
mouse_state.AbsoluteMode, mouse_state.ClipCursorToScreen = false, true   -- SKS 自己还原

-- 重载脚本时还原
visible = true; frame()
for _, f in ipairs(resets) do f() end
assert(mouse_state.AbsoluteMode == false and _G.__AVM_UI_INPUT_BLOCKER_STATES.ArmorVariantManager == false)

-- 字段布局对不上:不装设备挂钩,也不报错
FIELDS.Wheel[2] = 8
hooks, frames = {}, {}
package.loaded["ArmorVariantManager_Core.Games.RE4.InputGuard"] = nil
local warned
assert(not require("ArmorVariantManager_Core.Games.RE4.InputGuard").install(function() return true end, function(m) warned = m end))
assert(hooks["Device.update"] == nil and warned and warned:find("layout mismatch"), "layout mismatch refuses to hook")

print("PASS: RE4 InputGuard zeroes mouse fields while visible, waits for release, restores the cursor, respects other panels and refuses a mismatched layout")
