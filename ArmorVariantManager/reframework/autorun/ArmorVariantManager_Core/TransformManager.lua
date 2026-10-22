local TransformManager = {}
local GroundClippingFix = require("ArmorVariantManager_Core.GroundClippingFix")

-- 引入条件注册表
local ConditionRegistry = {
    hp = require("ArmorVariantManager_Core.Conditions.Condition_HP"),
    damage = require("ArmorVariantManager_Core.Conditions.Condition_Damage"),
    weapon = require("ArmorVariantManager_Core.Conditions.Condition_Weapon"),
    spirit = require("ArmorVariantManager_Core.Conditions.Condition_LongSword"),
    dual_blades = require("ArmorVariantManager_Core.Conditions.Condition_DualBlades"),
    switch_axe = require("ArmorVariantManager_Core.Conditions.Condition_SwitchAxe"),
    insect_glaive = require("ArmorVariantManager_Core.Conditions.Condition_InsectGlaive"),
    charge_blade = require("ArmorVariantManager_Core.Conditions.Condition_ChargeBlade"),
    greatsword_type = require("ArmorVariantManager_Core.Conditions.Condition_GreatSwordType"),
    greatsword_level = require("ArmorVariantManager_Core.Conditions.Condition_GreatSwordLevel"),
    bow_level = require("ArmorVariantManager_Core.Conditions.Condition_BowLevel"),
    hammer_level = require("ArmorVariantManager_Core.Conditions.Condition_HammerLevel")
}

-- 暴露状态获取接口给外部 (UI 需要用到这些接口)
function TransformManager.get_character_hp_percent(character) return ConditionRegistry.hp.get_state(character) end
function TransformManager.set_character_hp_percent(character, percent) return ConditionRegistry.hp.set_state(character, percent) end
function TransformManager.get_character_hp(character) return ConditionRegistry.hp.get_hp(character) end
function TransformManager.set_character_hp(character, target_hp) return ConditionRegistry.hp.set_hp(character, target_hp) end
function TransformManager.get_character_weapon_drawn(character) return ConditionRegistry.weapon.get_state(character) end
function TransformManager.get_character_spirit_level(character) return ConditionRegistry.spirit.get_state(character) end
function TransformManager.get_character_dual_blades_state(character) return ConditionRegistry.dual_blades.get_state(character) end
function TransformManager.get_character_switch_axe_state(character) return ConditionRegistry.switch_axe.get_state(character) end
function TransformManager.get_character_insect_glaive_state(character) return ConditionRegistry.insect_glaive.get_state(character) end
function TransformManager.get_character_charge_blade_state(character) return ConditionRegistry.charge_blade.get_state(character) end
function TransformManager.get_character_greatsword_charge_type(character) return ConditionRegistry.greatsword_type.get_state(character) end
function TransformManager.get_character_greatsword_charge_level(character) return ConditionRegistry.greatsword_level.get_state(character) end
function TransformManager.get_character_bow_charge_level(character) return ConditionRegistry.bow_level.get_state(character) end
function TransformManager.get_character_hammer_charge_level(character) return ConditionRegistry.hammer_level.get_state(character) end

function TransformManager.get_damage_remaining_time(char_addr) return ConditionRegistry.damage.get_remaining_time(char_addr) end

-- 暴露模块状态接口给外部 (UI 需要用到这些接口)
function TransformManager.is_hp_module_initialized() return ConditionRegistry.hp.is_initialized() end
function TransformManager.has_weapon_getter() return ConditionRegistry.weapon.has_getter() end
function TransformManager.has_spirit_getter() return ConditionRegistry.spirit.has_getter() end
function TransformManager.has_dual_blades_getter() return ConditionRegistry.dual_blades.has_getter() end
function TransformManager.has_switch_axe_getter() return ConditionRegistry.switch_axe.has_getter() end
function TransformManager.has_insect_glaive_getter() return ConditionRegistry.insect_glaive.has_getter() end
function TransformManager.has_charge_blade_getter() return ConditionRegistry.charge_blade.has_getter() end
function TransformManager.has_greatsword_getter() return ConditionRegistry.greatsword_type.has_getter() end
function TransformManager.has_bow_getter() return ConditionRegistry.bow_level.has_getter() end
function TransformManager.has_hammer_getter() return ConditionRegistry.hammer_level.has_getter() end

