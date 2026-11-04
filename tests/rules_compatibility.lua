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

-- 只替换 SDK 信号读取；规则规划、优先级和角色缓存执行正式模块。
local function host(game)
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
        loaded[name] = assert(loadfile(path, "t", env))()
        return loaded[name]
    end
    local path = root .. "ArmorVariantManager_Core/Games/" .. game .. "/Rules.lua"
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

local wilds=host("Wilds")
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
local function check_wilds(actor,signals,show,height,names,changed,affected)
    states[actor]=signals
    local result=table.pack(wilds.apply_transform_rules(actor,config,actor,base,wp.merge))
    S.equal(result[1],preset(show,height),"Wilds "..actor)
    assert(result[2]==changed,"Wilds changed "..actor)
    S.equal(result[3],names)
    S.equal(result[4],affected or {[""]=true,global=true})
    S.equal(base,preset(true,8),"manual baseline unchanged")
    return result
end
local samples={
    {signals={hp=20,weapon=true,spirit=1,weapon_type=3},show=true,height=0,names={[""]="show",global="hide"}},
    {signals={hp=20,weapon=false,spirit=1,weapon_type=3},show=false,height=17,names={[""]="hide",global="hide"}},
    {signals={hp=false,weapon=false,spirit=1,weapon_type=0},show=true,height=8,names={}},
    {signals={},show=true,height=8,names={}},
}
for index,sample in ipairs(samples) do
    check_wilds("A",sample.signals,sample.show,sample.height,sample.names,true)
    check_wilds("B",{hp=80,weapon=true,weapon_type=0},true,0,{[""]="show"},index==1)
    check_wilds("A",sample.signals,sample.show,sample.height,sample.names,false)
end
S.equal(config,original)
check_wilds("A",{hp=10,weapon=true},true,0,{[""]="show"},true)
config.weapon_transform_rules[1].targets[2]={group="removed",preset="missing"}
wilds.refresh_config_rules(config); wilds.clear_last_state_cache()
check_wilds("A",{hp=10,weapon=true},true,0,{[""]="show",removed="missing"},true,
    {[""]=true,global=true,removed=true})
config.is_parallel,config.transform_type=false,"spirit"
wilds.refresh_config_rules(config)
check_wilds("A",{spirit=2,weapon_type=3},false,8,{global="hide"},true,{[""]=true,global=true,removed=true})
check_wilds("A",{spirit=2,weapon_type=0},true,8,{},true,{[""]=true,global=true,removed=true})
print("PASS: Wilds priority, checked zero, actor changes and target rollback")

local rise=host("Rise")

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
local outputs={}
local function check_rise(actor,signals,show,names,changed,context,affected)
    context=context or "armor_shared"
    states[actor]=signals
    local previous=outputs[actor..context] or base
    local result=table.pack(rise.apply_transform_rules(actor,context,config,"GO",previous,rp.merge,actor))
    outputs[actor..context]=result[1]
    S.equal(result[1],preset(show),"Rise "..actor)
    assert(result[2]==changed,"Rise changed "..actor)
    S.equal(result[3],names)
    S.equal(result[4],affected or {[""]=true,global=true})
    return result
end
local samples={
    {signals={weapon=true,scroll="red",monster_hp=15},show=false,names={[""]="hide",global="hide"},changed=true},
    {signals={weapon=false,scroll="blue",monster_hp=50},show=true,names={[""]="show",global="show"},changed=true},
    {signals={monster_hp=90},show=true,names={},changed=true},
    {signals={},show=true,names={},changed=false},
}
for index,sample in ipairs(samples) do
    check_rise("A",sample.signals,sample.show,sample.names,sample.changed)
    check_rise("B",{weapon=true,scroll="blue"},false,{[""]="hide",global="show"},index==1)
    check_rise("A",sample.signals,sample.show,sample.names,false)
end
S.equal(config,original)
check_rise("A",{weapon=false},true,{[""]="show"},true,"weapon_other")
check_rise("T",{monster_hp=50},true,{[""]="show"},true)
check_rise("T",{monster_hp=15},false,{[""]="hide"},true)
check_rise("T",{monster_hp=90},true,{},true)
config.scroll_transform_rules[1].targets={{group="missing",preset="gone"}}
rise.invalidate_config("shared",config)
local affected={[""]=true,global=true,missing=true}
check_rise("A",{scroll="red",weapon=false},true,{[""]="show"},true,nil,affected)
config.parallel_settings.scroll.priority=2
config.weapon_transform_rules[3]=node("","hide","sheathed")
rise.clear_cache(nil,nil,true)
rise.update_base_preset("shared",config,"","show",rp.merge)
check_rise("A",{weapon=false,scroll="blue",monster_hp=20},true,{[""]="show",global="show"},true,nil,affected)
rise.forget_actor("A")
check_rise("A",{weapon=true,scroll="red"},false,{[""]="hide"},true,nil,affected)
print("PASS: Rise thresholds, globals, actor/context caches and invalidation")

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
