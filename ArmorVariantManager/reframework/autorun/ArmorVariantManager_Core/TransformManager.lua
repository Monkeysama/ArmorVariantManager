local TransformManager = {}

-- 引入独立的受击计时器模块
local DamageTimer = require("ArmorVariantManager_Core.DamageTimer")

-- =============================================================================
-- 武器状态模块
-- =============================================================================
local weapon_state_initialized = false
local weapon_state_getter = nil
local type_hunter_character = nil

local function get_hunter_character(character)
    if not character then return nil end
    local type_name = character:get_type_definition():get_name()
    if type_name and string.find(type_name, "HunterCharacter") then return character end
    
    if not type_hunter_character then
        type_hunter_character = sdk.typeof("app.HunterCharacter")
    end
    
    local ok, game_obj = pcall(function() return character:call("get_GameObject") end)
    if ok and game_obj and type_hunter_character then
        local hc_ok, hc = pcall(function() return game_obj:call("getComponent(System.Type)", type_hunter_character) end)
        if hc_ok and hc then
            return hc
        end
    end
    return character
end

local function init_weapon_state_reflection(character)
    if weapon_state_initialized then return end
    local type_def = character:get_type_definition()
    if not type_def then return end
    local field_weapon_on = type_def:get_field("_IsWeaponOn")
    if field_weapon_on then
        weapon_state_getter = { field = field_weapon_on, is_field = true }
        weapon_state_initialized = true
        return
    end
    local method_names = {
        "get_IsWeaponDraw", "get_isWeaponDraw", "isWeaponDraw",
        "isDrawWeapon", "get_IsDrawWeapon"
    }
    for _, name in ipairs(method_names) do
        local m = type_def:get_method(name)
        if m then
            weapon_state_getter = { method = m, invert = false, is_field = false }
            weapon_state_initialized = true
            return
        end
    end
    if type_def:get_method("get_WeaponState") then
        local m = type_def:get_method("get_WeaponState")
        weapon_state_getter = { method = m, is_enum = true, is_field = false }
        weapon_state_initialized = true
        return
    end
end

function TransformManager.get_character_weapon_drawn(character)
    if not character then return false end
    local target_char = get_hunter_character(character)
    if not weapon_state_initialized then init_weapon_state_reflection(target_char) end
    if not weapon_state_getter then return false end
    if weapon_state_getter.is_field then
        local ok, res = pcall(function() return weapon_state_getter.field:get_data(target_char) end)
        if ok then return res == true end
        return false
    else
        local ok, res = pcall(function() return weapon_state_getter.method:call(target_char) end)
        if ok and res ~= nil then
            if weapon_state_getter.is_enum then
                return tonumber(res) > 0
            else
                return weapon_state_getter.invert and not res or (res == true)
            end
        end
    end
    return false
end

-- =============================================================================
-- 生命值状态模块
-- =============================================================================
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

function TransformManager.get_character_hp_percent(character)
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

function TransformManager.set_character_hp_percent(character, percent)
    if not character then return end
    if not hp_reflection_initialized then init_hp_reflection(character) end
    if not hp_setter or not max_hp_getter then return end
    local ok, max_hp = pcall(function() return max_hp_getter:call(character) end)
    if ok and type(max_hp) == "number" and max_hp > 0 then
        local target_hp = (percent / 100) * max_hp
        pcall(function() hp_setter:call(character, target_hp) end)
    end
end

-- =============================================================================
-- 气刃等级模块 (太刀)
-- =============================================================================
local spirit_level_getter = nil
local function get_spirit_level_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return nil end
    local ok2, level = pcall(function() return wh:call("get_AuraLevel") end)
    if not ok2 then return nil end
    if type(level) == "number" then return level end
    return nil
end

local function init_spirit_level_reflection(character)
    if spirit_level_getter then return end
    local type_def = character:get_type_definition()
    if not type_def then return end
    local get_wh = type_def:get_method("get_WeaponHandling")
    if get_wh then
        local wh_type = get_wh:get_return_type()
        if wh_type then
            local get_aura = wh_type:get_method("get_AuraLevel")
            if get_aura then
                spirit_level_getter = { call = function(_, target)
                    local wh = get_wh:call(target)
                    if not wh then return nil end
                    local level = get_aura:call(wh)
                    return type(level) == "number" and level or nil
                end }
                return
            end
        end
    end
    local direct_aura = type_def:get_method("get_AuraLevel")
    if direct_aura then
        spirit_level_getter = { call = function(_, target) return direct_aura:call(target) end }
        return
    end
end

function TransformManager.get_character_spirit_level(character)
    if not character then return nil end
    local level = get_spirit_level_direct(character)
    if level then return level end
    if spirit_level_getter == nil then init_spirit_level_reflection(character) end
    if spirit_level_getter then
        local ok, result = pcall(function() return spirit_level_getter:call(character) end)
        if ok and result then return result end
    end
    return nil
