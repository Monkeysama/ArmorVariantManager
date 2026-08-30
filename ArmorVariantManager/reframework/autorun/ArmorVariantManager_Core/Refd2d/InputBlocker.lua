local InputBlocker = {}

-- 桥接状态放在运行时目录，避免与用户持久化的 GlobalSettings 混在一起。
local cursor_bridge_state_path = "ArmorVariantManager/Runtime/D2DInputState.json"

-- 重载脚本后旧 Hook 可能仍在 native 层，统一使用全局状态避免旧 Hook 恢复错误的光标状态。
local function input_is_blocked()
    return _G.__AVM_REFD2D_INPUT_BLOCKED == true
end

-- 创建游戏输入拦截器。D2D 使用 ImGui 的原始鼠标状态，游戏则读取被清空的输入对象。
function InputBlocker.new()
    _G.__AVM_REFD2D_INPUT_BLOCKED = false
    local component = {
        enabled = false,
        installed = false,
        hook_count = 0,
        failed_hooks = {},
        last_error = nil,
        wheel_delta = 0,
        mouse_mode_saved = false,
        saved_absolute_mode = nil,
        saved_show_cursor = nil,
        saved_clip_cursor = nil,
        saved_mouse_manipulator = nil,
        mouse_mode_hook_installed = false,
        mouse_info_hook_installed = false,
        last_mouse_info = nil,
        zero_point = nil,
        last_mode_log_at = 0,
        last_mode_apply_at = 0,
        cursor_x = nil,
        cursor_y = nil,
        cursor_initialized = false,
        point_type = nil
    }
    setmetatable(component, { __index = InputBlocker })
    component:install()

    -- 在游戏读取 HID 之前同步拦截状态，避免 on_frame 更新得太晚而让鼠标事件先穿透一帧。
    if re and re.on_pre_application_entry then
        re.on_pre_application_entry("UpdateHID", function()
            if component.enabled then
                component.wheel_delta = 0
                component:set_mouse_mode(true)
            end
        end)
    end
    -- 游戏更新 HID 后可能重新选择 RuntimeDefault，后置确认确保相对模式不会把光标拉回中心。
    if re and re.on_application_entry then
        re.on_application_entry("UpdateHID", function()
            if component.enabled then
                component:set_mouse_mode(true)
            end
        end)
    end
    if re and re.on_pre_application_entry then
        -- UpdateMotionFrame 位于相机消费输入前，在这里读取并清空本帧鼠标量，
        -- 避免鼠标增量继续传给视角，同时保留给 D2D 自绘光标使用。
        re.on_pre_application_entry("UpdateMotionFrame", function()
            if component.enabled then
                component:capture_and_clear_mouse_info()
            end
        end)
    end
    return component
end

-- 同步弹窗是否开启给光标桥接 DLL，DLL 仅在状态开启时拦截 SetCursorPos。
function InputBlocker:write_cursor_bridge_state(blocked)
    local ok, error_value = pcall(function()
        json.dump_file(cursor_bridge_state_path, { blocked = blocked == true })
    end)
    if not ok then self.last_error = tostring(error_value) end
end

-- 安全调用输入对象的 clear，避免切场景或输入设备重建时产生脚本错误。
function InputBlocker:clear_input(input)
    if not input then return end
    local ok, error_value = pcall(function()
        -- 不同输入包装对象的 managed/native 判定可能不同，统一尝试调用 clear。
        input:call("clear")
    end)
    if not ok then self.last_error = tostring(error_value) end
end

-- 生成可用于 Hook 返回值的真正 via.Point 值类型。
-- 直接修改 post 回调中的 userdata 字段在 Wilds 中不会改变值类型返回值。
function InputBlocker:get_zero_point()
    if self.zero_point then return self.zero_point end
    local ok, point = pcall(function()
        if not ValueType or not ValueType.new then return nil end
        local type_definition = sdk.find_type_definition("via.Point")
        if not type_definition then return nil end
        local value = ValueType.new(type_definition)
        value.x = 0
        value.y = 0
        return value
    end)
    if ok then self.zero_point = point end
    return self.zero_point
end

