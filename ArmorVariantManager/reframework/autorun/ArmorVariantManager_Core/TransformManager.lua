local TransformManager = {}

-- 引入条件注册表（所有条件模块）
local ConditionRegistry = {
    weapon = require("ArmorVariantManager_Core.Conditions.Condition_Weapon"),
    scroll = require("ArmorVariantManager_Core.Conditions.Condition_Scroll"),
    longsword = require("ArmorVariantManager_Core.Conditions.Condition_LongSword"),
    dual_blades = require("ArmorVariantManager_Core.Conditions.Condition_DualBlades"),
    switch_axe = require("ArmorVariantManager_Core.Conditions.Condition_SwitchAxe"),
    charge_axe = require("ArmorVariantManager_Core.Conditions.Condition_ChargeAxe"),
    greatsword_level = require("ArmorVariantManager_Core.Conditions.Condition_GreatSwordLevel"),
    hammer = require("ArmorVariantManager_Core.Conditions.Condition_Hammer"),
    bow = require("ArmorVariantManager_Core.Conditions.Condition_Bow"),
    monster_hp = require("ArmorVariantManager_Core.Conditions.Condition_MonsterHP")
}

-- 本地化支持（用于显示当前状态）
local Localization = require("ArmorVariantManager_Core.Localization")
local global_config_path = "ArmorVariantManager/GlobalSettings.json"
local function get_language()
    local config = json.load_file(global_config_path)
    if config and config.language then
        return config.language
    end
    return "zh"
end

local function T(key)
    if not key then return "nil" end
    local lang = get_language()
    local dict = Localization[lang] or Localization["en"]
    return dict[key] or tostring(key)
end

-- 状态缓存（避免每帧重复评估相同状态）
-- 键格式：char_addr .. "|" .. context_id
local last_state_cache = {}

