local NativeTextInput = {}
local BridgeRuntime = require("ArmorVariantManager_UI.Service.BridgeRuntime")
local default_request_path = "ArmorVariantManager/Runtime/D2DTextInputRequest.json"
local default_result_path = "ArmorVariantManager/Runtime/D2DTextInputResult.json"
function NativeTextInput.new(options)
    options = options or {}
    local paths = BridgeRuntime.paths(options.runtime_directory)
    BridgeRuntime.register(options.client_id or BridgeRuntime.default_client_id, paths.runtime_directory)
    local self = {
        active_id = nil,
        session = 0,
        token_prefix = string.format("%d_%d", os.time(), math.floor(os.clock() * 1000000)),
        active_token = nil,
        active_text = "",
        active_rect = nil,
        request_path = options.request_path or paths.request_path,
        result_path = options.result_path or paths.result_path,
        composition = "",
        caret_start = nil,
        caret_end = nil,
        last_sequence = 0,
        last_request_signature = nil
    }
    return setmetatable(self, { __index = NativeTextInput })
end
function NativeTextInput:write_request(active, text, rect)
    local request = { active = active == true }
    if request.active then
        request.session = self.session
        request.focus_sequence = self.focus_sequence or 0
        request.id = self.active_id
        request.token = self.active_token
        request.text = text or ""
        request.x = math.floor((rect and rect.x or 0) + 0.5)
        request.y = math.floor((rect and rect.y or 0) + 0.5)
        request.width = math.max(1, math.floor((rect and rect.w or 1) + 0.5))
        request.height = math.max(1, math.floor((rect and rect.h or 28) + 0.5))
    end
    pcall(function() json.dump_file(self.request_path, request) end)
end
function NativeTextInput:activate(input_id, text, rect, reset)
    local is_new_session = reset == true or self.active_id ~= input_id
    if is_new_session then
        self.session = self.session + 1
        _G.__AVM_UI_TEXT_FOCUS_SEQUENCE = (_G.__AVM_UI_TEXT_FOCUS_SEQUENCE or 0) + 1
        self.focus_sequence = _G.__AVM_UI_TEXT_FOCUS_SEQUENCE
        self.active_id = input_id
        self.active_token = self.token_prefix .. ":" .. tostring(self.session)
        self.active_text = text or ""
        self.composition = ""
        self.caret_start = nil
        self.caret_end = nil
        self.last_sequence = 0
        self.last_request_signature = nil
    end
    self:sync_rect(input_id, rect)
end
function NativeTextInput:sync_rect(input_id, rect)
    if self.active_id ~= input_id then return end
    local x = math.floor((rect and rect.x or 0) + 0.5)
    local y = math.floor((rect and rect.y or 0) + 0.5)
    local w = math.max(1, math.floor((rect and rect.w or 1) + 0.5))
    local h = math.max(1, math.floor((rect and rect.h or 28) + 0.5))
    local signature = string.format("%s:%d:%d:%d:%d:%d", input_id, self.session, x, y, w, h)
    if signature == self.last_request_signature then return end
    self.last_request_signature = signature
    self:write_request(true, self.active_text, { x = x, y = y, w = w, h = h })
end
function NativeTextInput:deactivate(input_id)
    if input_id ~= nil and self.active_id ~= input_id then return end
    if self.active_id == nil then return end
    self.active_id = nil
    self.active_token = nil
    self.active_text = ""
    self.active_rect = nil
    self.composition = ""
    self.caret_start = nil
    self.caret_end = nil
    self.last_request_signature = nil
    self:write_request(false)
end
function NativeTextInput:is_active(input_id)
    return self.active_id == input_id
end
function NativeTextInput:get_composition(input_id)
    if self.active_id == input_id then return self.composition or "" end
    return ""
end
function NativeTextInput:get_caret(input_id)
    if self.active_id ~= input_id then return nil, nil end
    return self.caret_start, self.caret_end
end
function NativeTextInput:update()
    if self.active_id == nil then return nil end
    local ok, result = pcall(function() return json.load_file(self.result_path) end)
    if not ok or type(result) ~= "table" then return nil end
    local sequence = tonumber(result.sequence)
    if not sequence or sequence <= self.last_sequence then return nil end
    if result.id ~= self.active_id or tonumber(result.session) ~= self.session
        or result.token ~= self.active_token then return nil end
    self.last_sequence = sequence
    self.active_text = type(result.text) == "string" and result.text or ""
    self.composition = type(result.composition) == "string" and result.composition or ""
    self.caret_start = tonumber(result.caret_start)
    self.caret_end = tonumber(result.caret_end)
    return self.active_id, self.active_text, self.composition, result.focused ~= false,
        self.caret_start, self.caret_end
end
return NativeTextInput
