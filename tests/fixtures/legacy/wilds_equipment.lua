-- 冻结自 5d09c01 的荒野实际入口，供模块拆分对照。
return function(env)
    return assert(load([=[
local body_id_cache, weapon_id_cache = {}, {}
local function find_weapons_in_hierarchy(transform, depth, results)
    if depth > 5 then return end
    local child = transform:call("get_Child")
    while child do
        local child_obj_ok, child_obj = (function() local go = safe_get_game_object(child, "weapon_hierarchy_search") if not go then return false end return true, go end)()
        if child_obj_ok and child_obj then
            local name = child_obj:call("get_Name")
            -- 如果节点名叫 Wp_Parent 或 WpSub_Parent，则视为当前激活的主武器部件
            -- 排除包含 Reserve 的节点，过滤掉副武器
            if name and (name == "Wp_Parent" or name == "WpSub_Parent") then
                local wp_transform = child_obj:call("get_Transform")
                if wp_transform then
                    local wp_child = wp_transform:call("get_Child")
                    while wp_child do
                        local wp_child_obj_ok, wp_child_obj = (function() local go = safe_get_game_object(wp_child, "weapon_hierarchy_child") if not go then return false end return true, go end)()
                        if wp_child_obj_ok and wp_child_obj then
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
    local game_obj_status_cache, game_obj_cache = (function() local go = safe_get_game_object(character, "weapon_id_hierarchy") if not go then return false end return true, go end)()
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
    local game_obj_cache = safe_get_game_object(character, "body_id_cache_key")
    if game_obj_cache then
        cache_key = tostring(game_obj_cache)
    else
        -- GameObject 已销毁说明这个角色包装对象已随场景失效：
        -- 直接返回 nil 让调用方跳过该角色，避免每帧继续对它做无效访问。
        return nil
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
        local game_obj = safe_get_game_object(character, "body_id_fallback")
        if game_obj then
            local transform = game_obj:call("get_Transform")
            if transform then
                local child = transform:call("get_Child")
                -- 收集所有候选 Body ID
                local candidates = {}
                local has_non_ch00 = false
                while child do
                    local child_obj_ok, child_obj = (function() local go = safe_get_game_object(child, "body_id_first") if not go then return false end return true, go end)()
                    if child_obj_ok and child_obj then
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
                if name and (name == "Pl000_00" or preview_character_names[name]) then
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


return {body_id=get_character_body_id, weapon_id=get_character_weapon_id}
]=], "legacy-wilds_equipment", "t", env))()
end