-- 清除指定角色和上下文的缓存
function TransformManager.clear_cache(char_addr, context_id)
    if char_addr and context_id then
        local key = char_addr .. "|" .. tostring(context_id)
        last_state_cache[key] = nil
    elseif char_addr then
        -- 清除该角色所有缓存
        local prefix = char_addr .. "|"
        for k, _ in pairs(last_state_cache) do
            if string.sub(k, 1, #prefix) == prefix then
                last_state_cache[k] = nil
            end
        end
    else
        last_state_cache = {}
    end
end

-- 获取指定条件类型的激活规则（内部函数）
local function get_active_rule_for_type(t_type, config, character, char_addr)
    local handler = ConditionRegistry[t_type]
    if handler then
        return handler.evaluate(config, character, char_addr)
    end
    return nil, nil
end

-- 核心函数：应用变身规则，返回最终的 overrides、是否变化、激活的分组预设、所有被引用的分组
-- 新增 context_id 参数，用于区分防具/武器等不同配置上下文
function TransformManager.apply_transform_rules(char_addr, context_id, config, character, active_overrides, merge_overrides)
    if not active_overrides then
        return active_overrides, false, {}, {}
    end

    local active_rules = {}        -- { rule, priority }
    local current_states = {}      -- 记录每个条件类型的当前状态（用于缓存签名）

    if config.is_parallel then
        -- 并行模式：遍历所有启用的条件
        for t_type, p_setting in pairs(config.parallel_settings or {}) do
            if p_setting.enabled and ConditionRegistry[t_type] then
                local rule, cur_state = get_active_rule_for_type(t_type, config, character, char_addr)
                if cur_state ~= nil then
                    current_states[t_type] = cur_state
                end
                if rule then
                    table.insert(active_rules, { rule = rule, priority = p_setting.priority or 1 })
                end
            end
        end
    else
        -- 单一模式：只评估当前选中的条件类型
        local t_type = config.transform_type
        if t_type and ConditionRegistry[t_type] then
            local rule, cur_state = get_active_rule_for_type(t_type, config, character, char_addr)
            if cur_state ~= nil then
                current_states[t_type] = cur_state
            end
            if rule then
                table.insert(active_rules, { rule = rule, priority = 1 })
            end
        end
    end

    -- 生成状态签名（用于判断是否变化）
    local state_signature = ""
    local sorted_types = {}
    for t, _ in pairs(current_states) do
        table.insert(sorted_types, t)
    end
    table.sort(sorted_types)
    for _, t in ipairs(sorted_types) do
        state_signature = state_signature .. t .. ":" .. tostring(current_states[t]) .. "|"
    end

    -- 使用复合键存储缓存
    local cache_key = char_addr .. "|" .. tostring(context_id)
    local changed = (last_state_cache[cache_key] ~= state_signature)
    last_state_cache[cache_key] = state_signature

    -- 收集激活的分组预设和目标分组（用于全局分组更新）
    local activated_targets = {}   -- group_name -> preset_name (当前激活的规则中实际应用的预设)
    local all_targeted_groups = {} -- group_name -> true (所有被规则引用的分组)

    -- **关键：如果状态没有变化，直接返回传入的 active_overrides（保留用户手动修改）**
    if not changed then
        return active_overrides, false, activated_targets, all_targeted_groups
    end

    -- 状态变化，需要重新计算规则并生成新的 overrides
    local new_overrides = {}
    for p, data in pairs(active_overrides) do
        new_overrides[p] = { mesh_enabled = data.mesh_enabled, materials = {} }
        if data.materials then
            for m, en in pairs(data.materials) do
                new_overrides[p].materials[m] = en
            end
        end
    end

    -- 按优先级排序（高优先级后应用，实现覆盖）
    if #active_rules > 0 then
        table.sort(active_rules, function(a, b) return a.priority > b.priority end)
        for _, active_item in ipairs(active_rules) do
            local rule = active_item.rule
            if rule.targets then
                for _, target in ipairs(rule.targets) do
                    local g_name = target.group
                    local p_name = target.preset
                    if p_name and p_name ~= "None" then
                        -- 记录所有被引用的分组
                        all_targeted_groups[g_name or ""] = true
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
                            -- 记录当前规则实际激活了哪个预设（用于全局分组）
                            if g_name ~= nil and g_name ~= "" then
                                activated_targets[g_name] = p_name
                            end
                        end
                    end
                end
            end
        end
    end

    return new_overrides, true, activated_targets, all_targeted_groups
end

-- 获取当前状态的显示字符串（用于 UI）
function TransformManager.get_current_state_display(config, character)
    if not config then return "" end
    if config.is_parallel then
        return ""
    end

    local t_type = config.transform_type
    if t_type and ConditionRegistry[t_type] then
        local _, state = get_active_rule_for_type(t_type, config, character, "")
        if state ~= nil then
            if t_type == "weapon" then
                return (state == "sheathed") and T("weapon_sheathed") or T("weapon_drawn")
            elseif t_type == "scroll" then
                return (state == "red") and T("scroll_red") or T("scroll_blue")
            elseif t_type == "longsword" then
                local level_names = {
                    [0] = T("spirit_level_0"),
                    [1] = T("spirit_level_1"),
                    [2] = T("spirit_level_2"),
                    [3] = T("spirit_level_3")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "dual_blades" then
                local state_names = {
                    [0] = T("dual_normal"),
                    [1] = T("dual_kijin"),
                    [2] = T("dual_enhancement")
                }
                return state_names[state] or tostring(state)
            elseif t_type == "switch_axe" then
                local state_names = {
                    [0] = T("switch_axe_axe"),
                    [1] = T("switch_axe_sword"),
                    [2] = T("switch_axe_awakened")
                }
                return state_names[state] or tostring(state)
            elseif t_type == "charge_axe" then
                local state_names = {
                    [0] = T("charge_axe_axe"),
                    [1] = T("charge_axe_sword"),
                    [2] = T("charge_axe_axe_enhanced"),
                    [3] = T("charge_axe_shield"),
                    [4] = T("charge_axe_sword_enhanced"),
                    [5] = T("charge_axe_triple")
                }
                return state_names[state] or tostring(state)
            elseif t_type == "greatsword_level" then
                local level_names = {
                    [0] = T("greatsword_level_0"),
                    [1] = T("greatsword_level_1"),
                    [2] = T("greatsword_level_2"),
                    [3] = T("greatsword_level_3")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "hammer" then
                local level_names = {
                    [0] = T("hammer_level_0"),
                    [1] = T("hammer_level_1"),
                    [2] = T("hammer_level_2")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "bow" then
                local level_names = {
                    [0] = T("bow_level_0"),
                    [1] = T("bow_level_1"),
                    [2] = T("bow_level_2"),
                    [3] = T("bow_level_3")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "monster_hp" then
                if state then
                    return string.format("%.1f%%", state)
                else
                    return T("no_monster_target")
                end
            else
                return tostring(state)
            end
        end
    end

    local default_preset = config.default_preset
    if default_preset and default_preset ~= "" then
        return string.format(T("default_preset_display") or "Default: %s", default_preset)
    end
    return T("no_active_condition") or "None"
end

-- 获取当前状态的原始值（用于 UI 中的阈值比较等）
function TransformManager.get_current_raw_state(config, character)
    if not config then return nil end
    if config.is_parallel then return nil end
    local t_type = config.transform_type
    if not t_type or not ConditionRegistry[t_type] then return nil end
    local _, state = get_active_rule_for_type(t_type, config, character, "")
    return state
end

-- 以下函数用于 UI 判断模块是否可用（总是返回 true，因为所有条件模块已实现）
function TransformManager.has_weapon_getter() return true end
function TransformManager.has_scroll_getter() return true end
function TransformManager.has_longsword_getter() return true end
function TransformManager.has_dual_blades_getter() return true end
function TransformManager.has_switch_axe_getter() return true end
function TransformManager.has_charge_axe_getter() return true end
function TransformManager.has_greatsword_level_getter() return true end
function TransformManager.has_hammer_getter() return true end
function TransformManager.has_bow_getter() return true end
function TransformManager.has_monster_hp_getter() return true end

return TransformManager