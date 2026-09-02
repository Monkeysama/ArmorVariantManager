local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local Button = require("ArmorVariantManager_UI.Component.Button")
local Checkbox = require("ArmorVariantManager_UI.Component.Checkbox")
local Panel = require("ArmorVariantManager_UI.Component.Panel")
local List = require("ArmorVariantManager_UI.Component.List")
local Window = require("ArmorVariantManager_UI.Component.Window")
local Slider = require("ArmorVariantManager_UI.Component.Slider")
local Tag = require("ArmorVariantManager_UI.Component.Tag")
local Input = require("ArmorVariantManager_UI.Component.Input")
local InputNumber = require("ArmorVariantManager_UI.Component.InputNumber")
local Select = require("ArmorVariantManager_UI.Component.Select")
local BridgeRuntime = require("ArmorVariantManager_UI.Service.BridgeRuntime")
local InputBlocker = require("ArmorVariantManager_UI.Service.InputBlocker")
local NativeTextInput = require("ArmorVariantManager_UI.Service.NativeTextInput")
local Documentation = require("ArmorVariantManager_Core.Documentation")
local VariantManagerUI = {}
local COLORS = {
    background = 0xE8141820,
    panel = 0xF01F2630,
    panel_alt = 0xF5252E3A,
    border = 0xFF3D4A5C,
    text = 0xFFF1F4F8,
    muted = 0xFF9AA8B8,
    accent = 0xFF55B8C8,
    accent_dark = 0xFF214C5A,
    dragging = 0xFF2E7282,
    dragging_hover = 0xFF3B9EAF,
    disabled = 0xFF687583,
    tag_group_fill = 0xFF254F59,
    tag_group_text = 0xFFA8E1E8,
    tag_global_fill = 0xFF5B4133,
    tag_global_text = 0xFFF0C7A8,
    tag_default_fill = 0xFF315645,
    tag_default_text = 0xFFC3E8D0,
    placeholder = 0xFF718091,
    success = 0xFF75C58A,
    danger = 0xFFE88383
}
local PART_KEYS = {
    [0] = "helm",
    [1] = "body",
    [2] = "arm",
    [3] = "waist",
    [4] = "leg",
    [5] = "slinger"
}
local TRANSFORM_TYPES = {
    { key = "hp", label = "condition_hp", field = "transform_rules" },
    { key = "weapon", label = "condition_weapon", field = "weapon_transform_rules" },
    { key = "damage", label = "condition_damage", field = "damage_transform_rules" },
    { key = "spirit", label = "condition_spirit", field = "spirit_transform_rules" },
    { key = "dual_blades", label = "condition_dual_blades", field = "dual_blades_transform_rules" },
    { key = "switch_axe", label = "condition_switch_axe", field = "switch_axe_transform_rules" },
    { key = "insect_glaive", label = "condition_insect_glaive", field = "insect_glaive_transform_rules" },
    { key = "charge_blade", label = "condition_charge_blade", field = "charge_blade_transform_rules" },
    { key = "greatsword_type", label = "condition_greatsword_type", field = "greatsword_type_transform_rules" },
    { key = "greatsword_level", label = "condition_greatsword_level", field = "greatsword_level_transform_rules" },
    { key = "bow_level", label = "condition_bow_level", field = "bow_level_transform_rules" },
    { key = "hammer_level", label = "condition_hammer_level", field = "hammer_level_transform_rules" }
}
local LAYOUT = {
    content_inset = 18,
    panel_gap = 12,
    panel_inset = 12,
    title_height = 30,
    list_gap = 6,
    part_list_width_min = 150,
    part_list_width_max = 220,
    header_inset = 18,
    header_top = 18,
    content_top = 82,
    footer_height = 48,
    footer_gap = 2,
    header_height = 64,
    header_center = 43,
    header_text_top = 15,
    header_text_gap = 8,
    mode_button_width = 76,
    mode_button_height = 30,
    mode_button_padding = 16,
    mode_button_gap = 8,
    close_button_size = 30,
    settings_language_title = 58,
    settings_language_controls = 96,
    settings_performance_title = 156,
    settings_performance_controls = 190,
    settings_performance_row_gap = 42,
    settings_description_top = 324,
    settings_shortcut_title = 392,
    settings_shortcut_controls = 426,
    preset_actions_height = 190,
    group_actions_height = 190
}
function VariantManagerUI.new(deps)
    local bridge_client_id = deps.bridge_client_id or "ArmorVariantManager"
    local bridge_registered, bridge_paths = BridgeRuntime.register(
        bridge_client_id, deps.bridge_runtime_directory or "ArmorVariantManager/Runtime")
    local self = {
        deps = deps,
        available = d2d ~= nil,
        ready = false,
        visible = false,
        key_down = false,
        waiting_for_key = false,
        waiting_for_key_release = false,
        part_index = 0,
        material_offset = 0,
        material_filter = {},
        material_filter_editing = false,
        material_filter_key = nil,
        group_name_input = "",
        group_name_editing = false,
        group_is_global = false,
        group_creation_mode = false,
        pending_material_selections = {},
        preset_name_input = "",
        preset_name_editing = false,
        preset_name_key = nil,
        caps_lock_active = false,
        caps_lock_down = false,
        input_key_down = {},
        input_repeat_at = {},
        number_inputs = {},
        number_editing = nil,
        frame_mouse_wheel = 0,
        native_text_input = NativeTextInput.new({
            client_id = bridge_client_id,
            runtime_directory = bridge_paths.runtime_directory
        }),
        bridge_client_id = bridge_client_id,
        bridge_runtime_directory = bridge_paths.runtime_directory,
        bridge_registered = bridge_registered,
        fonts = {},
        window_x = nil,
        window_y = nil,
        window_scale = 1,
        resize_edge = nil,
        pending_group = nil,
        pending_group_create = nil,
        pending_group_delete = nil,
        right_panel = "parts",
        expanded_part = 0,
        material_scroll_dragging = false,
        material_scroll_drag_offset = 0,
        transform_scroll_offset = 0,
        transform_max_scroll = 0,
        transform_scroll_dragging = false,
        transform_scroll_drag_offset = 0,
        documentation_scroll_offset = 0,
        documentation_max_scroll = 0,
        documentation_scroll_dragging = false,
        documentation_scroll_drag_offset = 0,
        documentation_layout = nil,
        documentation_section = 2,
        auto_find_status = nil,
        auto_find_succeeded = false,
        last_error = nil,
        d2d = d2d,
        colors = COLORS,
        translate = deps.translate,
        version = deps.version or "",
        author = deps.author or ""
    }
    self.button = Button.new(self.d2d, COLORS, self.fonts)
    self.checkbox = Checkbox.new(self.d2d, COLORS, self.fonts)
    self.panel = Panel.new(self.d2d, COLORS)
    self.list = List.new(self.button, self.d2d, COLORS)
    self.window = Window.new()
    self.tag = Tag.new(self.d2d, COLORS, self.fonts)
    self.input = Input.new(self.d2d, COLORS, self.fonts)
    self.input_number = InputNumber.new(self.d2d, COLORS, self.fonts)
    self.select = Select.new(self.d2d, COLORS, self.fonts)
    self.sliders = {
        scan_interval = Slider.new(self.d2d, COLORS, self.fonts),
        body_id_ttl = Slider.new(self.d2d, COLORS, self.fonts),
        scanner_batch_size = Slider.new(self.d2d, COLORS, self.fonts)
    }
    self.input_blocker = nil
    setmetatable(self, { __index = VariantManagerUI })
    if self.available then
        d2d.register(
            function()
                local ok, err = pcall(function()
                    self.fonts.title = d2d.Font.new("Tahoma", 24, true)
                    self.fonts.body = d2d.Font.new("Tahoma", 18)
                    self.fonts.small = d2d.Font.new("Tahoma", 16)
                    self.fonts.tiny = d2d.Font.new("Tahoma", 13)
                end)
                self.ready = ok and err == nil
            end,
            function()
                if not self.deps.config.new_ui_enabled then return end
                local ok, err = xpcall(function() self:draw() end, function(draw_error)
                    if debug and debug.traceback then
                        return debug.traceback(tostring(draw_error), 2)
                    end
                    return tostring(draw_error)
                end)
                if not ok then
                    self.visible = false
                    self.last_error = err
                else
                    self.last_error = nil
                end
            end
        )
    end
    return self
end
function VariantManagerUI:T(key)
    if self.translate then return self.translate(key) end
    return key
end
function VariantManagerUI:TF(key, ...)
    local value = self:T(key)
    if select("#", ...) == 0 then return value end
    return string.format(value, ...)
end
function VariantManagerUI:search_key_character(key, force_lowercase)
    if type(key) ~= "number" then return nil end
    if key >= 0x41 and key <= 0x5A then
        local shift_ok, shift_down = pcall(function() return reframework:is_key_down(0x10) end)
        local uppercase = (shift_ok and shift_down or false) ~= self.caps_lock_active
        local character = string.char(key + (uppercase and 0 or 32))
        return force_lowercase and string.lower(character) or character
    end
    if key >= 0x30 and key <= 0x39 then return string.char(key) end
    if key >= 0x60 and key <= 0x69 then return string.char(key - 0x60 + 0x30) end
    if key == 0x20 then return " " end
    if key == 0xBD then
        local shift_ok, shift_down = pcall(function() return reframework:is_key_down(0x10) end)
        return shift_ok and shift_down and "_" or "-"
    end
    if key == 0xBE or key == 0x6E then return "." end
    return nil
end
function VariantManagerUI:update_caps_lock_state()
    local ok, down = pcall(function() return reframework:is_key_down(0x14) end)
    down = ok and down or false
    if down and not self.caps_lock_down then
        self.caps_lock_active = not self.caps_lock_active
    end
    self.caps_lock_down = down
end
function VariantManagerUI:get_search_key_down()
    local special_keys = { 0x08, 0x0D, 0x1B, 0x20, 0xBD, 0xBE, 0x6E }
    for _, key in ipairs(special_keys) do
        local ok, down = pcall(function() return reframework:is_key_down(key) end)
        if ok and down then return key end
    end
    for key = 0x41, 0x5A do
        local ok, down = pcall(function() return reframework:is_key_down(key) end)
        if ok and down then return key end
    end
    for key = 0x30, 0x39 do
        local ok, down = pcall(function() return reframework:is_key_down(key) end)
        if ok and down then return key end
    end
    for key = 0x60, 0x69 do
        local ok, down = pcall(function() return reframework:is_key_down(key) end)
        if ok and down then return key end
    end
    return nil
end
function VariantManagerUI:input_key_pressed(key)
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    down = ok and down == true
    local was_down = self.input_key_down[key] == true
    local now = os.clock()
    local repeat_at = self.input_repeat_at[key]
    local pressed = down and (not was_down or (repeat_at and now >= repeat_at))
    if down then
        if pressed then
            self.input_repeat_at[key] = now + (was_down and 0.045 or 0.6)
        end
    else
        self.input_repeat_at[key] = nil
    end
    self.input_key_down[key] = down
    return pressed
