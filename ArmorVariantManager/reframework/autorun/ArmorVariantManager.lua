local mod_name = "ArmorVariantManager"
local version = "2.3.6"
local author = "Moon、MK"
-- Ported from MHWS version
-- Original author: MK

local global_config_path = "ArmorVariantManager/GlobalSettings.json"
local global_config = {
    language = "zh", -- 默认语言: zh (中文), en (英文)
    scan_interval = 0.5, -- 全量扫描间隔 (秒)
    body_id_ttl = 1.0, -- Body ID 缓存有效期 (秒)，默认缩短以加速换装检测
    scanner_batch_size = 100, -- 每帧扫描的对象数量
    enable_image_quality = false,      -- 是否启用自定义渲染比例
    image_quality_rate = 1.0           -- 渲染比例（1.0 = 100%）
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
        if loaded.enable_image_quality ~= nil then global_config.enable_image_quality = loaded.enable_image_quality end
        if loaded.image_quality_rate then global_config.image_quality_rate = loaded.image_quality_rate end
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

-- ========== 预定义 PlayerManager 相关类型和方法 ==========
local playerManagerTypeDef = sdk.find_type_definition("snow.player.PlayerManager")
local playerListField = playerManagerTypeDef and playerManagerTypeDef:get_field("PlayerList")
local playerListGetItem = nil
if playerListField then
    local playerListTypeDef = playerListField:get_type()
    playerListGetItem = playerListTypeDef:get_method("get_Item")
end

-- ========== 模式切换 ==========
local is_weapon_mode = false

-- 状态变量
local loaded_configs = {}
local active_overrides = {}
local active_group_presets = {}   -- body_id -> { group_name = preset_name }
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
local new_group_is_global = false
local is_selection_mode = false
local pending_material_selections = {}

-- 材质过滤
local mat_filter_text = {}

-- 排序状态
local sort_mode = nil   -- "preset" or "group"
local sort_temp_list = {}
local sort_selected_index = 1

-- 备份恢复状态
local config_restored = {}
local config_restore_handled = {}

-- 性能优化：缓存上次应用到渲染的材质状态，避免重复调用 setMaterialsEnable
local last_applied_overrides = {}  -- body_id -> deep copy of the last applied overrides
-- 特殊内嵌式 CG 标志（用于临时绕过缓存）
local g_is_special_cg = false
-- 特殊CG期间的应用帧计数器
local special_cg_frame_counter = 0
local SPECIAL_CG_APPLY_INTERVAL = 15  -- 每15帧应用一次（可调整）

-- 记录每个 body_id 对应的玩家 GameObject 地址，用于检测换装重建
local last_player_addresses = {}

-- 辅助函数
local function deep_copy_table(orig) return Utils.deep_copy_table(orig) end
local function get_type(name) return Utils.get_type(name) end
local function get_player_manager() return sdk.get_managed_singleton("snow.player.PlayerManager") end

-- ========== 多玩家管理 ==========
local player_list = {}

-- 辅助函数：检查玩家是否有 body 子物体
local function player_has_body(player)
    local transform = player:call("get_Transform")
    if not transform then return false end
    local child = transform:call("get_Child")
    while child do
        local child_obj = child:call("get_GameObject")
        if child_obj then
            local name = child_obj:call("get_Name")
            if name and string.find(name, "body") then
                return true
            end
        end
        child = child:call("get_Next")
    end
    return false
end

-- 按需回退扫描（仅当列表为空时触发，带缓存）
local fallback_cache = nil
local fallback_cache_time = 0
local fallback_cache_ttl = 5.0

local function scan_fallback_once()
    local now = os.clock()
    if fallback_cache and (now - fallback_cache_time) < fallback_cache_ttl then
        return fallback_cache
    end
    local scene_manager = sdk.get_native_singleton("via.SceneManager")
    if not scene_manager then return nil end
    local scene = sdk.call_native_func(scene_manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return nil end
    local transforms = scene:call("findComponents(System.Type)", type_cache.via_transform)
    if not transforms then return nil end
    local list = transforms:get_elements()
    for _, t in ipairs(list) do
        local ok, game_obj = pcall(method_cache.Component_get_GameObject.call, method_cache.Component_get_GameObject, t)
        if ok and game_obj then
            local name = game_obj:call("get_Name")
            if name then
                local lowerName = name:lower()
                if string.find(lowerName, "female") or string.find(lowerName, "male") or string.find(lowerName, "player") then
                    if player_has_body(game_obj) then
                        fallback_cache = game_obj
                        fallback_cache_time = now
                        return game_obj
                    end
                end
            end
        end
    end
    fallback_cache = nil
    fallback_cache_time = now
    return nil
end

-- 获取 Body ID（防具模式）
local function get_character_body_id(character)
    if not character then return nil end
    if not sdk.is_managed_object(character) then return nil end
    local transform = character:call("get_Transform")
    if transform then
        local child = transform:call("get_Child")
        while child do
            local child_obj = child:call("get_GameObject")
            if child_obj then
                local name = child_obj:call("get_Name")
                if name and string.find(name, "body") then
                    return name
                end
            end
            child = child:call("get_Next")
        end
    end
    local go_name = character:call("get_Name")
    if go_name then return go_name end
    return nil
end

-- ========== 获取武器的主要攻击部件名称（用于预设管理ID） ==========
-- 采用原有崛起版本逻辑：基于部件前缀确定主要部件
local function get_weapon_attack_part_name(player_obj)
    if not player_obj then return nil end
    if not sdk.is_managed_object(player_obj) then return nil end

    local weapon_parts = Utils.get_current_weapon_parts(player_obj)
    if not weapon_parts or #weapon_parts == 0 then return nil end
    
    local weapon_type = Utils.get_current_weapon_type(player_obj)
    if not weapon_type then return nil end

    -- 对于双刀特殊处理
    if weapon_type == Utils.WEAPON_TYPE.DUAL_BLADES then
        if weapon_parts[1] then
            return weapon_parts[1]:call("get_Name")
        end
    end
    
    local main_part_index = {
        [Utils.WEAPON_TYPE.GREATSWORD] = 1,
        [Utils.WEAPON_TYPE.SWITCH_AXE] = 1,
        [Utils.WEAPON_TYPE.LONGSWORD] = 2,
        [Utils.WEAPON_TYPE.LIGHT_BOWGUN] = 1,
        [Utils.WEAPON_TYPE.HEAVY_BOWGUN] = 1,
        [Utils.WEAPON_TYPE.HAMMER] = 1,
        [Utils.WEAPON_TYPE.GUNLANCE] = 2,
        [Utils.WEAPON_TYPE.LANCE] = 2,
        [Utils.WEAPON_TYPE.SWORD_SHIELD] = 2,
        [Utils.WEAPON_TYPE.DUAL_BLADES] = 1,
        [Utils.WEAPON_TYPE.HUNTING_HORN] = 1,
        [Utils.WEAPON_TYPE.CHARGE_BLADE] = 2,
        [Utils.WEAPON_TYPE.INSECT_GLAIVE] = 2,
        [Utils.WEAPON_TYPE.BOW] = 1,
    }
    
    local idx = main_part_index[weapon_type] or 1
    if weapon_parts[idx] then
        return weapon_parts[idx]:call("get_Name")
    end
    for _, part in ipairs(weapon_parts) do
        if part then return part:call("get_Name") end
    end
    return nil
end

-- 获取正常玩家（通过 PlayerManager 的 PlayerList）
local function get_normal_players()
    local players = {}
    local pm = get_player_manager()
    if not pm or not playerListGetItem then return players end
    local playerList = pm:get_field("PlayerList")
    if not playerList then return players end
    for i = 0, 8 do
        local player = playerListGetItem:call(playerList, i)
        if player then
            local ok, go = pcall(function() return player:call("get_GameObject") end)
            if ok and go then
                table.insert(players, go)
            end
        end
    end
    return players
end

-- 获取事件玩家（CG）
-- 特殊内嵌式 CG：使用 get_Count / get_Item；普通 CG：使用 ToArray
local function get_event_players()
    local players = {}
    local eventManager = sdk.get_managed_singleton("snow.eventcut.EventManager")
    if not eventManager then return players end
    local loadHandlerStack = eventManager:call("get_LoadHandlerStack")
    if not loadHandlerStack then return players end
    for _, handler in ipairs(loadHandlerStack) do
        if handler then
            local uniqueEventManager = handler:call("findUniqueEventManager")
            if uniqueEventManager then
                local eventPlayerList = uniqueEventManager:call("get_EventPlayerList")
                if eventPlayerList then
                    -- 优先尝试 get_Count / get_Item（特殊内嵌式 CG）
                    local ok_count, count = pcall(function() return eventPlayerList:call("get_Count") end)
                    if ok_count and type(count) == "number" and count > 0 then
                        for i = 0, count - 1 do
                            local ok_player, eventPlayer = pcall(function() return eventPlayerList:call("get_Item", i) end)
                            if ok_player and eventPlayer then
                                local ok_go, go = pcall(function() return eventPlayer:call("get_GameObject") end)
                                if ok_go and go then
                                    table.insert(players, go)
                                end
                            end
                        end
                    else
                        -- 回退到 ToArray（普通独立过场 CG）
                        local ok_arr, arr = pcall(function() return eventPlayerList:call("ToArray") end)
                        if ok_arr and arr then
                            for _, eventPlayer in ipairs(arr) do
                                if eventPlayer then
                                    local ok_go, go = pcall(function() return eventPlayer:call("get_GameObject") end)
                                    if ok_go and go then
                                        table.insert(players, go)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return players
end

-- 刷新玩家列表
local function refresh_player_list()
    local new_list = {}
    local normal = get_normal_players()
    for _, p in ipairs(normal) do
        table.insert(new_list, p)
    end
    local event = get_event_players()
    for _, p in ipairs(event) do
        local found = false
        for _, existing in ipairs(new_list) do
            if existing == p then found = true; break end
        end
        if not found then
            table.insert(new_list, p)
        end
    end
    if #new_list == 0 then
        local fallback = scan_fallback_once()
        if fallback then
            table.insert(new_list, fallback)
        end
    end
    player_list = new_list
end

-- 获取本地玩家（MasterPlayer）的 GameObject
local function get_master_player_object()
    local master = Utils.get_master_player()
    if not master then return nil end
    local ok, go = pcall(function() return master:call("get_GameObject") end)
    if ok and go and sdk.is_managed_object(go) then
        return go
    end
    return nil
end

-- 获取主玩家（优先本地玩家，回退到列表中的第一个 "player" 对象）
local function get_primary_player()
    -- 1. 优先使用本地玩家（MasterPlayer）
    local master_go = get_master_player_object()
    if master_go then
        return master_go
    end
    -- 2. 回退到 player_list（联机场景或特殊情况下）
    if #player_list == 0 then return nil end
    for _, player in ipairs(player_list) do
        local name = player:call("get_Name")
        if name and string.sub(name, 1, 6):lower() == "player" then
            if player_has_body(player) then
                return player
            end
        end
    end
    return player_list[1]
end

-- 获取主玩家 ID（防具模式返回 body 子物体名，武器模式返回主要攻击部件名）
local function get_primary_body_id()
    local primary = get_primary_player()
    if not primary then return nil end
    if is_weapon_mode then
        return get_weapon_attack_part_name(primary)
    else
        return get_character_body_id(primary)
    end
end

-- ========== 全局分组辅助函数 ==========
-- 获取包含指定材质的全局分组列表
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
    return result
end

-- 检查材质是否被某个全局分组强制隐藏（根据当前激活的预设）
local function is_globally_hidden(part_index, mat_name)
    if current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global then
        return false
    end
    if not current_config.groups then return false end
    local s_idx = tostring(part_index)
    local body_id = get_primary_body_id()
    local saved = (body_id and active_group_presets[body_id]) or {}
    for g_name, g_data in pairs(current_config.groups) do
        if g_data.is_global and g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
            local pname = saved[g_name]
            if not pname or pname == "" then pname = g_data.default_preset end
            if pname and pname ~= "" and g_data.presets and g_data.presets[pname] then
                local def = g_data.presets[pname]
                if def and def[s_idx] and def[s_idx].materials and def[s_idx].materials[mat_name] == false then
                    return true
                end
            end
        end
    end
    return false
end

-- 仅合并全局分组的隐藏覆盖（只设置 false，不设置 true）
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

-- ========== 辅助函数 ==========
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

-- 更新预设列表（支持顺序）
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
            for name, _ in pairs(target_presets) do
                if not added[name] then
                    table.insert(preset_names_list, name)
                end
            end
        else
            for name, _ in pairs(target_presets) do
                table.insert(preset_names_list, name)
            end
            table.sort(preset_names_list)
        end
    end
    -- 当前选中的预设（优先使用 active_group_presets 记录的预设）
    local current_body_id = get_primary_body_id()
    local active_preset_name = ""
    if current_body_id and active_group_presets[current_body_id] and active_group_presets[current_body_id][current_group_name] then
        active_preset_name = active_group_presets[current_body_id][current_group_name]
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

-- 更新分组列表（支持顺序）
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

-- 获取材质所属的非全局分组（独占）
local function get_material_group_owner(part_index, mat_name)
    if not mat_name then return nil end
    if not current_config or not current_config.groups then return nil end
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

-- 材质是否属于当前 UI 上下文（考虑全局分组）
local function is_material_in_current_context(part_index, mat_name)
    if current_group_name == "" then
        return get_material_group_owner(part_index, mat_name) == nil
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

-- 比较两个 overrides 表是否相等（只比较材质开关，不比较 mesh_enabled）
local function is_overrides_equal(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for p_idx, p_data in pairs(a) do
        local other = b[p_idx]
        if not other then return false end
        if p_data.materials then
            if not other.materials then return false end
            for mat, val in pairs(p_data.materials) do
                if other.materials[mat] ~= val then return false end
            end
            for mat, val in pairs(other.materials) do
                if p_data.materials[mat] ~= val then return false end
            end
        elseif other.materials then
            return false
        end
    end
    for p_idx, p_data in pairs(b) do
        if not a[p_idx] then return false end
    end
    return true
end

local function apply_preset_to_character(character, preset_data, ignore_context)
    if not character or not preset_data then return end
    if not sdk.is_managed_object(character) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end

    -- 特殊CG期间降低应用频率
    if g_is_special_cg then
        special_cg_frame_counter = special_cg_frame_counter + 1
        if special_cg_frame_counter < SPECIAL_CG_APPLY_INTERVAL then
            return
        else
            special_cg_frame_counter = 0
        end
    end

    -- 获取当前 body_id（用于缓存键）
    local body_id = get_character_body_id(character)
    if not body_id then return end

    -- 获取当前应该应用的意图值（active_overrides）
    local current_intent = active_overrides[body_id]
    if not current_intent then return end

    -- 快速检查：仅在非特殊CG且与上次应用的状态相同时跳过
    local last_applied = last_applied_overrides[body_id]
    if not g_is_special_cg and last_applied and is_overrides_equal(current_intent, last_applied) then
        return  -- 无变化，直接返回
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
                                        if mat_enabled == false then
                                            mesh_component:call("setMaterialsEnable", j, false)
                                        elseif mat_enabled == true then
                                            if is_globally_hidden(i, mat_name) then
                                                mesh_component:call("setMaterialsEnable", j, false)
                                            else
                                                mesh_component:call("setMaterialsEnable", j, true)
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
    end

    -- 更新缓存
    last_applied_overrides[body_id] = deep_copy_table(current_intent)
end

local function apply_preset_to_weapon(weapon_parts, preset_data, ignore_context, body_id)
    if not weapon_parts or not preset_data then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end

    -- 使用传入的 body_id，不再调用 get_primary_body_id
    if not body_id then return end

    -- 特殊CG期间降低应用频率
    if g_is_special_cg then
        special_cg_frame_counter = special_cg_frame_counter + 1
        if special_cg_frame_counter < SPECIAL_CG_APPLY_INTERVAL then
            return
        else
            special_cg_frame_counter = 0
        end
    end

    local current_intent = active_overrides[body_id]
    if not current_intent then return end

    local last_applied = last_applied_overrides[body_id]
    if not g_is_special_cg and last_applied and is_overrides_equal(current_intent, last_applied) then
        return
    end

    for i, part_obj in ipairs(weapon_parts) do
        if part_obj and sdk.is_managed_object(part_obj) then
            local part_data = preset_data[tostring(i - 1)]
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
                                if ignore_context or is_material_in_current_context(i - 1, mat_name) then
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

    last_applied_overrides[body_id] = deep_copy_table(current_intent)
end

-- 创建分组（支持 is_global）
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

-- 删除分组
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

local function get_config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end

-- ========== 预设备份与恢复辅助函数 ==========
local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k, v in pairs(b) do
        if not deep_equal(v, a[k]) then return false end
    end
    return true
end

local function get_backup_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/backup/" .. body_id .. ".json"
end

-- 从备份恢复配置
local function restore_config_from_backup(body_id)
    if not body_id then return false end
    local path = get_config_path(body_id)
    local backup_path = get_backup_path(body_id)
    if not backup_path then return false end
    
    local backup_data = json.load_file(backup_path)
    if not backup_data then return false end
    
    json.dump_file(path, backup_data)
    
    loaded_configs[body_id] = nil
    active_overrides[body_id] = nil
    config_restored[body_id] = nil
    config_restore_handled[body_id] = nil
    last_applied_overrides[body_id] = nil   -- 清除渲染缓存
    
    local data = load_config_data(body_id)
    if data then
        for k, v in pairs(data) do
            current_config[k] = deep_copy_table(v)
        end
        update_group_names_list()
        update_preset_names_list()
        apply_all_defaults(body_id)
        
        local current_preset_name = preset_names_list[selected_preset_index]
        if current_preset_name then
            apply_preset(current_preset_name)
        end
        
        local primary = get_primary_player()
        if primary then
            if is_weapon_mode then
                local weapon_parts = Utils.get_current_weapon_parts(primary)
                if weapon_parts then
                    apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                end
            else
                apply_preset_to_character(primary, active_overrides[body_id], true)
            end
        end
        return true
    end
    return false
end

-- 保存配置到文件（同时写备份）
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
    last_applied_overrides[body_id] = nil   -- 保存后清除缓存，强制下一帧重绘
    
    -- 清除 active_overrides 缓存，强制下一帧重新合并所有默认预设
    if active_overrides[body_id] then
        active_overrides[body_id] = nil
    end
    -- 清除 active_group_presets 缓存，确保下一帧 apply_all_defaults 使用配置中的默认预设，
    -- 避免变身规则之前设置的全局分组预设残留导致状态不一致
    active_group_presets[body_id] = nil
    
    -- 清除状态机缓存，强制下一帧重新应用最新的预设内容
    if TransformManager.clear_cache then
        TransformManager.clear_cache()
    end
end

-- 加载配置数据（带备份比对）
local function load_config_data(body_id)
    if not body_id then return nil end
    if loaded_configs[body_id] then return loaded_configs[body_id] end
    local path = get_config_path(body_id)
    local loaded_data = json.load_file(path)
    
    local backup_path = get_backup_path(body_id)
    local backup_data = backup_path and json.load_file(backup_path)
    if backup_data and loaded_data then
        -- 重新读取原始主配置（未补全）用于比较
        local raw_main = json.load_file(path)
        if raw_main then
            local same = deep_equal(raw_main, backup_data)
            if not same then
                config_restored[body_id] = true
            else
                config_restored[body_id] = nil
            end
        else
            config_restored[body_id] = nil
        end
    else
        config_restored[body_id] = nil
    end
    
    if loaded_data then
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

-- ============================================================================
-- 初始化默认预设（按正确顺序：主列表 -> 普通分组 -> 全局分组）
-- 为全局分组增加 Fallback：若 default_preset 缺失，则自动选取该分组的第一个预设
-- ============================================================================
local function apply_all_defaults(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    active_overrides[body_id] = {}
    if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
    -- 清除渲染缓存，强制下一帧重新应用
    last_applied_overrides[body_id] = nil

    -- 1. 主列表默认预设
    if config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then
            merge_preset_into_overrides(body_id, def)
            if not active_group_presets[body_id][""] or active_group_presets[body_id][""] == "" then
                active_group_presets[body_id][""] = config.default_preset
            end
        end
    end

    -- 2. 非全局分组默认预设
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

    -- 3. 全局分组默认预设（仅隐藏覆盖），增加 Fallback 机制
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if g_data.is_global then
                local default_preset = g_data.default_preset
                -- 如果 default_preset 无效，自动选取该分组的第一个预设
                if not default_preset or default_preset == "" then
                    if g_data.presets and next(g_data.presets) then
                        -- 优先按 preset_order 排序，取第一个
                        if g_data.preset_order and #g_data.preset_order > 0 then
                            for _, pname in ipairs(g_data.preset_order) do
                                if g_data.presets[pname] then
                                    default_preset = pname
                                    break
                                end
                            end
                        end
                        -- 如果 preset_order 无效，按遍历顺序取第一个
                        if not default_preset then
                            for pname, _ in pairs(g_data.presets) do
                                default_preset = pname
                                break
                            end
                        end
                    end
                end
                -- 应用选定的默认预设
                if default_preset and default_preset ~= "" and g_data.presets and g_data.presets[default_preset] then
                    local g_def = g_data.presets[default_preset]
                    merge_global_preset_into_overrides(body_id, g_def)
                    if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                        active_group_presets[body_id][g_name] = default_preset
                    end
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

-- 应用预设（支持全局分组覆盖重建）
local function apply_preset(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_id = get_primary_body_id()
    if current_id then
        if not active_group_presets[current_id] then active_group_presets[current_id] = {} end
        active_group_presets[current_id][current_group_name] = preset_name
        local is_current_global = (current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name]
            and current_config.groups[current_group_name].is_global)
        if is_current_global then
            -- 全局分组：重建整个 overrides
            active_overrides[current_id] = {}
            local saved = active_group_presets[current_id] or {}
            -- 主列表
            local main_preset_name = saved[""]
            if main_preset_name and main_preset_name ~= "" and current_config.presets and current_config.presets[main_preset_name] then
                merge_preset_into_overrides(current_id, current_config.presets[main_preset_name])
            elseif current_config.default_preset and current_config.default_preset ~= "" and current_config.presets then
                local def = current_config.presets[current_config.default_preset]
                if def then merge_preset_into_overrides(current_id, def) end
            end
            -- 普通分组
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if not g_data.is_global then
                        local gp_name = saved[g_name]
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_preset_into_overrides(current_id, g_data.presets[gp_name])
                        elseif g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                            local g_def = g_data.presets[g_data.default_preset]
                            if g_def then merge_preset_into_overrides(current_id, g_def) end
                        end
                    end
                end
            end
            -- 全局分组（当前分组使用新预设，其他使用已保存或默认）
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global then
                        local gp_name = (g_name == current_group_name) and preset_name or saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        else
            -- 普通分组或主列表：直接合并，再叠加全局分组的隐藏覆盖
            merge_preset_into_overrides(current_id, preset_data)
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global and g_data.presets then
                        local saved = active_group_presets[current_id] or {}
                        local gp_name = saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        end
        -- 清除渲染缓存，强制下一帧重新应用
        last_applied_overrides[current_id] = nil
    end
    local primary = get_primary_player()
    if not primary then return end
    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if weapon_parts then
            apply_preset_to_weapon(weapon_parts, active_overrides[current_id], true, current_id)
        end
    else
        apply_preset_to_character(primary, active_overrides[current_id], true)
    end
end

-- ============================================================================
-- 全量重建 overrides（当变身规则激活全局分组时使用）
-- ============================================================================
local function rebuild_overrides_for_transform(body_id, config, activated_targets)
    if not body_id or not config then return end
    active_overrides[body_id] = {}
    local saved = active_group_presets[body_id] or {}

    -- 1. 主列表当前预设
    local main_preset_name = saved[""]
    if main_preset_name and main_preset_name ~= "" and config.presets and config.presets[main_preset_name] then
        merge_preset_into_overrides(body_id, config.presets[main_preset_name])
    elseif config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then merge_preset_into_overrides(body_id, def) end
    end

    -- 2. 非全局分组当前预设
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

    -- 3. 变身规则激活的非全局分组预设（覆盖步骤2）
    if activated_targets and config.groups then
        for g_name, p_name in pairs(activated_targets) do
            if g_name ~= "" and config.groups[g_name] and not config.groups[g_name].is_global then
                if p_name and p_name ~= "" and config.groups[g_name].presets and config.groups[g_name].presets[p_name] then
                    merge_preset_into_overrides(body_id, config.groups[g_name].presets[p_name])
                end
            elseif g_name == "" then
                -- 激活主列表预设
                if p_name and p_name ~= "" and config.presets and config.presets[p_name] then
                    merge_preset_into_overrides(body_id, config.presets[p_name])
                end
            end
        end
    end

    -- 4. 所有全局分组（只锁隐藏），使用 activated_targets 中的预设（如果有），否则用已保存或默认
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

    -- 清除渲染缓存，强制下一帧应用
    last_applied_overrides[body_id] = nil
end

-- ============================================================================
-- 保存预设（全局分组仅存储隐藏材质 false，普通分组存储全部状态）
-- ============================================================================
local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_primary_body_id() end
    if not body_id then return false end
    local primary = get_primary_player()
    if not primary then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = {}
    
    -- 判断当前上下文是否为全局分组
    local is_global_context = (current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global)

    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if weapon_parts then
            for i, part_obj in ipairs(weapon_parts) do
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
                                if is_material_in_current_context(i - 1, mat_name) then
                                    local is_mat_enabled = mesh_component:call("getMaterialsEnable", j)
                                    -- 全局分组：仅存储 false（隐藏），跳过 true
                                    if is_global_context then
                                        if is_mat_enabled == false then
                                            part_data.materials[mat_name] = false
                                        end
                                    else
                                        part_data.materials[mat_name] = is_mat_enabled
                                    end
                                end
                            end
                        end
                        -- 只有存储了材质数据（或主列表/普通分组才保存）
                        if next(part_data.materials) or current_group_name == "" or not is_global_context then
                            new_preset_data[tostring(i - 1)] = part_data
                        end
                    end
                end
            end
        end
    else
        for i = 0, 4 do
            local part_obj = get_character_part(primary, i)
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
                                -- 全局分组：仅存储 false（隐藏），跳过 true
                                if is_global_context then
                                    if is_mat_enabled == false then
                                        part_data.materials[mat_name] = false
                                    end
                                else
                                    part_data.materials[mat_name] = is_mat_enabled
                                end
                            end
                        end
                    end
                    -- 只有存储了材质数据（或主列表/普通分组才保存）
                    if next(part_data.materials) or current_group_name == "" or not is_global_context then
                        new_preset_data[tostring(i)] = part_data
                    end
                end
            end
        end
    end

    -- 如果全局分组且没有任何材质需要隐藏，仍需保存一个空表以标记预设存在
    if is_global_context and not next(new_preset_data) then
        -- 至少保存一个空结构，表示这是一个有效的预设（无隐藏项，即全部显示）
        new_preset_data = { _empty = true }  -- 用特殊标记表示空预设
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
    local primary = get_primary_player()
    if not primary then return false, "No Character" end
    local current_mats = {}
    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if not weapon_parts or #weapon_parts == 0 then return false, "No weapon parts found" end
        local wt = Utils.get_current_weapon_type(primary)
        local main_part_idx = nil
        if wt == Utils.WEAPON_TYPE.DUAL_BLADES then
            main_part_idx = 1
        else
            local main_part_index_map = {
                [Utils.WEAPON_TYPE.GREATSWORD] = 1,
                [Utils.WEAPON_TYPE.SWITCH_AXE] = 1,
                [Utils.WEAPON_TYPE.LONGSWORD] = 2,
                [Utils.WEAPON_TYPE.LIGHT_BOWGUN] = 1,
                [Utils.WEAPON_TYPE.HEAVY_BOWGUN] = 1,
                [Utils.WEAPON_TYPE.HAMMER] = 1,
                [Utils.WEAPON_TYPE.GUNLANCE] = 2,
                [Utils.WEAPON_TYPE.LANCE] = 2,
                [Utils.WEAPON_TYPE.SWORD_SHIELD] = 2,
                [Utils.WEAPON_TYPE.HUNTING_HORN] = 1,
                [Utils.WEAPON_TYPE.CHARGE_BLADE] = 2,
                [Utils.WEAPON_TYPE.INSECT_GLAIVE] = 2,
                [Utils.WEAPON_TYPE.BOW] = 1,
            }
            main_part_idx = main_part_index_map[wt] or 1
        end
        local main_part = weapon_parts[main_part_idx]
        if not main_part then
            for _, p in ipairs(weapon_parts) do if p then main_part = p; break end end
        end
        if not main_part then return false, "No valid weapon part" end
        local mesh = get_mesh_component_recursive(main_part)
        if not mesh then return false, "No mesh on weapon part" end
        local mat_count = mesh:call("get_MaterialNum")
        if not mat_count or mat_count == 0 then return false, "No materials on weapon" end
        for i = 0, mat_count - 1 do
            local name = mesh:call("getMaterialName", i)
            if name then current_mats[name] = true end
        end
    else
        local body_part = get_character_part(primary, 1)
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
                if first_preset then
                    local part_to_check = is_weapon_mode and "0" or "1"
                    local materials_table = first_preset[part_to_check] and first_preset[part_to_check].materials
                    if materials_table then
                        local match = true
                        local match_count = 0
                        for mat_name, _ in pairs(materials_table) do
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
    end
    return false, "No matching preset found"
end

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

-- ========== UI 辅助函数：绘制 Mesh 开关（增强：过滤、全选、反选、全局分组提示） ==========
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
                local function mat_is_operable(mat_name)
                    local flt = mat_filter_text[part_index] or ""
                    if flt ~= "" and not string.find(string.lower(mat_name), string.lower(flt), 1, true) then
                        return false
                    end
                    if is_selection_mode then
                        return get_material_group_owner(part_index, mat_name) == nil
                    else
                        return is_material_in_current_context(part_index, mat_name)
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
                                mesh_component:call("setMaterialsEnable", k, target_val)
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
                                mesh_component:call("setMaterialsEnable", k, nv)
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
                                        local body_id_hint = get_primary_body_id()
                                        local saved = (body_id_hint and active_group_presets[body_id_hint]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname = saved[gname]
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
                                        local body_id_hint2 = get_primary_body_id()
                                        local saved2 = (body_id_hint2 and active_group_presets[body_id_hint2]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname2 = saved2[gname]
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

-- 辅助函数：绘制条件的目标列表（分组下拉框支持全局分组前缀）
local function draw_targets_ui(targets, rule_type, rule_idx, body_id, player_obj)
    for j, target in ipairs(targets) do
        imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)
        local all_groups = { "" }
        local all_groups_display = { T("main_list") or "Main" }
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
                    table.insert(all_groups_display, T("global_group_label") .. " " .. gname)
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

-- 纯函数合并覆盖（用于 TransformManager）
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

-- ========== 过场动画强制显示装备 ==========
local function pre_function(args)
    args[4] = sdk.to_ptr(false)
end
local function post_function(retval)
    return retval
end
if not pcall(function()
    sdk.hook(sdk.find_type_definition("snow.eventcut.EventPlayerLoader"):get_method("<reqStandby>g__set_equip_index|88_0(snow.player.PlayerRequestEquipsData.EquipPack, System.Int32, System.Boolean, snow.eventcut.EventPlayerLoader.<>c__DisplayClass88_0)"), pre_function, post_function)
end) then
    log.debug("[ArmorVariantManager] Failed to hook EventPlayerLoader")
end

-- ========== 运行时配置加载（独立于 UI 的 current_config） ==========
local function get_runtime_config(body_id)
    if not loaded_configs[body_id] then
        local default_config = {
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
            for k, v in pairs(data) do
                default_config[k] = v
            end
        end
        loaded_configs[body_id] = default_config
    end
    return loaded_configs[body_id]
end

-- ========== 帧率解锁与渲染比例 ==========
local app = sdk.get_native_singleton("via.Application")
local set_MaxFps = app and sdk.find_type_definition("via.Application"):get_method("set_MaxFps")
local render = sdk.get_native_singleton("via.render.Renderer")
local set_ImageQualityRate = render and sdk.find_type_definition("via.render.Renderer"):get_method("set_ImageQualityRate")

-- 应用帧率（自动模式：读取游戏选项中的帧率上限）
local function apply_fps_cap()
    if not app or not set_MaxFps then return end
    local stmOptionManager = sdk.get_managed_singleton("snow.StmOptionManager")
    if stmOptionManager then
        local optionContainer = stmOptionManager:get_field("_StmOptionDataContainer")
        if optionContainer then
            local frameRateOption = optionContainer:call("getFrameRateOption") -- 返回 0~7 对应 fps_option 索引
            local fps_option = { 30, 60, 90, 120, 144, 165, 240, 600 }
            local desiredFPS = fps_option[frameRateOption + 1] or 60
            set_MaxFps:call(app, desiredFPS + 0.0)
        end
    end
end

-- 应用渲染比例
local function apply_image_quality()
    if not render or not set_ImageQualityRate then return end
    if global_config.enable_image_quality then
        set_ImageQualityRate:call(render, global_config.image_quality_rate + 0.0)
    end
end

-- 钩子函数：当游戏选项改变或过场动画播放时刷新帧率
local function on_game_option_changed()
    apply_fps_cap()
    apply_image_quality()
end

-- 安全 hook（如果目标函数存在）
local function safe_hook(type_def, method_name, pre_cb, post_cb)
    if type_def and type_def.get_method then
        local method = type_def:get_method(method_name)
        if method then
            sdk.hook(method, pre_cb or function() end, post_cb or function(ret) return ret end)
            return true
        end
    end
    return false
end

-- Hook 游戏选项写入（修改帧率触发）
local stmOptionManagerType = sdk.find_type_definition("snow.StmOptionManager")
if stmOptionManagerType then
    safe_hook(stmOptionManagerType, "writeGraphicOptionOnIniFile", nil, on_game_option_changed)
end

-- Hook 过场动画播放（确保过场中帧率正确）
local uniqueEventManagerType = sdk.find_type_definition("snow.eventcut.UniqueEventManager")
if uniqueEventManagerType then
    safe_hook(uniqueEventManagerType, "playEventCommon", nil, on_game_option_changed)
end

-- Hook 渲染质量变更（确保渲染比例被重新应用）
local renderAppManagerType = sdk.find_type_definition("snow.RenderAppManager")
if renderAppManagerType then
    safe_hook(renderAppManagerType, "setSamplerQuality", nil, apply_image_quality)
end

-- 初始化时立即应用一次
apply_fps_cap()
apply_image_quality()

-- ========== 场景切换时清除所有状态缓存 ==========
local current_flow_state = 0  -- 0=未知, 1=据点, 2=任务中, 其他=其他状态

local questManagerTypeDef = sdk.find_type_definition("snow.QuestManager")
if questManagerTypeDef then
    local onChangedGameStatus = questManagerTypeDef:get_method("onChangedGameStatus")
    if onChangedGameStatus then
        sdk.hook(onChangedGameStatus,
            function(args)
                -- 记录当前游戏状态（1=据点，2=任务中）
                local flow_state = sdk.to_int64(args[3])
                current_flow_state = flow_state

                -- 场景切换时重置所有缓存（但不重置首次刷新标志）
                last_applied_overrides = {}
                last_player_addresses = {}
                part_cache = {}      -- 清空防具部件缓存
                weapon_part_cache = {} -- 清空武器部件缓存
                if TransformManager.clear_cache then TransformManager.clear_cache() end
                current_group_name = ""
                active_overrides = {}
                active_group_presets = {}
                update_preset_names_list()
                update_group_names_list()
            end,
            function(retval) return retval end
        )
    end
end

-- ========== 特殊内嵌式 CG 检测函数 ==========
-- 仅在据点（flow_state == 1）时才会真正检测 CG 状态
local function is_special_cg_active()
    if current_flow_state ~= 1 then
        return false
    end

    local eventManager = sdk.get_managed_singleton("snow.eventcut.EventManager")
    if not eventManager then return false end

    local loadHandlerStack = eventManager:call("get_LoadHandlerStack")
    if not loadHandlerStack then return false end

    for _, handler in ipairs(loadHandlerStack) do
        if handler then
            local uniqueEventManager = handler:call("findUniqueEventManager")
            if uniqueEventManager then
                local eventPlayerList = uniqueEventManager:call("get_EventPlayerList")
                if eventPlayerList then
                    local ok_count, count = pcall(function() return eventPlayerList:call("get_Count") end)
                    if ok_count and type(count) == "number" and count > 0 then
                        local ok_item, player = pcall(function() return eventPlayerList:call("get_Item", 0) end)
                        if ok_item and player then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- ========== 特殊CG刷新间隔与每帧处理玩家数量（可手动调节） ==========
local SPECIAL_CG_UPDATE_INTERVAL = 15      -- 特殊CG每N帧处理一次，默认15帧
local SPECIAL_CG_PLAYERS_PER_FRAME = 2     -- 每次处理的玩家数量，默认2个

-- ========== 正常游玩刷新间隔（可手动调节） ==========
local NORMAL_UPDATE_INTERVAL = 10           -- 正常游玩每N帧处理一次，默认10帧

-- ========== 每帧更新 ==========
local last_frame_time = 0
local frame_interval = 1/30
local global_frame_counter = 0  -- 全局帧计数器，用于降频

-- 特殊内嵌式 CG 状态缓存
local last_is_special_cg = nil
-- 特殊CG玩家轮询索引
local special_cg_next_index = 1

-- 首次刷新标志（启动后只执行一次）
local first_apply_done = false

-- 确保强制展开节点标志存在（如果尚未定义，则初始化）
if force_open_presets_node == nil then
    force_open_presets_node = false
end

-- ========== 玩家部件缓存（防具） ==========
local part_cache = {}  -- key: player_addr, value: { [part_index] = part_obj }

-- 缓存版 get_character_part
local function get_cached_character_part(character, part_index)
    if not character then return nil end
    local player_addr = tostring(character)
    local cache_entry = part_cache[player_addr]
    if cache_entry and cache_entry[part_index] then
        return cache_entry[part_index]
    end
    -- 缓存缺失，调用原始函数获取
    local part_obj = get_character_part(character, part_index)
    if part_obj then
        if not cache_entry then
            cache_entry = {}
            part_cache[player_addr] = cache_entry
        end
        cache_entry[part_index] = part_obj
    end
    return part_obj
end

-- ========== 玩家部件缓存（武器） ==========
local weapon_part_cache = {}  -- key: player_addr, value: weapon_parts table

-- 缓存版获取武器部件列表
local function get_cached_weapon_parts(player_obj)
    if not player_obj then return nil end
    local player_addr = tostring(player_obj)
    local cached = weapon_part_cache[player_addr]
    if cached then
        -- 验证缓存的部件是否仍然有效（简单检查第一个部件是否 still managed）
        if #cached > 0 and sdk.is_managed_object(cached[1]) then
            return cached
        else
            -- 如果部件无效，清除缓存
            weapon_part_cache[player_addr] = nil
        end
    end
    -- 缓存缺失或无效，调用原始函数获取
    local weapon_parts = Utils.get_current_weapon_parts(player_obj)
    if weapon_parts and #weapon_parts > 0 then
        weapon_part_cache[player_addr] = weapon_parts
    end
    return weapon_parts
end

-- ========== 清除缓存函数 ==========
-- 清除特定玩家的所有缓存（防具 + 武器）
local function clear_player_cache(player_addr)
    if player_addr then
        if part_cache[player_addr] then
            part_cache[player_addr] = nil
        end
        if weapon_part_cache[player_addr] then
            weapon_part_cache[player_addr] = nil
        end
    end
end

-- ========== 运行时循环 ==========
re.on_frame(function()
    local now = os.clock()
    if now - last_frame_time > frame_interval then
        refresh_player_list()
        last_frame_time = now
    end

    -- 帧计数器递增
    global_frame_counter = global_frame_counter + 1
    if global_frame_counter > 1000000 then
        global_frame_counter = 1
    end

    -- 检测特殊内嵌式 CG 状态变化
    local current_special_cg = is_special_cg_active()
    if current_special_cg ~= last_is_special_cg then
        last_applied_overrides = {}
        last_player_addresses = {}
        part_cache = {}
        weapon_part_cache = {}
        if TransformManager.clear_cache then TransformManager.clear_cache() end
        current_group_name = ""
        active_overrides = {}
        active_group_presets = {}
        update_preset_names_list()
        update_group_names_list()
        if not current_special_cg then
            special_cg_frame_counter = 0
            special_cg_next_index = 1  -- 重置轮询索引
        end
        last_is_special_cg = current_special_cg
    end
    g_is_special_cg = current_special_cg

    -- ====================================================================
    -- 确定要处理的玩家列表
    -- 特殊CG时处理所有玩家（事件角色），否则仅处理本地玩家（若不存在则回退到所有玩家）
    -- ====================================================================
    local local_player = get_primary_player()
    local players_to_process
    if current_special_cg then
        players_to_process = player_list
    else
        if local_player then
            players_to_process = { local_player }
        else
            players_to_process = player_list
        end
    end

    -- ====================================================================
    -- 首次刷新（仅针对本地玩家，且只执行一次）
    -- 模拟面板展开操作：调用 load_body_config 强制重新加载配置
    -- 该操作不受降频影响，以确保启动时立即生效
    -- ====================================================================
    if local_player and not first_apply_done then
        local armor_id = get_character_body_id(local_player)
        if armor_id then
            -- 强制重新加载配置（从磁盘读取，模拟面板展开）
            load_body_config(armor_id)
            -- 应用当前 UI 选中的预设
            local current_preset_name = preset_names_list[selected_preset_index]
            if current_preset_name then
                apply_preset(current_preset_name)
            end
            -- 强制触发一次规则评估，确保当前状态正确
            local armor_config = get_runtime_config(armor_id)
            if armor_config and armor_config.enable_transform then
                local char_addr = tostring(local_player)
                local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                    char_addr, "armor_" .. armor_id, armor_config, local_player, active_overrides[armor_id] or {}, merge_overrides
                )
                if not active_group_presets[armor_id] then active_group_presets[armor_id] = {} end
                if activated_targets then
                    for g_name, p_name in pairs(activated_targets) do
                        active_group_presets[armor_id][g_name] = p_name
                    end
                end
                if changed then
                    active_overrides[armor_id] = new_overrides
                    apply_preset_to_character(local_player, new_overrides, true)
                else
                    apply_preset_to_character(local_player, new_overrides, true)
                end
            end
        end
        first_apply_done = true
    end

    -- ====================================================================
    -- 特殊CG降频与轮询处理
    -- ====================================================================
    if current_special_cg then
        -- 仅当达到刷新间隔时才处理
        if global_frame_counter % SPECIAL_CG_UPDATE_INTERVAL == 0 then
            local player_count = #players_to_process
            if player_count > 0 then
                -- 确保索引有效
                if special_cg_next_index > player_count then
                    special_cg_next_index = 1
                end
                local start_idx = special_cg_next_index
                local end_idx = math.min(start_idx + SPECIAL_CG_PLAYERS_PER_FRAME - 1, player_count)
                for i = start_idx, end_idx do
                    local player_obj = players_to_process[i]
                    if player_obj and sdk.is_managed_object(player_obj) then
                        -- 处理该玩家（防具和武器）
                        -- 防具处理
                        local armor_id = get_character_body_id(player_obj)
                        if armor_id then
                            local player_addr = tostring(player_obj)
                            if last_player_addresses[armor_id] and last_player_addresses[armor_id] ~= player_addr then
                                local old_addr = last_player_addresses[armor_id]
                                clear_player_cache(old_addr)
                                last_applied_overrides[armor_id] = nil
                                active_overrides[armor_id] = nil
                                loaded_configs[armor_id] = nil
                                active_group_presets[armor_id] = nil
                            end
                            last_player_addresses[armor_id] = player_addr

                            local armor_config = get_runtime_config(armor_id)

                            -- 特殊CG轻量级应用：非本地玩家跳过规则评估
                            if player_obj ~= local_player then
                                if not active_overrides[armor_id] then
                                    apply_all_defaults(armor_id)
                                end
                                apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                            else
                                -- 本地玩家完整处理
                                if not active_overrides[armor_id] then
                                    apply_all_defaults(armor_id)
                                end
                                if armor_config and armor_config.enable_transform then
                                    local char_addr = tostring(player_obj)
                                    local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                        char_addr, "armor_" .. armor_id, armor_config, player_obj, active_overrides[armor_id] or {}, merge_overrides
                                    )
                                    if not active_group_presets[armor_id] then active_group_presets[armor_id] = {} end
                                    if activated_targets then
                                        for g_name, p_name in pairs(activated_targets) do
                                            active_group_presets[armor_id][g_name] = p_name
                                        end
                                    end
                                    local has_global_target = false
                                    if armor_config.groups then
                                        for g_name, g_data in pairs(armor_config.groups) do
                                            if g_data.is_global then
                                                if activated_targets and activated_targets[g_name] then
                                                    active_group_presets[armor_id][g_name] = activated_targets[g_name]
                                                    has_global_target = true
                                                elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                    active_group_presets[armor_id][g_name] = g_data.default_preset or ""
                                                    has_global_target = true
                                                end
                                            end
                                        end
                                    end
                                    if changed then
                                        if has_global_target then
                                            rebuild_overrides_for_transform(armor_id, armor_config, activated_targets)
                                            apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                                        else
                                            active_overrides[armor_id] = new_overrides
                                            apply_preset_to_character(player_obj, new_overrides, true)
                                        end
                                    else
                                        if has_global_target then
                                            apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                                        else
                                            apply_preset_to_character(player_obj, new_overrides, true)
                                        end
                                    end
                                else
                                    if active_overrides[armor_id] then
                                        apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                                    end
                                end
                            end
                        end

                        -- 武器处理（使用缓存）
                        local weapon_part_name = get_weapon_attack_part_name(player_obj)
                        if weapon_part_name then
                            local weapon_id = weapon_part_name
                            local player_addr = tostring(player_obj)
                            if last_player_addresses[weapon_id] and last_player_addresses[weapon_id] ~= player_addr then
                                -- 清除武器缓存（已由 clear_player_cache 处理，但保险起见）
                                clear_player_cache(player_addr)
                                last_applied_overrides[weapon_id] = nil
                                active_overrides[weapon_id] = nil
                                loaded_configs[weapon_id] = nil
                                active_group_presets[weapon_id] = nil
                            end
                            last_player_addresses[weapon_id] = player_addr

                            local weapon_config = get_runtime_config(weapon_id)

                            if player_obj ~= local_player then
                                if not active_overrides[weapon_id] then
                                    apply_all_defaults(weapon_id)
                                end
                                local weapon_parts = get_cached_weapon_parts(player_obj)
                                if weapon_parts then
                                    apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                                end
                            else
                                if not active_overrides[weapon_id] then
                                    apply_all_defaults(weapon_id)
                                end
                                local weapon_parts = get_cached_weapon_parts(player_obj)
                                if weapon_parts then
                                    if weapon_config and weapon_config.enable_transform then
                                        local char_addr = tostring(player_obj)
                                        local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                            char_addr, "weapon_" .. weapon_id, weapon_config, player_obj, active_overrides[weapon_id] or {}, merge_overrides
                                        )
                                        if not active_group_presets[weapon_id] then active_group_presets[weapon_id] = {} end
                                        if activated_targets then
                                            for g_name, p_name in pairs(activated_targets) do
                                                active_group_presets[weapon_id][g_name] = p_name
                                            end
                                        end
                                        local has_global_target = false
                                        if weapon_config.groups then
                                            for g_name, g_data in pairs(weapon_config.groups) do
                                                if g_data.is_global then
                                                    if activated_targets and activated_targets[g_name] then
                                                        active_group_presets[weapon_id][g_name] = activated_targets[g_name]
                                                        has_global_target = true
                                                    elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                        active_group_presets[weapon_id][g_name] = g_data.default_preset or ""
                                                        has_global_target = true
                                                    end
                                                end
                                            end
                                        end
                                        if changed then
                                            if has_global_target then
                                                rebuild_overrides_for_transform(weapon_id, weapon_config, activated_targets)
                                                apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                                            else
                                                active_overrides[weapon_id] = new_overrides
                                                apply_preset_to_weapon(weapon_parts, new_overrides, true, weapon_id)
                                            end
                                        else
                                            if has_global_target then
                                                apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                                            else
                                                apply_preset_to_weapon(weapon_parts, new_overrides, true, weapon_id)
                                            end
                                        end
                                    else
                                        if active_overrides[weapon_id] then
                                            apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                -- 更新轮询索引
                special_cg_next_index = end_idx + 1
                if special_cg_next_index > player_count then
                    special_cg_next_index = 1
                end
            end
        end
        -- 特殊CG处理完成，跳过非CG逻辑（避免重复处理）
        goto skip_non_cg_processing
    end

    -- ====================================================================
    -- 正常游玩（非特殊CG）：每 N 帧处理一次
    -- ====================================================================
    if global_frame_counter % NORMAL_UPDATE_INTERVAL == 0 then
        for _, player_obj in ipairs(players_to_process) do
            if not (player_obj and sdk.is_managed_object(player_obj)) then
                goto continue_player_non_cg
            end

            -- ============================================================
            -- 防具处理（非CG）
            -- ============================================================
            local armor_id = get_character_body_id(player_obj)
            if armor_id then
                local player_addr = tostring(player_obj)
                if last_player_addresses[armor_id] and last_player_addresses[armor_id] ~= player_addr then
                    local old_addr = last_player_addresses[armor_id]
                    clear_player_cache(old_addr)
                    last_applied_overrides[armor_id] = nil
                    active_overrides[armor_id] = nil
                    loaded_configs[armor_id] = nil
                    active_group_presets[armor_id] = nil
                end
                last_player_addresses[armor_id] = player_addr

                local armor_config = get_runtime_config(armor_id)
                if not active_overrides[armor_id] then
                    apply_all_defaults(armor_id)
                end

                if armor_config and armor_config.enable_transform then
                    local char_addr = tostring(player_obj)
                    local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                        char_addr, "armor_" .. armor_id, armor_config, player_obj, active_overrides[armor_id] or {}, merge_overrides
                    )
                    if not active_group_presets[armor_id] then active_group_presets[armor_id] = {} end
                    if activated_targets then
                        for g_name, p_name in pairs(activated_targets) do
                            active_group_presets[armor_id][g_name] = p_name
                        end
                    end

                    local has_global_target = false
                    if armor_config.groups then
                        for g_name, g_data in pairs(armor_config.groups) do
                            if g_data.is_global then
                                if activated_targets and activated_targets[g_name] then
                                    active_group_presets[armor_id][g_name] = activated_targets[g_name]
                                    has_global_target = true
                                elseif all_targeted_groups and all_targeted_groups[g_name] then
                                    active_group_presets[armor_id][g_name] = g_data.default_preset or ""
                                    has_global_target = true
                                end
                            end
                        end
                    end

                    if changed then
                        if has_global_target then
                            rebuild_overrides_for_transform(armor_id, armor_config, activated_targets)
                            apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                        else
                            active_overrides[armor_id] = new_overrides
                            apply_preset_to_character(player_obj, new_overrides, true)
                        end
                    else
                        if has_global_target then
                            apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                        else
                            apply_preset_to_character(player_obj, new_overrides, true)
                        end
                    end
                else
                    if active_overrides[armor_id] then
                        apply_preset_to_character(player_obj, active_overrides[armor_id], true)
                    end
                end
            end

            -- ============================================================
            -- 武器处理（非CG，使用缓存）
            -- ============================================================
            local weapon_part_name = get_weapon_attack_part_name(player_obj)
            if weapon_part_name then
                local weapon_id = weapon_part_name
                local player_addr = tostring(player_obj)
                if last_player_addresses[weapon_id] and last_player_addresses[weapon_id] ~= player_addr then
                    clear_player_cache(player_addr)
                    last_applied_overrides[weapon_id] = nil
                    active_overrides[weapon_id] = nil
                    loaded_configs[weapon_id] = nil
                    active_group_presets[weapon_id] = nil
                end
                last_player_addresses[weapon_id] = player_addr

                local weapon_config = get_runtime_config(weapon_id)
                if not active_overrides[weapon_id] then
                    apply_all_defaults(weapon_id)
                end

                local weapon_parts = get_cached_weapon_parts(player_obj)
                if weapon_parts then
                    if weapon_config and weapon_config.enable_transform then
                        local char_addr = tostring(player_obj)
                        local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                            char_addr, "weapon_" .. weapon_id, weapon_config, player_obj, active_overrides[weapon_id] or {}, merge_overrides
                        )
                        if not active_group_presets[weapon_id] then active_group_presets[weapon_id] = {} end
                        if activated_targets then
                            for g_name, p_name in pairs(activated_targets) do
                                active_group_presets[weapon_id][g_name] = p_name
                            end
                        end

                        local has_global_target = false
                        if weapon_config.groups then
                            for g_name, g_data in pairs(weapon_config.groups) do
                                if g_data.is_global then
                                    if activated_targets and activated_targets[g_name] then
                                        active_group_presets[weapon_id][g_name] = activated_targets[g_name]
                                        has_global_target = true
                                    elseif all_targeted_groups and all_targeted_groups[g_name] then
                                        active_group_presets[weapon_id][g_name] = g_data.default_preset or ""
                                        has_global_target = true
                                    end
                                end
                            end
                        end

                        if changed then
                            if has_global_target then
                                rebuild_overrides_for_transform(weapon_id, weapon_config, activated_targets)
                                apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                            else
                                active_overrides[weapon_id] = new_overrides
                                apply_preset_to_weapon(weapon_parts, new_overrides, true, weapon_id)
                            end
                        else
                            if has_global_target then
                                apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                            else
                                apply_preset_to_weapon(weapon_parts, new_overrides, true, weapon_id)
                            end
                        end
                    else
                        if active_overrides[weapon_id] then
                            apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id)
                        end
                    end
                end
            end

            ::continue_player_non_cg::
        end
    end

    ::skip_non_cg_processing::
end)

