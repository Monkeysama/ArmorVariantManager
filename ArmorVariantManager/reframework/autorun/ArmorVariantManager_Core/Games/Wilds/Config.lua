local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local Config = {}

local condition_order = {
    "hp", "weapon", "damage", "spirit", "dual_blades", "switch_axe",
    "insect_glaive", "charge_blade", "greatsword_type", "greatsword_level", "bow_level", "hammer_level"
}
local definitions = {
    weapon_transform_rules = { key = "state", values = { "sheathed", "drawn" } },
    spirit_transform_rules = { key = "level", values = { 1, 2, 3, 4 } },
    dual_blades_transform_rules = { key = "state", values = { "normal", "kijin", "enhancement" } },
    switch_axe_transform_rules = { key = "state", values = { "sword_normal", "sword_awakened", "axe_normal", "axe_enhanced" } },
    insect_glaive_transform_rules = { key = "state", values = { "none", "white", "orange", "red", "triple" } },
    charge_blade_transform_rules = { key = "state", values = { "sword", "axe", "sword_shield", "sword_sword", "sword_shield_sword", "axe_axe", "triple" } },
    greatsword_type_transform_rules = { key = "state", values = { "0", "1", "2", "3", "5", "other" } },
    greatsword_level_transform_rules = { key = "level", values = { 0, 1, 2, 3 } },
    bow_level_transform_rules = { key = "level", values = { 1, 2, 3, 4 } },
    hammer_level_transform_rules = { key = "level", values = { 0, 1, 2, 3 } }
}

-- 优先级数值越小越高，默认只启用血量条件。
function Config.default_parallel_settings()
    local settings = {}
    for index, key in ipairs(condition_order) do
        settings[key] = { enabled = key == "hp", priority = index }
    end
    return settings
end

-- 仅识别完整旧默认序列；自定义顺序和未知条件原样保留。
function Config.normalize_parallel_settings(settings)
    if type(settings) ~= "table" then return Config.default_parallel_settings() end
    local legacy_order = {
        "hp", "weapon", "spirit", "dual_blades", "switch_axe", "insect_glaive",
        "charge_blade", "greatsword_type", "greatsword_level", "bow_level", "hammer_level"
    }
    local legacy_default = type(settings.damage) ~= "table"
    if legacy_default then
        for index, key in ipairs(legacy_order) do
            local item = settings[key]
            if type(item) ~= "table" or item.enabled ~= (key == "hp") or tonumber(item.priority) ~= index then
                legacy_default = false
                break
            end
        end
    end
    for index, key in ipairs(condition_order) do
        if type(settings[key]) ~= "table" then
            settings[key] = { enabled = key == "hp", priority = index }
        else
            if settings[key].enabled == nil then settings[key].enabled = false end
            if tonumber(settings[key].priority) == nil then settings[key].priority = index end
        end
        if legacy_default then settings[key].priority = index end
    end
    return settings
end

-- 保留荒野的字段名、默认值及已有受击规则迁移行为。
function Config.normalize(data)
    if not data.transform_type then data.transform_type = "hp" end
    if data.is_parallel == nil then data.is_parallel = false end
    data.parallel_settings = Config.normalize_parallel_settings(data.parallel_settings)
    if data.transform_rules then
        for index = #data.transform_rules, 1, -1 do
            local rule = data.transform_rules[index]
            if rule.trigger_on_damage then
                if not data.damage_transform_rules then
                    data.damage_transform_rules = { { duration = rule.duration or 5, targets = rule.targets or {} } }
                end
                table.remove(data.transform_rules, index)
            end
        end
    end
    if not data.transform_rules then data.transform_rules = {} end
    if not data.damage_transform_rules then data.damage_transform_rules = { { duration = 5, targets = {} } } end
    Normalize.rules(data, definitions, false)
end

return Config