-- 获取 D2D 实际绘制表面尺寸，避免 ImGui 显示尺寸与 D2D 尺寸不一致时边界错位。
function InputBlocker:get_surface_size()
    local d2d_ok, width, height = pcall(function()
        if d2d and d2d.surface_size then return d2d.surface_size() end
        return nil, nil
    end)
    if d2d_ok and type(width) == "number" and type(height) == "number"
        and width > 0 and height > 0 then
        return width, height
    end
    local imgui_ok, size = pcall(function() return imgui.get_display_size() end)
    width = imgui_ok and size and (size.x or size[1]) or 0
    height = imgui_ok and size and (size.y or size[2]) or 0
    return width, height
end

-- 初始化自绘光标到 D2D 表面中心。窗口模式下 get_ScreenCursorPosition 是桌面绝对坐标，
-- 不能直接用于 D2D 的窗口局部坐标，否则会随窗口位置产生整体偏移。
function InputBlocker:initialize_cursor()
    if self.cursor_initialized then return end
    local width, height = self:get_surface_size()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then return end
    self.cursor_x, self.cursor_y = width / 2, height / 2
    self.cursor_initialized = true
    _G.__AVM_REFD2D_CURSOR_POSITION = { x = self.cursor_x, y = self.cursor_y }
end

-- 将相对鼠标增量累积到 D2D 自绘光标，并限制在当前游戏渲染区域内。
function InputBlocker:apply_cursor_delta(dx, dy)
    if not input_is_blocked() then return end
    if type(dx) ~= "number" or type(dy) ~= "number" then return end
    if dx == 0 and dy == 0 then return end
    if not self.cursor_initialized then
        self:initialize_cursor()
    end
    if not self.cursor_initialized then return end
    local width, height = self:get_surface_size()
    self.cursor_x = self.cursor_x + dx
    self.cursor_y = self.cursor_y + dy
    if width > 0 then self.cursor_x = math.max(0, math.min(width - 1, self.cursor_x)) end
    if height > 0 then self.cursor_y = math.max(0, math.min(height - 1, self.cursor_y)) end
    local cursor = _G.__AVM_REFD2D_CURSOR_POSITION
    if type(cursor) ~= "table" then
        cursor = {}
        _G.__AVM_REFD2D_CURSOR_POSITION = cursor
    end
    cursor.x, cursor.y = self.cursor_x, self.cursor_y
end

-- 从任意 via.Point 包装对象提取相对移动量，兼容 native 值类型和 Lua 字段包装。
function InputBlocker:read_point_delta(point)
    local dx, dy
    local ok = pcall(function()
        if not self.point_type then self.point_type = sdk.find_type_definition("via.Point") end
        if point and self.point_type then
            dx = sdk.get_native_field(point, self.point_type, "x")
            dy = sdk.get_native_field(point, self.point_type, "y")
        end
        -- 某些版本会把 native 值类型包装成可直接访问字段的对象。
        if type(dx) ~= "number" or type(dy) ~= "number" then
            dx, dy = point and point.x, point and point.y
        end
    end)
    if not ok or type(dx) ~= "number" or type(dy) ~= "number" then return nil, nil end
    return dx, dy
end

-- 保存 HID getter 返回的相对移动；仅作为旧输入链路的兼容回退。
function InputBlocker:capture_motion(retval)
    local dx, dy = self:read_point_delta(retval)
    self:apply_cursor_delta(dx, dy)
end

-- 在清零前读取汇总输入对象。Wilds 的绝对模式下 HID getter 可能恒为零，
-- 但 applyMergeMouse 写入的 cMouseKeyboardInfo 仍保存真实的原始移动量。
function InputBlocker:capture_mouse_info_motion(input)
    if not input_is_blocked() or not input then return end
    -- getter 会返回可直接读取的 via.Point，优先使用以兼容值类型字段无法包装的运行时。
    local getter_ok, getter_point = pcall(function() return input:call("get_MouseDeltaPos") end)
    if getter_ok and getter_point then
        local dx, dy = self:read_point_delta(getter_point)
        if type(dx) == "number" and type(dy) == "number" and (dx ~= 0 or dy ~= 0) then
            self:apply_cursor_delta(dx, dy)
            return
        end
    end
    local fields = { "_MouseRawDeltaPos", "_MouseMovePos", "_MouseDeltaPos" }
    for _, field_name in ipairs(fields) do
        local ok, point = pcall(function() return input:get_field(field_name) end)
        if ok and point then
            local dx, dy = self:read_point_delta(point)
            if type(dx) == "number" and type(dy) == "number" and (dx ~= 0 or dy ~= 0) then
                self:apply_cursor_delta(dx, dy)
                return
            end
        end
    end
end

