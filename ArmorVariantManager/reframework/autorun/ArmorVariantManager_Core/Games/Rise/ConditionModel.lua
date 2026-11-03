local Model = { default_selected = "weapon", enabled_field = "enable_transform", default_target_preset = true }

local function fixed(id, key, values, labels)
    local states = {}
    for index, value in ipairs(values) do
        states[index] = { value = value, label = labels and labels[index] or id .. "_" .. tostring(value) }
    end
    return { id = id, field = id .. "_transform_rules", state_key = key, states = states, fields = {} }
end

-- 崛起状态保留数值类型，不能与荒野同名条件的字符串状态混用。
Model.definitions = {
    fixed("weapon", "state", { "sheathed", "drawn" }),
    fixed("scroll", "state", { "red", "blue" }),
    { id = "monster_hp", field = "monster_hp_transform_rules", variable = true,
        fields = { { key = "threshold", label = "monster_hp_threshold", kind = "number", min = 0, max = 100, default = 50 } } },
    fixed("longsword", "level", { 0, 1, 2, 3 }, { "spirit_level_0", "spirit_level_1", "spirit_level_2", "spirit_level_3" }),
    fixed("dual_blades", "state", { 0, 1, 2 }, { "dual_normal", "dual_kijin", "dual_enhancement" }),
    fixed("switch_axe", "state", { 0, 1, 2 }, { "switch_axe_axe", "switch_axe_sword", "switch_axe_awakened" }),
    fixed("charge_axe", "state", { 0, 1, 2, 3, 4, 5 },
        { "charge_axe_axe", "charge_axe_sword", "charge_axe_axe_enhanced", "charge_axe_shield", "charge_axe_sword_enhanced", "charge_axe_triple" }),
    fixed("greatsword_level", "level", { 0, 1, 2, 3 }),
    fixed("hammer", "level", { 0, 1, 2 }, { "hammer_level_0", "hammer_level_1", "hammer_level_2" }),
    fixed("bow", "level", { 0, 1, 2, 3 }, { "bow_level_0", "bow_level_1", "bow_level_2", "bow_level_3" }),
}

return Model
