local mod_name = "ArmorVariantManager"
local version = "4.1.0"
local author = "MK,Moon,AZUSA"
local global_config_path = "ArmorVariantManager/GlobalSettings.json"
local global_config = {
    language = "zh", 
    scan_interval = 0.5, 
    body_id_ttl = 1.0, 
    scanner_batch_size = 200, 
    new_ui_enabled = true, 
    new_ui_key = 0x24, 
    auto_set_selected_preset_as_default = true 
}
local Localization = require("ArmorVariantManager_Core.Localization")
local TransformManager = require("ArmorVariantManager_Core.TransformManager")
local refd2d_module_names = {
    "ArmorVariantManager_Core.UI.VariantManagerUI",
    "ArmorVariantManager_Core.Documentation",
    "ArmorVariantManager_UI",
    "ArmorVariantManager_UI.Component.Runtime",
    "ArmorVariantManager_UI.Component.Button",
    "ArmorVariantManager_UI.Component.Checkbox",
    "ArmorVariantManager_UI.Component.Input",
    "ArmorVariantManager_UI.Component.InputNumber",
    "ArmorVariantManager_UI.Component.List",
    "ArmorVariantManager_UI.Component.Panel",
    "ArmorVariantManager_UI.Component.Select",
    "ArmorVariantManager_UI.Component.Slider",
    "ArmorVariantManager_UI.Component.Tag",
    "ArmorVariantManager_UI.Component.Window",
    "ArmorVariantManager_UI.Service.BridgeRuntime",
    "ArmorVariantManager_UI.Service.InputBlocker",
    "ArmorVariantManager_UI.Service.NativeTextInput"
}
if package and package.loaded then
    for _, module_name in ipairs(refd2d_module_names) do
        package.loaded[module_name] = nil
    end
end
local VariantManagerUI = require("ArmorVariantManager_Core.UI.VariantManagerUI")
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
        if loaded.new_ui_enabled ~= nil then global_config.new_ui_enabled = loaded.new_ui_enabled end
        if loaded.new_ui_key then global_config.new_ui_key = loaded.new_ui_key end
        if loaded.auto_set_selected_preset_as_default ~= nil then
            global_config.auto_set_selected_preset_as_default = loaded.auto_set_selected_preset_as_default == true
        end
    end
end
local function save_global_settings()
    json.dump_file(global_config_path, global_config)
end
load_global_settings()
local type_player_manager = nil
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
local show_window = true
local last_body_id = nil
local body_id_cache = {} 
local loaded_configs = {} 
local temp_applied_presets = {} 
local active_overrides = {} 
local active_group_presets = {}
local config_restored = {}
local config_restore_handled = {}
local parallel_condition_order = {
    "hp", "weapon", "damage", "spirit", "dual_blades", "switch_axe",
    "insect_glaive", "charge_blade", "greatsword_type", "greatsword_level",
    "bow_level", "hammer_level"
}
local function create_default_parallel_settings()
    local settings = {}
    for index, key in ipairs(parallel_condition_order) do
        settings[key] = { enabled = key == "hp", priority = index }
    end
    return settings