-- =============================================================================
-- 武器类型获取模块 (用于过滤不匹配的武器条件)
-- =============================================================================
local weapon_type_getter = nil

local function init_weapon_type_reflection(character)
    if weapon_type_getter then return end
    local type_def = character:get_type_definition()
    if not type_def then return end
    local method = type_def:get_method("get_WeaponType")
    if method then
        weapon_type_getter = method
    end
end

function TransformManager.get_character_weapon_type(character)
    if not character then return nil end
    if not weapon_type_getter then init_weapon_type_reflection(character) end
    if weapon_type_getter then
        local ok, wt = pcall(function() return weapon_type_getter:call(character) end)
        if ok and type(wt) == "number" then return wt end
    end
    return nil
end

-- =============================================================================
-- 规则引擎
-- =============================================================================
local last_state_cache = {}

-- 规则摘要仅依赖配置，不持有角色对象；弱键允许已替换的配置随原表释放。
local config_rule_cache = setmetatable({}, { __mode = "k" })
local rule_fields = {
    hp = "transform_rules",
    damage = "damage_transform_rules",
    weapon = "weapon_transform_rules",
    spirit = "spirit_transform_rules",
    dual_blades = "dual_blades_transform_rules",
    switch_axe = "switch_axe_transform_rules",
    insect_glaive = "insect_glaive_transform_rules",
    charge_blade = "charge_blade_transform_rules",
    greatsword_type = "greatsword_type_transform_rules",
    greatsword_level = "greatsword_level_transform_rules",
    bow_level = "bow_level_transform_rules",
    hammer_level = "hammer_level_transform_rules"
}
local weapon_type_required = {
    spirit = 3,           -- 太刀
    dual_blades = 2,      -- 双刀
    switch_axe = 8,       -- 斩斧
    insect_glaive = 10,   -- 虫棍
    charge_blade = 9,     -- 盾斧
    greatsword_type = 0,  -- 大剑
    greatsword_level = 0, -- 大剑
    bow_level = 11,       -- 弓箭
    hammer_level = 4      -- 大锤
}

-- 空节点、未选择预设和已删除的目标不需要监测；空预设表仍是有效的用户配置。
local function has_configured_target(config, targets)
    if type(targets) ~= "table" then return false end
    for _, target in ipairs(targets) do
        if type(target) == "table" and type(target.preset) == "string"
            and target.preset ~= "" and target.preset ~= "None" then
            local group_name = target.group or ""
            local owner = group_name == "" and config or
                (type(config.groups) == "table" and config.groups[group_name])
            if type(owner) == "table" and type(owner.presets) == "table"
                and type(owner.presets[target.preset]) == "table" then
                return true
            end
        end
    end
    return false
end

-- 受击链只使用 chain_nodes 的目标，其余模式使用规则本身的目标。
local function has_configured_rule(config, type_key, rule)
    if type(rule) ~= "table" then return false end
    if type_key == "damage" and rule.mode == 3 then
        if type(rule.chain_nodes) ~= "table" then return false end
        for _, node in pairs(rule.chain_nodes) do
            if type(node) == "table" and has_configured_target(config, node.targets) then return true end
        end
        return false
    end
    return has_configured_target(config, rule.targets)
end

