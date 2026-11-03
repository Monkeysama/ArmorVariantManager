local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local Config = {}

local condition_order = {
    "weapon", "scroll", "monster_hp", "longsword", "dual_blades",
    "switch_axe", "charge_axe", "greatsword_level", "hammer", "bow"
}
local definitions = {
    weapon_transform_rules = { key = "state", values = { "sheathed", "drawn" } },
    scroll_transform_rules = { key = "state", values = { "red", "blue" } },
    longsword_transform_rules = { key = "level", values = { 0, 1, 2, 3 } },
    dual_blades_transform_rules = { key = "state", values = { 0, 1, 2 } },
    switch_axe_transform_rules = { key = "state", values = { 0, 1, 2 } },
    charge_axe_transform_rules = { key = "state", values = { 0, 1, 2, 3, 4, 5 } },
    greatsword_level_transform_rules = { key = "level", values = { 0, 1, 2, 3 } },
    hammer_transform_rules = { key = "level", values = { 0, 1, 2 } },
    bow_transform_rules = { key = "level", values = { 0, 1, 2, 3 } },
    monster_hp_transform_rules = { key = "threshold", values = {} }
}

-- 崛起旧配置仅补缺失条件，不重排用户已有优先级。
function Config.normalize_parallel_settings(settings)
    if type(settings) ~= "table" then settings = {} end
    for index, key in ipairs(condition_order) do
        if settings[key] == nil then settings[key] = { enabled = key == "weapon", priority = index } end
    end
    return settings
end

local function fill_preset_order(owner)
    if owner.presets and next(owner.presets) and #owner.preset_order == 0 then
        for name in pairs(owner.presets) do owner.preset_order[#owner.preset_order + 1] = name end
        table.sort(owner.preset_order)
    end
end

-- 崛起的顺序补齐、数值状态和 targets 修复不影响荒野配置。
function Config.normalize(data)
    fill_preset_order(data)
    for _, group in pairs(data.groups) do
        if group.is_global == nil then group.is_global = false end
        fill_preset_order(group)
    end
    if data.enable_transform == nil then data.enable_transform = false end
    if data.transform_type == nil then data.transform_type = "weapon" end
    if data.is_parallel == nil then data.is_parallel = false end
    data.parallel_settings = Config.normalize_parallel_settings(data.parallel_settings)
    Normalize.rules(data, definitions, true)
    for field in pairs(definitions) do
        if type(data[field]) == "table" then
            for _, rule in ipairs(data[field]) do
                if type(rule.targets) ~= "table" then rule.targets = {} end
            end
        end
    end
end

return Config
