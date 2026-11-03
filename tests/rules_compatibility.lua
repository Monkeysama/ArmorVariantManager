package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local root = "ArmorVariantManager/reframework/autorun/"
local prefix = "ArmorVariantManager_Core."
local states = {}
local names = { HP = "hp", Damage = "damage", Weapon = "weapon", LongSword = "spirit",
    DualBlades = "dual_blades", SwitchAxe = "switch_axe", InsectGlaive = "insect_glaive",
    ChargeBlade = "charge_blade", GreatSwordType = "greatsword_type", GreatSwordLevel = "greatsword_level",
    BowLevel = "bow_level", HammerLevel = "hammer_level", Scroll = "scroll", ChargeAxe = "charge_axe",
    Bow = "bow", Hammer = "hammer", MonsterHP = "monster_hp" }

-- 只替换 SDK 信号读取，执行两分支的原规则与当前规则；模块缓存分别隔离。
local function host(game, legacy)
    local loaded = {}
    local env = setmetatable({}, { __index = _G })
    env.require = function(name)
        local condition = name:match("Conditions%.Condition_(.+)$")
        if condition then
            local kind = condition == "LongSword" and game == "Rise" and "longsword" or names[condition]
            return {
                get_state = function(actor) return states[actor] and states[actor][kind] end,
                evaluate = function(config, actor)
                    local state = states[actor] and states[actor][kind]
                    local field = kind == "hp" and "transform_rules" or kind .. "_transform_rules"
                    return state ~= nil and state ~= false and config[field][1] or nil, state
                end,
            }
        end
        if name == prefix .. "Utils" or name == prefix .. "Games.Rise.Signals" then
            return { sample_condition = function(kind, handler, actor, player)
                return handler.get_state(player or actor)
            end }
        end
        if loaded[name] then return loaded[name] end
        local path = root .. name:gsub("%.", "/") .. ".lua"
        if name == prefix .. "RulePlan" then path = "tests/fixtures/legacy/rise_rule_plan.lua" end
        loaded[name] = assert(loadfile(path, "t", env))()
        return loaded[name]
    end
    local path = legacy and "tests/fixtures/legacy/" .. game:lower() .. "_rules.lua"
        or root .. "ArmorVariantManager_Core/Games/" .. game .. "/Rules.lua"
    local result = assert(loadfile(path, "t", env))()
    if game == "Wilds" then result.get_character_weapon_type = function(actor) return states[actor].weapon_type end end
    return result
end

local function preset(show, height)
    local result = { ["0"] = { mesh_enabled = true, materials = { cape = show, buckle = true } } }
    if height ~= nil then result.ground_clipping_fix = { enabled = true, height_cm = height } end
    return result
end
local function node(group, name, state)
    return { state = state, targets = { { group = group, preset = name } } }
end

local wilds_old, wilds = host("Wilds", true), host("Wilds", false)
local wp = require(prefix .. "Games.Wilds.Presets")
local config = { is_parallel = true, parallel_settings = { hp = { enabled = true, priority = 2 },
    weapon = { enabled = true, priority = 1 }, spirit = { enabled = true, priority = 3 } },
    presets = { hide = preset(false, 17), show = preset(true, 0) },
    groups = { global = { is_global = true, presets = { hide = preset(false) } } },
    transform_rules = { node("", "hide") }, weapon_transform_rules = { node("", "show") },
    spirit_transform_rules = { node("global", "hide") } }
config = require(prefix .. "Config.Normalize").apply(config, require(prefix .. "Games.Wilds.Config"))
local base = preset(true, 8)
local original = S.copy(config)
local function wilds_compare(actor, current)
    states[actor] = current
    local before = S.copy(base)
    local expected = table.pack(wilds_old.apply_transform_rules(actor, config, actor, base, wp.merge))
    local actual = table.pack(wilds.apply_transform_rules(actor, config, actor, base, wp.merge))
    S.equal(actual, expected, "wilds." .. actor)
    S.equal(base, before, "wilds.manual")
    return actual
end
for _, values in ipairs({ { hp = 20, weapon = true, spirit = 1, weapon_type = 3 },
    { hp = 20, weapon = false, spirit = 1, weapon_type = 3 },
    { hp = false, weapon = false, spirit = 1, weapon_type = 0 }, {} }) do
    wilds_compare("A", values)
    wilds_compare("B", { hp = 80, weapon = true, weapon_type = 0 })
    wilds_compare("A", values) -- 相同配置多角色与重复状态的 changed 标志。
