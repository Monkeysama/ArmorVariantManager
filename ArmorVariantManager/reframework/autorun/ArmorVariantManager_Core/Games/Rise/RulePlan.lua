local Plan = require("ArmorVariantManager_Core.Rules.Plan")

-- 保留崛起旧字段及原始状态值，存储格式不随共享引擎改变。
return Plan.new({
    weapon = { field = "weapon_transform_rules", value = "state",
        normalize = function(value) return value and "drawn" or "sheathed" end },
    scroll = { field = "scroll_transform_rules", value = "state" },
    monster_hp = { field = "monster_hp_transform_rules", value = "threshold", threshold = true },
    longsword = { field = "longsword_transform_rules", value = "level" },
    dual_blades = { field = "dual_blades_transform_rules", value = "state" },
    switch_axe = { field = "switch_axe_transform_rules", value = "state" },
    charge_axe = { field = "charge_axe_transform_rules", value = "state" },
    greatsword_level = { field = "greatsword_level_transform_rules", value = "level" },
    hammer = { field = "hammer_transform_rules", value = "level" },
    bow = { field = "bow_transform_rules", value = "level" },
})