-- 直接清空 cMouseKeyboardInfo 内的 Point 字段，覆盖相对移动、原始移动和位置增量。
function InputBlocker:zero_point_field(input, field_name)
    if not input then return end
    pcall(function()
        local type_definition = input:get_type_definition()
        local field = type_definition and type_definition:get_field(field_name)
        if not field then return end
        local offset = field:get_offset_from_base()
        local size = field:get_type():get_valuetype_size()
        for index = 0, size - 1 do
            input:write_byte(offset + index, 0)
        end
    end)
end

-- 清空汇总输入对象，同时保留本帧滚轮供 D2D 列表消费。
function InputBlocker:zero_mouse_info(input)
    if not input then return end
    -- 必须在字段归零前保存移动量，否则自绘光标会失去唯一的相对输入来源。
    self:capture_mouse_info_motion(input)
    pcall(function()
        local wheel = input:call("get_MouseWheelDelta")
        if type(wheel) == "number" and wheel ~= 0 then self.wheel_delta = wheel end
    end)
    self:zero_point_field(input, "_MouseDeltaPos")
    self:zero_point_field(input, "_MouseMovePos")
    self:zero_point_field(input, "_MouseRawDeltaPos")
    pcall(function() input:set_field("_MouseWheel", 0) end)
    pcall(function() input:set_field("_MouseWheelDelta", 0) end)
end

-- 在 GameInputManager 更新结束后清空游戏实际消费的输入对象。
-- 同时清理 PC 原始输入与按当前设备类型转换后的输入，覆盖键鼠和手柄切换场景。
function InputBlocker:clear_game_inputs(player_input)
    if not self.enabled then return end
    local ok, error_value = pcall(function()
        local manager = sdk.get_managed_singleton("app.GameInputManager")
        if not manager then return end
        if player_input then
            self:clear_input(manager:call("get_PcPlayerInput"))
            self:clear_input(manager:call("get_PlayerInput"))
        else
            self:clear_input(manager:call("get_PcUIInput"))
            self:clear_input(manager:call("get_UIInput"))
        end
        -- 游戏输入更新可能把鼠标重新切回相对模式，每次更新后重新确认弹窗的鼠标模式。
        self:set_mouse_mode(true)
    end)
    if not ok then self.last_error = tostring(error_value) end
end

-- 保存本帧滚轮后清空原始鼠标键盘信息，阻止游戏直接读取 MouseKeyboardInfo。
function InputBlocker:capture_and_clear_mouse_info()
    -- 弹窗关闭时不访问输入管理器，避免每帧产生托管对象调用和字段扫描。
    if not self.enabled then return end
    local ok, error_value = pcall(function()
        local manager = sdk.get_managed_singleton("app.AppMouseKeyboardManager")
        if not manager then return end
        local mouse_keyboard = manager:call("get_MainMouseKeyboard")
        if not mouse_keyboard then return end
        local wheel = mouse_keyboard:call("get_MouseWheelDelta")
        -- MergedMouseDevice 的拦截器优先保存非零值，避免这里读到已清空的值覆盖滚轮事件。
        if type(wheel) == "number" and wheel ~= 0 then self.wheel_delta = wheel end
        self:clear_input(mouse_keyboard)
        self:zero_mouse_info(mouse_keyboard)
        self:set_mouse_mode(true)
    end)
    if not ok then self.last_error = tostring(error_value) end
end

-- 弹窗打开时切换到绝对鼠标模式，避免游戏的相对视角逻辑持续把光标拽回屏幕中心。
-- 对单次 native 调用单独容错，避免某个鼠标属性缺失时跳过其他拦截措施。
function InputBlocker:call_mouse_native(mouse, mouse_type, method_name, ...)
    local arguments = { ... }
    local unpack_arguments = table.unpack or unpack
    -- native 对象必须优先使用 sdk.call_native_func；NativeObject:call 在部分版本中
    -- 可能不报错但不真正执行 setter，导致鼠标模式看似切换、实际仍保持相对模式。
    local native_ok, native_value = pcall(function()
        return sdk.call_native_func(mouse, mouse_type, method_name, unpack_arguments(arguments))
    end)
    if native_ok then return true, native_value end

    -- 兼容少数旧版运行时：如果 native 调用失败，再尝试对象调用。
    local call_ok, call_value = pcall(function()
        return mouse:call(method_name, unpack_arguments(arguments))
    end)
    if not call_ok then
        self.last_error = tostring(native_value) .. " | " .. tostring(call_value)
    end
    return call_ok, call_value
