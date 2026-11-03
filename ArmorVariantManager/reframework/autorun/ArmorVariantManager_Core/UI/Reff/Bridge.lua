local Bridge = {}

-- REFF 可选加载；未安装时不影响业务处理和 REF 原生入口。
function Bridge.register(controller)
    if not rawget(_G, "reff_native") then return nil end
    local ok, sdk = pcall(require, "reff.sdk")
    if not ok then
        log.error("[ArmorVariantManager] REFF SDK 加载失败: " .. tostring(sdk))
        return nil
    end
    local registered, handle = pcall(sdk.register, "monkeysama.avm", {methods={
        ["monkeysama.avm.snapshot"]=controller.snapshot,
        ["monkeysama.avm.action"]=controller.action,
        ["monkeysama.avm.documentation"]=controller.documentation,
    },events={}}, reff_native)
    if not registered then
        log.error("[ArmorVariantManager] REFF 注册失败: " .. tostring(handle))
        return nil
    end
    re.on_script_reset(function() handle.unregister() end)
    return handle
end

return Bridge
