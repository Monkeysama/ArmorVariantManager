local mod_name = "ArmorVariantManager"
local version = "2.7.0"
local author = "MK"

-- =============================================================================
-- 多语言与全局配置系统
-- =============================================================================

local global_config_path = "ArmorVariantManager/GlobalSettings.json"

local global_config = {
    language = "zh",
    scan_interval = 0.5,
    body_id_ttl = 1.0,
    scanner_batch_size = 200
}

local Localization = require("ArmorVariantManager_Core.Localization")
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

-- =============================================================================

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

local current_config = {
    default_preset = "",
    presets = {},
    groups = {},
    transform_type = "hp",
    is_parallel = false,
    parallel_settings = {
        hp = { enabled = true, priority = 1 },
        weapon = { enabled = false, priority = 2 },
        spirit = { enabled = false, priority = 3 },
        dual_blades = { enabled = false, priority = 4 },
        switch_axe = { enabled = false, priority = 5 },
        insect_glaive = { enabled = false, priority = 6 },
        charge_blade = { enabled = false, priority = 7 },
        greatsword_type = { enabled = false, priority = 8 },
        greatsword_level = { enabled = false, priority = 9 },
        bow_level = { enabled = false, priority = 10 },
        hammer_level = { enabled = false, priority = 11 }
    },
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
local is_selection_mode = false
local pending_material_selections = {}

-- 辅助函数
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

-- =============================================================================
-- 辅助函数：获取指定 Character 的 Body ID (Name)
-- =============================================================================
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

-- =============================================================================
-- 角色扫描与缓存
-- =============================================================================
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
                                    if bid and string.find(bid, "^ch03") then
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
                            if bid and string.find(bid, "^ch03") then
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

local function get_body_id()
    return get_character_body_id(get_local_player_character())
end

local function get_config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end

-- =============================================================================
-- 预设和分组 UI 辅助
-- =============================================================================
local function update_preset_names_list()
    preset_names_list = {}
    local target_presets = nil
    if current_group_name == "" then
        target_presets = current_config.presets
    else
        if current_config.groups and current_config.groups[current_group_name] then
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
        ctx_default = current_config.default_preset or ""
    else
        if current_config.groups and current_config.groups[current_group_name] then
            ctx_default = current_config.groups[current_group_name].default_preset or ""
        end
    end
    if ctx_default ~= "" then
        local found = false
        for i, name in ipairs(preset_names_list) do
            if name == ctx_default then selected_preset_index = i; found = true; break end
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
        for name, _ in pairs(current_config.groups) do
            table.insert(group_names_list, name)
        end
        table.sort(group_names_list)
    end
    if #group_names_list == 0 then selected_group_index = 1
    elseif selected_group_index > #group_names_list then selected_group_index = 1 end
end

-- =============================================================================
-- Mesh 和部位相关函数
-- =============================================================================
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
        if g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
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

-- =============================================================================
-- 预设应用函数
-- =============================================================================
local applied_parts_cache = {}
local function apply_preset_to_character(character, preset_data, ignore_context, force_apply)
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
        local part_obj = get_character_part(character, i)
        if part_obj then
            local part_data = preset_data[tostring(i)]
            if part_data then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    local mat_count = mesh_component:call("get_MaterialNum") or 0
                    local first_mat = mat_count > 0 and mesh_component:call("getMaterialName", 0) or ""
                    local state_hash = tostring(mesh_component) .. "_" .. tostring(mat_count) .. "_" .. first_mat
                    local should_apply = force_apply or (applied_parts_cache[char_addr][i] ~= state_hash)
                    if should_apply then applied_parts_cache[char_addr][i] = state_hash end
                    if part_data.mesh_enabled ~= nil then
                        local cur_en = mesh_component:call("get_Enabled")
                        if part_data.mesh_enabled == false then
                            if cur_en ~= false then mesh_component:call("set_Enabled", false) end
                        elseif should_apply then
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
                                elseif mat_enabled == true and should_apply then
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

-- =============================================================================
-- 分组管理
-- =============================================================================
local function create_new_group(group_name, body_id)
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
        presets = {}
    }
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