end

-- 将枚举值转换为 native Hook 参数所需的指针表示。
-- sdk.to_ptr 对不同 REFramework 版本的枚举包装兼容性不同，因此保留整数回退。
function InputBlocker:to_native_ptr(value)
    local ok, pointer = pcall(function() return sdk.to_ptr(value) end)
    if ok and pointer ~= nil then return pointer end
    local int_ok, integer = pcall(function() return sdk.to_int64(value) end)
    if int_ok and integer ~= nil then
        local ptr_ok, int_pointer = pcall(function() return sdk.to_ptr(integer) end)
        if ptr_ok then return int_pointer end
    end
    return nil
end

-- 读取枚举静态字段的原始 native 值，兼容不同版本对 Lua 枚举对象的包装。
function InputBlocker:get_enum_native_value(type_name, field_name, fallback)
    local ok, value = pcall(function()
        local type_definition = sdk.find_type_definition(type_name)
        local field = type_definition and type_definition:get_field(field_name)
        return field and field:get_data(nil)
    end)
    if ok and value ~= nil then return value end
    return fallback
end

-- 将 Lua 布尔值转换为 native setter 所需的指针参数。
function InputBlocker:to_bool_ptr(value)
    local ok, pointer = pcall(function() return sdk.to_ptr(value == true) end)
    if ok then return pointer end
    return nil
end

-- 低频记录鼠标模式，便于确认 setter 是否被游戏逻辑覆盖，同时避免每帧刷日志。
function InputBlocker:log_mouse_mode(mouse, mouse_type, reason)
    if not log or not log.info then return end
    local now = os.clock()
    if now - (self.last_mode_log_at or 0) < 0.5 then return end
    self.last_mode_log_at = now
    local function read_value(method_name)
        local read_ok, value = self:call_mouse_native(mouse, mouse_type, method_name)
        if not read_ok then return "<error>" end
        return tostring(value)
    end
    local ok, absolute, clip, shown, manipulator = pcall(function()
        return true, read_value("get_AbsoluteMode()"), read_value("get_ClipCursorToScreen()"),
            read_value("get_ShowCursor()"), read_value("get_MouseManipulator()")
    end)
    if ok then
        log.info(string.format("[ArmorVariantManager] D2D mouse mode (%s): absolute=%s clip=%s show=%s manipulator=%s",
            tostring(reason), tostring(absolute), tostring(clip), tostring(shown), tostring(manipulator)))
    end
end

function InputBlocker:set_mouse_mode(blocked, force)
    if blocked and not force then
        local now = os.clock()
        -- 鼠标模式只需低频校正，避免每帧重复调用多个 native getter/setter。
        if now - (self.last_mode_apply_at or 0) < 0.25 then return end
        self.last_mode_apply_at = now
    end
    local ok, error_value = pcall(function()
        local mouse = sdk.get_native_singleton("via.hid.Mouse")
        local mouse_type = sdk.find_type_definition("via.hid.Mouse")
        if not mouse or not mouse_type then return end

        if blocked then
            if not self.mouse_mode_saved then
                _, self.saved_absolute_mode = self:call_mouse_native(mouse, mouse_type,
                    "get_AbsoluteMode()")
                _, self.saved_show_cursor = self:call_mouse_native(mouse, mouse_type,
                    "get_ShowCursor()")
                _, self.saved_clip_cursor = self:call_mouse_native(mouse, mouse_type,
                    "get_ClipCursorToScreen()")
                -- 保存游戏原本的鼠标操控器，关闭弹窗时完整恢复。
                _, self.saved_mouse_manipulator = self:call_mouse_native(mouse, mouse_type,
                    "get_MouseManipulator()")
                self.mouse_mode_saved = true
            end
            -- 使用 Null 操控器接管游戏鼠标，避免相对鼠标模式把位置重新锁回屏幕中心。
            -- 自绘光标由 D2D 绘制，不依赖游戏的系统光标。
            local null_value = self:get_enum_native_value(
                "via.hid.mouse.ManipulatorClientType", "Null",
                via.hid.mouse.ManipulatorClientType.Null)
            self:call_mouse_native(mouse, mouse_type,
                "set_MouseManipulator(via.hid.mouse.ManipulatorClientType)",
                self:to_native_ptr(null_value))
            self:call_mouse_native(mouse, mouse_type, "set_AbsoluteMode(System.Boolean)",
                self:to_bool_ptr(true))
            -- 保留游戏自己的窗口裁剪。窗口化时强制关闭裁剪会让物理鼠标离开游戏，
            -- 而且不同 DPI 下由脚本重算裁剪矩形容易与 D2D 坐标产生偏移。
            -- D2D 使用自绘光标，隐藏游戏自己的系统光标，避免出现两个光标。
            self:call_mouse_native(mouse, mouse_type, "set_ShowCursor(System.Boolean)",
                self:to_bool_ptr(false))
        elseif self.mouse_mode_saved then
            -- 关闭弹窗时恢复打开前的操控器，避免影响游戏和其他插件的鼠标行为。
            if self.saved_mouse_manipulator ~= nil then
                self:call_mouse_native(mouse, mouse_type,
                    "set_MouseManipulator(via.hid.mouse.ManipulatorClientType)",
                    self:to_native_ptr(self.saved_mouse_manipulator))
            end
            self:call_mouse_native(mouse, mouse_type,
                "set_AbsoluteMode(System.Boolean)", self:to_bool_ptr(self.saved_absolute_mode == true))
            self:call_mouse_native(mouse, mouse_type,
                "set_ClipCursorToScreen(System.Boolean)",
                self:to_bool_ptr(self.saved_clip_cursor == true))
            if self.saved_show_cursor ~= nil then
                self:call_mouse_native(mouse, mouse_type,
                    "set_ShowCursor(System.Boolean)",
                    self:to_bool_ptr(self.saved_show_cursor == true))
            end
            self.mouse_mode_saved = false
        end
        if blocked then self:log_mouse_mode(mouse, mouse_type, "blocked") end
    end)
    if not ok then self.last_error = tostring(error_value) end
