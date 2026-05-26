local mod_name = "ArmorVariantManager"
local version = "2.0.0"
local author = "Moon"
-- Ported from MHWS version
-- Original author: MK

local global_config_path = "ArmorVariantManager/GlobalSettings.json"
local global_config = {
    language = "zh",
    scan_interval = 0.5,
    body_id_ttl = 1.0,
    scanner_batch_size = 200
}

local Localization = require("ArmorVariantManager_Core.Localization")
local Utils = require("ArmorVariantManager_Core.Utils")
local TransformManager = require("ArmorVariantManager_Core.TransformManager")

local function T(key)
    if not key then return "nil" end
    local lang = global_config.language or "en"
    if not Localization[lang] then lang = "en" end
    return Localization[lang][key] or tostring(key)
end

local function load_global_settings()
    local loaded = json.load_file(global_config_path)
    if loaded then
        if loaded.language then global_config.language = loaded.language end
        if loaded.scan_interval then global_config.scan_interval = loaded.scan_interval end
        if loaded.body_id_ttl then global_config.body_id_ttl = loaded.body_id_ttl end
        if loaded.scanner_batch_size then global_config.scanner_batch_size = loaded.scanner_batch_size end
    end
end
local function save_global_settings()
    json.dump_file(global_config_path, global_config)
end
load_global_settings()

-- 缓存常用类型和方法
local type_mesh = nil
local method_cache = {
    Component_get_GameObject = sdk.find_type_definition("via.Component"):get_method("get_GameObject"),
    GameObject_get_Name = sdk.find_type_definition("via.GameObject"):get_method("get_Name"),
    GameObject_getComponent = sdk.find_type_definition("via.GameObject"):get_method("getComponent(System.Type)"),
    Scene_findComponents = sdk.find_type_definition("via.Scene"):get_method("findComponents(System.Type)")
}
local type_cache = {
    via_transform = sdk.typeof("via.Transform"),
    app_character = sdk.typeof("app.Character"),
    app_hunter_character = sdk.typeof("app.HunterCharacter")
}