end
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
local current_config = {
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
local PART_INDEX_TO_NAME = {
    [0] = "helm",
    [1] = "body",
    [2] = "arm",
    [3] = "waist",
    [4] = "leg",
    [5] = "slinger"
}
local new_preset_name = ""
local selected_preset_index = 1
local preset_names_list = {}
local auto_find_log = "" 
local test_hp_input = "100" 
local current_group_name = "" 
local selected_group_index = 1 
local group_names_list = {} 
local new_group_name = "" 
local new_group_is_global = false 
local is_selection_mode = false 
local pending_material_selections = {} 
local mat_filter_text = {}
local sort_mode = nil 
local sort_temp_list = {} 
local sort_selected_index = 1 
local function get_type(name)
    return sdk.find_type_definition(name)
end
local function deep_copy_table(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deep_copy_table(orig_key)] = deep_copy_table(orig_value)
        end
        setmetatable(copy, deep_copy_table(getmetatable(orig)))
    else 
        copy = orig
    end
    return copy
end
local function get_player_manager()
    return sdk.get_managed_singleton("app.PlayerManager")
end
local weapon_id_cache = {}
local function find_weapons_in_hierarchy(transform, depth, results)
    if depth > 5 then return end
    local child = transform:call("get_Child")
    while child do
        local child_obj = child:call("get_GameObject")
        if child_obj then
            local name = child_obj:call("get_Name")
            if name and (name == "Wp_Parent" or name == "WpSub_Parent") then
                local wp_transform = child_obj:call("get_Transform")
                if wp_transform then
                    local wp_child = wp_transform:call("get_Child")
                    while wp_child do
                        local wp_child_obj = wp_child:call("get_GameObject")
                        if wp_child_obj then
                            local wp_name = wp_child_obj:call("get_Name")
                            if wp_name and string.match(wp_name, "^it%d%d%d%d") then
                                table.insert(results, { name = wp_name, obj = wp_child_obj })
                            end
                        end
                        wp_child = wp_child:call("get_Next")
                    end
                end
            end
            if name and string.match(name, "^it%d%d%d%d_%d%d%d%d") then
                local already_added = false
                for _, v in ipairs(results) do
                    if v.name == name then already_added = true; break end
                end
                if not already_added then
                    table.insert(results, { name = name, obj = child_obj })
                end
            end
            if not (name and string.match(name, "Reserve")) then
                find_weapons_in_hierarchy(child, depth + 1, results)
            end
        end
        child = child:call("get_Next")
    end
end
local function get_character_weapon_id(character)
    if not character then return nil, nil end
    if not sdk.is_managed_object(character) then return nil, nil end
    local cache_key = nil
    local game_obj_status_cache, game_obj_cache = pcall(function() return character:call("get_GameObject") end)
    if game_obj_status_cache and game_obj_cache then
        cache_key = tostring(game_obj_cache)
    else
        cache_key = tostring(character)
    end
    local cached = weapon_id_cache[cache_key]
    local current_time = os.clock()
    local ttl = global_config.body_id_ttl or 1.0
    if cached and (current_time - cached.last_check < ttl) then
        if cached.objs and #cached.objs > 0 and sdk.is_managed_object(cached.objs[1]) then
            return cached.id, cached.objs
        end
    end
    local results = {}
    if game_obj_status_cache and game_obj_cache then
        local transform = game_obj_cache:call("get_Transform")
        if transform then
            find_weapons_in_hierarchy(transform, 0, results)
        end
    end
    if #results > 0 then
        local base_id = string.gsub(results[1].name, "_%d$", "")
        local objs = {}
        for _, v in ipairs(results) do table.insert(objs, v.obj) end
        weapon_id_cache[cache_key] = { id = base_id, objs = objs, last_check = current_time }
        return base_id, objs
    end
    weapon_id_cache[cache_key] = { id = nil, objs = nil, last_check = current_time }
    return nil, nil
end
local function get_character_body_id(character)
    if not character then return nil end
    if not sdk.is_managed_object(character) then return nil end
    local cache_key = nil
    local game_obj_status_cache, game_obj_cache = pcall(function() return character:call("get_GameObject") end)
    if game_obj_status_cache and game_obj_cache then
        cache_key = tostring(game_obj_cache)
    else
        cache_key = tostring(character)
    end
    local cached = body_id_cache[cache_key]
    local current_time = os.clock()
    local ttl = global_config.body_id_ttl or 1.0
    if cached and (current_time - cached.last_check < ttl) then
        return cached.id
    end
    local result_id = nil
    local status, body_part = pcall(function() return character:call("getParts", 1) end)
    if status and body_part then
        local name_status, name = pcall(function() return body_part:call("get_Name") end)
        if name_status and name then
            result_id = name
        end
    end
    if not result_id then
        local game_obj_status, game_obj = pcall(function() return character:call("get_GameObject") end)
        if game_obj_status and game_obj then
            local transform = game_obj:call("get_Transform")
            if transform then
                local child = transform:call("get_Child")
                local candidates = {}
                local has_non_ch00 = false
                while child do
                    local child_obj = child:call("get_GameObject")
                    if child_obj then
                        local name = child_obj:call("get_Name")
                        if name and string.match(name, "^ch%d%d_%d%d%d_%d%d%d%d?$") then
                            if not string.find(name, "^ch00") then has_non_ch00 = true end
                            table.insert(candidates, name)
                        end
                    end
                    child = child:call("get_Next")
                end
                if #candidates > 0 then
                    for _, name in ipairs(candidates) do
                        if not string.find(name, "^ch00") and string.match(name, "2$") then
                            result_id = name; break
                        end
                    end
                    if not result_id then
                        for _, name in ipairs(candidates) do
                            if not string.find(name, "^ch00") and string.match(name, "3$") then
                                result_id = name; break
                            end
                        end
                    end
                    if not result_id then
                        for _, name in ipairs(candidates) do
                            if not string.find(name, "^ch00") and string.match(name, "1$") then
                                result_id = name; break
                            end
                        end
                    end
                    if not result_id then
                        if has_non_ch00 then
                            for _, name in ipairs(candidates) do
                                if not string.find(name, "^ch00") then
                                    result_id = name; break
                                end
                            end
                        else
                            result_id = candidates[1]
                        end
                    end
                end
            end
            if not result_id then
                local name = game_obj:call("get_Name")
                local special_names = {
                    ["Pl000_00"] = true,
                    ["SaveSelect_HunterXX"] = true,
                    ["SaveSelect_HunterXY"] = true,
                    ["GuildCard_HunterXX"] = true,
                    ["GuildCard_HunterXY"] = true,
                    ["Lobby_HunterXX"] = true,
                    ["Lobby_HunterXY"] = true
                }
                if name and special_names[name] then
                    local transform = game_obj:call("get_Transform")
                    if transform and transform:call("get_Child") then
                        result_id = name
                    end
                end
            end
        end
    end
    body_id_cache[cache_key] = { id = result_id, last_check = current_time }
    return result_id
end
local character_cache = {} 
local CACHE_TTL_BUFFER = 10.0 
local last_valid_local_player = nil 
local last_valid_local_player_time = 0 
local PLAYER_PERSISTENCE_TIME = 1.0 
local scanner = {
    state = "IDLE", 
    transforms = nil, 
    count = 0,
    index = 1,
    last_scan_time = 0
}
local function update_cache_entry(char)
    if not char then return end
    local game_obj = nil
    if method_cache.Component_get_GameObject then
        local ok, obj = pcall(method_cache.Component_get_GameObject.call, method_cache.Component_get_GameObject, char)
        if ok then game_obj = obj end
    else
        game_obj = char:call("get_GameObject")
    end
    if not game_obj then return end
    local key = tostring(game_obj)
    local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
    if draw_status and is_draw == false then return end
    local body_id = get_character_body_id(char)
    if not body_id then return end
    if not string.find(body_id, "^ch03") then return end
    character_cache[key] = { char = char, last_seen = os.clock() }
end
local function tick_scanner()
    local current_time = os.clock()
    local scan_interval = global_config.scan_interval or 2.0
    if scanner.state == "IDLE" then
        if (current_time - scanner.last_scan_time > scan_interval) then
            local ttl = global_config.body_id_ttl or 1.0
            for k, v in pairs(body_id_cache) do
                if current_time - v.last_check > ttl * 2 then body_id_cache[k] = nil end
            end
            local scene_manager = sdk.get_native_singleton("via.SceneManager")
            local scene = nil
            if scene_manager then
                scene = sdk.call_native_func(scene_manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            end
            if scene then
                if type_cache.app_character then
                    local components = scene:call("findComponents(System.Type)", type_cache.app_character:get_runtime_type())
                    if components then
                        local list = components:get_elements()
                        for _, char in ipairs(list) do update_cache_entry(char) end
                    end
                end
                if method_cache.Scene_findComponents and type_cache.via_transform then
                    local transforms = method_cache.Scene_findComponents:call(scene, type_cache.via_transform)
                    if transforms then
                        scanner.transforms = transforms:get_elements()
                        scanner.count = #scanner.transforms
                        scanner.index = 1
                        scanner.state = "PROCESSING"
                    else
                        scanner.last_scan_time = current_time
                    end
                else
                    scanner.last_scan_time = current_time
                end
            else
                scanner.last_scan_time = current_time
            end
        end
    elseif scanner.state == "PROCESSING" then
        local batch_size = global_config.scanner_batch_size or 100
        local limit = scanner.index + batch_size - 1
        if limit > scanner.count then limit = scanner.count end
        for i = scanner.index, limit do
            local safe_get_transform = function()
                local t = scanner.transforms[i]
                return (t and sdk.is_managed_object(t)) and t or nil
            end
            local status, transform = pcall(safe_get_transform)
            if status and transform then
                local ok, game_obj = pcall(method_cache.Component_get_GameObject.call, method_cache.Component_get_GameObject, transform)
                if ok and game_obj and sdk.is_managed_object(game_obj) then
                    local name_ok, name = pcall(method_cache.GameObject_get_Name.call, method_cache.GameObject_get_Name, game_obj)
                    local is_target = false
                    if name_ok and name then
                        if string.sub(name, 1, 2) == "Pl" then
                            is_target = true
                        else
                            local special_names = {
                                "SaveSelect_HunterXX", "SaveSelect_HunterXY",
                                "GuildCard_HunterXX", "GuildCard_HunterXY",
                                "Lobby_HunterXX", "Lobby_HunterXY"
                            }
                            for _, s_name in ipairs(special_names) do
                                if name == s_name then is_target = true; break end
                            end
                        end
                    end
                    if is_target then
                        local char = nil
                        if type_cache.app_character then
                            local char_ok, c = pcall(method_cache.GameObject_getComponent.call, method_cache.GameObject_getComponent, game_obj, type_cache.app_character)
                            if char_ok then char = c end
                        end
                        if not char and type_cache.app_hunter_character then
                            local char_ok, c = pcall(method_cache.GameObject_getComponent.call, method_cache.GameObject_getComponent, game_obj, type_cache.app_hunter_character)
                            if char_ok then char = c end
                        end
                        if char then update_cache_entry(char) else update_cache_entry(transform) end
                    end
                end
            end
        end
        scanner.index = limit + 1
        if scanner.index > scanner.count then
            scanner.state = "IDLE"
            scanner.transforms = nil
            scanner.last_scan_time = os.clock()
        end
    end
end
local function get_all_characters()
    local chars = {}
    local seen_objs = {} 
    if not type_player_manager then type_player_manager = get_type("app.PlayerManager") end
    local pm = get_player_manager()
    if pm then
        local count = pm:call("get_InstancedPlayerNum")
        if count then
            for i = 0, count - 1 do
                local player = pm:call("get_InstancedPlayer", i)
                if player then
                    local char = player:call("get_Character")
                    if char and sdk.is_managed_object(char) then
                        local game_obj_ok, game_obj = pcall(function() return char:call("get_GameObject") end)
                        if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                            local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                            if not (draw_status and is_draw == false) then
                                local key = tostring(game_obj)
                                if not seen_objs[key] then
                                    local bid = get_character_body_id(char)
                                    if bid then
                                        table.insert(chars, char)
                                        seen_objs[key] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        local master = pm:call("getMasterPlayer")
        if master then
            local char = master:call("get_Character")
            if char and sdk.is_managed_object(char) then
                local game_obj_ok, game_obj = pcall(function() return char:call("get_GameObject") end)
                if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                    local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                    if not (draw_status and is_draw == false) then
                        local key = tostring(game_obj)
                        if not seen_objs[key] then
                            local bid = get_character_body_id(char)
                            if bid then
                                table.insert(chars, char)
                                seen_objs[key] = true
                            end
                        end
                    end
                end
            end
        end
    end
    local current_time = os.clock()
    local scan_interval = global_config.scan_interval or 2.0
    local cache_ttl = scan_interval + CACHE_TTL_BUFFER
    for key, data in pairs(character_cache) do
        local is_valid = false
        if data.char and sdk.is_managed_object(data.char) then
            local game_obj_ok, game_obj = pcall(function() return data.char:call("get_GameObject") end)
            if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                is_valid = not (draw_status and is_draw == false)
            end
        end
        if is_valid and (current_time - data.last_seen <= cache_ttl) then
            if not seen_objs[key] then
                table.insert(chars, data.char)
                seen_objs[key] = true
            end
        else
            character_cache[key] = nil 
        end
    end
    return chars
end
local function get_local_player_character()
    local char = nil
    local current_time = os.clock()
    if not type_player_manager then type_player_manager = get_type("app.PlayerManager") end
    local player_manager = get_player_manager()
    if player_manager then
        local master_player = player_manager:call("getMasterPlayer")
        if master_player then char = master_player:call("get_Character") end
    end
    if not char then
        local all_chars = get_all_characters()
        if #all_chars > 0 then
            local found_last = false
            if last_valid_local_player then
                for _, c in ipairs(all_chars) do
                    if c == last_valid_local_player then char = c; found_last = true; break end
                end
            end
            if not found_last then char = all_chars[1] end
        end
    end
    if char then
        if sdk.is_managed_object(char) then
            last_valid_local_player = char
            last_valid_local_player_time = current_time
        end
    else
        if last_valid_local_player and (current_time - last_valid_local_player_time <= PLAYER_PERSISTENCE_TIME) then
            if sdk.is_managed_object(last_valid_local_player) then
                char = last_valid_local_player
            else
                last_valid_local_player = nil
            end
        end
    end
    return char
end
local is_weapon_mode = false
local mode_group_selection = {}
local pending_mode_group_restore = false
local function is_weapon_id(id)
    return id and (string.match(id, "^wp%d%d") ~= nil or string.match(id, "^it%d%d%d%d") ~= nil)
end
local function get_body_id()
    if is_weapon_mode then
        local id, _ = get_character_weapon_id(get_local_player_character())
        return id
    end
    return get_character_body_id(get_local_player_character())
end
local function get_config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end
local function get_backup_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/backup/" .. body_id .. ".json"
end
local function deep_equal(a, b)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k, v in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
local function update_preset_names_list()
    preset_names_list = {}
    local target_presets = nil
    local target_order = nil
    if current_group_name == "" then
        target_presets = current_config.presets
        target_order = current_config.preset_order
    else
        if current_config.groups and current_config.groups[current_group_name] then
            target_presets = current_config.groups[current_group_name].presets or {}
            target_order = current_config.groups[current_group_name].preset_order
        else
            target_presets = {}
        end
    end
    if target_presets then
        if target_order and #target_order > 0 then
            local added = {}
            for _, name in ipairs(target_order) do
                if target_presets[name] then
                    table.insert(preset_names_list, name)
                    added[name] = true
                end
            end
            local missing = {}
            for name, _ in pairs(target_presets) do
                if not added[name] then
                    table.insert(missing, name)
                end
            end
            table.sort(missing)
            for _, name in ipairs(missing) do table.insert(preset_names_list, name) end
        else
            for name, _ in pairs(target_presets) do
                table.insert(preset_names_list, name)
            end
            table.sort(preset_names_list)
        end
    end
    local current_body_id = get_body_id and get_body_id() or nil
    local active_preset_name = ""
    if current_body_id and active_group_presets[current_body_id] then
        active_preset_name = active_group_presets[current_body_id][current_group_name] or ""
    end
    if active_preset_name == "" then
        if current_group_name == "" then
            active_preset_name = current_config.default_preset or ""
        else
            if current_config.groups and current_config.groups[current_group_name] then
                active_preset_name = current_config.groups[current_group_name].default_preset or ""
            end
        end
    end
    if active_preset_name ~= "" then
        local found = false
        for i, name in ipairs(preset_names_list) do
            if name == active_preset_name then selected_preset_index = i; found = true; break end
        end
        if not found then selected_preset_index = 1 end
    else
        selected_preset_index = 1
    end
    if #preset_names_list == 0 then selected_preset_index = 1
    elseif selected_preset_index > #preset_names_list then selected_preset_index = 1 end
end
local function update_group_names_list()
    group_names_list = {}
    if current_config.groups then
        if current_config.group_order and #current_config.group_order > 0 then
            local added = {}
            for _, name in ipairs(current_config.group_order) do
                if current_config.groups[name] then
                    table.insert(group_names_list, name)
                    added[name] = true
                end
            end
            for name, _ in pairs(current_config.groups) do
                if not added[name] then
                    table.insert(group_names_list, name)
                end
            end
        else
            for name, _ in pairs(current_config.groups) do
                table.insert(group_names_list, name)
            end
            table.sort(group_names_list)
        end
    end
    if #group_names_list == 0 then selected_group_index = 1
    elseif selected_group_index > #group_names_list then selected_group_index = 1 end
end
local function collect_mesh_components_recursive(game_obj, result, visited)
    if not game_obj or not sdk.is_managed_object(game_obj) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end
    result = result or {}
    visited = visited or {}
    local obj_key = tostring(game_obj)
    if visited[obj_key] then return end
    visited[obj_key] = true
    local ok_mesh, mesh = pcall(function()
        return game_obj:call("getComponent(System.Type)", type_mesh:get_runtime_type())
    end)
    if ok_mesh and mesh and sdk.is_managed_object(mesh) then
        local mesh_key = tostring(mesh)
        if not visited[mesh_key] then
            visited[mesh_key] = true
            table.insert(result, mesh)
        end
    end
    local ok_transform, transform = pcall(function() return game_obj:call("get_Transform") end)
    if not ok_transform or not transform then return end
    local ok_child, child = pcall(function() return transform:call("get_Child") end)
    while ok_child and child do
        local ok_child_obj, child_obj = pcall(function() return child:call("get_GameObject") end)
        if ok_child_obj and child_obj then
            collect_mesh_components_recursive(child_obj, result, visited)
        end
        ok_child, child = pcall(function() return child:call("get_Next") end)
    end
end
local function get_mesh_component_recursive(game_obj)
    local meshes = {}
    collect_mesh_components_recursive(game_obj, meshes, {})
    return meshes[1]
end
local get_character_part
local function is_player_face_object(game_obj)
    if not game_obj then return false end
    local ok_name, name = pcall(function() return game_obj:call("get_Name") end)
    return ok_name and name == "Player_Face"
end
local character_mesh_cache = {}
local CHARACTER_MESH_CACHE_TTL = 0.25
local function get_all_character_meshes(character)
    if not character or not sdk.is_managed_object(character) then return {} end
    local ok_root, root = pcall(function() return character:call("get_GameObject") end)
    if not ok_root or not root or not sdk.is_managed_object(root) then return {} end
    local cache_key = tostring(root)
    local now = os.clock()
    local cached = character_mesh_cache[cache_key]
    if cached and now - cached.time <= CHARACTER_MESH_CACHE_TTL then
        return cached.meshes
    end
    local meshes = {}
    collect_mesh_components_recursive(root, meshes, {})
    character_mesh_cache[cache_key] = { time = now, meshes = meshes }
    return meshes
end
local function get_character_part_meshes(character, part_index, part_data)
    local part_obj = get_character_part(character, part_index)
    if part_obj and not is_player_face_object(part_obj) then
        local part_meshes = {}
        collect_mesh_components_recursive(part_obj, part_meshes, {})
        local armor_meshes = {}
        for _, mesh in ipairs(part_meshes) do
            local ok_go, mesh_game_obj = pcall(function() return mesh:call("get_GameObject") end)
            if not (ok_go and mesh_game_obj and is_player_face_object(mesh_game_obj)) then
                table.insert(armor_meshes, mesh)
            end
        end
        if #armor_meshes > 0 then
            return armor_meshes
        end
    end
    local all_meshes = get_all_character_meshes(character)
    if #all_meshes == 0 then return {} end
    local material_defs = part_data and part_data.materials
    if material_defs and next(material_defs) then
        local best_count = 0
        local best_meshes = {}
        for _, mesh in ipairs(all_meshes) do
            local count = 0
            local is_player_face = false
            local ok_go, mesh_game_obj = pcall(function() return mesh:call("get_GameObject") end)
            if ok_go and mesh_game_obj then is_player_face = is_player_face_object(mesh_game_obj) end
            if not is_player_face then
                local mat_count = 0
                local ok_count, value = pcall(function() return mesh:call("get_MaterialNum") end)
                if ok_count and value then mat_count = value end
                for i = 0, mat_count - 1 do
                    local ok_name, mat_name = pcall(function() return mesh:call("getMaterialName", i) end)
                    if ok_name and mat_name and material_defs[mat_name] ~= nil then
                        count = count + 1
                    end
                end
                if count > best_count then
                    best_count = count
                    best_meshes = { mesh }
                elseif count > 0 and count == best_count then
                    table.insert(best_meshes, mesh)
                end
            end
        end
        if best_count > 0 then
            return best_meshes
        end
    end
    return {}
end
get_character_part = function(character, part_index)
    if not character then return nil end
    local status, part_obj = pcall(function() return character:call("getParts", part_index) end)
    if status and part_obj then return part_obj end
    local game_obj_status, game_obj = pcall(function() return character:call("get_GameObject") end)
    if game_obj_status and game_obj then
        local transform = game_obj:call("get_Transform")
        if transform then
            local parts_map = {} 
            local child = transform:call("get_Child")
            while child do
                local child_obj = child:call("get_GameObject")
                if child_obj then
                    local name = child_obj:call("get_Name")
                    if name and string.find(name, "^ch") then
                        local suffix_str = string.match(name, "(%d+)$")
                        if suffix_str then
                            local suffix = tonumber(suffix_str)
                            local last_digit = suffix % 10
                            local target_index = nil
                            if last_digit == 1 then target_index = 2
                            elseif last_digit == 2 then target_index = 1
                            elseif last_digit == 3 then target_index = 0
                            elseif last_digit == 4 then target_index = 4
                            elseif last_digit == 5 then target_index = 3
                            elseif last_digit == 6 then target_index = 5
                            end
                            if target_index then
                                local mesh = get_mesh_component_recursive(child_obj)
                                if mesh then
                                    local should_replace = true
                                    if parts_map[target_index] then
                                        local old_name = parts_map[target_index].name
                                        if not string.find(old_name, "^ch00") and string.find(name, "^ch00") then
                                            should_replace = false
                                        elseif not string.find(old_name, "^ch00") and not string.find(name, "^ch00") then
                                            should_replace = false
                                        elseif string.find(old_name, "^ch00") and string.find(name, "^ch00") then
                                            should_replace = false
                                        end
                                    end
                                    if should_replace then
                                        parts_map[target_index] = { obj = child_obj, name = name }
                                    end
                                end
                            end
                        end
                    end
                end
                child = child:call("get_Next")
            end
            if parts_map[part_index] then return parts_map[part_index].obj end
        end
    end
    return nil
end
local function get_material_group_owner(part_index, mat_name)
    if not mat_name then return nil end
    if not current_config.groups then return nil end
    local s_idx = tostring(part_index)
    for g_name, g_data in pairs(current_config.groups) do
        if not g_data.is_global then
            if g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
                return g_name
            end
        end
    end
    return nil
end
local function get_material_global_groups(part_index, mat_name)
    if not mat_name then return {} end
    if not current_config.groups then return {} end
    local s_idx = tostring(part_index)
    local result = {}
    for g_name, g_data in pairs(current_config.groups) do
        if g_data.is_global and g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
            table.insert(result, g_name)
        end
    end
    table.sort(result)
    return result
end
local function switch_variant_mode(weapon_mode)
    if is_weapon_mode == weapon_mode then return end
    if last_body_id then mode_group_selection[last_body_id] = current_group_name end
    is_weapon_mode = weapon_mode
    last_body_id = nil
    current_group_name = ""
    pending_mode_group_restore = true
    if weapon_mode then
        weapon_id_cache = {}
    else
        body_id_cache = {}
    end
end
local function is_material_in_current_context(part_index, mat_name)
    if current_group_name == "" then
        local owner = get_material_group_owner(part_index, mat_name)
        return owner == nil
    else
        local g_data = current_config.groups and current_config.groups[current_group_name]
        if g_data and g_data.is_global then
            local s_idx = tostring(part_index)
            return g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] == true
        else
            local owner = get_material_group_owner(part_index, mat_name)
            return owner == current_group_name
        end
    end
end
local function is_globally_hidden(part_index, mat_name)
    if current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global then
        return false
    end
    if not current_config.groups then return false end
    local s_idx = tostring(part_index)
    local body_id = get_body_id()
    local active_saved = (body_id and active_group_presets[body_id]) or {}
    for g_name, g_data in pairs(current_config.groups) do
        if g_data.is_global and g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
            local pname = active_saved[g_name]
            if not pname or pname == "" then pname = g_data.default_preset end
            if pname and pname ~= "" and g_data.presets and g_data.presets[pname] then
                local def = g_data.presets[pname]
                if def[s_idx] and def[s_idx].materials and def[s_idx].materials[mat_name] == false then
                    return true
                end
            end
        end
    end
    return false
end
local applied_parts_cache = {} 
local applied_weapon_cache = {} 
local function apply_preset_to_armor(character, preset_data, ignore_context, force_apply)
    if not character or not preset_data then return end
    if not sdk.is_managed_object(character) then return end
    local char_go = character:call("get_GameObject")
    if not char_go or not sdk.is_managed_object(char_go) then return end
    local char_addr = tostring(char_go)
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end
    if not applied_parts_cache[char_addr] then applied_parts_cache[char_addr] = {} end
    for i = 0, 5 do
        local part_data = preset_data[tostring(i)]
        if part_data then
            local mesh_components = get_character_part_meshes(character, i, part_data)
            for _, mesh_component in ipairs(mesh_components) do
                    local mat_count = mesh_component:call("get_MaterialNum") or 0
                    local first_mat = mat_count > 0 and mesh_component:call("getMaterialName", 0) or ""
                    local state_hash = tostring(mesh_component) .. "_" .. tostring(mat_count) .. "_" .. first_mat
                    local should_apply = force_apply or (applied_parts_cache[char_addr][i] ~= state_hash)
                    if should_apply then applied_parts_cache[char_addr][i] = state_hash end
                    if part_data.mesh_enabled ~= nil then
                        local cur_en = mesh_component:call("get_Enabled")
                        if part_data.mesh_enabled == false then
                            if cur_en ~= false then mesh_component:call("set_Enabled", false) end
                        elseif part_data.mesh_enabled == true then
                            if cur_en ~= true then mesh_component:call("set_Enabled", true) end
                        end
                    end
                    if part_data.materials and mat_count > 0 then
                        for j = 0, mat_count - 1 do
                            local mat_name = mesh_component:call("getMaterialName", j)
                            if ignore_context or is_material_in_current_context(i, mat_name) then
                                local mat_enabled = part_data.materials[mat_name]
                                local cur_mat = mesh_component:call("getMaterialsEnable", j)
                                if mat_enabled == false then
                                    if cur_mat ~= false then mesh_component:call("setMaterialsEnable", j, false) end
                                elseif mat_enabled == true then
                                    if is_globally_hidden(i, mat_name) then
                                        if cur_mat ~= false then mesh_component:call("setMaterialsEnable", j, false) end
                                    else
                                        if cur_mat ~= true then mesh_component:call("setMaterialsEnable", j, true) end
                                    end
                                end
                            end
                        end
                    end
            end
        end
    end
end
local function apply_preset_to_weapon(character, weapon_objs, preset_data, ignore_context, force_apply)
    if not character or not weapon_objs or not preset_data then return end
    if not sdk.is_managed_object(character) then return end
    local char_go = character:call("get_GameObject")
    if not char_go or not sdk.is_managed_object(char_go) then return end
    local char_addr = tostring(char_go)
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end
    for idx, w_obj in ipairs(weapon_objs) do
        if sdk.is_managed_object(w_obj) then
            local ok_alive, _ = pcall(function() return w_obj:call("get_Name") end)
            if ok_alive then
                local p_idx = tostring(idx - 1)
                local part_data = preset_data[p_idx]
                if part_data then
                    local mesh_component = get_mesh_component_recursive(w_obj)
                    if mesh_component then
                        local mat_count = mesh_component:call("get_MaterialNum") or 0
                        local first_mat = mat_count > 0 and mesh_component:call("getMaterialName", 0) or ""
                        local state_hash = tostring(mesh_component) .. "_" .. tostring(mat_count) .. "_" .. first_mat
                        if not applied_weapon_cache[char_addr] then applied_weapon_cache[char_addr] = {} end
                        local should_apply = force_apply or (applied_weapon_cache[char_addr][p_idx] ~= state_hash)
                        if should_apply then applied_weapon_cache[char_addr][p_idx] = state_hash end
                         if part_data.mesh_enabled ~= nil then
                             local cur_en = mesh_component:call("get_Enabled")
                             if part_data.mesh_enabled == false then
                                 if cur_en ~= false then mesh_component:call("set_Enabled", false) end
                             elseif part_data.mesh_enabled == true then
                                 if cur_en ~= true then mesh_component:call("set_Enabled", true) end
                             end
                         end
                         if part_data.materials and mat_count > 0 then
                             for j = 0, mat_count - 1 do
                                 local mat_name = mesh_component:call("getMaterialName", j)
                                 if ignore_context or is_material_in_current_context(idx - 1, mat_name) then
                                     local mat_enabled = part_data.materials[mat_name]
                                     local cur_mat = mesh_component:call("getMaterialsEnable", j)
                                     if mat_enabled == false then
                                         if cur_mat ~= false then mesh_component:call("setMaterialsEnable", j, false) end
                                     elseif mat_enabled == true then
                                         if cur_mat ~= true then mesh_component:call("setMaterialsEnable", j, true) end
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
local function create_new_group(group_name, body_id, is_global)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    local has_selection = false
    for _, v in pairs(pending_material_selections) do
        if next(v) then has_selection = true; break end
    end
    if not has_selection then return false end
    if not current_config.groups then current_config.groups = {} end
    if current_config.groups[group_name] then return false end 
    local new_group = {
        mask = deep_copy_table(pending_material_selections),
        presets = {},
        is_global = is_global == true
    }
    if not new_group.is_global then
        if current_config.presets then
            for _, preset_data in pairs(current_config.presets) do
                for part_idx_str, mats in pairs(new_group.mask) do
                    if preset_data[part_idx_str] and preset_data[part_idx_str].materials then
                        for m_name, _ in pairs(mats) do
                            preset_data[part_idx_str].materials[m_name] = nil
                        end
                    end
                end
            end
        end
    end
    current_config.groups[group_name] = new_group
    if not current_config.group_order then current_config.group_order = {} end
    table.insert(current_config.group_order, group_name)
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
    if current_config.group_order then
        for i = #current_config.group_order, 1, -1 do
            if current_config.group_order[i] == group_name then
                table.remove(current_config.group_order, i)
                break
            end
        end
    end
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
    if loaded_configs[body_id] then
        if loaded_configs[body_id] == "LOAD_FAILED" then return nil end
        return loaded_configs[body_id]
    end
    local path = get_config_path(body_id)
    local loaded_data = json.load_file(path)
    if loaded_data then
        if not loaded_data.presets then loaded_data.presets = {} end
        if not loaded_data.default_preset then loaded_data.default_preset = "" end
        if not loaded_data.groups then loaded_data.groups = {} end
        if not loaded_data.group_order then loaded_data.group_order = {} end
        if not loaded_data.preset_order then loaded_data.preset_order = {} end
        for _, g_data in pairs(loaded_data.groups) do
            if not g_data.preset_order then g_data.preset_order = {} end
        end
        if not loaded_data.transform_type then loaded_data.transform_type = "hp" end
        if loaded_data.is_parallel == nil then loaded_data.is_parallel = false end
        loaded_data.parallel_settings = normalize_parallel_settings(loaded_data.parallel_settings)
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
        local backup_path = get_backup_path(body_id)
        if backup_path then
            local backup_data = json.load_file(backup_path)
            if backup_data then
                local config_path = get_config_path(body_id)
                local raw_config = json.load_file(config_path)
                if raw_config then
                    local same = deep_equal(raw_config, backup_data)
                    if not same then
                        config_restored[body_id] = true
                    else
                        config_restored[body_id] = nil
                    end
                end
            end
        end
        loaded_configs[body_id] = loaded_data
        return loaded_data
    end
    loaded_configs[body_id] = "LOAD_FAILED"
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
local function merge_overrides(base_data, add_data)
    local result = deep_copy_table(base_data) or {}
    if not add_data then return result end
    for p_idx, p_data in pairs(add_data) do
        if not result[p_idx] then result[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            result[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not result[p_idx].materials then result[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                result[p_idx].materials[mat_name] = is_enabled
            end
        end
    end
    return result
end
local function merge_global_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if p_data.materials then
            if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                if is_enabled == false then
                    overrides[p_idx].materials[mat_name] = false
                end
            end
        end
    end
end
local function apply_all_defaults(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    active_overrides[body_id] = {}
    if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
    if config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then
            merge_preset_into_overrides(body_id, def)
            if not active_group_presets[body_id][""] or active_group_presets[body_id][""] == "" then
                active_group_presets[body_id][""] = config.default_preset
            end
        end
    end
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if not g_data.is_global then
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then
                        merge_preset_into_overrides(body_id, g_def)
                        if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                            active_group_presets[body_id][g_name] = g_data.default_preset
                        end
                    end
                end
            end
        end
    end
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if g_data.is_global then
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then
                        merge_global_preset_into_overrides(body_id, g_def)
                        if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                            active_group_presets[body_id][g_name] = g_data.default_preset
                        end
                    end
                end
            end
        end
    end
end
local function rebuild_overrides_for_transform(body_id, config, activated_targets)
    if not body_id or not config then return end
    active_overrides[body_id] = {}
    local saved = active_group_presets[body_id] or {}
    local main_preset_name = saved[""]
    if main_preset_name and main_preset_name ~= "" and config.presets and config.presets[main_preset_name] then
        merge_preset_into_overrides(body_id, config.presets[main_preset_name])
    elseif config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then merge_preset_into_overrides(body_id, def) end
    end
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if not g_data.is_global then
                local gp_name = saved[g_name]
                if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                    merge_preset_into_overrides(body_id, g_data.presets[gp_name])
                elseif g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then merge_preset_into_overrides(body_id, g_def) end
                end
            end
        end
    end
    if activated_targets and config.groups then
        for g_name, p_name in pairs(activated_targets) do
            if g_name ~= "" and config.groups[g_name] and not config.groups[g_name].is_global then
                if p_name and p_name ~= "" and config.groups[g_name].presets and config.groups[g_name].presets[p_name] then
                    merge_preset_into_overrides(body_id, config.groups[g_name].presets[p_name])
                end
            elseif g_name == "" then
                if p_name and p_name ~= "" and config.presets and config.presets[p_name] then
                    merge_preset_into_overrides(body_id, config.presets[p_name])
                end
            end
        end
    end
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if g_data.is_global then
                local gp_name = (activated_targets and activated_targets[g_name]) or saved[g_name]
                if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                    merge_global_preset_into_overrides(body_id, g_data.presets[gp_name])
                end
            end
        end
    end
end
local function get_current_preset_data(preset_name)
    if current_group_name == "" then
        return current_config.presets and current_config.presets[preset_name]
    else
        if current_config.groups and current_config.groups[current_group_name] then
            return current_config.groups[current_group_name].presets and current_config.groups[current_group_name].presets[preset_name]
        end
    end
    return nil
end
local function apply_preset(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_body_id = get_body_id()
    if current_body_id then
        if not active_group_presets[current_body_id] then active_group_presets[current_body_id] = {} end
        active_group_presets[current_body_id][current_group_name] = preset_name
        local is_current_global = (current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name]
            and current_config.groups[current_group_name].is_global)
        if is_current_global then
            active_overrides[current_body_id] = {}
            local saved = active_group_presets[current_body_id] or {}
            local main_preset_name = saved[""]
            if main_preset_name and main_preset_name ~= "" and current_config.presets and current_config.presets[main_preset_name] then
                merge_preset_into_overrides(current_body_id, current_config.presets[main_preset_name])
            elseif current_config.default_preset and current_config.default_preset ~= "" and current_config.presets then
                local def = current_config.presets[current_config.default_preset]
                if def then merge_preset_into_overrides(current_body_id, def) end
            end
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if not g_data.is_global then
                        local gp_name = saved[g_name]
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_preset_into_overrides(current_body_id, g_data.presets[gp_name])
                        elseif g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                            local g_def = g_data.presets[g_data.default_preset]
                            if g_def then merge_preset_into_overrides(current_body_id, g_def) end
                        end
                    end
                end
            end
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global then
                        local gp_name = (g_name == current_group_name) and preset_name or saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_body_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        else
            merge_preset_into_overrides(current_body_id, preset_data)
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global and g_data.presets then
                        local active_saved = active_group_presets[current_body_id] or {}
                        local gp_name = active_saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_body_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        end
        temp_applied_presets[current_body_id] = preset_name
    end
    local all_chars = get_all_characters()
    local local_char_for_preset = get_local_player_character()
    if local_char_for_preset and sdk.is_managed_object(local_char_for_preset) then
        local local_seen = false
        for _, listed_char in ipairs(all_chars) do
            if listed_char == local_char_for_preset then
                local_seen = true
                break
            end
        end
        if not local_seen then
            table.insert(all_chars, local_char_for_preset)
        end
    end
    for _, char in ipairs(all_chars) do
        if is_weapon_id(current_body_id) then
            local char_weapon_id, w_objs = get_character_weapon_id(char)
            if char_weapon_id and char_weapon_id == current_body_id then
                local config = load_config_data(char_weapon_id)
                local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                local new_overrides, _ = TransformManager.apply_transform_rules(
                    char_addr, config, char, active_overrides[current_body_id], merge_overrides
                )
                apply_preset_to_weapon(char, w_objs, new_overrides, true, true)
            end
        else
            local char_body_id = get_character_body_id(char)
            if char_body_id and char_body_id == current_body_id then
                local config = load_config_data(char_body_id)
                local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                local new_overrides, _, activated_targets = TransformManager.apply_transform_rules(
                    char_addr, config, char, active_overrides[current_body_id], merge_overrides
                )
                local has_global_target = false
                if activated_targets and config and config.groups then
                    for g_name, _ in pairs(activated_targets) do
                        if g_name ~= "" and config.groups[g_name] and config.groups[g_name].is_global then
                            has_global_target = true
                            break
                        end
                    end
                end
                if has_global_target then
                    rebuild_overrides_for_transform(char_body_id, config, activated_targets)
                    apply_preset_to_armor(char, active_overrides[char_body_id], true, true)
                else
                    apply_preset_to_armor(char, new_overrides, true, true)
                end
            end
        end
    end
end
local function load_body_config(body_id)
    if not body_id then return false end
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
    local backup_path = get_backup_path(body_id)
    if backup_path then
        json.dump_file(backup_path, current_config)
    end
    config_restored[body_id] = nil
    config_restore_handled[body_id] = nil
    if active_overrides[body_id] then
        active_overrides[body_id] = nil
    end
    active_group_presets[body_id] = nil
    if TransformManager.clear_last_state_cache then
        TransformManager.clear_last_state_cache()
    end
end
local function set_preset_as_default(preset_name, body_id)
    if not body_id or not preset_name or preset_name == "" or not current_config then return false end
    local target = current_config
    if current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name] then
        target = current_config.groups[current_group_name]
    end
    if not target.presets or not target.presets[preset_name] then return false end
    target.default_preset = preset_name
    save_current_config_to_file(body_id)
    update_preset_names_list()
    return true
end
local function auto_set_selected_preset_as_default(body_id)
    if not global_config.auto_set_selected_preset_as_default then return false end
    return set_preset_as_default(preset_names_list[selected_preset_index], body_id)
end
local function restore_config_from_backup(body_id)
    if not body_id then return false end
    local backup_path = get_backup_path(body_id)
    if not backup_path then return false end
    local backup_data = json.load_file(backup_path)
    if not backup_data then return false end
    local path = get_config_path(body_id)
    json.dump_file(path, backup_data)
    loaded_configs[body_id] = nil
    active_overrides[body_id] = nil
    active_group_presets[body_id] = nil
    config_restored[body_id] = nil
    local data = load_config_data(body_id)
    if data then
        current_config = data
        update_group_names_list()
        update_preset_names_list()
        apply_all_defaults(body_id)
    end
    if TransformManager.clear_last_state_cache then
        TransformManager.clear_last_state_cache()
    end
    return true
end
local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_body_id() end
    if not body_id then return false end
    local character = get_local_player_character()
    if not character then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = {}
    if is_weapon_id(body_id) then
        local w_id, w_objs = get_character_weapon_id(character)
        if w_objs then
            for idx, w_obj in ipairs(w_objs) do
                local mesh_component = get_mesh_component_recursive(w_obj)
                if mesh_component then
                    local part_data = {
                        materials = {}
                    }
                    local is_global_ctx = (current_group_name ~= "" and current_config.groups
                        and current_config.groups[current_group_name]
                        and current_config.groups[current_group_name].is_global)
                    if not is_global_ctx then
                        part_data.mesh_enabled = mesh_component:call("get_Enabled")
                    end
                    local mat_count = mesh_component:call("get_MaterialNum")
                    if mat_count then
                        for j = 0, mat_count - 1 do
                            local mat_name = mesh_component:call("getMaterialName", j)
                            if is_material_in_current_context(idx - 1, mat_name) then
                                local s_idx = tostring(idx - 1)
                                local intent = active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mat_name]
                                local is_mat_enabled = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", j)
                                part_data.materials[mat_name] = is_mat_enabled
                            end
                        end
                    end
                    if next(part_data.materials) or current_group_name == "" then
                        new_preset_data[tostring(idx - 1)] = part_data
                    end
                end
            end
        end
    else
        for i = 0, 5 do
            local part_obj = get_character_part(character, i)
            local reference_part_data = active_overrides[body_id]
                and active_overrides[body_id][tostring(i)]
            local mesh_components = get_character_part_meshes(character, i, reference_part_data)
            if #mesh_components > 0 then
                local part_data = {
                    materials = {}
                }
                local is_global_ctx = (current_group_name ~= "" and current_config.groups
                    and current_config.groups[current_group_name]
                    and current_config.groups[current_group_name].is_global)
                for _, mesh_component in ipairs(mesh_components) do
                    if not is_global_ctx and part_data.mesh_enabled == nil then
                        part_data.mesh_enabled = mesh_component:call("get_Enabled")
                    end
                    local mat_count = mesh_component:call("get_MaterialNum")
                    if mat_count then
                        for j = 0, mat_count - 1 do
                            local mat_name = mesh_component:call("getMaterialName", j)
                            if is_material_in_current_context(i, mat_name) then
                                local s_idx_j = tostring(i)
                                local intent = active_overrides[body_id]
                                    and active_overrides[body_id][s_idx_j]
                                    and active_overrides[body_id][s_idx_j].materials
                                    and active_overrides[body_id][s_idx_j].materials[mat_name]
                                local is_mat_enabled = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", j)
                                part_data.materials[mat_name] = is_mat_enabled
                            end
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
        if not current_config.presets[preset_name] then
            if not current_config.preset_order then current_config.preset_order = {} end
            table.insert(current_config.preset_order, preset_name)
        end
        current_config.presets[preset_name] = new_preset_data
    else
        if not current_config.groups then current_config.groups = {} end
        if not current_config.groups[current_group_name] then
            current_config.groups[current_group_name] = { presets = {}, mask = {} }
        end
        if not current_config.groups[current_group_name].presets then
            current_config.groups[current_group_name].presets = {}
        end
        if not current_config.groups[current_group_name].presets[preset_name] then
            if not current_config.groups[current_group_name].preset_order then
                current_config.groups[current_group_name].preset_order = {}
            end
            table.insert(current_config.groups[current_group_name].preset_order, preset_name)
        end
        current_config.groups[current_group_name].presets[preset_name] = new_preset_data
    end
    update_preset_names_list()
    save_current_config_to_file(body_id)
    return true
end
local function find_auto_preset(target_body_id)
    if not target_body_id then return false, "No Body ID" end
    local character = get_local_player_character()
    if not character or not sdk.is_managed_object(character) then return false, "No Character" end
    local is_weapon_target = is_weapon_id(target_body_id)
    local current_mats = {}
    local current_weapon_mats = {}
    if is_weapon_target then
        local current_weapon_id, weapon_objs = get_character_weapon_id(character)
        if current_weapon_id ~= target_body_id or not weapon_objs or #weapon_objs == 0 then
            return false, "Weapon not found"
        end
        for index, weapon_obj in ipairs(weapon_objs) do
            local mesh = get_mesh_component_recursive(weapon_obj)
            if mesh then
                local mats = {}
                local mat_count = mesh:call("get_MaterialNum") or 0
                for material_index = 0, mat_count - 1 do
                    local name = mesh:call("getMaterialName", material_index)
                    if name then mats[name] = true end
                end
                if next(mats) then current_weapon_mats[tostring(index - 1)] = mats end
            end
        end
        if not next(current_weapon_mats) then return false, "No materials on Weapon" end
    else
        local body_part = get_character_part(character, 1) 
        if not body_part then return false, "Body part not found" end
        local mesh = get_mesh_component_recursive(body_part)
        if not mesh then return false, "Mesh not found" end
        local mat_count = mesh:call("get_MaterialNum")
        if not mat_count or mat_count == 0 then return false, "No materials on Body" end
        for i = 0, mat_count - 1 do
            local name = mesh:call("getMaterialName", i)
            if name then current_mats[name] = true end
        end
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
                for _, preset in pairs(data.presets) do first_preset = preset; break end
                if is_weapon_target then
                    local normalized_file = file:gsub("\\", "/")
                    local candidate_id = normalized_file:match("([^/]+)%.json$")
                    local match = candidate_id and is_weapon_id(candidate_id) and first_preset ~= nil
                    local match_count = 0
                    if match then
                        for part_index, part_data in pairs(first_preset) do
                            local preset_mats = part_data and part_data.materials
                            if preset_mats and next(preset_mats) then
                                local weapon_mats = current_weapon_mats[tostring(part_index)]
                                if not weapon_mats then match = false; break end
                                for mat_name, _ in pairs(preset_mats) do
                                    if not weapon_mats[mat_name] then match = false; break end
                                    match_count = match_count + 1
                                end
                                if not match then break end
                            end
                        end
                    end
                    if match and match_count > 0 then
                        current_config = data
                        save_current_config_to_file(target_body_id)
                        update_preset_names_list()
                        return true, "Success! Loaded from " .. file
                    end
                elseif first_preset and first_preset["1"] and first_preset["1"].materials then
                    local preset_mats = first_preset["1"].materials
                    local match = true
                    local match_count = 0
                    for mat_name, _ in pairs(preset_mats) do
                        if not current_mats[mat_name] then match = false; break end
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
                local s_idx = tostring(part_index)
                local function mat_is_operable(mn)
                    local flt = mat_filter_text[part_index] or ""
                    if flt ~= "" and not string.find(string.lower(mn), string.lower(flt), 1, true) then
                        return false
                    end
                    if is_selection_mode then
                        return get_material_group_owner(part_index, mn) == nil
                    else
                        return is_material_in_current_context(part_index, mn)
                    end
                end
                imgui.same_line()
                if imgui.button(T("select_all") .. "##sa_" .. s_idx) then
                    local all_on = true
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not (pending_material_selections[s_idx] and pending_material_selections[s_idx][mn]) then
                                    all_on = false; break
                                end
                            else
                                local intent = (active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mn])
                                local cur_on = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", k)
                                if not cur_on then
                                    all_on = false; break
                                end
                            end
                        end
                    end
                    local target_val = not all_on
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                pending_material_selections[s_idx][mn] = target_val or nil
                            else
                                local render_val
                                if target_val == true and is_globally_hidden(part_index, mn) then
                                    render_val = false
                                else
                                    render_val = target_val
                                end
                                mesh_component:call("setMaterialsEnable", k, render_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = target_val  
                                end
                            end
                        end
                    end
                end
                imgui.same_line()
                if imgui.button(T("invert_select") .. "##inv_" .. s_idx) then
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                local cur = pending_material_selections[s_idx][mn]
                                pending_material_selections[s_idx][mn] = (not cur) or nil
                            else
                                local cur = mesh_component:call("getMaterialsEnable", k)
                                local nv = not cur
                                local render_val
                                if nv == true and is_globally_hidden(part_index, mn) then
                                    render_val = false
                                else
                                    render_val = nv
                                end
                                mesh_component:call("setMaterialsEnable", k, render_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = nv  
                                end
                            end
                        end
                    end
                end
                imgui.same_line()
                imgui.set_next_item_width(140)
                local flt_cur = mat_filter_text[part_index] or ""
                local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                if flt_changed then mat_filter_text[part_index] = flt_val end
                if flt_cur ~= "" then
                    imgui.same_line()
                    if imgui.button("x##fltclr_" .. s_idx) then mat_filter_text[part_index] = "" end
                end
                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")
                local filter_str = string.lower(mat_filter_text[part_index] or "")
                for i = 0, mat_count - 1 do
                    local mat_name = mesh_component:call("getMaterialName", i)
                    if mat_name then
                        if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                            local is_mat_enabled = mesh_component:call("getMaterialsEnable", i)
                            local owner = get_material_group_owner(part_index, mat_name)
                            local global_groups = get_material_global_groups(part_index, mat_name)
                            if is_selection_mode then
                                local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                                if owner and not new_group_is_global then
                                    imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF808080)
                                else
                                    local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                    if changed_sel then
                                        if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                        pending_material_selections[s_idx][mat_name] = new_sel
                                    end
                                    if #global_groups > 0 then
                                        local bid_hint = get_body_id()
                                        local ag_saved = (bid_hint and active_group_presets[bid_hint]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname = ag_saved[gname]
                                            if not pname or pname == "" then pname = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname and g_data.presets and g_data.presets[pname]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            else
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_visible"), gname), 0xFF80C0FF)
                                            end
                                        end
                                    end
                                end
                            else
                                if is_material_in_current_context(part_index, mat_name) then
                                    local mat_label = string.format("[%d] %s", i, mat_name)
                                    local intent_val = (active_overrides[body_id]
                                        and active_overrides[body_id][s_idx]
                                        and active_overrides[body_id][s_idx].materials
                                        and active_overrides[body_id][s_idx].materials[mat_name])
                                    local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                    local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                    if mat_changed then
                                        if body_id and part_index then
                                            if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                            if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                            if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                            active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                        end
                                        local render_val
                                        if mat_new_val == true and is_globally_hidden(part_index, mat_name) then
                                            render_val = false
                                        else
                                            render_val = mat_new_val
                                        end
                                        mesh_component:call("setMaterialsEnable", i, render_val)
                                    end
                                    if #global_groups > 0 then
                                        local bid_hint2 = get_body_id()
                                        local ag_saved2 = (bid_hint2 and active_group_presets[bid_hint2]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname2 = ag_saved2[gname]
                                            if not pname2 or pname2 == "" then pname2 = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname2 and g_data.presets and g_data.presets[pname2]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            end
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
            end
            imgui.tree_pop()
        end
    else
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end
local variant_manager_ui = VariantManagerUI.new({
    config = global_config,
    translate = T,
    version = version,
    author = author,
    save_settings = save_global_settings,
    get_context = function()
        local body_id = get_body_id()
        local active_preset_name = body_id and active_group_presets[body_id]
            and active_group_presets[body_id][current_group_name] or ""
        if not active_preset_name or active_preset_name == "" then
            if current_group_name == "" then
                active_preset_name = current_config.default_preset or ""
            else
                local group = current_config.groups and current_config.groups[current_group_name]
                active_preset_name = group and group.default_preset or ""
            end
        end
        if active_preset_name ~= "" then
            for index, preset_name in ipairs(preset_names_list) do
                if preset_name == active_preset_name then
                    selected_preset_index = index
                    break
                end
            end
        end
        return {
            body_id = body_id,
            character = get_local_player_character(),
            weapon_mode = is_weapon_mode,
            group_name = current_group_name,
            group_names = group_names_list,
            preset_names = preset_names_list,
            selected_preset_index = selected_preset_index,
            selected_preset_name = active_preset_name ~= "" and active_preset_name
                or preset_names_list[selected_preset_index],
            config_restored = body_id and config_restored[body_id] == true
                and config_restore_handled[body_id] ~= true,
            config = current_config
        }
    end,
    has_any_presets = function(config)
        if config and config.presets and next(config.presets) then return true end
        for _, group in pairs((config and config.groups) or {}) do
            if group.presets and next(group.presets) then return true end
        end
        return false
    end,
    auto_find_preset = function(body_id)
        local ok, found, message = pcall(find_auto_preset, body_id)
        if not ok then return false, tostring(found) end
        return found == true, message
    end,
    restore_backup = function(body_id)
        if not body_id then return false end
        config_restore_handled[body_id] = true
        return restore_config_from_backup(body_id) == true
    end,
    dismiss_backup = function(body_id)
        if not body_id then return end
        config_restore_handled[body_id] = true
        config_restored[body_id] = nil
    end,
    set_mode = function(weapon_mode)
        switch_variant_mode(weapon_mode)
    end,
    select_group = function(group_name)
        group_name = group_name or ""
        if group_name ~= "" and (not current_config.groups or not current_config.groups[group_name]) then
            group_name = ""
        end
        current_group_name = group_name
        selected_group_index = 1
        for i, name in ipairs(group_names_list) do
            if name == current_group_name then
                selected_group_index = i + 1
                break
            end
        end
        variant_manager_ui.material_offset = 0
        update_preset_names_list()
        local body_id = get_body_id()
        local active_preset = body_id and active_group_presets[body_id]
            and active_group_presets[body_id][current_group_name]
        if active_preset and active_preset ~= "" then
            for index, preset_name in ipairs(preset_names_list) do
                if preset_name == active_preset then
                    selected_preset_index = index
                    break
                end
            end
        end
    end,
    select_preset = function(index)
        selected_preset_index = index
    end,
    reorder_groups = function(items)
        local body_id = get_body_id()
        if not body_id or not current_config then return end
        current_config.group_order = {}
        for _, item in ipairs(items or {}) do
            if item.name and item.name ~= "" then
                table.insert(current_config.group_order, item.name)
            end
        end
        update_group_names_list()
        save_current_config_to_file(body_id)
    end,
    create_group = function(group_name, is_global, selections)
        local body_id = get_body_id()
        if not body_id then return false end
        pending_material_selections = selections or {}
        local created = create_new_group(group_name, body_id, is_global == true)
        if created then
            current_group_name = group_name
            selected_group_index = 1
            for i, name in ipairs(group_names_list) do
                if name == current_group_name then selected_group_index = i + 1; break end
            end
            selected_preset_index = 1
            update_group_names_list()
            update_preset_names_list()
        else
            pending_material_selections = {}
        end
        return created == true
    end,
    delete_group = function(group_name)
        local body_id = get_body_id()
        if not body_id then return false end
        local deleted = delete_group(group_name, body_id)
        if deleted then
            selected_preset_index = 1
            variant_manager_ui.material_offset = 0
            update_group_names_list()
            update_preset_names_list()
        end
        return deleted == true
    end,
    reorder_presets = function(items)
        local body_id = get_body_id()
        if not body_id or not current_config then return end
        local target = current_config
        if current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name] then
            target = current_config.groups[current_group_name]
        end
        target.preset_order = {}
        for _, preset_name in ipairs(items or {}) do
            table.insert(target.preset_order, preset_name)
        end
        update_preset_names_list()
        save_current_config_to_file(body_id)
    end,
    create_preset = function(preset_name)
        local body_id = get_body_id()
        if not body_id or not preset_name or preset_name == "" then return false end
        local saved = save_preset(preset_name, body_id)
        if saved then update_preset_names_list() end
        return saved == true
    end,
    overwrite_preset = function(preset_name)
        local body_id = get_body_id()
        if not body_id or not preset_name or preset_name == "" then return false end
        local saved = save_preset(preset_name, body_id)
        if saved then update_preset_names_list() end
        return saved == true
    end,
    delete_preset = function(preset_name)
        local body_id = get_body_id()
        if not body_id or not preset_name or preset_name == "" or not current_config then return false end
        local target = current_config
        if current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name] then
            target = current_config.groups[current_group_name]
        end
        if not target.presets or not target.presets[preset_name] then return false end
        target.presets[preset_name] = nil
        if target.default_preset == preset_name then target.default_preset = "" end
        if target.preset_order then
            for index = #target.preset_order, 1, -1 do
                if target.preset_order[index] == preset_name then
                    table.remove(target.preset_order, index)
                    break
                end
            end
        end
        update_preset_names_list()
        save_current_config_to_file(body_id)
        return true
    end,
    set_default_preset = function(preset_name)
        return set_preset_as_default(preset_name, get_body_id())
    end,
    set_auto_default_enabled = function(enabled, preset_name, body_id)
        global_config.auto_set_selected_preset_as_default = enabled == true
        save_global_settings()
        if global_config.auto_set_selected_preset_as_default then
            return set_preset_as_default(preset_name, body_id or get_body_id())
        end
        return true
    end,
    auto_set_default_preset = function(preset_name, body_id)
        if not global_config.auto_set_selected_preset_as_default then return false end
        return set_preset_as_default(preset_name, body_id or get_body_id())
    end,
    apply_preset = apply_preset,
    save_transform = function(context)
        local body_id = context and context.body_id or get_body_id()
        if body_id then save_current_config_to_file(body_id) end
    end,
    get_transform_state = function(type_key, character)
        if not character then return nil end
        if type_key == "damage" then
            local ok, remaining = pcall(function()
                local game_object = character:call("get_GameObject")
                local character_address = tostring(game_object or character)
                return TransformManager.get_damage_remaining_time(character_address)
            end)
            return ok and remaining or nil
        end
        local getters = {
            hp = TransformManager.get_character_hp_percent,
            weapon = TransformManager.get_character_weapon_drawn,
            spirit = TransformManager.get_character_spirit_level,
            dual_blades = TransformManager.get_character_dual_blades_state,
            switch_axe = TransformManager.get_character_switch_axe_state,
            insect_glaive = TransformManager.get_character_insect_glaive_state,
            charge_blade = TransformManager.get_character_charge_blade_state,
            greatsword_type = TransformManager.get_character_greatsword_charge_type,
            greatsword_level = TransformManager.get_character_greatsword_charge_level,
            bow_level = TransformManager.get_character_bow_charge_level,
            hammer_level = TransformManager.get_character_hammer_charge_level
        }
        local getter = getters[type_key]
        if not getter then return nil end
        local ok, value = pcall(function() return getter(character) end)
        if ok then return value end
        return nil
    end,
    set_test_hp = function(character, percent)
        if not character then return false end
        local ok, result = pcall(function()
            return TransformManager.set_character_hp_percent(character, percent)
        end)
        return ok and result ~= false
    end,
    get_meshes = function(character, body_id, part_index)
        if not character or not body_id then return {} end
        if is_weapon_mode then
            local _, weapon_objs = get_character_weapon_id(character)
            local weapon_obj = weapon_objs and weapon_objs[part_index + 1]
            local mesh = weapon_obj and get_mesh_component_recursive(weapon_obj)
            return mesh and { mesh } or {}
        end
        local reference = active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
        return get_character_part_meshes(character, part_index, reference)
    end,
    get_mesh_view = function(meshes, body_id, part_index)
        local mesh = meshes and meshes[1]
        if not mesh or not sdk.is_managed_object(mesh) then return nil end
        local view = {
            mesh_enabled = mesh:call("get_Enabled") ~= false,
            materials = {}
        }
        local count = mesh:call("get_MaterialNum") or 0
        for i = 0, count - 1 do
            table.insert(view.materials, {
                name = mesh:call("getMaterialName", i),
                enabled = mesh:call("getMaterialsEnable", i) ~= false,
                index = i
            })
        end
        return view
    end,
    get_override = function(body_id, part_index)
        return active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
    end,
    set_mesh_enabled = function(body_id, part_index, meshes, enabled)
        if not body_id then return end
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        local key = tostring(part_index)
        if not active_overrides[body_id][key] then
            active_overrides[body_id][key] = { materials = {} }
        elseif not active_overrides[body_id][key].materials then
            active_overrides[body_id][key].materials = {}
        end
        active_overrides[body_id][key].mesh_enabled = enabled
        for _, mesh in ipairs(meshes or {}) do
            if sdk.is_managed_object(mesh) then mesh:call("set_Enabled", enabled) end
        end
    end,
    set_material_enabled = function(body_id, part_index, meshes, material_name, enabled)
        if not body_id then return end
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        local key = tostring(part_index)
        if not active_overrides[body_id][key] then
            active_overrides[body_id][key] = { materials = {} }
        elseif not active_overrides[body_id][key].materials then
            active_overrides[body_id][key].materials = {}
        end
        active_overrides[body_id][key].materials[material_name] = enabled
        local render_enabled = enabled
        if enabled and is_globally_hidden(part_index, material_name) then render_enabled = false end
        for _, mesh in ipairs(meshes or {}) do
            if sdk.is_managed_object(mesh) then
                local count = mesh:call("get_MaterialNum") or 0
                for i = 0, count - 1 do
                    if mesh:call("getMaterialName", i) == material_name then
                        mesh:call("setMaterialsEnable", i, render_enabled)
                    end
                end
            end
        end
    end,
    is_material_in_context = is_material_in_current_context,
    get_material_occupancy = function(part_index, material_name)
        return {
            owner = get_material_group_owner(part_index, material_name),
            global_groups = get_material_global_groups(part_index, material_name),
            in_context = is_material_in_current_context(part_index, material_name)
        }
    end,
    get_part_count = function(character, weapon_mode)
        if not weapon_mode then return 6 end
        local _, weapon_objs = get_character_weapon_id(character)
        return weapon_objs and #weapon_objs or 1
    end,
    get_part_label = function(character, weapon_mode, part_index)
        if not weapon_mode then return nil end
        local _, weapon_objs = get_character_weapon_id(character)
        local weapon_obj = weapon_objs and weapon_objs[part_index + 1]
        if not weapon_obj or not sdk.is_managed_object(weapon_obj) then return nil end
        local mesh = get_mesh_component_recursive(weapon_obj)
        local target = mesh and mesh:call("get_GameObject") or weapon_obj
        local ok, name = pcall(function() return target:call("get_Name") end)
        return ok and name or nil
    end
})
if variant_manager_ui and not variant_manager_ui.update then
    setmetatable(variant_manager_ui, { __index = VariantManagerUI })
end
local show_debug_window = false
local function draw_targets_ui(targets, rule_type, rule_idx)
    local body_id = last_body_id
    for j, target in ipairs(targets) do
        imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)
        local all_groups = { "" }
        local all_groups_display = { T("main_list") or "Main" }
        local global_label_t = T("global_group_label") or "[Global]"
        if current_config.groups then
            local ordered_gnames = {}
            local in_order = {}
            if current_config.group_order then
                for _, gname in ipairs(current_config.group_order) do
                    if current_config.groups[gname] then
                        table.insert(ordered_gnames, gname)
                        in_order[gname] = true
                    end
                end
            end
            for gname, _ in pairs(current_config.groups) do
                if not in_order[gname] then table.insert(ordered_gnames, gname) end
            end
            for _, gname in ipairs(ordered_gnames) do
                local g_data = current_config.groups[gname]
                table.insert(all_groups, gname)
                if g_data.is_global then
                    table.insert(all_groups_display, global_label_t .. " " .. gname)
                else
                    table.insert(all_groups_display, gname)
                end
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
        local target_presets = {}
        if target.group == "" or target.group == nil then
            if current_config.presets then
                local in_order = {}
                if current_config.preset_order then
                    for _, pname in ipairs(current_config.preset_order) do
                        if current_config.presets[pname] then
                            table.insert(target_presets, pname)
                            in_order[pname] = true
                        end
                    end
                end
                for pname, _ in pairs(current_config.presets) do
                    if not in_order[pname] then table.insert(target_presets, pname) end
                end
            end
        else
            if current_config.groups and current_config.groups[target.group] and current_config.groups[target.group].presets then
                local g_data = current_config.groups[target.group]
                local in_order = {}
                if g_data.preset_order then
                    for _, pname in ipairs(g_data.preset_order) do
                        if g_data.presets[pname] then
                            table.insert(target_presets, pname)
                            in_order[pname] = true
                        end
                    end
                end
                for pname, _ in pairs(g_data.presets) do
                    if not in_order[pname] then table.insert(target_presets, pname) end
                end
            end
        end
        local p_idx = 1
        local found = false
        for idx, p in ipairs(target_presets) do
            if p == target.preset then p_idx = idx; found = true; break end
        end
        if not found and #target_presets > 0 then
            target.preset = target_presets[1]
            save_current_config_to_file(body_id)
        end
        if #target_presets == 0 then table.insert(target_presets, "None") end
        imgui.set_next_item_width(150)
        local c_p, v_p = imgui.combo("##preset", p_idx, target_presets)
        if c_p and target_presets[v_p] ~= "None" then
            target.preset = target_presets[v_p]
            save_current_config_to_file(body_id)
        end
        imgui.same_line()
        if imgui.button(T("delete_condition") .. "##del_cond") then
            table.remove(targets, j)
            save_current_config_to_file(body_id)
        end
        imgui.pop_id()
    end
end
re.on_frame(function()
    tick_scanner()
    variant_manager_ui:update()
    local local_body_id = get_body_id()
    if local_body_id then
        if local_body_id ~= last_body_id then
            last_body_id = local_body_id
            current_group_name = ""
            local restoring_mode_group = pending_mode_group_restore == true
            if not restoring_mode_group then
                active_group_presets[local_body_id] = nil
                active_overrides[local_body_id] = nil
                temp_applied_presets[local_body_id] = nil
            end
            if active_overrides[local_body_id] then
                local data = load_config_data(local_body_id)
                if data then
                    current_config = data
                    update_group_names_list()
                    update_preset_names_list()
                else
                    load_body_config(local_body_id)
                end
            else
                temp_applied_presets[local_body_id] = nil
                load_body_config(local_body_id)
            end
            if restoring_mode_group then
                pending_mode_group_restore = false
                local saved_group = mode_group_selection[local_body_id]
                if saved_group and saved_group ~= "" and current_config.groups
                    and current_config.groups[saved_group] then
                    current_group_name = saved_group
                    for index, group_name in ipairs(group_names_list) do
                        if group_name == saved_group then
                            selected_group_index = index + 1
                            break
                        end
                    end
                    update_preset_names_list()
                end
            end
        end
    end
    local all_chars = get_all_characters()
    local local_char_for_frame = get_local_player_character()
    if local_char_for_frame and sdk.is_managed_object(local_char_for_frame) then
        local local_seen = false
        for _, listed_char in ipairs(all_chars) do
            if listed_char == local_char_for_frame then
                local_seen = true
                break
            end
        end
        if not local_seen then
            table.insert(all_chars, local_char_for_frame)
        end
    end
    for _, char in ipairs(all_chars) do
        local char_body_id = get_character_body_id(char)
        if char_body_id then
            local config = load_config_data(char_body_id)
            if config then
                if not active_overrides[char_body_id] then
                    apply_all_defaults(char_body_id)
                    local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                    local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                    local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                        char_addr, config, char, active_overrides[char_body_id], merge_overrides
                    )
                    if not active_group_presets[char_body_id] then active_group_presets[char_body_id] = {} end
                    local has_global_target = false
                    if config.groups then
                        for g_name, g_data in pairs(config.groups) do
                            if g_data.is_global then
                                if activated_targets and activated_targets[g_name] then
                                    active_group_presets[char_body_id][g_name] = activated_targets[g_name]
                                    has_global_target = true
                                elseif all_targeted_groups and all_targeted_groups[g_name] then
                                    active_group_presets[char_body_id][g_name] = g_data.default_preset or ""
                                    has_global_target = true
                                end
                            end
                        end
                    end
                    if has_global_target then
                        rebuild_overrides_for_transform(char_body_id, config, activated_targets)
                        apply_preset_to_armor(char, active_overrides[char_body_id], true, true)
                    else
                        apply_preset_to_armor(char, new_overrides, true, true)
                    end
                end
                if active_overrides[char_body_id] then
                    if char and sdk.is_managed_object(char) then
                        local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                        local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                        local final_overrides = active_overrides[char_body_id]
                        local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                            char_addr, config, char, final_overrides, merge_overrides
                        )
                        if not active_group_presets[char_body_id] then active_group_presets[char_body_id] = {} end
                        local has_global_target = false
                        if config.groups then
                            for g_name, g_data in pairs(config.groups) do
                                if g_data.is_global then
                                    if activated_targets and activated_targets[g_name] then
                                        active_group_presets[char_body_id][g_name] = activated_targets[g_name]
                                        has_global_target = true
                                    elseif all_targeted_groups and all_targeted_groups[g_name] then
                                        active_group_presets[char_body_id][g_name] = g_data.default_preset or ""
                                        has_global_target = true
                                    end
                                end
                            end
                        end
                        if changed then
                            if has_global_target then
                                rebuild_overrides_for_transform(char_body_id, config, activated_targets)
                                apply_preset_to_armor(char, active_overrides[char_body_id], true, true)
                            else
                                apply_preset_to_armor(char, new_overrides, true, true)
                            end
                        else
                            if has_global_target then
                                apply_preset_to_armor(char, active_overrides[char_body_id], true, false)
                            else
                                apply_preset_to_armor(char, new_overrides, true, false)
                            end
                        end
                    end
                end
            end
        end
        local char_weapon_id, w_objs = get_character_weapon_id(char)
        if char_weapon_id and w_objs then
            local config = load_config_data(char_weapon_id)
            if config then
                if not active_overrides[char_weapon_id] then
                    apply_all_defaults(char_weapon_id)
                    local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                    local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                    local new_overrides, _ = TransformManager.apply_transform_rules(
                        char_addr, config, char, active_overrides[char_weapon_id], merge_overrides
                    )
                    apply_preset_to_weapon(char, w_objs, new_overrides, true, true)
                end
                if active_overrides[char_weapon_id] then
                    if char and sdk.is_managed_object(char) then
                        local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                        local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                        local final_overrides = active_overrides[char_weapon_id]
                        local new_overrides, changed = TransformManager.apply_transform_rules(
                            char_addr, config, char, final_overrides, merge_overrides
                        )
                        if changed then
                            apply_preset_to_weapon(char, w_objs, new_overrides, true, true)
                        else
                            apply_preset_to_weapon(char, w_objs, new_overrides, true, false)
                        end
                    end
                end
            end
        end
    end
end)
re.on_draw_ui(function()
    if imgui.tree_node(T("mod_name")) then
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()
        if variant_manager_ui:draw_settings() then
            imgui.tree_pop()
            return
        end
        if show_debug_window then
            if imgui.tree_node("Debug Info") then
                local all_chars = get_all_characters()
                imgui.text("Detected Characters: " .. tostring(#all_chars))
                if imgui.begin_table("DebugTable", 3) then
                    imgui.table_setup_column("Index")
                    imgui.table_setup_column("Address")
                    imgui.table_setup_column("BodyID")
                    imgui.table_headers_row()
                    for i, char in ipairs(all_chars) do
                        imgui.table_next_row()
                        imgui.table_set_column_index(0)
                        imgui.text(tostring(i))
                        imgui.table_set_column_index(1)
                        local addr = "N/A"
                        if char and sdk.is_managed_object(char) then
                            local ok, game_obj = pcall(function() return char:call("get_GameObject") end)
                            if ok and game_obj then addr = tostring(game_obj) end
                        else
                            addr = "Invalid/Destroyed"
                        end
                        imgui.text(addr)
                        imgui.table_set_column_index(2)
                        imgui.text(get_character_body_id(char) or "Unknown")
                    end
                    imgui.end_table()
                end
                imgui.separator()
                imgui.text("Cache Status:")
                for k, v in pairs(character_cache) do
                    imgui.text("Key: " .. tostring(k) .. " | Valid: " .. tostring(sdk.is_managed_object(v.char)))
                end
                imgui.tree_pop()
            end
        end
        local status, err = pcall(function()
            local armor_mode_text = T("armor_mode") or "Armor Variant"
            local weapon_mode_text = T("weapon_mode") or "Weapon Variant"
            local changed_armor, new_armor = imgui.checkbox(armor_mode_text, not is_weapon_mode)
            if changed_armor and new_armor then
                switch_variant_mode(false)
            end
            imgui.same_line()
            local changed_weapon, new_weapon = imgui.checkbox(weapon_mode_text, is_weapon_mode)
            if changed_weapon and new_weapon then
                switch_variant_mode(true)
            end
            imgui.separator()
            local character = get_local_player_character()
            if character and sdk.is_managed_object(character) then
                local body_id = get_body_id()
                if body_id then
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                        local ui_status, ui_err = pcall(function()
                            if config_restored[body_id] and not config_restore_handled[body_id] then
                                imgui.text_colored(T("config_restored_warning"), 0xFF00CCFF)
                                if imgui.button(T("restore_from_backup") .. "##restore_backup") then
                                    config_restore_handled[body_id] = true
                                    restore_config_from_backup(body_id)
                                end
                                imgui.same_line()
                                if imgui.button(T("dismiss") .. "##dismiss_restore") then
                                    config_restore_handled[body_id] = true
                                    config_restored[body_id] = nil
                                end
                                imgui.separator()
                            end
                            local global_label = T("global_group_label") or "[Global]"
                            local full_group_list = {T("main_list")}
                            for _, gname in ipairs(group_names_list) do
                                local g_data = current_config.groups and current_config.groups[gname]
                                if g_data and g_data.is_global then
                                    table.insert(full_group_list, global_label .. " " .. gname)
                                else
                                    table.insert(full_group_list, gname)
                                end
                            end
                            local current_group_combo_index = 1
                            if current_group_name ~= "" then
                                for i, gname in ipairs(group_names_list) do
                                    if gname == current_group_name then current_group_combo_index = i + 1; break end
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
                                        auto_set_selected_preset_as_default(body_id)
                                    end
                                else
                                    local no_preset_key = is_weapon_mode and "no_weapon_presets" or "no_presets"
                                    imgui.text_colored("[" .. T(no_preset_key) .. "]", 0xFF808080)
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
                                            if current_config.preset_order then
                                                for pi = #current_config.preset_order, 1, -1 do
                                                    if current_config.preset_order[pi] == current_preset_name then
                                                        table.remove(current_config.preset_order, pi); break
                                                    end
                                                end
                                            end
                                        else
                                            if current_config.groups[current_group_name] then
                                                current_config.groups[current_group_name].presets[current_preset_name] = nil
                                                if current_config.groups[current_group_name].default_preset == current_preset_name then
                                                    current_config.groups[current_group_name].default_preset = ""
                                                end
                                                if current_config.groups[current_group_name].preset_order then
                                                    for pi = #current_config.groups[current_group_name].preset_order, 1, -1 do
                                                        if current_config.groups[current_group_name].preset_order[pi] == current_preset_name then
                                                            table.remove(current_config.groups[current_group_name].preset_order, pi); break
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                        update_preset_names_list()
                                        save_current_config_to_file(body_id)
                                    end
                                    imgui.same_line()
                                    if not global_config.auto_set_selected_preset_as_default
                                        and imgui.button(T("set_as_default")) then
                                        set_preset_as_default(current_preset_name, body_id)
                                    end
                                    imgui.same_line()
                                    if ctx_default == current_preset_name then
                                        imgui.text_colored(T("selected_and_default"), 0xFF00FF00)
                                    else
                                        imgui.text_colored(T("selected_not_default"), 0xFF00CCFF)
                                    end
                                    imgui.same_line()
                                    if imgui.button(T("sort") .. "##p_sort") then
                                        sort_mode = "preset"
                                        sort_temp_list = {}
                                        for _, pn in ipairs(preset_names_list) do
                                            table.insert(sort_temp_list, pn)
                                        end
                                        sort_selected_index = selected_preset_index
                                    end
                                end
                                imgui.spacing()
                                local changed_auto, auto_enabled = imgui.checkbox(
                                    T("auto_set_selected_preset_as_default"),
                                    global_config.auto_set_selected_preset_as_default == true)
                                if changed_auto then
                                    global_config.auto_set_selected_preset_as_default = auto_enabled == true
                                    save_global_settings()
                                    if global_config.auto_set_selected_preset_as_default then
                                        auto_set_selected_preset_as_default(body_id)
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
                                if #preset_names_list > 0 then
                                    imgui.same_line()
                                    if imgui.button(T("overwrite_preset") .. "##p_overwrite") then
                                        local current_preset_name = preset_names_list[selected_preset_index]
                                        if current_preset_name and current_preset_name ~= "" then
                                            save_preset(current_preset_name, body_id)
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
                                    if current_config.groups and next(current_config.groups) then
                                        imgui.same_line()
                                        if imgui.button(T("sort") .. "##g_sort") then
                                            sort_mode = "group"
                                            sort_temp_list = {}
                                            for _, gn in ipairs(group_names_list) do
                                                table.insert(sort_temp_list, gn)
                                            end
                                            sort_selected_index = 1
                                            if current_group_name ~= "" then
                                                for gi, gn in ipairs(sort_temp_list) do
                                                    if gn == current_group_name then sort_selected_index = gi; break end
                                                end
                                            end
                                        end
                                    end
                                else
                                    imgui.text_colored(T("selection_mode") .. " ", 0xFF00FFFF)
                                    imgui.text_colored(T("selection_mode_desc") .. " ", 0xFF00FFFF)
                                    local cg, gtext = imgui.input_text(T("name") .. "##gn", new_group_name)
                                    if cg then new_group_name = gtext end
                                    local cg_global, new_is_global = imgui.checkbox(T("is_global_group") .. "##gisgl", new_group_is_global)
                                    if cg_global then new_group_is_global = new_is_global end
                                    if new_group_is_global then
                                        imgui.same_line()
                                        imgui.text_colored(T("is_global_group_desc"), 0xFF80FFFF)
                                    end
                                    if imgui.button(T("confirm_creation") .. "##gconfirm") then
                                        if new_group_name ~= "" and create_new_group(new_group_name, body_id, new_group_is_global) then
                                            current_group_name = new_group_name
                                            new_group_name = ""
                                            new_group_is_global = false
                                            is_selection_mode = false
                                            update_group_names_list()
                                            update_preset_names_list()
                                        end
                                    end
                                    imgui.same_line()
                                    if imgui.button(T("cancel") .. "##gcancel") then
                                        is_selection_mode = false
                                        new_group_is_global = false
                                    end
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
                                    if g.presets and next(g.presets) then has_any_data = true; break end
                                end
                            end
                            if not has_any_data then
                                imgui.separator()
                                if imgui.button(T("auto_find_preset")) then
                                    local st, res, m = pcall(find_auto_preset, body_id)
                                    if st and res then
                                        auto_find_log = T("auto_find_success") .. tostring(m or "")
                                    elseif st and m == "No matching preset found" then
                                        auto_find_log = T("auto_find_fail")
                                    else
                                        auto_find_log = st and ("Failed: " .. tostring(m)) or "Lua Error: " .. tostring(res)
                                    end
                                end
                                if auto_find_log ~= "" then imgui.text_colored(auto_find_log, 0xFF00FFFF) end
                            end
                        end)
                        if not ui_status then
                            imgui.text_colored("UI Error: " .. tostring(ui_err), 0xFFFF0000)
                            pcall(imgui.end_table)
                        end
                        if sort_mode then
                            imgui.separator()
                            local sort_title = (sort_mode == "group") and (T("sort") .. " - " .. T("group")) or (T("sort") .. " - " .. T("preset"))
                            imgui.text_colored(sort_title, 0xFF00FFFF)
                            imgui.spacing()
                            if sort_selected_index and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                imgui.text_colored(T("sort_hint_selected") .. ": " .. sort_temp_list[sort_selected_index], 0xFFFFFF80)
                            else
                                imgui.text_colored(T("sort_hint_click"), 0xFF808080)
                            end
                            imgui.spacing()
                            for si, sname in ipairs(sort_temp_list) do
                                if si <= 1 then imgui.begin_disabled() end
                                if imgui.button(T("move_up") .. "##su_" .. si) then
                                    if si > 1 then
                                        sort_temp_list[si], sort_temp_list[si - 1] = sort_temp_list[si - 1], sort_temp_list[si]
                                        if sort_selected_index == si then sort_selected_index = si - 1
                                        elseif sort_selected_index == si - 1 then sort_selected_index = si end
                                    end
                                end
                                if si <= 1 then imgui.end_disabled() end
                                imgui.same_line()
                                if si >= #sort_temp_list then imgui.begin_disabled() end
                                if imgui.button(T("move_down") .. "##sd_" .. si) then
                                    if si < #sort_temp_list then
                                        sort_temp_list[si], sort_temp_list[si + 1] = sort_temp_list[si + 1], sort_temp_list[si]
                                        if sort_selected_index == si then sort_selected_index = si + 1
                                        elseif sort_selected_index == si + 1 then sort_selected_index = si end
                                    end
                                end
                                if si >= #sort_temp_list then imgui.end_disabled() end
                                imgui.same_line()
                                if si == sort_selected_index then
                                    imgui.push_style_color(21, 0xFF00AAFF) 
                                end
                                if imgui.button(tostring(si) .. ". " .. sname .. "##sn_" .. si) then
                                    sort_selected_index = si
                                end
                                if si == sort_selected_index then
                                    imgui.pop_style_color(1)
                                end
                                if sort_selected_index and sort_selected_index ~= si and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                    imgui.same_line()
                                    if imgui.button(T("sort_insert_here") .. "##si_" .. si) then
                                        local item = table.remove(sort_temp_list, sort_selected_index)
                                        table.insert(sort_temp_list, si, item)
                                        sort_selected_index = si
                                    end
                                end
                            end
                            imgui.spacing()
                            if imgui.button(T("sort_confirm") .. "##sort_ok") then
                                if sort_mode == "group" then
                                    current_config.group_order = {}
                                    for _, gn in ipairs(sort_temp_list) do
                                        table.insert(current_config.group_order, gn)
                                    end
                                    update_group_names_list()
                                elseif sort_mode == "preset" then
                                    if current_group_name == "" then
                                        current_config.preset_order = {}
                                        for _, pn in ipairs(sort_temp_list) do
                                            table.insert(current_config.preset_order, pn)
                                        end
                                    else
                                        local g = current_config.groups and current_config.groups[current_group_name]
                                        if g then
                                            g.preset_order = {}
                                            for _, pn in ipairs(sort_temp_list) do
                                                table.insert(g.preset_order, pn)
                                            end
                                        end
                                    end
                                    update_preset_names_list()
                                end
                                save_current_config_to_file(body_id)
                                sort_mode = nil
                                sort_temp_list = {}
                            end
                            imgui.same_line()
                            if imgui.button(T("sort_cancel") .. "##sort_no") then
                                sort_mode = nil
                                sort_temp_list = {}
                            end
                        end
                        imgui.tree_pop()
                    end
                    imgui.separator()
                    if imgui.tree_node(T("transform_manager") .. " (" .. body_id .. ")") then
                        local inner_status, inner_err = pcall(function()
                            local function should_show_warning(type_key)
                                if current_config.is_parallel then
                                    return current_config.parallel_settings and current_config.parallel_settings[type_key] and current_config.parallel_settings[type_key].enabled
                                else
                                    return current_config.transform_type == type_key
                                end
                            end
                            if should_show_warning("hp") and not TransformManager.is_hp_module_initialized() then
                                imgui.text_colored(T("hp_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("weapon") and not TransformManager.has_weapon_getter() then
                                imgui.text_colored(T("weapon_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("spirit") and not TransformManager.has_spirit_getter() then
                                imgui.text_colored(T("spirit_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("dual_blades") and not TransformManager.has_dual_blades_getter() then
                                imgui.text_colored(T("dual_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("switch_axe") and not TransformManager.has_switch_axe_getter() then
                                imgui.text_colored(T("switch_axe_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("insect_glaive") and not TransformManager.has_insect_glaive_getter() then
                                imgui.text_colored(T("insect_glaive_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("charge_blade") and not TransformManager.has_charge_blade_getter() then
                                imgui.text_colored(T("charge_blade_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("greatsword_type") and not TransformManager.has_greatsword_getter() then
                                imgui.text_colored(T("greatsword_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("bow_level") and not TransformManager.has_bow_getter() then
                                imgui.text_colored(T("bow_module_not_found"), 0xFF0000FF)
                            end
                            if should_show_warning("hammer_level") and not TransformManager.has_hammer_getter() then
                                imgui.text_colored(T("hammer_module_not_found"), 0xFF0000FF)
                            end
                            imgui.separator()
                            local mode_text = current_config.is_parallel and T("current_mode_parallel") or T("current_mode_selection")
                            imgui.text(mode_text)
                            local parallel_btn_text = current_config.is_parallel and T("switch_to_selection") or T("switch_to_parallel")
                            if imgui.button(parallel_btn_text) then
                                current_config.is_parallel = not current_config.is_parallel
                                save_current_config_to_file(body_id)
                            end
                            if not current_config.is_parallel then
                                local c_type_idx = 1
                                if current_config.transform_type == "hp" then c_type_idx = 1
                                elseif current_config.transform_type == "damage" then c_type_idx = 2
                                elseif current_config.transform_type == "weapon" then c_type_idx = 3
                                elseif current_config.transform_type == "spirit" then c_type_idx = 4
                                elseif current_config.transform_type == "dual_blades" then c_type_idx = 5
                                elseif current_config.transform_type == "switch_axe" then c_type_idx = 6
                                elseif current_config.transform_type == "insect_glaive" then c_type_idx = 7
                                elseif current_config.transform_type == "charge_blade" then c_type_idx = 8
                                elseif current_config.transform_type == "greatsword_type" then c_type_idx = 9
                                elseif current_config.transform_type == "greatsword_level" then c_type_idx = 10
                                elseif current_config.transform_type == "bow_level" then c_type_idx = 11
                                elseif current_config.transform_type == "hammer_level" then c_type_idx = 12
                                end
                                local c_type_list = {
                                    T("condition_hp"),
                                    T("condition_damage"),
                                    T("condition_weapon"),
                                    T("condition_spirit"),
                                    T("condition_dual_blades"),
                                    T("condition_switch_axe"),
                                    T("condition_insect_glaive"),
                                    T("condition_charge_blade"),
                                    T("condition_greatsword_type"),
                                    T("condition_greatsword_level"),
                                    T("condition_bow_level"),
                                    T("condition_hammer_level")
                                }
                                local c_changed, c_val = imgui.combo(T("transform_condition_type"), c_type_idx, c_type_list)
                                if c_changed then
                                    if c_val == 1 then current_config.transform_type = "hp"
                                    elseif c_val == 2 then current_config.transform_type = "damage"
                                    elseif c_val == 3 then current_config.transform_type = "weapon"
                                    elseif c_val == 4 then current_config.transform_type = "spirit"
                                    elseif c_val == 5 then current_config.transform_type = "dual_blades"
                                    elseif c_val == 6 then current_config.transform_type = "switch_axe"
                                    elseif c_val == 7 then current_config.transform_type = "insect_glaive"
                                    elseif c_val == 8 then current_config.transform_type = "charge_blade"
                                    elseif c_val == 9 then current_config.transform_type = "greatsword_type"
                                    elseif c_val == 10 then current_config.transform_type = "greatsword_level"
                                    elseif c_val == 11 then current_config.transform_type = "bow_level"
                                    else current_config.transform_type = "hammer_level"
                                    end
                                    save_current_config_to_file(body_id)
                                end
                            else
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
                                draw_parallel_setting("hp", T("condition_hp"))
                                draw_parallel_setting("weapon", T("condition_weapon"))
                                draw_parallel_setting("damage", T("condition_damage"))
                                draw_parallel_setting("spirit", T("condition_spirit"))
                                draw_parallel_setting("dual_blades", T("condition_dual_blades"))
                                draw_parallel_setting("switch_axe", T("condition_switch_axe"))
                                draw_parallel_setting("insect_glaive", T("condition_insect_glaive"))
                                draw_parallel_setting("charge_blade", T("condition_charge_blade"))
                                draw_parallel_setting("greatsword_type", T("condition_greatsword_type"))
                                draw_parallel_setting("greatsword_level", T("condition_greatsword_level"))
                                draw_parallel_setting("bow_level", T("condition_bow_level"))
                                draw_parallel_setting("hammer_level", T("condition_hammer_level"))
                                imgui.unindent(10)
                            end
                            imgui.separator()
                            local function show_rule_list(rules, rule_type, get_display_name_func)
                                if not rules then return end
                                for i, rule in ipairs(rules) do
                                    imgui.push_id(rule_type .. "_rule_" .. i)
                                    imgui.spacing()
                                    local display_name = get_display_name_func(rule)
                                    imgui.text(display_name)
                                    imgui.indent(20)
                                    if not rule.targets then rule.targets = {} end
                                    draw_targets_ui(rule.targets, rule_type, i)
                                    if imgui.button("+ " .. T("add_condition") .. "##add_" .. rule_type .. "_" .. i) then
                                        table.insert(rule.targets, { group = "", preset = "" })
                                        save_current_config_to_file(body_id)
                                    end
                                    imgui.unindent(20)
                                    imgui.separator()
                                    imgui.pop_id()
                                end
                            end
                            local show_hp = (not current_config.is_parallel and current_config.transform_type == "hp") or
                                           (current_config.is_parallel and current_config.parallel_settings.hp and current_config.parallel_settings.hp.enabled)
                            if show_hp then
                                local cur_hp = TransformManager.get_character_hp_percent(character)
                                if cur_hp then
                                    imgui.text(string.format(T("cur_hp_percent"), cur_hp))
                                    imgui.set_next_item_width(80)
                                    local c_test, v_test = imgui.input_text("##test_hp_input", test_hp_input)
                                    if c_test then test_hp_input = v_test end
                                    imgui.same_line()
                                    if imgui.button(T("test_hp_btn")) then
                                        local num = tonumber(test_hp_input)
                                        if num then
                                            if num < 0 then num = 0 end
                                            if num > 100 then num = 100 end
                                            TransformManager.set_character_hp_percent(character, num)
                                        end
                                    end
                                    imgui.separator()
                                end
                                if not current_config.transform_rules then current_config.transform_rules = {} end
                                if imgui.button(T("add_node")) then
                                    table.insert(current_config.transform_rules, { threshold = 50, targets = {} })
                                    save_current_config_to_file(body_id)
                                end
                                imgui.separator()
                                for i, rule in ipairs(current_config.transform_rules) do
                                    imgui.push_id("hp_rule_" .. i)
                                    imgui.spacing()
                                    imgui.set_next_item_width(120)
                                    local c_t, v_t_str = imgui.input_text(T("hp_percent") .. "##" .. i, tostring(rule.threshold))
                                    if c_t then
                                        local num = tonumber(v_t_str)
                                        if num then
                                            if num < 1 then num = 1 end
                                            if num > 100 then num = 100 end
                                            rule.threshold = num
                                            save_current_config_to_file(body_id)
                                        end
                                    end
                                    imgui.same_line()
                                    if imgui.button(T("delete_node") .. "##" .. i) then
                                        table.remove(current_config.transform_rules, i)
                                        save_current_config_to_file(body_id)
                                    end
                                    imgui.indent(20)
                                    if not rule.targets then rule.targets = {} end
                                    draw_targets_ui(rule.targets, "hp", i)
                                    if imgui.button("+ " .. T("add_condition") .. "##hp_add_" .. i) then
                                        table.insert(rule.targets, { group = "", preset = "" })
                                        save_current_config_to_file(body_id)
                                    end
                                    imgui.unindent(20)
                                    imgui.separator()
                                    imgui.pop_id()
                                end
                            end
                            local show_weapon = (not current_config.is_parallel and current_config.transform_type == "weapon") or
                                               (current_config.is_parallel and current_config.parallel_settings.weapon and current_config.parallel_settings.weapon.enabled)
                            if show_weapon then
                                local is_drawn = TransformManager.get_character_weapon_drawn(character)
                                imgui.text((T("condition_weapon") or "Weapon State") .. ": " .. (is_drawn and T("weapon_drawn") or T("weapon_sheathed")))
                                imgui.separator()
                                if not current_config.weapon_transform_rules then
                                    current_config.weapon_transform_rules = {
                                        { state = "sheathed", targets = {} },
                                        { state = "drawn", targets = {} }
                                    }
                                end
                                show_rule_list(current_config.weapon_transform_rules, "weapon", function(rule)
                                    return rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn")
                                end)
                            end
                            local show_damage = (not current_config.is_parallel and current_config.transform_type == "damage") or
                                           (current_config.is_parallel and current_config.parallel_settings.damage and current_config.parallel_settings.damage.enabled)
                            if show_damage then
                                imgui.text(T("condition_damage"))
                                imgui.separator()
                                if not current_config.damage_transform_rules then
                                    current_config.damage_transform_rules = { { duration = 5, targets = {} } }
                                end
                                local dmg_rule = current_config.damage_transform_rules[1]
                                local char_go_ok, char_go = pcall(function() return character:call("get_GameObject") end)
                                local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(character)
                                if imgui.button((T("damage_test_btn") or "Test Hit") .. "##test_dmg") then
                                    local cur_hp = TransformManager.get_character_hp(character)
                                    if cur_hp then
                                        TransformManager.set_character_hp(character, cur_hp - 25)
                                    end
                                end
                                local remaining = TransformManager.get_damage_remaining_time(char_addr)
                                if remaining > 0 then
                                    imgui.text_colored(string.format(T("damage_countdown") or "Countdown: %.1f s", remaining), 0xFF00A0FF)
                                end
                                imgui.separator()
                                imgui.spacing()
                                if dmg_rule.condition_delay == nil then dmg_rule.condition_delay = 0 end
                                if dmg_rule.mode == nil then dmg_rule.mode = 1 end
                                if dmg_rule.loop_inactive_time == nil then dmg_rule.loop_inactive_time = 0 end
                                if dmg_rule.loop_count == nil then dmg_rule.loop_count = 0 end
                                if dmg_rule.chain_loop_count == nil then dmg_rule.chain_loop_count = 1 end
                                if dmg_rule.chain_nodes == nil then dmg_rule.chain_nodes = { { duration = 1, targets = {} } } end
                                if dmg_rule.duration == nil then dmg_rule.duration = 5 end
                                imgui.set_next_item_width(120)
                                local c_delay, v_delay_str = imgui.input_text(T("condition_delay") .. "##dmg", tostring(dmg_rule.condition_delay))
                                if c_delay then local num = tonumber(v_delay_str); if num then dmg_rule.condition_delay = math.max(0, num); save_current_config_to_file(body_id) end end
                                imgui.spacing()
                                local modes = { T("mode_normal"), T("mode_loop"), T("mode_chain") }
                                imgui.set_next_item_width(150)
                                local c_m, v_m = imgui.combo(T("action_mode") .. "##dmg", dmg_rule.mode, modes)
                                if c_m then dmg_rule.mode = v_m; save_current_config_to_file(body_id) end
                                imgui.separator()
                                if dmg_rule.mode == 1 or dmg_rule.mode == 2 then
                                    imgui.set_next_item_width(120)
                                    local c_dur, v_dur_str = imgui.input_text(T("duration") .. "##dmg", tostring(dmg_rule.duration))
                                    if c_dur then
                                        local num = tonumber(v_dur_str)
                                        if num then if num < 0 then num = 0 end; dmg_rule.duration = num; save_current_config_to_file(body_id) end
                                    end
                                    imgui.same_line()
                                    imgui.text_colored(T("duration_desc"), 0xFF808080)
                                    if dmg_rule.mode == 2 then
                                        imgui.set_next_item_width(120)
                                        local c_in, v_in_str = imgui.input_text(T("loop_inactive_time") .. "##dmg", tostring(dmg_rule.loop_inactive_time))
                                        if c_in then local num = tonumber(v_in_str); if num then dmg_rule.loop_inactive_time = math.max(0, num); save_current_config_to_file(body_id) end end
                                        imgui.same_line(); imgui.set_next_item_width(120)
                                        local c_lc, v_lc_str = imgui.input_text(T("loop_count") .. "##dmg", tostring(dmg_rule.loop_count))
                                        if c_lc then local num = tonumber(v_lc_str); if num then dmg_rule.loop_count = math.max(0, num); save_current_config_to_file(body_id) end end
                                        imgui.same_line(); imgui.text_colored(T("loop_count_desc"), 0xFF808080)
                                    end
                                    imgui.indent(20)
                                    if not dmg_rule.targets then dmg_rule.targets = {} end
                                    draw_targets_ui(dmg_rule.targets, "damage", 1)
                                    if imgui.button("+ " .. T("add_condition") .. "##dmg_add") then
                                        table.insert(dmg_rule.targets, { group = "", preset = "" })
                                        save_current_config_to_file(body_id)
                                    end
                                    imgui.unindent(20)
                                elseif dmg_rule.mode == 3 then
                                    imgui.set_next_item_width(120)
                                    local c_clc, v_clc_str = imgui.input_text(T("chain_loop_count") .. "##dmg", tostring(dmg_rule.chain_loop_count))
                                    if c_clc then local num = tonumber(v_clc_str); if num then dmg_rule.chain_loop_count = math.max(0, num); save_current_config_to_file(body_id) end end
                                    imgui.same_line(); imgui.text_colored(T("loop_count_desc"), 0xFF808080)
                                    for n_idx, node in ipairs(dmg_rule.chain_nodes) do
                                        imgui.push_id("dmg_chain_node_" .. n_idx)
                                        imgui.spacing()
                                        imgui.text(T("chain_node") .. " " .. n_idx)
                                        imgui.same_line()
                                        if imgui.button(T("delete_chain_node")) then
                                            table.remove(dmg_rule.chain_nodes, n_idx)
                                            save_current_config_to_file(body_id)
                                        end
                                        imgui.set_next_item_width(120)
                                        local c_ndur, v_ndur_str = imgui.input_text(T("duration") .. "##ndur", tostring(node.duration))
                                        if c_ndur then local num = tonumber(v_ndur_str); if num then node.duration = math.max(0, num); save_current_config_to_file(body_id) end end
                                        imgui.indent(20)
                                        if not node.targets then node.targets = {} end
                                        draw_targets_ui(node.targets, "damage_chain_" .. n_idx, 1)
                                        if imgui.button("+ " .. T("add_condition") .. "##dmg_chain_add_" .. n_idx) then
                                            table.insert(node.targets, { group = "", preset = "" })
                                            save_current_config_to_file(body_id)
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                    if imgui.button("+ " .. T("add_chain_node") .. "##dmg_chain_add") then
                                        table.insert(dmg_rule.chain_nodes, { duration = 1, targets = {} })
                                        save_current_config_to_file(body_id)
                                    end
                                end
                            end
                            local show_spirit = (not current_config.is_parallel and current_config.transform_type == "spirit") or
                                               (current_config.is_parallel and current_config.parallel_settings.spirit and current_config.parallel_settings.spirit.enabled)
                            if show_spirit then
                                local current_level = TransformManager.get_character_spirit_level(character)
                                local level_text = current_level and tostring(current_level) or "?"
                                imgui.text(T("spirit_level") .. ": " .. level_text)
                                imgui.separator()
                                if not current_config.spirit_transform_rules then
                                    current_config.spirit_transform_rules = {
                                        { level = 1, targets = {} },
                                        { level = 2, targets = {} },
                                        { level = 3, targets = {} },
                                        { level = 4, targets = {} }
                                    }
                                end
                                show_rule_list(current_config.spirit_transform_rules, "spirit", function(rule)
                                    if rule.level == 1 then return T("spirit_level_1")
                                    elseif rule.level == 2 then return T("spirit_level_2")
                                    elseif rule.level == 3 then return T("spirit_level_3")
                                    elseif rule.level == 4 then return T("spirit_level_4")
                                    else return T("spirit_level") .. " " .. tostring(rule.level) end
                                end)
                            end
                            local show_dual = (not current_config.is_parallel and current_config.transform_type == "dual_blades") or
                                             (current_config.is_parallel and current_config.parallel_settings.dual_blades and current_config.parallel_settings.dual_blades.enabled)
                            if show_dual then
                                local cur_state = TransformManager.get_character_dual_blades_state(character)
                                local state_text = ""
                                if cur_state == "normal" then state_text = T("dual_normal")
                                elseif cur_state == "kijin" then state_text = T("dual_kijin")
                                elseif cur_state == "enhancement" then state_text = T("dual_enhancement")
                                else state_text = "?" end
                                imgui.text(T("dual_current") .. ": " .. state_text)
                                imgui.separator()
                                if not current_config.dual_blades_transform_rules then
                                    current_config.dual_blades_transform_rules = {
                                        { state = "normal", targets = {} },
                                        { state = "kijin", targets = {} },
                                        { state = "enhancement", targets = {} }
                                    }
                                end
                                show_rule_list(current_config.dual_blades_transform_rules, "dual", function(rule)
                                    if rule.state == "normal" then return T("dual_normal")
                                    elseif rule.state == "kijin" then return T("dual_kijin")
                                    elseif rule.state == "enhancement" then return T("dual_enhancement")
                                    else return rule.state end
                                end)
                            end
                            local show_switch_axe = (not current_config.is_parallel and current_config.transform_type == "switch_axe") or
                                                   (current_config.is_parallel and current_config.parallel_settings.switch_axe and current_config.parallel_settings.switch_axe.enabled)
                            if show_switch_axe then
                                local cur_state = TransformManager.get_character_switch_axe_state(character)
                                local state_text = ""
                                if cur_state == "sword_normal" then state_text = T("switch_axe_sword_normal")
                                elseif cur_state == "sword_awakened" then state_text = T("switch_axe_sword_awakened")
                                elseif cur_state == "axe_normal" then state_text = T("switch_axe_axe_normal")
                                elseif cur_state == "axe_enhanced" then state_text = T("switch_axe_axe_enhanced")
                                else state_text = "?" end
                                imgui.text(T("switch_axe_current") .. ": " .. state_text)
                                imgui.separator()
                                if not current_config.switch_axe_transform_rules then
                                    current_config.switch_axe_transform_rules = {
                                        { state = "sword_normal", targets = {} },
                                        { state = "sword_awakened", targets = {} },
                                        { state = "axe_normal", targets = {} },
                                        { state = "axe_enhanced", targets = {} }
                                    }
                                end
                                show_rule_list(current_config.switch_axe_transform_rules, "switch_axe", function(rule)
                                    if rule.state == "sword_normal" then return T("switch_axe_sword_normal")
                                    elseif rule.state == "sword_awakened" then return T("switch_axe_sword_awakened")
                                    elseif rule.state == "axe_normal" then return T("switch_axe_axe_normal")
                                    elseif rule.state == "axe_enhanced" then return T("switch_axe_axe_enhanced")
                                    else return rule.state end
                                end)
                            end
                            local show_insect_glaive = (not current_config.is_parallel and current_config.transform_type == "insect_glaive") or
                                                      (current_config.is_parallel and current_config.parallel_settings.insect_glaive and current_config.parallel_settings.insect_glaive.enabled)
                            if show_insect_glaive then
                                local cur_state = TransformManager.get_character_insect_glaive_state(character)
                                local state_text = ""
                                if cur_state == "none" then state_text = T("insect_glaive_none")
                                elseif cur_state == "white" then state_text = T("insect_glaive_white")
                                elseif cur_state == "orange" then state_text = T("insect_glaive_orange")
                                elseif cur_state == "red" then state_text = T("insect_glaive_red")
                                elseif cur_state == "triple" then state_text = T("insect_glaive_triple")
                                else state_text = "?" end
                                imgui.text(T("insect_glaive_current") .. ": " .. state_text)
                                imgui.separator()
                                if not current_config.insect_glaive_transform_rules then
                                    current_config.insect_glaive_transform_rules = {
                                        { state = "none", targets = {} },
                                        { state = "white", targets = {} },
                                        { state = "orange", targets = {} },
                                        { state = "red", targets = {} },
                                        { state = "triple", targets = {} }
                                    }
                                end
                                show_rule_list(current_config.insect_glaive_transform_rules, "insect_glaive", function(rule)
                                    if rule.state == "none" then return T("insect_glaive_none")
                                    elseif rule.state == "white" then return T("insect_glaive_white")
                                    elseif rule.state == "orange" then return T("insect_glaive_orange")
                                    elseif rule.state == "red" then return T("insect_glaive_red")
                                    elseif rule.state == "triple" then return T("insect_glaive_triple")
                                    else return rule.state end
                                end)
                            end
                            local show_charge_blade = (not current_config.is_parallel and current_config.transform_type == "charge_blade") or
                                                     (current_config.is_parallel and current_config.parallel_settings.charge_blade and current_config.parallel_settings.charge_blade.enabled)
                            if show_charge_blade then
                                local cur_state = TransformManager.get_character_charge_blade_state(character)
                                local state_text = ""
                                if cur_state == "sword" then state_text = T("charge_blade_sword")
                                elseif cur_state == "axe" then state_text = T("charge_blade_axe")
                                elseif cur_state == "sword_shield" then state_text = T("charge_blade_sword_shield")
                                elseif cur_state == "sword_sword" then state_text = T("charge_blade_sword_sword")
                                elseif cur_state == "sword_shield_sword" then state_text = T("charge_blade_sword_shield_sword")
                                elseif cur_state == "axe_axe" then state_text = T("charge_blade_axe_axe")
                                elseif cur_state == "triple" then state_text = T("charge_blade_triple")
                                else state_text = "?" end
                                imgui.text(T("charge_blade_current") .. ": " .. state_text)
                                imgui.separator()
                                if not current_config.charge_blade_transform_rules then
                                    current_config.charge_blade_transform_rules = {
                                        { state = "sword", targets = {} },
                                        { state = "axe", targets = {} },
                                        { state = "sword_shield", targets = {} },
                                        { state = "sword_sword", targets = {} },
                                        { state = "sword_shield_sword", targets = {} },
                                        { state = "axe_axe", targets = {} },
                                        { state = "triple", targets = {} }
                                    }
                                end
                                show_rule_list(current_config.charge_blade_transform_rules, "charge_blade", function(rule)
                                    if rule.state == "sword" then return T("charge_blade_sword")
                                    elseif rule.state == "axe" then return T("charge_blade_axe")
                                    elseif rule.state == "sword_shield" then return T("charge_blade_sword_shield")
                                    elseif rule.state == "sword_sword" then return T("charge_blade_sword_sword")
                                    elseif rule.state == "sword_shield_sword" then return T("charge_blade_sword_shield_sword")
                                    elseif rule.state == "axe_axe" then return T("charge_blade_axe_axe")
                                    elseif rule.state == "triple" then return T("charge_blade_triple")
                                    else return rule.state end
                                end)
                            end
                            local show_greatsword_type = (not current_config.is_parallel and current_config.transform_type == "greatsword_type") or
                                                        (current_config.is_parallel and current_config.parallel_settings.greatsword_type and current_config.parallel_settings.greatsword_type.enabled)
                            if show_greatsword_type then
                                local cur_type = TransformManager.get_character_greatsword_charge_type(character)
                                local type_text = ""
                                if cur_type == "0" then type_text = T("greatsword_type_0")
                                elseif cur_type == "1" then type_text = T("greatsword_type_1")
                                elseif cur_type == "2" then type_text = T("greatsword_type_2")
                                elseif cur_type == "3" then type_text = T("greatsword_type_3")
                                elseif cur_type == "5" then type_text = T("greatsword_type_5")
                                else type_text = T("greatsword_type_other") end
                                imgui.text(T("greatsword_type_current") .. ": " .. type_text)
                                imgui.separator()
                                if not current_config.greatsword_type_transform_rules then
                                    current_config.greatsword_type_transform_rules = {
                                        { state = "0", targets = {} },
                                        { state = "1", targets = {} },
                                        { state = "2", targets = {} },
                                        { state = "3", targets = {} },
                                        { state = "5", targets = {} },
                                        { state = "other", targets = {} }
                                    }
                                end
                                show_rule_list(current_config.greatsword_type_transform_rules, "greatsword_type", function(rule)
                                    if rule.state == "0" then return T("greatsword_type_0")
                                    elseif rule.state == "1" then return T("greatsword_type_1")
                                    elseif rule.state == "2" then return T("greatsword_type_2")
                                    elseif rule.state == "3" then return T("greatsword_type_3")
                                    elseif rule.state == "5" then return T("greatsword_type_5")
                                    else return T("greatsword_type_other") end
                                end)
                            end
                            local show_greatsword_level = (not current_config.is_parallel and current_config.transform_type == "greatsword_level") or
                                                         (current_config.is_parallel and current_config.parallel_settings.greatsword_level and current_config.parallel_settings.greatsword_level.enabled)
                            if show_greatsword_level then
                                local cur_level = TransformManager.get_character_greatsword_charge_level(character)
                                imgui.text(T("greatsword_level_current") .. ": " .. tostring(cur_level))
                                imgui.separator()
                                if not current_config.greatsword_level_transform_rules then
                                    current_config.greatsword_level_transform_rules = {
                                        { level = 0, targets = {} },
                                        { level = 1, targets = {} },
                                        { level = 2, targets = {} },
                                        { level = 3, targets = {} }
                                    }
                                end
                                show_rule_list(current_config.greatsword_level_transform_rules, "greatsword_level", function(rule)
                                    return T("greatsword_level_" .. tostring(rule.level))
                                end)
                            end
                            local show_bow_level = (not current_config.is_parallel and current_config.transform_type == "bow_level") or
                                                  (current_config.is_parallel and current_config.parallel_settings.bow_level and current_config.parallel_settings.bow_level.enabled)
                            if show_bow_level then
                                local cur_level = TransformManager.get_character_bow_charge_level(character)
                                local level_text = ""
                                if cur_level == 1 then level_text = T("bow_level_1")
                                elseif cur_level == 2 then level_text = T("bow_level_2")
                                elseif cur_level == 3 then level_text = T("bow_level_3")
                                elseif cur_level == 4 then level_text = T("bow_level_4")
                                else level_text = tostring(cur_level) end
                                imgui.text(T("bow_level_current") .. ": " .. level_text)
                                imgui.separator()
                                if not current_config.bow_level_transform_rules then
                                    current_config.bow_level_transform_rules = {
                                        { level = 1, targets = {} },
                                        { level = 2, targets = {} },
                                        { level = 3, targets = {} },
                                        { level = 4, targets = {} }
                                    }
                                end
                                show_rule_list(current_config.bow_level_transform_rules, "bow_level", function(rule)
                                    if rule.level == 1 then return T("bow_level_1")
                                    elseif rule.level == 2 then return T("bow_level_2")
                                    elseif rule.level == 3 then return T("bow_level_3")
                                    elseif rule.level == 4 then return T("bow_level_4")
                                    else return T("bow_level") .. " " .. tostring(rule.level) end
                                end)
                            end
                            local show_hammer_level = (not current_config.is_parallel and current_config.transform_type == "hammer_level") or
                                                     (current_config.is_parallel and current_config.parallel_settings.hammer_level and current_config.parallel_settings.hammer_level.enabled)
                            if show_hammer_level then
                                local cur_level = TransformManager.get_character_hammer_charge_level(character)
                                local level_text = ""
                                if cur_level == 0 then level_text = T("hammer_level_0")
                                elseif cur_level == 1 then level_text = T("hammer_level_1")
                                elseif cur_level == 2 then level_text = T("hammer_level_2")
                                elseif cur_level == 3 then level_text = T("hammer_level_3")
                                else level_text = tostring(cur_level) end
                                imgui.text(T("hammer_level_current") .. ": " .. level_text)
                                imgui.separator()
                                if not current_config.hammer_level_transform_rules then
                                    current_config.hammer_level_transform_rules = {
                                        { level = 0, targets = {} },
                                        { level = 1, targets = {} },
                                        { level = 2, targets = {} },
                                        { level = 3, targets = {} }
                                    }
                                end
                                show_rule_list(current_config.hammer_level_transform_rules, "hammer_level", function(rule)
                                    if rule.level == 0 then return T("hammer_level_0")
                                    elseif rule.level == 1 then return T("hammer_level_1")
                                    elseif rule.level == 2 then return T("hammer_level_2")
                                    elseif rule.level == 3 then return T("hammer_level_3")
                                    else return T("hammer_level") .. " " .. tostring(rule.level) end
                                end)
                            end
                        end)
                        if not inner_status then
                            imgui.text_colored("UI Error: " .. tostring(inner_err), 0xFFFF0000)
                        end
                        imgui.tree_pop()
                    end
                    imgui.separator()
                    if is_weapon_mode then
                        if imgui.tree_node(T("weapon_parts") or "Weapon Parts") then
                            local w_id, w_objs = get_character_weapon_id(character)
                            if w_objs and #w_objs > 0 then
                                for idx, w_obj in ipairs(w_objs) do
                                    if sdk.is_managed_object(w_obj) then
                                        local mesh_comp = get_mesh_component_recursive(w_obj)
                                        if mesh_comp then
                                            local mesh_game_obj = mesh_comp:call("get_GameObject")
                                            local obj_name = mesh_game_obj:call("get_Name")
                                            draw_mesh_toggle(mesh_game_obj, string.format("Weapon %d [%s]", idx - 1, obj_name), body_id, tostring(idx - 1))
                                        else
                                            local obj_name = w_obj:call("get_Name")
                                            imgui.text_colored(string.format("Weapon %d [%s] (No Mesh)", idx - 1, obj_name), 0xFF808080)
                                        end
                                    end
                                end
                            else
                                imgui.text_colored("Weapon " .. T("not_equipped"), 0xFF808080)
                            end
                            imgui.tree_pop()
                        end
                    else
                        local armor_parts = {
                            [0] = T("helm"),
                            [1] = T("body"),
                            [2] = T("arm"),
                            [3] = T("waist"),
                            [4] = T("leg"),
                            [5] = T("slinger")
                        }
                        if imgui.tree_node(T("armor_parts")) then
                            for i = 0, 5 do
                                local part_obj = get_character_part(character, i)
                                local part_name = armor_parts[i]
                                local reference_part_data = active_overrides[body_id]
                                    and active_overrides[body_id][tostring(i)]
                                local mesh_components = get_character_part_meshes(character, i, reference_part_data)
                                if #mesh_components > 0 then
                                    local mesh_game_obj = mesh_components[1]:call("get_GameObject")
                                    local obj_name = mesh_game_obj and mesh_game_obj:call("get_Name") or "Mesh"
                                    draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, i)
                                elseif part_obj and not is_player_face_object(part_obj) then
                                    local obj_name = part_obj:call("get_Name")
                                    imgui.text_colored(string.format("%s [%s] (No Mesh)", part_name, obj_name), 0xFF808080)
                                else
                                    imgui.text_colored(part_name .. " " .. T("not_equipped"), 0xFF808080)
                                end
                            end
                            imgui.tree_pop()
                        end
                    end
                    imgui.separator()
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
