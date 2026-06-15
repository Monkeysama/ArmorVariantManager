local mod_name = "ArmorVariantManager"
-- 开发中遵守
-- 版本号-开发状态-开发状态标识
local version = "3.3.0-beta-001"
local author = "MK,Moon,AZUSA"

-- =============================================================================
-- 多语言与全局配置系统
-- =============================================================================

-- 全局配置路径
local global_config_path = "ArmorVariantManager/GlobalSettings.json"

-- 默认全局配置
local global_config = {
    language = "zh", -- 默认语言: zh (中文), en (英文)
    scan_interval = 0.5, -- 全量扫描间隔 (秒)
    body_id_ttl = 1.0, -- Body ID 缓存有效期 (秒)，默认缩短以加速换装检测
    scanner_batch_size = 200 -- 每帧扫描的对象数量
}

-- 本地化字典 (从外部模块加载)
local Localization = require("ArmorVariantManager_Core.Localization")
local TransformManager = require("ArmorVariantManager_Core.TransformManager")

-- 获取本地化字符串
local function T(key)
    if not key then return "nil" end
    local lang = global_config.language or "en"
    if not Localization[lang] then lang = "en" end
    return Localization[lang][key] or tostring(key)
end

-- 加载全局配置
local function load_global_settings()
    local loaded = json.load_file(global_config_path)
    if loaded then
        if loaded.language then global_config.language = loaded.language end
        if loaded.scan_interval then global_config.scan_interval = loaded.scan_interval end
        if loaded.body_id_ttl then global_config.body_id_ttl = loaded.body_id_ttl end
        if loaded.scanner_batch_size then global_config.scanner_batch_size = loaded.scanner_batch_size end
    end
end

-- 保存全局配置
local function save_global_settings()
    json.dump_file(global_config_path, global_config)
end

-- 初始化加载
load_global_settings()

-- =============================================================================

-- 缓存常用的类型定义，提高性能
local type_player_manager = nil
local type_mesh = nil

-- 性能优化：缓存反射方法 (Method Cache)
local method_cache = {
    -- via.Component
    Component_get_GameObject = sdk.find_type_definition("via.Component"):get_method("get_GameObject"),
    -- via.GameObject
    GameObject_get_Name = sdk.find_type_definition("via.GameObject"):get_method("get_Name"),
    GameObject_getComponent = sdk.find_type_definition("via.GameObject"):get_method("getComponent(System.Type)"),
    -- via.Scene
    Scene_findComponents = sdk.find_type_definition("via.Scene"):get_method("findComponents(System.Type)")
}

-- 性能优化：缓存常用类型 (Type Cache)
local type_cache = {
    via_transform = sdk.typeof("via.Transform"),
    app_character = sdk.typeof("app.Character"),
    app_hunter_character = sdk.typeof("app.HunterCharacter")
}

-- 状态变量
local show_window = true
local last_body_id = nil
local body_id_cache = {} -- Key: Character Address, Value: { id: string, last_check: number }
-- BODY_ID_CACHE_TTL 已移至全局配置 global_config.body_id_ttl
local loaded_configs = {} -- 缓存所有 Body ID 的配置 { [body_id] = config_table }
local temp_applied_presets = {} -- 记录当前临时应用的预设 (BodyID -> PresetName)
local active_overrides = {} -- 记录当前生效的配置状态 (BodyID -> { [part_index] = { mesh_enabled=..., materials={...} } })
-- 记录各分组当前选中的预设名 (BodyID -> { [""] = "主列表预设名", ["分组名"] = "预设名" })
-- 用于全局分组切换时全量重算，确保其他分组的当前预设也一起被应用
local active_group_presets = {}

-- 记录配置是否被外部还原 (BodyID -> true)
-- 检测原理：插件在玩家保存时会同时写主配置和备份(backup/)，两者此刻内容一致；
-- mod 重装只会还原主配置文件而不会动备份文件，因此加载时若发现"备份存在且与主配置不一致"，
-- 即可判定主配置被 mod 管理器还原成了作者版本，从而提示玩家一键恢复。
local config_restored = {}
-- 记录玩家已对"配置被还原"提示做出处理（恢复或忽略），用于点击后立即隐藏横幅。
-- 会话级标记：重启游戏后清空，下次仍能正常检测提示。
local config_restore_handled = {}

-- 当前 Body 的配置数据结构 (用于 UI 编辑):
-- {
--   default_preset = "PresetName",
--   presets = {
--     ["PresetName"] = { ... part_data ... },
--     ...
--   }
-- }
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

-- 部位索引映射表 (用于日志和材质分组预览)
local PART_INDEX_TO_NAME = {
    [0] = "helm",
    [1] = "body",
    [2] = "arm",
    [3] = "waist",
    [4] = "leg",
    [5] = "slinger"
}

-- UI 状态变量
local new_preset_name = ""
local selected_preset_index = 1
local preset_names_list = {}
local auto_find_log = "" -- 用于显示自动查找的调试信息
local test_hp_input = "100" -- 用于测试生命值的输入框

-- 分组管理状态变量
local current_group_name = "" -- 当前选中的分组名称，空字符串表示主列表
local selected_group_index = 1 -- 分组下拉框选中的索引
local group_names_list = {} -- 分组名称列表
local new_group_name = "" -- 新建分组的名称输入
local new_group_is_global = false -- 新建分组时是否勾选了全局分组
-- 材质细粒度选择状态
local is_selection_mode = false -- 是否处于材质勾选模式
local pending_material_selections = {} -- 临时存储勾选的材质 { [part_idx_str] = { [mat_name] = true } }
-- 材质过滤输入框状态 { [part_index] = "filter_text" }
local mat_filter_text = {}
-- 排序面板状态
local sort_mode = nil -- nil: 不显示, "group": 分组排序, "preset": 预设排序
local sort_temp_list = {} -- 排序临时列表（可自由上下移动）
local sort_selected_index = 1 -- 排序面板中当前选中的项目索引

-- 辅助函数
-- 辅助函数：获取类型定义 (Lazy Load)
local function get_type(name)
    return sdk.find_type_definition(name)
end