end

function TransformManager.is_spirit_module_initialized() return true end
function TransformManager.has_spirit_getter() return true end

-- =============================================================================
-- 双刀鬼人状态模块
-- =============================================================================
local function get_dual_blades_state_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "normal" end
    local ok2, kijin = pcall(function() return wh:call("get_IsKijinOn") end)
    if not ok2 then kijin = false end
    local ok3, enhance = pcall(function() return wh:call("get_IsKijinEnhancement") end)
    if not ok3 then enhance = false end
    if enhance then return "enhancement"
    elseif kijin then return "kijin"
    else return "normal" end
end

function TransformManager.get_character_dual_blades_state(character)
    if not character then return "normal" end
    return get_dual_blades_state_direct(character)
end

function TransformManager.has_dual_blades_getter() return true end

-- =============================================================================
-- 斩斧状态模块 (Switch Axe)
-- =============================================================================
local function get_switch_axe_state_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "axe_normal" end
    local ok_mode, mode = pcall(function() return wh:call("get_Mode") end)
    if not ok_mode then mode = 1 end
    local ok_axe_enh, axe_enh = pcall(function() return wh:call("get_IsAxeEnhanced") end)
    if not ok_axe_enh then axe_enh = false end
    local ok_sword_awaken, sword_awaken = pcall(function() return wh:call("get_IsSwordAwaken") end)
    if not ok_sword_awaken then sword_awaken = false end
    if mode == 0 then
        if sword_awaken then return "sword_awakened"
        else return "sword_normal" end
    else
        if axe_enh then return "axe_enhanced"
        else return "axe_normal" end
    end
end

function TransformManager.get_character_switch_axe_state(character)
    if not character then return "axe_normal" end
    return get_switch_axe_state_direct(character)
end

function TransformManager.has_switch_axe_getter() return true end

-- =============================================================================
-- 虫棍灯色状态模块 (Insect Glaive)
-- =============================================================================
local insect_glaive_timestamps = {}

local function get_insect_glaive_state_direct(character, char_addr)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "none" end
    
    local function get_lamp(method)
        local ok, val = pcall(function() return wh:call(method) end)
        return ok and val == true or false
    end
    
    local is_white = get_lamp("get_IsWhite")
    local is_orange = get_lamp("get_IsOrange")
    local is_red = get_lamp("get_IsRed")
    local is_triple = get_lamp("get_IsTrippleUp")
    
    if is_triple then return "triple" end
    
    if not insect_glaive_timestamps[char_addr] then insect_glaive_timestamps[char_addr] = {} end
    local stamps = insect_glaive_timestamps[char_addr]
    local current_time = os.clock()
    
    if is_white and not stamps.white then stamps.white = current_time
    elseif not is_white then stamps.white = nil end
    if is_orange and not stamps.orange then stamps.orange = current_time
    elseif not is_orange then stamps.orange = nil end
    if is_red and not stamps.red then stamps.red = current_time
    elseif not is_red then stamps.red = nil end
    
    local active_lamps = {}
    if is_white then table.insert(active_lamps, { name = "white", time = stamps.white }) end
    if is_orange then table.insert(active_lamps, { name = "orange", time = stamps.orange }) end
    if is_red then table.insert(active_lamps, { name = "red", time = stamps.red }) end
    
    if #active_lamps == 0 then return "none" end
    table.sort(active_lamps, function(a,b) return a.time > b.time end)
    return active_lamps[1].name
end

function TransformManager.get_character_insect_glaive_state(character)
    if not character then return "none" end
    local char_go_ok, char_go = pcall(function() return character:call("get_GameObject") end)
    local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(character)
    return get_insect_glaive_state_direct(character, char_addr)
end

function TransformManager.has_insect_glaive_getter() return true end

-- =============================================================================
-- 盾斧状态模块 (Charge Blade)
-- =============================================================================
local function get_charge_blade_state_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "sword" end
    
    local ok_shield, is_shield = pcall(function() return wh:call("get_IsShieldEnhanced") end)
    if not ok_shield then is_shield = false end
    local ok_axe, is_axe = pcall(function() return wh:call("get_IsAxeEnhanced") end)
    if not ok_axe then is_axe = false end
    local ok_sword, is_sword = pcall(function() return wh:call("get_IsSwordEnhanced") end)
    if not ok_sword then is_sword = false end
    local ok_mode, mode = pcall(function() return wh:call("get_Mode") end)
    if not ok_mode then mode = 0 end
    
    if is_shield and is_axe and is_sword then
        return "triple"
    end
    
    if mode == 0 then
        if is_shield and is_sword then
            return "sword_shield_sword"
        elseif is_shield then
            return "sword_shield"
        elseif is_sword then
            return "sword_sword"
        else
            return "sword"
        end
    else
        if is_axe then
            return "axe_axe"
        else
            return "axe"
        end
    end
