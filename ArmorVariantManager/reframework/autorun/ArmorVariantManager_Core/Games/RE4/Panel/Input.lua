-- 独立面板的鼠标状态(给即时模式控件用)。照搬 ShapeKeySystem(d026d06,2026-11-04)的输入链路:
--   ShapeKeySystem_UI/Input.lua            点击队列、命中测试、钉住判定(raw_mouse)
--   ShapeKeySystem_UI/InputBlocker.lua     虚拟光标按设备位移移动(move_cursor)、设备左键
--   ShapeKeySystem_Games/RE4R/Input.lua    位移和滚轮在 UpdateMotionFrame 之前采样(capture_mouse)
-- 屏蔽游戏鼠标、切绝对模式仍由 AVM 的 InputGuard 做(它本来就是从 SKS 的 RE4R 适配移植的)。
--
-- 光标:游戏在野外会用 SetCursorPos 把系统光标拉回屏幕中心。根治在 InputGuard:屏蔽期间让
-- chainsaw.GuiManager.isMousePointerDispGui 回答 true,游戏像开着暂停菜单那样自己放开光标,这里直接用系统光标。
-- 虚拟光标只是后备(照 SKS):系统光标在中心 ±2 像素时认定被钉住,粘滞 30 帧,钉住时按设备位移移动。
-- 别再在这里设计"跟游戏抢光标"的规则:2026-11-05 试过始终用虚拟光标、按位移差判瞬移等,都会被吸或粘滞。
-- 位移必须在 UpdateMotionFrame 之前读:在 re.on_frame 里读到的基本是 0(2026-11-05 独立面板实测:
-- 在 on_frame 读位移时光标要么被拉回中心、要么粘滞;SKS 注释里滚轮也有同样的坑)。
--
-- AVM 自己加的两点(SKS 没有):
--   * 系统光标自由时,按下落在别的 ImGui 窗口上(REF 菜单、别的 mod 的窗口)不算面板的点击
--   * 钉住时 ImGui 自己点不中输入框:由控件主动给焦点 / 失焦(见 Widgets.text_box、TextInput)
--
-- 命中测试:I.hit 在当前裁剪矩形之外、以及上一次绘制登记的浮层(展开的下拉框)下面都是 false,
-- 除非正在画的就是那个浮层。

local D = require("ArmorVariantManager_Core.Games.RE4.Panel.Draw")

local I = {
    mx = -1, my = -1,          -- 这次绘制的鼠标位置(逻辑坐标)
    down = false, clicked = false, released = false,
    wheel = 0,                 -- 这次绘制的滚轮格数(+ = 向前)
    active = nil,              -- 正按住鼠标的控件 id(滑条拖动、窗口拖动)
    in_overlay = false,        -- 浮层正在画自己
    enabled = false,           -- 面板开着(虚拟光标和采样只在这时工作)
    pinned = false,            -- 系统光标被钉在屏幕中心,正在用虚拟光标
    frame_clicked = false,     -- 这次绘制有没有点击(给输入框失焦用,控件消费点击之后也还在)
}

local queue, q_head, q_tail = {}, 1, 0
local was_down = false
local swallowed = false        -- 这次按下落在别的 ImGui 窗口上,抬起前都不算
local sampled = false
local overlays, next_overlays = {}, {}
local wheel_acc = 0
local cursor = nil             -- 虚拟光标(屏幕像素)
local pinned_frames = 0

local function imgui_mouse()
    local ok, m = pcall(imgui.get_mouse)
    if ok and m and type(m.x) == "number" and m.x >= 0 and m.y >= 0 then return m.x, m.y end
    return nil
end

-- ---------------------------------------------------------------- 引擎鼠标设备
local mouse_type, point_type
local function device()
    mouse_type = mouse_type or sdk.find_type_definition("via.hid.Mouse")
    local m = sdk.get_native_singleton("via.hid.Mouse")
    if not m or not mouse_type then return nil end
    return sdk.call_native_func(m, mouse_type, "get_Device()")
end

local function point_xy(p)
    local x, y
    pcall(function()
        point_type = point_type or sdk.find_type_definition("via.Point")
        x = sdk.get_native_field(p, point_type, "x")
        y = sdk.get_native_field(p, point_type, "y")
    end)
    if type(x) ~= "number" then pcall(function() x, y = p.x, p.y end) end
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

-- 设备上的左键(ImGui 读不到按键时的后备;InputGuard 清零的是 share.hid.Device,不是这里)
local BTN_L
local function device_left_down()
    local down = false
    pcall(function()
        if not BTN_L then
            local td = sdk.find_type_definition("via.hid.MouseButton")
            local f = td and td:get_field("L")
            BTN_L = f and f:get_data(nil) or 1
        end
        local dev = device()
        local b = dev and dev:call("get_Button()")
        if type(b) == "number" then down = (b & BTN_L) ~= 0 end
    end)
    return down
end

local function raw_down()
    local ok, v = pcall(imgui.is_mouse_down, 0)
    if ok and v == true then return true end
    return I.enabled and device_left_down() or false
end

-- 用虚拟光标时按设备位移移动(SKS InputBlocker.move_cursor)
local function move_cursor(dx, dy)
    if not dx or (dx == 0 and dy == 0) then return end
    local sw, sh = D.surface_pixels()
    if not cursor then cursor = { x = sw / 2, y = sh / 2 } end
    if not I.pinned then return end
    cursor.x = math.max(0, math.min(sw - 1, cursor.x + dx))
    cursor.y = math.max(0, math.min(sh - 1, cursor.y + dy))
end

