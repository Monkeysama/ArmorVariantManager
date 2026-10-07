local BridgeRuntime = {}
BridgeRuntime.default_runtime_directory = "ArmorVariantManager/Runtime"
BridgeRuntime.default_client_id = "ArmorVariantManager"
function BridgeRuntime.paths(runtime_directory)
    local directory = runtime_directory or BridgeRuntime.default_runtime_directory
    directory = tostring(directory):gsub("\\", "/"):gsub("/+$", "")
    if directory == "" then directory = BridgeRuntime.default_runtime_directory end
    return {
        runtime_directory = directory,
        state_path = directory .. "/D2DInputState.json",
        request_path = directory .. "/D2DTextInputRequest.json",
        result_path = directory .. "/D2DTextInputResult.json"
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