-- 状态变量
local last_body_id = nil
local body_id_cache = {}
local loaded_configs = {}
local active_overrides = {}
local current_config = {
    default_preset = "",
    presets = {},
    groups = {},
    enable_transform = false,
    transform_type = "weapon",
    is_parallel = false,
    parallel_settings = {
        weapon = { enabled = true, priority = 1 },
        scroll = { enabled = false, priority = 2 },
        longsword = { enabled = false, priority = 3 },
        dual_blades = { enabled = false, priority = 4 },
        switch_axe = { enabled = false, priority = 5 },
        charge_axe = { enabled = false, priority = 6 },
        greatsword_level = { enabled = false, priority = 7 },
        hammer = { enabled = false, priority = 8 },
        bow = { enabled = false, priority = 9 },
        monster_hp = { enabled = false, priority = 10 }
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
local PART_INDEX_TO_NAME = {
    [0] = "helm",
    [1] = "body",
    [2] = "arm",
    [3] = "waist",
    [4] = "leg"
}

-- UI 状态
local new_preset_name = ""
local selected_preset_index = 1
local preset_names_list = {}
local auto_find_log = ""
local current_group_name = ""
local selected_group_index = 1
local group_names_list = {}
local new_group_name = ""
local is_selection_mode = false
local pending_material_selections = {}

-- 辅助函数
local function deep_copy_table(orig) return Utils.deep_copy_table(orig) end
local function get_type(name) return Utils.get_type(name) end
local function get_player_manager() return Utils.get_player_manager() end
local function get_master_player() return Utils.get_master_player() end

-- 获取本地玩家角色 GameObject
local function get_local_player_character()
    local master = get_master_player()
    if master then
        local game_obj = master:call("get_GameObject")
        if game_obj and sdk.is_managed_object(game_obj) then
            return game_obj
        end
    end
    local scene_manager = sdk.get_native_singleton("via.SceneManager")
    if scene_manager then
        local scene = sdk.call_native_func(scene_manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if scene then
            local transforms = scene:call("findComponents(System.Type)", type_cache.via_transform)
            if transforms then
                local list = transforms:get_elements()
                for _, t in ipairs(list) do
                    local ok, game_obj = pcall(method_cache.Component_get_GameObject.call, method_cache.Component_get_GameObject, t)
                    if ok and game_obj then
                        local name = game_obj:call("get_Name")
                        if name and string.find(name:lower(), "player") then
                            local transform = game_obj:call("get_Transform")
                            local child = transform:call("get_Child")
                            while child do
                                local child_obj = child:call("get_GameObject")
                                if child_obj then
                                    local child_name = child_obj:call("get_Name")
                                    if child_name and string.find(child_name, "body") then
                                        return game_obj
                                    end
                                end
                                child = child:call("get_Next")
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- 获取 Body ID（优先返回包含 "body" 的子物体）
local function get_character_body_id(character)
    if not character then return nil end
    if not sdk.is_managed_object(character) then return nil end
    local transform = character:call("get_Transform")
    if transform then
        local child = transform:call("get_Child")
        local body_name = nil
        local any_name = nil
        while child do
            local child_obj = child:call("get_GameObject")
            if child_obj then
                local name = child_obj:call("get_Name")
                if name then
                    if string.find(name, "body") then
                        body_name = name
                        break
                    elseif not any_name and (string.find(name, "helm") or string.find(name, "arm") or string.find(name, "wst") or string.find(name, "leg")) then
                        any_name = name
                    end
                end
            end
            child = child:call("get_Next")
        end
        if body_name then return body_name end
        if any_name then return any_name end
    end
    local name = character:call("get_Name")
    if name and (string.find(name, "body") or string.find(name, "helm") or string.find(name, "arm") or string.find(name, "wst") or string.find(name, "leg")) then
        return name
    end
    return nil
end

local function get_body_id()
    local player_obj = get_local_player_character()
    if not player_obj then return nil end
    return get_character_body_id(player_obj)
end

local function get_config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end

-- ========== 修复变身规则（仅确保结构，不自动填充空条件） ==========
local function fix_transform_rules(rules)
    if not rules or type(rules) ~= "table" then return end
    for _, rule in ipairs(rules) do
        if not rule.targets or type(rule.targets) ~= "table" then
            rule.targets = {}
        end
    end
end

-- 确保 parallel_settings 结构完整
local function fix_parallel_settings(settings)
    if not settings or type(settings) ~= "table" then
        return {
            weapon = { enabled = true, priority = 1 },
            scroll = { enabled = false, priority = 2 },
            longsword = { enabled = false, priority = 3 },
            dual_blades = { enabled = false, priority = 4 },
            switch_axe = { enabled = false, priority = 5 },
            charge_axe = { enabled = false, priority = 6 },
            greatsword_level = { enabled = false, priority = 7 },
            hammer = { enabled = false, priority = 8 },
            bow = { enabled = false, priority = 9 },
            monster_hp = { enabled = false, priority = 10 }
        }
    end
    if settings.weapon == nil then settings.weapon = { enabled = true, priority = 1 } end
    if settings.scroll == nil then settings.scroll = { enabled = false, priority = 2 } end
    if settings.longsword == nil then settings.longsword = { enabled = false, priority = 3 } end
    if settings.dual_blades == nil then settings.dual_blades = { enabled = false, priority = 4 } end
    if settings.switch_axe == nil then settings.switch_axe = { enabled = false, priority = 5 } end
    if settings.charge_axe == nil then settings.charge_axe = { enabled = false, priority = 6 } end
    if settings.greatsword_level == nil then settings.greatsword_level = { enabled = false, priority = 7 } end
    if settings.hammer == nil then settings.hammer = { enabled = false, priority = 8 } end
    if settings.bow == nil then settings.bow = { enabled = false, priority = 9 } end
    if settings.monster_hp == nil then settings.monster_hp = { enabled = false, priority = 10 } end
    return settings
end

-- 根据分组和预设名获取预设数据（用于直接应用）
local function get_preset_data_by_group(group_name, preset_name)
    if not preset_name then return nil end
    if group_name == "" or group_name == nil then
        if current_config.presets then
            return current_config.presets[preset_name]
        end
    else
        if current_config.groups and current_config.groups[group_name] and current_config.groups[group_name].presets then
            return current_config.groups[group_name].presets[preset_name]
        end
    end
    return nil
end

-- 预设管理核心函数
local function update_preset_names_list()
    preset_names_list = {}
    local target_presets = nil
    if current_group_name == "" then
        if current_config and current_config.presets then
            target_presets = current_config.presets
        end
    else
        if current_config and current_config.groups and current_config.groups[current_group_name] then
            target_presets = current_config.groups[current_group_name].presets or {}
        else
            target_presets = {}
        end
    end
    if target_presets then
        for name, _ in pairs(target_presets) do
            table.insert(preset_names_list, name)
        end
        table.sort(preset_names_list)
    end
    local ctx_default = ""
    if current_group_name == "" then
        ctx_default = current_config and current_config.default_preset or ""
    else
        if current_config and current_config.groups and current_config.groups[current_group_name] then
            ctx_default = current_config.groups[current_group_name].default_preset or ""
        end
    end
    if ctx_default ~= "" then
        local found = false
        for i, name in ipairs(preset_names_list) do
            if name == ctx_default then
                selected_preset_index = i
                found = true
                break
            end
        end
        if not found then selected_preset_index = 1 end
    else
        selected_preset_index = 1
    end
    if #preset_names_list == 0 then
        selected_preset_index = 1
    elseif selected_preset_index > #preset_names_list then
        selected_preset_index = 1
    end
end

local function update_group_names_list()
    group_names_list = {}
    if current_config and current_config.groups then
        for name, _ in pairs(current_config.groups) do
            table.insert(group_names_list, name)
        end
        table.sort(group_names_list)
    end
    if #group_names_list == 0 then
        selected_group_index = 1
    elseif selected_group_index > #group_names_list then
        selected_group_index = 1
    end
end

local function get_mesh_component_recursive(game_obj)
    if not game_obj then return nil end
    if not sdk.is_managed_object(game_obj) then return nil end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return nil end
    end
    local mesh = game_obj:call("getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh then return mesh end
    local transform = game_obj:call("get_Transform")
    if transform then
        local child = transform:call("get_Child")
        while child do
            local child_obj = child:call("get_GameObject")
            if child_obj then
                mesh = child_obj:call("getComponent(System.Type)", type_mesh:get_runtime_type())
                if mesh then return mesh end
            end
            child = child:call("get_Next")
        end
    end
    return nil
end

local function get_character_part(character, part_index)
    if not character then return nil end
    local transform = character:call("get_Transform")
    if not transform then return nil end
    local child = transform:call("get_Child")
    while child do
        local child_obj = child:call("get_GameObject")
        if child_obj then
            local name = child_obj:call("get_Name")
            if name then
                local target_index = nil
                if string.find(name, "body") then target_index = 1
                elseif string.find(name, "helm") then target_index = 0
                elseif string.find(name, "arm") then target_index = 2
                elseif string.find(name, "wst") then target_index = 3
                elseif string.find(name, "leg") then target_index = 4
                end
                if target_index == part_index then
                    return child_obj
                end
            end
        end
        child = child:call("get_Next")
    end
    return nil
end

local function get_material_group_owner(part_index, mat_name)
    if not mat_name then return nil end
    if not current_config or not current_config.groups then return nil end
    local s_idx = tostring(part_index)
    for g_name, g_data in pairs(current_config.groups) do
        if g_data and g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
            return g_name
        end
    end
    return nil
end

local function is_material_in_current_context(part_index, mat_name)
    local owner = get_material_group_owner(part_index, mat_name)
    if current_group_name == "" then
        return owner == nil
    else
        return owner == current_group_name
    end
end

local function apply_preset_to_character(character, preset_data, ignore_context)
    if not character or not preset_data then return end
    if not sdk.is_managed_object(character) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end
    for i = 0, 4 do
        local part_obj = get_character_part(character, i)
        if part_obj then
            local part_data = preset_data[tostring(i)]
            if part_data then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    if part_data.mesh_enabled ~= nil then
                        mesh_component:call("set_Enabled", part_data.mesh_enabled)
                    end
                    if part_data.materials then
                        local mat_count = mesh_component:call("get_MaterialNum")
                        if mat_count then
                            for j = 0, mat_count - 1 do
                                local mat_name = mesh_component:call("getMaterialName", j)
                                if ignore_context or is_material_in_current_context(i, mat_name) then
                                    local mat_enabled = part_data.materials[mat_name]
                                    if mat_enabled ~= nil then
                                        mesh_component:call("setMaterialsEnable", j, mat_enabled)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function create_new_group(group_name, body_id)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    local has_selection = false
    for _, v in pairs(pending_material_selections) do
        if next(v) then has_selection = true break end
    end
    if not has_selection then return false end
    if not current_config.groups then current_config.groups = {} end
    if current_config.groups[group_name] then return false end
    local new_group = {
        mask = deep_copy_table(pending_material_selections),
        presets = {}
    }
    if current_config.presets then
        for _, preset_data in pairs(current_config.presets) do
            for part_idx_str, mats in pairs(new_group.mask) do
                if preset_data[part_idx_str] and preset_data[part_idx_str].materials then
                    local p_mats = preset_data[part_idx_str].materials
                    for m_name, _ in pairs(mats) do
                        p_mats[m_name] = nil
                    end
                end
            end
        end
    end
    current_config.groups[group_name] = new_group
    pending_material_selections = {}
    is_selection_mode = false
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

local function delete_group(group_name, body_id)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    if not current_config.groups or not current_config.groups[group_name] then return false end
    current_config.groups[group_name] = nil
    if current_group_name == group_name then
        current_group_name = ""
        selected_group_index = 1
        update_preset_names_list()
    end
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

local function load_config_data(body_id)
    if not body_id then return nil end
    if loaded_configs[body_id] then return loaded_configs[body_id] end
    local path = get_config_path(body_id)
    local loaded_data = json.load_file(path)
    if loaded_data then
        if not loaded_data.presets then loaded_data.presets = {} end
        if not loaded_data.default_preset then loaded_data.default_preset = "" end
        if not loaded_data.groups then loaded_data.groups = {} end
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
        loaded_configs[body_id] = loaded_data
        return loaded_data
    end
    return nil
end

local function merge_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            overrides[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                overrides[p_idx].materials[mat_name] = is_enabled
            end
        end
    end
end

local function apply_all_defaults(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    active_overrides[body_id] = {}
    if not config.enable_transform then
        if config.default_preset and config.default_preset ~= "" and config.presets then
            local def = config.presets[config.default_preset]
            if def then merge_preset_into_overrides(body_id, def) end
        end
        if config.groups then
            for _, g_data in pairs(config.groups) do
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then merge_preset_into_overrides(body_id, g_def) end
                end
            end
        end
    end
end

local function get_current_preset_data(preset_name)
    if current_group_name == "" then
        if current_config and current_config.presets then
            return current_config.presets[preset_name]
        end
    else
        if current_config and current_config.groups and current_config.groups[current_group_name] then
            return current_config.groups[current_group_name].presets[preset_name]
        end
    end
    return nil
end

local function apply_preset(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_body_id = get_body_id()
    if current_body_id then
        merge_preset_into_overrides(current_body_id, preset_data)
    end
    local player_obj = get_local_player_character()
    if player_obj then
        apply_preset_to_character(player_obj, active_overrides[current_body_id], true)
    end
end

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
            longsword = { enabled = false, priority = 3 },
            dual_blades = { enabled = false, priority = 4 },
            switch_axe = { enabled = false, priority = 5 },
            charge_axe = { enabled = false, priority = 6 },
            greatsword_level = { enabled = false, priority = 7 },
            hammer = { enabled = false, priority = 8 },
            bow = { enabled = false, priority = 9 },
            monster_hp = { enabled = false, priority = 10 }
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

local function save_current_config_to_file(body_id)
    if not body_id then return end
    loaded_configs[body_id] = current_config
    local path = get_config_path(body_id)
    json.dump_file(path, current_config)
end

local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_body_id() end
    if not body_id then return false end
    local player_obj = get_local_player_character()
    if not player_obj then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = {}
    for i = 0, 4 do
        local part_obj = get_character_part(player_obj, i)
        if part_obj then
            local mesh_component = get_mesh_component_recursive(part_obj)
            if mesh_component then
                local part_data = {
                    mesh_enabled = mesh_component:call("get_Enabled"),
                    materials = {}
                }
                local mat_count = mesh_component:call("get_MaterialNum")
                if mat_count then
                    for j = 0, mat_count - 1 do
                        local mat_name = mesh_component:call("getMaterialName", j)
                        if is_material_in_current_context(i, mat_name) then
                            local is_mat_enabled = mesh_component:call("getMaterialsEnable", j)
                            part_data.materials[mat_name] = is_mat_enabled
                        end
                    end
                end
                if next(part_data.materials) or current_group_name == "" then
                    new_preset_data[tostring(i)] = part_data
                end
            end
        end
    end
    if current_group_name == "" then
        if not current_config.presets then current_config.presets = {} end
        current_config.presets[preset_name] = new_preset_data
    else
        if not current_config.groups then current_config.groups = {} end
        if not current_config.groups[current_group_name] then
            current_config.groups[current_group_name] = { presets = {}, mask = {} }
        end
        if not current_config.groups[current_group_name].presets then
            current_config.groups[current_group_name].presets = {}
        end
        current_config.groups[current_group_name].presets[preset_name] = new_preset_data
    end
    update_preset_names_list()
    save_current_config_to_file(body_id)
    return true
end

local function find_auto_preset(target_body_id)
    if not target_body_id then return false, "No Body ID" end
    local player_obj = get_local_player_character()
    if not player_obj then return false, "No Character" end
    local body_part = get_character_part(player_obj, 1)
    if not body_part then return false, "Body part not found" end
    local mesh = get_mesh_component_recursive(body_part)
    if not mesh then return false, "Mesh not found" end
    local current_mats = {}
    local mat_count = mesh:call("get_MaterialNum")
    if not mat_count or mat_count == 0 then return false, "No materials on Body" end
    for i = 0, mat_count - 1 do
        local name = mesh:call("getMaterialName", i)
        if name then current_mats[name] = true end
    end
    if not fs or not fs.glob then return false, "fs.glob missing" end
    local search_patterns = {
        "reframework/data/ArmorVariantManager/.*\\.json",
        "reframework\\\\data\\\\ArmorVariantManager\\\\.*\\.json",
        "ArmorVariantManager/.*\\.json",
        "ArmorVariantManager\\\\.*\\.json",
        "data/ArmorVariantManager/.*\\.json"
    }
    local files = {}
    for _, pattern in ipairs(search_patterns) do
        local found = fs.glob(pattern)
        if found and #found > 0 then
            for _, f in ipairs(found) do table.insert(files, f) end
        end
    end
    if #files == 0 then return false, "No preset files found" end
    for _, file in ipairs(files) do
        if not string.find(file, target_body_id) then
            local load_path = file
            local data_prefix = "reframework\\data\\"
            local s, e = string.find(file, data_prefix)
            if not s then
                data_prefix = "reframework/data/"
                s, e = string.find(file, data_prefix)
            end
            if e then load_path = string.sub(file, e + 1) end
            local data = json.load_file(load_path)
            if not data then data = json.load_file(file) end
            if data and data.presets then
                local first_preset = nil
                for _, preset in pairs(data.presets) do first_preset = preset break end
                if first_preset and first_preset["1"] and first_preset["1"].materials then
                    local preset_mats = first_preset["1"].materials
                    local match = true
                    local match_count = 0
                    for mat_name, _ in pairs(preset_mats) do
                        if not current_mats[mat_name] then match = false break end
                        match_count = match_count + 1
                    end
                    if match and match_count > 0 then
                        current_config = data
                        save_current_config_to_file(target_body_id)
                        update_preset_names_list()
                        return true, "Success! Loaded from " .. file
                    end
                end
            end
        end
    end
    return false, "No matching preset found"
end

local function draw_mesh_toggle(game_object, label, body_id, part_index)
    if not game_object then return end
    if not sdk.is_managed_object(game_object) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then
            imgui.text_colored(label .. " " .. T("type_loading"), 0xFF808080)
            return
        end
    end
    local mesh_component = game_object:call("getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh_component then
        if imgui.tree_node(label) then
            local is_enabled = mesh_component:call("get_Enabled")
            local changed, new_value = imgui.checkbox(T("enable_mesh"), is_enabled)
            if changed then
                mesh_component:call("set_Enabled", new_value)
                if body_id and part_index then
                    local s_idx = tostring(part_index)
                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                    active_overrides[body_id][s_idx].mesh_enabled = new_value
                end
            end
            local mat_count = mesh_component:call("get_MaterialNum")
            if mat_count and mat_count > 0 then
                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")
                local s_idx = tostring(part_index)
                for i = 0, mat_count - 1 do
                    local mat_name = mesh_component:call("getMaterialName", i)
                    if mat_name then
                        local is_mat_enabled = mesh_component:call("getMaterialsEnable", i)
                        local owner = get_material_group_owner(part_index, mat_name)
                        if is_selection_mode then
                            local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                            if owner then
                                imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF808080)
                            else
                                local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                if changed_sel then
                                    if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                    pending_material_selections[s_idx][mat_name] = new_sel
                                end
                            end
                        else
                            if is_material_in_current_context(part_index, mat_name) then
                                local mat_label = string.format("[%d] %s", i, mat_name)
                                local mat_changed, mat_new_val = imgui.checkbox(mat_label, is_mat_enabled)
                                if mat_changed then
                                    mesh_component:call("setMaterialsEnable", i, mat_new_val)
                                    if body_id and part_index then
                                        if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                        if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                        if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                        active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                    end
                                end
                            else
                                if current_group_name == "" and owner then
                                    imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF804040)
                                end
                            end
                        end
                    end
                end
            end
            imgui.tree_pop()
        end
    else
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end

-- 辅助函数：绘制条件的目标列表
local function draw_targets_ui(targets, rule_type, rule_idx, body_id, player_obj)
    for j, target in ipairs(targets) do
        imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)
        -- 分组选择
        local all_groups = { "" }
        local all_groups_display = { T("main_list") or "Main" }
        if current_config.groups then
            for gname, _ in pairs(current_config.groups) do
                table.insert(all_groups, gname)
                table.insert(all_groups_display, gname)
            end
        end
        local g_idx = 1
        for idx, g in ipairs(all_groups) do
            if g == (target.group or "") then g_idx = idx; break end
        end
        imgui.set_next_item_width(120)
        local c_g, v_g = imgui.combo("##group", g_idx, all_groups_display)
        if c_g then
            target.group = all_groups[v_g]
            target.preset = ""
            save_current_config_to_file(body_id)
        end
        imgui.same_line()
        -- 预设选择
        local target_presets = {}
        if target.group == "" or target.group == nil then
            if current_config.presets then
                for pname, _ in pairs(current_config.presets) do table.insert(target_presets, pname) end
            end
        else
            if current_config.groups and current_config.groups[target.group] and current_config.groups[target.group].presets then
                for pname, _ in pairs(current_config.groups[target.group].presets) do table.insert(target_presets, pname) end
            end
        end
        table.sort(target_presets)
        local p_idx = 1
        for idx, p in ipairs(target_presets) do
            if p == target.preset then p_idx = idx; break end
        end
        if #target_presets == 0 then table.insert(target_presets, "None") end
        imgui.set_next_item_width(150)
        local c_p, v_p = imgui.combo("##preset", p_idx, target_presets)
        if c_p and target_presets[v_p] ~= "None" then
            target.preset = target_presets[v_p]
            save_current_config_to_file(body_id)
            -- 判断当前状态是否匹配该规则
            local should_apply = false
            if player_obj and current_config.enable_transform and not current_config.is_parallel then
                local target_state = nil
                if rule_type == "weapon" or rule_type == "weapon_para" then
                    local rules = current_config.weapon_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].state
                    end
                elseif rule_type == "scroll" or rule_type == "scroll_para" then
                    local rules = current_config.scroll_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].state
                    end
                elseif rule_type == "longsword" or rule_type == "longsword_para" then
                    local rules = current_config.longsword_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].level
                    end
                elseif rule_type == "dual_blades" or rule_type == "dual_blades_para" then
                    local rules = current_config.dual_blades_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].state
                    end
                elseif rule_type == "switch_axe" or rule_type == "switch_axe_para" then
                    local rules = current_config.switch_axe_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].state
                    end
                elseif rule_type == "charge_axe" or rule_type == "charge_axe_para" then
                    local rules = current_config.charge_axe_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].state
                    end
                elseif rule_type == "greatsword_level" or rule_type == "greatsword_level_para" then
                    local rules = current_config.greatsword_level_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].level
                    end
                elseif rule_type == "hammer" or rule_type == "hammer_para" then
                    local rules = current_config.hammer_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].level
                    end
                elseif rule_type == "bow" or rule_type == "bow_para" then
                    local rules = current_config.bow_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].level
                    end
                elseif rule_type == "monster_hp" or rule_type == "monster_hp_para" then
                    local rules = current_config.monster_hp_transform_rules
                    if rules and rules[rule_idx] then
                        target_state = rules[rule_idx].threshold
                    end
                end
                local current_state = TransformManager.get_current_raw_state(current_config, player_obj)
                if target_state ~= nil and current_state ~= nil then
                    if rule_type == "monster_hp" or rule_type == "monster_hp_para" then
                        if current_state <= target_state then
                            should_apply = true
                        end
                    else
                        if target_state == current_state then
                            should_apply = true
                        end
                    end
                end
            end
            if should_apply then
                local preset_data = get_preset_data_by_group(target.group, target.preset)
                if preset_data then
                    merge_preset_into_overrides(body_id, preset_data)
                    apply_preset_to_character(player_obj, active_overrides[body_id], true)
                end
            end
        end
        imgui.same_line()
        if imgui.button(T("delete_condition") .. "##del_cond") then
            table.remove(targets, j)
            save_current_config_to_file(body_id)
            if current_config.enable_transform and player_obj then
                local char_addr = tostring(player_obj)
                TransformManager.clear_cache(char_addr)
                local new_overrides, _ = TransformManager.apply_transform_rules(
                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                )
                active_overrides[body_id] = new_overrides
                apply_preset_to_character(player_obj, new_overrides, true)
            end
        end
        imgui.pop_id()
    end
