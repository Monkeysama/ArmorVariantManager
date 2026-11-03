local RuntimeGuard = require("ArmorVariantManager_Core.Games.Wilds.RuntimeGuard")
local Actors = {}

-- 预览模型与场景玩家是独立对象，不能只从 PlayerManager 查找。
-- 使用精确根节点白名单，避免把穿戴相同装备的 NPC 或脸部对象当作玩家。
local preview_character_names = {
    SaveSelect_HunterXX = true, SaveSelect_HunterXY = true,
    GuildCard_HunterXX = true, GuildCard_HunterXY = true,
    Lobby_HunterXX = true, Lobby_HunterXY = true,
    CharaMake_HunterXX = true, CharaMake_HunterXY = true
}

Actors.preview_names = preview_character_names

-- 扫描器只管理游戏对象；配置与界面状态由场景清理回调的所有者维护。
function Actors.new(global_config, scene_object, equipment, meshes, on_reset)
    -- 性能优化：缓存反射方法 (Method Cache)
    local method_cache = {
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

    local runtime_guard
    local transform_player_characters = {}
    local get_character_body_id = equipment.body_id
    local safe_get_game_object = scene_object.game_object
    local clear_dead_object_marks = scene_object.clear
    local function get_player_manager()
        return sdk.get_managed_singleton("app.PlayerManager")
    end

    -- =============================================================================
    -- 角色扫描与缓存
    -- =============================================================================
    -- 派生自游戏对象的缓存必须先声明，后面的清理函数才能访问同一份局部表。
    -- 辅助函数：获取场景中所有有效的玩家角色
    -- 引入缓存机制以防止列表闪烁 (仅用于主菜单)
    local character_cache = {} -- Key: GameObject Address, Value: { char: userdata, last_seen: number }
    local CACHE_TTL_BUFFER = 10.0 -- 缓存过期时间的缓冲值 (秒)，设置较大值以防止列表闪烁
    -- 场景纪元：用 via.Scene 原生指针的变化判定"换场景"。
    -- 旧场景销毁后原生对象立即失效，但上面的缓存 TTL 仍会让这些引用多存活十多秒，
    -- 期间每次访问都会抛出 InvalidOperationException 并写入大量错误日志。
    -- 因此场景一变就整体作废缓存，而不是等 TTL 自然过期。
    local last_valid_local_player = nil -- 记录上一个有效的本地玩家角色
    local last_valid_local_player_time = 0 -- 记录上一个有效角色的时间戳
    local PLAYER_PERSISTENCE_TIME = 1.0 -- UI 层面的角色保持宽限期 (秒)

    -- 扫描器状态 (用于分帧处理)
    local scanner = {
        state = "IDLE", -- IDLE, PROCESSING
        transforms = nil, -- 待处理的 Transforms 列表
        count = 0,
        index = 1,
        scene_key = "",
        generation = 0,
        force_rescan = false,
        -- batch_size 已移至全局配置 global_config.scanner_batch_size
        last_scan_time = 0
    }

    -- 换场景后作废"派生自游戏对象"的状态。不触碰纯 JSON 配置缓存：
    -- loaded_configs 是文件配置，active_overrides / active_group_presets / current_config
    -- 等是用户编辑状态，都没有原生对象引用，清空反而会造成预设显示丢失。
    local function flush_scene_reset(reset_dead_marks)
        scanner.state = "IDLE"
        scanner.transforms = nil
        scanner.count = 0
        scanner.index = 1
        scanner.scene_key = ""
        scanner.force_rescan = true
        character_cache = {}
        equipment.clear()
        meshes.clear()
        last_valid_local_player = nil
        last_valid_local_player_time = 0
        transform_player_characters = {}
        -- 换场景后旧的"已销毁"标记不再适用，清空以免误伤新场景复用的地址。
        if reset_dead_marks ~= false then clear_dead_object_marks() end
        on_reset()
    end

    runtime_guard = RuntimeGuard.new(flush_scene_reset)

    -- 扫描失败只丢弃枚举快照，按正常间隔重试；对象缓存与 UI 只在确认换场景后清理。
    local function discard_unreliable_scanner_snapshot()
        scanner.state = "IDLE"
        scanner.transforms = nil
        scanner.count, scanner.index, scanner.scene_key = 0, 1, ""
        scanner.force_rescan = false
        scanner.last_scan_time = os.clock()
    end

    -- 更新单个角色的缓存。返回值 game_obj 为 nil 表示该包装对象已随场景销毁：
    -- 调用方据此跳过后续访问，避免对死对象反复 invoke 而后台刷错误日志。
    local function update_cache_entry(char)
        if not char then return end
        -- 安全获取 GameObject 的地址作为唯一标识
        local game_obj = safe_get_game_object(char, "update_cache_entry")
        if not game_obj then return end
        local key = tostring(game_obj)
        -- 过滤掉不绘制的对象 (隐藏对象)
        local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
        if draw_status and is_draw == false then return end
        -- 尝试获取 Body ID 来进一步验证
        local body_id = get_character_body_id(char)
        if not body_id then return end
        local name = game_obj:call("get_Name")
        if not string.find(body_id, "^ch03") and not preview_character_names[name] then return end
        character_cache[key] = {
            char = char, last_seen = os.clock(),
            is_editor_preview = name == "CharaMake_HunterXX" or name == "CharaMake_HunterXY"
        }
    end

    -- 单个对象的生命周期不代表整个场景失效；异常由批次逐项捕获，继续扫描其他有效对象。
    local function scan_transform_entry(transform)
        if not transform or not sdk.is_managed_object(transform) then return false end
        local game_obj = safe_get_game_object(transform, "scanner_transform")
        if not game_obj then return false end
        local name = method_cache.GameObject_get_Name:call(game_obj)
        if not name or (string.sub(name, 1, 2) ~= "Pl" and not preview_character_names[name]) then return true end
        local char
        if type_cache.app_character then
            char = method_cache.GameObject_getComponent:call(game_obj, type_cache.app_character)
        end
        if not char and type_cache.app_hunter_character then
            char = method_cache.GameObject_getComponent:call(game_obj, type_cache.app_hunter_character)
        end
        update_cache_entry(char or transform)
        return true
    end

    -- 批次绑定Scene原生地址与代际；生命周期变化后不继续读取跨帧保存的旧Transform。
    local function scan_scene_batch()
        local current_time = os.clock()
        local scan_interval = global_config.scan_interval or 2.0
        if scanner.state == "IDLE" then
            if scanner.force_rescan or (current_time - scanner.last_scan_time > scan_interval) then
                scanner.force_rescan = false
                -- 清理过期 Body ID 缓存
                equipment.prune(current_time)
                local scene, scene_key = runtime_guard:get_scene()
                if scene then
                    if not runtime_guard:accept_scene(scene_key) then return false end
                    -- 1. 扫描 app.Character (通常数量较少，一次性处理)
                    if type_cache.app_character then
                        local components = scene:call("findComponents(System.Type)", type_cache.app_character:get_runtime_type())
                        if components then
                            local list = components:get_elements()
                            for _, char in ipairs(list) do pcall(update_cache_entry, char) end
                        end
                    end
                    -- 2. 开始 via.Transform 扫描 (分帧处理)
                    if method_cache.Scene_findComponents and type_cache.via_transform then
                        local transforms = method_cache.Scene_findComponents:call(scene, type_cache.via_transform)
                        if transforms then
                            scanner.transforms = transforms:get_elements()
                            scanner.count = #scanner.transforms
                            scanner.index = 1
                            scanner.scene_key = scene_key
                            scanner.generation = runtime_guard.generation
                            scanner.state = "PROCESSING"
                        else
                            scanner.last_scan_time = current_time
                        end
                    else
                        scanner.last_scan_time = current_time
                    end
                else
                    scanner.last_scan_time = current_time
                    scanner.force_rescan = true
                    runtime_guard:block_frame()
                    return false
                end
            end
        elseif scanner.state == "PROCESSING" then
            local _, scene_key = runtime_guard:get_scene()
            if scanner.generation ~= runtime_guard.generation or scene_key == ""
                or scanner.scene_key ~= scene_key then
                runtime_guard:accept_scene(scene_key)
                discard_unreliable_scanner_snapshot()
                scanner.force_rescan = true
                runtime_guard:block_frame()
                return false
            end
            -- 跳过个别已销毁对象；一批内多次失败时停止枚举以限制原生异常数量，但不暂停 UI。
            local batch_size = global_config.scanner_batch_size or 100
            local limit = scanner.index + batch_size - 1
            if limit > scanner.count then limit = scanner.count end
            local failures = 0
            for i = scanner.index, limit do
                local ok, valid = pcall(scan_transform_entry, scanner.transforms[i])
                if not ok or not valid then
                    failures = failures + 1
                    if failures >= 8 then
                        discard_unreliable_scanner_snapshot()
                        return true
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
        return true
    end

    -- 枚举异常不等于换场景；仅场景地址变化或无法读取场景时隔离本帧。
    local function tick_scanner()
        local ok, ready = pcall(scan_scene_batch)
        if not ok then
            discard_unreliable_scanner_snapshot()
            local _, key = runtime_guard:get_scene()
            if key == "" or not runtime_guard:accept_scene(key) then
                scanner.force_rescan = true
                runtime_guard:block_frame()
                return false
            end
            return true
        end
        return ready
    end

    local function get_all_characters()
        transform_player_characters = {}
        local chars = {}
        local seen_objs = {} -- 用于去重，Key: GameObject Address
        local pm = get_player_manager()
        if pm then
            -- 遍历 InstancedPlayer (通常包含所有玩家)
            local count = pm:call("get_InstancedPlayerNum")
            if count then
                for i = 0, count - 1 do
                    local player = pm:call("getInstancedPlayer", i)
                    if player then
                        local char = player:call("get_Character")
                        if char and sdk.is_managed_object(char) then
                            transform_player_characters[tostring(char)] = true
                            local game_obj_ok, game_obj = (function() local go = safe_get_game_object(char, "get_all_characters_instanced") if not go then return false end return true, go end)()
                            if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                                -- 检查角色是否被游戏原生隐藏 (例如在使用装备箱时)
                                local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                                if not (draw_status and is_draw == false) then
                                    local key = tostring(game_obj)
                                    if not seen_objs[key] then
                                        local bid = get_character_body_id(char)
                                        -- PlayerManager 返回的就是已实例化玩家；Body ID 允许 PFB 自定义名称，
                                        -- 不能再限制为原版 ch03 前缀，否则预设不会应用到改名装备。
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
            -- 获取 MasterPlayer (本地玩家)
            local master = pm:call("getMasterPlayer")
            if master then
                local char = master:call("get_Character")
                if char and sdk.is_managed_object(char) then
                    transform_player_characters[tostring(char)] = true
                    local game_obj_ok, game_obj = (function() local go = safe_get_game_object(char, "get_all_characters_master") if not go then return false end return true, go end)()
                    if game_obj_ok and game_obj and sdk.is_managed_object(game_obj) then
                        local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                        if not (draw_status and is_draw == false) then
                            local key = tostring(game_obj)
                            if not seen_objs[key] then
                                local bid = get_character_body_id(char)
                                -- 同上：主玩家的自定义 Body ID 也必须参与预设应用循环。
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
        -- 2. 合并缓存中的结果 (由 scanner 异步更新)
        local current_time = os.clock()
        local scan_interval = global_config.scan_interval or 2.0
        local cache_ttl = scan_interval + CACHE_TTL_BUFFER
        for key, data in pairs(character_cache) do
            -- 增加有效性检查
            local is_valid = false
            -- 角色包装对象可能已随场景销毁；safe_get_game_object 失败时立即丢弃该条目，
            -- 避免之后每帧都对死对象重复 invoke。
            local game_obj = data.char and safe_get_game_object(data.char, "character_cache_validate") or nil
            if game_obj then
                -- 检查角色是否被游戏原生隐藏
                local draw_status, is_draw = pcall(function() return game_obj:call("get_Draw") end)
                is_valid = not (draw_status and is_draw == false)
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
        -- 变更造型时 MasterPlayer 仍存在，但画面显示的是 CharaMake 的独立预览。
        -- 仅使用扫描器确认且仍可见的预览，不把预览加入战斗变身规则的玩家集合。
        for _, data in pairs(character_cache) do
            if data.is_editor_preview
                and current_time - data.last_seen <= (global_config.scan_interval or 2.0) + CACHE_TTL_BUFFER then
                local game_obj = safe_get_game_object(data.char, "local_editor_preview")
                if game_obj then
                    local ok, visible = pcall(function() return game_obj:call("get_Draw") end)
                    if ok and visible == true then return data.char end
                end
            end
        end
        local player_manager = get_player_manager()
        if player_manager then
            local master_player = player_manager:call("getMasterPlayer")
            if master_player then
                char = master_player:call("get_Character")
                if char and sdk.is_managed_object(char) then transform_player_characters[tostring(char)] = true end
            end
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

    return {
        guard = runtime_guard,
        tick = tick_scanner,
        all = get_all_characters,
        local_player = get_local_player_character,
        cached = function() return character_cache end,
        can_transform = function(character)
            return not runtime_guard.suspended and character ~= nil
                and transform_player_characters[tostring(character)] == true
        end,
    }
end

return Actors
