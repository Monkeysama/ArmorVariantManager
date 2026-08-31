local BridgeRuntime = {}

-- 保持差分管理器既有目录为默认值，旧版组件不传配置时无需迁移。
BridgeRuntime.default_runtime_directory = "ArmorVariantManager/Runtime"
BridgeRuntime.default_client_id = "ArmorVariantManager"

-- 根据运行时目录统一生成桥接文件路径，供输入拦截与原生文本输入复用。
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

-- 将当前 Lua 项目的通信目录注册给单 DLL 原生运行时。
function BridgeRuntime.register(client_id, runtime_directory)
    client_id = client_id or BridgeRuntime.default_client_id
    local paths = BridgeRuntime.paths(runtime_directory)
    local ok, registered = pcall(function()
        return d2d and d2d.bridge and d2d.bridge.register_runtime
            and d2d.bridge.register_runtime(client_id, paths.runtime_directory)
    end)
    return ok and registered == true, paths
end

-- 显式注销已停止的项目，避免其残留状态文件继续参与原生输入仲裁。
function BridgeRuntime.unregister(client_id)
    local ok, unregistered = pcall(function()
        return d2d and d2d.bridge and d2d.bridge.unregister_runtime
            and d2d.bridge.unregister_runtime(client_id)
    end)
    return ok and unregistered == true
end

return BridgeRuntime
