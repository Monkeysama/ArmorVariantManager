-- ============================================================================
--  差分管理器（崛起版本）新版 UI —— 输入接管服务
-- ----------------------------------------------------------------------------
--  职责：新版 UI 显示期间，把鼠标控制权从游戏手里抢过来：
--    1. 让引擎鼠标进入「绝对坐标 + 显示光标」模式并解除光标裁剪；
--    2. 持续把光标位置写进 _G.__AVM_REFD2D_CURSOR_POSITION 供 UI 读取；
--    3. 尽最大努力阻止游戏继续消费鼠标（视角不再乱转）；
--    4. 提供滚轮增量。
--
--  与荒野版本（v4.0.0）的差异 —— 这是「荒野版 UI 无法在崛起运行」的主因：
--    荒野版直接操作 app.GameInputManager / app.AppMouseKeyboardManager（荒野
--    专属类型），崛起没有这些类型。崛起使用 snow.StmInputManager，且方法签名
--    未知，因此这里改为：
--      * 引擎级 via.hid.Mouse 操作（崛起确认存在，EMV Engine 亦在使用）；
--      * 游戏级输入屏蔽改为「运行时自省 + 特征探测」：枚举候选类型的方法名，
--        按名字挂钩，全部 pcall 保护，任何一步失败都不影响 UI 显示；
--      * 滚轮优先取 ImGui 的 MouseWheel（与游戏无关，最可靠）。
--    探测结果会写进 self.backend / self.failed_hooks 供设置面板显示。
-- ============================================================================
local InputBlocker = {}
local BridgeRuntime = require("ArmorVariantManager_UI.Service.BridgeRuntime")

-- 崛起版本候选的游戏级输入管理器类型（按优先级）
local INPUT_MANAGER_TYPE_CANDIDATES = {
    "snow.StmInputManager",
    "app.GameInputManager",
    "snow.device.InputManager",
    "snow.InputManager"
}

-- 名字命中即挂钩的「输入更新」方法名（不写签名，避免签名不匹配导致挂钩失败）
-- 故意只保留语义明确的名字，不挂钩通用的 update()，避免影响游戏主循环
local INPUT_UPDATE_METHOD_NAMES = {
    updatePlayerInput = true,
    updateUIInput = true,
    updateAppInput = true,
    updateInput = true,
    updatePad = true,
    updateMouse = true
}

-- 用来取得「可清空输入对象」的 getter 名（前缀匹配）
local INPUT_OBJECT_GETTER_PREFIXES = {
    "get_PcPlayerInput",
    "get_PcUIInput",
    "get_PlayerInput",
    "get_UIInput",
    "get_AppPlayerInput",
    "get_AppUIInput",
    "get_MouseKeyboard",
    "get_MainMouseKeyboard"
}

-- 引擎鼠标 delta 字段名（崛起/荒野同为 RE Engine，存在则清零）
local MOUSE_DELTA_FIELDS = { "_MouseDeltaPos", "_MouseMovePos", "_MouseRawDeltaPos" }
local MOUSE_WHEEL_FIELDS = { "_MouseWheel", "_MouseWheelDelta" }

-- 候选应用入口名（用于在游戏更新输入前清空输入）
-- 同样不包含通用的 "Update"，避免每帧都触发我们的回调
local UPDATE_ENTRY_CANDIDATES = { "UpdateHID", "UpdateInput", "UpdateMouse" }

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

local function safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return true, result end
    return false, result
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
        last_mode_apply_at = 0,
        cursor_x = nil,
        cursor_y = nil,
        cursor_initialized = false,
        engine_mouse = nil,
        engine_mouse_type = nil,
        engine_mouse_available = false,
        engine_mouse_probed = false,
        backend = "none",
        input_manager = nil,
        input_manager_type = nil,
        clear_targets = {},
        hook_installed = false,
        mouse_hook_installed = false,
        hooks_attempted = false,
        mute_game_input = options.mute_game_input ~= false,
        last_log_at = 0
    }
    setmetatable(component, { __index = InputBlocker })
    component:install()
    return component