end

-- 纯函数合并覆盖
local function merge_overrides(base, add)
    local result = deep_copy_table(base) or {}
    if not add then return result end
    for p_idx, p_data in pairs(add) do
        if not result[p_idx] then result[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            result[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not result[p_idx].materials then result[p_idx].materials = {} end
            for m, en in pairs(p_data.materials) do
                result[p_idx].materials[m] = en
            end
        end
    end
    return result
end

-- ========== 每帧更新 ==========
re.on_frame(function()
    local player_obj = get_local_player_character()
    if player_obj then
        local body_id = get_body_id()
        if body_id then
            if body_id ~= last_body_id then
                last_body_id = body_id
                active_overrides[body_id] = nil
                load_body_config(body_id)
                if not current_config.enable_transform then
                    apply_all_defaults(body_id)
                    if active_overrides[body_id] then
                        apply_preset_to_character(player_obj, active_overrides[body_id], true)
                    end
                end
            end
            if current_config.enable_transform then
                local char_addr = tostring(player_obj)
                local new_overrides, changed = TransformManager.apply_transform_rules(
                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                )
                if changed then
                    active_overrides[body_id] = new_overrides
                    apply_preset_to_character(player_obj, new_overrides, true)
                end
            end
        else
            last_body_id = nil
        end
    else
        last_body_id = nil
    end
end)

-- ========== UI 绘制 ==========
re.on_draw_ui(function()
    if imgui.tree_node(T("mod_name")) then
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()
        local status, err = pcall(function()
            local player_obj = get_local_player_character()
            if player_obj then
                local body_id = get_body_id()
                if body_id then
                    -- 预设管理区域
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                        local full_group_list = {T("main_list")}
                        for _, gname in ipairs(group_names_list) do table.insert(full_group_list, gname) end
                        local current_group_combo_index = 1
                        if current_group_name ~= "" then
                            for i, gname in ipairs(group_names_list) do
                                if gname == current_group_name then current_group_combo_index = i + 1 break end
                            end
                        end
                        if imgui.begin_table("PresetsLayout", 2, 512) then
                            imgui.table_setup_column("PresetArea", 2048, 1.0)
                            imgui.table_setup_column("GroupArea", 2048, 1.0)
                            imgui.table_next_row()
                            imgui.table_next_column()
                            imgui.text(T("preset") .. ":")
                            imgui.table_next_column()
                            imgui.text(T("group") .. ":")
                            imgui.table_next_row()
                            imgui.table_next_column()
                            imgui.set_next_item_width(-1)
                            if #preset_names_list > 0 then
                                local changed_idx, idx = imgui.combo("##preset_selector", selected_preset_index, preset_names_list)
                                if changed_idx then
                                    selected_preset_index = idx
                                    local current_preset_name = preset_names_list[selected_preset_index]
                                    if current_preset_name then apply_preset(current_preset_name) end
                                end
                            else
                                imgui.text_colored("[" .. T("no_presets") .. "]", 0xFF808080)
                            end
                            imgui.table_next_column()
                            imgui.set_next_item_width(-1)
                            local changed_g, g_idx = imgui.combo("##group_selector", current_group_combo_index, full_group_list)
                            if changed_g then
                                current_group_name = (g_idx == 1) and "" or group_names_list[g_idx - 1]
                                selected_group_index = g_idx
                                update_preset_names_list()
                            end
                            imgui.table_next_row()
                            imgui.table_next_column()
                            if #preset_names_list > 0 then
                                local current_preset_name = preset_names_list[selected_preset_index]
                                local ctx_default = (current_group_name == "") and current_config.default_preset or
                                                   (current_config.groups[current_group_name] and current_config.groups[current_group_name].default_preset)
                                if imgui.button(T("delete_preset")) then
                                    if current_group_name == "" then
                                        current_config.presets[current_preset_name] = nil
                                        if current_config.default_preset == current_preset_name then current_config.default_preset = "" end
                                    else
                                        if current_config.groups[current_group_name] then
                                            current_config.groups[current_group_name].presets[current_preset_name] = nil
                                            if current_config.groups[current_group_name].default_preset == current_preset_name then
                                                current_config.groups[current_group_name].default_preset = ""
                                            end
                                        end
                                    end
                                    update_preset_names_list()
                                    save_current_config_to_file(body_id)
                                end
                                imgui.same_line()
                                if imgui.button(T("set_as_default")) then
                                    if current_group_name == "" then
                                        current_config.default_preset = current_preset_name
                                    else
                                        if current_config.groups[current_group_name] then current_config.groups[current_group_name].default_preset = current_preset_name end
                                    end
                                    save_current_config_to_file(body_id)
                                end
                                if ctx_default == current_preset_name then
                                    imgui.same_line()
                                    imgui.text_colored(T("is_default"), 0xFF00FF00)
                                end
                            end
                            imgui.spacing()
                            imgui.text(T("create_new_preset"))
                            imgui.set_next_item_width(-1)
                            local cp, ptext = imgui.input_text("##new_preset_name_input", new_preset_name)
                            if cp then new_preset_name = ptext end
                            if imgui.button(T("save_preset") .. "##p_left") then
                                if new_preset_name ~= "" then
                                    if save_preset(new_preset_name, body_id) then
                                        new_preset_name = ""
                                        update_preset_names_list()
                                    end
                                end
                            end
                            imgui.table_next_column()
                            if not is_selection_mode then
                                if imgui.button(T("start_selection") .. "##right") then
                                    is_selection_mode = true
                                    pending_material_selections = {}
                                end
                                if current_group_name ~= "" then
                                    imgui.same_line()
                                    if imgui.button(T("delete_group") .. "##right") then
                                        delete_group(current_group_name, body_id)
                                    end
                                end
                            else
                                imgui.text_colored(T("selection_mode") .. " ", 0xFF00FFFF)
                                imgui.text_colored(T("selection_mode_desc") .. " ", 0xFF00FFFF)
                                local cg, gtext = imgui.input_text(T("name") .. "##gn", new_group_name)
                                if cg then new_group_name = gtext end
                                if imgui.button(T("confirm_creation") .. "##gconfirm") then
                                    if new_group_name ~= "" and create_new_group(new_group_name, body_id) then
                                        current_group_name = new_group_name
                                        new_group_name = ""
                                        is_selection_mode = false
                                        update_group_names_list()
                                        update_preset_names_list()
                                    end
                                end
                                imgui.same_line()
                                if imgui.button(T("cancel") .. "##gcancel") then is_selection_mode = false end
                            end
                            imgui.end_table()
                        end
                        if current_group_name ~= "" then
                            local group_data = current_config.groups[current_group_name]
                            if group_data and group_data.mask and imgui.tree_node(T("materials") .. " in " .. current_group_name) then
                                for p_idx, mats in pairs(group_data.mask) do
                                    local part_name = T(PART_INDEX_TO_NAME[tonumber(p_idx)]) or p_idx
                                    for m_name, _ in pairs(mats) do
                                        imgui.text("  • [" .. part_name .. "] " .. tostring(m_name))
                                    end
                                end
                                imgui.tree_pop()
                            end
                        end
                        local has_any_data = (next(current_config.presets) ~= nil)
                        if not has_any_data and current_config.groups then
                            for _, g in pairs(current_config.groups) do
                                if g.presets and next(g.presets) then has_any_data = true break end
                            end
                        end
                        if not has_any_data then
                            imgui.separator()
                            if imgui.button(T("auto_find_preset")) then
                                local st, res, m = pcall(find_auto_preset, body_id)
                                auto_find_log = st and (res and m or "Failed: " .. m) or "Lua Error: " .. tostring(res)
                            end
                            if auto_find_log ~= "" then imgui.text_colored(auto_find_log, 0xFF00FFFF) end
                        end
                        imgui.tree_pop()
                    end
                    -- ========== 变身管理区域 ==========
                    if imgui.tree_node(T("transform_manager")) then
                        local transform_changed = false
                        local enable_transform = current_config.enable_transform
                        local changed_enable, new_enable = imgui.checkbox(T("enable_transform"), enable_transform)
                        if changed_enable then
                            current_config.enable_transform = new_enable
                            transform_changed = true
                            if new_enable then
                                local char_addr = tostring(player_obj)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                apply_preset_to_character(player_obj, new_overrides, true)
                            else
                                apply_all_defaults(body_id)
                                if active_overrides[body_id] then
                                    apply_preset_to_character(player_obj, active_overrides[body_id], true)
                                end
                            end
                            save_current_config_to_file(body_id)
                        end
                        imgui.separator()
                        if current_config.enable_transform then
                            local current_state_str = TransformManager.get_current_state_display(current_config, player_obj)
                            if current_state_str ~= "" then
                                imgui.text(T("current_state") .. ": " .. current_state_str)
                                imgui.separator()
                            end
                            local mode_text = current_config.is_parallel and T("current_mode_parallel") or T("current_mode_selection")
                            imgui.text(mode_text)
                            local parallel_btn_text = current_config.is_parallel and T("switch_to_selection") or T("switch_to_parallel")
                            if imgui.button(parallel_btn_text) then
                                current_config.is_parallel = not current_config.is_parallel
                                save_current_config_to_file(body_id)
                            end
                            if not current_config.is_parallel then
                                -- 条件类型顺序：武器、红蓝书、怪物血量、太刀、双刀、斩斧、盾斧、大剑、大锤、弓箭
                                local c_type_idx = 1
                                if current_config.transform_type == "weapon" then c_type_idx = 1
                                elseif current_config.transform_type == "scroll" then c_type_idx = 2
                                elseif current_config.transform_type == "monster_hp" then c_type_idx = 3
                                elseif current_config.transform_type == "longsword" then c_type_idx = 4
                                elseif current_config.transform_type == "dual_blades" then c_type_idx = 5
                                elseif current_config.transform_type == "switch_axe" then c_type_idx = 6
                                elseif current_config.transform_type == "charge_axe" then c_type_idx = 7
                                elseif current_config.transform_type == "greatsword_level" then c_type_idx = 8
                                elseif current_config.transform_type == "hammer" then c_type_idx = 9
                                elseif current_config.transform_type == "bow" then c_type_idx = 10
                                end
                                local c_type_list = {
                                    T("condition_weapon"),
                                    T("condition_scroll"),
                                    T("condition_monster_hp"),
                                    T("condition_longsword"),
                                    T("condition_dual_blades"),
                                    T("condition_switch_axe"),
                                    T("condition_charge_axe"),
                                    T("condition_greatsword_level"),
                                    T("condition_hammer"),
                                    T("condition_bow")
                                }
                                local c_changed, c_val = imgui.combo(T("transform_condition_type"), c_type_idx, c_type_list)
                                if c_changed then
                                    if c_val == 1 then current_config.transform_type = "weapon"
                                    elseif c_val == 2 then current_config.transform_type = "scroll"
                                    elseif c_val == 3 then current_config.transform_type = "monster_hp"
                                    elseif c_val == 4 then current_config.transform_type = "longsword"
                                    elseif c_val == 5 then current_config.transform_type = "dual_blades"
                                    elseif c_val == 6 then current_config.transform_type = "switch_axe"
                                    elseif c_val == 7 then current_config.transform_type = "charge_axe"
                                    elseif c_val == 8 then current_config.transform_type = "greatsword_level"
                                    elseif c_val == 9 then current_config.transform_type = "hammer"
                                    else current_config.transform_type = "bow" end
                                    save_current_config_to_file(body_id)
                                end
                                -- 武器状态 (收刀/拔刀)
                                if current_config.transform_type == "weapon" then
                                    for i, rule in ipairs(current_config.weapon_transform_rules) do
                                        imgui.push_id("weapon_rule_" .. i)
                                        imgui.text(rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn"))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "weapon", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##weapon_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 红蓝书
                                elseif current_config.transform_type == "scroll" then
                                    for i, rule in ipairs(current_config.scroll_transform_rules) do
                                        imgui.push_id("scroll_rule_" .. i)
                                        imgui.text(rule.state == "red" and T("scroll_red") or T("scroll_blue"))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "scroll", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##scroll_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 怪物血量
                                elseif current_config.transform_type == "monster_hp" then
                                    local curHP = TransformManager.get_current_raw_state(current_config, player_obj)
                                    if curHP then
                                        imgui.text(string.format(T("monster_current_hp"), curHP))
                                    else
                                        imgui.text_colored(T("no_monster_target"), 0xFF808080)
                                    end
                                    imgui.separator()
                                    if imgui.button(T("add_hp_node")) then
                                        table.insert(current_config.monster_hp_transform_rules, { threshold = 50, targets = {} })
                                        save_current_config_to_file(body_id)
                                    end
                                    for i, rule in ipairs(current_config.monster_hp_transform_rules) do
                                        imgui.push_id("monster_hp_rule_" .. i)
                                        imgui.set_next_item_width(120)
                                        local c_t, v_t_str = imgui.input_text(T("monster_hp_threshold") .. "##" .. i, tostring(rule.threshold))
                                        if c_t then
                                            local num = tonumber(v_t_str)
                                            if num then
                                                if num < 0 then num = 0 end
                                                if num > 100 then num = 100 end
                                                rule.threshold = num
                                                save_current_config_to_file(body_id)
                                            end
                                        end
                                        imgui.same_line()
                                        if imgui.button(T("delete_node") .. "##" .. i) then
                                            table.remove(current_config.monster_hp_transform_rules, i)
                                            save_current_config_to_file(body_id)
                                        end
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "monster_hp", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##monster_hp_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 太刀
                                elseif current_config.transform_type == "longsword" then
                                    for i, rule in ipairs(current_config.longsword_transform_rules) do
                                        imgui.push_id("longsword_rule_" .. i)
                                        local level_names = {
                                            [0] = T("spirit_level_0"),
                                            [1] = T("spirit_level_1"),
                                            [2] = T("spirit_level_2"),
                                            [3] = T("spirit_level_3")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("%s %d", T("spirit_level"), rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "longsword", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##longsword_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 双刀
                                elseif current_config.transform_type == "dual_blades" then
                                    for i, rule in ipairs(current_config.dual_blades_transform_rules) do
                                        imgui.push_id("dual_blades_rule_" .. i)
                                        local state_names = {
                                            [0] = T("dual_normal"),
                                            [1] = T("dual_kijin"),
                                            [2] = T("dual_enhancement")
                                        }
                                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "dual_blades", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##dual_blades_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 斩斧
                                elseif current_config.transform_type == "switch_axe" then
                                    for i, rule in ipairs(current_config.switch_axe_transform_rules) do
                                        imgui.push_id("switch_axe_rule_" .. i)
                                        local state_names = {
                                            [0] = T("switch_axe_axe"),
                                            [1] = T("switch_axe_sword"),
                                            [2] = T("switch_axe_awakened")
                                        }
                                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "switch_axe", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##switch_axe_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 盾斧
                                elseif current_config.transform_type == "charge_axe" then
                                    for i, rule in ipairs(current_config.charge_axe_transform_rules) do
                                        imgui.push_id("charge_axe_rule_" .. i)
                                        local state_names = {
                                            [0] = T("charge_axe_axe"),
                                            [1] = T("charge_axe_sword"),
                                            [2] = T("charge_axe_axe_enhanced"),
                                            [3] = T("charge_axe_shield"),
                                            [4] = T("charge_axe_sword_enhanced"),
                                            [5] = T("charge_axe_triple")
                                        }
                                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "charge_axe", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##charge_axe_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 大剑蓄力等级
                                elseif current_config.transform_type == "greatsword_level" then
                                    for i, rule in ipairs(current_config.greatsword_level_transform_rules) do
                                        imgui.push_id("greatsword_level_rule_" .. i)
                                        local level_names = {
                                            [0] = T("greatsword_level_0"),
                                            [1] = T("greatsword_level_1"),
                                            [2] = T("greatsword_level_2"),
                                            [3] = T("greatsword_level_3")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("%s %d", T("greatsword_level"), rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "greatsword_level", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##greatsword_level_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 大锤蓄力等级
                                elseif current_config.transform_type == "hammer" then
                                    for i, rule in ipairs(current_config.hammer_transform_rules) do
                                        imgui.push_id("hammer_rule_" .. i)
                                        local level_names = {
                                            [0] = T("hammer_level_0"),
                                            [1] = T("hammer_level_1"),
                                            [2] = T("hammer_level_2")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "hammer", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##hammer_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                -- 弓箭蓄力等级
                                elseif current_config.transform_type == "bow" then
                                    for i, rule in ipairs(current_config.bow_transform_rules) do
                                        imgui.push_id("bow_rule_" .. i)
                                        local level_names = {
                                            [0] = T("bow_level_0"),
                                            [1] = T("bow_level_1"),
                                            [2] = T("bow_level_2"),
                                            [3] = T("bow_level_3")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "bow", i, body_id, player_obj)
                                        if imgui.button("+ " .. T("add_condition") .. "##bow_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(player_obj)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _ = TransformManager.apply_transform_rules(
                                                    char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                apply_preset_to_character(player_obj, new_overrides, true)
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                end
                            else
                                -- 并行模式
                                imgui.indent(10)
                                local function draw_parallel_setting(cond_key, label)
                                    local set = current_config.parallel_settings[cond_key]
                                    if not set then return end
                                    local changed_en, val_en = imgui.checkbox(T("enable") .. " " .. label, set.enabled)
                                    if changed_en then set.enabled = val_en; save_current_config_to_file(body_id) end
                                    imgui.same_line()
                                    imgui.set_next_item_width(80)
                                    local changed_pri, val_pri = imgui.input_text(T("priority") .. "##" .. cond_key, tostring(set.priority))
                                    if changed_pri then
                                        local p = tonumber(val_pri)
                                        if p then set.priority = p; save_current_config_to_file(body_id) end
                                    end
                                end
                                draw_parallel_setting("weapon", T("condition_weapon"))
                                draw_parallel_setting("scroll", T("condition_scroll"))
                                draw_parallel_setting("monster_hp", T("condition_monster_hp"))
                                draw_parallel_setting("longsword", T("condition_longsword"))
                                draw_parallel_setting("dual_blades", T("condition_dual_blades"))
                                draw_parallel_setting("switch_axe", T("condition_switch_axe"))
                                draw_parallel_setting("charge_axe", T("condition_charge_axe"))
                                draw_parallel_setting("greatsword_level", T("condition_greatsword_level"))
                                draw_parallel_setting("hammer", T("condition_hammer"))
                                draw_parallel_setting("bow", T("condition_bow"))
                                imgui.unindent(10)
                                if imgui.tree_node(T("parallel_rules_details")) then
                                    if current_config.parallel_settings.weapon.enabled then
                                        imgui.text(T("condition_weapon"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.weapon_transform_rules) do
                                            imgui.push_id("weapon_para_rule_" .. i)
                                            imgui.text(rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn"))
                                            draw_targets_ui(rule.targets, "weapon_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##weapon_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.scroll.enabled then
                                        imgui.text(T("condition_scroll"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.scroll_transform_rules) do
                                            imgui.push_id("scroll_para_rule_" .. i)
                                            imgui.text(rule.state == "red" and T("scroll_red") or T("scroll_blue"))
                                            draw_targets_ui(rule.targets, "scroll_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##scroll_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.monster_hp.enabled then
                                        imgui.text(T("condition_monster_hp"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.monster_hp_transform_rules) do
                                            imgui.push_id("monster_hp_para_rule_" .. i)
                                            imgui.set_next_item_width(120)
                                            local c_t, v_t_str = imgui.input_text(T("monster_hp_threshold") .. "##" .. i, tostring(rule.threshold))
                                            if c_t then
                                                local num = tonumber(v_t_str)
                                                if num then
                                                    if num < 0 then num = 0 end
                                                    if num > 100 then num = 100 end
                                                    rule.threshold = num
                                                    save_current_config_to_file(body_id)
                                                end
                                            end
                                            imgui.same_line()
                                            if imgui.button(T("delete_node") .. "##" .. i) then
                                                table.remove(current_config.monster_hp_transform_rules, i)
                                                save_current_config_to_file(body_id)
                                            end
                                            draw_targets_ui(rule.targets, "monster_hp_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##monster_hp_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                            end
                                            imgui.separator()
                                            imgui.pop_id()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.longsword.enabled then
                                        imgui.text(T("condition_longsword"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.longsword_transform_rules) do
                                            imgui.push_id("longsword_para_rule_" .. i)
                                            local level_names = {
                                                [0] = T("spirit_level_0"),
                                                [1] = T("spirit_level_1"),
                                                [2] = T("spirit_level_2"),
                                                [3] = T("spirit_level_3")
                                            }
                                            imgui.text(level_names[rule.level] or string.format("%s %d", T("spirit_level"), rule.level))
                                            draw_targets_ui(rule.targets, "longsword_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##longsword_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.dual_blades.enabled then
                                        imgui.text(T("condition_dual_blades"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.dual_blades_transform_rules) do
                                            imgui.push_id("dual_blades_para_rule_" .. i)
                                            local state_names = {
                                                [0] = T("dual_normal"),
                                                [1] = T("dual_kijin"),
                                                [2] = T("dual_enhancement")
                                            }
                                            imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                            draw_targets_ui(rule.targets, "dual_blades_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##dual_blades_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.switch_axe.enabled then
                                        imgui.text(T("condition_switch_axe"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.switch_axe_transform_rules) do
                                            imgui.push_id("switch_axe_para_rule_" .. i)
                                            local state_names = {
                                                [0] = T("switch_axe_axe"),
                                                [1] = T("switch_axe_sword"),
                                                [2] = T("switch_axe_awakened")
                                            }
                                            imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                            draw_targets_ui(rule.targets, "switch_axe_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##switch_axe_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.charge_axe.enabled then
                                        imgui.text(T("condition_charge_axe"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.charge_axe_transform_rules) do
                                            imgui.push_id("charge_axe_para_rule_" .. i)
                                            local state_names = {
                                                [0] = T("charge_axe_axe"),
                                                [1] = T("charge_axe_sword"),
                                                [2] = T("charge_axe_axe_enhanced"),
                                                [3] = T("charge_axe_shield"),
                                                [4] = T("charge_axe_sword_enhanced"),
                                                [5] = T("charge_axe_triple")
                                            }
                                            imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                            draw_targets_ui(rule.targets, "charge_axe_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##charge_axe_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.greatsword_level.enabled then
                                        imgui.text(T("condition_greatsword_level"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.greatsword_level_transform_rules) do
                                            imgui.push_id("greatsword_level_para_rule_" .. i)
                                            local level_names = {
                                                [0] = T("greatsword_level_0"),
                                                [1] = T("greatsword_level_1"),
                                                [2] = T("greatsword_level_2"),
                                                [3] = T("greatsword_level_3")
                                            }
                                            imgui.text(level_names[rule.level] or string.format("%s %d", T("greatsword_level"), rule.level))
                                            draw_targets_ui(rule.targets, "greatsword_level_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##greatsword_level_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.hammer.enabled then
                                        imgui.text(T("condition_hammer"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.hammer_transform_rules) do
                                            imgui.push_id("hammer_para_rule_" .. i)
                                            local level_names = {
                                                [0] = T("hammer_level_0"),
                                                [1] = T("hammer_level_1"),
                                                [2] = T("hammer_level_2")
                                            }
                                            imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                                            draw_targets_ui(rule.targets, "hammer_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##hammer_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    if current_config.parallel_settings.bow.enabled then
                                        imgui.text(T("condition_bow"))
                                        imgui.indent(20)
                                        for i, rule in ipairs(current_config.bow_transform_rules) do
                                            imgui.push_id("bow_para_rule_" .. i)
                                            local level_names = {
                                                [0] = T("bow_level_0"),
                                                [1] = T("bow_level_1"),
                                                [2] = T("bow_level_2"),
                                                [3] = T("bow_level_3")
                                            }
                                            imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                                            draw_targets_ui(rule.targets, "bow_para", i, body_id, player_obj)
                                            if imgui.button("+ " .. T("add_condition") .. "##bow_para_add_" .. i) then
                                                local default_preset = current_config.default_preset or ""
                                                if default_preset == "" and next(current_config.presets) then
                                                    for name, _ in pairs(current_config.presets) do
                                                        default_preset = name
                                                        break
                                                    end
                                                end
                                                table.insert(rule.targets, { group = "", preset = default_preset })
                                                save_current_config_to_file(body_id)
                                                if current_config.enable_transform then
                                                    local char_addr = tostring(player_obj)
                                                    TransformManager.clear_cache(char_addr)
                                                    local new_overrides, _ = TransformManager.apply_transform_rules(
                                                        char_addr, current_config, player_obj, active_overrides[body_id] or {}, merge_overrides
                                                    )
                                                    active_overrides[body_id] = new_overrides
                                                    apply_preset_to_character(player_obj, new_overrides, true)
                                                end
                                            end
                                            imgui.pop_id()
                                            imgui.separator()
                                        end
                                        imgui.unindent(20)
                                    end
                                    imgui.tree_pop()
                                end
                            end
                        end
                        imgui.tree_pop()
                    end
                    -- 防具部件列表
                    local armor_parts = {
                        [0] = T("helm"),
                        [1] = T("body"),
                        [2] = T("arm"),
                        [3] = T("waist"),
                        [4] = T("leg")
                    }
                    if imgui.tree_node(T("armor_parts")) then
                        for i = 0, 4 do
                            local part_obj = get_character_part(player_obj, i)
                            local part_name = armor_parts[i]
                            if part_obj then
                                local mesh_comp = get_mesh_component_recursive(part_obj)
                                if mesh_comp then
                                    local mesh_game_obj = mesh_comp:call("get_GameObject")
                                    local obj_name = mesh_game_obj:call("get_Name")
                                    draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, i)
                                else
                                    local obj_name = part_obj:call("get_Name")
                                    imgui.text_colored(string.format("%s [%s] (No Mesh)", part_name, obj_name), 0xFF808080)
                                end
                            else
                                imgui.text_colored(part_name .. " " .. T("not_equipped"), 0xFF808080)
                            end
                        end
                        imgui.tree_pop()
                    end
                    imgui.separator()
                    -- 语言设置
                    if imgui.tree_node(T("language")) then
                        local is_en = global_config.language == "en"
                        local changed_en, new_en = imgui.checkbox("English", is_en)
                        if changed_en and new_en then
                            global_config.language = "en"
                            save_global_settings()
                        end
                        imgui.same_line()
                        local is_zh = global_config.language == "zh"
                        local changed_zh, new_zh = imgui.checkbox("中文", is_zh)
                        if changed_zh and new_zh then
                            global_config.language = "zh"
                            save_global_settings()
                        end
                        imgui.tree_pop()
                    end
                    imgui.separator()
                    -- 性能设置
                    if imgui.tree_node(T("performance_settings")) then
                        imgui.text(T("performance_desc"))
                        imgui.spacing()
                        local changed_si, val_si = imgui.slider_float(T("scan_interval"), global_config.scan_interval, 0.1, 5.0)
                        if changed_si then
                            global_config.scan_interval = val_si
                            save_global_settings()
                        end
                        local changed_ttl, val_ttl = imgui.slider_float(T("refresh_interval"), global_config.body_id_ttl, 0.1, 10.0)
                        if changed_ttl then
                            global_config.body_id_ttl = val_ttl
                            save_global_settings()
                        end
                        local changed_bs, val_bs = imgui.slider_int(T("scanner_batch_size"), global_config.scanner_batch_size, 10, 1000)
                        if changed_bs then
                            global_config.scanner_batch_size = val_bs
                            save_global_settings()
                        end
                        imgui.tree_pop()
                    end
                else
                    imgui.text_colored(T("no_body_part"), 0xFF0000FF)
                end
            else
                imgui.text_colored(T("waiting_for_player"), 0xFF0000FF)
            end
        end)
        if not status then
            imgui.text_colored(T("lua_error") .. tostring(err), 0xFF0000FF)
        end
        imgui.tree_pop()
    end
end)