-- =============================================================================
-- 配置加载与保存
-- =============================================================================
local function load_config_data(body_id)
    if not body_id then return nil end
    if loaded_configs[body_id] then return loaded_configs[body_id] end
    local path = get_config_path(body_id)
    local loaded_data = json.load_file(path)
    if loaded_data then
        if not loaded_data.presets then loaded_data.presets = {} end
        if not loaded_data.default_preset then loaded_data.default_preset = "" end
        if not loaded_data.groups then loaded_data.groups = {} end
        if not loaded_data.transform_type then loaded_data.transform_type = "hp" end
        if loaded_data.is_parallel == nil then loaded_data.is_parallel = false end
        if not loaded_data.parallel_settings then
            loaded_data.parallel_settings = {
                hp = { enabled = true, priority = 1 },
                weapon = { enabled = false, priority = 2 },
                spirit = { enabled = false, priority = 3 },
                dual_blades = { enabled = false, priority = 4 },
                switch_axe = { enabled = false, priority = 5 },
                insect_glaive = { enabled = false, priority = 6 },
                charge_blade = { enabled = false, priority = 7 },
                greatsword_type = { enabled = false, priority = 8 },
                greatsword_level = { enabled = false, priority = 9 },
                bow_level = { enabled = false, priority = 10 },
                hammer_level = { enabled = false, priority = 11 }
            }
        else
            if not loaded_data.parallel_settings.spirit then
                loaded_data.parallel_settings.spirit = { enabled = false, priority = 3 }
            end
            if not loaded_data.parallel_settings.dual_blades then
                loaded_data.parallel_settings.dual_blades = { enabled = false, priority = 4 }
            end
            if not loaded_data.parallel_settings.switch_axe then
                loaded_data.parallel_settings.switch_axe = { enabled = false, priority = 5 }
            end
            if not loaded_data.parallel_settings.insect_glaive then
                loaded_data.parallel_settings.insect_glaive = { enabled = false, priority = 6 }
            end
            if not loaded_data.parallel_settings.charge_blade then
                loaded_data.parallel_settings.charge_blade = { enabled = false, priority = 7 }
            end
            if not loaded_data.parallel_settings.greatsword_type then
                loaded_data.parallel_settings.greatsword_type = { enabled = false, priority = 8 }
            end
            if not loaded_data.parallel_settings.greatsword_level then
                loaded_data.parallel_settings.greatsword_level = { enabled = false, priority = 9 }
            end
            if not loaded_data.parallel_settings.bow_level then
                loaded_data.parallel_settings.bow_level = { enabled = false, priority = 10 }
            end
            if not loaded_data.parallel_settings.hammer_level then
                loaded_data.parallel_settings.hammer_level = { enabled = false, priority = 11 }
            end
        end
        if not loaded_data.transform_rules then loaded_data.transform_rules = {} end
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

