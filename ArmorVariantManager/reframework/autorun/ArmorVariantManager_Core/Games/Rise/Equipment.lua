local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Signals = require("ArmorVariantManager_Core.Games.Rise.Signals")
local Weapons = require("ArmorVariantManager_Core.Games.Rise.Weapons")
local Equipment = {}

-- 按角色缓存装备标识、五个防具部件和武器；由运行层推进帧次并清理。
function Equipment.new()
    local state = {body_id={by_char={}},mesh={by_obj={},ttl=2},parts_retry=.02}
    local part_cache, weapon_part_cache = {}, {}
    local type_mesh
    local get_cached_weapon_parts, get_mesh_component_recursive_uncached
    local safe_object_alive = SceneObject.is_alive
    local function safe_object_name(obj)
        local name = SceneObject.call(obj, "get_Name")
        return type(name) == "string" and name or nil
    end
    local function get_type(name) return sdk.find_type_definition(name) end

    local function read_body_id(character)
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
        [Weapons.WEAPON_TYPE.GREATSWORD] = 1,
        [Weapons.WEAPON_TYPE.SWITCH_AXE] = 1,
        [Weapons.WEAPON_TYPE.LONGSWORD] = 2,
        [Weapons.WEAPON_TYPE.LIGHT_BOWGUN] = 1,
        [Weapons.WEAPON_TYPE.HEAVY_BOWGUN] = 1,
        [Weapons.WEAPON_TYPE.HAMMER] = 1,
        [Weapons.WEAPON_TYPE.GUNLANCE] = 2,
        [Weapons.WEAPON_TYPE.LANCE] = 2,
        [Weapons.WEAPON_TYPE.SWORD_SHIELD] = 2,
        [Weapons.WEAPON_TYPE.DUAL_BLADES] = 1,
        [Weapons.WEAPON_TYPE.HUNTING_HORN] = 1,
        [Weapons.WEAPON_TYPE.CHARGE_BLADE] = 2,
        [Weapons.WEAPON_TYPE.INSECT_GLAIVE] = 2,
        [Weapons.WEAPON_TYPE.BOW] = 1,
    }

    -- 用目标玩家自己的武器类型选择主攻击部件，保持旧配置标识。
    local function weapon_id(player_obj, player_handle)
        if not player_obj then return nil end
        if not safe_object_alive(player_obj) then return nil end

        local weapon_parts = get_cached_weapon_parts(player_obj, player_handle)
        if not weapon_parts then return nil end

        local weapon_type = Signals.get_current_weapon_type(player_handle or player_obj)
        if not weapon_type then return nil end

        -- 对于双刀特殊处理
        if weapon_type == Weapons.WEAPON_TYPE.DUAL_BLADES then
            if weapon_parts[1] then
                return safe_object_name(weapon_parts[1])
            end
        end

        local idx = WEAPON_MAIN_PART_INDEX[weapon_type] or 1
        if weapon_parts[idx] then
            return safe_object_name(weapon_parts[idx])
        end
        for _, part in ipairs(weapon_parts) do
            if part then return safe_object_name(part) end
        end
        return nil
    end

    -- 帧内复用 ID，跨帧检查部件引用和身体名称。
    function state.body_id_of(character)
        if not safe_object_alive(character) then return nil end
        local addr = tostring(character)
        local now = os.clock()
        local cached=state.body_id.by_char[addr]
        if cached and state.epoch and cached.epoch==state.epoch then return cached.id end
        local parts=state.parts(character)
        local body=parts and parts[1]
        local body_name=body and safe_object_name(body)
        if cached and not cached.short and parts and cached.sig==parts.sig
            and cached.body_name==body_name then cached.epoch=state.epoch;return cached.id end
        if cached and cached.short and now-cached.time<.02 then return cached.id end
        local id = read_body_id(character)
        local looks_like_body_part = id ~= nil and string.find(id, "body", 1, true) ~= nil
        state.body_id.by_char[addr] = {
            id = id, time = now, epoch=state.epoch, sig = parts and parts.sig or nil, body_name=body_name,
            short = not looks_like_body_part
        }
        return id
    end

    function state.invalidate_body_id(character)
        if not character then return end
        state.body_id.by_char[tostring(character)] = nil
    end

    -- 网格缓存有效期两秒；已销毁的组件立即重新查找。
    function state.mesh_of(game_obj)
        if not safe_object_alive(game_obj) then return nil end
        local addr = tostring(game_obj)
        local now = os.clock()
        local cached = state.mesh.by_obj[addr]
        if cached and (now - cached.time) < state.mesh.ttl
            and cached.mesh ~= nil and safe_object_alive(cached.mesh) then
            return cached.mesh
        end
        local mesh = get_mesh_component_recursive_uncached(game_obj)
        if mesh ~= nil then
            state.mesh.by_obj[addr] = { mesh = mesh, time = now }
        else
            state.mesh.by_obj[addr] = nil
        end
        return mesh
    end

    -- 获取自身或直接子物体上的网格组件。
    get_mesh_component_recursive_uncached = function(game_obj)

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

    function state.parts_valid(entry)
        if not entry then return false,false end
        if state.epoch and entry.validated_epoch==state.epoch then return entry.complete,true end
        local complete = true
        for i = 0, 4 do
            local obj = entry[i]
            if obj == nil then
                complete = false
            elseif not safe_object_alive(obj) then
                return false, false -- 有部件已销毁 → 必须立刻丢弃，不能按缺件重试限频沿用
            end
        end
        entry.validated_epoch,entry.complete=state.epoch,complete
        return complete, true
    end

    function state.walk_parts(character)
        -- 递归发现五个部件；同一槽位优先非 ch00 的 MOD 部件。
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
    function state.parts(character)
        if not character then return nil end
        if not safe_object_alive(character) then return nil end
        local addr = tostring(character)
        local entry = part_cache[addr]
        local now = os.clock()
        if entry then
            local complete, alive = state.parts_valid(entry)
            if complete then return entry end
            if not alive then
                part_cache[addr] = nil
                entry = nil
            end
            -- 不完整（模型还在生成，或该模型确实缺件）：限频重扫，不要每帧狂扫
            if entry and entry.walked_at and (now - entry.walked_at) < state.parts_retry then
                return entry
            end
        end
        local parts = state.walk_parts(character)
        if not parts then return entry end
        -- 签名变化（换装 / 模型重建）时打个标记，让应用层强制重刷一次差分
        if entry and entry.sig and entry.sig ~= parts.sig then
            parts.changed = true
        end
        part_cache[addr] = parts

        return parts
    end

    local function weapon_parts_alive(parts)
        if not parts then return false end
        local found_any = false
        -- 稀疏数组不能用 ipairs：盾牌缺失时仍需检查第二个攻击部件。
        for i = 1, 8 do
            local p = parts[i]
            if p ~= nil then
                found_any = true
                if not safe_object_alive(p) then return false end
            end
        end
        return found_any
    end

    state.weapon_misses={}
    -- 按角色与武器类型复用部件，未生成时等待 20ms 后重试。
    local function get_cached_weapon_parts_impl(player_obj, player_handle)
        if not player_obj or not safe_object_alive(player_obj) then return nil end
        local addr=tostring(player_obj)
        local weapon_type=Signals.get_current_weapon_type(player_handle or player_obj)
        local cached=weapon_part_cache[addr]
        if cached and cached.weapon_type==weapon_type then
            if cached.validated_epoch==state.epoch or weapon_parts_alive(cached) then
                cached.validated_epoch=state.epoch
                return cached
            end
        end
        weapon_part_cache[addr]=nil
        local miss=state.weapon_misses[addr]
        local now=os.clock()
        if miss and miss.weapon_type==weapon_type and now<miss.retry_at then return nil end
        local parts=Weapons.get_current_weapon_parts(player_handle or player_obj)
        if weapon_parts_alive(parts) then
            parts.weapon_type,parts.validated_epoch=weapon_type,state.epoch
            weapon_part_cache[addr]=parts;state.weapon_misses[addr]=nil
            return parts
        end
        state.weapon_misses[addr]={weapon_type=weapon_type,retry_at=now+.02}
    end

    get_cached_weapon_parts = get_cached_weapon_parts_impl
    local api = {
        body_id = state.body_id_of, parts = state.parts, mesh = state.mesh_of,
        weapon_id = weapon_id, weapons = get_cached_weapon_parts,
        invalidate_body_id = state.invalidate_body_id,
    }

    -- 同一帧复用存活检查，跨帧重新识别已销毁或替换的部件。
    function api.begin_frame(epoch) state.epoch = epoch end

    -- 换装后不能继续复用旧网格绑定。
    function api.clear_meshes() state.mesh.by_obj = {} end

    -- 角色离场清理该角色；场景重置清理全部实例引用。
    function api.clear(character)
        if character then
            local key = tostring(character)
            part_cache[key], weapon_part_cache[key] = nil, nil
            state.body_id.by_char[key], state.weapon_misses[key] = nil, nil
        else
            part_cache, weapon_part_cache = {}, {}
            state.body_id.by_char, state.weapon_misses = {}, {}
            state.epoch = nil
        end
        api.clear_meshes()
    end
    return api
end

return Equipment
