local Materials = {}

-- 猎人原生隐藏期间只允许关闭网格；菜单演员不受战斗角色的隐藏标记限制。
local function native_allows_enable(character)
    local definition = character:get_type_definition()
    if not definition then return false end
    local name = definition:get_full_name()
    if type(name) ~= "string" or name == "" then return false end
    if name ~= "app.HunterCharacter" then return true end
    local draw_off = character:call("get_IsDrawOff")
    if draw_off == false then return true end
    if draw_off ~= true then return false end
    return character:call("get_IsInAllTent") == false
end

-- 每次应用只读取一次原生显隐，不跨角色或帧缓存。
local function enable_check(character)
    local allowed
    return function()
        if allowed == nil then
            local ok, result = pcall(native_allows_enable, character)
            allowed = ok and result == true
        end
        return allowed
    end
end

-- 防具与武器共用读后写；上下文过滤由调用方提供，不读取 UI 状态。
local function apply_mesh(mesh, data, index, operable, hidden, allow_enable)
    local count = mesh:call("get_MaterialNum") or 0
    if data.mesh_enabled ~= nil then
        local current = mesh:call("get_Enabled")
        if data.mesh_enabled == false and current ~= false then
            mesh:call("set_Enabled", false)
        elseif data.mesh_enabled == true and current ~= true and allow_enable() then
            mesh:call("set_Enabled", true)
        end
    end
    if data.materials then
        for slot = 0, count - 1 do
            local name = mesh:call("getMaterialName", slot)
            if not operable or operable(index, name) then
                local desired = data.materials[name]
                local current = mesh:call("getMaterialsEnable", slot)
                if desired == true and hidden and hidden(index, name) then desired = false end
                if type(desired) == "boolean" and current ~= desired then
                    mesh:call("setMaterialsEnable", slot, desired)
                end
            end
        end
    end
end

function Materials.new(meshes, game_object)
    local instance = {}

    function instance.armor(character, preset, operable, hidden)
        if not character or not preset or not sdk.is_managed_object(character) then return end
        if not game_object(character, "apply_preset_armor") then return end
        local allow_enable = enable_check(character)
        for index = 0, 5 do
            local data = preset[tostring(index)]
            if data then
                for _, mesh in ipairs(meshes.part_meshes(character, index, data)) do
                    apply_mesh(mesh, data, index, operable, hidden, allow_enable)
                end
            end
        end
    end

    function instance.weapon(character, objects, preset, operable)
        if not character or not objects or not preset or not sdk.is_managed_object(character) then return end
        if not game_object(character, "apply_preset_weapon") then return end
        local allow_enable = enable_check(character)
        for index, object in ipairs(objects) do
            if sdk.is_managed_object(object) then
                local alive = pcall(function() return object:call("get_Name") end)
                local data = preset[tostring(index - 1)]
                if alive and data then
                    local mesh = meshes.first(object)
                    if mesh then apply_mesh(mesh, data, index - 1, operable, nil, allow_enable) end
                end
            end
        end
    end

    return instance
end

return Materials
