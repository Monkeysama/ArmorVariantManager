-- Frozen from MHR 093c61c.
-- Configuration work happens once per config revision. Effective rule IDs,
-- rather than continuously varying raw state, identify composed appearances.
local Plan = {}
local cache=setmetatable({}, {__mode='k'})
local fields={weapon='state',scroll='state',monster_hp='threshold',longsword='level',
    dual_blades='state',switch_axe='state',charge_axe='state',greatsword_level='level',
    hammer='level',bow='level'}
function Plan.invalidate(config)
    if config then cache[config]=nil else cache=setmetatable({}, {__mode='k'}) end
end
function Plan.get(config, registry)
    if cache[config] then return cache[config] end
    local result={conditions={},all_groups={},globals={}}
    local function add(kind,priority)
        if not registry[kind] then return end
        local condition={kind=kind,priority=priority or 1,by_value={},rules={},ids={}}
        for index,rule in ipairs(config[kind..'_transform_rules'] or {}) do
            condition.rules[#condition.rules+1]=rule;condition.ids[rule]=index
            local value=rule[fields[kind]]
            if value~=nil and not condition.by_value[value] then condition.by_value[value]=rule end
            for _,target in ipairs(rule.targets or {}) do result.all_groups[target.group or '']=true end
        end
        if kind=='monster_hp' then
            table.sort(condition.rules,function(a,b)
                if a.threshold==b.threshold then return condition.ids[a]<condition.ids[b] end
                return a.threshold<b.threshold
            end)
        end
        result.conditions[#result.conditions+1]=condition
    end
    if config.is_parallel then
        for kind,setting in pairs(config.parallel_settings or {}) do
            if setting.enabled then add(kind,setting.priority) end
        end
    else add(config.transform_type,1) end
    table.sort(result.conditions,function(a,b)
        if a.priority==b.priority then return a.kind<b.kind end
        return a.priority>b.priority
    end)
    for group,data in pairs(config.groups or {}) do
        if data.is_global then result.globals[#result.globals+1]={name=group,data=data} end
    end
    cache[config]=result
    return result
end
function Plan.select(condition,state)
    if state==nil then return nil end
    if condition.kind=='weapon' then state=state and 'drawn' or 'sheathed' end
    if condition.kind=='monster_hp' then
        for _,rule in ipairs(condition.rules) do if state<=rule.threshold then return rule end end
        return nil
    end
    return condition.by_value[state]
end
return Plan
