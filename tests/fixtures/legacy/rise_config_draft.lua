-- 093c61c 原入口的新装备配置与加载操作。
return function(env)
    local _ENV = env
    local function load_body_config(body_id)
    if not body_id then return false end
    current_config = {
        default_preset = "",
        presets = {},
        groups = {},
        enable_transform = false,
        transform_type = "weapon",
        is_parallel = false,
        parallel_settings = {
            weapon = { enabled = true, priority = 1 },
            scroll = { enabled = false, priority = 2 },
            monster_hp = { enabled = false, priority = 3 },
            longsword = { enabled = false, priority = 4 },
            dual_blades = { enabled = false, priority = 5 },
            switch_axe = { enabled = false, priority = 6 },
            charge_axe = { enabled = false, priority = 7 },
            greatsword_level = { enabled = false, priority = 8 },
            hammer = { enabled = false, priority = 9 },
            bow = { enabled = false, priority = 10 }
        },
        weapon_transform_rules = {
            { state = "sheathed", targets = {} },
            { state = "drawn", targets = {} }
        },
        scroll_transform_rules = {
            { state = "red", targets = {} },
            { state = "blue", targets = {} }
        },
        longsword_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        dual_blades_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} }
        },
        switch_axe_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} }
        },
        charge_axe_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} },
            { state = 3, targets = {} },
            { state = 4, targets = {} },
            { state = 5, targets = {} }
        },
        greatsword_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        hammer_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} }
        },
        bow_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        monster_hp_transform_rules = {}
    }
    local data = load_config_data(body_id)
    if data then
        current_config = data
        loaded_configs[body_id] = current_config
    end
    update_group_names_list()
    update_preset_names_list()
    if data then
        apply_all_defaults(body_id)
        return true
    end
    return false
end
    return function() return {
    default_preset = "",
    presets = {},
    groups = {},
    enable_transform = false,
    transform_type = "weapon",
    is_parallel = false,
    parallel_settings = {
        weapon = { enabled = true, priority = 1 },
        scroll = { enabled = false, priority = 2 },
        monster_hp = { enabled = false, priority = 3 },
        longsword = { enabled = false, priority = 4 },
        dual_blades = { enabled = false, priority = 5 },
        switch_axe = { enabled = false, priority = 6 },
        charge_axe = { enabled = false, priority = 7 },
        greatsword_level = { enabled = false, priority = 8 },
        hammer = { enabled = false, priority = 9 },
        bow = { enabled = false, priority = 10 }
    },
    weapon_transform_rules = {
        { state = "sheathed", targets = {} },
        { state = "drawn", targets = {} }
    },
    scroll_transform_rules = {
        { state = "red", targets = {} },
        { state = "blue", targets = {} }
    },
    longsword_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    dual_blades_transform_rules = {
        { state = 0, targets = {} },
        { state = 1, targets = {} },
        { state = 2, targets = {} }
    },
    switch_axe_transform_rules = {
        { state = 0, targets = {} },
        { state = 1, targets = {} },
        { state = 2, targets = {} }
    },
    charge_axe_transform_rules = {
        { state = 0, targets = {} },
        { state = 1, targets = {} },
        { state = 2, targets = {} },
        { state = 3, targets = {} },
        { state = 4, targets = {} },
        { state = 5, targets = {} }
    },
    greatsword_level_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    hammer_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} }
    },
    bow_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    monster_hp_transform_rules = {}
} end, load_body_config
end
