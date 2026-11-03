local Plan = {}

-- 编译配置一次，信号取值与字段映射由游戏适配层提供。
function Plan.new(definitions)
    local cache = setmetatable({}, { __mode = "k" })
    local instance = {}

    function instance.invalidate(config)
        if config then cache[config] = nil else cache = setmetatable({}, { __mode = "k" }) end
    end

    function instance.get(config, registry)
        if cache[config] then return cache[config] end
        local result = { conditions = {}, all_groups = {}, globals = {} }
        local function add(kind, priority)
            if not registry[kind] then return end
            local definition = definitions[kind]
            local condition = { kind = kind, priority = priority or 1, by_value = {}, rules = {}, ids = {},
                definition = definition }
            for index, rule in ipairs(config[definition.field] or {}) do
                condition.rules[#condition.rules + 1] = rule
                condition.ids[rule] = index
                local value = rule[definition.value]
                if value ~= nil and not condition.by_value[value] then condition.by_value[value] = rule end
                for _, target in ipairs(rule.targets or {}) do result.all_groups[target.group or ""] = true end
            end
            if definition.threshold then
                table.sort(condition.rules, function(a, b)
                    if a[definition.value] == b[definition.value] then return condition.ids[a] < condition.ids[b] end
                    return a[definition.value] < b[definition.value]
                end)
            end
            result.conditions[#result.conditions + 1] = condition
        end
        if config.is_parallel then
            for kind, setting in pairs(config.parallel_settings or {}) do
                if setting.enabled then add(kind, setting.priority) end
            end
        else add(config.transform_type, 1) end
        table.sort(result.conditions, function(a, b)
            if a.priority == b.priority then return a.kind < b.kind end
            return a.priority > b.priority
        end)
        for group, data in pairs(config.groups or {}) do
            if data.is_global then result.globals[#result.globals + 1] = { name = group, data = data } end
        end
        cache[config] = result
        return result
    end

    function instance.select(condition, state)
        if state == nil then return nil end
        local definition = condition.definition
        if definition.normalize then state = definition.normalize(state) end
        if definition.threshold then
            for _, rule in ipairs(condition.rules) do
                if state <= rule[definition.value] then return rule end
            end
            return nil
        end
        return condition.by_value[state]
    end
    return instance
end

return Plan
