local BridgeRuntime = {}
local present, retry = {}, {}
-- Optional native output may not exist until plugin startup / the first edit.
-- fs.glob paths use Windows separators in some REF builds. Cache existence;
-- never enumerate the data directory in the steady-state per-frame reader.
function BridgeRuntime.read_optional_json(path)
    if not present[path] and fs and type(fs.glob) == "function" then
        local now = os.clock()
        if now < (retry[path] or 0) then return nil end
        local pattern = path:gsub("\\", "/"):gsub("%.", "\\."):gsub("/", "[/\\\\]")
        local ok, files = pcall(fs.glob, pattern)
        if ok and type(files) == "table" then
            if next(files) == nil then retry[path] = now + 0.1; return nil end
            present[path] = true
        end
    end
    local ok, value
    if fs and type(fs.read) == "function" and type(json.load_string) == "function" then
        -- A concurrent atomic replacement can briefly make an open fail. Treat
        -- that as no new snapshot; json.load_file would emit a parse-error log.
        local read_ok, text = pcall(fs.read, path)
        if not read_ok or type(text) ~= "string" or #text > 65536
            or not text:match("^%s*{.*}%s*$") then return nil end
        ok, value = pcall(json.load_string, text)
    else
        ok, value = pcall(function() return json.load_file(path) end)
    end
    if ok and type(value) == "table" then return value end
    present[path] = nil
end
BridgeRuntime.default_runtime_directory = "ArmorVariantManager/Runtime"
BridgeRuntime.default_client_id = "ArmorVariantManager"
function BridgeRuntime.paths(runtime_directory)
    local directory = runtime_directory or BridgeRuntime.default_runtime_directory
    directory = tostring(directory):gsub("\\", "/"):gsub("/+$", "")
    if directory == "" then directory = BridgeRuntime.default_runtime_directory end
    return {
        runtime_directory = directory,
        state_path = directory .. "/AVMInputRequest.json",
        request_path = directory .. "/AVMTextInputRequest.json",
        result_path = directory .. "/AVMTextInputResult.json"
    }
end
function BridgeRuntime.register(client_id, runtime_directory)
    client_id = client_id or BridgeRuntime.default_client_id
    local paths = BridgeRuntime.paths(runtime_directory)
    local ok, registered = pcall(function()
        return d2d and d2d.bridge and d2d.bridge.register_runtime
            and d2d.bridge.register_runtime(client_id, paths.runtime_directory)
    end)
    return ok and registered == true, paths
end
function BridgeRuntime.unregister(client_id)
    local ok, unregistered = pcall(function()
        return d2d and d2d.bridge and d2d.bridge.unregister_runtime
            and d2d.bridge.unregister_runtime(client_id)
    end)
    return ok and unregistered == true
end
return BridgeRuntime
