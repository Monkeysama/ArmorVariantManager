-- 02b90e9 原入口的新装备配置与加载操作。
return function(env)
    local _ENV = env
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

    local function load_body_config(body_id)
    if not body_id then return false end
    -- 1. 重置当前内存配置，确保切换到新 Body 时不残留旧数据
    current_config = {
        default_preset = "",
        presets = {},
        groups = {},
        transform_type = "hp",
        is_parallel = false,
        parallel_settings = create_default_parallel_settings(),
        transform_rules = {},
        weapon_transform_rules = {
            { state = "sheathed", targets = {} },
            { state = "drawn", targets = {} }
        },
        spirit_transform_rules = {
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} },
            { level = 4, targets = {} }
        },
        dual_blades_transform_rules = {
            { state = "normal", targets = {} },
            { state = "kijin", targets = {} },
            { state = "enhancement", targets = {} }
        },
        switch_axe_transform_rules = {
            { state = "sword_normal", targets = {} },
            { state = "sword_awakened", targets = {} },
            { state = "axe_normal", targets = {} },
            { state = "axe_enhanced", targets = {} }
        },
        insect_glaive_transform_rules = {
            { state = "none", targets = {} },
            { state = "white", targets = {} },
            { state = "orange", targets = {} },
            { state = "red", targets = {} },
            { state = "triple", targets = {} }
        },
        charge_blade_transform_rules = {
            { state = "sword", targets = {} },
            { state = "axe", targets = {} },
            { state = "sword_shield", targets = {} },
            { state = "sword_sword", targets = {} },
            { state = "sword_shield_sword", targets = {} },
            { state = "axe_axe", targets = {} },
            { state = "triple", targets = {} }
        },
        greatsword_type_transform_rules = {
            { state = "0", targets = {} },
            { state = "1", targets = {} },
            { state = "2", targets = {} },
            { state = "3", targets = {} },
            { state = "5", targets = {} },
            { state = "other", targets = {} }
        },
        greatsword_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        bow_level_transform_rules = {
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} },
            { level = 4, targets = {} }
        },
        hammer_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    }
    -- 2. 尝试加载数据
    local data = load_config_data(body_id)
    if data then
        current_config = data
        -- 写入缓存，避免重复尝试加载
        loaded_configs[body_id] = current_config
    end
    -- 3. 始终更新 UI 列表索引和名称列表，即使加载失败也要清除 UI
    update_group_names_list()
    update_preset_names_list()
    if data then
        -- 核心修复：调用 apply_all_defaults 进行全量合并加载
        apply_all_defaults(body_id)
        return true
    end
    return false
end
    return function() return {
    default_preset = "",
    presets = {},
    groups = {},
    transform_type = "hp",
    is_parallel = false,
    parallel_settings = create_default_parallel_settings(),
    transform_rules = {},
    weapon_transform_rules = {
        { state = "sheathed", targets = {} },
        { state = "drawn", targets = {} }
    },
    spirit_transform_rules = {
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} },
        { level = 4, targets = {} }
    },
    dual_blades_transform_rules = {
        { state = "normal", targets = {} },
        { state = "kijin", targets = {} },
        { state = "enhancement", targets = {} }
    },
    switch_axe_transform_rules = {
        { state = "sword_normal", targets = {} },
        { state = "sword_awakened", targets = {} },
        { state = "axe_normal", targets = {} },
        { state = "axe_enhanced", targets = {} }
    },
    insect_glaive_transform_rules = {
        { state = "none", targets = {} },
        { state = "white", targets = {} },
        { state = "orange", targets = {} },
        { state = "red", targets = {} },
        { state = "triple", targets = {} }
    },
    charge_blade_transform_rules = {
        { state = "sword", targets = {} },
        { state = "axe", targets = {} },
        { state = "sword_shield", targets = {} },
        { state = "sword_sword", targets = {} },
        { state = "sword_shield_sword", targets = {} },
        { state = "axe_axe", targets = {} },
        { state = "triple", targets = {} }
    },
    greatsword_type_transform_rules = {
        { state = "0", targets = {} },
        { state = "1", targets = {} },
        { state = "2", targets = {} },
        { state = "3", targets = {} },
        { state = "5", targets = {} },
        { state = "other", targets = {} }
    },
    greatsword_level_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    bow_level_transform_rules = {
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} },
        { level = 4, targets = {} }
    },
    hammer_level_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    }
} end, load_body_config
end
