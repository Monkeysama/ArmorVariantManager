-- REFF 面板显示时,不让游戏读到鼠标(按键、滚轮、位移),并接管光标模式。键盘不拦(用户决定)。
--
-- 为什么 AVM 自己做:REFF 在窗口消息层拦输入,RE4 上有几处漏(见 docs/REFF_RE4_INPUT_ISSUE.md):
-- 从别的窗口用左键点回游戏时,按下落在 REFF 的失焦暂停里被放行、抬起被吞,游戏一直按着左键;
-- 切回游戏后光标有概率被引擎的"回中"吸在屏幕中间。这里不依赖窗口消息,在游戏输入层截断。
--
-- 做法照 SKS(ShapeKeySystem_Games/RE4R/Input.lua),只取鼠标部分:
-- 1. share.hid.Device.update() 之后,把设备上的鼠标字段写零。字段先按名字、类型、大小、偏移
--    校验(2026-11-05 用 reframework MCP 核对过 RE4 的布局),对不上就整体不启用,不乱写内存。
-- 2. 面板显示期间把引擎鼠标切到绝对模式、不裁剪光标(引擎不再把光标拉回中心)。
-- 3. 面板关闭后不立刻放行:等所有鼠标键都松开再停止清零、还原光标。否则"点关闭那一下"或
--    关闭时还按着的键会漏给游戏,又变成一直按住。
-- 4. 在 _G.__AVM_UI_INPUT_BLOCKER_STATES 登记(重构前 AVM 定的约定,SKS 也在用):别的面板
--    还在屏蔽时不还原光标,免得两个面板互相把光标模式改来改去。
local InputGuard = {}

local ID = "ArmorVariantManager"

local function registry()
    local t = rawget(_G, "__AVM_UI_INPUT_BLOCKER_STATES")
    if type(t) ~= "table" then t = {}; rawset(_G, "__AVM_UI_INPUT_BLOCKER_STATES", t) end
    return t
end
local function publish(on)
    registry()[ID] = on == true
    local any = false
    for _, v in pairs(registry()) do if v == true then any = true; break end end
    rawset(_G, "__AVM_REFD2D_INPUT_BLOCKED", any)
end
local function other_panel()
    for id, on in pairs(registry()) do
        if id ~= ID and on == true then return true end
    end
    return false
end

-- 设备上要清零的鼠标字段:名字、类型、大小
local MOUSE_FIELDS = {
    { "MouseButtonTrigger", "via.hid.MouseButton", 4 },
    { "MouseButtonDown", "via.hid.MouseButton", 4 },
    { "MouseButtonRelease", "via.hid.MouseButton", 4 },
    { "MouseButtonRepeat", "via.hid.MouseButton", 4 },
    { "Wheel", "System.Single", 4 }, { "WheelDelta", "System.Single", 4 },
    { "MovePosition", "via.Point", 8 }, { "RawMovePosition", "via.Point", 8 },
}

