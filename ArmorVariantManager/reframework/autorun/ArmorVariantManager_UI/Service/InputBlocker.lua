local InputBlocker = {}
local BridgeRuntime = require("ArmorVariantManager_UI.Service.BridgeRuntime")
local default_cursor_bridge_state_path = "ArmorVariantManager/Runtime/D2DInputState.json"
local function get_blocker_states()
    if type(_G.__AVM_UI_INPUT_BLOCKER_STATES) ~= "table" then
        _G.__AVM_UI_INPUT_BLOCKER_STATES = {}
    end
    return _G.__AVM_UI_INPUT_BLOCKER_STATES
end
local function refresh_blocked_state()
    local blocked = false
    for _, enabled in pairs(get_blocker_states()) do
        if enabled == true then
            blocked = true
            break
        end
    end
    _G.__AVM_REFD2D_INPUT_BLOCKED = blocked
    return blocked
end
local function input_is_blocked()
    return refresh_blocked_state()
end
function InputBlocker.new(options)
    options = options or {}
    local paths = BridgeRuntime.paths(options.runtime_directory)
    local blocker_id = options.client_id or BridgeRuntime.default_client_id
    BridgeRuntime.register(blocker_id, paths.runtime_directory)
    get_blocker_states()[blocker_id] = false
    refresh_blocked_state()
    local component = {
        enabled = false,
        blocker_id = blocker_id,
        cursor_bridge_state_path = options.cursor_bridge_state_path or paths.state_path,
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
    if re and re.on_pre_application_entry then
        re.on_pre_application_entry("UpdateHID", function()
            if component.enabled then
                component.wheel_delta = 0
                component:set_mouse_mode(true)
            end
        end)
    end
    if re and re.on_application_entry then
        re.on_application_entry("UpdateHID", function()
            if component.enabled then
                component:set_mouse_mode(true)
            end
        end)
    end
    if re and re.on_pre_application_entry then
        re.on_pre_application_entry("UpdateMotionFrame", function()
            if component.enabled then
                component:capture_and_clear_mouse_info()
            end
        end)
    end
    return component
end
function InputBlocker:write_cursor_bridge_state(blocked)
    local ok, error_value = pcall(function()
        json.dump_file(self.cursor_bridge_state_path, { blocked = blocked == true })
    end)
    if not ok then self.last_error = tostring(error_value) end
end
function InputBlocker:clear_input(input)
    if not input then return end
    local ok, error_value = pcall(function()
        input:call("clear")
    end)
    if not ok then self.last_error = tostring(error_value) end
end
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
function InputBlocker:initialize_cursor()
    if self.cursor_initialized then return end
    local width, height = self:get_surface_size()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then return end
    self.cursor_x, self.cursor_y = width / 2, height / 2
    self.cursor_initialized = true
    _G.__AVM_REFD2D_CURSOR_POSITION = { x = self.cursor_x, y = self.cursor_y }
end
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
function InputBlocker:read_point_delta(point)
    local dx, dy
    local ok = pcall(function()
        if not self.point_type then self.point_type = sdk.find_type_definition("via.Point") end
        if point and self.point_type then
            dx = sdk.get_native_field(point, self.point_type, "x")
            dy = sdk.get_native_field(point, self.point_type, "y")
        end
        if type(dx) ~= "number" or type(dy) ~= "number" then
            dx, dy = point and point.x, point and point.y
        end
    end)
    if not ok or type(dx) ~= "number" or type(dy) ~= "number" then return nil, nil end
    return dx, dy
end
function InputBlocker:capture_motion(retval)
    local dx, dy = self:read_point_delta(retval)
    self:apply_cursor_delta(dx, dy)
end
function InputBlocker:capture_mouse_info_motion(input)
    if not input_is_blocked() or not input then return end
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
function InputBlocker:zero_mouse_info(input)
    if not input then return end
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
        self:set_mouse_mode(true)
    end)
    if not ok then self.last_error = tostring(error_value) end
end
function InputBlocker:capture_and_clear_mouse_info()
    if not self.enabled then return end
    local ok, error_value = pcall(function()
        local manager = sdk.get_managed_singleton("app.AppMouseKeyboardManager")
        if not manager then return end
        local mouse_keyboard = manager:call("get_MainMouseKeyboard")
        if not mouse_keyboard then return end
        local wheel = mouse_keyboard:call("get_MouseWheelDelta")
        if type(wheel) == "number" and wheel ~= 0 then self.wheel_delta = wheel end
        self:clear_input(mouse_keyboard)
        self:zero_mouse_info(mouse_keyboard)
        self:set_mouse_mode(true)
    end)
    if not ok then self.last_error = tostring(error_value) end
end
function InputBlocker:call_mouse_native(mouse, mouse_type, method_name, ...)
    local arguments = { ... }
    local unpack_arguments = table.unpack or unpack
    local native_ok, native_value = pcall(function()
        return sdk.call_native_func(mouse, mouse_type, method_name, unpack_arguments(arguments))
    end)
    if native_ok then return true, native_value end
    local call_ok, call_value = pcall(function()
        return mouse:call(method_name, unpack_arguments(arguments))
    end)
    if not call_ok then
        self.last_error = tostring(native_value) .. " | " .. tostring(call_value)
    end
    return call_ok, call_value
end
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
function InputBlocker:get_enum_native_value(type_name, field_name, fallback)
    local ok, value = pcall(function()
        local type_definition = sdk.find_type_definition(type_name)
        local field = type_definition and type_definition:get_field(field_name)
        return field and field:get_data(nil)
    end)
    if ok and value ~= nil then return value end
    return fallback
end
function InputBlocker:to_bool_ptr(value)
    local ok, pointer = pcall(function() return sdk.to_ptr(value == true) end)
    if ok then return pointer end
    return nil
end
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
                _, self.saved_mouse_manipulator = self:call_mouse_native(mouse, mouse_type,
                    "get_MouseManipulator()")
                self.mouse_mode_saved = true
            end
            local null_value = self:get_enum_native_value(
                "via.hid.mouse.ManipulatorClientType", "Null",
                via.hid.mouse.ManipulatorClientType.Null)
            self:call_mouse_native(mouse, mouse_type,
                "set_MouseManipulator(via.hid.mouse.ManipulatorClientType)",
                self:to_native_ptr(null_value))
            self:call_mouse_native(mouse, mouse_type, "set_AbsoluteMode(System.Boolean)",
                self:to_bool_ptr(true))
            self:call_mouse_native(mouse, mouse_type, "set_ShowCursor(System.Boolean)",
                self:to_bool_ptr(false))
        elseif self.mouse_mode_saved then
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
    install_update_hook("updatePlayerInput()", true)
    install_update_hook("updateUIInput()", false)
end
function InputBlocker:get_mouse_wheel()
    local ok, wheel = pcall(function()
        return self.wheel_delta or 0
    end)
    if ok and type(wheel) == "number" then return wheel end
    if not ok then self.last_error = tostring(wheel) end
    return 0
end
function InputBlocker:set_enabled(enabled)
    local next_enabled = enabled == true
    get_blocker_states()[self.blocker_id] = next_enabled
    refresh_blocked_state()
    if next_enabled == self.enabled then
        return
    end
    self.enabled = next_enabled
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
