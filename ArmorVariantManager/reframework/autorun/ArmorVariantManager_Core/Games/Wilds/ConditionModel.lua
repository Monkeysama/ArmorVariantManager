local Model = { default_selected = "hp", default_target_preset = false }

local function fixed(id, key, values, labels)
    local states = {}
    for index, value in ipairs(values) do
        states[index] = { value = value, label = labels and labels[index] or id .. "_" .. tostring(value) }
    end
    return { id = id, field = id .. "_transform_rules", state_key = key, states = states, fields = {} }
end

-- 只描述荒野旧字段；读取模型不会补写或迁移配置。
Model.definitions = {
    { id = "hp", field = "transform_rules", variable = true,
        fields = { { key = "threshold", label = "hp_percent", kind = "number", min = 1, max = 100, default = 50 } } },
    fixed("weapon", "state", { "sheathed", "drawn" }),
    { id = "damage", field = "damage_transform_rules", damage = true, fields = {
        { key = "mode", label = "action_mode", kind = "select", default = 1,
            options = { { value = 1, label = "mode_normal" }, { value = 2, label = "mode_loop" }, { value = 3, label = "mode_chain" } } },
        { key = "condition_delay", label = "condition_delay", kind = "number", min = 0, default = 0 },
        { key = "duration", label = "duration", kind = "number", min = 0, default = 5, modes = { 1, 2 } },
        { key = "loop_inactive_time", label = "loop_inactive_time", kind = "number", min = 0, default = 0, modes = { 2 } },
        { key = "loop_count", label = "loop_count", kind = "number", min = 0, default = 0, modes = { 2 } },
        { key = "chain_loop_count", label = "chain_loop_count", kind = "number", min = 0, default = 1, modes = { 3 } },
    } },
    fixed("spirit", "level", { 1, 2, 3, 4 }, { "spirit_level_1", "spirit_level_2", "spirit_level_3", "spirit_level_4" }),
    fixed("dual_blades", "state", { "normal", "kijin", "enhancement" }, { "dual_normal", "dual_kijin", "dual_enhancement" }),
    fixed("switch_axe", "state", { "sword_normal", "sword_awakened", "axe_normal", "axe_enhanced" }),
    fixed("insect_glaive", "state", { "none", "white", "orange", "red", "triple" }),
    fixed("charge_blade", "state", { "sword", "axe", "sword_shield", "sword_sword", "sword_shield_sword", "axe_axe", "triple" }),
    fixed("greatsword_type", "state", { "0", "1", "2", "3", "5", "other" }),
    fixed("greatsword_level", "level", { 0, 1, 2, 3 }),
    fixed("bow_level", "level", { 1, 2, 3, 4 }),
    fixed("hammer_level", "level", { 0, 1, 2, 3 }),
}

return Model