end
S.equal(config, original, "wilds.config")
local value = wilds_compare("A", { hp = 10, weapon = true })
assert(value[1].ground_clipping_fix.height_cm == 0, "Higher priority checked zero wins")
config.weapon_transform_rules[1].targets[#config.weapon_transform_rules[1].targets + 1] =
    { group = "removed", preset = "missing" }
for _, engine in ipairs({ wilds_old, wilds }) do engine.refresh_config_rules(config); engine.clear_last_state_cache() end
value = wilds_compare("A", { hp = 10, weapon = true })
assert(value[3].removed == "missing", "Wilds preserves unresolved activated names")
config.is_parallel, config.transform_type = false, "spirit"
for _, engine in ipairs({ wilds_old, wilds }) do engine.refresh_config_rules(config) end
wilds_compare("A", { spirit = 2, weapon_type = 3 })
wilds_compare("A", { spirit = 2, weapon_type = 0 })
print("PASS: Wilds legacy rule output, priorities, height, state changes and target rollback")

local rise_old, rise = host("Rise", true), host("Rise", false)
local rp = require(prefix .. "Games.Rise.Presets")
config = { is_parallel = true, is_global = true, parallel_settings = {
        weapon = { enabled = true, priority = 2 }, scroll = { enabled = true, priority = 1 },
        monster_hp = { enabled = true, priority = 3 } },
    presets = { hide = preset(false), show = preset(true) },
    groups = { global = { is_global = true, default_preset = "show",
        presets = { hide = preset(false), show = preset(true) } } },
    weapon_transform_rules = { node("", "hide", "drawn"), node("", "show", "sheathed") },
    scroll_transform_rules = { node("global", "hide", "red"), node("global", "show", "blue") },
    monster_hp_transform_rules = { { threshold = 70, targets = { { group = "", preset = "show" } } },
        { threshold = 20, targets = { { group = "", preset = "hide" } } } } }
base = preset(true)
original = S.copy(config)
local outputs = { {}, {} }
local function rise_compare(actor, current, context)
    context = context or "armor_shared"
    states[actor] = current
    local results = {}
    for index, engine in ipairs({ rise_old, rise }) do
        local previous = outputs[index][actor .. context] or base
        results[index] = table.pack(engine.apply_transform_rules(actor, context, config, "GO", previous, rp.merge, actor))
        outputs[index][actor .. context] = results[index][1]
    end
    S.equal(results[2], results[1], "rise." .. actor)
    return results[2]
end
for _, values in ipairs({ { weapon = true, scroll = "red", monster_hp = 15 },
    { weapon = false, scroll = "blue", monster_hp = 50 }, { monster_hp = 90 }, {} }) do
    rise_compare("A", values)
    rise_compare("B", { weapon = true, scroll = "blue" })
    rise_compare("A", values)
end
S.equal(config, original, "rise.config")
rise_compare("A", { weapon = false }, "weapon_other")
config.scroll_transform_rules[1].targets = { { group = "missing", preset = "gone" } }
for _, engine in ipairs({ rise_old, rise }) do engine.invalidate_config("shared", config) end
value = rise_compare("A", { scroll = "red", weapon = false })
assert(value[3].missing == nil, "Rise only records existing preset targets")
-- 同优先级按类型排序；相同数值的重复节点保留首个，阈值取最严格的命中项。
config.parallel_settings.scroll.priority = 2
config.weapon_transform_rules[3] = node("", "hide", "sheathed")
for _, engine in ipairs({ rise_old, rise }) do
    engine.clear_cache(nil, nil, true)
    engine.update_base_preset("shared", config, "", "show", rp.merge)
end
rise_compare("A", { weapon = false, scroll = "blue", monster_hp = 20 })
for _, engine in ipairs({ rise_old, rise }) do engine.forget_actor("A") end
rise_compare("A", { weapon = true, scroll = "red" })
print("PASS: Rise legacy thresholds, globals, same-model cache, invalidation and context separation")

-- 迁移后的真实取值模块：保留 Player/GO 解析、队友参数与每帧采样缓存。
local function player(id, weapon)
    local actor = { fields = { _playerWeaponType = weapon }, drawn = false, go = {} }
    function actor:get_field(name) return self.fields[name] end
    function actor:isWeaponOn() return self.drawn end
    function actor:call(method)
        if method == "getPlayerIndex" then return id end
        if method == "get_GameObject" then return self.go end
        if method == "get_ChargeLv" then return 2 end
        if method == "get_Mode" then return 0 end
        error(method)
    end
    return actor
end
local master, remote = player(0, 2), player(1, 2)
master.fields._LongSwordGaugeLv, remote.fields._LongSwordGaugeLv = 1, 3
local signal_env = setmetatable({ sdk = { get_managed_singleton = function(name)
    assert(name == "snow.player.PlayerManager")
    return { call = function() return master end }
end } }, { __index = _G })
signal_env.require = function(name)
    assert(name == prefix .. "Games.Rise.SceneObject")
    return { is_alive = function(obj) return obj ~= nil end, call = function(obj, method, ...) return obj:call(method, ...) end }
end
local signals = assert(loadfile(root .. "ArmorVariantManager_Core/Games/Rise/Signals.lua", "t", signal_env))()
local function condition(name)
    local env = setmetatable({ require = function(path)
        assert(path == prefix .. "Games.Rise.Signals")
        return signals
    end }, { __index = _G })
    return assert(loadfile(root .. "ArmorVariantManager_Core/Games/Rise/Conditions/Condition_" .. name .. ".lua", "t", env))()
end
local longsword, weapon, scroll = condition("LongSword"), condition("Weapon"), condition("Scroll")
signals.begin_frame(1)
signals.bind_actor(remote, remote.go)
assert(signals.sample_condition("longsword", longsword, remote.go, remote) == 3)
assert(signals.sample_condition("longsword", longsword, master.go, master) == 1)
remote.fields._LongSwordGaugeLv = 2
assert(signals.sample_condition("longsword", longsword, remote.go, remote) == 3, "One sample per frame")
assert(signals.sample_condition("weapon", weapon, remote.go, remote) == false, "False must be cached")
assert(scroll.get_state(remote) == nil, "Remote actor must not read local scroll HUD")
signals.begin_frame(2)
assert(signals.sample_condition("longsword", longsword, remote.go, remote) == 2)
for _, item in ipairs({ { "DualBlades", 9, 0 }, { "SwitchAxe", 1, 0 }, { "ChargeAxe", 11, 1 },
    { "GreatSwordLevel", 0, 0 }, { "Hammer", 5, 0 }, { "Bow", 13, 2 } }) do
    signals.invalidate_samples()
    remote.fields._playerWeaponType = item[2]
    assert(condition(item[1]).get_state(remote) == item[3], item[1] .. " migrated state reader")
end
signals.invalidate_samples()
remote.fields._playerWeaponType = 3
assert(longsword.get_state(remote) == nil, "Wilds longsword enum must not activate Rise longsword")
print("PASS: real Rise condition readers, actor routing, false values and frame cache")