local function apply_all_defaults(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    active_overrides[body_id] = {}
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
        merge_preset_into_overrides(current_body_id, preset_data)
        temp_applied_presets[current_body_id] = preset_name
    end
    local all_chars = get_all_characters()
    for _, char in ipairs(all_chars) do
        local char_body_id = get_character_body_id(char)
        if char_body_id and char_body_id == current_body_id then
            apply_preset_to_character(char, active_overrides[current_body_id], true, true)
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
        parallel_settings = {
            hp = { enabled = true, priority = 1 },
            weapon = { enabled = false, priority = 2 },
            spirit = { enabled = false, priority = 3 },
            dual_blades = { enabled = false, priority = 4 },
            switch_axe = { enabled = false, priority = 5 },
            insect_glaive = { enabled = false, priority = 6 },
            charge_blade = { enabled = false, priority = 7 },
            greatsword_type = { enabled = false, priority = 8 },
            greatsword_level = { enabled = false, priority = 9 },
            bow_level = { enabled = false, priority = 10 },
            hammer_level = { enabled = false, priority = 11 }
        },
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
    for i = 0, 5 do
        local part_obj = get_character_part(character, i)
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
    local character = get_local_player_character()
    if not character or not sdk.is_managed_object(character) then return false, "No Character" end
    local body_part = get_character_part(character, 1)
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
                for _, preset in pairs(data.presets) do first_preset = preset; break end
                if first_preset and first_preset["1"] and first_preset["1"].materials then
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

local show_debug_window = false

-- =============================================================================
-- =============================================================================

-- 辅助函数：在 UI 中绘制条件的目标列表（捕获外部的 body_id 和 current_config）
local function draw_targets_ui(targets, rule_type, rule_idx)
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
        end

        imgui.same_line()
        if imgui.button(T("delete_condition") .. "##del_cond") then
            table.remove(targets, j)
            save_current_config_to_file(body_id)
        end
        imgui.pop_id()
    end
end

-- =============================================================================
-- 每一帧执行
-- =============================================================================
re.on_frame(function()
    tick_scanner()

    local local_body_id = get_body_id()
    if local_body_id then
        if local_body_id ~= last_body_id then
            last_body_id = local_body_id
            active_overrides[local_body_id] = nil
            temp_applied_presets[local_body_id] = nil
            load_body_config(local_body_id)
        end
    else
        last_body_id = nil
    end

    -- 遍历所有角色并应用规则引擎
    local all_chars = get_all_characters()
    for _, char in ipairs(all_chars) do
        local char_body_id = get_character_body_id(char)
        if char_body_id then
            local config = load_config_data(char_body_id)
            if not active_overrides[char_body_id] then
                apply_all_defaults(char_body_id)
            end
            if active_overrides[char_body_id] then
                if char and sdk.is_managed_object(char) then
                    local char_go_ok, char_go = pcall(function() return char:call("get_GameObject") end)
                    local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(char)
                    local final_overrides = active_overrides[char_body_id]
                    local new_overrides, changed = TransformManager.apply_transform_rules(
                        char_addr, config, char, final_overrides, merge_overrides
                    )
                    if changed then
                        active_overrides[char_body_id] = new_overrides
                        apply_preset_to_character(char, new_overrides, true, true)
                    end
                end
            end
        end
    end
end)

-- =============================================================================
-- UI 绘制
-- =============================================================================
re.on_draw_ui(function()
    if imgui.tree_node(T("mod_name")) then
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()

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
            local character = get_local_player_character()
            if character and sdk.is_managed_object(character) then
                local body_id = get_body_id()
                if body_id then
                    -- ========== 预设管理区域 ==========
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                        local ui_status, ui_err = pcall(function()
                            local full_group_list = {T("main_list")}
                            for _, gname in ipairs(group_names_list) do table.insert(full_group_list, gname) end
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

                            -- 分组材质预览
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
                                    auto_find_log = st and (res and m or "Failed: " .. m) or "Lua Error: " .. tostring(res)
                                end
                                if auto_find_log ~= "" then imgui.text_colored(auto_find_log, 0xFF00FFFF) end
                            end
                        end)
                        if not ui_status then
                            imgui.text_colored("UI Error: " .. tostring(ui_err), 0xFFFF0000)
                            pcall(imgui.end_table)
                        end
                        imgui.tree_pop()
                    end

                    imgui.separator()

                    -- ========== 变身管理区域 ==========
                    if imgui.tree_node(T("transform_manager") .. " (" .. body_id .. ")") then
                        local inner_status, inner_err = pcall(function()
                            -- 模块状态提示
                            if not TransformManager.is_hp_module_initialized() then
                                imgui.text_colored(T("hp_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_weapon_getter() then
                                imgui.text_colored(T("weapon_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_spirit_getter() then
                                imgui.text_colored(T("spirit_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_dual_blades_getter() then
                                imgui.text_colored(T("dual_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_switch_axe_getter() then
                                imgui.text_colored(T("switch_axe_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_insect_glaive_getter() then
                                imgui.text_colored(T("insect_glaive_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_charge_blade_getter() then
                                imgui.text_colored(T("charge_blade_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_greatsword_getter() then
                                imgui.text_colored(T("greatsword_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_bow_getter() then
                                imgui.text_colored(T("bow_module_not_found"), 0xFF0000FF)
                            end
                            if not TransformManager.has_hammer_getter() then
                                imgui.text_colored(T("hammer_module_not_found"), 0xFF0000FF)
                            end
                            imgui.separator()

                            -- 模式选择
                            local mode_text = current_config.is_parallel and T("current_mode_parallel") or T("current_mode_selection")
                            imgui.text(mode_text)
                            local parallel_btn_text = current_config.is_parallel and T("switch_to_selection") or T("switch_to_parallel")
                            if imgui.button(parallel_btn_text) then
                                current_config.is_parallel = not current_config.is_parallel
                                save_current_config_to_file(body_id)
                            end

                            if not current_config.is_parallel then
                                -- 单一条件模式
                                local c_type_idx = 1
                                if current_config.transform_type == "hp" then c_type_idx = 1
                                elseif current_config.transform_type == "weapon" then c_type_idx = 2
                                elseif current_config.transform_type == "spirit" then c_type_idx = 3
                                elseif current_config.transform_type == "dual_blades" then c_type_idx = 4
                                elseif current_config.transform_type == "switch_axe" then c_type_idx = 5
                                elseif current_config.transform_type == "insect_glaive" then c_type_idx = 6
                                elseif current_config.transform_type == "charge_blade" then c_type_idx = 7
                                elseif current_config.transform_type == "greatsword_type" then c_type_idx = 8
                                elseif current_config.transform_type == "greatsword_level" then c_type_idx = 9
                                elseif current_config.transform_type == "bow_level" then c_type_idx = 10
                                elseif current_config.transform_type == "hammer_level" then c_type_idx = 11
                                end
                                local c_type_list = {
                                    T("condition_hp"),
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
                                    elseif c_val == 2 then current_config.transform_type = "weapon"
                                    elseif c_val == 3 then current_config.transform_type = "spirit"
                                    elseif c_val == 4 then current_config.transform_type = "dual_blades"
                                    elseif c_val == 5 then current_config.transform_type = "switch_axe"
                                    elseif c_val == 6 then current_config.transform_type = "insect_glaive"
                                    elseif c_val == 7 then current_config.transform_type = "charge_blade"
                                    elseif c_val == 8 then current_config.transform_type = "greatsword_type"
                                    elseif c_val == 9 then current_config.transform_type = "greatsword_level"
                                    elseif c_val == 10 then current_config.transform_type = "bow_level"
                                    else current_config.transform_type = "hammer_level"
                                    end
                                    save_current_config_to_file(body_id)
                                end
                            else
                                -- 并行条件模式
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

                            -- 辅助函数：显示某个规则类型的配置
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

                            -- HP 规则
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
                                    table.insert(current_config.transform_rules, { threshold = 100, targets = {} })
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

                            -- 武器规则
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

                            -- 气刃规则
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

                            -- 双刀鬼人规则
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

                            -- 斩斧规则
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

                            -- 虫棍灯色规则
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

                            -- 盾斧规则
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

                            -- 大剑蓄力类型规则
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

                            -- 大剑蓄力等级规则
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

                            -- 弓箭蓄力等级规则
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

                            -- 大锤蓄力等级规则
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

                    -- ========== 防具部位列表 ==========
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

                    -- ========== 语言切换 ==========
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

                    -- ========== 性能设置 ==========
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