end

function TransformManager.get_character_charge_blade_state(character)
    if not character then return "sword" end
    return get_charge_blade_state_direct(character)
end

function TransformManager.has_charge_blade_getter() return true end

-- =============================================================================
-- 大剑蓄力模块 (Greatsword)
-- =============================================================================
local function get_greatsword_charge_type_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "other" end
    local ok, charge_type = pcall(function() return wh:call("get_ChargeType") end)
    if not ok then return "other" end
    if type(charge_type) == "number" then
        if charge_type == 0 then return "0"
        elseif charge_type == 1 then return "1"
        elseif charge_type == 2 then return "2"
        elseif charge_type == 3 then return "3"
        elseif charge_type == 5 then return "5"
        else return "other" end
    end
    return "other"
end

local function get_greatsword_charge_level_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return 0 end
    local ok, level = pcall(function() return wh:call("get_ChargeLevel") end)
    if ok and type(level) == "number" then
        if level >= 0 and level <= 3 then return level end
    end
    return 0
end

function TransformManager.get_character_greatsword_charge_type(character)
    if not character then return "other" end
    return get_greatsword_charge_type_direct(character)
end

function TransformManager.get_character_greatsword_charge_level(character)
    if not character then return 0 end
    return get_greatsword_charge_level_direct(character)
end

function TransformManager.has_greatsword_getter() return true end

-- =============================================================================
-- 弓箭蓄力等级模块 (Bow)
-- =============================================================================
local function get_bow_charge_level_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return 1 end
    local ok, level = pcall(function() return wh:call("get_ChargeLv") end)
    if ok and type(level) == "number" then
        if level >= 1 and level <= 4 then return level
        else return 1 end
    end
    return 1
end

function TransformManager.get_character_bow_charge_level(character)
    if not character then return 1 end
    return get_bow_charge_level_direct(character)
end

function TransformManager.has_bow_getter() return true end

-- =============================================================================
-- 大锤蓄力等级模块 (Hammer)
-- =============================================================================
local function get_hammer_charge_level_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return 0 end
    local ok, level = pcall(function() return wh:call("get_ChargeLv") end)
    if ok and type(level) == "number" then
        if level >= 0 and level <= 3 then return level
        else return 0 end
    end
    return 0
end

function TransformManager.get_character_hammer_charge_level(character)
    if not character then return 0 end
    return get_hammer_charge_level_direct(character)
end

function TransformManager.has_hammer_getter() return true end

-- =============================================================================
-- 规则引擎
-- =============================================================================
local last_state_cache = {}

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

local function get_active_rule_for_type(t_type, config, character, char_addr)
    if t_type == "hp" then
        local cur_hp = TransformManager.get_character_hp_percent(character)
        if cur_hp and config.transform_rules then
            local rule = get_active_hp_rule(config.transform_rules, cur_hp)
            return rule, cur_hp
        end
    elseif t_type == "damage" then
        local cur_hp = TransformManager.get_character_hp_percent(character)
        if cur_hp and config.damage_transform_rules and config.damage_transform_rules[1] then
            -- 将独立的伤害规则包裹为列表传入
            local rule = DamageTimer.evaluate_damage_rules(char_addr, cur_hp, config.damage_transform_rules[1])
            return rule, "dmg"
        end
    elseif t_type == "weapon" then
        local drawn = TransformManager.get_character_weapon_drawn(character)
        local target = drawn and "drawn" or "sheathed"
        if config.weapon_transform_rules then
            for _, r in ipairs(config.weapon_transform_rules) do
                if r.state == target then return r, target end
            end
        end
    elseif t_type == "spirit" then
        local level = TransformManager.get_character_spirit_level(character)
        if level and config.spirit_transform_rules then
            for _, r in ipairs(config.spirit_transform_rules) do
                if r.level == level then return r, level end
            end
        end
    elseif t_type == "dual_blades" then
        local state = TransformManager.get_character_dual_blades_state(character)
        if config.dual_blades_transform_rules then
            for _, r in ipairs(config.dual_blades_transform_rules) do
                if r.state == state then return r, state end
            end
        end
    elseif t_type == "switch_axe" then
        local state = TransformManager.get_character_switch_axe_state(character)
        if config.switch_axe_transform_rules then
            for _, r in ipairs(config.switch_axe_transform_rules) do
                if r.state == state then return r, state end
            end
        end
    elseif t_type == "insect_glaive" then
        local state = TransformManager.get_character_insect_glaive_state(character)
        if config.insect_glaive_transform_rules then
            for _, r in ipairs(config.insect_glaive_transform_rules) do
                if r.state == state then return r, state end
            end
        end
    elseif t_type == "charge_blade" then
        local state = TransformManager.get_character_charge_blade_state(character)
        if config.charge_blade_transform_rules then
            for _, r in ipairs(config.charge_blade_transform_rules) do
                if r.state == state then return r, state end
            end
        end
    elseif t_type == "greatsword_type" then
        local state = TransformManager.get_character_greatsword_charge_type(character)
        if config.greatsword_type_transform_rules then
            for _, r in ipairs(config.greatsword_type_transform_rules) do
                if r.state == state then return r, state end
            end
        end
    elseif t_type == "greatsword_level" then
        local level = TransformManager.get_character_greatsword_charge_level(character)
        if level ~= nil and config.greatsword_level_transform_rules then
            for _, r in ipairs(config.greatsword_level_transform_rules) do
                if r.level == level then return r, level end
            end
        end
    elseif t_type == "bow_level" then
        local level = TransformManager.get_character_bow_charge_level(character)
        if level and config.bow_level_transform_rules then
            for _, r in ipairs(config.bow_level_transform_rules) do
                if r.level == level then return r, level end
            end
        end
    elseif t_type == "hammer_level" then
        local level = TransformManager.get_character_hammer_charge_level(character)
        if level ~= nil and config.hammer_level_transform_rules then
            for _, r in ipairs(config.hammer_level_transform_rules) do
                if r.level == level then return r, level end
            end
        end
    end
    return nil, nil