-- 辅助函数：深拷贝表
local function deep_copy_table(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deep_copy_table(orig_key)] = deep_copy_table(orig_value)
        end
        setmetatable(copy, deep_copy_table(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- 辅助函数：获取玩家管理器单例
local function get_player_manager()
    return sdk.get_managed_singleton("app.PlayerManager")
end

-- 武器 ID 缓存
local weapon_id_cache = {}

local function find_weapons_in_hierarchy(transform, depth, results)
    if depth > 5 then return end
    local child = transform:call("get_Child")
    while child do
        local child_obj = child:call("get_GameObject")
        if child_obj then
            local name = child_obj:call("get_Name")
            -- 如果节点名叫 Wp_Parent 或 WpSub_Parent，则视为当前激活的主武器部件
            -- 排除包含 Reserve 的节点，过滤掉副武器
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
            
            -- 直接回退匹配 it 格式（仅当该节点本身是武器模型时，且我们未在父节点层级捕获）
            if name and string.match(name, "^it%d%d%d%d_%d%d%d%d") then
                local already_added = false
                for _, v in ipairs(results) do
                    if v.name == name then already_added = true; break end
                end
                if not already_added then
                    table.insert(results, { name = name, obj = child_obj })
                end
            end
            
            -- 递归查找子节点。如果当前节点是ReserveParent，就停止向下递归，从而屏蔽副武器
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
        -- 在收集的结果中，优先过滤出那些父节点不是直接匹配回退机制的（或者更简单，因为我们已经截断了 Reserve 的遍历，所以这里面的就是当前激活的武器部件）
        -- 使用第一个武器的名称去掉 _0 或 _1 作为基础 ID
        local base_id = string.gsub(results[1].name, "_%d$", "")
        local objs = {}
        for _, v in ipairs(results) do table.insert(objs, v.obj) end
        weapon_id_cache[cache_key] = { id = base_id, objs = objs, last_check = current_time }
        return base_id, objs
    end

    weapon_id_cache[cache_key] = { id = nil, objs = nil, last_check = current_time }
    return nil, nil
end

-- =============================================================================
-- 辅助函数：获取指定 Character 的 Body ID (Name)
-- =============================================================================
local function get_character_body_id(character)
    if not character then return nil end
    if not sdk.is_managed_object(character) then return nil end

    -- 0. 检查缓存
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

    -- 2. 回退机制，用于主菜单等没有 app.Character 组件的情况，作为 via.Transform 遍历子节点查找 Body 对象
    if not result_id then
        local game_obj_status, game_obj = pcall(function() return character:call("get_GameObject") end)
        if game_obj_status and game_obj then
            local transform = game_obj:call("get_Transform")
            if transform then
                local child = transform:call("get_Child")
                -- 收集所有候选 Body ID
                local candidates = {}
                local has_non_ch00 = false
                while child do
                    local child_obj = child:call("get_GameObject")
                    if child_obj then
                        local name = child_obj:call("get_Name")
                        -- 匹配标准 Body ID 格式: chXX_XXX_XXX (例如 ch00_000_0000)
                        if name and string.match(name, "^ch%d%d_%d%d%d_%d%d%d%d?$") then
                            if not string.find(name, "^ch00") then has_non_ch00 = true end
                            table.insert(candidates, name)
                        end
                    end
                    child = child:call("get_Next")
                end
                -- 如果存在非 ch00 的 Body ID，优先返回第一个非 ch00 的 ID
                -- 优先级：Body (结尾为2) > Helm (结尾为1) > Others
                if #candidates > 0 then
                    -- 1
                    for _, name in ipairs(candidates) do
                        if not string.find(name, "^ch00") and string.match(name, "2$") then
                            result_id = name; break
                        end
                    end
                    if not result_id then
                        -- 2
                        for _, name in ipairs(candidates) do
                            if not string.find(name, "^ch00") and string.match(name, "3$") then
                                result_id = name; break
                            end
                        end
                    end
                    if not result_id then
                        -- 3
                        for _, name in ipairs(candidates) do
                            if not string.find(name, "^ch00") and string.match(name, "1$") then
                                result_id = name; break
                            end
                        end
                    end
                    -- 3. 保险机制
                    if not result_id then
                        if has_non_ch00 then
                            for _, name in ipairs(candidates) do
                                -- 如果不是 ch00 (素体)，标记为 true
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
                    -- 增加去重/有效性检查：必须包含至少一个子节点（通常是 Mesh 或骨骼）
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
-- 辅助函数：获取场景中所有有效的玩家角色
-- 引入缓存机制以防止列表闪烁 (仅用于主菜单)
local character_cache = {} -- Key: GameObject Address, Value: { char: userdata, last_seen: number }
local CACHE_TTL_BUFFER = 10.0 -- 缓存过期时间的缓冲值 (秒)，设置较大值以防止列表闪烁
local last_valid_local_player = nil -- 记录上一个有效的本地玩家角色
local last_valid_local_player_time = 0 -- 记录上一个有效角色的时间戳
local PLAYER_PERSISTENCE_TIME = 1.0 -- UI 层面的角色保持宽限期 (秒)

-- 扫描器状态 (用于分帧处理)
local scanner = {
    state = "IDLE", -- IDLE, PROCESSING
    transforms = nil, -- 待处理的 Transforms 列表
    count = 0,
    index = 1,
    -- batch_size 已移至全局配置 global_config.scanner_batch_size
    last_scan_time = 0
}

local function update_cache_entry(char)
    if not char then return end
    -- 尝试获取 GameObject 的地址作为唯一标识
    local game_obj = nil
    if method_cache.Component_get_GameObject then
        local ok, obj = pcall(method_cache.Component_get_GameObject.call, method_cache.Component_get_GameObject, char)
        if ok then game_obj = obj end
    else
        game_obj = char:call("get_GameObject")
    end
    if not game_obj then return end
    local key = tostring(game_obj)
    -- 过滤掉不绘制的对象 (隐藏对象)
    local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
    if draw_status and is_draw == false then return end
    -- 尝试获取 Body ID 来进一步验证
    local body_id = get_character_body_id(char)
    if not body_id then return end
    if not string.find(body_id, "^ch03") then return end
    character_cache[key] = { char = char, last_seen = os.clock() }
end

-- 分帧扫描器逻辑
local function tick_scanner()
    local current_time = os.clock()
    local scan_interval = global_config.scan_interval or 2.0
    if scanner.state == "IDLE" then
        if (current_time - scanner.last_scan_time > scan_interval) then
            -- 清理过期 Body ID 缓存
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
                -- 1. 扫描 app.Character (通常数量较少，一次性处理)
                if type_cache.app_character then
                    local components = scene:call("findComponents(System.Type)", type_cache.app_character:get_runtime_type())
                    if components then
                        local list = components:get_elements()
                        for _, char in ipairs(list) do update_cache_entry(char) end
                    end
                end
                -- 2. 开始 via.Transform 扫描 (分帧处理)
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
        -- 处理当前批次
        local batch_size = global_config.scanner_batch_size or 100
        local limit = scanner.index + batch_size - 1
        if limit > scanner.count then limit = scanner.count end
        for i = scanner.index, limit do
            -- 防御性编程：使用 pcall 包裹对象的获取和有效性检查
            -- 防止因对象跨帧销毁导致的 sol: runtime error
            local safe_get_transform = function()
                local t = scanner.transforms[i]
                return (t and sdk.is_managed_object(t)) and t or nil
            end
            local status, transform = pcall(safe_get_transform)
            if status and transform then
                -- 极速获取 GameObject
                local ok, game_obj = pcall(method_cache.Component_get_GameObject.call, method_cache.Component_get_GameObject, transform)
                if ok and game_obj and sdk.is_managed_object(game_obj) then
                    -- 极速获取 Name (再次使用 pcall 确保安全)
                    local name_ok, name = pcall(method_cache.GameObject_get_Name.call, method_cache.GameObject_get_Name, game_obj)
                    -- 快速筛选
                    local is_target = false
                    if name_ok and name then
                        -- 检查 "Pl" 前缀 (使用 string.sub 比 find 快)
                        if string.sub(name, 1, 2) == "Pl" then
                            is_target = true
                        else
                            -- 检查特殊名称
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
                        -- 找到目标，进一步获取 Character 组件
                        local char = nil
                        if type_cache.app_character then
                            -- 使用 pcall 包裹 getComponent
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
        -- 检查是否完成
        if scanner.index > scanner.count then
            scanner.state = "IDLE"
            scanner.transforms = nil
            scanner.last_scan_time = os.clock()
        end
    end
end

local function get_all_characters()
    local chars = {}
    local seen_objs = {} -- 用于去重，Key: GameObject Address
    if not type_player_manager then type_player_manager = get_type("app.PlayerManager") end
    local pm = get_player_manager()
    if pm then
        -- 遍历 InstancedPlayer (通常包含所有玩家)
        local count = pm:call("get_InstancedPlayerNum")
        if count then
            for i = 0, count - 1 do
                local player = pm:call("get_InstancedPlayer", i)
                if player then
                    local char = player:call("get_Character")
                    if char and sdk.is_managed_object(char) then
                        local game_obj_ok, game_obj = pcall(function() return char:call("get_GameObject") end)
                        if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                            -- 检查角色是否被游戏原生隐藏 (例如在使用装备箱时)
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
        -- 获取 MasterPlayer (本地玩家)
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
    -- 2. 合并缓存中的结果 (由 scanner 异步更新)
    local current_time = os.clock()
    local scan_interval = global_config.scan_interval or 2.0
    local cache_ttl = scan_interval + CACHE_TTL_BUFFER
    for key, data in pairs(character_cache) do
        -- 增加有效性检查
        local is_valid = false
        if data.char and sdk.is_managed_object(data.char) then
            -- 检查角色是否被游戏原生隐藏
            local game_obj_ok, game_obj = pcall(function() return data.char:call("get_GameObject") end)
            if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                is_valid = not (draw_status and is_draw == false)
            end
        end
        if is_valid and (current_time - data.last_seen <= cache_ttl) then
            -- 如果 PlayerManager 还没包含这个对象，则添加
            if not seen_objs[key] then
                table.insert(chars, data.char)
                seen_objs[key] = true
            end
        -- 如果游戏隐藏了该角色，跳过处理，不应用 mod 的覆盖状态
        else
            -- 注意：被隐藏的对象会因为 is_valid=false 而在这里被直接移除缓存，
            -- 这是符合预期的，因为当它重新显示时 scanner 会重新捕获它。
            character_cache[key] = nil -- 移除过期或无效条目
        end
    end
    return chars
end

-- 辅助函数：获取本地玩家角色 (Character)
local function get_local_player_character()
    local char = nil
    local current_time = os.clock()
    if not type_player_manager then type_player_manager = get_type("app.PlayerManager") end
    local player_manager = get_player_manager()
    if player_manager then
        local master_player = player_manager:call("getMasterPlayer")
        if master_player then char = master_player:call("get_Character") end
    end
    -- 2. 如果 PlayerManager 失败，尝试从缓存的角色列表中获取 (主菜单/过场)
    if not char then
        local all_chars = get_all_characters()
        if #all_chars > 0 then
            -- 优化选择逻辑：如果之前记录的有效角色在列表中，优先保持它，防止跳变
            local found_last = false
            if last_valid_local_player then
                for _, c in ipairs(all_chars) do
                    if c == last_valid_local_player then char = c; found_last = true; break end
                end
            end
            if not found_last then char = all_chars[1] end
        end
    end
    -- 3. 更新或应用宽限期逻辑
    if char then
        -- 只有当对象确实有效时才更新记录
        if sdk.is_managed_object(char) then
            last_valid_local_player = char
            last_valid_local_player_time = current_time
        end
    else
        -- 如果当前没找到角色，但在宽限期内，且上一个角色仍然有效，则返回上一个角色
        if last_valid_local_player and (current_time - last_valid_local_player_time <= PLAYER_PERSISTENCE_TIME) then
            if sdk.is_managed_object(last_valid_local_player) then
                char = last_valid_local_player
            else
                -- 如果对象已失效，立即清除记录
                last_valid_local_player = nil
            end
        end
    end
    return char
end

local is_weapon_mode = false

local function is_weapon_id(id)
    return id and (string.match(id, "^wp%d%d") ~= nil or string.match(id, "^it%d%d%d%d") ~= nil)
end

-- 辅助函数：获取当前本地玩家 Body 的 ID (Name) - 兼容旧接口
local function get_body_id()
    if is_weapon_mode then
        local id, _ = get_character_weapon_id(get_local_player_character())
        return id
    end
    return get_character_body_id(get_local_player_character())
end

-- 辅助函数：获取配置文件路径
local function get_config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end

-- 辅助函数：获取备份文件路径
local function get_backup_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/backup/" .. body_id .. ".json"
end

-- 辅助函数：深度比较两个 table 是否内容一致
-- 用于判断主配置是否被外部还原（与备份不一致即视为被改写）
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

-- =============================================================================
-- 预设和分组 UI 辅助
-- =============================================================================
-- 辅助函数：更新预设名称列表 (用于 UI)
local function update_preset_names_list()
    preset_names_list = {}
    -- 根据当前分组获取对应的预设列表和排序
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
        -- 优先按 order 排序，fallback 按字母排序
        if target_order and #target_order > 0 then
            -- 先按 order 中的顺序添加
            local added = {}
            for _, name in ipairs(target_order) do
                if target_presets[name] then
                    table.insert(preset_names_list, name)
                    added[name] = true
                end
            end
            -- 再添加 order 中没有的（新建但还没排序的）
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
    -- 2. 自动选中当前分组的活跃预设（优先用 active_group_presets，fallback 到默认预设）
    local current_body_id = get_body_id and get_body_id() or nil
    local active_preset_name = ""
    if current_body_id and active_group_presets[current_body_id] then
        active_preset_name = active_group_presets[current_body_id][current_group_name] or ""
    end
    -- 如果 active_group_presets 中没有记录，fallback 到默认预设
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

-- 辅助函数：更新分组名称列表 (用于 UI)
local function update_group_names_list()
    group_names_list = {}
    if current_config.groups then
        -- 优先按 group_order 排序，fallback 按字母排序
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

-- =============================================================================
-- Mesh 和部位相关函数
-- =============================================================================
-- 辅助函数：尝试从 GameObject 及其子节点中获取 Mesh 组件
local function get_mesh_component_recursive(game_obj)
    if not game_obj then return nil end
    if not sdk.is_managed_object(game_obj) then return nil end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return nil end
    end
    -- 1. 检查自身
    local ok_mesh, mesh = pcall(function() return game_obj:call("getComponent(System.Type)", type_mesh:get_runtime_type()) end)
    if ok_mesh and mesh then return mesh end
    -- 2. 检查子节点 (浅层遍历)
    local ok_transform, transform = pcall(function() return game_obj:call("get_Transform") end)
    if ok_transform and transform then
        local ok_child, child = pcall(function() return transform:call("get_Child") end)
        while ok_child and child do
            local ok_child_obj, child_obj = pcall(function() return child:call("get_GameObject") end)
            if ok_child_obj and child_obj then
                local ok_c_mesh, c_mesh = pcall(function() return child_obj:call("getComponent(System.Type)", type_mesh:get_runtime_type()) end)
                if ok_c_mesh and c_mesh then return c_mesh end
            end
            ok_child, child = pcall(function() return child:call("get_Next") end)
        end
    end
    return nil
end

-- 辅助函数：获取角色的指定部位对象 (兼容 Transform 模式)
local function get_character_part(character, part_index)
    if not character then return nil end
    local status, part_obj = pcall(function() return character:call("getParts", part_index) end)
    if status and part_obj then return part_obj end
    -- 2. 回退模式：遍历 Transform 子节点并根据名称后缀匹配
    local game_obj_status, game_obj = pcall(function() return character:call("get_GameObject") end)
    if game_obj_status and game_obj then
        local transform = game_obj:call("get_Transform")
        if transform then
            local parts_map = {} -- Key: part_index, Value: { obj, name }
            local child = transform:call("get_Child")
            while child do
                local child_obj = child:call("get_GameObject")
                if child_obj then
                    local name = child_obj:call("get_Name")
                    -- 只收集标准角色模型 (ch开头)
                    if name and string.find(name, "^ch") then
                        -- 尝试解析后缀数字
                        local suffix_str = string.match(name, "(%d+)$")
                        if suffix_str then
                            local suffix = tonumber(suffix_str)
                            local last_digit = suffix % 10
                            -- 映射规则 (MHWS)
                            -- 1 -> Arm (2)
                            -- 2 -> Body (1)
                            -- 3 -> Helm (0)
                            -- 4 -> Leg (4)
                            -- 5 -> Waist (3)
                            -- 6 -> Slinger (5)
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
                                    -- 优先级逻辑：
                                    -- 1. 如果该槽位为空，直接填入
                                    -- 2. 如果该槽位已有值：
                                    --    a. 如果新值是非 ch00 且旧值是 ch00 -> 替换
                                    --    b. 如果都是非 ch00 或都是 ch00 -> 不替换 (通常第一个找到的有效)
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

-- 辅助函数：检测材质被哪个分组占用（全局组不计入归属，只有普通组才独占材质）
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

-- 辅助函数：检测材质被哪些全局分组的 mask 覆盖（用于 UI 提示）
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

-- 辅助函数：判断材质是否属于当前 UI 上下文 (主列表或当前分组)
local function is_material_in_current_context(part_index, mat_name)
    if current_group_name == "" then
        -- 主列表只管理未被任何普通分组占用的材质
        local owner = get_material_group_owner(part_index, mat_name)
        return owner == nil
    else
        local g_data = current_config.groups and current_config.groups[current_group_name]
        if g_data and g_data.is_global then
            -- 全局分组：用 mask 直接判断是否在该组内
            local s_idx = tostring(part_index)
            return g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] == true
        else
            -- 普通分组：通过归属判定
            local owner = get_material_group_owner(part_index, mat_name)
            return owner == current_group_name
        end
    end
end

-- 辅助函数：判断某材质是否被全局分组的当前预设锁定为隐藏
-- 返回 true 表示被全局隐藏，此时不允许将其显示出来
-- 注意：当前上下文本身就是全局分组时不做限制，允许在其内部自由编辑
local function is_globally_hidden(part_index, mat_name)
    -- 在全局分组上下文内操作时，不施加任何限制
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
            -- 优先用用户当前选中的预设，fallback 到默认预设
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
-- 预设应用函数
-- =============================================================================
-- 用于记录角色部位上次应用时的状态哈希，避免每帧重复应用导致覆盖游戏的原生临时状态
local applied_parts_cache = {} -- Key: char GameObject Address, Value: { [part_index] = state_hash }
local applied_weapon_cache = {} -- Key: char GameObject Address, Value: state_hash

-- 辅助函数：应用指定预设到指定角色的防具
local function apply_preset_to_armor(character, preset_data, ignore_context, force_apply)
    if not character or not preset_data then return end
    -- 增加有效性检查，防止在对象销毁后访问
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
                    -- 1. 应用 Mesh 整体开关
                    if part_data.mesh_enabled ~= nil then
                        local cur_en = mesh_component:call("get_Enabled")
                        if part_data.mesh_enabled == false then
                            if cur_en ~= false then mesh_component:call("set_Enabled", false) end
                        elseif part_data.mesh_enabled == true then
                            if cur_en ~= true then mesh_component:call("set_Enabled", true) end
                        end
                    end
                    -- 2. 应用材质开关
                    if part_data.materials and mat_count > 0 then
                        for j = 0, mat_count - 1 do
                            local mat_name = mesh_component:call("getMaterialName", j)
                            -- 核心逻辑：只应用属于当前显示/操作上下文的材质状态
                            if ignore_context or is_material_in_current_context(i, mat_name) then
                                local mat_enabled = part_data.materials[mat_name]
                                local cur_mat = mesh_component:call("getMaterialsEnable", j)
                                if mat_enabled == false then
                                    if cur_mat ~= false then mesh_component:call("setMaterialsEnable", j, false) end
                                elseif mat_enabled == true then
                                    -- 全局隐藏锁：即使意图是显示，被全局分组锁定的材质强制隐藏
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
end

-- 辅助函数：应用指定预设到指定角色的武器
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
            -- 加上一个安全调用，防止武器对象在这一帧刚刚被销毁
            -- 注意：w_obj 本身已经是 GameObject，所以不能调用 get_GameObject()
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

                        -- 1. 应用 Mesh 整体开关
                         if part_data.mesh_enabled ~= nil then
                             local cur_en = mesh_component:call("get_Enabled")
                             if part_data.mesh_enabled == false then
                                 if cur_en ~= false then mesh_component:call("set_Enabled", false) end
                             elseif part_data.mesh_enabled == true then
                                 if cur_en ~= true then mesh_component:call("set_Enabled", true) end
                             end
                         end
                         -- 2. 应用材质开关
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

-- =============================================================================
-- 分组管理
-- =============================================================================
-- 分组管理核心函数
-- 辅助函数：创建新分组
-- 辅助函数：创建材质级新分组
local function create_new_group(group_name, body_id, is_global)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    -- 0. 检查是否有勾选材质
    local has_selection = false
    for _, v in pairs(pending_material_selections) do
        if next(v) then has_selection = true; break end
    end
    if not has_selection then return false end
    if not current_config.groups then current_config.groups = {} end
    if current_config.groups[group_name] then return false end -- 重名检查
    -- 1. 创建分组结构
    local new_group = {
        mask = deep_copy_table(pending_material_selections),
        presets = {},
        is_global = is_global == true
    }
    -- 2. 只有普通分组才需要从主列表/其他普通分组预设中剥离材质控制权
    -- 全局分组允许 mask 与其他分组重叠，不做剥离
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
    -- 3. 保存新分组并清空选择
    current_config.groups[group_name] = new_group
    -- 维护 group_order：新建分组追加到末尾
    if not current_config.group_order then current_config.group_order = {} end
    table.insert(current_config.group_order, group_name)
    pending_material_selections = {}
    is_selection_mode = false
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

-- 辅助函数：删除分组（将预设归还到主列表）
-- 辅助函数：删除材质级分组并归还控制权
local function delete_group(group_name, body_id)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    if not current_config.groups or not current_config.groups[group_name] then return false end
    -- 归还逻辑：删除分组时直接丢弃分组特有的预设数据
    -- 仅将材质控制权通过清除 mask 的方式归还给主列表（主列表预设中该材质的状态将恢复为默认或通过重新保存来定义）
    -- 删除分组
    current_config.groups[group_name] = nil
    -- 维护 group_order：从数组中移除
    if current_config.group_order then
        for i = #current_config.group_order, 1, -1 do
            if current_config.group_order[i] == group_name then
                table.remove(current_config.group_order, i)
                break
            end
        end
    end
    -- 如果当前在被删除的分组，切换回主列表
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
-- 辅助函数：仅加载配置数据，不更新 UI 状态
local function load_config_data(body_id)
    if not body_id then return nil end
    if loaded_configs[body_id] then
        -- 如果缓存的是加载失败标记，返回 nil（不再重试）
        if loaded_configs[body_id] == "LOAD_FAILED" then return nil end
        return loaded_configs[body_id]
    end
    local path = get_config_path(body_id)
    local loaded_data = json.load_file(path)
    if loaded_data then
        -- 确保结构完整
        if not loaded_data.presets then loaded_data.presets = {} end
        if not loaded_data.default_preset then loaded_data.default_preset = "" end
        if not loaded_data.groups then loaded_data.groups = {} end
        if not loaded_data.group_order then loaded_data.group_order = {} end
        if not loaded_data.preset_order then loaded_data.preset_order = {} end
        -- 确保各分组也有 preset_order
        for _, g_data in pairs(loaded_data.groups) do
            if not g_data.preset_order then g_data.preset_order = {} end
        end
        if not loaded_data.transform_type then loaded_data.transform_type = "hp" end
        if loaded_data.is_parallel == nil then loaded_data.is_parallel = false end
        if not loaded_data.parallel_settings then
            loaded_data.parallel_settings = {
                hp = { enabled = true, priority = 1 },
                weapon = { enabled = false, priority = 2 },
                damage = { enabled = false, priority = 3 },
                spirit = { enabled = false, priority = 4 },
                dual_blades = { enabled = false, priority = 5 },
                switch_axe = { enabled = false, priority = 6 },
                insect_glaive = { enabled = false, priority = 7 },
                charge_blade = { enabled = false, priority = 8 },
                greatsword_type = { enabled = false, priority = 9 },
                greatsword_level = { enabled = false, priority = 10 },
                bow_level = { enabled = false, priority = 11 },
                hammer_level = { enabled = false, priority = 12 }
            }
        else
            if not loaded_data.parallel_settings.damage then loaded_data.parallel_settings.damage = { enabled = false, priority = 3 } end
            if not loaded_data.parallel_settings.weapon then loaded_data.parallel_settings.weapon = { enabled = false, priority = 2 } end
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
                loaded_data.parallel_settings.hammer_level = { enabled = false, priority = 12 }
            end
        end
        
        -- 数据迁移：将原来 HP 中的 trigger_on_damage 迁移到新的 damage 节点
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
        -- 检测主配置是否被外部还原：若备份存在且与主配置的核心内容不一致，
        -- 说明主配置文件被 mod 管理器还原成了作者版本，打上标记供 UI 提示一键恢复。
        -- 注意：必须用原始文件内容比较（而非补全后的 loaded_data），
        -- 因为加载流程会为缺失字段补全默认值，导致"补全后数据 vs 原始备份"产生误差。
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
        -- 写入缓存
        loaded_configs[body_id] = loaded_data
        return loaded_data
    end
    -- 加载失败（文件不存在或为空）：缓存标记，避免每帧重复尝试并产生日志错误
    loaded_configs[body_id] = "LOAD_FAILED"
    return nil
end

-- 辅助函数：将预设数据合并到复合状态表中
local function merge_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
        -- 合并 Mesh 整体开关
        if p_data.mesh_enabled ~= nil then
            overrides[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        -- 合并材质开关
        if p_data.materials then
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                overrides[p_idx].materials[mat_name] = is_enabled
            end
        end
    end
end

-- 辅助函数：返回合并后的新复合状态表（不修改原表）
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

-- Transform Rules Application Logic
-- 辅助函数：将全局分组预设合并进 overrides，只锁隐藏项（true 项跳过，不干预）
-- 全局分组只操作材质级别，不锁定 mesh_enabled（避免整体隐藏整个部件）
-- 注意：全局隐藏项会强制覆盖已有的 true（确保最高优先级）
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
                    -- 强制覆盖：全局隐藏具有最高优先级，无论之前是否为 true
                    overrides[p_idx].materials[mat_name] = false
                end
                -- is_enabled == true 时跳过，不干预普通分组已写入的值
            end
        end
    end
end

-- 辅助函数：应用一个 Body ID 的所有默认预设 (主列表 + 所有分组)
-- 合并顺序：主列表 → 普通分组 → 全局分组（最后）
local function apply_all_defaults(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    -- 彻底重置该 Body 的复合状态
    active_overrides[body_id] = {}
    -- 同步初始化 active_group_presets，使 is_globally_hidden 等函数能找到正确的预设
    if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
    -- 1. 首先合并主列表默认预设
    if config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then
            merge_preset_into_overrides(body_id, def)
            -- 记录主列表当前预设（key 为空字符串）
            if not active_group_presets[body_id][""] or active_group_presets[body_id][""] == "" then
                active_group_presets[body_id][""] = config.default_preset
            end
        end
    end
    -- 2. 合并所有普通分组的默认预设
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
    -- 3. 最后合并所有全局分组的默认预设（只锁隐藏项，强制覆盖）
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

-- 辅助函数：变身规则激活全局分组时的全量重算
-- 合并顺序与 apply_all_defaults 一致（主列表 → 普通分组 → 全局分组），
-- 但使用 active_group_presets 中记录的当前预设（而非默认预设），
-- 并将变身规则激活的非全局分组 targets 也合并进来。
-- 参数 activated_targets: 变身规则激活的 group→preset 映射
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
    -- 2. 普通分组的当前预设
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
    -- 3. 合并变身规则激活的非全局分组 targets（覆盖步骤2的对应分组预设）
    if activated_targets and config.groups then
        for g_name, p_name in pairs(activated_targets) do
            if g_name ~= "" and config.groups[g_name] and not config.groups[g_name].is_global then
                if p_name and p_name ~= "" and config.groups[g_name].presets and config.groups[g_name].presets[p_name] then
                    merge_preset_into_overrides(body_id, config.groups[g_name].presets[p_name])
                end
            elseif g_name == "" then
                -- 变身规则激活了主列表预设
                if p_name and p_name ~= "" and config.presets and config.presets[p_name] then
                    merge_preset_into_overrides(body_id, config.presets[p_name])
                end
            end
        end
    end
    -- 4. 所有全局分组（只锁隐藏项），使用 activated_targets 中的预设（如果有）
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

-- 辅助函数：获取当前分组的预设数据
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

-- 辅助函数：应用指定预设 (兼容旧接口，针对所有玩家)
local function apply_preset(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_body_id = get_body_id()
    if current_body_id then
        -- 记录当前分组的选中预设（用于全局分组全量重算时恢复）
        if not active_group_presets[current_body_id] then active_group_presets[current_body_id] = {} end
        active_group_presets[current_body_id][current_group_name] = preset_name

        -- 判断当前是否为全局分组
        local is_current_global = (current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name]
            and current_config.groups[current_group_name].is_global)

        if is_current_global then
            -- 全局分组预设切换：全量重算（不自动更新 default_preset，只有用户点"设为默认"才更新）
            active_overrides[current_body_id] = {}
            local saved = active_group_presets[current_body_id] or {}
            -- 1. 主列表当前预设
            local main_preset_name = saved[""]
            if main_preset_name and main_preset_name ~= "" and current_config.presets and current_config.presets[main_preset_name] then
                merge_preset_into_overrides(current_body_id, current_config.presets[main_preset_name])
            elseif current_config.default_preset and current_config.default_preset ~= "" and current_config.presets then
                local def = current_config.presets[current_config.default_preset]
                if def then merge_preset_into_overrides(current_body_id, def) end
            end
            -- 2. 普通分组的当前预设
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
            -- 3. 所有全局分组（只锁隐藏项），当前切换的全局组用新 preset_name
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
            -- 普通分组/主列表：增量合并当前预设数据，再叠加全局锁
            merge_preset_into_overrides(current_body_id, preset_data)
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global and g_data.presets then
                        -- 优先用用户当前选中的预设（active_group_presets），fallback 到默认预设
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
                -- 检查变身规则是否激活了全局分组
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

-- 辅助函数：加载指定 Body ID 的配置 (用于 UI 和本地玩家)
local function load_body_config(body_id)
    if not body_id then return false end
    -- 1. 重置当前内存配置，确保切换到新 Body 时不残留旧数据
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

-- 辅助函数：保存配置到文件
local function save_current_config_to_file(body_id)
    if not body_id then return end
    -- 更新缓存
    loaded_configs[body_id] = current_config
    local path = get_config_path(body_id)
    json.dump_file(path, current_config)

    -- 同步写入备份文件：保存时主配置与备份内容一致，
    -- 后续若主配置被 mod 管理器还原，备份仍保留玩家改动，作为恢复来源。
    local backup_path = get_backup_path(body_id)
    if backup_path then
        json.dump_file(backup_path, current_config)
    end
    -- 玩家主动保存视为已是最新状态，清除"被还原"标记
    config_restored[body_id] = nil
    config_restore_handled[body_id] = nil
    -- 清除 active_overrides 缓存，强制下一帧重新合并所有默认预设
    if active_overrides[body_id] then
        active_overrides[body_id] = nil
    end
    
    -- 清除状态机缓存，强制下一帧重新应用最新的预设内容
    if TransformManager.clear_last_state_cache then
        TransformManager.clear_last_state_cache()
    end
end

-- 辅助函数：从备份恢复配置
-- 将 backup/<id>.json 的内容写回主配置文件并刷新内存状态，
-- 用于 mod 重装后一键还原玩家手动调整过的预设。
local function restore_config_from_backup(body_id)
    if not body_id then return false end
    local backup_path = get_backup_path(body_id)
    if not backup_path then return false end
    local backup_data = json.load_file(backup_path)
    if not backup_data then return false end
    -- 用备份覆盖主配置文件
    local path = get_config_path(body_id)
    json.dump_file(path, backup_data)
    -- 清除该 body 的所有内存缓存，强制下一帧重新加载备份内容
    -- 注意：这里不清除 config_restore_handled，由 UI 调用方设置的"已处理"标记需保留，
    -- 否则随后的 load_config_data 重新检测会让横幅再次显示。
    loaded_configs[body_id] = nil
    active_overrides[body_id] = nil
    config_restored[body_id] = nil
    -- 重新加载并刷新 UI
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

-- 辅助函数：捕获当前状态为新预设
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
                    -- 全局分组不保存 mesh_enabled，避免整体隐藏部件
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
                                -- 优先读意图值（active_overrides），避免全局锁导致游戏状态是 false 而丢失用户意图
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
            if part_obj then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    local part_data = {
                        materials = {}
                    }
                    -- 全局分组不保存 mesh_enabled，避免整体隐藏部件
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
                            if is_material_in_current_context(i, mat_name) then
                                -- 优先读意图值（active_overrides），避免全局锁导致游戏状态是 false 而丢失用户意图
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
                    if next(part_data.materials) or current_group_name == "" then
                        new_preset_data[tostring(i)] = part_data
                    end
                end
            end
        end
    end
    -- 保存到当前分组或主列表
    if current_group_name == "" then
        -- 保存到主列表
        if not current_config.presets then current_config.presets = {} end
        -- 维护 preset_order：如果是新预设则追加到末尾
        if not current_config.presets[preset_name] then
            if not current_config.preset_order then current_config.preset_order = {} end
            table.insert(current_config.preset_order, preset_name)
        end
        current_config.presets[preset_name] = new_preset_data
    else
        -- 保存到当前分组
        if not current_config.groups then current_config.groups = {} end
        if not current_config.groups[current_group_name] then
            current_config.groups[current_group_name] = { presets = {}, mask = {} }
        end
        -- 确保 presets 表存在
        if not current_config.groups[current_group_name].presets then
            current_config.groups[current_group_name].presets = {}
        end
        -- 维护分组的 preset_order：如果是新预设则追加到末尾
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

-- 辅助函数：自动查找匹配的预设
local function find_auto_preset(target_body_id)
    if not target_body_id then return false, "No Body ID" end
    -- 1. 获取当前 Body (Part 1) 的材质特征
    local character = get_local_player_character()
    if not character or not sdk.is_managed_object(character) then return false, "No Character" end
    local body_part = get_character_part(character, 1) -- 1 is Body
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
    -- 2. 遍历所有 JSON 文件
    if not fs or not fs.glob then return false, "fs.glob missing" end
    -- 尝试更广泛的搜索路径，包含反斜杠版本
    -- 注意：fs.glob 使用正则表达式，因此必须使用 valid regex syntax
    -- * -> .*
    -- . -> \.
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
        -- 排除自身
        if not string.find(file, target_body_id) then
            -- 路径处理：json.load_file 通常需要相对于 reframework/data 的路径
            -- 如果 file 包含 reframework/data，尝试截取
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
                -- 获取第一个预设
                local first_preset = nil
                for _, preset in pairs(data.presets) do first_preset = preset; break end
                -- 检查 Body (1) 的材质匹配度
                if first_preset and first_preset["1"] and first_preset["1"].materials then
                    local preset_mats = first_preset["1"].materials
                    local match = true
                    local match_count = 0
                    for mat_name, _ in pairs(preset_mats) do
                        if not current_mats[mat_name] then match = false; break end
                        match_count = match_count + 1
                    end
                    if match and match_count > 0 then
                        -- 找到匹配！
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

-- 辅助函数：安全地获取组件并控制可见性
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
    -- 获取 Mesh 组件
    local mesh_component = game_object:call("getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh_component then
        if imgui.tree_node(label) then
            -- 1. 整体 Mesh 开关
            local is_enabled = mesh_component:call("get_Enabled")
            local changed, new_value = imgui.checkbox(T("enable_mesh"), is_enabled)
            if changed then
                mesh_component:call("set_Enabled", new_value)
                -- 更新 active_overrides
                if body_id and part_index then
                    local s_idx = tostring(part_index)
                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                    active_overrides[body_id][s_idx].mesh_enabled = new_value
                end
            end

            -- 2. 遍历材质
            local mat_count = mesh_component:call("get_MaterialNum")
            if mat_count and mat_count > 0 then
                local s_idx = tostring(part_index)

                -- 辅助：判断某材质在当前模式下是否"可操作"（过滤后可见且未被普通分组占用）
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

                -- 全选 / 反选 / 过滤框：与"启用模型"checkbox 同行
                imgui.same_line()
                if imgui.button(T("select_all") .. "##sa_" .. s_idx) then
                    -- 收集所有可操作材质的当前状态
                    local all_on = true
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not (pending_material_selections[s_idx] and pending_material_selections[s_idx][mn]) then
                                    all_on = false; break
                                end
                            else
                                -- 优先用意图值判断全选状态
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
                                -- 全局隐藏锁：意图值正常存储，渲染时应用锁
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
                                    active_overrides[body_id][s_idx].materials[mn] = target_val  -- 存意图值
                                end
                            end
                        end
                    end
                end

                imgui.same_line()

                -- 反选按钮：将可操作材质的当前状态取反
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
                                -- 全局隐藏锁：意图值正常存储，渲染时应用锁
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
                                    active_overrides[body_id][s_idx].materials[mn] = nv  -- 存意图值
                                end
                            end
                        end
                    end
                end

                -- 过滤输入框（与全选/反选同行）
                imgui.same_line()
                imgui.set_next_item_width(140)
                local flt_cur = mat_filter_text[part_index] or ""
                local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                if flt_changed then mat_filter_text[part_index] = flt_val end
                if flt_cur ~= "" then
                    imgui.same_line()
                    if imgui.button("x##fltclr_" .. s_idx) then mat_filter_text[part_index] = "" end
                end

                -- 材质列表
                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")

                -- 材质列表（过滤后显示）
                local filter_str = string.lower(mat_filter_text[part_index] or "")
                for i = 0, mat_count - 1 do
                    local mat_name = mesh_component:call("getMaterialName", i)
                    if mat_name then
                        -- 过滤：名称不含关键字则跳过
                        if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                            local is_mat_enabled = mesh_component:call("getMaterialsEnable", i)
                            local owner = get_material_group_owner(part_index, mat_name)
                            local global_groups = get_material_global_groups(part_index, mat_name)
                            -- A. 分组创建模式
                            if is_selection_mode then
                                local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                                if owner and not new_group_is_global then
                                    -- 普通分组不能选择已被其他普通分组占用的材质
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
                                -- B. 正常管理模式
                                if is_material_in_current_context(part_index, mat_name) then
                                    local mat_label = string.format("[%d] %s", i, mat_name)
                                    -- 优先用 active_overrides 里的意图值显示 checkbox，避免全局锁强制隐藏后 checkbox 跳回未勾选
                                    local intent_val = (active_overrides[body_id]
                                        and active_overrides[body_id][s_idx]
                                        and active_overrides[body_id][s_idx].materials
                                        and active_overrides[body_id][s_idx].materials[mat_name])
                                    local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                    local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                    if mat_changed then
                                        -- 记录用户意图值到 active_overrides（全局锁不影响存储的意图）
                                        if body_id and part_index then
                                            if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                            if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                            if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                            active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                        end
                                        -- 实际渲染时应用全局锁：被全局隐藏的材质始终保持隐藏
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
        -- 如果没有 Mesh 组件，显示禁用状态的文本
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end

-- Debug 状态
local show_debug_window = false

-- =============================================================================
-- =============================================================================

-- 辅助函数：在 UI 中绘制条件的目标列表（捕获外部的 body_id 和 current_config）
local function draw_targets_ui(targets, rule_type, rule_idx)
    local body_id = last_body_id
    for j, target in ipairs(targets) do
        imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)

        -- 分组选择
        -- 准备分组下拉框的数据（按 group_order 排序）
        local all_groups = { "" }
        local all_groups_display = { T("main_list") or "Main" }
        local global_label_t = T("global_group_label") or "[Global]"
        if current_config.groups then
            -- 按 group_order 排序，fallback 字母序
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
            target.preset = "" -- 分组改变时重置预设
            save_current_config_to_file(body_id)
        end

        imgui.same_line()

        -- 预设选择（按 preset_order 排序）
        local target_presets = {}
        if target.group == "" or target.group == nil then
            if current_config.presets then
                -- 按 preset_order 排序，fallback 字母序
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
                -- 按分组的 preset_order 排序，fallback 字母序
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

-- =============================================================================
-- 每一帧执行
-- =============================================================================
-- temp_applied_presets 已在文件头部定义
re.on_frame(function()
    -- 0. 执行分帧扫描器
    tick_scanner()

    -- 1. 维护本地玩家 UI 状态
    local local_body_id = get_body_id()
    if local_body_id then
        if local_body_id ~= last_body_id then
            last_body_id = local_body_id
            -- 如果该 body_id 已有 active_overrides（说明之前已加载过），只更新 UI 不重置状态
            if active_overrides[local_body_id] then
                -- 仅更新 UI 配置和列表
                local data = load_config_data(local_body_id)
                if data then
                    current_config = data
                end
                update_group_names_list()
                update_preset_names_list()
            else
                -- 全新加载：重置状态并应用默认预设
                temp_applied_presets[local_body_id] = nil
                load_body_config(local_body_id)
            end
        end
    end
    -- 当 local_body_id 为 nil 时不重置 last_body_id，避免模型短暂重建期间丢失状态

    -- 遍历所有角色并应用规则引擎
    -- 2. 遍历所有玩家并应用配置
    local all_chars = get_all_characters()
    for _, char in ipairs(all_chars) do
        -- 处理防具
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
                    -- 同步变身规则激活的分组预设到 active_group_presets
                    -- 只对变身规则中实际涉及的全局分组做回退，未配置规则的全局分组保持用户手动选择
                    if not active_group_presets[char_body_id] then active_group_presets[char_body_id] = {} end
                    local has_global_target = false
                    if config.groups then
                        for g_name, g_data in pairs(config.groups) do
                            if g_data.is_global then
                                if activated_targets and activated_targets[g_name] then
                                    active_group_presets[char_body_id][g_name] = activated_targets[g_name]
                                    has_global_target = true
                                elseif all_targeted_groups and all_targeted_groups[g_name] then
                                    -- 该全局分组被变身规则覆盖，但当前无规则激活，回退为默认预设
                                    active_group_presets[char_body_id][g_name] = g_data.default_preset or ""
                                    has_global_target = true
                                end
                                -- 未被任何变身规则 target 的全局分组：保持 active_group_presets 不变
                            end
                        end
                    end
                    if has_global_target then
                        -- 全局分组被变身规则激活：全量重算，确保正确的合并顺序
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
                        -- 同步变身规则激活的分组预设到 active_group_presets
                        -- 只对变身规则中实际涉及的全局分组做回退，未配置规则的全局分组保持用户手动选择
                        if not active_group_presets[char_body_id] then active_group_presets[char_body_id] = {} end
                        -- 检测 activated_targets 中是否有全局分组
                        local has_global_target = false
                        if config.groups then
                            for g_name, g_data in pairs(config.groups) do
                                if g_data.is_global then
                                    if activated_targets and activated_targets[g_name] then
                                        active_group_presets[char_body_id][g_name] = activated_targets[g_name]
                                        has_global_target = true
                                    elseif all_targeted_groups and all_targeted_groups[g_name] then
                                        -- 该全局分组被变身规则覆盖，但当前无规则激活，回退为默认预设
                                        active_group_presets[char_body_id][g_name] = g_data.default_preset or ""
                                        has_global_target = true
                                    end
                                    -- 未被任何变身规则 target 的全局分组：保持 active_group_presets 不变
                                end
                            end
                        end
                        
                        if changed then
                            if has_global_target then
                                -- 全局分组被变身规则激活：全量重算 active_overrides，
                                -- 确保全局分组只锁隐藏、不覆盖非全局分组的隐藏状态
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

        -- 处理武器
        local char_weapon_id, w_objs = get_character_weapon_id(char)
        if char_weapon_id and w_objs then
            local config = load_config_data(char_weapon_id)
            -- 只有成功加载到 config 才进行后续处理，避免新武器暂无配置时报错
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

-- =============================================================================
-- UI 绘制
-- =============================================================================
-- UI 绘制回调
re.on_draw_ui(function()
    if imgui.tree_node(T("mod_name")) then
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()

        -- 仅在调试模式下打印错误，避免刷屏
        -- 调试模式开关 (默认隐藏，需要时取消注释)
        -- local changed, val = imgui.checkbox(T("debug_mode") or "Debug Mode", show_debug_window)
        -- if changed then show_debug_window = val end
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

        -- 使用 pcall 包裹核心绘制逻辑，防止 Lua 错误导致 ImGui 状态异常
        local status, err = pcall(function()
            -- 模式切换 Tabs (使用 Radio Button 替代 Tab Bar，因为 REFramework 某些版本不支持 begin_tab_bar)
            local armor_mode_text = T("armor_mode") or "Armor Variant"
            local weapon_mode_text = T("weapon_mode") or "Weapon Variant"
            
            -- 使用 Checkbox 模拟切换，因为部分版本也没有 radio_button
            local changed_armor, new_armor = imgui.checkbox(armor_mode_text, not is_weapon_mode)
            if changed_armor and new_armor then
                if is_weapon_mode ~= false then
                    is_weapon_mode = false
                    last_body_id = nil
                    current_group_name = ""
                    -- 切换到防具模式时清除防具ID缓存，确保立即重新扫描
                    body_id_cache = {}
                end
            end
            
            imgui.same_line()
            local changed_weapon, new_weapon = imgui.checkbox(weapon_mode_text, is_weapon_mode)
            if changed_weapon and new_weapon then
                if is_weapon_mode ~= true then
                    is_weapon_mode = true
                    last_body_id = nil
                    current_group_name = ""
                    -- 切换到武器模式时清除武器ID缓存，确保立即重新扫描
                    weapon_id_cache = {}
                end
            end
            imgui.separator()

            local character = get_local_player_character()
            if character and sdk.is_managed_object(character) then
                local body_id = get_body_id()
                -- imgui.text(T("current_body_id") .. tostring(body_id))
                if body_id then
                    -- ========== 预设管理区域 ==========
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                        -- 使用 pcall 包裹整个预设管理区域，防止 UI 脚本报错导致 ImGui Mismatch 崩溃
                        local ui_status, ui_err = pcall(function()
                            -- 配置被还原提示横幅：检测到主配置被 mod 重装覆盖时，提供一键恢复入口
                            -- config_restore_handled 用于点击恢复/忽略后立即隐藏横幅，避免恢复流程重新检测导致复现
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
                            -- 1. 准备数据
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

                            -- 2. 预设与分组选择 (左右分区布局 - 已对调位置)
                            -- 使用分行对齐策略，确保文字标签在同一水平线上
                            if imgui.begin_table("PresetsLayout", 2, 512) then
                                imgui.table_setup_column("PresetArea", 2048, 1.0)
                                imgui.table_setup_column("GroupArea", 2048, 1.0)
                                -- 第一行：标题对齐
                                imgui.table_next_row()
                                imgui.table_next_column()
                                imgui.text(T("preset") .. ":")
                                imgui.table_next_column()
                                imgui.text(T("group") .. ":")

                                -- 第二行：下拉框对齐
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

                                -- 第三行：操作按钮与新增 UI 对齐
                                imgui.table_next_row()
                                imgui.table_next_column()
                                -- 预设操作
                                if #preset_names_list > 0 then
                                    local current_preset_name = preset_names_list[selected_preset_index]
                                    local ctx_default = (current_group_name == "") and current_config.default_preset or
                                                       (current_config.groups[current_group_name] and current_config.groups[current_group_name].default_preset)
                                    if imgui.button(T("delete_preset")) then
                                        if current_group_name == "" then
                                            current_config.presets[current_preset_name] = nil
                                            if current_config.default_preset == current_preset_name then current_config.default_preset = "" end
                                            -- 维护 preset_order
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
                                                -- 维护分组 preset_order
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
                                    -- 预设状态提示
                                    imgui.same_line()
                                    if ctx_default == current_preset_name then
                                        imgui.text_colored(T("selected_and_default"), 0xFF00FF00)
                                    else
                                        imgui.text_colored(T("selected_not_default"), 0xFF00CCFF)
                                    end
                                    -- 排序按钮
                                    imgui.same_line()
                                    if imgui.button(T("sort") .. "##p_sort") then
                                        sort_mode = "preset"
                                        -- 初始化排序临时列表
                                        sort_temp_list = {}
                                        for _, pn in ipairs(preset_names_list) do
                                            table.insert(sort_temp_list, pn)
                                        end
                                        sort_selected_index = selected_preset_index
                                    end
                                end

                                -- 新增预设 UI (在预设列)
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
                                -- 覆盖当前预设按钮
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
                                -- 分组操作
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
                                    -- 分组排序按钮（有分组时才显示）
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
                                    -- 选择模式活跃状态
                                    imgui.text_colored(T("selection_mode") .. " ", 0xFF00FFFF)
                                    imgui.text_colored(T("selection_mode_desc") .. " ", 0xFF00FFFF)
                                    local cg, gtext = imgui.input_text(T("name") .. "##gn", new_group_name)
                                    if cg then new_group_name = gtext end
                                    -- 全局分组勾选框
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

                            -- 分组材质预览
                            -- 4. 分组预览 (保持在下方)
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

                            -- C. 自动查找 (仅在没有任何预设数据时显示)
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

                        -- 排序面板（在 pcall 外渲染，独立区域）
                        if sort_mode then
                            imgui.separator()
                            local sort_title = (sort_mode == "group") and (T("sort") .. " - " .. T("group")) or (T("sort") .. " - " .. T("preset"))
                            imgui.text_colored(sort_title, 0xFF00FFFF)
                            imgui.spacing()
                            -- 提示文字
                            if sort_selected_index and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                imgui.text_colored(T("sort_hint_selected") .. ": " .. sort_temp_list[sort_selected_index], 0xFFFFFF80)
                            else
                                imgui.text_colored(T("sort_hint_click"), 0xFF808080)
                            end
                            imgui.spacing()
                            for si, sname in ipairs(sort_temp_list) do
                                -- 上移按钮
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
                                -- 下移按钮
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
                                -- 名称按钮（点击选中，选中项高亮）
                                if si == sort_selected_index then
                                    imgui.push_style_color(21, 0xFF00AAFF) -- ImGuiCol_Button 高亮
                                end
                                if imgui.button(tostring(si) .. ". " .. sname .. "##sn_" .. si) then
                                    sort_selected_index = si
                                end
                                if si == sort_selected_index then
                                    imgui.pop_style_color(1)
                                end
                                -- 插入按钮：将选中项移动到第si行的位置
                                if sort_selected_index and sort_selected_index ~= si and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                    imgui.same_line()
                                    if imgui.button(T("sort_insert_here") .. "##si_" .. si) then
                                        local item = table.remove(sort_temp_list, sort_selected_index)
                                        table.insert(sort_temp_list, si, item)
                                        sort_selected_index = si
                                    end
                                end
                            end
                            -- 底部按钮
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

                    -- ========== 变身管理区域 ==========
                    if imgui.tree_node(T("transform_manager") .. " (" .. body_id .. ")") then
                        local inner_status, inner_err = pcall(function()
                            -- 模块状态提示（选中条件或启用了该条件时才提示）
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
                                -- 当前生命值百分比展示 (调试用)
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
                                    
                                    -- 缩进显示 Conditions
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

                            -- 受击规则
                            local show_damage = (not current_config.is_parallel and current_config.transform_type == "damage") or
                                           (current_config.is_parallel and current_config.parallel_settings.damage and current_config.parallel_settings.damage.enabled)
                            if show_damage then
                                imgui.text(T("condition_damage"))
                                imgui.separator()
                                if not current_config.damage_transform_rules then
                                    current_config.damage_transform_rules = { { duration = 5, targets = {} } }
                                end
                                local dmg_rule = current_config.damage_transform_rules[1]
                                
                                -- 剩余时间和测试按钮
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

                    -- ========== 防具/武器部位列表 ==========
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
                        -- 1. 遍历防具部位 (Helm, Body, Arm, Waist, Leg)
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
                                    -- 尝试获取 Mesh 组件 (支持递归查找)
                                    local mesh_comp = get_mesh_component_recursive(part_obj)
                                    if mesh_comp then
                                        -- 使用拥有 Mesh 的 GameObject 进行绘制
                                        local mesh_game_obj = mesh_comp:call("get_GameObject")
                                        local obj_name = mesh_game_obj:call("get_Name")
                                        draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, i)
                                    else
                                        -- 虽然找到了部位对象，但没有 Mesh
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

                    -- ========== 语言切换 ==========
                    if imgui.tree_node(T("language")) then
                        -- 使用 Checkbox 模拟 RadioButton (因为 radio_button 可能不可用)
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
                        -- 1. 扫描间隔
                        local changed_si, val_si = imgui.slider_float(T("scan_interval"), global_config.scan_interval, 0.1, 5.0)
                        if changed_si then
                            global_config.scan_interval = val_si
                            save_global_settings()
                        end
                        -- 2. 刷新间隔 (Body ID TTL)
                        local changed_ttl, val_ttl = imgui.slider_float(T("refresh_interval"), global_config.body_id_ttl, 0.1, 10.0)
                        if changed_ttl then
                            global_config.body_id_ttl = val_ttl
                            save_global_settings()
                        end
                        -- 3. 分帧扫描步频
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
        -- 如果发生错误，显示错误信息
        if not status then
            imgui.text_colored(T("lua_error") .. tostring(err), 0xFF0000FF)
        end
        imgui.tree_pop()
    end
end)