end

-- ============================================================================
--  引擎级鼠标（via.hid.Mouse）—— 崛起确认存在
-- ============================================================================
function InputBlocker:probe_engine_mouse()
    if self.engine_mouse_probed then
        return self.engine_mouse_available
    end
    self.engine_mouse_probed = true
    local ok, mouse_type = safe_call(function()
        return sdk.find_type_definition("via.hid.Mouse")
    end)
    if not ok or not mouse_type then
        table.insert(self.failed_hooks, "via.hid.Mouse (type not found)")
        return false
    end
    local singleton_ok, singleton = safe_call(function()
        return sdk.get_native_singleton("via.hid.Mouse")
    end)
    if not singleton_ok or not singleton then
        table.insert(self.failed_hooks, "via.hid.Mouse (native singleton not found)")
        return false
    end
    self.engine_mouse_type = mouse_type
    self.engine_mouse = singleton
    self.engine_mouse_available = true
    return true
end

function InputBlocker:call_mouse_native(method_name, ...)
    if not self.engine_mouse or not self.engine_mouse_type then return false, nil end
    local arguments = { ... }
    local unpack_arguments = table.unpack or unpack
    local native_ok, native_value = safe_call(function()
        return sdk.call_native_func(self.engine_mouse, self.engine_mouse_type,
            method_name, unpack_arguments(arguments))
    end)
    if native_ok then return true, native_value end
    local call_ok, call_value = safe_call(function()
        return self.engine_mouse:call(method_name, unpack_arguments(arguments))
    end)
    if not call_ok then
        self.last_error = tostring(native_value) .. " | " .. tostring(call_value)
    end
    return call_ok, call_value
end

function InputBlocker:to_native_ptr(value)
    local ok, pointer = safe_call(function() return sdk.to_ptr(value) end)
    if ok and pointer ~= nil then return pointer end
    local int_ok, integer = safe_call(function() return sdk.to_int64(value) end)
    if int_ok and integer ~= nil then
        local ptr_ok, int_pointer = safe_call(function() return sdk.to_ptr(integer) end)
        if ptr_ok then return int_pointer end
    end
    return nil
end

function InputBlocker:to_bool_ptr(value)
    local ok, pointer = safe_call(function() return sdk.to_ptr(value == true) end)
    if ok then return pointer end
    return nil
end

function InputBlocker:get_enum_native_value(type_name, field_name, fallback)
    local ok, value = safe_call(function()
        local type_definition = sdk.find_type_definition(type_name)
        local field = type_definition and type_definition:get_field(field_name)
        return field and field:get_data(nil)
    end)
    if ok and value ~= nil then return value end
    return fallback
end

function InputBlocker:set_mouse_mode(blocked, force)
    if blocked and not force then
        local now = os.clock()
        if now - (self.last_mode_apply_at or 0) < 0.25 then return end
        self.last_mode_apply_at = now
    end
    if not self:probe_engine_mouse() then return end
    local ok = safe_call(function()
        if blocked then
            if not self.mouse_mode_saved then
                _, self.saved_absolute_mode = self:call_mouse_native("get_AbsoluteMode()")
                _, self.saved_show_cursor = self:call_mouse_native("get_ShowCursor()")
                _, self.saved_clip_cursor = self:call_mouse_native("get_ClipCursorToScreen()")
                _, self.saved_mouse_manipulator = self:call_mouse_native("get_MouseManipulator()")
                self.mouse_mode_saved = true
            end
            local null_value = self:get_enum_native_value(
                "via.hid.mouse.ManipulatorClientType", "Null", nil)
            if null_value ~= nil then
                self:call_mouse_native("set_MouseManipulator(via.hid.mouse.ManipulatorClientType)",
                    self:to_native_ptr(null_value))
            end
            self:call_mouse_native("set_AbsoluteMode(System.Boolean)", self:to_bool_ptr(true))
            self:call_mouse_native("set_ShowCursor(System.Boolean)", self:to_bool_ptr(false))
        elseif self.mouse_mode_saved then
            if self.saved_mouse_manipulator ~= nil then
                self:call_mouse_native("set_MouseManipulator(via.hid.mouse.ManipulatorClientType)",
                    self:to_native_ptr(self.saved_mouse_manipulator))
            end
            self:call_mouse_native("set_AbsoluteMode(System.Boolean)",
                self:to_bool_ptr(self.saved_absolute_mode == true))
            self:call_mouse_native("set_ClipCursorToScreen(System.Boolean)",
                self:to_bool_ptr(self.saved_clip_cursor == true))
            if self.saved_show_cursor ~= nil then
                self:call_mouse_native("set_ShowCursor(System.Boolean)",
                    self:to_bool_ptr(self.saved_show_cursor == true))
            end
            self.mouse_mode_saved = false
        end
    end)
    if not ok then self.last_error = tostring(select(2, safe_call(function() end))) end