end
function VariantManagerUI:update_material_filter_input()
    local filter_key = self.material_filter_editing
    if not filter_key then return end
    if self.native_text_input:is_active("material:" .. filter_key) then return end
    local value = self.material_filter[filter_key] or ""
    if self:input_key_pressed(0x08) then
        value = string.sub(value, 1, math.max(0, #value - 1))
    else
        local key = self:get_search_key_down()
        if key and self:input_key_pressed(key) then
            local character = self:search_key_character(key, false)
            if character then value = value .. character end
        end
    end
    self.material_filter[filter_key] = value
end
function VariantManagerUI:update_preset_name_input()
    if not self.preset_name_editing then return end
    if self.native_text_input:is_active("preset_name") then return end
    local value = self.preset_name_input or ""
    if self:input_key_pressed(0x08) then
        value = string.sub(value, 1, math.max(0, #value - 1))
    else
        local key = self:get_search_key_down()
        if key and self:input_key_pressed(key) then
            local character = self:search_key_character(key, false)
            if character then value = value .. character end
        end
    end
    self.preset_name_input = value
end
function VariantManagerUI:reset_text_input_state()
    self.input_key_down = {}
    self.input_repeat_at = {}
end
function VariantManagerUI:update_native_text_input()
    local input_id, text, _, focused = self.native_text_input:update()
    if not input_id then return end
    if input_id == "preset_name" then
        self.preset_name_input = text
    elseif input_id == "group_name" then
        self.group_name_input = text
    elseif string.sub(input_id, 1, 9) == "material:" then
        self.material_filter[string.sub(input_id, 10)] = text
    end
    if focused == false then
        if input_id == "preset_name" then self.preset_name_editing = false end
        if input_id == "group_name" then self.group_name_editing = false end
        if string.sub(input_id, 1, 9) == "material:" then
            self.material_filter_editing = false
        end
        self:reset_text_input_state()
        self:deactivate_native_text_input(input_id)
    end
end
function VariantManagerUI:activate_native_text_input(input_id, text, rect, reset)
    self.native_text_input:activate(input_id, text, rect, reset)
end
function VariantManagerUI:sync_native_text_input(input_id, rect)
    self.native_text_input:sync_rect(input_id, rect)
end
function VariantManagerUI:deactivate_native_text_input(input_id)
    self.native_text_input:deactivate(input_id)
end
function VariantManagerUI:focus_native_text_input(input_id, text, rect, force_focus)
    if force_focus or not self.native_text_input:is_active(input_id) then
        self:activate_native_text_input(input_id, text, rect, true)
    else
        self:sync_native_text_input(input_id, rect)
    end
end
function VariantManagerUI:clear_released_input_keys()
    for key, down in pairs(self.input_key_down) do
        if down then
            local ok, still_down = pcall(function() return reframework:is_key_down(key) end)
            if not ok or not still_down then
                self.input_key_down[key] = false
                self.input_repeat_at[key] = nil
            end
        end
    end
end
function VariantManagerUI:update_group_name_input()
    if not self.group_name_editing then return end
    if self.native_text_input:is_active("group_name") then return end
    local value = self.group_name_input or ""
    if self:input_key_pressed(0x08) then
        value = string.sub(value, 1, math.max(0, #value - 1))
    else
        local key = self:get_search_key_down()
        if key and self:input_key_pressed(key) then
            local character = self:search_key_character(key, false)
            if character then value = value .. character end
        end
    end
    self.group_name_input = value
end
function VariantManagerUI:update_number_input()
    local field_key = self.number_editing
    if not field_key then return end
    local value = self.number_inputs[field_key] or ""
    if self:input_key_pressed(0x08) then
        value = string.sub(value, 1, math.max(0, #value - 1))
    else
        local key = self:get_search_key_down()
        if key and self:input_key_pressed(key) then
            local character = self:number_key_character(key)
            if character then value = value .. character end
        end
    end
    self.number_inputs[field_key] = value
end
function VariantManagerUI:draw_number_input(field_key, value, x, y, w, h, minimum, maximum, step)
    local text_value = self.number_inputs[field_key]
    if text_value == nil or not self.number_editing then text_value = tostring(value or minimum or 0) end
    self.number_inputs[field_key] = text_value
    local focused = self.number_editing == field_key
    local input_action = self.input:draw(text_value, "", x, y, w, h, focused, false)
    if input_action.focused or input_action.hovered and Runtime.is_mouse_down() then
        self.number_editing = field_key
        self.material_filter_editing = false
        self.preset_name_editing = false
        self.group_name_editing = false
        self:reset_text_input_state()
        self:deactivate_native_text_input()
    elseif Runtime.is_mouse_clicked() and not input_action.hovered and focused then
        self.number_editing = nil
        self.number_inputs[field_key] = tostring(value or minimum or 0)
        self:reset_text_input_state()
    end
    if input_action.clear then
        self.number_inputs[field_key] = ""
        self.number_editing = field_key
    end
    local numeric = tonumber(self.number_inputs[field_key])
    if numeric == nil then return false, value end
    numeric = math.max(minimum, math.min(maximum, numeric))
    local current = tonumber(value) or minimum
    local changed = math.abs(numeric - current) >= (step or 0)
    return changed, numeric
end
function VariantManagerUI:draw_group_actions(x, y, w, h, context)
    local inner_x = x + LAYOUT.panel_inset
    local inner_w = w - LAYOUT.panel_inset * 2
    if not self.group_creation_mode then
        local button_y = y + h - LAYOUT.panel_inset - 64
        if self.button:draw(self:T("start_selection"), inner_x, button_y,
            inner_w, 28, false, nil, self.fonts.tiny) then
            self.group_creation_mode = true
            self.group_name_input = ""
            self.group_name_editing = false
            self.group_is_global = false
            self.pending_material_selections = {}
            self.material_filter_editing = false
            self.preset_name_editing = false
            self:reset_text_input_state()
            self:deactivate_native_text_input()
        end
        local delete_disabled = not context.group_name or context.group_name == ""
        if self.button:draw(self:T("delete_group"), inner_x, button_y + 36,
            inner_w, 28, false, nil, self.fonts.tiny, delete_disabled) then
            self.pending_group_delete = context.group_name
        end
        return
    end
    local action_y = y + h - LAYOUT.panel_inset - 28
    local global_y = action_y - 34 - 26
    local input_y = global_y - 42
    local title_y = input_y - 34
    Runtime.text(self.d2d, self.fonts.small, self:T("selection_mode"),
        inner_x, title_y, COLORS.accent)
    local input_action = self.input:draw(self.group_name_input,
        self:T("d2d_group_name_hint"), inner_x, input_y, inner_w, 28, self.group_name_editing,
        true, self.native_text_input:get_composition("group_name"),
        self.native_text_input:get_caret("group_name"))
    if input_action.focused or input_action.hovered and Runtime.is_mouse_down() then
        self.group_name_editing = true
        self.group_is_global = self.group_is_global == true
        self.material_filter_editing = false
        self.preset_name_editing = false
        self.number_editing = nil
        self:reset_text_input_state()
        self:focus_native_text_input("group_name", self.group_name_input, input_action.rect,
            input_action.focused)
    elseif Runtime.is_mouse_clicked() and not input_action.hovered and self.group_name_editing then
        self.group_name_editing = false
        self:reset_text_input_state()
        self:deactivate_native_text_input("group_name")
    end
    if self.group_name_editing then self:sync_native_text_input("group_name", input_action.rect) end
    if input_action.clear then
        self.group_name_input = ""
        self.group_name_editing = false
        self:reset_text_input_state()
        self:deactivate_native_text_input("group_name")
    end
    if self.checkbox:draw(self:T("is_global_group"), inner_x, global_y,
        inner_w, 26, self.group_is_global) then
        self.group_is_global = not self.group_is_global
    end
    local action_gap = 6
    local action_w = (inner_w - action_gap) / 2
    if self.button:draw(self:T("confirm_creation"), inner_x, action_y,
        action_w, 28, false, nil, self.fonts.tiny) then
        if self.group_name_input ~= "" and self.deps.create_group then
            self.pending_group_create = {
                name = self.group_name_input,
                is_global = self.group_is_global,
                selections = self.pending_material_selections
            }
        end
    end
    if self.button:draw(self:T("cancel"), inner_x + action_w + action_gap, action_y,
        action_w, 28, false, nil, self.fonts.tiny) then
        self.group_creation_mode = false
        self.group_name_input = ""
        self.group_name_editing = false
        self.group_is_global = false
        self.pending_material_selections = {}
        self:reset_text_input_state()
        self:deactivate_native_text_input("group_name")
    end
end
function VariantManagerUI:key_name(key)
    if not key then return self:T("d2d_unbound") end
    local names = {
        [0x08] = "Backspace", [0x09] = "Tab", [0x0C] = "Clear", [0x0D] = "Enter",
        [0x10] = "Shift", [0x11] = "Ctrl", [0x12] = "Alt", [0x13] = "Pause",
        [0x14] = "Caps Lock", [0x1B] = "Esc", [0x20] = "Space",
        [0x21] = "Page Up", [0x22] = "Page Down", [0x23] = "End", [0x24] = "Home",
        [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down",
        [0x2C] = "Print Screen", [0x2D] = "Insert", [0x2E] = "Delete",
        [0x5B] = "Left Win", [0x5C] = "Right Win", [0x5D] = "Menu",
        [0x6A] = "Num *", [0x6B] = "Num +", [0x6C] = "Num Separator",
        [0x6D] = "Num -", [0x6E] = "Num .", [0x6F] = "Num /",
        [0x90] = "Num Lock", [0x91] = "Scroll Lock",
        [0xA0] = "Left Shift", [0xA1] = "Right Shift",
        [0xA2] = "Left Ctrl", [0xA3] = "Right Ctrl",
        [0xA4] = "Left Alt", [0xA5] = "Right Alt",
        [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-",
        [0xBE] = ".", [0xBF] = "/", [0xC0] = "`", [0xDB] = "[",
        [0xDC] = "\\", [0xDD] = "]", [0xDE] = "'"
    }
    if key >= 0x41 and key <= 0x5A then return string.char(key) end
    if key >= 0x30 and key <= 0x39 then return string.char(key) end
    if key >= 0x60 and key <= 0x69 then return "Num " .. tostring(key - 0x60) end
    if key >= 0x70 and key <= 0x87 then return "F" .. tostring(key - 0x6F) end
    return names[key] or string.format("0x%02X", key)
end
function VariantManagerUI:begin_key_binding()
    self.waiting_for_key = true
    self.waiting_for_key_release = false
end
function VariantManagerUI:is_bindable_key(key)
    return type(key) == "number" and not (key >= 0x01 and key <= 0x06)
end
function VariantManagerUI:update()
    local config = self.deps.config
    if not config.new_ui_enabled then
        self:deactivate_native_text_input()
        if self.input_blocker and self.input_blocker.enabled then
            self.input_blocker:set_enabled(false)
        end
        self.key_down = false
        self.frame_mouse_wheel = 0
        return
    end
    local update_ok, update_error = xpcall(function()
        if self.pending_group_create then
            local request = self.pending_group_create
            self.pending_group_create = nil
            local create_ok, created = pcall(function()
                return self.deps.create_group and self.deps.create_group(
                    request.name, request.is_global, request.selections)
            end)
            if create_ok and created then
                self.group_creation_mode = false
                self.group_name_input = ""
                self.group_name_editing = false
                self.group_is_global = false
                self.pending_material_selections = {}
                self:reset_text_input_state()
                self:deactivate_native_text_input("group_name")
            elseif not create_ok then
                self.last_error = tostring(created)
            end
        end
        if self.pending_group_delete then
            local group_name = self.pending_group_delete
            self.pending_group_delete = nil
            local delete_ok, deleted = pcall(function()
                return self.deps.delete_group and self.deps.delete_group(group_name)
            end)
            if not delete_ok then self.last_error = tostring(deleted) end
        end
        if self.pending_group ~= nil then
            local group_name = self.pending_group
            self.pending_group = nil
            local select_ok, select_err = pcall(function()
                self.deps.select_group(group_name)
            end)
            if not select_ok then self.last_error = tostring(select_err) end
        end
        local key_ok, down = pcall(function()
            return not self.waiting_for_key and not self.material_filter_editing and not self.preset_name_editing
                and config.new_ui_enabled and config.new_ui_key
                and reframework:is_key_down(config.new_ui_key)
        end)
        down = key_ok and down or false
        if self.waiting_for_key then
            if not self.waiting_for_key_release then
                local mouse_ok, mouse_down = pcall(function() return imgui.is_mouse_down(0) end)
                if not mouse_ok or not mouse_down then self.waiting_for_key_release = true end
                return
            end
            local bind_ok, bind_key = pcall(function() return reframework:get_first_key_down() end)
            if bind_ok and self:is_bindable_key(bind_key) then
                config.new_ui_key = bind_key
                self.waiting_for_key = false
                self.waiting_for_key_release = false
                self.key_down = true
                self.deps.save_settings()
                return
            end
        end
        self:update_caps_lock_state()
        self:update_native_text_input()
        self:update_material_filter_input()
        self:update_preset_name_input()
        self:update_group_name_input()
        self:update_number_input()
        self:clear_released_input_keys()
        if down and not self.key_down and self.available then
            self.visible = not self.visible
        end
        self.key_down = down
        if not self.visible then self:deactivate_native_text_input() end
        if self.visible and not self.input_blocker then
            self.input_blocker = InputBlocker.new({
                client_id = self.bridge_client_id,
                runtime_directory = self.bridge_runtime_directory
            })
        end
        if self.input_blocker then
            local should_block = self.visible
            if self.input_blocker.enabled ~= should_block then
                self.input_blocker:set_enabled(should_block)
            end
        end
        if self.visible and self.input_blocker then
            local wheel_ok, wheel = pcall(function() return self.input_blocker:get_mouse_wheel() end)
            self.frame_mouse_wheel = wheel_ok and type(wheel) == "number" and wheel or 0
        else
            self.frame_mouse_wheel = 0
        end
    end, function(update_error_value)
        return tostring(update_error_value)
    end)
    if not update_ok then
        self.last_error = update_error
    end
end
function VariantManagerUI:draw_settings()
    local config = self.deps.config
    local changed, value = imgui.checkbox(self:T("d2d_use_new_ui"), config.new_ui_enabled)
    if changed then
        config.new_ui_enabled = value
        if not value then
            self.visible = false
            self.waiting_for_key = false
            self.waiting_for_key_release = false
        end
        self.deps.save_settings()
    end
    if not config.new_ui_enabled then
        imgui.separator()
        return false
    end
    imgui.same_line()
    if self.waiting_for_key then
        imgui.text_colored(self:T("d2d_press_key"), 0xFF00FFFF)
    else
        if imgui.button(self:T("d2d_bind_key") .. "##new_ui_key") then self:begin_key_binding() end
        imgui.same_line()
        imgui.text_colored(self:T("d2d_current_key") .. self:key_name(config.new_ui_key), 0xFF80C0FF)
    end
    if not self.available then
        imgui.text_colored(self:T("d2d_not_loaded"), 0xFFFF8080)
        imgui.separator()
        return false
    end
    imgui.text_colored(self:T("d2d_enabled_hint"), 0xFF80C080)
    return true
end
local function get_group_presets(context)
    local config = context and context.config or {}
    local group_name = context and context.group_name or ""
    local target_presets = config.presets or {}
    local target_order = config.preset_order
    if group_name ~= "" then
        local group_data = config.groups and config.groups[group_name]
        target_presets = group_data and group_data.presets or {}
        target_order = group_data and group_data.preset_order
    end
    if type(target_presets) ~= "table" then return {} end
    local presets = {}
    local added = {}
    if type(target_order) == "table" and #target_order > 0 then
        for _, name in ipairs(target_order) do
            if target_presets[name] then
                table.insert(presets, name)
                added[name] = true
            end
        end
        local missing = {}
        for name, _ in pairs(target_presets) do
            if not added[name] then table.insert(missing, name) end
        end
        table.sort(missing)
        for _, name in ipairs(missing) do table.insert(presets, name) end
    else
        for name, _ in pairs(target_presets) do table.insert(presets, name) end
        table.sort(presets)
    end
    return presets
end
local function get_default_preset_name(context)
    if context.group_name == "" then return context.config and context.config.default_preset or "" end
    local group = context.config and context.config.groups and context.config.groups[context.group_name]
    return group and group.default_preset or ""
end
function VariantManagerUI:draw_preset_actions(x, y, w, h, context, presets)
    local action_top = y + h - LAYOUT.preset_actions_height + LAYOUT.panel_inset
    local input_y = action_top + 32
    local save_width = 58
    local input_width = math.max(80, w - LAYOUT.panel_inset * 2 - save_width - 6)
    Runtime.text(self.d2d, self.fonts.small, self:T("create_new_preset"),
        x + LAYOUT.panel_inset, action_top, COLORS.muted)
    local input_action = self.input:draw(self.preset_name_input, self:T("d2d_preset_name_hint"),
        x + LAYOUT.panel_inset, input_y, input_width, 28, self.preset_name_editing,
        true, self.native_text_input:get_composition("preset_name"),
        self.native_text_input:get_caret("preset_name"))
    if input_action.focused or input_action.hovered and Runtime.is_mouse_down() then
        self.preset_name_editing = true
        self.preset_name_key = nil
        self:reset_text_input_state()
        self.material_filter_editing = false
        self.group_name_editing = false
        self.number_editing = nil
        self:focus_native_text_input("preset_name", self.preset_name_input, input_action.rect,
            input_action.focused)
    elseif Runtime.is_mouse_clicked() and not input_action.hovered and self.preset_name_editing then
        self.preset_name_editing = false
        self.preset_name_key = nil
        self:reset_text_input_state()
        self:deactivate_native_text_input("preset_name")
    end
    if self.preset_name_editing then self:sync_native_text_input("preset_name", input_action.rect) end
    if input_action.clear then
        self.preset_name_input = ""
        self.preset_name_editing = false
        self.preset_name_key = nil
        self:reset_text_input_state()
        self:deactivate_native_text_input("preset_name")
    end
    if self.button:draw(self:T("save"), x + LAYOUT.panel_inset + input_width + 6,
        input_y, save_width, 28, false) then
        if self.preset_name_input ~= "" and self.deps.create_preset
            and self.deps.create_preset(self.preset_name_input) then
            self.preset_name_input = ""
            self.preset_name_editing = false
            self:deactivate_native_text_input("preset_name")
        end
    end
    local selected_name = context.selected_preset_name or presets[context.selected_preset_index]
    Runtime.text(self.d2d, self.fonts.small,
        self:TF("d2d_selected_preset", selected_name or self:T("d2d_none")),
        x + LAYOUT.panel_inset, input_y + 42, COLORS.muted)
    local button_y = input_y + 70
    if selected_name then
        local inner_width = w - LAYOUT.panel_inset * 2
        local button_gap = 6
        local auto_default = self.deps.config.auto_set_selected_preset_as_default == true
        local half_width = (inner_width - button_gap) / 2
        local default_width = half_width
        if self.button:draw(self:T("set_as_default"), x + LAYOUT.panel_inset,
            button_y, default_width, 28, false, nil, self.fonts.tiny, auto_default) then
            if self.deps.set_default_preset then self.deps.set_default_preset(selected_name) end
        end
        if self.checkbox:draw(self:T("d2d_auto_save_default"),
            x + LAYOUT.panel_inset + default_width + button_gap, button_y,
            inner_width - default_width - button_gap, 28, auto_default) then
            if self.deps.set_auto_default_enabled then
                self.deps.set_auto_default_enabled(not auto_default, selected_name, context.body_id)
            end
        end
        if self.button:draw(self:T("overwrite_preset"), x + LAYOUT.panel_inset,
            button_y + 40, half_width, 28, false, nil, self.fonts.tiny) then
            if self.deps.overwrite_preset then self.deps.overwrite_preset(selected_name) end
        end
        if self.button:draw(self:T("delete_preset"), x + LAYOUT.panel_inset + half_width + button_gap,
            button_y + 40, half_width, 28, false, nil, self.fonts.tiny) then
            if self.deps.delete_preset then self.deps.delete_preset(selected_name) end
        end
    end
end
function VariantManagerUI:draw_library(x, y, w, h, context, preset_w)
    self.panel:draw(x, y, w, h)
    Runtime.text(self.d2d, self.fonts.small, self:T("group"),
        x + LAYOUT.panel_inset, y + LAYOUT.panel_inset, COLORS.muted)
    local groups = { { name = "", label = self:T("main_list"), is_global = false } }
    for _, group_name in ipairs(context.group_names or {}) do
        local group_data = context.config and context.config.groups and context.config.groups[group_name]
        table.insert(groups, {
            name = group_name,
            label = (group_data and group_data.is_global and self:T("global_group_label") .. " " or "") .. group_name,
            is_global = group_data and group_data.is_global == true
        })
    end
    self.list:draw(groups, x + LAYOUT.panel_inset, y, w - LAYOUT.panel_inset * 2, h, {
        top_padding = LAYOUT.panel_inset + LAYOUT.title_height,
        bottom_padding = LAYOUT.group_actions_height,
        row_gap = LAYOUT.list_gap,
        label = function(item) return item.label end,
        selected = function(item) return context.group_name == item.name end,
        on_click = function(item)
            if self.group_creation_mode then
                self.group_creation_mode = false
                self.group_name_input = ""
                self.group_is_global = false
                self.pending_material_selections = {}
                self:reset_text_input_state()
            end
            self.pending_group = item.name
        end,
        draggable = function(item) return item.name ~= "" and not item.is_global end,
        reorderable_only = true,
        on_reorder = function(items)
            if self.deps.reorder_groups then self.deps.reorder_groups(items) end
        end
    })
    self:draw_group_actions(x, y, w, h, context)
    local preset_x = x + w + LAYOUT.panel_gap
    preset_w = preset_w or w
    self.panel:draw(preset_x, y, preset_w, h)
    local preset_group_name = context.group_name == "" and self:T("main_list") or context.group_name
    Runtime.text(self.d2d, self.fonts.small,
        self:TF("d2d_preset_list", preset_group_name),
        preset_x + LAYOUT.panel_inset, y + LAYOUT.panel_inset, COLORS.muted)
    local presets = get_group_presets(context)
    local default_preset = get_default_preset_name(context)
    local selected_preset_name = context.selected_preset_name or presets[context.selected_preset_index]
    local show_restore_warning = context.config_restored == true
    local warning_text = self:T("config_restored_warning")
    local warning_w = preset_w - LAYOUT.panel_inset * 2
    local warning_line_height = 16
    if self.fonts.tiny then
        local _, measured_height = self.fonts.tiny:measure("Ag")
        warning_line_height = math.max(warning_line_height, math.ceil(measured_height + 2))
    end
    local warning_lines = show_restore_warning
        and Runtime.wrap_text(self.fonts.tiny, warning_text, warning_w) or {}
    local warning_height = show_restore_warning and (#warning_lines * warning_line_height + 50) or 0
    if show_restore_warning then
        local warning_x = preset_x + LAYOUT.panel_inset
        local warning_y = y + LAYOUT.panel_inset + LAYOUT.title_height
        for line_index, line in ipairs(warning_lines) do
            Runtime.text(self.d2d, self.fonts.tiny, line,
                warning_x, warning_y + (line_index - 1) * warning_line_height, COLORS.accent)
        end
        local restore_w = math.max(84, math.floor((warning_w - 6) * 0.64))
        local warning_button_y = warning_y + #warning_lines * warning_line_height + 12
        if self.button:draw(self:T("restore_from_backup"), warning_x, warning_button_y,
            restore_w, 26, false, nil, self.fonts.tiny) then
            if self.deps.restore_backup then self.deps.restore_backup(context.body_id) end
        end
        if self.button:draw(self:T("dismiss"), warning_x + restore_w + 6, warning_button_y,
            warning_w - restore_w - 6, 26, false, nil, self.fonts.tiny) then
            if self.deps.dismiss_backup then self.deps.dismiss_backup(context.body_id) end
        end
    end
    self.list:draw(presets, preset_x + LAYOUT.panel_inset, y, preset_w - LAYOUT.panel_inset * 2, h, {
        top_padding = LAYOUT.panel_inset + LAYOUT.title_height + warning_height,
        bottom_padding = LAYOUT.preset_actions_height,
        row_gap = LAYOUT.list_gap,
        label = function(item) return item end,
        selected = function(item) return item == selected_preset_name end,
        on_click = function(item, index)
            self.deps.select_preset(index)
            self.deps.apply_preset(item)
            if self.deps.auto_set_default_preset then
                self.deps.auto_set_default_preset(item, context.body_id)
            end
        end,
        draggable = function() return true end,
        on_reorder = function(items)
            if self.deps.reorder_presets then self.deps.reorder_presets(items) end
        end,
        draw_after = function(item, _, row_x, row_y, row_w, _, right_x)
            if item == default_preset then
                local tag_label = self:T("d2d_default_tag")
                local tag_width = self.tag:measure(tag_label)
                self.tag:draw(tag_label, right_x - tag_width, row_y, right_x, "default")
            end
        end
    })
    if #presets == 0 then
        local no_preset_key = context.weapon_mode and "no_weapon_presets" or "no_presets"
        Runtime.text(self.d2d, self.fonts.small, self:T(no_preset_key),
            preset_x + LAYOUT.panel_inset, y + 65 + warning_height, COLORS.muted)
    end
    local has_any_presets = self.deps.has_any_presets
        and self.deps.has_any_presets(context.config) or #presets > 0
    if not has_any_presets and context.body_id then
        local action_x = preset_x + LAYOUT.panel_inset
        local action_y = y + 94 + warning_height
        local action_w = preset_w - LAYOUT.panel_inset * 2
        if self.button:draw(self:T("auto_find_preset"), action_x, action_y,
            action_w, 28, false, nil, self.fonts.tiny) then
            local found, message = false, nil
            if self.deps.auto_find_preset then found, message = self.deps.auto_find_preset(context.body_id) end
            self.auto_find_succeeded = found == true
            if found then
                self.auto_find_status = self:T("auto_find_success")
            elseif message == "No matching preset found" then
                self.auto_find_status = self:T("auto_find_fail")
            else
                self.auto_find_status = message and tostring(message) or self:T("auto_find_fail")
            end
        end
        if self.auto_find_status then
            Runtime.text(self.d2d, self.fonts.tiny, self.auto_find_status,
                action_x, action_y + 34, self.auto_find_succeeded and COLORS.success or COLORS.danger)
        end
    end
    self:draw_preset_actions(preset_x, y, preset_w, h, context, presets)
    return preset_x + preset_w
end
function VariantManagerUI:draw_part_content(x, y, w, h, context, part_index)
    local meshes = self.deps.get_meshes(context.character, context.body_id, part_index)
    if not meshes or #meshes == 0 then
        Runtime.text(self.d2d, self.fonts.tiny, self:T("d2d_no_part_mesh"),
            x + LAYOUT.panel_inset, y + 8, COLORS.muted)
        return
    end
    local view = self.deps.get_mesh_view(meshes, context.body_id, part_index) or { materials = {} }
    local override = self.deps.get_override(context.body_id, part_index)
    local mesh_enabled = view.mesh_enabled ~= false
    if override and override.mesh_enabled ~= nil then mesh_enabled = override.mesh_enabled end
    if self.group_creation_mode then
        Runtime.text(self.d2d, self.fonts.small, self:T("selection_mode"),
            x + LAYOUT.panel_inset, y, COLORS.accent)
    elseif self.checkbox:draw(self:T("enable_mesh"), x + LAYOUT.panel_inset, y,
        w - LAYOUT.panel_inset * 2, 28, mesh_enabled) then
        self.deps.set_mesh_enabled(context.body_id, part_index, meshes, not mesh_enabled)
    end
    local filter_key = tostring(context.body_id or "") .. ":" .. tostring(part_index) .. ":" ..
        tostring(context.group_name or "")
    local filter_value = self.material_filter[filter_key] or ""
    local filter_lower = string.lower(filter_value)
    local materials = {}
    for _, material in ipairs(view.materials or {}) do
        if material.name then
            local metadata = self.deps.get_material_occupancy
                and self.deps.get_material_occupancy(part_index, material.name) or {}
            local visible = self.group_creation_mode
                or metadata.in_context == true or context.group_name == ""
            local matches_filter = filter_lower == "" or string.find(string.lower(material.name), filter_lower, 1, true)
            if visible and matches_filter then
                material.owner = metadata.owner
                material.global_groups = metadata.global_groups or {}
                material.operable = self.group_creation_mode
                    and (self.group_is_global or not metadata.owner)
                    or (not self.group_creation_mode and metadata.in_context == true)
                table.insert(materials, material)
            end
        end
    end
    local count = #materials
    Runtime.text(self.d2d, self.fonts.tiny, self:TF("d2d_material_count", count),
        x + LAYOUT.panel_inset, y + 34, COLORS.muted)
    local function material_enabled(material)
        if self.group_creation_mode then
            local selected = self.pending_material_selections[tostring(part_index)]
                and self.pending_material_selections[tostring(part_index)][material.name]
            return selected == true
        end
        local intent = override and override.materials and override.materials[material.name]
        return intent ~= nil and intent or material.enabled ~= false
    end
    local controls_y = y + 62
    local action_width = 46
    if self.button:draw(self:T("select_all"), x + LAYOUT.panel_inset, controls_y,
        action_width, 28, false) then
        local all_enabled = true
        for _, material in ipairs(materials) do
            if material.operable and not material_enabled(material) then all_enabled = false; break end
        end
        local target_enabled = not all_enabled
        for _, material in ipairs(materials) do
            if material.operable then
                if self.group_creation_mode then
                    local key = tostring(part_index)
                    if not self.pending_material_selections[key] then
                        self.pending_material_selections[key] = {}
                    end
                    self.pending_material_selections[key][material.name] = target_enabled or nil
                else
                    self.deps.set_material_enabled(context.body_id, part_index, meshes,
                        material.name, target_enabled)
                end
            end
        end
    end
    if self.button:draw(self:T("invert_select"), x + LAYOUT.panel_inset + action_width + 6,
        controls_y, action_width, 28, false) then
        for _, material in ipairs(materials) do
            if material.operable then
                if self.group_creation_mode then
                    local key = tostring(part_index)
                    if not self.pending_material_selections[key] then
                        self.pending_material_selections[key] = {}
                    end
                    self.pending_material_selections[key][material.name] = not material_enabled(material) or nil
                else
                    self.deps.set_material_enabled(context.body_id, part_index, meshes,
                        material.name, not material_enabled(material))
                end
            end
        end
    end
    local search_x = x + LAYOUT.panel_inset + action_width * 2 + 18
    local search_w = math.max(90, w - LAYOUT.panel_inset - (search_x - x) - LAYOUT.panel_inset)
    local search_focused = self.material_filter_editing == filter_key
    local input_action = self.input:draw(filter_value, self:T("d2d_material_search_hint"),
        search_x, controls_y, search_w, 28, search_focused, true,
        self.native_text_input:get_composition("material:" .. filter_key),
        self.native_text_input:get_caret("material:" .. filter_key))
    if input_action.focused or input_action.hovered and Runtime.is_mouse_down() then
        self.material_filter_editing = filter_key
        self.material_filter_key = nil
        self:reset_text_input_state()
        self.preset_name_editing = false
        self.group_name_editing = false
        self.number_editing = nil
        self:focus_native_text_input("material:" .. filter_key, filter_value, input_action.rect,
            input_action.focused)
    end
    if self.material_filter_editing == filter_key then
        self:sync_native_text_input("material:" .. filter_key, input_action.rect)
    end
    if input_action.clear then
        self.material_filter[filter_key] = ""
        self.material_filter_editing = false
        self.material_filter_key = nil
        self:reset_text_input_state()
        self:deactivate_native_text_input("material:" .. filter_key)
    elseif Runtime.is_mouse_clicked() and not input_action.hovered
        and self.material_filter_editing == filter_key then
        self.material_filter_editing = false
        self.material_filter_key = nil
        self:reset_text_input_state()
        self:deactivate_native_text_input("material:" .. filter_key)
    end
    if count == 0 then return end
    local viewport_y = y + 98
    local viewport_h = math.max(30, h - 98)
    local max_rows = math.max(1, math.floor(viewport_h / 30))
    local max_offset = math.max(0, count - max_rows)
    self.material_offset = math.max(0, math.min(self.material_offset, max_offset))
    local mx, my = Runtime.mouse_position()
    local viewport_w = w - LAYOUT.panel_inset * 2
    if count > max_rows then
        if Runtime.point_in_rect(mx, my, x, viewport_y, viewport_w, viewport_h) then
            local wheel = self.frame_mouse_wheel
            if wheel ~= 0 then
                self.material_offset = math.max(0, math.min(max_offset,
                    self.material_offset - math.floor(wheel * 3)))
            end
        end
    end
    local row_y = viewport_y
    local end_index = math.min(count, self.material_offset + max_rows)
    for i = self.material_offset + 1, end_index do
        local material = materials[i]
        local enabled = material_enabled(material)
        local disabled = not material.operable
        local material_color = disabled and COLORS.disabled or nil
        if self.checkbox:draw(material.name, x + LAYOUT.panel_inset, row_y,
            viewport_w, 26, enabled, disabled, material_color) then
            if self.group_creation_mode then
                local key = tostring(part_index)
                if not self.pending_material_selections[key] then
                    self.pending_material_selections[key] = {}
                end
                self.pending_material_selections[key][material.name] = not enabled or nil
            else
                self.deps.set_material_enabled(context.body_id, part_index, meshes,
                    material.name, not enabled)
            end
        end
        local box_size = 18
        local text_x = x + LAYOUT.panel_inset + 4 + box_size + 9
        local text_width = self.fonts.body:measure(material.name)
        local tag_x = text_x + text_width + 8
        local tag_limit = x + w - LAYOUT.panel_inset - 12
        if material.owner then
            tag_x = self.tag:draw(material.owner, tag_x, row_y, tag_limit, "group")
        end
        for _, group_name in ipairs(material.global_groups or {}) do
            tag_x = self.tag:draw(group_name, tag_x, row_y, tag_limit, "global")
        end
        row_y = row_y + 30
    end
    if count > max_rows then
        local track_x = x + w - LAYOUT.panel_inset
        local track_y = viewport_y
        local track_w = 8
        local track_h = viewport_h
        local thumb_h = math.max(24, track_h * max_rows / count)
        local thumb_range = math.max(0, track_h - thumb_h)
        local thumb_y = track_y
        if max_offset > 0 then
            thumb_y = track_y + thumb_range * self.material_offset / max_offset
        end
        self.d2d.fill_rounded_rect(track_x, track_y, track_w, track_h, 3, 3, COLORS.panel_alt)
        local thumb_hovered = Runtime.point_in_rect(mx, my, track_x - 5, thumb_y, track_w + 10, thumb_h)
        self.d2d.fill_rounded_rect(track_x, thumb_y, track_w, thumb_h, 3, 3,
            thumb_hovered or self.material_scroll_dragging and COLORS.accent or COLORS.border)
        local track_hovered = Runtime.point_in_rect(mx, my, track_x - 5, track_y, track_w + 10, track_h)
        if Runtime.is_mouse_clicked() and track_hovered then
            self.material_scroll_dragging = true
            if thumb_hovered then
                self.material_scroll_drag_offset = my - thumb_y
            else
                self.material_scroll_drag_offset = thumb_h / 2
                local next_thumb_y = math.max(track_y, math.min(track_y + thumb_range,
                    my - self.material_scroll_drag_offset))
                self.material_offset = math.floor((next_thumb_y - track_y) / thumb_range * max_offset + 0.5)
            end
        end
        if not Runtime.is_mouse_down() then self.material_scroll_dragging = false end
        if self.material_scroll_dragging and Runtime.is_mouse_down() and thumb_range > 0 then
            local next_thumb_y = math.max(track_y, math.min(track_y + thumb_range,
                my - self.material_scroll_drag_offset))
            self.material_offset = math.floor((next_thumb_y - track_y) / thumb_range * max_offset + 0.5)
        end
    else
        self.material_scroll_dragging = false
    end
end
function VariantManagerUI:number_key_character(key)
    if type(key) ~= "number" then return nil end
    if key >= 0x30 and key <= 0x39 then return string.char(key) end
    if key >= 0x60 and key <= 0x69 then return string.char(key - 0x60 + 0x30) end
    if key == 0xBE or key == 0x6E then return "." end
    if key == 0xBD then return "-" end
    return nil
end
function VariantManagerUI:transform_type_label(type_key)
    for _, definition in ipairs(TRANSFORM_TYPES) do
        if definition.key == type_key then return self:T(definition.label) end
    end
    return tostring(type_key or "")
end
function VariantManagerUI:format_transform_state(type_key, state)
    if state == nil then return self:T("d2d_state_unavailable") end
    if type_key == "hp" then return string.format("%.1f%%", tonumber(state) or 0) end
    if type_key == "damage" then
        if type(state) == "number" and state > 0 then return self:TF("damage_countdown", state) end
        return self:T("d2d_damage_idle_state")
    end
    if type_key == "weapon" then
        return state == true and self:T("weapon_drawn") or self:T("weapon_sheathed")
    end
    if type_key == "spirit" and tonumber(state) and tonumber(state) >= 1 and tonumber(state) <= 4 then
        return self:T("spirit_level_" .. tostring(state))
    end
    local state_keys = {
        dual_blades = { normal = "dual_normal", kijin = "dual_kijin", enhancement = "dual_enhancement" },
        switch_axe = { sword_normal = "switch_axe_sword_normal", sword_awakened = "switch_axe_sword_awakened", axe_normal = "switch_axe_axe_normal", axe_enhanced = "switch_axe_axe_enhanced" },
        insect_glaive = { none = "insect_glaive_none", white = "insect_glaive_white", orange = "insect_glaive_orange", red = "insect_glaive_red", triple = "insect_glaive_triple" },
        charge_blade = { sword = "charge_blade_sword", axe = "charge_blade_axe", sword_shield = "charge_blade_sword_shield", sword_sword = "charge_blade_sword_sword", sword_shield_sword = "charge_blade_sword_shield_sword", axe_axe = "charge_blade_axe_axe", triple = "charge_blade_triple" },
        greatsword_type = { ["0"] = "greatsword_type_0", ["1"] = "greatsword_type_1", ["2"] = "greatsword_type_2", ["3"] = "greatsword_type_3", ["5"] = "greatsword_type_5", other = "greatsword_type_other" }
    }
    local key = state_keys[type_key] and state_keys[type_key][tostring(state)]
    if key then return self:T(key) end
    if type_key == "greatsword_level" and tonumber(state) and tonumber(state) >= 0 and tonumber(state) <= 3 then
        return self:T("greatsword_level_" .. tostring(state))
    end
    if type_key == "bow_level" and tonumber(state) and tonumber(state) >= 1 and tonumber(state) <= 4 then
        return self:T("bow_level_" .. tostring(state))
    end
    if type_key == "hammer_level" and tonumber(state) and tonumber(state) >= 0 and tonumber(state) <= 3 then
        return self:T("hammer_level_" .. tostring(state))
    end
    return tostring(state)
end
function VariantManagerUI:draw_transform_condition_title(type_key, character, x, y, w, view_top, view_bottom)
    local state = self.deps.get_transform_state and self.deps.get_transform_state(type_key, character)
    local title = self:transform_type_label(type_key) .. " (" .. self:T("current_state")
        .. ": " .. self:format_transform_state(type_key, state) .. ")"
    local line_height = 19
    for _, line in ipairs(Runtime.wrap_text(self.fonts.tiny, title, w)) do
        if y >= view_top and y + line_height <= view_bottom then
            Runtime.text(self.d2d, self.fonts.tiny, line, x, y, COLORS.accent)
        end
        y = y + line_height
    end
    return y + 8
end
function VariantManagerUI:get_transform_groups(context)
    local groups = { "" }
    for _, name in ipairs(context.group_names or {}) do table.insert(groups, name) end
    return groups
end
function VariantManagerUI:get_transform_presets(context, group_name)
    local target = context.config
    if group_name and group_name ~= "" and context.config and context.config.groups then
        target = context.config.groups[group_name]
    end
    if not target or type(target.presets) ~= "table" then return {} end
    local result, added = {}, {}
    if type(target.preset_order) == "table" then
        for _, name in ipairs(target.preset_order) do
            if target.presets[name] then table.insert(result, name); added[name] = true end
        end
    end
    for name, _ in pairs(target.presets) do
        if not added[name] then table.insert(result, name) end
    end
    return result
end
function VariantManagerUI:cycle_transform_target(target, context, direction)
    local groups = self:get_transform_groups(context)
    local group_index = 1
    for i, name in ipairs(groups) do
        if name == (target.group or "") then group_index = i; break end
    end
    group_index = ((group_index - 1 + direction) % #groups) + 1
    target.group = groups[group_index]
    target.preset = ""
end
function VariantManagerUI:new_transform_rule(type_key)
    if type_key == "hp" then return { threshold = 50, targets = {} } end
    if type_key == "damage" then
        return { condition_delay = 0, mode = 1, loop_inactive_time = 0,
            loop_count = 0, chain_loop_count = 1, duration = 5, targets = {},
            chain_nodes = { { duration = 1, targets = {} } } }
    end
    if type_key == "weapon" then return { state = "sheathed", targets = {} } end
    if type_key == "spirit" then return { level = 1, targets = {} } end
    if type_key == "dual_blades" then return { state = "normal", targets = {} } end
    if type_key == "switch_axe" then return { state = "sword_normal", targets = {} } end
    if type_key == "insect_glaive" then return { state = "none", targets = {} } end
    if type_key == "charge_blade" then return { state = "sword", targets = {} } end
    if type_key == "greatsword_type" then return { state = "0", targets = {} } end
    if type_key == "greatsword_level" then return { level = 0, targets = {} } end
    if type_key == "bow_level" then return { level = 1, targets = {} } end
    if type_key == "hammer_level" then return { level = 0, targets = {} } end
    return { targets = {} }
end
function VariantManagerUI:transform_rule_label(type_key, rule)
    if type_key == "hp" then return self:T("hp_percent") end
    if type_key == "damage" then return self:T("condition_damage") end
    if type_key == "spirit" then return self:T("spirit_level") .. " " .. tostring(rule.level or "?") end
    if type_key == "greatsword_level" or type_key == "bow_level" or type_key == "hammer_level" then
        return self:transform_type_label(type_key) .. " " .. tostring(rule.level or "?")
    end
    local state = tostring(rule.state or "")
    local state_keys = {
        weapon = { sheathed = "weapon_sheathed", drawn = "weapon_drawn" },
        dual_blades = { normal = "dual_normal", kijin = "dual_kijin", enhancement = "dual_enhancement" },
        switch_axe = { sword_normal = "switch_axe_sword_normal", sword_awakened = "switch_axe_sword_awakened", axe_normal = "switch_axe_axe_normal", axe_enhanced = "switch_axe_axe_enhanced" },
        insect_glaive = { none = "insect_glaive_none", white = "insect_glaive_white", orange = "insect_glaive_orange", red = "insect_glaive_red", triple = "insect_glaive_triple" },
        charge_blade = { sword = "charge_blade_sword", axe = "charge_blade_axe", sword_shield = "charge_blade_sword_shield", sword_sword = "charge_blade_sword_sword", sword_shield_sword = "charge_blade_sword_shield_sword", axe_axe = "charge_blade_axe_axe", triple = "charge_blade_triple" },
        greatsword_type = { ["0"] = "greatsword_type_0", ["1"] = "greatsword_type_1", ["2"] = "greatsword_type_2", ["3"] = "greatsword_type_3", ["5"] = "greatsword_type_5", other = "greatsword_type_other" }
    }
    local key = state_keys[type_key] and state_keys[type_key][state]
    return key and self:T(key) or state
end
function VariantManagerUI:save_transform(context)
    if self.deps.save_transform then self.deps.save_transform(context) end
end
function VariantManagerUI:draw_transform_target(target, context, x, y, w, visible)
    if not visible then return end
    if not target then return end
    local remove_w, gap = 24, 6
    local target_w = w - remove_w - gap
    local group_w = math.max(80, target_w * 0.42)
    local preset_w = target_w - group_w - gap
    local group_values = self:get_transform_groups(context)
    local group_labels = {}
    local group_index = 1
    for index, name in ipairs(group_values) do
        group_labels[index] = name == "" and self:T("main_list") or
            ((context.config.groups and context.config.groups[name] and context.config.groups[name].is_global)
                and self:T("global_group_label") .. " " or "") .. name
        if name == (target.group or "") then group_index = index end
    end
    local presets = self:get_transform_presets(context, target.group or "")
    self.select:draw({ key = "transform_group_" .. tostring(target), x = x, y = y,
        w = group_w, h = 26, values = group_values, labels = group_labels,
        selected_index = group_index, font = self.fonts.small,
        on_change = function(value) target.group = value; target.preset = ""; self:save_transform(context) end })
    local preset_index = 1
    for index, name in ipairs(presets) do if name == target.preset then preset_index = index; break end end
    self.select:draw({ key = "transform_preset_" .. tostring(target),
        x = x + group_w + gap, y = y, w = preset_w, h = 26, values = presets,
        selected_index = preset_index, placeholder = self:T("d2d_none"), font = self.fonts.small,
        on_change = function(value) target.preset = value; self:save_transform(context) end })
    if self.button:draw("x", x + target_w + gap, y, remove_w, 26, false, nil, self.fonts.tiny) then
        return true
    end
    return false
end
function VariantManagerUI:draw_transform_rules(type_key, config, context, x, y, w, view_top, view_bottom)
    local definition
    for _, item in ipairs(TRANSFORM_TYPES) do if item.key == type_key then definition = item; break end end
    if not definition then return y end
    local rules = config[definition.field]
    if type(rules) ~= "table" then rules = {}; config[definition.field] = rules end
    if type_key == "damage" and #rules == 0 then
        table.insert(rules, self:new_transform_rule(type_key))
    elseif type_key == "weapon" and #rules == 0 then
        table.insert(rules, { state = "sheathed", targets = {} })
        table.insert(rules, { state = "drawn", targets = {} })
    end
    local function visible(top, bottom) return top >= view_top and bottom <= view_bottom end
    if type_key == "hp" and context.character and self.deps.get_transform_state then
        local current_hp = self.deps.get_transform_state("hp", context.character)
        if type(current_hp) == "number" then
            local hp_label = self:T("hp_percent")
            local label_width = self.fonts.tiny and self.fonts.tiny:measure(hp_label) or 0
            local input_x = x + label_width + 10
            local input_width = 96
            local button_width = 60
            if visible(y, y + 28) then
                Runtime.text(self.d2d, self.fonts.tiny, hp_label, x, y + 5, COLORS.text)
                local test_field = "transform_test_hp"
                local stored_test_value = tonumber(self.number_inputs[test_field])
                if stored_test_value == nil then stored_test_value = current_hp end
                local test_value = stored_test_value
                self:draw_number_input(test_field, stored_test_value,
                    input_x, y, input_width, 26, 0, 100, 1)
                test_value = math.max(0, math.min(100, test_value))
                if self.button:draw(self:T("test_hp_btn"), input_x + input_width + 6, y,
                    button_width, 26, false, nil, self.fonts.tiny) and self.deps.set_test_hp then
                    self.deps.set_test_hp(context.character, test_value)
                end
            end
            y = y + 36
        end
    end
    if type_key == "hp" and visible(y, y + 26)
        and self.button:draw(self:T("add_node"), x, y, w, 26, false, nil, self.fonts.tiny) then
        table.insert(rules, self:new_transform_rule(type_key))
        self:save_transform(context)
    end
    if type_key == "hp" then y = y + 34 end
    for index, rule in ipairs(rules) do
        if type(rule.targets) ~= "table" then rule.targets = {} end
        local row_top = y
        local label = self:transform_rule_label(type_key, rule)
        local delete_w = type_key == "hp" and 24 or 0
        if visible(row_top, row_top + 28) then
            Runtime.text(self.d2d, self.fonts.tiny, label, x, row_top + 5, COLORS.text)
            if type_key == "hp" then
                local value_changed, next_value = self:draw_number_input(
                    "transform_hp_" .. tostring(rule), rule.threshold or 50,
                    x + (self.fonts.tiny and self.fonts.tiny:measure(label) or 0) + 10,
                    row_top, 106, 26, 1, 100, 1)
                if value_changed then rule.threshold = next_value; self:save_transform(context) end
            end
            if type_key == "damage" then
                local mode_values = { 1, 2, 3 }
                local mode_labels = { self:T("mode_normal"), self:T("mode_loop"), self:T("mode_chain") }
                self.select:draw({ key = "transform_damage_mode_" .. tostring(rule),
                    x = x + w - 156, y = row_top, w = 150, h = 26,
                    values = mode_values, labels = mode_labels,
                    selected_index = math.max(1, math.min(3, tonumber(rule.mode) or 1)),
                    font = self.fonts.small,
                    on_change = function(value) rule.mode = value; self:save_transform(context) end })
            end
            if delete_w > 0 and self.button:draw("x", x + w - delete_w, row_top, delete_w, 26, false, nil, self.fonts.tiny) then
                table.remove(rules, index); self:save_transform(context); y = y + 0
            end
        end
        y = y + 32
        if type_key == "damage" then
            local function draw_number_parameter(label_key, field_name, minimum, step)
                local value = tonumber(rule[field_name]) or minimum
                if visible(y, y + 26) then
                    local parameter_label = self:T(label_key)
                    Runtime.text(self.d2d, self.fonts.tiny,
                        parameter_label, x + 12, y + 5, COLORS.muted)
                    local value_changed, next_value = self:draw_number_input(
                        "transform_damage_" .. tostring(rule) .. "_" .. field_name,
                        value, x + 12 + (self.fonts.tiny and self.fonts.tiny:measure(parameter_label) or 0) + 10,
                        y, 106, 26, minimum, 999, step)
                    if value_changed then rule[field_name] = next_value; self:save_transform(context) end
                end
                y = y + 36
            end
            draw_number_parameter("condition_delay", "condition_delay", 0, 0.5)
            if rule.mode == 1 or rule.mode == 2 then
                draw_number_parameter("duration", "duration", 0, 1)
            end
            if rule.mode == 2 then
                draw_number_parameter("loop_inactive_time", "loop_inactive_time", 0, 0.5)
                draw_number_parameter("loop_count", "loop_count", 0, 1)
            elseif rule.mode == 3 then
                draw_number_parameter("chain_loop_count", "chain_loop_count", 1, 1)
            end
        end
        local target_list = rule.targets
        if type_key == "damage" and rule.mode == 3 then
            if type(rule.chain_nodes) ~= "table" then rule.chain_nodes = {} end
            for node_index, node in ipairs(rule.chain_nodes) do
                if type(node.targets) ~= "table" then node.targets = {} end
                if visible(y, y + 26) then
                    Runtime.text(self.d2d, self.fonts.tiny,
                        self:T("chain_node") .. " " .. tostring(node_index), x + 12, y + 5, COLORS.accent)
                    if self.button:draw("x", x + w - 24, y, 24, 26, false, nil, self.fonts.tiny) then
                        table.remove(rule.chain_nodes, node_index); self:save_transform(context)
                    end
                end
                y = y + 36
                local duration = tonumber(node.duration) or 1
                if visible(y, y + 26) then
                    local duration_label = self:T("duration")
                    Runtime.text(self.d2d, self.fonts.tiny,
                        duration_label, x + 12, y + 5, COLORS.muted)
                    local value_changed, next_value = self:draw_number_input(
                        "transform_chain_" .. tostring(node) .. "_duration", duration,
                        x + 12 + (self.fonts.tiny and self.fonts.tiny:measure(duration_label) or 0) + 10,
                        y, 106, 26, 0, 999, 1)
                    if value_changed then node.duration = next_value; self:save_transform(context) end
                end
                y = y + 30
                target_list = node.targets
                for target_index, target in ipairs(target_list) do
                    if visible(y, y + 26) then
                        local removed = self:draw_transform_target(target, context, x + 24, y, w - 24, true)
                        if removed then table.remove(target_list, target_index); self:save_transform(context) end
                    end
                    y = y + 36
                end
                if visible(y, y + 26) and self.button:draw(self:T("add_condition"), x + 24, y,
                    math.min(130, w - 24), 26, false, nil, self.fonts.tiny) then
                    table.insert(target_list, { group = "", preset = "" }); self:save_transform(context)
                end
                y = y + 36
            end
            if visible(y, y + 26) and self.button:draw(self:T("add_chain_node"), x, y,
                math.min(150, w), 26, false, nil, self.fonts.tiny) then
                table.insert(rule.chain_nodes, { duration = 1, targets = {} }); self:save_transform(context)
            end
            y = y + 36
        else
            for target_index, target in ipairs(target_list) do
                if visible(y, y + 26) then
                    local removed = self:draw_transform_target(target, context, x + 12, y, w - 12, true)
                    if removed then table.remove(target_list, target_index); self:save_transform(context) end
                end
                y = y + 36
            end
            if visible(y, y + 26) and self.button:draw(self:T("add_condition"), x + 12, y,
                math.min(130, w - 12), 26, false, nil, self.fonts.tiny) then
                table.insert(target_list, { group = "", preset = "" })
                self:save_transform(context)
            end
            y = y + 36
        end
    end
    return y
end
function VariantManagerUI:draw_transform_panel(x, y, w, h, context)
    self.panel:draw(x, y, w, h)
    local config = context.config or {}
    if config.is_parallel == nil then config.is_parallel = false end
    if type(config.parallel_settings) ~= "table" then config.parallel_settings = {} end
    local left_width = math.max(220, math.min(440, w * 0.40))
    local divider_x = x + left_width
    local left_x = x + LAYOUT.panel_inset
    local left_inner_width = left_width - LAYOUT.panel_inset * 2
    local right_x = divider_x + LAYOUT.panel_gap
    local right_width = x + w - right_x - LAYOUT.panel_inset - LAYOUT.panel_gap
    self.d2d.line(divider_x, y + LAYOUT.panel_inset, divider_x,
        y + h - LAYOUT.panel_inset, 1, COLORS.border)
    Runtime.text(self.d2d, self.fonts.small, self:T("transform_manager"),
        left_x, y + LAYOUT.panel_inset, COLORS.text)
    local mode_y = y + LAYOUT.panel_inset + LAYOUT.title_height + 8
    Runtime.text(self.d2d, self.fonts.tiny,
        config.is_parallel and self:T("current_mode_parallel") or self:T("current_mode_selection"),
        left_x, mode_y, COLORS.muted)
    if self.button:draw(config.is_parallel and self:T("switch_to_selection") or self:T("switch_to_parallel"),
        left_x, mode_y + 24, left_inner_width, 28, false, nil, self.fonts.tiny) then
        config.is_parallel = not config.is_parallel
        self.transform_scroll_offset = 0
        self.transform_max_scroll = 0
        self:save_transform(context)
    end
    local selected_type = config.transform_type or "hp"
    if not config.is_parallel then
        local type_values, type_labels, type_index = {}, {}, 1
        for index, definition in ipairs(TRANSFORM_TYPES) do
            type_values[index] = definition.key
            type_labels[index] = self:transform_type_label(definition.key)
            if definition.key == selected_type then type_index = index end
        end
        Runtime.text(self.d2d, self.fonts.tiny, self:T("transform_condition_type"),
            left_x, mode_y + 70, COLORS.muted)
        self.select:draw({ key = "transform_condition_type", x = left_x, y = mode_y + 92,
            w = left_inner_width, h = 30, values = type_values, labels = type_labels,
            selected_index = type_index, font = self.fonts.small,
            on_change = function(value)
                config.transform_type = value
                self.transform_scroll_offset = 0
                self.transform_max_scroll = 0
                self:save_transform(context)
            end })
    else
        Runtime.text(self.d2d, self.fonts.tiny, self:T("parallel_settings"),
            left_x, mode_y + 70, COLORS.muted)
        local priority_x = x + left_width - LAYOUT.panel_inset - 68
        Runtime.text(self.d2d, self.fonts.tiny, self:T("priority"),
            priority_x, mode_y + 70, COLORS.muted)
        local setting_y = mode_y + 94
        for _, definition in ipairs(TRANSFORM_TYPES) do
            local setting = config.parallel_settings[definition.key]
            if type(setting) ~= "table" then
                setting = { enabled = false, priority = 1 }
                config.parallel_settings[definition.key] = setting
            end
            if self.checkbox:draw(self:transform_type_label(definition.key), left_x,
                setting_y, left_inner_width - 74, 28, setting.enabled == true) then
                setting.enabled = not setting.enabled; self:save_transform(context)
            end
            local priority = tonumber(setting.priority) or 1
            local priority_changed, next_priority = self.input_number:draw(priority,
                priority_x, setting_y, 68, 26, 1, 999, 1)
            if priority_changed then setting.priority = next_priority; self:save_transform(context) end
            setting_y = setting_y + 32
        end
    end
    Runtime.text(self.d2d, self.fonts.small, self:T("d2d_transform_config"),
        right_x, y + LAYOUT.panel_inset, COLORS.text)
    local view_top = y + LAYOUT.panel_inset + LAYOUT.title_height
    local view_bottom = y + h - LAYOUT.panel_inset
    local mx, my = Runtime.mouse_position()
    if self.transform_max_scroll > 0
        and Runtime.point_in_rect(mx, my, right_x, view_top, right_width,
        math.max(0, view_bottom - view_top))
        and self.frame_mouse_wheel ~= 0 then
        self.transform_scroll_offset = math.max(0, math.min(self.transform_max_scroll,
            self.transform_scroll_offset - self.frame_mouse_wheel * 90))
    end
    local cursor_y = view_top + 8 - self.transform_scroll_offset
    local content_start = cursor_y
    local function visible(top, bottom) return top >= view_top and bottom <= view_bottom end
    if not config.is_parallel then
        cursor_y = self:draw_transform_condition_title(selected_type, context.character,
            right_x, cursor_y, right_width, view_top, view_bottom)
        cursor_y = self:draw_transform_rules(selected_type, config, context,
            right_x, cursor_y, right_width,
            view_top, view_bottom)
    else
        for _, definition in ipairs(TRANSFORM_TYPES) do
            local setting = config.parallel_settings[definition.key]
            if setting and setting.enabled then
                cursor_y = self:draw_transform_condition_title(definition.key, context.character,
                    right_x, cursor_y, right_width, view_top, view_bottom)
                cursor_y = self:draw_transform_rules(definition.key, config, context,
                    right_x, cursor_y, right_width,
                    view_top, view_bottom)
                cursor_y = cursor_y + 8
            end
        end
    end
    local content_height = cursor_y - content_start
    local viewport_height = view_bottom - view_top
    local max_scroll = math.max(0, content_height - viewport_height)
    self.transform_max_scroll = max_scroll
    self.transform_scroll_offset = math.min(self.transform_scroll_offset, max_scroll)
    if max_scroll > 0 then
        local track_x, track_w = x + w - LAYOUT.panel_inset, 8
        local track_y, track_h = view_top, viewport_height
        local thumb_h = math.max(24, track_h * viewport_height / content_height)
        local thumb_range = math.max(0, track_h - thumb_h)
        local thumb_y = track_y
        if max_scroll > 0 then
            thumb_y = track_y + thumb_range * self.transform_scroll_offset / max_scroll
        end
        self.d2d.fill_rounded_rect(track_x, track_y, track_w, track_h, 3, 3, COLORS.panel_alt)
        local thumb_hovered = Runtime.point_in_rect(mx, my, track_x - 5, thumb_y, track_w + 10, thumb_h)
        self.d2d.fill_rounded_rect(track_x, thumb_y, track_w, thumb_h, 3, 3,
            thumb_hovered or self.transform_scroll_dragging and COLORS.accent or COLORS.border)
        local track_hovered = Runtime.point_in_rect(mx, my, track_x - 5, track_y, track_w + 10, track_h)
        if Runtime.is_mouse_clicked() and track_hovered then
            self.transform_scroll_dragging = true
            if thumb_hovered then
                self.transform_scroll_drag_offset = my - thumb_y
            else
                self.transform_scroll_drag_offset = thumb_h / 2
                local next_thumb_y = math.max(track_y, math.min(track_y + thumb_range,
                    my - self.transform_scroll_drag_offset))
                self.transform_scroll_offset = math.floor(
                    (next_thumb_y - track_y) / math.max(1, thumb_range) * max_scroll + 0.5)
            end
        end
        if not Runtime.is_mouse_down() then self.transform_scroll_dragging = false end
        if self.transform_scroll_dragging and Runtime.is_mouse_down() and thumb_range > 0 then
            local next_thumb_y = math.max(track_y, math.min(track_y + thumb_range,
                my - self.transform_scroll_drag_offset))
            self.transform_scroll_offset = math.floor(
                (next_thumb_y - track_y) / thumb_range * max_scroll + 0.5)
        end
    end
    self.select:draw_popup()
end
function VariantManagerUI:get_documentation_section(section_index)
    local section = Documentation[section_index] or Documentation[1] or {}
    local language = self.deps.config and self.deps.config.language or "zh"
    if language == "en" and section.en then return section.en end
    return section
end
function VariantManagerUI:get_documentation_layout(text_width, section_index)
    local cache = self.documentation_layout
    local cache_width = math.floor(text_width + 0.5)
    local language = self.deps.config and self.deps.config.language or "zh"
    if cache and cache.width == cache_width and cache.section_index == section_index
        and cache.language == language and cache.text_font == self.fonts.small
        and cache.title_font == self.fonts.body then
        return cache
    end
    local section = self:get_documentation_section(section_index)
    local text_font = self.fonts.small
    local title_font = self.fonts.body
    local _, text_height = text_font:measure("Ag")
    local _, title_height = title_font:measure("Ag")
    local text_line_height = math.max(18, text_height + 5)
    local title_line_height = math.max(22, title_height + 5)
    local lines, cursor_y = {}, 0
    local function append_lines(value, font, max_width, line_height, color)
        for _, line in ipairs(Runtime.wrap_text(font, value, max_width)) do
            table.insert(lines, { text = line, font = font, y = cursor_y, color = color,
                height = line_height })
            cursor_y = cursor_y + line_height
        end
    end
    for _, entry in ipairs(section.entries or {}) do
        append_lines(entry.title, title_font, cache_width, title_line_height, COLORS.text)
        cursor_y = cursor_y + 4
        for _, paragraph in ipairs(entry.paragraphs or {}) do
            append_lines(paragraph, text_font, cache_width - 10, text_line_height, COLORS.muted)
            cursor_y = cursor_y + 6
        end
        cursor_y = cursor_y + 12
    end
    self.documentation_layout = {
        width = cache_width,
        section_index = section_index,
        language = language,
        text_font = text_font,
        title_font = title_font,
        lines = lines,
        height = cursor_y
    }
    return self.documentation_layout
end
function VariantManagerUI:draw_documentation_panel(x, y, w, h)
    self.panel:draw(x, y, w, h)
    local section_index = math.max(1, math.min(#Documentation, self.documentation_section or 1))
    self.documentation_section = section_index
    local switch_y = y + LAYOUT.panel_inset
    local switch_gap = 8
    local configure_label = self:get_documentation_section(1).title
    local usage_label = self:get_documentation_section(2).title
    local changelog_label = self:get_documentation_section(3).title
    local configure_width = math.max(100, self.fonts.small:measure(configure_label) + 28)
    local usage_width = math.max(100, self.fonts.small:measure(usage_label) + 28)
    local changelog_width = math.max(100, self.fonts.small:measure(changelog_label) + 28)
    if self.button:draw(usage_label, x + LAYOUT.panel_inset, switch_y,
        usage_width, 30, section_index == 2, nil, self.fonts.small) then
        self.documentation_section = 2
        self.documentation_scroll_offset = 0
        self.documentation_max_scroll = 0
        self.documentation_scroll_dragging = false
        section_index = 2
    end
    if self.button:draw(configure_label, x + LAYOUT.panel_inset + usage_width + switch_gap, switch_y,
        configure_width, 30, section_index == 1, nil, self.fonts.small) then
        self.documentation_section = 1
        self.documentation_scroll_offset = 0
        self.documentation_max_scroll = 0
        self.documentation_scroll_dragging = false
        section_index = 1
    end
    if self.button:draw(changelog_label,
        x + LAYOUT.panel_inset + usage_width + configure_width + switch_gap * 2, switch_y,
        changelog_width, 30, section_index == 3, nil, self.fonts.small) then
        self.documentation_section = 3
        self.documentation_scroll_offset = 0
        self.documentation_max_scroll = 0
        self.documentation_scroll_dragging = false
        section_index = 3
    end
    local view_top = switch_y + 40
    local view_bottom = y + h - LAYOUT.panel_inset
    local view_height = math.max(0, view_bottom - view_top)
    local mx, my = Runtime.mouse_position()
    if self.documentation_max_scroll > 0
        and Runtime.point_in_rect(mx, my, x + LAYOUT.panel_inset, view_top,
            w - LAYOUT.panel_inset * 2, view_height)
        and self.frame_mouse_wheel ~= 0 then
        self.documentation_scroll_offset = math.max(0, math.min(self.documentation_max_scroll,
            self.documentation_scroll_offset - self.frame_mouse_wheel * 90))
    end
    local text_x = x + LAYOUT.panel_inset
    local text_width = math.max(80, w - LAYOUT.panel_inset * 2 - 18)
    local layout = self:get_documentation_layout(text_width, section_index)
    local content_top = view_top + 8 - self.documentation_scroll_offset
    local function visible(top, bottom)
        return top >= view_top and bottom <= view_bottom
    end
    for _, line in ipairs(layout.lines) do
        local line_y = content_top + line.y
        if visible(line_y, line_y + line.height) then
            Runtime.text(self.d2d, line.font, line.text, text_x, line_y, line.color)
        end
    end
    local content_height = layout.height
    self.documentation_max_scroll = math.max(0, content_height - view_height)
    self.documentation_scroll_offset = math.min(self.documentation_scroll_offset,
        self.documentation_max_scroll)
    if self.documentation_max_scroll <= 0 then
        self.documentation_scroll_dragging = false
        return
    end
    local track_x, track_w = x + w - LAYOUT.panel_inset, 8
    local track_y, track_h = view_top, view_height
    local thumb_h = math.max(24, track_h * view_height / content_height)
    local thumb_range = math.max(0, track_h - thumb_h)
    local thumb_y = track_y + thumb_range * self.documentation_scroll_offset
        / math.max(1, self.documentation_max_scroll)
    self.d2d.fill_rounded_rect(track_x, track_y, track_w, track_h, 3, 3, COLORS.panel_alt)
    local thumb_hovered = Runtime.point_in_rect(mx, my, track_x - 5, thumb_y, track_w + 10, thumb_h)
    self.d2d.fill_rounded_rect(track_x, thumb_y, track_w, thumb_h, 3, 3,
        (thumb_hovered or self.documentation_scroll_dragging) and COLORS.accent or COLORS.border)
    local track_hovered = Runtime.point_in_rect(mx, my, track_x - 5, track_y, track_w + 10, track_h)
    if Runtime.is_mouse_clicked() and track_hovered then
        self.documentation_scroll_dragging = true
        self.documentation_scroll_drag_offset = thumb_hovered and my - thumb_y or thumb_h / 2
    end
    if not Runtime.is_mouse_down() then self.documentation_scroll_dragging = false end
    if self.documentation_scroll_dragging and Runtime.is_mouse_down() and thumb_range > 0 then
        local next_thumb_y = math.max(track_y, math.min(track_y + thumb_range,
            my - self.documentation_scroll_drag_offset))
        self.documentation_scroll_offset = math.floor((next_thumb_y - track_y)
            / thumb_range * self.documentation_max_scroll + 0.5)
    end
end
function VariantManagerUI:draw_right_tabs(x, y, w)
    local parts_label = self:T("d2d_parts_tab")
    local transform_label = self:T("d2d_transform_tab")
    local documentation_label = self:T("d2d_documentation_tab")
    local settings_label = self:T("d2d_settings_tab")
    local parts_width = 78
    local documentation_width = 78
    local settings_width = 78
    if self.fonts.body then
        parts_width = math.max(parts_width,
            self.fonts.body:measure(parts_label) + 24,
            self.fonts.body:measure(transform_label) + 24)
        documentation_width = math.max(documentation_width,
            self.fonts.body:measure(documentation_label) + 24)
        settings_width = math.max(settings_width, self.fonts.body:measure(settings_label) + 24)
    end
    local transform_width = parts_width
    local tab_height = 28
    local tab_gap = LAYOUT.mode_button_gap
    local tabs_x = x + w - LAYOUT.content_inset - parts_width - transform_width
        - documentation_width - settings_width - tab_gap * 3
    local tabs_y = y
    if self.button:draw(parts_label, tabs_x, tabs_y,
        parts_width, tab_height, self.right_panel == "parts") then
        self.right_panel = "parts"
    end
    if self.button:draw(transform_label, tabs_x + parts_width + tab_gap, tabs_y,
        transform_width, tab_height, self.right_panel == "transform") then
        self.right_panel = "transform"
    end
    if self.button:draw(documentation_label,
        tabs_x + parts_width + transform_width + tab_gap * 2, tabs_y,
        documentation_width, tab_height, self.right_panel == "documentation") then
        self.right_panel = "documentation"
    end
    if self.button:draw(settings_label,
        tabs_x + parts_width + transform_width + documentation_width + tab_gap * 3, tabs_y,
        settings_width, tab_height, self.right_panel == "settings") then
        self.right_panel = "settings"
    end
end
function VariantManagerUI:draw_wrapped_text(text, x, y, max_width, font, line_height, color)
    local line = ""
    local line_y = y
    local characters = string.gmatch(tostring(text or ""), "[%z\1-\127\194-\244][\128-\191]*")
    for character in characters do
        local candidate = line .. character
        local text_width = font and font:measure(candidate) or 0
        if line ~= "" and text_width > max_width then
            Runtime.text(self.d2d, font, line, x, line_y, color)
            line = character
            line_y = line_y + line_height
        else
            line = candidate
        end
    end
    if line ~= "" then Runtime.text(self.d2d, font, line, x, line_y, color) end
    return line_y + line_height
end
function VariantManagerUI:draw_settings_panel(x, y, w, h)
    local config = self.deps.config
    self.panel:draw(x, y, w, h)
    Runtime.text(self.d2d, self.fonts.small, self:T("d2d_settings_tab"),
        x + LAYOUT.panel_inset, y + LAYOUT.panel_inset, COLORS.muted)
    Runtime.text(self.d2d, self.fonts.body, self:T("d2d_settings_language"),
        x + LAYOUT.panel_inset, y + LAYOUT.settings_language_title, COLORS.text)
    local language_y = y + LAYOUT.settings_language_controls
    local language_width = 112
    if self.button:draw(self:T("d2d_language_chinese"), x + LAYOUT.panel_inset,
        language_y, language_width, 30, config.language == "zh") then
        config.language = "zh"
        self.deps.save_settings()
    end
    if self.button:draw(self:T("d2d_language_english"),
        x + LAYOUT.panel_inset + language_width + LAYOUT.mode_button_gap,
        language_y, language_width, 30, config.language == "en") then
        config.language = "en"
        self.deps.save_settings()
    end
    Runtime.text(self.d2d, self.fonts.body, self:T("d2d_settings_performance"),
        x + LAYOUT.panel_inset, y + LAYOUT.settings_performance_title, COLORS.text)
    local value_width = w - LAYOUT.panel_inset * 2
    local changed, value = self.sliders.scan_interval:draw(self:T("scan_interval"),
        config.scan_interval, x + LAYOUT.panel_inset, y + LAYOUT.settings_performance_controls, value_width,
        0.1, 5.0, 0.1, function(v) return string.format("%.1f s", v) end)
    if changed then config.scan_interval = value; self.deps.save_settings() end
    changed, value = self.sliders.body_id_ttl:draw(self:T("refresh_interval"),
        config.body_id_ttl, x + LAYOUT.panel_inset,
        y + LAYOUT.settings_performance_controls + LAYOUT.settings_performance_row_gap,
        value_width,
        0.1, 10.0, 0.1, function(v) return string.format("%.1f s", v) end)
    if changed then config.body_id_ttl = value; self.deps.save_settings() end
    changed, value = self.sliders.scanner_batch_size:draw(self:T("scanner_batch_size"),
        config.scanner_batch_size, x + LAYOUT.panel_inset,
        y + LAYOUT.settings_performance_controls + LAYOUT.settings_performance_row_gap * 2,
        value_width,
        10, 1000, 10, function(v) return tostring(math.floor(v + 0.5)) end)
    if changed then config.scanner_batch_size = value; self.deps.save_settings() end
    self:draw_wrapped_text(self:T("performance_desc"), x + LAYOUT.panel_inset,
        y + LAYOUT.settings_description_top, value_width, self.fonts.tiny, 18, COLORS.muted)
    Runtime.text(self.d2d, self.fonts.body, self:T("d2d_settings_shortcut"),
        x + LAYOUT.panel_inset, y + LAYOUT.settings_shortcut_title, COLORS.text)
    if self.waiting_for_key then
        Runtime.text(self.d2d, self.fonts.small, self:T("d2d_waiting_key"),
            x + LAYOUT.panel_inset, y + LAYOUT.settings_shortcut_controls, COLORS.accent)
    else
        if self.button:draw(self:T("d2d_bind_key"), x + LAYOUT.panel_inset,
            y + LAYOUT.settings_shortcut_controls - 4, 140, 30, false) then
            self:begin_key_binding()
        end
        Runtime.text(self.d2d, self.fonts.small,
            self:T("d2d_current_key") .. self:key_name(config.new_ui_key),
            x + LAYOUT.panel_inset + 152, y + LAYOUT.settings_shortcut_controls + 1, COLORS.muted)
    end
end
function VariantManagerUI:draw_parts(x, y, w, h, context)
    self.panel:draw(x, y, w, h)
    Runtime.text(self.d2d, self.fonts.small,
        context.weapon_mode and self:T("weapon_parts") or self:T("armor_parts"),
        x + LAYOUT.panel_inset, y + LAYOUT.panel_inset, COLORS.muted)
    local part_count = self.deps.get_part_count(context.character, context.weapon_mode)
    part_count = math.max(1, math.min(6, part_count or 1))
    if self.expanded_part ~= nil and self.expanded_part >= part_count then self.expanded_part = 0 end
    local list_w = math.min(LAYOUT.part_list_width_max,
        math.max(LAYOUT.part_list_width_min, math.floor(w * 0.26)))
    local list_x = x + LAYOUT.panel_inset
    local header_y = y + LAYOUT.panel_inset + LAYOUT.title_height
    local header_h = 30
    local header_gap = LAYOUT.list_gap
    for i = 0, part_count - 1 do
        if header_y + header_h > y + h then break end
        local label = self.deps.get_part_label
            and self.deps.get_part_label(context.character, context.weapon_mode, i)
        if not label or label == "" then
            label = context.weapon_mode and self:TF("d2d_part", i)
                or (PART_KEYS[i] and self:T(PART_KEYS[i]) or self:TF("d2d_part", i))
        end
        local expanded = self.expanded_part == i
        if self.button:draw(label,
            list_x, header_y, list_w, header_h, expanded) then
            self.expanded_part = expanded and nil or i
            self.part_index = i
            self.material_offset = 0
        end
        header_y = header_y + header_h + header_gap
    end
    local detail_x = list_x + list_w + LAYOUT.panel_gap
    local detail_w = x + w - detail_x - LAYOUT.panel_inset
    self.d2d.line(detail_x - LAYOUT.panel_gap / 2, y + LAYOUT.panel_inset + LAYOUT.title_height,
        detail_x - LAYOUT.panel_gap / 2, y + h - LAYOUT.panel_inset, 1, COLORS.border)
    if self.expanded_part ~= nil and self.expanded_part < part_count then
        local content_y = y + LAYOUT.panel_inset + LAYOUT.title_height
        local content_h = h - (LAYOUT.panel_inset + LAYOUT.title_height + LAYOUT.panel_inset)
        if content_h > 30 and detail_w > 80 then
            self:draw_part_content(detail_x, content_y, detail_w, content_h, context, self.expanded_part)
        end
    else
        Runtime.text(self.d2d, self.fonts.small, self:T("d2d_expand_hint"),
            detail_x, y + LAYOUT.panel_inset + LAYOUT.title_height, COLORS.muted)
    end
end
function VariantManagerUI:draw()
    local config = self.deps.config
    if not config.new_ui_enabled or not self.ready or not self.visible then return end
    local scale = self.window_scale or 1
    Runtime.set_ui_scale(scale)
    local raw_sw, raw_sh = self.d2d.surface_size()
    if not raw_sw or not raw_sh or raw_sw < 320 or raw_sh < 240 then return end
    Runtime.begin_input_frame()
    local sw, sh = raw_sw / scale, raw_sh / scale
    local mx, my = Runtime.mouse_position()
    local raw_mx, raw_my = Runtime.raw_mouse_position()
    local panel_w = math.min(1160, sw - 70)
    local panel_h = math.min(700, sh - 70)
    if not self.window_x then self.window_x = math.max(24, sw - panel_w - 48) end
    if not self.window_y then self.window_y = (sh - panel_h) / 2 end
    self.window_x, self.window_y = self.window:clamp(self.window_x, self.window_y, sw, sh, panel_w, panel_h)
    local panel_x, panel_y = self.window_x, self.window_y
    local armor_label = self:T("armor_mode")
    local weapon_label = self:T("weapon_mode")
    local mode_button_width = LAYOUT.mode_button_width
    if self.fonts.body then
        local armor_width = self.fonts.body:measure(armor_label)
        local weapon_width = self.fonts.body:measure(weapon_label)
        mode_button_width = math.max(mode_button_width,
            armor_width + LAYOUT.mode_button_padding * 2,
            weapon_width + LAYOUT.mode_button_padding * 2)
    end
    local mode_group_width = mode_button_width * 2 + LAYOUT.mode_button_gap
    local mode_x = panel_x + (panel_w - mode_group_width) / 2
    local mode_y = panel_y + LAYOUT.header_center - LAYOUT.mode_button_height / 2
    local weapon_mode_x = mode_x + mode_button_width + LAYOUT.mode_button_gap
    local close_x = panel_x + panel_w - LAYOUT.header_inset - LAYOUT.close_button_size
    local excluded = {
        { x = mode_x, y = mode_y, w = mode_button_width, h = LAYOUT.mode_button_height },
        { x = weapon_mode_x, y = mode_y, w = mode_button_width, h = LAYOUT.mode_button_height },
        { x = close_x, y = mode_y, w = LAYOUT.close_button_size, h = LAYOUT.close_button_size }
    }
    local edge_size = 10
    local physical_x, physical_y = panel_x * scale, panel_y * scale
    local physical_w, physical_h = panel_w * scale, panel_h * scale
    local function edge_at(x, y)
        local left = math.abs(x - physical_x) <= edge_size
        local right = math.abs(x - (physical_x + physical_w)) <= edge_size
        local top = math.abs(y - physical_y) <= edge_size
        local bottom = math.abs(y - (physical_y + physical_h)) <= edge_size
        if top and left then return "nw" end
        if top and right then return "ne" end
        if bottom and left then return "sw" end
        if bottom and right then return "se" end
        if left then return "w" end
        if right then return "e" end
        if top then return "n" end
        if bottom then return "s" end
        return nil
    end
    if self.resize_edge then
        if Runtime.is_mouse_down() then
            local horizontal = nil
            if self.resize_edge:find("e") then horizontal = (raw_mx - physical_x) / panel_w end
            if self.resize_edge:find("w") then horizontal = (physical_x + physical_w - raw_mx) / panel_w end
            local vertical = nil
            if self.resize_edge:find("s") then vertical = (raw_my - physical_y) / panel_h end
            if self.resize_edge:find("n") then vertical = (physical_y + physical_h - raw_my) / panel_h end
            local next_scale = horizontal or vertical or scale
            if horizontal and vertical then next_scale = (horizontal + vertical) / 2 end
            next_scale = math.max(0.65, math.min(1.25, next_scale))
            if self.resize_edge:find("w") then
                local right = physical_x + physical_w
                panel_x = (right - panel_w * next_scale) / next_scale
            end
            if self.resize_edge:find("n") then
                local bottom = physical_y + physical_h
                panel_y = (bottom - panel_h * next_scale) / next_scale
            end
            scale = next_scale
            self.window_scale = scale
            Runtime.set_ui_scale(scale)
            sw, sh = raw_sw / scale, raw_sh / scale
            mx, my = Runtime.to_logical_point(raw_mx, raw_my)
        else
            self.resize_edge = nil
        end
    elseif Runtime.is_mouse_clicked() then
        self.resize_edge = edge_at(raw_mx, raw_my)
    end
    panel_x, panel_y = self.window:update(mx, my, panel_x, panel_y, panel_w, panel_h, sw, sh, excluded, false)
    self.window_x, self.window_y = panel_x, panel_y
    mode_x = panel_x + (panel_w - mode_group_width) / 2
    mode_y = panel_y + LAYOUT.header_center - LAYOUT.mode_button_height / 2
    weapon_mode_x = mode_x + mode_button_width + LAYOUT.mode_button_gap
    close_x = panel_x + panel_w - LAYOUT.header_inset - LAYOUT.close_button_size
    self.d2d.fill_rect(0, 0, raw_sw, raw_sh, 0x66000000)
    self.d2d.push_transform(0, 0, scale)
    self.d2d.fill_rounded_rect(panel_x, panel_y, panel_w, panel_h, 10, 10, COLORS.background)
    self.d2d.outline_rect(panel_x, panel_y, panel_w, panel_h, 1, COLORS.border)
    Runtime.text(self.d2d, self.fonts.title, self:T("mod_name"),
        panel_x + LAYOUT.header_inset, panel_y + LAYOUT.header_text_top, COLORS.text)
    local context = self.deps.get_context() or {}
    Runtime.text(self.d2d, self.fonts.small,
        (context.weapon_mode and self:T("weapon_mode") or self:T("armor_mode")) .. "  •  " ..
            (context.body_id or self:T("waiting_for_player")),
            panel_x + LAYOUT.header_inset,
            panel_y + LAYOUT.header_text_top + LAYOUT.header_text_gap + 29, COLORS.muted)
    if self.button:draw(armor_label, mode_x, mode_y,
        mode_button_width, LAYOUT.mode_button_height, not context.weapon_mode) then
        if context.weapon_mode then self.deps.set_mode(false) end
    end
    if self.button:draw(weapon_label, weapon_mode_x, mode_y,
        mode_button_width, LAYOUT.mode_button_height, context.weapon_mode) then
        if not context.weapon_mode then self.deps.set_mode(true) end
    end
    if self.button:draw("×", close_x, mode_y,
        LAYOUT.close_button_size, LAYOUT.close_button_size, false) then
        self.visible = false
    end
    local content_y = panel_y + LAYOUT.content_top
    local content_h = panel_h - LAYOUT.content_top - LAYOUT.footer_height - LAYOUT.footer_gap
    context = self.deps.get_context() or context
    local available_width = panel_w - LAYOUT.content_inset * 2 - LAYOUT.panel_gap * 2
    local library_width = available_width * 0.25
    local preset_width = available_width * 0.25
    local right_panel_width = available_width * 0.5
    local library_x = panel_x + LAYOUT.content_inset
    local replaceable_x = library_x + library_width + LAYOUT.panel_gap + preset_width + LAYOUT.panel_gap
    local library_right = library_x + library_width + LAYOUT.panel_gap + preset_width
    if self.right_panel == "transform" or self.right_panel == "documentation" then
        if self.right_panel == "transform" then
            self:draw_transform_panel(library_x, content_y,
                panel_w - LAYOUT.content_inset * 2, content_h, context)
        else
            self:draw_documentation_panel(library_x, content_y,
                panel_w - LAYOUT.content_inset * 2, content_h)
        end
        library_right = library_x + panel_w - LAYOUT.content_inset * 2
    elseif context.character and context.body_id then
        library_right = self:draw_library(library_x, content_y, library_width,
            content_h, context, preset_width)
    else
        self.panel:draw(library_x, content_y, library_width + LAYOUT.panel_gap + preset_width, content_h)
        Runtime.text(self.d2d, self.fonts.small, self:T("group"),
            library_x + LAYOUT.panel_inset,
            content_y + LAYOUT.panel_inset, COLORS.muted)
        Runtime.text(self.d2d, self.fonts.tiny, self:T("d2d_waiting_data"),
            library_x + LAYOUT.panel_inset,
            content_y + LAYOUT.panel_inset + LAYOUT.title_height + 8, COLORS.muted)
    end
    local replaceable_w = right_panel_width
    if self.right_panel ~= "transform" and self.right_panel ~= "documentation" and replaceable_w > 80 then
        if self.right_panel == "settings" then
            self:draw_settings_panel(replaceable_x, content_y, replaceable_w, content_h)
        elseif self.right_panel == "transform" then
            self:draw_transform_panel(replaceable_x, content_y, replaceable_w, content_h, context)
        elseif context.character and context.body_id then
            self:draw_parts(replaceable_x, content_y, replaceable_w, content_h, context)
        else
            self.panel:draw(replaceable_x, content_y, replaceable_w, content_h)
            Runtime.text(self.d2d, self.fonts.small, self:T("d2d_parts_tab"),
                replaceable_x + LAYOUT.panel_inset, content_y + LAYOUT.panel_inset, COLORS.muted)
            Runtime.text(self.d2d, self.fonts.tiny, self:T("d2d_waiting_data"),
                replaceable_x + LAYOUT.panel_inset,
                content_y + LAYOUT.panel_inset + LAYOUT.title_height + 8, COLORS.muted)
        end
    end
    local footer_text = self:T("version") .. ": " .. self.version .. "  |  " ..
        self:T("author") .. ": " .. self.author
    local footer_top = panel_y + panel_h - LAYOUT.footer_height
    local _, footer_text_height = self.fonts.small:measure(footer_text)
    local footer_y = footer_top + math.max(0, (LAYOUT.footer_height - footer_text_height) / 2)
    Runtime.text(self.d2d, self.fonts.small, footer_text,
        panel_x + LAYOUT.content_inset, footer_y, COLORS.muted)
    self:draw_right_tabs(panel_x,
        panel_y + panel_h - LAYOUT.footer_height + 9, panel_w)
    self.d2d.pop_transform()
    local cursor_x, cursor_y = Runtime.raw_mouse_position()
    if Runtime.real_mouse_inside_surface() and cursor_x >= 0 and cursor_y >= 0 then
        local hover_edge = self.resize_edge or edge_at(cursor_x, cursor_y)
        local logical_cursor_x, logical_cursor_y = Runtime.to_logical_point(cursor_x, cursor_y)
        local hover_drag_header = not hover_edge
            and Runtime.point_in_rect(logical_cursor_x, logical_cursor_y,
                panel_x + 6, panel_y + 6, panel_w - 12, 58)
            and not Runtime.point_in_rect(logical_cursor_x, logical_cursor_y,
                mode_x, mode_y, mode_button_width, LAYOUT.mode_button_height)
            and not Runtime.point_in_rect(logical_cursor_x, logical_cursor_y,
                weapon_mode_x, mode_y, mode_button_width, LAYOUT.mode_button_height)
            and not Runtime.point_in_rect(logical_cursor_x, logical_cursor_y,
                close_x, mode_y, LAYOUT.close_button_size, LAYOUT.close_button_size)
        if hover_edge then
            local horizontal = hover_edge:find("e") or hover_edge:find("w")
            local vertical = hover_edge:find("n") or hover_edge:find("s")
            if horizontal then
                self.d2d.line(cursor_x - 8, cursor_y, cursor_x + 8, cursor_y, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x - 8, cursor_y, cursor_x - 4, cursor_y - 4, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x - 8, cursor_y, cursor_x - 4, cursor_y + 4, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x + 8, cursor_y, cursor_x + 4, cursor_y - 4, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x + 8, cursor_y, cursor_x + 4, cursor_y + 4, 2, 0xFFF7FAFC)
            end
            if vertical then
                self.d2d.line(cursor_x, cursor_y - 8, cursor_x, cursor_y + 8, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x, cursor_y - 8, cursor_x - 4, cursor_y - 4, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x, cursor_y - 8, cursor_x + 4, cursor_y - 4, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x, cursor_y + 8, cursor_x - 4, cursor_y + 4, 2, 0xFFF7FAFC)
                self.d2d.line(cursor_x, cursor_y + 8, cursor_x + 4, cursor_y + 4, 2, 0xFFF7FAFC)
            end
        elseif hover_drag_header then
            self.d2d.line(cursor_x - 9, cursor_y, cursor_x + 9, cursor_y, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x, cursor_y - 9, cursor_x, cursor_y + 9, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x - 9, cursor_y, cursor_x - 5, cursor_y - 4, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x - 9, cursor_y, cursor_x - 5, cursor_y + 4, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x + 9, cursor_y, cursor_x + 5, cursor_y - 4, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x + 9, cursor_y, cursor_x + 5, cursor_y + 4, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x, cursor_y - 9, cursor_x - 4, cursor_y - 5, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x, cursor_y - 9, cursor_x + 4, cursor_y - 5, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x, cursor_y + 9, cursor_x - 4, cursor_y + 5, 2, 0xFFF7FAFC)
            self.d2d.line(cursor_x, cursor_y + 9, cursor_x + 4, cursor_y + 5, 2, 0xFFF7FAFC)
        else
            local points = {
                { cursor_x, cursor_y },
                { cursor_x, cursor_y + 20 },
                { cursor_x + 6, cursor_y + 15 },
                { cursor_x + 11, cursor_y + 26 },
                { cursor_x + 15, cursor_y + 24 },
                { cursor_x + 9, cursor_y + 12 },
                { cursor_x + 19, cursor_y + 12 },
                { cursor_x, cursor_y }
            }
            for i = 1, #points - 1 do
                local from_point, to_point = points[i], points[i + 1]
                self.d2d.line(from_point[1], from_point[2], to_point[1], to_point[2], 4, 0xFF10151C)
            end
            for i = 1, #points - 1 do
                local from_point, to_point = points[i], points[i + 1]
                self.d2d.line(from_point[1], from_point[2], to_point[1], to_point[2], 2, 0xFFF7FAFC)
            end
        end
    end
    Runtime.end_input_frame()
end
return VariantManagerUI
