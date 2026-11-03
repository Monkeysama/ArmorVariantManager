local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Actors = {}

-- 玩家目录与扫描只持有角色引用，装备缓存和应用状态由运行层管理。
function Actors.new(global_config)
    local get_component_go = sdk.find_type_definition("via.Component"):get_method("get_GameObject")
    local transform_type = sdk.typeof("via.Transform")
    local manager_type = sdk.find_type_definition("snow.player.PlayerManager")
    local list_field = manager_type and manager_type:get_field("PlayerList")
    local playerListGetItem = list_field and list_field:get_type():get_method("get_Item")
    local function get_player_manager() return sdk.get_managed_singleton("snow.player.PlayerManager") end
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

    local function player_has_body(player)
        if not safe_object_alive(player) then return false end
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

    local function name_looks_like_player(name)
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

    -- 每批最多 24 个（可配置）或 0.3ms，失效快照丢弃后延迟重试。
    function PlayerDir.scan_tick()
        local scan = PlayerDir.scan
        local now = os.clock()

        if now < scan.retry_at then return end

        if scan.state == "IDLE" then
            if scan.result_valid then
                local ttl = scan.result and scan.hit_ttl or scan.miss_ttl
                if (now - scan.result_time) < ttl then return end
            end

            local scene_manager = sdk.get_native_singleton("via.SceneManager")
            if not scene_manager then return end
            local scene = sdk.call_native_func(scene_manager,
                sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            if not scene then return end
            local transforms = SceneObject.call(scene, "findComponents(System.Type)", transform_type)
            if not transforms then return end
            local list = transforms:get_elements()
            if not list then return end

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

        local batch = tonumber(global_config.scene_scan_batch) or 24
        if batch < 4 then batch = 4 end
        if batch > 128 then batch = 128 end

        local i = scan.index
        local last = i + batch - 1
        if last > scan.count then last = scan.count end
        local batch_started=os.clock()
        while i <= last do
            if i>scan.index and os.clock()-batch_started>=.0003 then break end
            local ok, game_obj = pcall(function()
                local t = scan.transforms[i]
                if t == nil then return nil end
                if not safe_object_alive(t) then error("AVM: stale Transform snapshot", 0) end
                return get_component_go:call(t)
            end)
            if not ok then
                PlayerDir.scan_reset()
                scan.retry_at = now + 0.1

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

                    return
                end
            end
            i = i + 1
        end
        scan.index = i

        if scan.index > scan.count then
            scan.result = nil
            scan.result_time = os.clock()
            scan.result_valid = true
            scan.state = "IDLE"
            scan.transforms = nil
            scan.count = 0
            scan.index = 1

        end
    end

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

    function PlayerDir.read_list_item(list, i)
        local ok, item = pcall(function() return list:call("get_Item", i) end)
        if ok and item then return item end
        if playerListGetItem then
            local ok2, item2 = pcall(playerListGetItem.call, playerListGetItem, list, i)
            if ok2 and item2 then return item2 end
        end
        return nil
    end

    -- 主角由 MasterPlayer 身份或玩家索引确定，不依赖 player00 等名字。
    function PlayerDir.rebuild()

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
                        local entry = { player = item, obj = go, index = idx,
                                        is_local = is_local, name = safe_object_name(go) }
                        entries[#entries + 1] = entry
                        if is_local and local_entry == nil then local_entry = entry end
                    end
                end
            end
        end

        if local_entry == nil and master_go ~= nil then
            local_entry = { player = master, obj = master_go, index = master_index,
                            is_local = true, from_master = true,
                            name = safe_object_name(master_go) }
            table.insert(entries, 1, local_entry)
        end

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
                entries[1].is_local = true
                local_entry = entries[1]
            end
        end

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

    end

    function PlayerDir.get()
        local now = os.clock()
        if not PlayerDir.valid
            or (now - PlayerDir.last_refresh) > PlayerDir.refresh_interval then
            PlayerDir.rebuild()
        elseif PlayerDir.local_entry ~= nil
            and not safe_object_alive(PlayerDir.local_entry.obj) then
            PlayerDir.rebuild()
        elseif PlayerDir.local_entry == nil and #PlayerDir.entries == 0
            and PlayerDir.scan.result_valid and PlayerDir.scan.result ~= nil then
            PlayerDir.rebuild()
        end
        return PlayerDir
    end

    -- REF SystemArray 的 get_elements 返回一基序列，也可能是 userdata。
    function PlayerDir.sequence(value)
        if value == nil then return EMPTY_PLAYER_LIST end
        local ok, elements = pcall(function() return value:get_elements() end)
        if ok and elements ~= nil then return elements end
        if type(value) == "table" then return value end
        return EMPTY_PLAYER_LIST
    end
    -- 内嵌 CG 使用 Count/Item；普通过场兼容 ToArray。
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
    -- 读图短暂失联时沿用有效本地角色，最长一秒。
    local function get_master_player_object_impl()
        local dir = PlayerDir.get()
        if dir.local_entry and safe_object_alive(dir.local_entry.obj) then
            return dir.local_entry.obj
        end
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
    return {
        get = PlayerDir.get,
        local_player = get_master_player_object_impl,
        events = get_event_players_impl,
        reset = PlayerDir.reset,
        -- 正常游戏不扫描场景，缺少本地角色时推进菜单/预览回退。
        tick = function()
            if not PlayerDir.local_entry or not SceneObject.is_alive(PlayerDir.local_entry.obj) then
                PlayerDir.scan_tick()
            end
        end,
    }
end

return Actors