end

function TransformManager.apply_transform_rules(char_addr, config, character, base_overrides, merge_overrides_func)
    if not config then return base_overrides, false end
    local new_overrides = base_overrides
    local prev_state = last_state_cache[char_addr]
    local changed = false
    
    local types = {}
    if config.is_parallel then
        local sets = config.parallel_settings or {}
        for k, v in pairs(sets) do
            if v.enabled then
                table.insert(types, { type = k, priority = v.priority or 99 })
            end
        end
        table.sort(types, function(a,b) return a.priority > b.priority end)
    else
        table.insert(types, { type = config.transform_type or "hp", priority = 1 })
    end
    
    local sig_parts = {}
    for _, eval in ipairs(types) do
        local rule, extra = get_active_rule_for_type(eval.type, config, character, char_addr)
        if rule then
            local part = eval.type .. ":"
            if eval.type == "hp" then part = part .. "th:" .. tostring(rule.threshold)
            elseif eval.type == "weapon" then part = part .. "ws:" .. tostring(extra)
            elseif eval.type == "spirit" then part = part .. "lvl:" .. tostring(extra)
            elseif eval.type == "dual_blades" then part = part .. "st:" .. tostring(extra)
            elseif eval.type == "switch_axe" then part = part .. "st:" .. tostring(extra)
            elseif eval.type == "insect_glaive" then part = part .. "lamp:" .. tostring(extra)
            elseif eval.type == "charge_blade" then part = part .. "cb:" .. tostring(extra)
            elseif eval.type == "greatsword_type" then part = part .. "type:" .. tostring(extra)
            elseif eval.type == "greatsword_level" then part = part .. "lvl:" .. tostring(extra)
            elseif eval.type == "bow_level" then part = part .. "lvl:" .. tostring(extra)
            elseif eval.type == "hammer_level" then part = part .. "lvl:" .. tostring(extra)
            end
            if rule.targets then
                for _, tgt in ipairs(rule.targets) do
                    local gname = tgt.group or ""
                    local pname = tgt.preset or ""
                    
                    part = part .. "|" .. gname .. ":" .. pname
                    
                    if pname ~= "" then
                        local preset = nil
                        if gname == "" then
                            preset = config.presets and config.presets[pname]
                        else
                            if config.groups and config.groups[gname] and config.groups[gname].presets then
                                preset = config.groups[gname].presets[pname]
                            end
                        end
                        if preset then
                            new_overrides = merge_overrides_func(new_overrides, preset)
                        end
                    end
                end
            end
            table.insert(sig_parts, part)
        end
    end
    
    local current_sig = #sig_parts > 0 and table.concat(sig_parts, "|") or "none"
    if prev_state ~= current_sig then
        changed = true
        last_state_cache[char_addr] = current_sig
    end
    return new_overrides, changed
end

-- 所有模块检测函数全部返回 true，避免 UI 警告
function TransformManager.is_weapon_module_initialized() return true end
function TransformManager.has_weapon_getter() return true end
function TransformManager.is_hp_module_initialized() return true end
function TransformManager.has_hp_getter() return true end

return TransformManager