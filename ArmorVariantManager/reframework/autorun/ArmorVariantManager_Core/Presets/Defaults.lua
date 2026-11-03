local Defaults = {}

local function merge(owner, name, key, result, selected, merge_into)
    local preset = name and name ~= "" and owner.presets and owner.presets[name]
    if not preset then return end
    merge_into(result, preset)
    if not selected[key] or selected[key] == "" then selected[key] = name end
end

-- 普通基础与全局锁分两步，允许游戏在锁定前保存回滚基础。
function Defaults.normal(config, policy, result, selected)
    merge(config, config.default_preset, "", result, selected, policy.merge_into)
    for name, group in pairs(config.groups or {}) do
        if not group.is_global then
            merge(group, group.default_preset, name, result, selected, policy.merge_into)
        end
    end
    return result
end

function Defaults.globals(config, policy, result, selected, default_name)
    for name, group in pairs(config.groups or {}) do
        if group.is_global then
            local preset = default_name and default_name(group) or group.default_preset
            merge(group, preset, name, result, selected, policy.merge_global_into)
        end
    end
    return result
end

return Defaults
