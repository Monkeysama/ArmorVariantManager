-- MHR 093c61c：冻结玩家目录、增量扫描与事件角色读取。
local source = [====[
local PlayerDir = {
    entries={}, others={}, local_entry=nil, local_index=nil,
    last_local_obj=nil, last_local_time=0, last_refresh=-math.huge,
    valid=false, refresh_interval=.5, persist=1, refresh_count=0,
    scan={state="IDLE",transforms=nil,count=0,index=1,last_scan_time=-math.huge,
        hit_ttl=10,miss_ttl=3,result=nil,result_time=-math.huge,
        result_valid=false,scan_count=0,retry_at=-math.huge},
}
local EMPTY_PLAYER_LIST = {}
local function safe_object_name(obj)
    local name = SceneObject.call(obj, "get_Name")
    if type(name) == "string" then return name end
    return nil
end

local function safe_object_alive(obj)
    return SceneObject.is_alive(obj)
end

-- 辅助函数：检查玩家是否有 body 子物体
local function player_has_body(player)
    if not safe_object_alive(player) then return false end
    -- 整条 transform 链都放进 pcall：链条上任一环失效都会抛异常
    local ok, result = pcall(function()
        local transform = SceneObject.call(player, "get_Transform")
        if not transform then return false end
        local child = SceneObject.call(transform, "get_Child")
        local guard = 0
        while child do
            guard = guard + 1
            if guard > 256 then break end
            local child_obj = SceneObject.call(child, "get_GameObject")
            if child_obj then
                local name = SceneObject.call(child_obj, "get_Name")
                if name and string.find(name, "body") then
                    return true
                end
            end
            child = SceneObject.call(child, "get_Next")
        end
        return false
    end)
    return ok and result == true
end

-- 名称是否"像玩家"（大小写不敏感）。
-- - 不能写成 name:lower() —— 那会为每个组件新建一个字符串，
--   8000 个组件就是 8000 次分配，是这条扫描路径上很可观的一部分开销。
--   这里用 Lua 模式做大小写不敏感匹配，零分配。
local function name_looks_like_player(name)
    -- "player" / "female" / "male"（"female" 里本来就含 "male"，所以一条就够）
    return string.find(name, "[Pp][Ll][Aa][Yy][Ee][Rr]") ~= nil
        or string.find(name, "[Mm][Aa][Ll][Ee]") ~= nil
end

function PlayerDir.scan_reset()
    local scan = PlayerDir.scan
    scan.state = "IDLE"
    scan.transforms = nil
    scan.count = 0
    scan.index = 1
    scan.result = nil
    scan.result_valid = false
    scan.result_time = -math.huge
    scan.last_scan_time = -math.huge
    scan.retry_at = -math.huge
end

function PlayerDir.scan_tick()
    local scan = PlayerDir.scan
    local now = os.clock()

    if now < scan.retry_at then return end

    if scan.state == "IDLE" then
        -- 结果还在有效期内 → 什么都不用做（正常游玩每帧走到这里只有一次比较）
        if scan.result_valid then
            local ttl = scan.result and scan.hit_ttl or scan.miss_ttl
            if (now - scan.result_time) < ttl then return end
        end
        -- 取场景里的全部 Transform（这一次调用本身不贵，贵的是逐个读名字）
        local t_start = Profiler.begin("scene_scan_start")
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        if not scene_manager then return end
        local scene = sdk.call_native_func(scene_manager,
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local transforms = SceneObject.call(scene, "findComponents(System.Type)", type_cache.via_transform)
        if not transforms then return end
        local list = transforms:get_elements()
        if not list then return end
        Profiler.finish("scene_scan_start", t_start)
        scan.transforms = list
        scan.count = #list
        scan.index = 1
        scan.state = "PROCESSING"
        scan.result = nil
        scan.result_valid = false
        scan.scan_count = scan.scan_count + 1
        scan.last_scan_time = now
        return
    end

    -- PROCESSING：这一帧只处理一小批
    -- - 批大小用专用的 scene_scan_batch（默认 24），不直接用 UI 上的
    --   scanner_batch_size —— 后者默认 100，扫描期间会吃掉约 0.36ms/帧。
    local batch = tonumber(global_config.scene_scan_batch) or 24
    if batch < 4 then batch = 4 end
    if batch > 128 then batch = 128 end
    local t_batch = Profiler.begin("scene_scan_batch")
    local i = scan.index
    local last = i + batch - 1
    if last > scan.count then last = scan.count end
    local get_component_go = method_cache.Component_get_GameObject
    local batch_started=os.clock()
    while i <= last do
        if i>scan.index and os.clock()-batch_started>=.0003 then break end
        -- SystemArray/get_elements 的元素在读取时才解包；场景切换后，
        -- scan.transforms[i] 本身就可能抛 sol_lua_push，并不只是在 call 时抛。
        -- 整个读取与调用一起保护；失效后丢弃旧快照，不能每帧卡在同一批。
        local ok, game_obj = pcall(function()
            local t = scan.transforms[i]
            if t == nil then return nil end
            if not safe_object_alive(t) then error("AVM: stale Transform snapshot", 0) end
            return get_component_go:call(t)
        end)
        if not ok then
            PlayerDir.scan_reset()
            scan.retry_at = now + 0.1
            Profiler.count("scene_scan_stale_snapshot")
            Profiler.finish("scene_scan_batch", t_batch)
            return
        end
        if game_obj then
            local name = safe_object_name(game_obj)
            if name and name_looks_like_player(name) and player_has_body(game_obj) then
                scan.result = game_obj
                scan.result_time = os.clock()
                scan.result_valid = true
                scan.state = "IDLE"
                scan.transforms = nil
                scan.count = 0
                scan.index = 1
                Profiler.count("scene_scan_hits")
                Profiler.max_value("scene_scan_index_at_hit", i)
                Profiler.finish("scene_scan_batch", t_batch)
                return
            end
        end
        i = i + 1
    end
    scan.index = i
    Profiler.finish("scene_scan_batch", t_batch)

    if scan.index > scan.count then
        -- 扫完了：把「没找到」也记成有效结果（否则会一直重扫）
        scan.result = nil
        scan.result_time = os.clock()
        scan.result_valid = true
        scan.state = "IDLE"
        scan.transforms = nil
        scan.count = 0
        scan.index = 1
        Profiler.count("scene_scan_complete")
    end
end

-- 非阻塞版「扫一次」：返回已有结果；没有就返回 nil 并推进一步
function PlayerDir.scan_once()
    local scan = PlayerDir.scan
    local function current()
        if not scan.result_valid then return nil end
        if scan.result and not safe_object_alive(scan.result) then
            PlayerDir.scan_reset()
            return nil
        end
        local ttl = scan.result and scan.hit_ttl or scan.miss_ttl
        if (os.clock() - scan.result_time) < ttl then return scan.result or false end
        return nil
    end
    local value = current()
    if value ~= nil then return value or nil end
    PlayerDir.scan_tick()
    value = current()
    if value ~= nil then return value or nil end
    return nil
end

-- getPlayerIndex()：联机时区分本地玩家与其他玩家的**唯一可靠依据**
function PlayerDir.index_of(player)
    if not safe_object_alive(player) then return nil end
    local ok, idx = pcall(function() return SceneObject.call(player, "getPlayerIndex") end)
    if ok and type(idx) == "number" then return idx end
    return nil
end

function PlayerDir.to_game_object(player)
    if not safe_object_alive(player) then return nil end
    local ok, go = pcall(function() return SceneObject.call(player, "get_GameObject") end)
    if ok and go and safe_object_alive(go) then return go end
    return nil
end

-- PlayerManager:findMasterPlayer()（getMasterPlayer 作为兜底）
function PlayerDir.find_master()
    local pm = get_player_manager()
    if not pm then return nil end
    local ok, master = pcall(function() return pm:call("findMasterPlayer()") end)
    if not (ok and master and safe_object_alive(master)) then
        ok, master = pcall(function() return pm:call("getMasterPlayer") end)
        if not (ok and master and safe_object_alive(master)) then
            master = nil
        end
    end
    return master
end

-- 读 PlayerList 里的第 i 个玩家。
-- - 先走「托管对象标准调用」list:call("get_Item", i)（最稳，兼容性最好），
--   失败再退回预先缓存的 MethodDefinition 形式。
function PlayerDir.read_list_item(list, i)
    local ok, item = pcall(function() return list:call("get_Item", i) end)
    if ok and item then return item end
    if playerListGetItem then
        local ok2, item2 = pcall(playerListGetItem.call, playerListGetItem, list, i)
        if ok2 and item2 then return item2 end
    end
    return nil
end

function PlayerDir.rebuild()
    local started = Profiler.begin("player_directory_rebuild")
    PlayerDir.refresh_count = PlayerDir.refresh_count + 1
    PlayerDir.last_refresh = os.clock()

    local entries = {}
    local local_entry = nil

    local master = PlayerDir.find_master()
    local master_index = PlayerDir.index_of(master)
    local master_go = PlayerDir.to_game_object(master)

    local pm = get_player_manager()
    local list = nil
    if pm then
        local ok, field = pcall(function() return pm:get_field("PlayerList") end)
        if ok then list = field end
    end

    if list then
        local count = nil
        local ok_count, c = pcall(function() return list:call("get_Count") end)
        if ok_count and type(c) == "number" then count = c end
        local limit = 16
        if count and count > 0 and count - 1 < limit then limit = count - 1 end

        for i = 0, limit do
            local item = PlayerDir.read_list_item(list, i)
            if item and safe_object_alive(item) then
                local go = PlayerDir.to_game_object(item)
                if go then
                    local idx = PlayerDir.index_of(item)
                    local is_local = (master ~= nil and item == master)
                        or (master_index ~= nil and idx ~= nil and idx == master_index)
                        or (master_go ~= nil and go == master_go)
                    -- - 名字顺手缓存下来：面板每帧都要显示「检测到的玩家」，
                    --   不能每帧为每个玩家各做一次托管调用（旧写法就是那样）。
                    local entry = { player = item, obj = go, index = idx,
                                    is_local = is_local, name = safe_object_name(go) }
                    entries[#entries + 1] = entry
                    if is_local and local_entry == nil then local_entry = entry end
                end
            end
        end
    end

    -- 极端情况：findMasterPlayer 拿到了玩家，但它不在 PlayerList 里
    if local_entry == nil and master_go ~= nil then
        local_entry = { player = master, obj = master_go, index = master_index,
                        is_local = true, from_master = true,
                        name = safe_object_name(master_go) }
        table.insert(entries, 1, local_entry)
    end

    -- 最后兜底：PlayerManager 不可用或被清空（读图、菜单、存档预览界面）
    -- 此时才退回「场景扫描」（增量式、非阻塞，见 PlayerDir.scan_once），
    -- 而且只有在场景里**只有一个**候选时才认它是主角，以免联机时又抓成队友。
    if local_entry == nil then
        local scanned = PlayerDir.scan_once()
        if scanned then
            if #entries == 0 then
                local_entry = { player = nil, obj = scanned, index = nil, is_local = true,
                                from_scan = true, name = safe_object_name(scanned) }
                entries[#entries + 1] = local_entry
            elseif #entries == 1 then
                entries[1].is_local = true
                local_entry = entries[1]
            end
        elseif #entries == 1 then
            -- 只有一个人物在场（存档预览 / 单人读图）：它就是主角
            entries[1].is_local = true
            local_entry = entries[1]
        end
    end

    -- 其他玩家（复用同一张表，避免每 0.5 秒新建垃圾）
    local others = PlayerDir.others
    for i = #others, 1, -1 do others[i] = nil end
    for _, entry in ipairs(entries) do
        if not entry.is_local then others[#others + 1] = entry end
    end

    PlayerDir.entries = entries
    PlayerDir.local_entry = local_entry
    PlayerDir.local_index = local_entry and local_entry.index or master_index
    if local_entry and safe_object_alive(local_entry.obj) then
        PlayerDir.last_local_obj = local_entry.obj
        PlayerDir.last_local_time = os.clock()
    end
    PlayerDir.valid = true

    Profiler.count("player_directory_rebuilds")
    Profiler.count("player_directory_entries", #entries)
    Profiler.count("player_directory_others", #others)
    Profiler.finish("player_directory_rebuild", started)
end

-- 取（必要时重建）玩家目录
function PlayerDir.get()
    local now = os.clock()
    if not PlayerDir.valid
        or (now - PlayerDir.last_refresh) > PlayerDir.refresh_interval then
        PlayerDir.rebuild()
    elseif PlayerDir.local_entry ~= nil
        and not safe_object_alive(PlayerDir.local_entry.obj) then
        -- 本地玩家对象失效（换装重建 / 切场景）→ 立刻重建，不等节流
        PlayerDir.rebuild()
    elseif PlayerDir.local_entry == nil and #PlayerDir.entries == 0
        and PlayerDir.scan.result_valid and PlayerDir.scan.result ~= nil then
        -- - 场景扫描刚把人找出来（PlayerManager 完全没给出玩家的情况）：
        --   立刻重建一次，不要等到下一个节流周期，否则面板会白等半秒。
        --   注意条件里带了 #entries == 0：一旦目录里已经有候选就不会再进来，
        --   所以这里不会变成「每帧重建」。
        PlayerDir.rebuild()
    end
    return PlayerDir
end

function PlayerDir.sequence(value)
    if value == nil then return EMPTY_PLAYER_LIST end
    local ok, elements = pcall(function() return value:get_elements() end)
    if ok and elements ~= nil then return elements end
    if type(value) == "table" then return value end
    return EMPTY_PLAYER_LIST
end
local get_event_players = nil
local function get_event_players_impl()
    local players = {}
    local eventManager = sdk.get_managed_singleton("snow.eventcut.EventManager")
    if not eventManager then return players end
    local loadHandlerStack = eventManager:call("get_LoadHandlerStack")
    if not loadHandlerStack then return players end
    for _, handler in ipairs(PlayerDir.sequence(loadHandlerStack)) do
        if handler then
            local uniqueEventManager = SceneObject.call(handler, "findUniqueEventManager")
            if uniqueEventManager then
                local eventPlayerList = SceneObject.call(uniqueEventManager, "get_EventPlayerList")
                if eventPlayerList then
                    -- 优先尝试 get_Count / get_Item（特殊内嵌式 CG）
                    local ok_count, count = pcall(function() return eventPlayerList:call("get_Count") end)
                    if ok_count and type(count) == "number" and count > 0 then
                        for i = 0, count - 1 do
                            local ok_player, eventPlayer = pcall(function() return eventPlayerList:call("get_Item", i) end)
                            if ok_player and eventPlayer then
                                local ok_go, go = pcall(function() return SceneObject.call(eventPlayer, "get_GameObject") end)
                                if ok_go and go then
                                    table.insert(players, go)
                                end
                            end
                        end
                    else
                        -- 回退到 ToArray（普通独立过场 CG）
                        local ok_arr, arr = pcall(function() return eventPlayerList:call("ToArray") end)
                        if ok_arr and arr then
                            for _, eventPlayer in ipairs(PlayerDir.sequence(arr)) do
                                if eventPlayer then
                                    local ok_go, go = pcall(function() return SceneObject.call(eventPlayer, "get_GameObject") end)
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
local function get_master_player_object_impl()
    local dir = PlayerDir.get()
    if dir.local_entry and safe_object_alive(dir.local_entry.obj) then
        return dir.local_entry.obj
    end
    -- 本地玩家短暂读不到（读图 / 菜单）：沿用最近一次确认过的对象，避免面板闪烁。
    -- 超过 PlayerDir.persist 秒还是拿不到就放弃（避免一直对着已销毁的对象调用）。
    local last = dir.last_local_obj
    if last and safe_object_alive(last)
        and (os.clock() - dir.last_local_time) <= PlayerDir.persist then
        return last
    end
    return nil
end
function PlayerDir.reset()
    PlayerDir.entries, PlayerDir.others = {}, {}
    PlayerDir.local_entry, PlayerDir.local_index = nil, nil
    PlayerDir.last_local_obj, PlayerDir.last_local_time = nil, 0
    PlayerDir.last_refresh, PlayerDir.valid = -math.huge, false
    PlayerDir.scan_reset()
end
return {get=PlayerDir.get,local_player=get_master_player_object_impl,
    events=get_event_players_impl,reset=PlayerDir.reset,state=PlayerDir}
]====]
return function(env) return assert(load(source, "legacy-rise-actors", "t", env))() end
