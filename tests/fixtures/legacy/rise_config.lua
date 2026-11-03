-- Rise 093c61c：旧入口的配置补全片段，只作行为对照，不随新实现修改。
local function fix_transform_rules(rules)
    if not rules or type(rules) ~= "table" then return end
    for _, rule in ipairs(rules) do
        if not rule.targets or type(rule.targets) ~= "table" then
            rule.targets = {}
        end
    end
end

local function fix_parallel_settings(settings)
    if not settings or type(settings) ~= "table" then
        return {
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
        }
    end
    if settings.weapon == nil then settings.weapon = { enabled = true, priority = 1 } end
    if settings.scroll == nil then settings.scroll = { enabled = false, priority = 2 } end
    if settings.monster_hp == nil then settings.monster_hp = { enabled = false, priority = 3 } end
    if settings.longsword == nil then settings.longsword = { enabled = false, priority = 4 } end
    if settings.dual_blades == nil then settings.dual_blades = { enabled = false, priority = 5 } end
    if settings.switch_axe == nil then settings.switch_axe = { enabled = false, priority = 6 } end
    if settings.charge_axe == nil then settings.charge_axe = { enabled = false, priority = 7 } end
    if settings.greatsword_level == nil then settings.greatsword_level = { enabled = false, priority = 8 } end
    if settings.hammer == nil then settings.hammer = { enabled = false, priority = 9 } end
    if settings.bow == nil then settings.bow = { enabled = false, priority = 10 } end
    return settings
end


return function(loaded_data)
    -- 以下为原有的补全逻辑（确保所有字段存在）
    if not loaded_data.presets then loaded_data.presets = {} end
    if not loaded_data.default_preset then loaded_data.default_preset = "" end
    if not loaded_data.groups then loaded_data.groups = {} end
    if not loaded_data.group_order then loaded_data.group_order = {} end
    if not loaded_data.preset_order then loaded_data.preset_order = {} end

    -- === 为老版本预设自动生成 preset_order（按字母排序） ===
    if loaded_data.presets and next(loaded_data.presets) then
        if not loaded_data.preset_order or #loaded_data.preset_order == 0 then
            loaded_data.preset_order = {}
            for name, _ in pairs(loaded_data.presets) do
                table.insert(loaded_data.preset_order, name)
            end
            table.sort(loaded_data.preset_order)
        end
    end

    -- 补充分组的 is_global 和预设顺序
    for _, g_data in pairs(loaded_data.groups) do
        if g_data.is_global == nil then g_data.is_global = false end
        if not g_data.preset_order then
            g_data.preset_order = {}
        end
        -- 为分组预设自动生成顺序
        if g_data.presets and next(g_data.presets) and #g_data.preset_order == 0 then
            for name, _ in pairs(g_data.presets) do
                table.insert(g_data.preset_order, name)
            end
            table.sort(g_data.preset_order)
        end
    end

    if loaded_data.enable_transform == nil then loaded_data.enable_transform = false end
    if loaded_data.transform_type == nil then loaded_data.transform_type = "weapon" end
    if loaded_data.is_parallel == nil then loaded_data.is_parallel = false end
    loaded_data.parallel_settings = fix_parallel_settings(loaded_data.parallel_settings)
    if loaded_data.weapon_transform_rules == nil then
        loaded_data.weapon_transform_rules = {
            { state = "sheathed", targets = {} },
            { state = "drawn", targets = {} }
        }
    end
    if loaded_data.scroll_transform_rules == nil then
        loaded_data.scroll_transform_rules = {
            { state = "red", targets = {} },
            { state = "blue", targets = {} }
        }
    end
    if loaded_data.longsword_transform_rules == nil then
        loaded_data.longsword_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    end
    if loaded_data.dual_blades_transform_rules == nil then
        loaded_data.dual_blades_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} }
        }
    end
    if loaded_data.switch_axe_transform_rules == nil then
        loaded_data.switch_axe_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} }
        }
    end
    if loaded_data.charge_axe_transform_rules == nil then
        loaded_data.charge_axe_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} },
            { state = 3, targets = {} },
            { state = 4, targets = {} },
            { state = 5, targets = {} }
        }
    end
    if loaded_data.greatsword_level_transform_rules == nil then
        loaded_data.greatsword_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    end
    if loaded_data.hammer_transform_rules == nil then
        loaded_data.hammer_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} }
        }
    end
    if loaded_data.bow_transform_rules == nil then
        loaded_data.bow_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    end
    if loaded_data.monster_hp_transform_rules == nil then
        loaded_data.monster_hp_transform_rules = {}
    end
    fix_transform_rules(loaded_data.weapon_transform_rules)
    fix_transform_rules(loaded_data.scroll_transform_rules)
    fix_transform_rules(loaded_data.longsword_transform_rules)
    fix_transform_rules(loaded_data.dual_blades_transform_rules)
    fix_transform_rules(loaded_data.switch_axe_transform_rules)
    fix_transform_rules(loaded_data.charge_axe_transform_rules)
    fix_transform_rules(loaded_data.greatsword_level_transform_rules)
    fix_transform_rules(loaded_data.hammer_transform_rules)
    fix_transform_rules(loaded_data.bow_transform_rules)
    fix_transform_rules(loaded_data.monster_hp_transform_rules)
    return loaded_data
end
