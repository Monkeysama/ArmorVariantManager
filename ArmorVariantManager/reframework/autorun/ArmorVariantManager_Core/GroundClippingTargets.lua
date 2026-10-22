-- 陷地修复的角色来源：实例化玩家、菜单展示人偶和过场玩家演员；不按防具名称猜测 NPC。
local GroundClippingTargets = {}

function GroundClippingTargets.new(deps)
    local scene_key, next_scan, models = nil, 0, {}
    local types = {}
    for _, name in ipairs({ "app.HunterDoll", "app.CharacterTimelineEventActorPlayer" }) do
        local definition = sdk.find_type_definition(name)
        if definition then types[name] = definition:get_runtime_type() end
    end
    local transform_type = sdk.find_type_definition("via.Transform")
    local find_joint = transform_type and transform_type:get_method("getJointByName")
    local weapon_type = sdk.find_type_definition("app.Weapon")
    weapon_type = weapon_type and weapon_type:get_runtime_type()
    local weapon_cache = {}

    -- 重新读取组件所属对象，拒绝销毁的组件；还原时允许隐藏对象，避免再次显示后遗留偏移。
    local function model_object(component)
        if not sdk.is_managed_object(component) then return nil end
        if deps.get_game_object then return deps.get_game_object(component, "ground_clipping_model") end
        local object = component:call("get_GameObject")
        if not object or not sdk.is_managed_object(object) then return nil end
        return object
    end

    -- 展示组件可能位于 Mannequin_Hunter 容器；只取最上层的完整人形骨架，不再下探盔甲和武器。
    -- 限制层数与节点数，且同层出现多个候选时放弃，避免把不明确的独立骨架一起抬高。
    local function preview_object(component)
        local owner = model_object(component)
        if not owner or not find_joint then return nil end
        local transform = owner:call("get_Transform")
        local level, visited, budget = transform and { transform } or {}, {}, 64
        for _ = 0, 4 do
            local candidate, children = nil, {}
            for _, node in ipairs(level) do
                local address = node:get_address()
                if not visited[address] then
                    visited[address], budget = true, budget - 1
                    if budget < 0 then return nil end
                    if find_joint:call(node, "root") and find_joint:call(node, "COG") then
                        if candidate then return nil end
                        candidate = node
                    else
                        local child = node:call("get_Child")
                        local siblings = {}
                        while child do
                            local id = child:get_address()
                            if siblings[id] or #children >= 64 then return nil end
                            siblings[id] = true
                            children[#children + 1] = child
                            child = child:call("get_Next")
                        end
                    end
                end
            end
            if candidate then
                local object = model_object(candidate)
                return candidate, object
            end
            level = children
            if #level == 0 then return nil end
        end
    end

    -- 只接收该展示骨架子树中的武器；每次钩子调用前再核验挂点归属，不碰独立展柜或掉落物。
    local function belongs_to(node, skeleton)
        for _ = 0, 5 do
            if not node then return false end
            if node:get_address() == skeleton:get_address() then return true end
            node = node:call("get_Parent")
        end
        return false
    end

    local function preview_weapons(skeleton, resolve)
        if not weapon_type then return {} end
        local id = skeleton:get_address()
        local cached = weapon_cache[id]
        if not cached or os.clock() >= cached.expires then
            cached = { expires = os.clock() + 0.5, weapons = {} }
            weapon_cache[id] = cached
            local queue, visited, index = {{ node = skeleton, depth = 0 }}, {}, 1
            while queue[index] and index <= 64 do
                local item = queue[index]; index = index + 1
                local node, depth = item.node, item.depth
                local address = node:get_address()
                if not visited[address] then
                    visited[address] = true
                    pcall(function()
                        local object = model_object(node)
                        local weapon = object and object:call("getComponent(System.Type)", weapon_type)
                        if weapon then cached.weapons[#cached.weapons + 1] = weapon end
                    end)
                    if depth < 4 then
                        local child, siblings = node:call("get_Child"), {}
                        while child and #queue < 64 do
                            local child_id = child:get_address()
                            if siblings[child_id] then break end
                            siblings[child_id] = true
                            queue[#queue + 1] = { node = child, depth = depth + 1 }
                            child = child:call("get_Next")
                        end
                    end
                end
            end
        end
        local bindings = {}
        for _, weapon in ipairs(cached.weapons) do
            local function valid()
                if not resolve() or not sdk.is_managed_object(weapon) then return false end
                local object = model_object(weapon)
                return object and belongs_to(object:call("get_Transform"), skeleton)
                    and belongs_to(weapon:call("get_WpParent"), skeleton)
            end
            local ok, attached = pcall(valid)
            if ok and attached then
                bindings[#bindings + 1] = { id = weapon:get_address(), valid = valid }
            end
        end
        return bindings
    end

    -- 只扫描两类明确属于玩家展示的组件，每半秒刷新，场景变化立即丢弃旧列表。
    local function scan_models(scene, key)
        if key ~= scene_key then scene_key, models, next_scan, weapon_cache = key, {}, 0, {} end
        if os.clock() < next_scan then return end
        next_scan = os.clock() + 0.5
        local found = {}
        for name, runtime_type in pairs(types) do
            local ok, components = pcall(function() return scene:call("findComponents(System.Type)", runtime_type) end)
            if ok and components then
                local list_ok, list = pcall(function() return components:get_elements() end)
                if list_ok and list then
                    for _, component in ipairs(list) do
                        found[#found + 1] = { component = component,
                            kind = name == "app.HunterDoll" and "preview" or "cutscene" }
                    end
                end
            end
        end
        models = found
    end

    -- 每个来源独立捕获异常，一个远端玩家离开或一个存档模型重建不影响其他骨架。
    return function()
        local scene, key = deps.get_scene()
        if not scene or key == "" then scene_key, models, next_scan, weapon_cache = nil, {}, 0, {}; return {} end
        scan_models(scene, key)
        local targets, by_transform, active_previews = {}, {}, {}
        local function add(character, object, kind, resolve, hunter, actor, ready)
            if not character or not object or object:call("get_Draw") == false then return end
            local transform = object:call("get_Transform")
            if not transform then return end
            local id = transform:get_address()
            local entry = { character = character, kind = kind, resolve = resolve,
                hunter = hunter, actor = actor, id = id, is_ready = ready }
            -- 场景键改变后，连还原旧偏移也不能再读取旧包装对象。
            entry.resolve = function()
                local _, current_key = deps.get_scene()
                if current_key ~= key then return nil end
                return resolve()
            end
            -- 过场演员优先于同一个 GameObject 的战斗角色，避免时间轴重算后再次覆盖抬升。
            local previous = by_transform[id]
            if previous then
                if kind == "cutscene" then
                    -- 普通猎人也可能常驻时间轴组件；保留已经验证的 IK 后入口与骑乘检测。
                    entry.hunter = targets[previous].hunter or entry.hunter
                    targets[previous] = entry
                elseif kind == "local" and targets[previous].kind == "remote" then
                    targets[previous] = entry
                end
            else
                targets[#targets + 1] = entry; by_transform[id] = #targets
            end
            return entry
        end
        local manager = sdk.get_managed_singleton("app.PlayerManager")
        local function add_player(player, primary)
            if not player then return end
            local function resolve()
                if not sdk.is_managed_object(player) then return nil end
                local character = player:call("get_Character")
                if not character or not character:call("get_IsSetUp") then return nil end
                local object = player:call("get_Object")
                return character, object and object:call("get_Transform"), object
            end
            local character, _, object = resolve()
            add(character, object, primary and "local" or "remote", resolve, character)
        end
        if manager then
            pcall(function() add_player(manager:call("getMasterPlayer"), true) end)
            local ok, count = pcall(function() return manager:call("get_InstancedPlayerNum") end)
            if ok and type(count) == "number" then
                for index = 0, count - 1 do
                    pcall(function() add_player(manager:call("getInstancedPlayer", index), false) end)
                end
            end
        end
        for _, model in ipairs(models) do
            pcall(function()
                local component, kind = model.component, model.kind
                -- 还原仍可读取隐藏骨架；是否允许新增偏移另行核验，避免显示回来后残留旧高度。
                local function ready()
                    local owner = model_object(component)
                    return owner and owner:call("get_Draw") ~= false
                        and (kind ~= "preview" or not (component:get_field("_RequiresRootSetup")
                            or component:get_field("_RequiresPartsSetup") or component:get_field("_RequiresWeaponSetup")
                            or component:get_field("_IsHiddenWhileBuilding")))
                end
                if not ready() then return end
                local skeleton = kind == "preview" and preview_object(component) or nil
                if kind == "preview" and not skeleton then return end
                local function resolve()
                    if kind == "preview" then
                        -- 捕获本次识别的骨架，之后只核验归属；列表变化时仍可还原尚未销毁的旧骨架。
                        local owner = model_object(component)
                        local parent = owner and owner:call("get_Transform")
                        local object = parent and model_object(skeleton)
                        local current = object and object:call("get_Transform")
                        if not current or current:get_address() ~= skeleton:get_address() then return nil end
                        for _ = 0, 4 do
                            if current:get_address() == parent:get_address() then return skeleton, skeleton, object end
                            current = current:call("get_Parent")
                            if not current then return nil end
                        end
                        return nil
                    end
                    local object = model_object(component)
                    return component, object and object:call("get_Transform"), object
                end
                local character, _, object = resolve()
                local hunter = kind == "cutscene" and component:get_field("_HunterComp") or nil
                local entry = add(character, object, kind, resolve, hunter, kind == "cutscene" and component or nil, ready)
                if entry and kind == "preview" then
                    active_previews[skeleton:get_address()] = true
                    entry.weapons = preview_weapons(skeleton, entry.resolve)
                end
            end)
        end
        -- 存档切换会替换骨架；及时释放不再使用的武器包装对象，不在同一场景持续积累。
        for id in pairs(weapon_cache) do
            if not active_previews[id] then weapon_cache[id] = nil end
        end
        return targets
    end
end

return GroundClippingTargets
