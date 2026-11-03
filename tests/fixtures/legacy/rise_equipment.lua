-- MHR 093c61c：冻结装备发现与缓存行为，仅补测试闭包。
local source = [====[
local get_cached_weapon_parts, get_mesh_component_recursive_uncached
local part_cache, weapon_part_cache = {}, {}
local PlayerDir = {body_id={by_char={}},mesh={by_obj={},ttl=2},parts_retry=.02}
local type_mesh
local function get_character_body_id_impl(character)
    if not character then return nil end
    if not safe_object_alive(character) then return nil end
    -- 整条 transform 链 + get_Name 都放进 pcall（场景切换后对象可能已失效）
    local ok, body_id = pcall(function()
        local transform = SceneObject.call(character, "get_Transform")
        if transform then
            local child = SceneObject.call(transform, "get_Child")
            local guard = 0
            while child do
                guard = guard + 1
                if guard > 256 then break end
                local child_obj = SceneObject.call(child, "get_GameObject")
                if child_obj then
                    local name = SceneObject.call(child_obj, "get_Name")
                    if name and string.find(name, "body") then
                        return name
                    end
                end
                child = SceneObject.call(child, "get_Next")
            end
        end
        local go_name = SceneObject.call(character, "get_Name")
        if go_name then return go_name end
        return nil
    end)
    if ok then return body_id end
    return nil
end

local WEAPON_MAIN_PART_INDEX = {
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

local get_weapon_attack_part_name = nil
-- player_handle：该玩家的 snow.player.Player 托管对象（可选）。
-- - 联机时它很关键：武器类型（_playerWeaponType）必须读**这名玩家自己**的，
--   旧实现永远读本地玩家的，于是队友会被套上主角的武器部件。
local function get_weapon_attack_part_name_impl(player_obj, player_handle)
    if not player_obj then return nil end
    if not safe_object_alive(player_obj) then return nil end

    -- - 先查缓存（命中就不做递归查找）。
    --   旧实现是「每次都重新递归查一遍，再顺手写缓存」，等于缓存只是给
    --   紧接着的 get_cached_weapon_parts 用，自己从不命中 —— 联机时
    --   4 个玩家每轮就是 4 次深度 5 的递归。
    local weapon_parts = nil
    if get_cached_weapon_parts then
        weapon_parts = get_cached_weapon_parts(player_obj, player_handle)
    end
    if not weapon_parts then return nil end

    local weapon_type = Utils.get_current_weapon_type(player_handle or player_obj)
    if not weapon_type then return nil end

    -- 对于双刀特殊处理
    if weapon_type == Utils.WEAPON_TYPE.DUAL_BLADES then
        if weapon_parts[1] then
            return safe_object_name(weapon_parts[1])
        end
    end

    local main_part_index = WEAPON_MAIN_PART_INDEX

    local idx = main_part_index[weapon_type] or 1
    if weapon_parts[idx] then
        return safe_object_name(weapon_parts[idx])
    end
    for _, part in ipairs(weapon_parts) do
        if part then return safe_object_name(part) end
    end
    return nil
end

function PlayerDir.body_id_of(character)
    if not safe_object_alive(character) then return nil end
    local addr = tostring(character)
    local now = os.clock()
    local cached=PlayerDir.body_id.by_char[addr]
    if cached and PlayerDir.epoch and cached.epoch==PlayerDir.epoch then return cached.id end
    local parts=PlayerDir.parts(character)
    local body=parts and parts[1]
    local body_name=body and safe_object_name(body)
    if cached and not cached.short and parts and cached.sig==parts.sig
        and cached.body_name==body_name then cached.epoch=PlayerDir.epoch;return cached.id end
    if cached and cached.short and now-cached.time<.02 then return cached.id end
    local id = get_character_body_id(character)
    local looks_like_body_part = id ~= nil and string.find(id, "body", 1, true) ~= nil
    PlayerDir.body_id.by_char[addr] = {
        id = id, time = now, epoch=PlayerDir.epoch, sig = parts and parts.sig or nil, body_name=body_name,
        short = not looks_like_body_part
    }
    return id
end

function PlayerDir.invalidate_body_id(character)
    if not character then return end
    PlayerDir.body_id.by_char[tostring(character)] = nil
end

-- mesh 组件：带 TTL + 存活校验的缓存（见 PlayerDir.mesh 上的说明）
function PlayerDir.mesh_of(game_obj)
    if not safe_object_alive(game_obj) then return nil end
    local addr = tostring(game_obj)
    local now = os.clock()
    local cached = PlayerDir.mesh.by_obj[addr]
    if cached and (now - cached.time) < PlayerDir.mesh.ttl
        and cached.mesh ~= nil and safe_object_alive(cached.mesh) then
        return cached.mesh
    end
    local mesh = get_mesh_component_recursive_uncached(game_obj)
    if mesh ~= nil then
        PlayerDir.mesh.by_obj[addr] = { mesh = mesh, time = now }
    else
        PlayerDir.mesh.by_obj[addr] = nil
    end
    return mesh
end

-- ============================================================================
--  增量式场景扫描（照搬荒野版本 tick_scanner 的思路）
-- ----------------------------------------------------------------------------
--  scan_tick()：每帧调用一次，空闲时只做一次时间比较；扫描中每次只处理
--               scanner_batch_size 个 Transform 组件，所以永远不会出现
--               「一帧卡几十毫秒」的情况。
--  scan_once()：给「找不到本地玩家」时兜底用。非阻塞 —— 有结果就给结果，
--               没有就顺手推进一步并返回 nil（下一帧接着推进）。
-- ============================================================================

get_mesh_component_recursive_uncached = function(game_obj)
    Profiler.count("get_mesh_component_uncached_calls")
    if not game_obj then return nil end
    if not safe_object_alive(game_obj) then return nil end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return nil end
    end
    local runtime_type = type_mesh:get_runtime_type()
    local mesh = SceneObject.call(game_obj, "getComponent(System.Type)", runtime_type)
    if mesh then return mesh end
    local transform = SceneObject.call(game_obj, "get_Transform")
    if transform then
        local child = SceneObject.call(transform, "get_Child")
        while child do
            local child_obj = SceneObject.call(child, "get_GameObject")
            if child_obj then
                mesh = SceneObject.call(child_obj, "getComponent(System.Type)", runtime_type)
                if mesh then return mesh end
            end
            child = SceneObject.call(child, "get_Next")
        end
    end
    return nil
end


function PlayerDir.parts_valid(entry)
    if not entry then return false,false end
    if PlayerDir.epoch and entry.validated_epoch==PlayerDir.epoch then return entry.complete,true end
    local complete = true
    for i = 0, 4 do
        local obj = entry[i]
        if obj == nil then
            complete = false
        elseif not safe_object_alive(obj) then
            return false, false -- 有部件已销毁 → 必须立刻丢弃，不能按缺件重试限频沿用
        end
    end
    entry.validated_epoch,entry.complete=PlayerDir.epoch,complete
    return complete, true
end

function PlayerDir.walk_parts(character)
    -- 与旧的「一次性获取玩家所有防具部件」保持完全一致：
    --   * 递归遍历（部件不一定都在第一层）；
    --   * 同一编号只记第一个，但「先遇到 ch00（游戏原版）后来遇到非 ch00（MOD）」时替换，
    --     也就是优先使用 MOD 部件。
    local parts = {}
    local ok = pcall(function()
        local transform = SceneObject.call(character, "get_Transform")
        if not transform then return end
        local function traverse(node)
            local child = SceneObject.call(node, "get_Child")
            local guard = 0
            while child do
                guard = guard + 1
                if guard > 256 then break end
                local child_obj = SceneObject.call(child, "get_GameObject")
                if child_obj then
                    local name = safe_object_name(child_obj)
                    if name then
                        local target_index = nil
                        if string.find(name, "body") then target_index = 1
                        elseif string.find(name, "helm") then target_index = 0
                        elseif string.find(name, "arm") then target_index = 2
                        elseif string.find(name, "wst") then target_index = 3
                        elseif string.find(name, "leg") then target_index = 4
                        end
                        if target_index ~= nil then
                            if parts[target_index] then
                                local old_name = safe_object_name(parts[target_index])
                                local is_old_ch00 = old_name and string.find(old_name, "^ch00")
                                local is_new_ch00 = string.find(name, "^ch00")
                                if is_old_ch00 and not is_new_ch00 then
                                    parts[target_index] = child_obj
                                end
                            else
                                parts[target_index] = child_obj
                            end
                        end
                    end
                    traverse(child)
                end
                child = SceneObject.call(child, "get_Next")
            end
        end
        traverse(transform)
    end)
    if not ok then return nil end
    local sig_parts = {}
    for i = 0, 4 do
        sig_parts[#sig_parts + 1] = parts[i] and tostring(parts[i]) or "-"
    end
    parts.sig = table.concat(sig_parts, "|")
    parts.walked_at = os.clock()
    return parts
end

-- 取「某角色 5 个防具部件」的缓存表（缺失时重建）
function PlayerDir.parts(character)
    if not character then return nil end
    if not safe_object_alive(character) then return nil end
    local addr = tostring(character)
    local entry = part_cache[addr]
    local now = os.clock()
    if entry then
        local complete, alive = PlayerDir.parts_valid(entry)
        if complete then return entry end
        if not alive then
            part_cache[addr] = nil
            entry = nil
        end
        -- 不完整（模型还在生成，或该模型确实缺件）：限频重扫，不要每帧狂扫
        if entry and entry.walked_at and (now - entry.walked_at) < PlayerDir.parts_retry then
            return entry
        end
    end
    local parts = PlayerDir.walk_parts(character)
    if not parts then return entry end
    -- 签名变化（换装 / 模型重建）时打个标记，让应用层强制重刷一次差分
    if entry and entry.sig and entry.sig ~= parts.sig then
        parts.changed = true
    end
    part_cache[addr] = parts
    Profiler.count("parts_walk")
    return parts
end


local function weapon_parts_alive(parts)
    if not parts then return false end
    local found_any = false
    -- 最多 2 个部件（各武器类型在 Utils.WEAPON_PARTS_MAP 里），循环上限给 8 足够
    for i = 1, 8 do
        local p = parts[i]
        if p ~= nil then
            found_any = true
            if not safe_object_alive(p) then return false end
        end
    end
    return found_any
end

PlayerDir.weapon_misses={}
local function get_cached_weapon_parts_impl(player_obj, player_handle)
    if not player_obj or not safe_object_alive(player_obj) then return nil end
    local addr=tostring(player_obj)
    local weapon_type=Utils.get_current_weapon_type(player_handle or player_obj)
    local cached=weapon_part_cache[addr]
    if cached and cached.weapon_type==weapon_type then
        if cached.validated_epoch==PlayerDir.epoch or weapon_parts_alive(cached) then
            cached.validated_epoch=PlayerDir.epoch
            return cached
        end
    end
    weapon_part_cache[addr]=nil
    local miss=PlayerDir.weapon_misses[addr]
    local now=os.clock()
    if miss and miss.weapon_type==weapon_type and now<miss.retry_at then return nil end
    local parts=Utils.get_current_weapon_parts(player_handle or player_obj)
    if weapon_parts_alive(parts) then
        parts.weapon_type,parts.validated_epoch=weapon_type,PlayerDir.epoch
        weapon_part_cache[addr]=parts;PlayerDir.weapon_misses[addr]=nil
        return parts
    end
    PlayerDir.weapon_misses[addr]={weapon_type=weapon_type,retry_at=now+.02}
end


get_character_body_id = get_character_body_id_impl
get_cached_weapon_parts = get_cached_weapon_parts_impl
return {state=PlayerDir, body_id=PlayerDir.body_id_of, parts=PlayerDir.parts,
    mesh=PlayerDir.mesh_of, weapon_id=get_weapon_attack_part_name_impl,
    weapons=get_cached_weapon_parts, invalidate_body_id=PlayerDir.invalidate_body_id}
]====]
return function(env) return assert(load(source, "legacy-rise-equipment", "t", env))() end
