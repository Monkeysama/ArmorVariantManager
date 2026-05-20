local TransformManager = {}

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
-- 规则引擎
-- =============================================================================
local last_state_cache = {}

local function get_active_rule_for_type(t_type, config, character, char_addr)
    -- 处理所有基于插件的逻辑
    local handler = ConditionRegistry[t_type]
    if handler then
        return handler.evaluate(config, character, char_addr)
    end
    
    return nil, nil
end

function TransformManager.apply_transform_rules(char_addr, config, character, active_overrides, merge_overrides)
    if not active_overrides then return active_overrides, false end
    
    local active_rules = {} -- 收集所有激活的规则，格式: { rule = node, priority = number }
    local current_states = {} -- 记录每个条件类型的当前状态，用于缓存比对
    
    if config.is_parallel then
        -- 并行模式：遍历所有启用的条件类型
        for t_type, p_setting in pairs(config.parallel_settings) do
            if p_setting.enabled then
                local rule, cur_state = get_active_rule_for_type(t_type, config, character, char_addr)
                if cur_state ~= nil then current_states[t_type] = cur_state end
                if rule then
                    table.insert(active_rules, { rule = rule, priority = p_setting.priority })
                end
            end
        end
    else
        -- 单一模式：只评估当前选中的条件类型
        local t_type = config.transform_type
        if t_type then
            local rule, cur_state = get_active_rule_for_type(t_type, config, character, char_addr)
            if cur_state ~= nil then current_states[t_type] = cur_state end
            if rule then
                table.insert(active_rules, { rule = rule, priority = 1 })
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
    
    local changed = (last_state_cache[char_addr] ~= state_signature)
    last_state_cache[char_addr] = state_signature
    
    local new_overrides = {}
    for p, data in pairs(active_overrides) do
        new_overrides[p] = { mesh_enabled = data.mesh_enabled, materials = {} }
        if data.materials then
            for m, en in pairs(data.materials) do new_overrides[p].materials[m] = en end
        end
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
                            new_overrides = merge_overrides(new_overrides, preset_data)
                        end
                    end
                end
            end
        end
    end

    -- 如果强制每次应用预设，忽略 changed
    -- changed = true

    return new_overrides, changed
end

return TransformManager