-- 加载、保存或恢复配置时重新计算一次；不读文件、不访问 SDK，也不修改原配置。
function TransformManager.refresh_config_rules(config)
    if type(config) ~= "table" then return nil end
    local summary = { conditions = {}, has_rules = false, needs_weapon_type = false }
    for type_key, field in pairs(rule_fields) do
        local setting = type(config.parallel_settings) == "table" and config.parallel_settings[type_key]
        local enabled = config.is_parallel and type(setting) == "table" and setting.enabled
            or not config.is_parallel and config.transform_type == type_key
        local rules = config[field]
        local configured = false
        if enabled and type(rules) == "table" then
            if type_key == "damage" then
                -- 与受击模块一致，只使用 pairs 返回的第一条规则。
                for _, rule in pairs(rules) do
                    configured = has_configured_rule(config, type_key, rule)
                    break
                end
            else
                for _, rule in ipairs(rules) do
                    if has_configured_rule(config, type_key, rule) then configured = true; break end
                end
            end
        end
        if configured then
            summary.conditions[type_key] = true
            summary.has_rules = true
            if weapon_type_required[type_key] ~= nil then summary.needs_weapon_type = true end
        end
    end
    config_rule_cache[config] = summary
    return summary
end

local function get_config_rules(config)
    if type(config) ~= "table" then return nil end
    return config_rule_cache[config] or TransformManager.refresh_config_rules(config)
end

function TransformManager.has_configured_rules(config)
    local summary = get_config_rules(config)
    return summary ~= nil and summary.has_rules
end

function TransformManager.has_configured_condition(config, type_key)
    local summary = get_config_rules(config)
    return summary ~= nil and summary.conditions[type_key] == true
end

-- 旧 UI 按摘要读取状态，新 UI 使用同一摘要判断；false 是有效的收刀状态，不能丢失。
function TransformManager.get_configured_state(config, type_key, character, char_addr)
    if not TransformManager.has_configured_condition(config, type_key) then return nil end
    if type_key == "damage" then return ConditionRegistry.damage.get_remaining_time(char_addr) end
    local handler = ConditionRegistry[type_key]
    if handler and handler.get_state then return handler.get_state(character) end
    return nil
end

function TransformManager.clear_last_state_cache()
    last_state_cache = {}
end

local function get_active_rule_for_type(t_type, config, character, char_addr)
    -- 处理所有基于插件的逻辑
    local handler = ConditionRegistry[t_type]
    if handler then
        return handler.evaluate(config, character, char_addr)
    end
    
    return nil, nil
end

