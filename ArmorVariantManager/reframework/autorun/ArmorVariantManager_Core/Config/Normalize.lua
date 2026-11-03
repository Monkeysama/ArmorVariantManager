local Normalize = {}

-- 只补齐共享容器，游戏字段及旧版本转换交给对应配置规则。
function Normalize.apply(data, schema)
    if not data.presets then data.presets = {} end
    if not data.default_preset then data.default_preset = "" end
    if not data.groups then data.groups = {} end
    if not data.group_order then data.group_order = {} end
    if not data.preset_order then data.preset_order = {} end
    for _, group in pairs(data.groups) do
        if not group.preset_order then group.preset_order = {} end
    end
    schema.normalize(data)
    return data
end

-- 每次创建独立节点，避免不同装备共享 targets 或编辑状态。
function Normalize.rule_nodes(key, values)
    local rules = {}
    for _, value in ipairs(values) do
        rules[#rules + 1] = { [key] = value, targets = {} }
    end
    return rules
end

-- 崛起仅补 nil，荒野沿用旧入口对 nil/false 的补齐语义。
function Normalize.rules(data, definitions, nil_only)
    for field, definition in pairs(definitions) do
        if data[field] == nil or (not nil_only and not data[field]) then
            data[field] = Normalize.rule_nodes(definition.key, definition.values)
        end
    end
end

return Normalize
