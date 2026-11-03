local Engine = {}

-- 按已经排好的规则顺序合成；游戏策略负责高度、全局组等特殊语义。
function Engine.apply_targets(config, rules, output, merge_target, record_unresolved)
    local targets = {}
    for _, rule in ipairs(rules) do
        for _, target in ipairs(rule and rule.targets or {}) do
            local group, name = target.group or "", target.preset
            if name and name ~= "None" then
                local owner = group == "" and config or config.groups and config.groups[group]
                local preset = owner and owner.presets and owner.presets[name]
                if preset then output = merge_target(output, preset, owner, config) end
                if preset or record_unresolved then targets[group] = name end
            end
        end
    end
    return output, targets
end

return Engine