function TransformManager.apply_transform_rules(char_addr, config, character, active_overrides, merge_overrides)
    if not active_overrides then return active_overrides, false, nil, nil end
    local summary = get_config_rules(config)
    if not summary or not summary.has_rules then return active_overrides, false, nil, nil end

    -- 只有已配置的武器专属条件才需要查询武器类型，纯血量/受击/收刀规则不查询。
    local current_weapon_type = nil
    if summary.needs_weapon_type then
        current_weapon_type = TransformManager.get_character_weapon_type(character)
    end
    
    local active_rules = {} -- 收集所有激活的规则，格式: { rule = node, priority = number }
    local current_states = {} -- 记录每个条件类型的当前状态，用于缓存比对
    
    if config.is_parallel then
        -- 并行模式：遍历所有启用的条件类型
        for t_type, p_setting in pairs(config.parallel_settings) do
            if summary.conditions[t_type] then
                -- 检查武器类型匹配性
                local required = weapon_type_required[t_type]
                if required and current_weapon_type ~= required then
                    goto continue_parallel
                end
                
                local rule, cur_state = get_active_rule_for_type(t_type, config, character, char_addr)
                if cur_state ~= nil then current_states[t_type] = cur_state end
                if rule then
                    table.insert(active_rules, { rule = rule, priority = p_setting.priority })
                end
                ::continue_parallel::
            end
        end
    else
        -- 单一模式：只评估当前选中的条件类型
        local t_type = config.transform_type
        if summary.conditions[t_type] then
            local required = weapon_type_required[t_type]
            if not (required and current_weapon_type ~= required) then
                local rule, cur_state = get_active_rule_for_type(t_type, config, character, char_addr)
                if cur_state ~= nil then current_states[t_type] = cur_state end
                if rule then
                    table.insert(active_rules, { rule = rule, priority = 1 })
                end
            end
        end
    end

    -- 构建状态签名用于比对
    local state_signature = ""
    local sorted_types = {}
    for t, _ in pairs(current_states) do table.insert(sorted_types, t) end
    table.sort(sorted_types)
    for _, t in ipairs(sorted_types) do
        state_signature = state_signature .. t .. ":" .. tostring(current_states[t]) .. "|"
    end
    
    -- 状态缓存的 Key，加上 config_id（区分防具和武器）
    local cache_key = char_addr .. "_" .. tostring(config)
    local changed = (last_state_cache[cache_key] ~= state_signature)
    last_state_cache[cache_key] = state_signature
    
    local new_overrides = {}
    for p, data in pairs(active_overrides) do
        if p == "ground_clipping_fix" then
            new_overrides[p] = data
            goto continue_base_part
        end
        new_overrides[p] = { mesh_enabled = data.mesh_enabled, materials = {} }
        if data.materials then
            for m, en in pairs(data.materials) do new_overrides[p].materials[m] = en end
        end
        ::continue_base_part::
    end

    if #active_rules > 0 then
        -- 按优先级排序（数字越小优先级越高）
        -- 优先级较低的规则先应用，优先级高的后应用（从而覆盖低优先级）
        table.sort(active_rules, function(a, b) return a.priority > b.priority end)
        
        for _, active_item in ipairs(active_rules) do
            local rule = active_item.rule
            if rule.targets then
                for _, target in ipairs(rule.targets) do
                    local g_name = target.group
                    local p_name = target.preset
                    if p_name and p_name ~= "None" then
                        local preset_data = nil
                        if g_name == "" or g_name == nil then
                            if config.presets and config.presets[p_name] then
                                preset_data = config.presets[p_name]
                            end
                        else
                            if config.groups and config.groups[g_name] and config.groups[g_name].presets and config.groups[g_name].presets[p_name] then
                                preset_data = config.groups[g_name].presets[p_name]
                            end
                        end
                        if preset_data then
                            local previous_height = new_overrides.ground_clipping_fix
                            new_overrides = merge_overrides(new_overrides, preset_data)
                            -- 仅勾选的目标参与高度优先级；未勾选保留低优先级规则或手动基线。
                            new_overrides.ground_clipping_fix = GroundClippingFix.participating_settings(preset_data, config)
                                or previous_height
                        end
                    end
                end
            end
        end
    end

    -- 返回第三个值：变身规则激活的所有 target（分组→预设名映射）
    -- 用于让主循环同步 active_group_presets，确保全局分组状态一致
    local activated_targets = {}
    if #active_rules > 0 then
        for _, active_item in ipairs(active_rules) do
            local rule = active_item.rule
            if rule.targets then
                for _, target in ipairs(rule.targets) do
                    local g_name = target.group or ""
                    local p_name = target.preset
                    if p_name and p_name ~= "None" then
                        activated_targets[g_name] = p_name
                    end
                end
            end
        end
    end

    -- 返回第四个值：所有变身规则中涉及的分组集合（无论是否激活）
    -- 用于区分"没有配置变身规则"和"规则未激活需要回退"两种情况
    local all_targeted_groups = {}
    local all_rules_tables = {
        config.transform_rules,
        config.damage_transform_rules,
        config.weapon_transform_rules,
        config.spirit_transform_rules,
        config.dual_blades_transform_rules,
        config.switch_axe_transform_rules,
        config.insect_glaive_transform_rules,
        config.charge_blade_transform_rules,
        config.greatsword_type_transform_rules,
        config.greatsword_level_transform_rules,
        config.bow_level_transform_rules,
        config.hammer_level_transform_rules
    }
    for _, rules_table in ipairs(all_rules_tables) do
        if rules_table then
            for _, rule in ipairs(rules_table) do
                if rule.targets then
                    for _, target in ipairs(rule.targets) do
                        local g_name = target.group or ""
                        local p_name = target.preset
                        if p_name and p_name ~= "None" then
                            all_targeted_groups[g_name] = true
                        end
                    end
                end
            end
        end
    end

    return new_overrides, changed, activated_targets, all_targeted_groups
end

return TransformManager