end

-- 安装游戏输入更新后的清理 Hook，恢复旧版弹窗的输入阻断行为。
function InputBlocker:install()
    if self.installed or not sdk then return end
    self.installed = true
    local type_ok, type_definition = pcall(function()
        return sdk.find_type_definition("app.GameInputManager")
    end)
    if not type_ok or not type_definition then
        table.insert(self.failed_hooks, "app.GameInputManager (type not found)")
        return
    end

    local function install_update_hook(signature, player_input)
        local method_ok, method = pcall(function()
            return type_definition:get_method(signature)
        end)
        if not method_ok or not method then
            table.insert(self.failed_hooks, "app.GameInputManager:" .. signature)
            return
        end
        local hook_ok, hook_error = pcall(function()
            sdk.hook(method, nil, function(retval)
                if input_is_blocked() then self:clear_game_inputs(player_input) end
                return retval
            end)
        end)
        if hook_ok then
            self.hook_count = self.hook_count + 1
        else
            table.insert(self.failed_hooks,
                "app.GameInputManager:" .. signature .. " (" .. tostring(hook_error) .. ")")
        end
    end

    -- 玩家输入负责相机，UI 输入负责游戏界面；两条都在后置阶段清理。
    install_update_hook("updatePlayerInput()", true)
    install_update_hook("updateUIInput()", false)
end

-- 读取游戏汇总后的真实滚轮增量。imgui.get_mouse_wheel 并非当前 Lua API，
-- 之前被 pcall 吞掉并恒为 0，导致 D2D 材质列表无法滚动。
function InputBlocker:get_mouse_wheel()
    local ok, wheel = pcall(function()
        return self.wheel_delta or 0
    end)
    if ok and type(wheel) == "number" then return wheel end
    if not ok then self.last_error = tostring(wheel) end
    return 0
end

-- 更新弹窗开启状态。快捷键由 reframework:is_key_down 独立读取，不依赖游戏输入对象。
function InputBlocker:set_enabled(enabled)
    local next_enabled = enabled == true
    _G.__AVM_REFD2D_INPUT_BLOCKED = next_enabled
    -- 即使状态没有变化也要重新校正一次，防止游戏在本帧稍后恢复相对鼠标模式。
    if next_enabled == self.enabled then
        return
    end
    self.enabled = next_enabled
    -- 每次打开都重置为窗口局部坐标，避免保留上次窗口位置或桌面坐标造成的偏移。
    if next_enabled then
        self.cursor_initialized = false
        self.cursor_x, self.cursor_y = nil, nil
        self:initialize_cursor()
    else
        _G.__AVM_REFD2D_CURSOR_POSITION = nil
    end
    self:write_cursor_bridge_state(next_enabled)
    self:set_mouse_mode(next_enabled)
end

return InputBlocker
