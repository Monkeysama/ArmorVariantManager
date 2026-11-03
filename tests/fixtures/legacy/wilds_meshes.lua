-- 冻结自 5d09c01 的荒野实际入口，供模块拆分对照。
return function(env)
    return assert(load([=[
local character_mesh_cache = {}
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
        local ok_child_obj, child_obj = (function() local go = safe_get_game_object(child, "mesh_recursive_child") if not go then return false end return true, go end)()
        if ok_child_obj and child_obj then
            collect_mesh_components_recursive(child_obj, result, visited)
        end
        ok_child, child = pcall(function() return child:call("get_Next") end)
    end
end

-- 辅助函数：尝试从 GameObject 及其子节点中获取第一个 Mesh 组件
-- 保留这个旧接口，武器和其他旧逻辑仍可使用；防具会调用下面的批量收集接口。
local function get_mesh_component_recursive(game_obj)
    local meshes = {}
    collect_mesh_components_recursive(game_obj, meshes, {})
    return meshes[1]
end

-- 前置声明：批量部位查找函数需要在无材料匹配时调用旧部位解析逻辑。
local get_character_part

-- 辅助函数：判断对象是否为独立角色脸部对象。
local function is_player_face_object(game_obj)
    if not game_obj then return false end
    local ok_name, name = pcall(function() return game_obj:call("get_Name") end)
    return ok_name and name == "Player_Face"
end

-- 辅助函数：获取角色对象树中的全部 Mesh，并在短时间内缓存结果
-- 装备切换期间对象会重建，短 TTL 可以兼顾新对象发现和每帧性能。
local CHARACTER_MESH_CACHE_TTL = 0.25
local function get_all_character_meshes(character)
    if not character or not sdk.is_managed_object(character) then return {} end
    local ok_root, root = (function() local go = safe_get_game_object(character, "all_character_meshes_root") if not go then return false end return true, go end)()
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

-- 辅助函数：按预设中的材料名定位一个防具部位的全部候选 Mesh
-- 旧 JSON 没有记录 GameObject 名称，只记录材料名，因此无需改变 JSON 结构即可兼容改名 PFB。
-- 优先沿用游戏的 getParts 部位结果，材质匹配只作为改名 PFB 的兜底。
-- 只返回防具 Mesh；Player_Face 是角色脸部对象，不属于任何防具部件。
local function get_character_part_meshes(character, part_index, part_data)
    -- 1. 优先使用原有部位对象路径，避免全角色材质匹配把其他部位误判为当前部位。
    local part_obj = get_character_part(character, part_index)
    if part_obj and not is_player_face_object(part_obj) then
        local part_meshes = {}
        collect_mesh_components_recursive(part_obj, part_meshes, {})
        local armor_meshes = {}
        for _, mesh in ipairs(part_meshes) do
            local mesh_game_obj = safe_get_game_object(mesh, "mesh_collect_armor")
            if not (mesh_game_obj and is_player_face_object(mesh_game_obj)) then
                table.insert(armor_meshes, mesh)
            end
        end
        if #armor_meshes > 0 then
            return armor_meshes
        end
    end

    -- 2. getParts 不可用时，按预设材料名在角色树中定位改名后的 Mesh。
    local all_meshes = get_all_character_meshes(character)
    if #all_meshes == 0 then return {} end

    local material_defs = part_data and part_data.materials
    if material_defs and next(material_defs) then
        local best_count = 0
        local best_meshes = {}
        for _, mesh in ipairs(all_meshes) do
            local count = 0
            local is_player_face = false
            local mesh_game_obj = safe_get_game_object(mesh, "mesh_collect_face")
            if mesh_game_obj then is_player_face = is_player_face_object(mesh_game_obj) end
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

-- 辅助函数：获取角色的指定部位对象 (兼容 Transform 模式)
get_character_part = function(character, part_index)
    if not character then return nil end
    local status, part_obj = pcall(function() return character:call("getParts", part_index) end)
    if status and part_obj then return part_obj end
    -- 2. 回退模式：遍历 Transform 子节点并根据名称后缀匹配
    local game_obj = safe_get_game_object(character, "get_character_part")
    if game_obj then
        local transform = game_obj:call("get_Transform")
        if transform then
            local parts_map = {} -- Key: part_index, Value: { obj, name }
            local child = transform:call("get_Child")
            while child do
                local child_obj_ok, child_obj = (function() local go = safe_get_game_object(child, "part_fallback_child") if not go then return false end return true, go end)()
                if child_obj_ok and child_obj then
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


return {part=get_character_part, part_meshes=get_character_part_meshes, first=get_mesh_component_recursive, all=get_all_character_meshes}
]=], "legacy-wilds_meshes", "t", env))()
end