-- ========== UI 绘制（使用主玩家） ==========
local current_config_body_id = nil

re.on_draw_ui(function()
    if imgui.tree_node(T("mod_name")) then
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()
        local status, err = pcall(function()
            local primary = get_primary_player()
            if primary then
                local body_id = get_primary_body_id()
                if body_id then
                    if current_config_body_id ~= body_id then
                        local config = loaded_configs[body_id]
                        if config then
                            for k, v in pairs(config) do
                                current_config[k] = deep_copy_table(v)
                            end
                            current_config_body_id = body_id
                            update_preset_names_list()
                            update_group_names_list()
                        else
                            load_body_config(body_id)
                            current_config_body_id = body_id
                        end
                    end

                    -- 模式切换
                    local armor_mode_text = T("armor_mode") or "Armor Variant"
                    local weapon_mode_text = T("weapon_mode") or "Weapon Variant"
                    local changed_armor, new_armor = imgui.checkbox(armor_mode_text, not is_weapon_mode)
                    if changed_armor and new_armor then
                        if is_weapon_mode ~= false then
                            is_weapon_mode = false
                            last_body_id = nil
                            last_weapon_type = nil
                            refresh_player_list()
                            local new_body_id = get_primary_body_id()
                            if new_body_id then
                                active_overrides[new_body_id] = nil
                                loaded_configs[new_body_id] = nil
                                load_body_config(new_body_id)
                                current_config_body_id = new_body_id
                            end
                            update_preset_names_list()
                            update_group_names_list()
                        end
                    end
                    imgui.same_line()
                    local changed_weapon, new_weapon = imgui.checkbox(weapon_mode_text, is_weapon_mode)
                    if changed_weapon and new_weapon then
                        if is_weapon_mode ~= true then
                            is_weapon_mode = true
                            last_body_id = nil
                            last_weapon_type = nil
                            refresh_player_list()
                            local new_body_id = get_primary_body_id()
                            if new_body_id then
                                active_overrides[new_body_id] = nil
                                loaded_configs[new_body_id] = nil
                                load_body_config(new_body_id)
                                current_config_body_id = new_body_id
                            end
                            update_preset_names_list()
                            update_group_names_list()
                        end
                    end
                    imgui.separator()

                    -- 预设管理区域
                    if force_open_presets_node then
                        imgui.set_next_item_open(true)
                        force_open_presets_node = false
                    end
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                        if config_restored[body_id] and not config_restore_handled[body_id] then
                            imgui.text_colored(T("config_restored_warning") or "Your local preset has been changed. Restore from backup?", 0xFF00CCFF)
                            if imgui.button(T("restore_from_backup") or "Restore My Changes") then
                                config_restore_handled[body_id] = true
                                restore_config_from_backup(body_id)
                            end
                            imgui.same_line()
                            if imgui.button(T("dismiss") or "Dismiss") then
                                config_restore_handled[body_id] = true
                                config_restored[body_id] = nil
                            end
                            imgui.separator()
                        end
                        
                        local full_group_list = {T("main_list")}
                        for _, gname in ipairs(group_names_list) do
                            table.insert(full_group_list, gname)
                        end
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
                                else
                                    imgui.same_line()
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
                                    force_open_presets_node = true
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
                                        force_open_presets_node = true
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

                    -- 排序界面
                    if sort_mode then
                        imgui.separator()
                        local sort_title = (sort_mode == "group") and (T("sort") .. " - " .. T("group")) or (T("sort") .. " - " .. T("preset"))
                        imgui.text_colored(sort_title, 0xFF00FFFF)
                        imgui.spacing()
                        if #sort_temp_list == 0 then
                            imgui.text_colored(T("no_items_to_sort") or "No items to sort.", 0xFF808080)
                        else
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

                    -- ========== 变身管理区域 ==========
                    if imgui.tree_node(T("transform_manager")) then
                        local enable_transform = current_config.enable_transform
                        local changed_enable, new_enable = imgui.checkbox(T("enable_transform"), enable_transform)
                        if changed_enable then
                            current_config.enable_transform = new_enable
                            if new_enable then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local weapon_parts = get_cached_weapon_parts(primary)
                                    if weapon_parts then
                                        apply_preset_to_weapon(weapon_parts, new_overrides, true, body_id)
                                    end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            else
                                apply_all_defaults(body_id)
                                if active_overrides[body_id] then
                                    if is_weapon_mode then
                                        local weapon_parts = get_cached_weapon_parts(primary)
                                        if weapon_parts then
                                            apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                                        end
                                    else
                                        apply_preset_to_character(primary, active_overrides[body_id], true)
                                    end
                                end
                            end
                            save_current_config_to_file(body_id)
                        end
                        imgui.separator()
                        if current_config.enable_transform then
                            local current_state_str = TransformManager.get_current_state_display(current_config, primary)
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
                                    T("condition_weapon"), T("condition_scroll"), T("condition_monster_hp"),
                                    T("condition_longsword"), T("condition_dual_blades"), T("condition_switch_axe"),
                                    T("condition_charge_axe"), T("condition_greatsword_level"),
                                    T("condition_hammer"), T("condition_bow")
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

                                -- 武器条件
                                if current_config.transform_type == "weapon" then
                                    for i, rule in ipairs(current_config.weapon_transform_rules) do
                                        imgui.push_id("weapon_rule_" .. i)
                                        imgui.text(rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn"))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "weapon", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 红蓝书 (scroll)
                                elseif current_config.transform_type == "scroll" then
                                    for i, rule in ipairs(current_config.scroll_transform_rules) do
                                        imgui.push_id("scroll_rule_" .. i)
                                        imgui.text(rule.state == "red" and T("scroll_red") or T("scroll_blue"))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "scroll", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 怪物血量 (monster_hp)
                                elseif current_config.transform_type == "monster_hp" then
                                    local curHP = TransformManager.get_current_raw_state(current_config, primary)
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
                                        draw_targets_ui(rule.targets, "monster_hp", i, body_id, primary)
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
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 太刀气刃等级 (longsword)
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
                                        draw_targets_ui(rule.targets, "longsword", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 双刀鬼人状态 (dual_blades)
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
                                        draw_targets_ui(rule.targets, "dual_blades", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 斩斧模式 (switch_axe)
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
                                        draw_targets_ui(rule.targets, "switch_axe", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 盾斧强化状态 (charge_axe)
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
                                        draw_targets_ui(rule.targets, "charge_axe", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 大剑蓄力等级 (greatsword_level)
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
                                        draw_targets_ui(rule.targets, "greatsword_level", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 大锤蓄力等级 (hammer)
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
                                        draw_targets_ui(rule.targets, "hammer", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 弓箭蓄力等级 (bow)
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
                                        draw_targets_ui(rule.targets, "bow", i, body_id, primary)
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
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
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
                                    imgui.tree_pop()
                                end
                            end
                        end
                        imgui.tree_pop()
                    end

                    -- 部件列表（防具部件顺序调整）
                    if is_weapon_mode then
                        if imgui.tree_node(T("weapon_parts") or "Weapon Parts") then
                            local weapon_parts = get_cached_weapon_parts(primary)
                            local weapon_type = Utils.get_current_weapon_type(primary)
                            if weapon_parts and #weapon_parts > 0 then
                                for idx, part_obj in ipairs(weapon_parts) do
                                    if part_obj and sdk.is_managed_object(part_obj) then
                                        local mesh_comp = get_mesh_component_recursive(part_obj)
                                        if mesh_comp then
                                            local mesh_game_obj = mesh_comp:call("get_GameObject")
                                            local obj_name = mesh_game_obj:call("get_Name")
                                            local part_name = Utils.get_weapon_part_name(weapon_type, idx - 1)
                                            draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, idx - 1)
                                        else
                                            local obj_name = part_obj:call("get_Name")
                                            imgui.text_colored(string.format("Part %d [%s] (No Mesh)", idx - 1, obj_name), 0xFF808080)
                                        end
                                    else
                                        imgui.text_colored(string.format("Part %d (Missing)", idx - 1), 0xFF808080)
                                    end
                                end
                            else
                                imgui.text_colored(T("weapon_not_equipped") or "No weapon equipped", 0xFF808080)
                            end
                            imgui.tree_pop()
                        end
                    else
                        local armor_parts = { [0]=T("helm"), [1]=T("body"), [2]=T("arm"), [3]=T("waist"), [4]=T("leg") }
                        if imgui.tree_node(T("armor_parts")) then
                            -- 自定义顺序：手臂(2), 身体(1), 头部(0), 腿部(4), 腰部(3)
                            local armor_order = {2, 1, 0, 4, 3}
                            for _, idx in ipairs(armor_order) do
                                local part_obj = get_cached_character_part(primary, idx)  -- 使用缓存版本
                                local part_name = armor_parts[idx]
                                if part_obj then
                                    local mesh_comp = get_mesh_component_recursive(part_obj)
                                    if mesh_comp then
                                        local mesh_game_obj = mesh_comp:call("get_GameObject")
                                        local obj_name = mesh_game_obj:call("get_Name")
                                        draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, idx)
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

                        -- 渲染比例设置
                        imgui.separator()
                        imgui.text(T("image_quality") or "Image Quality")
                        local changed_iq_enable, new_iq_enable = imgui.checkbox(T("enable_image_quality") or "Enable Custom Image Quality", global_config.enable_image_quality)
                        if changed_iq_enable then
                            global_config.enable_image_quality = new_iq_enable
                            save_global_settings()
                            apply_image_quality()
                        end
                        if global_config.enable_image_quality then
                            local current_rate = global_config.image_quality_rate
                            local display_percent = math.floor(current_rate * 100 + 0.5)
                            local changed_rate, new_rate = imgui.slider_float(T("image_quality_rate") or "Image Quality (%)", current_rate, 0.1, 4.0)
                            if changed_rate then
                                global_config.image_quality_rate = new_rate
                                save_global_settings()
                                apply_image_quality()
                            end
                            imgui.same_line()
                            imgui.text(string.format("(%d%%)", math.floor(global_config.image_quality_rate * 100)))
                        end

                        imgui.tree_pop()
                    end
                else
                    if is_weapon_mode then
                        imgui.text_colored(T("weapon_not_equipped") or "No weapon detected", 0xFF0000FF)
                    else
                        imgui.text_colored(T("no_body_part"), 0xFF0000FF)
                    end
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