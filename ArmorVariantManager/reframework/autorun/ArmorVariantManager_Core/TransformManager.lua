local TransformManager = {}

-- 引入独立的受击计时器模块
local DamageTimer = require("ArmorVariantManager_Core.DamageTimer")

-- =============================================================================
-- 武器状态模块
-- =============================================================================
local weapon_state_initialized = false
local weapon_state_getter = nil

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
    
    local method_names = { "get_IsWeaponDraw", "get_isWeaponDraw", "isWeaponDraw", "isDrawWeapon", "get_IsDrawWeapon" }
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
    if not weapon_state_initialized then init_weapon_state_reflection(character) end
    if not weapon_state_getter then return false end
    
    if weapon_state_getter.is_field then
        return weapon_state_getter.field:get_data(character) == true
    else
        local ok, res = pcall(function() return weapon_state_getter.method:call(character) end)
        if ok and res ~= nil then
            if weapon_state_getter.is_enum then return tonumber(res) > 0
            else return weapon_state_getter.invert and not res or res == true end
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
        hp_reflection_initialized = true; return
    end
    if type_def:get_method("get_Health") and type_def:get_method("get_MaxHealth") then
        hp_getter = type_def:get_method("get_Health")
        max_hp_getter = type_def:get_method("get_MaxHealth")
        hp_setter = type_def:get_method("set_Health")
        hp_reflection_initialized = true; return
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
                            hp_getter = { call = function(_, t) local hh = get_hunter_health:call(t); if not hh then return 0 end; local hm = get_health_mgr:call(hh); return hm and getter:call(hm) or 0 end }
                            max_hp_getter = { call = function(_, t) local hh = get_hunter_health:call(t); if not hh then return 0 end; local hm = get_health_mgr:call(hh); return hm and max_getter:call(hm) or 0 end }
                            if setter then hp_setter = { call = function(_, t, v) local hh = get_hunter_health:call(t); if not hh then return end; local hm = get_health_mgr:call(hh); if hm then setter:call(hm, v) end end } end
                            hp_reflection_initialized = true; return
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
-- 转换规则与逻辑 (使用外置计时器引擎)
-- =============================================================================

local last_hp_state = {} 

local function get_active_rule_for_type(t_type, config, character, char_addr)
    if t_type == "hp" then
        local cur_hp = TransformManager.get_character_hp_percent(character)
        if cur_hp and config.transform_rules and #config.transform_rules > 0 then
            -- 调用独立的新 Lua 模块处理受击与计时逻辑
            local rule = DamageTimer.evaluate_hp_rules(char_addr, cur_hp, config.transform_rules)
            return rule, cur_hp
        end
    elseif t_type == "weapon" then
        local is_drawn = TransformManager.get_character_weapon_drawn(character)
        local target_state = is_drawn and "drawn" or "sheathed"
        if config.weapon_transform_rules then
            for _, r in ipairs(config.weapon_transform_rules) do
                if r.state == target_state then return r, target_state end
            end
        end
    end
    return nil, nil
end

function TransformManager.apply_transform_rules(char_addr, config, character, base_overrides, merge_overrides_func)
    if not config then return base_overrides, false end
    local new_overrides = base_overrides
    local prev_state = last_hp_state[char_addr]
    local changed = false
    
    local types_to_evaluate = {}
    if config.is_parallel then
        local p_sets = config.parallel_settings or {}
        for k, v in pairs(p_sets) do
            if v.enabled then table.insert(types_to_evaluate, { type = k, priority = v.priority or 99 }) end
        end
        table.sort(types_to_evaluate, function(a, b) return a.priority > b.priority end)
    else
        table.insert(types_to_evaluate, { type = config.transform_type or "hp", priority = 1 })
    end
    
    local combined_sig = {}
    
    for _, eval in ipairs(types_to_evaluate) do
        local active_rule, extra = get_active_rule_for_type(eval.type, config, character, char_addr)
        if active_rule then
            local sig_part = eval.type .. ":"
            if eval.type == "hp" then sig_part = sig_part .. "th:" .. tostring(active_rule.threshold) end
            if eval.type == "weapon" then sig_part = sig_part .. "ws:" .. tostring(extra) end
            
            if active_rule.targets then
                for _, target in ipairs(active_rule.targets) do
                    local gname = target.group or ""
                    local preset_name = target.preset or "" -- 修复原版中的空值崩溃漏洞
                    
                    sig_part = sig_part .. "|" .. gname .. ":" .. preset_name
                    
                    if preset_name ~= "" then
                        local preset_data = nil
                        if gname == "" then preset_data = config.presets and config.presets[preset_name]
                        else if config.groups and config.groups[gname] and config.groups[gname].presets then preset_data = config.groups[gname].presets[preset_name] end end
                        if preset_data then new_overrides = merge_overrides_func(new_overrides, preset_data) end
                    end
                end
            end
            table.insert(combined_sig, sig_part)
        end
    end
    
    local current_state = #combined_sig > 0 and table.concat(combined_sig, "|") or "none"
    if prev_state ~= current_state then
        changed = true
        last_hp_state[char_addr] = current_state
    end
    return new_overrides, changed
end

function TransformManager.is_weapon_module_initialized() return weapon_state_initialized end
function TransformManager.has_weapon_getter() return weapon_state_getter ~= nil end
function TransformManager.is_hp_module_initialized() return hp_reflection_initialized end
function TransformManager.has_hp_getter() return hp_getter ~= nil end

return TransformManager