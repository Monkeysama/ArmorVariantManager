local Finder = {}

-- 只查找并返回候选配置；应用层负责导入、保存和刷新界面。
function Finder.new(meshes, equipment, files)
    local get_character_weapon_id = equipment.weapon_id
    local get_character_part = meshes.part
    local get_mesh_component_recursive = meshes.first
    local safe_json_load, fs = files.load, files.fs
    local function is_weapon_id(id)
        return type(id) == "string" and (id:match("^wp%d%d") ~= nil or id:match("^it%d%d%d%d") ~= nil)
    end
    return function(target_body_id, character)
        if not target_body_id then return nil, "No Body ID" end
        if not character or not sdk.is_managed_object(character) then return nil, "No Character" end
        local is_weapon_target = is_weapon_id(target_body_id)
        local current_mats = {}
        local current_weapon_mats = {}

        -- 防具读取身体部位材质；武器分别读取各部件材质，避免跨类型匹配。
        if is_weapon_target then
            local current_weapon_id, weapon_objs = get_character_weapon_id(character)
            if current_weapon_id ~= target_body_id or not weapon_objs or #weapon_objs == 0 then
                return nil, "Weapon not found"
            end
            for index, weapon_obj in ipairs(weapon_objs) do
                local mesh = get_mesh_component_recursive(weapon_obj)
                if mesh then
                    local mats = {}
                    local mat_count = mesh:call("get_MaterialNum") or 0
                    for material_index = 0, mat_count - 1 do
                        local name = mesh:call("getMaterialName", material_index)
                        if name then mats[name] = true end
                    end
                    if next(mats) then current_weapon_mats[tostring(index - 1)] = mats end
                end
            end
            if not next(current_weapon_mats) then return nil, "No materials on Weapon" end
        else
            local body_part = get_character_part(character, 1) -- 1 is Body
            if not body_part then return nil, "Body part not found" end
            local mesh = get_mesh_component_recursive(body_part)
            if not mesh then return nil, "Mesh not found" end
            local mat_count = mesh:call("get_MaterialNum")
            if not mat_count or mat_count == 0 then return nil, "No materials on Body" end
            for i = 0, mat_count - 1 do
                local name = mesh:call("getMaterialName", i)
                if name then current_mats[name] = true end
            end
        end
        -- 2. 遍历所有 JSON 文件
        if not fs or not fs.glob then return nil, "fs.glob missing" end
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
        if #files == 0 then return nil, "No preset files found" end
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
                local data = safe_json_load(load_path)
                if not data then data = safe_json_load(file) end
                if data and data.presets then
                    -- 获取第一个预设
                    local first_preset = nil
                    for _, preset in pairs(data.presets) do first_preset = preset; break end
                    if is_weapon_target then
                        -- 只匹配武器 ID 文件，并逐部件检查预设材质是否存在于当前武器。
                        local normalized_file = file:gsub("\\", "/")
                        local candidate_id = normalized_file:match("([^/]+)%.json$")
                        local match = candidate_id and is_weapon_id(candidate_id) and first_preset ~= nil
                        local match_count = 0
                        if match then
                            for part_index, part_data in pairs(first_preset) do
                                local preset_mats = part_data and part_data.materials
                                if preset_mats and next(preset_mats) then
                                    local weapon_mats = current_weapon_mats[tostring(part_index)]
                                    if not weapon_mats then match = false; break end
                                    for mat_name, _ in pairs(preset_mats) do
                                        if not weapon_mats[mat_name] then match = false; break end
                                        match_count = match_count + 1
                                    end
                                    if not match then break end
                                end
                            end
                        end
                        if match and match_count > 0 then
                            return data, "Success! Loaded from " .. file
                        end
                    -- 检查防具 Body (1) 的材质匹配度
                    elseif first_preset and first_preset["1"] and first_preset["1"].materials then
                        local preset_mats = first_preset["1"].materials
                        local match = true
                        local match_count = 0
                        for mat_name, _ in pairs(preset_mats) do
                            if not current_mats[mat_name] then match = false; break end
                            match_count = match_count + 1
                        end
                        if match and match_count > 0 then
                            -- 找到匹配！
                            return data, "Success! Loaded from " .. file
                        end
                    end
                end
            end
        end
        return nil, "No matching preset found"
    end
end

return Finder