local function layout_of(device_type)
    local layouts, object_size = {}, device_type:get_size()
    for _, item in ipairs(MOUSE_FIELDS) do
        local field = device_type:get_field("<" .. item[1] .. ">k__BackingField")
        if not field or field:is_static() then error("mouse field missing: " .. item[1]) end
        local td = field:get_type()
        local offset, size = field:get_offset_from_base(), td:get_valuetype_size()
        if td:get_full_name() ~= item[2] or size ~= item[3] or type(offset) ~= "number" or offset < 0
            or offset + size > object_size then
            error("mouse field layout mismatch: " .. item[1])
        end
        layouts[#layouts + 1] = { offset = offset, size = size }
    end
    return layouts
end

-- active():面板是否要求屏蔽。返回 true 表示设备清零装上了。
function InputGuard.install(active, logger)
    local warn = logger or function() end
    local mouse_type = sdk.find_type_definition("via.hid.Mouse")
    local device_type = sdk.find_type_definition("share.hid.Device")
    if not mouse_type or not device_type or not thread or not thread.get_hook_storage then
        warn("[AVM] InputGuard: via.hid.Mouse / share.hid.Device / hook storage unavailable; game mouse not guarded")
        return false
    end
    local function mouse(name, ...)
        local m = sdk.get_native_singleton("via.hid.Mouse")
        if not m then return nil end
        return sdk.call_native_func(m, mouse_type, name, ...)
    end
    -- 物理鼠标键是否全部松开(读引擎设备,不受我们清零的 share.hid.Device 影响)
    local function released()
        local ok, up = pcall(function()
            local dev = mouse("get_Device()")
            return dev ~= nil and dev:call("get_Button()") == 0 and dev:call("get_ButtonUp()") == 0
        end)
        return ok and up
    end

    local blocking = false   -- 这一帧是否在屏蔽(面板显示,或刚关、还在等松开)
    local function update_state()
        local ok, on = pcall(active)
        on = ok and on == true
        if on then blocking = true
        elseif blocking and released() then blocking = false end
        publish(blocking)
        return blocking
    end

    -- 1. 设备清零
    local ok_layout, layouts = pcall(layout_of, device_type)
    local hooked = false
    if not ok_layout then
        warn("[AVM] InputGuard: " .. tostring(layouts) .. "; game mouse buttons not guarded")
    else
        local ok_hook, err = pcall(function()
            sdk.hook(device_type:get_method("update()"), function(args)
                local storage = thread.get_hook_storage()
                storage.avm_re4_device = blocking and sdk.to_managed_object(args[2]) or nil
            end, function(retval)
                local storage = thread.get_hook_storage()
                local device = storage.avm_re4_device
                storage.avm_re4_device = nil
                if device and blocking then
                    pcall(function()
                        if not device:get_type_definition():is_a(device_type) then return end
                        for _, f in ipairs(layouts) do
                            for b = 0, f.size - 1 do device:write_byte(f.offset + b, 0) end
                        end
                    end)
                end
                return retval
            end)
        end)
        hooked = ok_hook
        if not ok_hook then warn("[AVM] InputGuard: hook share.hid.Device.update failed: " .. tostring(err)) end
    end

    -- 2. 光标模式:saved 不为 nil 表示我们在保持光标;saved.joined = 别的面板先接管了,我们只帮着保持、不负责还原。
    --
    -- 不能像以前那样"有别的面板在屏蔽就让给它":SKS 的规则是"有别的面板在屏蔽就不接管",
    -- 两边同一帧都登记了屏蔽、又都还没接管时,谁也不切绝对模式,引擎就一直把光标拉回中间
    -- (2026-11-05 用户在调色页拖滑条时遇到,时好时坏)。所以按光标的实际状态判断:
    --   已经是绝对模式 → 别人接管了,我们 joined;还是相对模式 → 没人接管,我们接管并记下原值。
    local saved = nil
    local function release_cursor()
        pcall(function()
            if not saved then
                -- 注意别写成 `type(x) == "boolean" and x or nil`:x 为 false 时会得到 nil
                local absolute, clip = mouse("get_AbsoluteMode()"), mouse("get_ClipCursorToScreen()")
                if other_panel() and absolute == true then
                    saved = { joined = true }
                else
                    saved = {}
                    if type(absolute) == "boolean" then saved.absolute = absolute end
                    if type(clip) == "boolean" then saved.clip = clip end
                end
            end
            if (saved.joined or saved.absolute ~= nil) and mouse("get_AbsoluteMode()") ~= true then mouse("set_AbsoluteMode(System.Boolean)", true) end
            if (saved.joined or saved.clip ~= nil) and mouse("get_ClipCursorToScreen()") ~= false then mouse("set_ClipCursorToScreen(System.Boolean)", false) end
        end)
    end
    local function restore_cursor()
        if not saved then return end
        -- 别的面板接管的:原值在它那里,由它还原
        if saved.joined then saved = nil; return end
        if other_panel() then return end
        local state = saved
        local ok = pcall(function()
            if state.absolute ~= nil then mouse("set_AbsoluteMode(System.Boolean)", state.absolute) end
            if state.clip ~= nil then mouse("set_ClipCursorToScreen(System.Boolean)", state.clip) end
        end)
        if ok then saved = nil end
    end

    -- 3. 让游戏自己放开光标:屏蔽期间 chainsaw.GuiManager.isMousePointerDispGui 回答 true。
    -- 游戏在野外会用 SetCursorPos 把系统光标拉回屏幕中心(REFramework 只在它的菜单开着时拦这个调用),
    -- 改 via.hid.Mouse 的绝对模式压不住;它自己的菜单(暂停等)就是靠这个函数放开光标的 ——
    -- 2026-11-05 实测:暂停菜单开着时它返回 true、ClipCursorToScreen 变 false,野外返回 false。
    -- 做法同 SKS 在荒野上 hook app.GUIManager.isMouseCursorAvailable。
    pcall(function()
        local gm = sdk.find_type_definition("chainsaw.GuiManager")
        local m = gm and gm:get_method("isMousePointerDispGui(chainsaw.RenderOutputType, via.hid.GamePadButton)")
        if not m then
            warn("[AVM] InputGuard: chainsaw.GuiManager.isMousePointerDispGui unavailable; cursor may be pulled to the centre")
            return
        end
        sdk.hook(m, nil, function(retval)
            if blocking then return sdk.to_ptr(true) end
            return retval
        end)
    end)

    re.on_frame(function()
        if update_state() then release_cursor() else restore_cursor() end
    end)
    re.on_script_reset(function()
        blocking = false
        publish(false)
        restore_cursor()
    end)
    return hooked
end

-- REFF 面板当前是否显示(REFF 未安装时为 false)
function InputGuard.reff_visible()
    local native = rawget(_G, "reff_native")
    return native ~= nil and native.is_visible ~= nil and native.is_visible() == true
end

return InputGuard