end

-- 从引擎读取绝对光标位置（优先），失败返回 nil
function InputBlocker:read_engine_cursor()
    if not self:probe_engine_mouse() then return nil, nil end
    for _, method_name in ipairs({ "get_PresentRectCursorPosition()", "get_ScreenCursorPosition()",
        "get_CursorPosition()", "get_Position()" }) do
        local ok, point = self:call_mouse_native(method_name)
        if ok and point then
            local x, y = point.x, point.y
            if type(x) ~= "number" then x = nil end
            if type(y) ~= "number" then y = nil end
            if x and y and x >= 0 and y >= 0 then
                return x, y
            end
        end
    end
    return nil, nil
end

-- ============================================================================
--  游戏级输入屏蔽（运行时自省，全部可失败）
-- ============================================================================
function InputBlocker:find_input_manager()
    for _, type_name in ipairs(INPUT_MANAGER_TYPE_CANDIDATES) do
        local ok, type_definition = safe_call(function()
            return sdk.find_type_definition(type_name)
        end)
        if ok and type_definition then
            self.input_manager_type = type_definition
            self.backend = type_name
            return type_definition
        end
    end
    return nil
end

function InputBlocker:collect_input_object_getters()
    local type_definition = self.input_manager_type
    if not type_definition then return end
    local ok, methods = safe_call(function() return type_definition:get_methods() end)
    if not ok or type(methods) ~= "table" then return end
    for _, method in ipairs(methods) do
        local name_ok, name = safe_call(function() return method:get_name() end)
        if name_ok and type(name) == "string" then
            for _, prefix in ipairs(INPUT_OBJECT_GETTER_PREFIXES) do
                if name == prefix or string.sub(name, 1, #prefix + 1) == prefix .. "(" then
                    table.insert(self.clear_targets, { name = name, method = method })
                    break
                end
            end
        end
    end
end

function InputBlocker:clear_input_object(object)
    if not object then return end
    safe_call(function() object:call("clear") end)
    -- 清零鼠标 delta / 滚轮字段（存在则清）
    local object_type_ok, object_type = safe_call(function() return object:get_type_definition() end)
    if not object_type_ok or not object_type then return end
    for _, field_name in ipairs(MOUSE_DELTA_FIELDS) do
        safe_call(function()
            local field = object_type:get_field(field_name)
            if not field then return end
            local offset = field:get_offset_from_base()
            local size = field:get_type():get_valuetype_size()
            for index = 0, size - 1 do
                object:write_byte(offset + index, 0)
            end
        end)
    end
    local wheel_ok, wheel = safe_call(function() return object:call("get_MouseWheelDelta") end)
    if wheel_ok and type(wheel) == "number" and wheel ~= 0 then
        self.wheel_delta = wheel
    end
    for _, field_name in ipairs(MOUSE_WHEEL_FIELDS) do
        safe_call(function() object:set_field(field_name, 0) end)
    end
end

function InputBlocker:clear_game_inputs()
    if not self.mute_game_input then return end
    if not self.input_manager then return end
    safe_call(function()
        for _, target in ipairs(self.clear_targets) do
            local getter_ok, object = safe_call(function()
                return sdk.call_native_func(self.input_manager,
                    self.input_manager_type, target.name)
            end)
            if not getter_ok or not object then
                getter_ok, object = safe_call(function()
                    return self.input_manager:call(target.name)
                end)
            end
            if getter_ok and object then
                self:clear_input_object(object)
            end
        end
    end)
end

function InputBlocker:install()
    if self.installed or not sdk then return end
    self.installed = true
    -- 引擎级鼠标始终探测（释放光标必须用到）
    self:probe_engine_mouse()
    -- 游戏级输入屏蔽只在需要时才挂钩，避免给游戏主循环增加无谓开销
    if self.mute_game_input then
        self:install_game_input_hooks()
    end
end

function InputBlocker:install_game_input_hooks()
    if self.hooks_attempted or not sdk then return end
    self.hooks_attempted = true
    local type_definition = self:find_input_manager()
    if not type_definition then
        table.insert(self.failed_hooks, table.concat(INPUT_MANAGER_TYPE_CANDIDATES, " / ")
            .. " (none found; game input muting disabled)")
        if self.engine_mouse_available then
            self.backend = "via.hid.Mouse only"
        end
        return
    end
    local ok, methods = safe_call(function() return type_definition:get_methods() end)
    if not ok or type(methods) ~= "table" then
        table.insert(self.failed_hooks, self.backend .. ":get_methods() failed")
        return
    end
    for _, method in ipairs(methods) do
        local name_ok, name = safe_call(function() return method:get_name() end)
        if name_ok and type(name) == "string" then
            local bare_name = string.match(name, "^([%w_]+)") or name
            if INPUT_UPDATE_METHOD_NAMES[bare_name] then
                local hook_ok = safe_call(function()
                    sdk.hook(method, nil, function(retval)
                        if input_is_blocked() then self:clear_game_inputs() end
                        return retval
                    end)
                end)
                if hook_ok then
                    self.hook_count = self.hook_count + 1
                    self.hook_installed = true
                else
                    table.insert(self.failed_hooks, self.backend .. ":" .. name)
                end
            end
        end
    end
    self:collect_input_object_getters()
    if #self.clear_targets == 0 then
        table.insert(self.failed_hooks, self.backend .. " (no usable input getters)")
    end
    -- 兜底：在游戏更新输入前清空一次
    if re and re.on_pre_application_entry then
        for _, entry_name in ipairs(UPDATE_ENTRY_CANDIDATES) do
            safe_call(function()
                re.on_pre_application_entry(entry_name, function()
                    if self.enabled then self:clear_game_inputs() end
                end)
            end)
        end
    end
    if not self.hook_installed and self.engine_mouse_available then
        self.backend = self.backend .. " (no update hook)"
    end
end

-- ============================================================================
--  滚轮 / 光标
-- ============================================================================
function InputBlocker:get_mouse_wheel()
    -- 优先 ImGui（WM_MOUSEWHEEL 驱动，与游戏无关，最可靠）
    local io_ok, io = safe_call(function() return imgui.get_io() end)
    if io_ok and io then
        local wheel = io.MouseWheel
        if type(wheel) == "number" and wheel ~= 0 then
            self.wheel_delta = 0
            return wheel
        end
    end
    local wheel = self.wheel_delta or 0
    self.wheel_delta = 0
    return wheel
end

function InputBlocker:get_surface_size()
    local d2d_ok, width, height = safe_call(function()
        if d2d and d2d.surface_size then return d2d.surface_size() end
        return nil, nil
    end)
    if d2d_ok and type(width) == "number" and type(height) == "number"
        and width > 0 and height > 0 then
        return width, height
    end
    local imgui_ok, size = safe_call(function() return imgui.get_display_size() end)
    width = imgui_ok and size and (size.x or size[1]) or 0
    height = imgui_ok and size and (size.y or size[2]) or 0
    return width, height
end

function InputBlocker:update_cursor_position()
    local x, y = self:read_engine_cursor()
    if not x or not y then
        local mouse_ok, mouse = safe_call(function() return imgui.get_mouse() end)
        if mouse_ok and mouse and type(mouse.x) == "number" and type(mouse.y) == "number"
            and mouse.x >= 0 and mouse.y >= 0 then
            x, y = mouse.x, mouse.y
        end
    end
    if not x or not y then return end
    self.cursor_x, self.cursor_y = x, y
    self.cursor_initialized = true
    _G.__AVM_REFD2D_CURSOR_POSITION = { x = x, y = y }
end

function InputBlocker:apply_cursor_delta(dx, dy)
    if not input_is_blocked() then return end
    if type(dx) ~= "number" or type(dy) ~= "number" then return end
    if dx == 0 and dy == 0 then return end
    if not self.cursor_initialized then
        local width, height = self:get_surface_size()
        if width > 0 and height > 0 then
            self.cursor_x, self.cursor_y = width / 2, height / 2
            self.cursor_initialized = true
        else
            return
        end
    end
    local width, height = self:get_surface_size()
    self.cursor_x = self.cursor_x + dx
    self.cursor_y = self.cursor_y + dy
    if width > 0 then self.cursor_x = math.max(0, math.min(width - 1, self.cursor_x)) end
    if height > 0 then self.cursor_y = math.max(0, math.min(height - 1, self.cursor_y)) end
    _G.__AVM_REFD2D_CURSOR_POSITION = { x = self.cursor_x, y = self.cursor_y }
end

-- ============================================================================
--  开关
-- ============================================================================
function InputBlocker:write_cursor_bridge_state(blocked)
    local ok, error_value = safe_call(function()
        json.dump_file(self.cursor_bridge_state_path, { blocked = blocked == true })
    end)
    if not ok then self.last_error = tostring(error_value) end
end

function InputBlocker:set_enabled(enabled)
    local next_enabled = enabled == true
    get_blocker_states()[self.blocker_id] = next_enabled
    refresh_blocked_state()
    if next_enabled == self.enabled then return end
    self.enabled = next_enabled
    if next_enabled then
        self.cursor_initialized = false
        self:update_cursor_position()
        if not self.cursor_initialized then
            local width, height = self:get_surface_size()
            if width > 0 and height > 0 then
                self.cursor_x, self.cursor_y = width / 2, height / 2
                self.cursor_initialized = true
                _G.__AVM_REFD2D_CURSOR_POSITION = { x = self.cursor_x, y = self.cursor_y }
            end
        end
    else
        _G.__AVM_REFD2D_CURSOR_POSITION = nil
    end
    self:write_cursor_bridge_state(next_enabled)
    self:set_mouse_mode(next_enabled, true)
end

-- 每帧由 UI 调用（UI 自己的 update 里已处理开关，这里只刷新光标）
function InputBlocker:tick()
    if not self.enabled then return end
    self:update_cursor_position()
end

function InputBlocker:set_mute_game_input(enabled)
    local next_enabled = enabled ~= false
    self.mute_game_input = next_enabled
    if next_enabled and not self.hooks_attempted then
        self:install_game_input_hooks()
    end
end

-- 诊断用：返回一行人类可读的后端描述
function InputBlocker:describe()
    local parts = {}
    table.insert(parts, "mouse=" .. (self.engine_mouse_available and "ok" or "missing"))
    table.insert(parts, "input=" .. tostring(self.backend))
    table.insert(parts, "hooks=" .. tostring(self.hook_count))
    return table.concat(parts, ", ")
end

return InputBlocker