-- UpdateMotionFrame 之前:读这一帧设备的位移和滚轮(SKS RE4R/Input.lua 的 capture_mouse)
function I.sample()
    if not I.enabled then return end
    pcall(function()
        local dev = device()
        if not dev then return end
        local w = dev:call("get_WheelDelta()")
        if type(w) == "number" and w ~= 0 then wheel_acc = wheel_acc + w end
        local p = dev:call("get_DeltaPosition()")
        if p then move_cursor(point_xy(p)) end
    end)
end

local installed = false
function I.install()
    if installed or not re or not re.on_pre_application_entry then return end
    installed = true
    re.on_pre_application_entry("UpdateMotionFrame", I.sample)
end

-- 光标落在某个 ImGui 窗口上(ImGuiHoveredFlags_AnyWindow = 4)
local function over_imgui_window()
    if not imgui.is_window_hovered then return false end
    local ok, v = pcall(imgui.is_window_hovered, 4)
    return ok and v == true
end

-- 屏幕像素。面板开着时:系统光标被钉在中心就用虚拟光标,自由时把虚拟光标同步过去(SKS Input.raw_mouse)
function I.raw_mouse()
    local x, y = imgui_mouse()
    if I.enabled then
        local sw, sh = D.surface_pixels()
        if x and math.abs(x - sw / 2) <= 2 and math.abs(y - sh / 2) <= 2 then
            pinned_frames = 30
        elseif x and pinned_frames > 0 then
            pinned_frames = pinned_frames - 1
        end
        I.pinned = (x == nil) or pinned_frames > 0
        if not I.pinned and x then
            if cursor then cursor.x, cursor.y = x, y else cursor = { x = x, y = y } end
            return x, y
        end
        if cursor then return cursor.x, cursor.y end
        return sw / 2, sh / 2
    end
    if x then return x, y end
    return -1, -1
end

-- 每个游戏帧(re.on_frame)
function I.capture()
    local down = raw_down()
    if sampled and down and not was_down then
        local x, y = I.raw_mouse()
        swallowed = not I.pinned and over_imgui_window()
        if not swallowed and x >= 0 then q_tail = q_tail + 1; queue[q_tail] = { x, y } end
    end
    if sampled and not down and was_down then
        if not swallowed then q_tail = q_tail + 1; queue[q_tail] = false end   -- 抬起标记
        swallowed = false
    end
    sampled, was_down = true, down
end

-- 面板打开 / 关闭
function I.set_enabled(on)
    I.enabled = on == true
    cursor, I.pinned, pinned_frames = nil, false, 0
    local x, y = imgui_mouse()
    if I.enabled and x then cursor = { x = x, y = y } end   -- 从系统光标当前的位置开始
    wheel_acc = 0
end

function I.reset()
    queue, q_head, q_tail = {}, 1, 0
    sampled, was_down, swallowed = false, false, false
    I.active, I.clicked, I.released = nil, false, false
    overlays, next_overlays = {}, {}
    wheel_acc = 0
end

-- 每次绘制开始
function I.begin_frame()
    local x, y = I.raw_mouse()
    I.clicked, I.released = false, false
    local ev = queue[q_head]
    if ev ~= nil then
        queue[q_head] = nil
        q_head = q_head + 1
        if q_head > q_tail then q_head, q_tail = 1, 0 end
        if ev then I.clicked = true; x, y = ev[1], ev[2] else I.released = true end
    end
    I.frame_clicked = I.clicked
    I.mx, I.my = x / D.S, y / D.S
    I.down = (raw_down() and not swallowed) or I.clicked
    if I.released and not I.clicked then I.down = false end
    I.wheel = wheel_acc > 0 and 1 or (wheel_acc < 0 and -1 or 0)
    wheel_acc = 0
    overlays, next_overlays = next_overlays, {}
    if not I.down and not I.clicked then I.active = nil end
end

function I.add_overlay(x, y, w, h) next_overlays[#next_overlays + 1] = { x, y, w, h } end

function I.inside(x, y, w, h)
    local mx, my = I.mx, I.my
    return mx >= x and mx < x + w and my >= y and my < y + h
end

function I.over_overlay()
    for _, r in ipairs(overlays) do
        if I.inside(r[1], r[2], r[3], r[4]) then return true end
    end
    return false
end

-- I.locked:整页锁定(新版特性关闭时的调色页、溶解页),所有控件不响应;浮层(下拉列表)照常
function I.hit(x, y, w, h)
    if I.locked and not I.in_overlay then return false end
    if not I.inside(x, y, w, h) then return false end
    local c = D.get_clip()
    if c and (I.mx < c[1] or I.mx >= c[3] or I.my < c[2] or I.my >= c[4]) then return false end
    if not I.in_overlay and I.over_overlay() then return false end
    return true
end

-- 点击落在矩形里(且没被别的控件拿走)。会消费掉这次点击
function I.click(x, y, w, h)
    if I.clicked and I.hit(x, y, w, h) then
        I.clicked = false
        return true
    end
    return false
end

function I.consume() I.clicked = false end

-- ---------------------------------------------------------------- 键盘(快捷键)
local VK = {}
for i = 1, 12 do VK["F" .. i] = 0x6F + i end
local MOD = { Ctrl = 0x11, Shift = 0x10, Alt = 0x12 }

local function key_down(vk)
    local ok, down = pcall(function() return reframework:is_key_down(vk) end)
    return ok and down == true
end

local key_was = {}
-- 这一帧刚按下 name(mod 给了的话要同时按着那个修饰键)。每帧都要调用,才能认出"刚按下"
function I.key_pressed(name, mod)
    local vk = VK[name or "F8"] or VK.F8
    local down = key_down(vk)
    local was = key_was[vk]
    key_was[vk] = down
    if not down or was then return false end
    local m = mod and MOD[mod]
    return not m or key_down(m)
end

return I
