-- Wilds 9f2d14d：旧入口的配置补全片段，只作行为对照，不随新实现修改。
local parallel_condition_order = {
    "hp", "weapon", "damage", "spirit", "dual_blades", "switch_axe",
    "insect_glaive", "charge_blade", "greatsword_type", "greatsword_level",
    "bow_level", "hammer_level"
}

-- 创建完整的并行条件默认配置，统一所有新建和缺失配置的优先级来源。
local function create_default_parallel_settings()
    local settings = {}
    for index, key in ipairs(parallel_condition_order) do
        settings[key] = { enabled = key == "hp", priority = index }
    end
    return settings
end

-- 补齐旧 JSON 的并行条件。仅当检测到完整的旧版默认序列时重排，保留用户自定义优先级。
local function normalize_parallel_settings(settings)
    if type(settings) ~= "table" then return create_default_parallel_settings() end
    local legacy_order = {
        "hp", "weapon", "spirit", "dual_blades", "switch_axe", "insect_glaive",
        "charge_blade", "greatsword_type", "greatsword_level", "bow_level", "hammer_level"
    }
    local legacy_default = type(settings.damage) ~= "table"
    if legacy_default then
        for index, key in ipairs(legacy_order) do
            local item = settings[key]
            if type(item) ~= "table" or item.enabled ~= (key == "hp")
                or tonumber(item.priority) ~= index then
                legacy_default = false
                break
            end
        end
    end
    for index, key in ipairs(parallel_condition_order) do
        if type(settings[key]) ~= "table" then
            settings[key] = { enabled = key == "hp", priority = index }
        else
            if settings[key].enabled == nil then settings[key].enabled = false end
            if tonumber(settings[key].priority) == nil then settings[key].priority = index end
        end
    end
    if legacy_default then
        for index, key in ipairs(parallel_condition_order) do
            settings[key].priority = index
        end
    end
    return settings
end


return function(loaded_data)
    -- 确保结构完整
    if not loaded_data.presets then loaded_data.presets = {} end
    if not loaded_data.default_preset then loaded_data.default_preset = "" end
    if not loaded_data.groups then loaded_data.groups = {} end
    if not loaded_data.group_order then loaded_data.group_order = {} end
    if not loaded_data.preset_order then loaded_data.preset_order = {} end
    -- 确保各分组也有 preset_order
    for _, g_data in pairs(loaded_data.groups) do
        if not g_data.preset_order then g_data.preset_order = {} end
    end
    if not loaded_data.transform_type then loaded_data.transform_type = "hp" end
    if loaded_data.is_parallel == nil then loaded_data.is_parallel = false end
    loaded_data.parallel_settings = normalize_parallel_settings(loaded_data.parallel_settings)

    -- 数据迁移：将原来 HP 中的 trigger_on_damage 迁移到新的 damage 节点
    local migrated_damage = false
    if loaded_data.transform_rules then
        for i = #loaded_data.transform_rules, 1, -1 do
            local r = loaded_data.transform_rules[i]
            if r.trigger_on_damage then
                if not loaded_data.damage_transform_rules then
                    loaded_data.damage_transform_rules = { { duration = r.duration or 5, targets = r.targets or {} } }
                end
                table.remove(loaded_data.transform_rules, i)
                migrated_damage = true
            end
        end
    end

    if not loaded_data.transform_rules then loaded_data.transform_rules = {} end
    if not loaded_data.damage_transform_rules then loaded_data.damage_transform_rules = { { duration = 5, targets = {} } } end
    if not loaded_data.weapon_transform_rules then
        loaded_data.weapon_transform_rules = {
            { state = "sheathed", targets = {} },
            { state = "drawn", targets = {} }
        }
    end
    if not loaded_data.spirit_transform_rules then
        loaded_data.spirit_transform_rules = {
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} },
            { level = 4, targets = {} }
        }
    end
    if not loaded_data.dual_blades_transform_rules then
        loaded_data.dual_blades_transform_rules = {
            { state = "normal", targets = {} },
            { state = "kijin", targets = {} },
            { state = "enhancement", targets = {} }
        }
    end
    if not loaded_data.switch_axe_transform_rules then
        loaded_data.switch_axe_transform_rules = {
            { state = "sword_normal", targets = {} },
            { state = "sword_awakened", targets = {} },
            { state = "axe_normal", targets = {} },
            { state = "axe_enhanced", targets = {} }
        }
    end
    if not loaded_data.insect_glaive_transform_rules then
        loaded_data.insect_glaive_transform_rules = {
            { state = "none", targets = {} },
            { state = "white", targets = {} },
            { state = "orange", targets = {} },
            { state = "red", targets = {} },
            { state = "triple", targets = {} }
        }
    end
    if not loaded_data.charge_blade_transform_rules then
        loaded_data.charge_blade_transform_rules = {
            { state = "sword", targets = {} },
            { state = "axe", targets = {} },
            { state = "sword_shield", targets = {} },
            { state = "sword_sword", targets = {} },
            { state = "sword_shield_sword", targets = {} },
            { state = "axe_axe", targets = {} },
            { state = "triple", targets = {} }
        }
    end
    if not loaded_data.greatsword_type_transform_rules then
        loaded_data.greatsword_type_transform_rules = {
            { state = "0", targets = {} },
            { state = "1", targets = {} },
            { state = "2", targets = {} },
            { state = "3", targets = {} },
            { state = "5", targets = {} },
            { state = "other", targets = {} }
        }
    end
    if not loaded_data.greatsword_level_transform_rules then
        loaded_data.greatsword_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    end
    if not loaded_data.bow_level_transform_rules then
        loaded_data.bow_level_transform_rules = {
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} },
            { level = 4, targets = {} }
        }
    end
    if not loaded_data.hammer_level_transform_rules then
        loaded_data.hammer_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    end
    return loaded_data
end
