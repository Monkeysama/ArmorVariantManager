local M = {}
M.id = "hp"
local hp_reflection_initialized = false
local hp_getter = nil
local max_hp_getter = nil
local hp_setter = nil
local function init_hp_reflection(character)
    if hp_reflection_initialized then return end
    local type_def = character:get_type_definition()
    if not type_def then return end
    if type_def:get_method("get_HitPoint") and type_def:get_method("get_MaxHitPoint") then
        hp_getter = type_def:get_method("get_HitPoint")
        max_hp_getter = type_def:get_method("get_MaxHitPoint")
        hp_setter = type_def:get_method("set_HitPoint")
        hp_reflection_initialized = true
        return
    end
    if type_def:get_method("get_Health") and type_def:get_method("get_MaxHealth") then
        hp_getter = type_def:get_method("get_Health")
        max_hp_getter = type_def:get_method("get_MaxHealth")
        hp_setter = type_def:get_method("set_Health")
        hp_reflection_initialized = true
        return
    end
    if type_def:get_method("get_HunterHealth") then
        local get_hunter_health = type_def:get_method("get_HunterHealth")
        if get_hunter_health then
            local health_type = get_hunter_health:get_return_type()
            if health_type then
                local get_health_mgr = health_type:get_method("get_HealthMgr")
                if get_health_mgr then
                    local mgr_type = get_health_mgr:get_return_type()
                    if mgr_type then
                        local getter = mgr_type:get_method("get_Health")
                        local max_getter = mgr_type:get_method("get_MaxHealth")
                        local setter = mgr_type:get_method("set_Health")
                        if getter and max_getter then
                            hp_getter = { call = function(_, target)
                                local hunter_health = get_hunter_health:call(target)
                                if not hunter_health then return 0 end
                                local health_mgr = get_health_mgr:call(hunter_health)
                                if not health_mgr then return 0 end
                                return getter:call(health_mgr)
                            end }
                            max_hp_getter = { call = function(_, target)
                                local hunter_health = get_hunter_health:call(target)
                                if not hunter_health then return 0 end
                                local health_mgr = get_health_mgr:call(hunter_health)
                                if not health_mgr then return 0 end
                                return max_getter:call(health_mgr)
                            end }
                            if setter then
                                hp_setter = { call = function(_, target, value)
                                    local hunter_health = get_hunter_health:call(target)
                                    if not hunter_health then return end
                                    local health_mgr = get_health_mgr:call(hunter_health)
                                    if not health_mgr then return end
                                    setter:call(health_mgr, value)
                                end }
                            end
                            hp_reflection_initialized = true
                            return
                        end
                    end
                end
            end
        end
    end
end
function M.get_hp(character)
    if not character then return nil end
    if not hp_reflection_initialized then init_hp_reflection(character) end
    if not hp_getter then return nil end
    local ok, hp = pcall(function() return hp_getter:call(character) end)
    if ok and type(hp) == "number" then
        return hp
    end
    return nil
end
function M.set_hp(character, target_hp)
    if not character then return end
    if not hp_reflection_initialized then init_hp_reflection(character) end
    if not hp_setter then return end
    pcall(function() hp_setter:call(character, target_hp) end)
end
function M.get_state(character)
    if not character then return nil end
    if not hp_reflection_initialized then init_hp_reflection(character) end
    if not hp_getter or not max_hp_getter then return nil end
    local ok1, hp = pcall(function() return hp_getter:call(character) end)
    local ok2, max_hp = pcall(function() return max_hp_getter:call(character) end)
    if ok1 and ok2 and type(hp) == "number" and type(max_hp) == "number" and max_hp > 0 then
        return (hp / max_hp) * 100
    end
    return nil
end
function M.set_state(character, percent)
    if not character then return end
    if not hp_reflection_initialized then init_hp_reflection(character) end
    if not hp_setter or not max_hp_getter then return end
    local ok, max_hp = pcall(function() return max_hp_getter:call(character) end)
    if ok and type(max_hp) == "number" and max_hp > 0 then
        local target_hp = (percent / 100) * max_hp
        pcall(function() hp_setter:call(character, target_hp) end)
    end
end
local function get_active_hp_rule(rules, cur_hp)
    if not rules or #rules == 0 then return nil end
    local sorted_rules = {}
    for _, r in ipairs(rules) do table.insert(sorted_rules, r) end
    table.sort(sorted_rules, function(a, b) return a.threshold < b.threshold end)
    for _, r in ipairs(sorted_rules) do
        if cur_hp <= r.threshold then
            return r
        end
    end
    return nil
end
function M.evaluate(config, character, char_addr)
    local cur_hp = M.get_state(character)
    local rules = config.transform_rules
    if cur_hp ~= nil and rules then
        local rule = get_active_hp_rule(rules, cur_hp)
        return rule, cur_hp
    end
    return nil, cur_hp
end
function M.is_initialized()
    return hp_reflection_initialized
end
return M
