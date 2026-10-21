-- Native bridge snapshots contain only this game's input; stale files are ignored.
local WindowsInput = {}
local BridgeRuntime = require("ArmorVariantManager_UI.Service.BridgeRuntime")
local path = "ArmorVariantManager/Runtime/AVMInputState.json"
local snapshot, sequence, changed_at, read_at
local retry_at = 0
function WindowsInput.refresh()
    local now = os.clock()
    if now < retry_at then return WindowsInput.state() end
    if read_at and now - read_at < 0.008 then return WindowsInput.state() end
    read_at = now
    local value = BridgeRuntime.read_optional_json(path)
    if type(value) == "table" and value.protocol == 1 and type(value.sequence) == "number" then
        retry_at = 0
        if sequence == nil then sequence = value.sequence
        elseif value.sequence ~= sequence then
            snapshot, sequence, changed_at = value, value.sequence, now
        end
    else retry_at = now + 1 end
    -- A file left over after a crash is never accepted until a new sequence arrives.
    if not changed_at or os.clock() - changed_at > 0.75 then return nil end
    return snapshot
end
function WindowsInput.state()
    if changed_at and os.clock() - changed_at <= 0.75 then return snapshot end
end
function WindowsInput.key_down(key)
    local value = WindowsInput.state()
    if value then return value.foreground == true and value.keys and value.keys[tostring(key)] == true end
    local ok, down = pcall(function() return reframework:is_key_down(key) end)
    return ok and down == true
end
function WindowsInput.first_key()
    for key = 8, 255 do if WindowsInput.key_down(key) then return key end end
end
function WindowsInput.surface_size()
    local value = WindowsInput.state()
    if value and type(value.surface_width) == "number" and type(value.surface_height) == "number"
        and value.surface_width > 0 and value.surface_height > 0 then
        return value.surface_width, value.surface_height
    end
end
return WindowsInput
