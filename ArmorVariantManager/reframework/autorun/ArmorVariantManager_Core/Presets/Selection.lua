local Selection = {}

-- 规则只覆盖当前角色的全局组选择，不改写共享手动选择。
function Selection.resolve_groups(config, selected, targets, targeted_groups)
    local result, rebuild = {}, false
    for name, preset in pairs(selected or {}) do result[name] = preset end
    for name, group in pairs(config.groups or {}) do
        if group.is_global then
            if targets and targets[name] then
                result[name], rebuild = targets[name], true
            elseif targeted_groups and targeted_groups[name] then
                result[name], rebuild = group.default_preset or "", true
            end
        end
    end
    return result, rebuild
end

-- 规则覆盖普通材质后仍须服从该角色的全局隐藏，不读取 UI 上下文。
function Selection.merge_globals(config, selected, result, policy)
    for name, group in pairs(config.groups or {}) do
        if group.is_global then
            local preset_name = selected[name]
            if not preset_name or preset_name == "" then preset_name = group.default_preset end
            local preset = preset_name and preset_name ~= "" and group.presets and group.presets[preset_name]
            if preset then policy.merge_global_into(result, preset) end
        end
    end
    return result
end

-- 按主列表、普通组、规则目标、全局组顺序合成；游戏策略处理额外字段。
function Selection.compose(config, selected, targets, result, policy)
    local function merge_selected(owner, name)
        if not name or name == "" or not (owner.presets and owner.presets[name]) then
            name = owner.default_preset
        end
        local preset = name and name ~= "" and owner.presets and owner.presets[name]
        if preset then policy.merge_into(result, preset) end
    end
    merge_selected(config, selected[""])
    for name, group in pairs(config.groups or {}) do
        if not group.is_global then merge_selected(group, selected[name]) end
    end
    if targets and config.groups then
        for name, preset_name in pairs(targets) do
            local owner = name == "" and config or config.groups[name]
            if owner and (name == "" or not owner.is_global) then
                local preset = preset_name and preset_name ~= "" and owner.presets and owner.presets[preset_name]
                if preset then policy.merge_into(result, preset) end
            end
        end
    end
    return Selection.merge_globals(config, selected, result, policy)
end

return Selection
