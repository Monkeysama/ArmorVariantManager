-- 使用真实 HP 模块与反射替身验证测试操作的返回值，不依赖游戏 SDK。
local root = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/"

local function method(call, return_type)
    return { call = call, get_return_type = function() return return_type end }
end

local function type_definition(methods)
    return { get_method = function(_, name) return methods[name] end }
end

local function fixture(kind)
    local hp = assert(loadfile(root .. "Games/Wilds/Conditions/Condition_HP.lua"))()
    local value = { hp = 150, max_hp = 200, writes = {} }
    local methods = {}
    local suffix = kind == "HitPoint" and "HitPoint" or "Health"
    methods["get_" .. suffix] = method(function(_, target)
        if target.hp_error then error(target.hp_error, 0) end
        return target.hp
    end)
    methods["get_Max" .. suffix] = method(function(_, target)
        if target.max_error then error(target.max_error, 0) end
        return target.max_hp
    end)
    methods["set_" .. suffix] = method(function(_, target, new_hp)
        if target.set_error then error(target.set_error, 0) end
        target.writes[#target.writes + 1] = new_hp
        target.hp = new_hp
        -- 游戏的 void setter 正常返回 nil。
    end)
    local character, character_methods
    if kind == "nested" then
        local manager_type = type_definition(methods)
        local hunter_type = type_definition({ get_HealthMgr = method(function(_, target)
            if target.manager_error then error(target.manager_error, 0) end
            return target.manager
        end, manager_type) })
        character_methods = { get_HunterHealth = method(function(_, target)
            if target.hunter_error then error(target.hunter_error, 0) end
            return target.hunter
        end, hunter_type) }
        character = { hunter = { manager = value } }
    else
        character, character_methods = value, methods
    end
    local character_type = type_definition(character_methods)
    function character:get_type_definition() return character_type end
    return hp, character, value, methods
end

local function succeeded(label, ok, reason)
    assert(ok == true, label .. ": " .. tostring(reason or ok))
    assert(reason == nil, label .. ": unexpected reason " .. tostring(reason))
end

local function failed(label, ok, reason)
    assert(ok == false, label .. ": expected false, got " .. tostring(ok))
    assert(type(reason) == "string" and reason ~= "", label .. ": missing failure reason")
    return reason
end

for _, kind in ipairs({ "HitPoint", "Health", "nested" }) do
    local cold_hp, cold_character, cold_value = fixture(kind)
    succeeded(kind .. " initialize by percent setter", cold_hp.set_state(cold_character, 50))
    assert(cold_value.hp == 100 and cold_hp.is_initialized())
    local hp, character, value = fixture(kind)
    assert(hp.id == "hp" and not hp.is_initialized())
    assert(hp.get_hp(character) == 150 and hp.get_state(character) == 75)
    assert(hp.is_initialized())
    succeeded(kind .. " absolute", hp.set_hp(character, 80.0))
    assert(value.hp == 80.0 and value.writes[1] == 80.0)
    assert(math.type(value.writes[1]) == "float", "Absolute setter preserves its argument type")
    succeeded(kind .. " percent", hp.set_state(character, 25))
    assert(value.hp == 50 and math.type(value.writes[2]) == "float")
    succeeded(kind .. " zero percent", hp.set_state(character, 0))
    assert(value.hp == 0)

    local high, low = { threshold = 60 }, { threshold = 20 }
    local config = { transform_rules = { high, low } }
    value.hp = 40
    local rule, percent = hp.evaluate(config, character, "local")
    assert(rule == low and percent == 20, "Lowest inclusive threshold wins")
    value.hp = 42
    assert(hp.evaluate(config, character, "local") == high)
    value.hp = 200
    rule, percent = hp.evaluate(config, character, "local")
    assert(rule == nil and percent == 100)
    assert(config.transform_rules[1] == high and config.transform_rules[2] == low,
        "Evaluation must not reorder configured rules")

    value.set_error = kind .. " setter failed"
    assert(failed(kind .. " setter error", hp.set_hp(character, 90)) == value.set_error)
    assert(failed(kind .. " percent setter error", hp.set_state(character, 50)) == value.set_error)
    value.set_error = nil
    value.max_error = kind .. " maximum read failed"
    assert(failed(kind .. " maximum error", hp.set_state(character, 50)) == value.max_error)
    assert(hp.get_state(character) == nil)
    succeeded(kind .. " absolute without max read", hp.set_hp(character, 90))
    value.max_error = nil
    for _, invalid in ipairs({ 0, -1, "unavailable", false }) do
        value.max_hp = invalid
        failed(kind .. " invalid maximum", hp.set_state(character, 50))
        assert(hp.get_state(character) == nil)
    end
    value.max_hp = nil
    failed(kind .. " missing maximum", hp.set_state(character, 50))
    assert(hp.get_state(character) == nil)
    succeeded(kind .. " absolute without maximum", hp.set_hp(character, 30))

    hp, character, value = fixture(kind)
    value.hp_error = kind .. " current read failed"
    assert(hp.get_hp(character) == nil and hp.get_state(character) == nil)
    succeeded(kind .. " setter without current read", hp.set_hp(character, 30))

    local methods
    hp, character, value, methods = fixture(kind)
    methods[kind == "HitPoint" and "set_HitPoint" or "set_Health"] = nil
    failed(kind .. " missing setter", hp.set_hp(character, 90))
    failed(kind .. " missing percent setter", hp.set_state(character, 50))
    assert(hp.get_hp(character) == 150 and hp.get_state(character) == 75,
        "A missing setter must not disable existing reads")
end

local hp = assert(loadfile(root .. "Games/Wilds/Conditions/Condition_HP.lua"))()
failed("missing character", hp.set_hp(nil, 20))
failed("missing percent character", hp.set_state(nil, 20))
assert(hp.get_hp(nil) == nil and hp.get_state(nil) == nil)
for _, character in ipairs({
    { get_type_definition = function() return nil end },
    { get_type_definition = function() return type_definition({}) end },
}) do
    failed("missing reflection", hp.set_hp(character, 20))
    failed("missing percent reflection", hp.set_state(character, 20))
end
local broken = { get_type_definition = function() error("reflection failed", 0) end }
assert(failed("reflection error", hp.set_hp(broken, 20)) == "reflection failed")
assert(failed("percent reflection error", hp.set_state(broken, 20)) == "reflection failed")

for _, missing in ipairs({ "HunterHealth", "HealthMgr" }) do
    local character
    hp, character = fixture("nested")
    if missing == "HunterHealth" then character.hunter = nil else character.hunter.manager = nil end
    assert(failed("missing " .. missing, hp.set_hp(character, 20)):find(missing, 1, true))
    assert(failed("missing percent " .. missing, hp.set_state(character, 20)):find(missing, 1, true))
    assert(hp.get_hp(character) == 0 and hp.get_state(character) == nil,
        "Missing nested objects retain the existing read results")
end
for _, failing in ipairs({ "hunter", "manager" }) do
    local character
    hp, character = fixture("nested")
    if failing == "hunter" then character.hunter_error = "hunter read failed"
    else character.hunter.manager_error = "manager read failed" end
    local expected = failing .. " read failed"
    assert(failed(failing .. " error", hp.set_hp(character, 20)) == expected)
    assert(failed(failing .. " percent error", hp.set_state(character, 20)) == expected)
end

-- 旧条件入口仍返回同一模块，调用参数与结果不经过转换。
local env = { require = function(name)
    assert(name == "ArmorVariantManager_Core.Games.Wilds.Conditions.Condition_HP")
    return hp
end }
assert(assert(loadfile(root .. "Conditions/Condition_HP.lua", "t", env))() == hp)

print("PASS: Wilds HP reflection paths, truthful setter results, failure reasons and legacy reads/thresholds")
