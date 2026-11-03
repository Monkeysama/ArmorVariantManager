-- MHR 093c61c：冻结原材质应用与角色缓存。
return function(env)
    return assert(load([====[
local Applied = { by_char = {}, parts_check_interval = 0,
                  -- 旧版状态结构保留；CG 调度统一由 RuntimeScheduler 负责。
                  cg_at = {}, cg_weapon_at = {} }

Applied.binding=Binding
function Applied.bindings_alive(st,kind)
    local bindings=st[kind..'_meshes']
    if not bindings then return false end
    for _,mesh in pairs(bindings) do if not safe_object_alive(mesh) then return false end end
    return st[kind..'_complete']==true
end
function Applied.get(character)
    local addr = tostring(character)
    local st = Applied.by_char[addr]
    if not st then
        st = {}
        Applied.by_char[addr] = st
    end
    return st
end

function Applied.clear()
    Applied.binding.reset()
    Applied.by_char = {}
    Applied.cg_at = {}
    Applied.cg_weapon_at = {}
end

-- 进入/离开过场时清空 CG 节流记录：新一场过场的角色应该立刻拿到差分，
-- 而不是被上一场的节流记录挡住。
function Applied.reset_cg()
    Applied.cg_at = {}
    Applied.cg_weapon_at = {}
end

-- 某个 body_id 的意图变了：所有用这个模型的角色下一轮都要重新应用
function Applied.invalidate_body(body_id)
    if not body_id then return end
    bump_overrides_version(body_id)
    for _, st in pairs(Applied.by_char) do
        if st.armor_body_id == body_id then st.armor_version = nil end
        if st.weapon_id == body_id then st.weapon_version = nil end
    end
end

-- 角色部件被重建（换装 / 模型重建）时，本角色的「已应用」记账必须作废，
-- 否则差分会在换装后静默失效。
-- 返回 true 表示「真的换装了」（调用方据此放弃这一拍的应用，等下一拍用新的 body_id）。
--
-- - v3.1.2 修：**首次见到某个角色**时不能算「换装」。
--   旧实现里 st.parts_sig 从 nil 变成真实签名也会判定为变化 → 调用方直接 return，
--   于是每个新角色（尤其是过场里刚登场的事件主角）都要多等一整轮才拿到差分。
--   首次见面时并不存在「旧 body_id 套到新部件上」的风险，所以直接放行。
function Applied.sync_parts(character, st)
    if not st then return false end
    local parts = PlayerDir.parts(character)
    if not parts then return false end
    if st.parts_sig ~= parts.sig then
        local had_sig = st.parts_sig ~= nil
        st.parts_sig = parts.sig
        st.armor_version = nil
        st.weapon_version = nil
        if had_sig then
            -- 真的换装：body_id 与 mesh 缓存都可能已经过期，一起作废
            PlayerDir.invalidate_body_id(character)
            PlayerDir.mesh.by_obj = {}
            return true
        end
    end
    return false
end

-- ============================================================================
--  应用预设到角色（角色级版本号缓存 + 先读后写）
-- ============================================================================
local apply_preset_to_character = nil
local function apply_preset_to_character_impl(character, preset_data, ignore_context, known_body_id)
    Profiler.count("apply_character_calls")
    if not character or not preset_data then return end
    if not safe_object_alive(character) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end



    -- 获取当前 body_id
    -- known_body_id：调用方（帧循环）刚刚已经算过一次，直接复用即可，
    -- 避免同一次逻辑里对玩家子物体做两遍遍历。
    -- - 兜底这里也走 TTL 缓存，避免内部再遍历一次子物体。
    local body_id = known_body_id or PlayerDir.body_id_of(character)
    if not body_id then return end

    -- 获取当前应该应用的意图值（active_overrides）
    local current_intent = active_overrides[body_id]
    if not current_intent then
        Profiler.count("apply_character_skip_no_intent")
        return
    end

    -- ===== 角色级版本号检查（- 联机的关键：记账按角色，不按模型）=====
    local st = Applied.get(character)
    local current_version = overrides_version[body_id] or 0
    local parts_changed = false
    if not g_is_special_cg and current_version ~= 0
        and st.armor_body_id == body_id and st.armor_version == current_version
        and st.armor_output == preset_data and Applied.bindings_alive(st,"armor") then
        -- - 快路径：版本号一致时先不碰任何托管对象。
        --   部件签名只用来发现「换装 / 模型重建」，没必要每个处理周期都复核一次；
        --   按 Applied.parts_check_interval 限频（默认 0.5 秒）即可。
        --   多人时这一条把「每轮每人 5 次存活检查」直接省掉。
        local now = os.clock()
        if (now - (st.parts_checked_at or 0)) < Applied.parts_check_interval then
            Profiler.count("apply_character_skip_version")
            return
        end
        st.parts_checked_at = now
        parts_changed = Applied.sync_parts(character, st)
        if not parts_changed
            and st.armor_body_id == body_id and st.armor_version == current_version
        and st.armor_output == preset_data and Applied.bindings_alive(st,"armor") then
            Profiler.count("apply_character_skip_version")
            return
        end
    else
        parts_changed = Applied.sync_parts(character, st)
    end
    if parts_changed then
        -- 模型刚换：这一拍不要拿旧 body_id 的意图往新部件上套，等下一拍用新的 body_id 处理
        Profiler.count("apply_character_skip_parts_changed")
        return
    end
    st.armor_meshes,st.armor_complete={},true
    st.armor_output = preset_data
    st.armor_body_id = body_id
    st.armor_version = current_version
    st.parts_checked_at = os.clock()

    Profiler.count("apply_character_applied")
    local parts = PlayerDir.parts(character)
    for i = 0, 4 do
        local part_obj = parts and parts[i] or nil
        if part_obj and safe_object_alive(part_obj) then
            local part_data = preset_data[tostring(i)]
            if part_data then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    TransformManager.capture_mesh(body_id, tostring(i), mesh_component, part_data, SceneObject.call)
                    st.armor_meshes[i]=mesh_component
                    local applied=Applied.binding.apply(mesh_component,part_data,
                        not ignore_context and function(name) return is_material_in_current_context(i,name) end or nil,
                        preset_data~=st.desired_armor and
                            function(name,enabled) return enabled and not is_globally_hidden(i,name) end or nil)
                    if not applied then st.armor_complete=false end
                else
                    st.armor_complete=false
                end
            end
        end
    end
end
apply_preset_to_character = function(character, preset_data, ignore_context, known_body_id)
    local t0 = Profiler.begin("apply_character")
    apply_preset_to_character_impl(character, preset_data, ignore_context, known_body_id)
    Profiler.finish("apply_character", t0)
end

-- ============================================================================
-- 应用预设到武器（角色级版本号缓存 + 先读后写）
-- character：目标角色，可选。旧调用点不带它时回退到主角。
-- ============================================================================
local apply_preset_to_weapon = nil
local function apply_preset_to_weapon_impl(weapon_parts, preset_data, ignore_context, body_id, character)
    Profiler.count("apply_weapon_calls")
    if not weapon_parts or not preset_data then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end

    -- 使用传入的 body_id，不再调用 get_primary_body_id
    if not body_id then return end



    local current_intent = active_overrides[body_id]
    if not current_intent then
        Profiler.count("apply_weapon_skip_no_intent")
        return
    end

    -- 角色级记账（旧调用点不传 character 时，按主角记账，语义与原来一致）
    local target = character
    if not (target and safe_object_alive(target)) then
        target = get_primary_player()
    end
    local st = nil
    if target then
        st = Applied.get(target)
        if Applied.sync_parts(target, st) then
            -- 模型刚换：等下一拍用新的武器/防具标识处理
            Profiler.count("apply_weapon_skip_parts_changed")
            return
        end
    end

    local current_version = overrides_version[body_id] or 0
    if not g_is_special_cg and st and current_version ~= 0
        and st.weapon_id == body_id and st.weapon_version == current_version
        and st.weapon_output == preset_data and Applied.bindings_alive(st,"weapon") then
        Profiler.count("apply_weapon_skip_version")
        return
    end
    if st then
        st.weapon_meshes,st.weapon_complete={},true
        st.weapon_output = preset_data
        st.weapon_id = body_id
        st.weapon_version = current_version
    end

    Profiler.count("apply_weapon_applied")
    for i, part_obj in ipairs(weapon_parts) do
        if part_obj and safe_object_alive(part_obj) then
            local part_data = preset_data[tostring(i - 1)]
            if part_data then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    TransformManager.capture_mesh(body_id, tostring(i - 1), mesh_component, part_data, SceneObject.call)
                    if st then st.weapon_meshes[i]=mesh_component end
                    local applied=Applied.binding.apply(mesh_component,part_data,
                        not ignore_context and function(name) return is_material_in_current_context(i-1,name) end or nil)
                    if st and not applied then st.weapon_complete=false end
                elseif st then
                    st.weapon_complete=false
                end
            end
        end
    end
end
apply_preset_to_weapon = function(weapon_parts, preset_data, ignore_context, body_id, character)
    local t0 = Profiler.begin("apply_weapon")
    apply_preset_to_weapon_impl(weapon_parts, preset_data, ignore_context, body_id, character)
    Profiler.finish("apply_weapon", t0)
end


return {armor=apply_preset_to_character,weapon=apply_preset_to_weapon,state=Applied}
]====], "legacy-rise-materials", "t", env))()
end
