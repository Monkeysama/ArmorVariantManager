-- 冻结自 5d09c01 的荒野实际入口，供模块拆分对照。
return function(env)
    return assert(load([=[
local applied_parts_cache, applied_weapon_cache = {}, {}
local function read_native_hunter_visibility(character)
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

-- 读取失败仅拒绝这一次开启，不修改角色状态；下一次应用重新判断。
local function native_hunter_allows_mesh_enable(character)
    local ok, allowed = pcall(read_native_hunter_visibility, character)
    return ok and allowed == true
end

-- 辅助函数：应用指定预设到指定角色的防具
local function apply_preset_to_armor(character, preset_data, ignore_context, force_apply)
    if not character or not preset_data then return end
    -- 增加有效性检查，防止在对象销毁后访问
    if not sdk.is_managed_object(character) then return end
    local native_enable_allowed -- 同次应用的各部位/多 Mesh 共用一次读取，不跨帧缓存。
    local char_go = safe_get_game_object(character, "apply_preset_armor")
    if not char_go then return end
    local char_addr = tostring(char_go)
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end
    if not applied_parts_cache[char_addr] then applied_parts_cache[char_addr] = {} end
    for i = 0, 5 do
        local part_data = preset_data[tostring(i)]
        if part_data then
            -- 通过预设材料名定位 Mesh，兼容 PFB 改名后 getParts 无法识别部位的情况。
            local mesh_components = get_character_part_meshes(character, i, part_data)
            for _, mesh_component in ipairs(mesh_components) do
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
                            if cur_en ~= true then
                                if native_enable_allowed == nil then
                                    native_enable_allowed = native_hunter_allows_mesh_enable(character)
                                end
                                if native_enable_allowed then mesh_component:call("set_Enabled", true) end
                            end
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
                                    -- 角色合成结果已含全局锁；仅 UI 局部编辑读取本地选择
                                    if not ignore_context and is_globally_hidden(i, mat_name) then
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

-- 辅助函数：应用指定预设到指定角色的武器
local function apply_preset_to_weapon(character, weapon_objs, preset_data, ignore_context, force_apply)
    if not character or not weapon_objs or not preset_data then return end
    if not sdk.is_managed_object(character) then return end
    local native_enable_allowed -- 武器与防具遵守相同的原生显隐限制。
    local char_go = safe_get_game_object(character, "apply_preset_weapon")
    if not char_go then return end
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
                                 if cur_en ~= true then
                                     if native_enable_allowed == nil then
                                         native_enable_allowed = native_hunter_allows_mesh_enable(character)
                                     end
                                     if native_enable_allowed then mesh_component:call("set_Enabled", true) end
                                 end
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


return {armor=apply_preset_to_armor, weapon=apply_preset_to_weapon}
]=], "legacy-wilds_materials", "t", env))()
end
