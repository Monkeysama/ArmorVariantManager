local NativeTextInput = {}

-- 原生输入代理的请求与结果均属于短生命周期运行时状态。
local request_path = "ArmorVariantManager/Runtime/D2DTextInputRequest.json"
local result_path = "ArmorVariantManager/Runtime/D2DTextInputResult.json"

-- 管理 D2D 自绘输入框与原生 IME 代理之间的会话状态。
function NativeTextInput.new()
    local self = {
        active_id = nil,
        session = 0,
        token_prefix = string.format("%d_%d", os.time(), math.floor(os.clock() * 1000000)),
        active_token = nil,
        active_text = "",
        active_rect = nil,
        composition = "",
        last_sequence = 0,
        last_request_signature = nil
    }
    return setmetatable(self, { __index = NativeTextInput })
end

-- 将当前输入会话请求写给 DLL。DLL 会容忍文件写入中的短暂不完整状态。
function NativeTextInput:write_request(active, text, rect)
    local request = { active = active == true }
    if request.active then
        request.session = self.session
        request.id = self.active_id
        request.token = self.active_token
        request.text = text or ""
        request.x = math.floor((rect and rect.x or 0) + 0.5)
        request.y = math.floor((rect and rect.y or 0) + 0.5)
        request.width = math.max(1, math.floor((rect and rect.w or 1) + 0.5))
        request.height = math.max(1, math.floor((rect and rect.h or 28) + 0.5))
    end
    pcall(function() json.dump_file(request_path, request) end)
end

-- 激活一个字段。每次切换字段或显式重置文本都会增加会话号，避免旧结果回写到新字段。
function NativeTextInput:activate(input_id, text, rect, reset)
    local is_new_session = reset == true or self.active_id ~= input_id
    if is_new_session then
        self.session = self.session + 1
        self.active_id = input_id
        self.active_token = self.token_prefix .. ":" .. tostring(self.session)
        self.active_text = text or ""
        self.composition = ""
        self.last_sequence = 0
        self.last_request_signature = nil
    end
    self:sync_rect(input_id, rect)
end

-- 仅在输入框坐标发生变化时写入请求，避免每帧磁盘写入和输入过程重置。
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

-- 结束当前原生 IME 会话，并把焦点还给游戏窗口。
function NativeTextInput:deactivate(input_id)
    if input_id ~= nil and self.active_id ~= input_id then return end
    if self.active_id == nil then return end
    self.active_id = nil
    self.active_token = nil
    self.active_text = ""
    self.active_rect = nil
    self.composition = ""
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

-- 读取 DLL 原子写回的文本结果，并返回发生变化的字段值。
function NativeTextInput:update()
    if self.active_id == nil then return nil end
    local ok, result = pcall(function() return json.load_file(result_path) end)
    if not ok or type(result) ~= "table" then return nil end
    local sequence = tonumber(result.sequence)
    if not sequence or sequence <= self.last_sequence then return nil end
    if result.id ~= self.active_id or tonumber(result.session) ~= self.session
        or result.token ~= self.active_token then return nil end
    self.last_sequence = sequence
    self.active_text = type(result.text) == "string" and result.text or ""
    self.composition = type(result.composition) == "string" and result.composition or ""
    return self.active_id, self.active_text, self.composition, result.focused ~= false
end

return NativeTextInput
