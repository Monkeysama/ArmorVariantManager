local PortraitModel = {}
local CHANNEL = 4
local LIGHT_HORIZONTAL = math.cos(math.rad(20))
local LIGHT_VERTICAL = math.sin(math.rad(20))
PortraitModel.STAGE_Y = -10000

local function identity(value) return tostring(value:get_address()) end

local function require_native(bridge)
    local api = bridge()
    assert(api and api.portrait_pose_version and api.portrait_pose_version() >= 3,
        "Portrait visibility native module missing; restart with the updated ArmorVariantManager_UI.dll")
    return api
end

-- 仅复制实际猎人的可见子网格，不依赖装备文件名，也不改原网格的材质、骨架或输出掩码。
function PortraitModel.game_adapter(deps)
    deps = deps or {}
    local adapter = {}
    local bridge = deps.bridge or function() return rawget(_G, "avm_bridge") end
    local object_type = assert(sdk.find_type_definition("via.GameObject"))
    local function component(object, name)
        return assert(object:call("createComponent(System.Type)", sdk.typeof(name)), "Portrait component creation failed: " .. name)
    end
    function adapter.inventory(context)
        -- 从实际猎人根节点向下查找，避免每半秒扫描数千个世界网格再逐个回溯父节点。
        -- 枚举节点全部组件，不能用 getComponent 漏掉同一对象上的第二个 Mesh。
        local root = assert(context.actor:call("get_Transform"))
        local queue, visited, cursor = {{ node = root, depth = 0 }}, { [identity(root)] = true }, 1
        local entries, signature = {}, {}
        while queue[cursor] do
            local item = queue[cursor]; cursor = cursor + 1
            local object = item.node:call("get_GameObject")
            local components = object and object:call("get_Valid") and object:call("get_Draw") and object:call("get_Components")
            -- 使用托管数组接口，兼容没有 get_size/get_element 扩展的普通托管包装器。
            for i = 0, components and components:call("get_Length") - 1 or -1 do
                local mesh = components:call("Get(System.Int32)", i)
                if mesh and mesh:get_type_definition():is_a("via.render.Mesh") and mesh:call("get_ReadyToDraw") then
                    -- 资源 holder 是引擎局部对象；这里只保存字符串，副本创建时由原生模块重新取得资源。
                    local asset = mesh:call("getMesh")
                    local asset_path = asset and asset:call("get_ResourcePath")
                    local material = mesh:call("get_Material")
                    local material_path = material and material:call("get_ResourcePath")
                    if asset_path and material_path then
                        assert(#entries < 64, "Portrait mesh count exceeded")
                        entries[#entries + 1] = { source = mesh }
                        signature[#signature + 1] = identity(mesh) .. ":" .. asset_path .. ":" .. material_path
                    end
                end
            end
            if item.depth < 31 then
                local child = item.node:call("get_Child")
                while child do
                    local id = identity(child)
                    assert(not visited[id], "Portrait actor hierarchy cycle")
                    assert(#queue < 20000, "Portrait mesh inventory bound exceeded")
                    visited[id] = true
                    queue[#queue + 1] = { node = child, depth = item.depth + 1 }
                    child = child:call("get_Next")
                end
            end
        end
        table.sort(signature)
        return entries, table.concat(signature, ";")
    end
    function adapter.create(name)
        local object = assert(object_type:get_method("create(System.String)")):call(nil, name)
        assert(object, "Portrait object creation failed")
        -- 托管登记由 userdata 的 GC 统一释放，不能在清理时再次手动消耗同一个计数。
        object:add_ref()
        return object
    end
    function adapter.disable(object)
        local draw_ok, draw_error = pcall(object.call, object, "set_DrawSelf", false)
        local update_ok, update_error = pcall(object.call, object, "set_UpdateSelf", false)
        assert(draw_ok and update_ok, tostring(draw_error or update_error))
    end
    function adapter.enable(object)
        object:call("set_UpdateSelf", true)
        object:call("set_DrawSelf", true)
    end
    function adapter.clone(object, entry)
        local mesh = component(object, "via.render.Mesh")
        local api = require_native(bridge)
        assert(api.portrait_mesh_copy(entry.source:get_address(), mesh:get_address()) == 0, api.portrait_pose_error())
        mesh:call("set_RenderOutputID", CHANNEL)
        mesh:call("set_DrawShadowCast", false)
        entry.copy, entry.copy_mesh = object, mesh
    end
    function adapter.light(object)
        local light = component(object, "via.render.PointLight")
        light:call("set_RenderOutputID", CHANNEL)
        light:call("set_Color", Vector3f.new(1, 1, 1))
        -- System.Single 必须传 Lua 浮点数；整数会按整数 ABI 打包，导致灯光强度实际写成 0。
        light:call("set_Intensity", 60000.0)
        light:call("set_Radius", 8.0)
        light:call("set_ShadowEnable", false)
        object:call("get_Transform"):call("set_Position", Vector3f.new(0, PortraitModel.STAGE_Y, 0))
    end
    -- 只照亮远端舞台的有限光源；输出掩码不能隔绝无限方向光对世界的影响。
    function adapter.light_follow(object, context)
        local forward = context.actor:call("get_Transform"):call("get_AxisZ")
        local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
        assert(length > 0.001, "Invalid portrait lighting facing")
        object:call("get_Transform"):call("set_Position", Vector3f.new(
            forward.x / length * LIGHT_HORIZONTAL * 3.0,
            PortraitModel.STAGE_Y + 0.9 + LIGHT_VERTICAL * 3.0,
            forward.z / length * LIGHT_HORIZONTAL * 3.0))
    end
    -- 亮度仅写入自有点光；由控制更新按变更提交，不在每帧重复设置。
    function adapter.light_intensity(object, value)
        local light = assert(object:call("getComponent(System.Type)", sdk.typeof("via.render.PointLight")))
        light:call("set_Intensity", 60000.0 * value)
    end
    function adapter.ready(entries)
        for _, entry in ipairs(entries) do
            if not entry.copy_mesh:call("get_ReadyToDraw") then return false end
        end
        return true
    end
    function adapter.batch(entries)
        local st, ct, sj, cj, sm, cm = {}, {}, {}, {}, {}, {}
        for _, entry in ipairs(entries) do
            local source = entry.source:call("get_GameObject"):call("get_Transform")
            local copy = entry.copy:call("get_Transform")
            st[#st + 1], ct[#ct + 1] = source:get_address(), copy:get_address()
            sm[#sm + 1], cm[#cm + 1] = entry.source:get_address(), entry.copy_mesh:get_address()
            local joints = assert(source:call("get_Joints"))
            assert(#sj + joints:get_size() <= 8192, "Portrait skeleton bound exceeded")
            for i = 0, joints:get_size() - 1 do
                local joint = assert(joints:get_element(i))
                local target = assert(copy:call("getJointByName(System.String)", joint:call("get_Name")), "Portrait joint mismatch")
                sj[#sj + 1], cj[#cj + 1] = joint:get_address(), target:get_address()
            end
        end
        return st, ct, sj, cj, sm, cm
    end
    function adapter.offset(context)
        local root = context.actor:call("get_Transform"):call("get_Position")
        return -root.x, PortraitModel.STAGE_Y - root.y, -root.z
    end
    -- 与相机共用销毁边界语义：对象已退出托管堆时，不能再调用它的 get_Valid。
    function adapter.valid(object) return sdk.is_managed_object(object) and object:call("get_Valid") == true end
    function adapter.destroy(object)
        assert(object_type:get_method("destroy(via.GameObject)")):call(nil, object)
    end
    return adapter
end

-- 装备变化先停旧副本并确认销毁，再重建；每次更新最多创建两个网格，避免一次性构造整套装备。
function PortraitModel.new(deps)
    deps = deps or {}
    local bridge = deps.bridge or function() return rawget(_G, "avm_bridge") end
    local adapter, clock = deps.adapter or PortraitModel.game_adapter({ bridge = bridge }), deps.clock or os.clock
    local self = { state = "idle" }
    local objects, entries, signature, key, cursor, next_inventory, deadline = {}, {}, nil, nil, 1, 0, 0
    local bound, rebuild, cleanup_failed, failed_reference = false, false, false, nil
    local light_intensity, applied_intensity = 1.0, nil
    local refresh_fps, next_sync = 0, nil
    local camera_anchor
    -- 只返回已同步的自有骨架，绝不把预览相机挂到世界猎人上；每次重建重新查找。
    function self.camera_anchor()
        if self.state ~= "ready" or rebuild then return nil end
        if camera_anchor ~= nil then return camera_anchor or nil end
        for _, entry in ipairs(entries) do
            local transform = entry.copy:call("get_Transform")
            local joint = transform:call("getJointByName(System.String)", "COG")
            if joint then
                camera_anchor = { transform = transform, joint = joint }
                return camera_anchor
            end
        end
        -- 无 COG 的自定义骨架保留原有世界坐标取景，不因新增绑定功能失去预览。
        camera_anchor = false
        return nil
    end
    function self.configure(settings)
        light_intensity = settings and settings.light_intensity or 1.0
        -- 正式入口传入规范化选项；旧的直接调用者未配置刷新率时仍逐帧同步。
        local fps = settings and settings.refresh_fps or 0
        if fps ~= refresh_fps then refresh_fps, next_sync = fps, nil end
    end
    local function native()
        return require_native(bridge)
    end
    local function own(name)
        local object = adapter.create(name)
        objects[#objects + 1] = object
        adapter.disable(object)
        return object
    end
    function self.poll()
        if cleanup_failed then error("Portrait mesh cleanup failed; references retained") end
        if self.state ~= "destroying" then return end
        for _, object in ipairs(objects) do
            if adapter.valid(object) then
                if clock() >= deadline then cleanup_failed = true; error("Portrait mesh destruction timeout; references retained") end
                return
            end
        end
        for i = #objects, 1, -1 do
            local object = objects[i]
            objects[i] = nil
            if adapter.release then
                local ok, err = pcall(adapter.release, object)
                if not ok then cleanup_failed, failed_reference = true, object; error(err) end
            end
        end
        entries, signature, key, self.state = {}, nil, nil, "idle"
    end
    function self.stop()
        if cleanup_failed then error("Portrait mesh cleanup failed; references retained") end
        if self.state == "destroying" then self.poll(); return end
        -- 相机必须先解除父子关系，避免销毁副本时连带销毁仍由控制器管理的相机。
        if deps.before_stop then deps.before_stop() end
        camera_anchor = nil
        -- 先释放原生批处理持有的骨骼引用，保证销毁后不会再次向旧副本写姿态。
        if bound then native().portrait_pose_clear(); bound = false end
        local ok, err = pcall(function()
            for _, object in ipairs(objects) do
                if adapter.valid(object) then adapter.disable(object) end
            end
            for _, object in ipairs(objects) do
                if adapter.valid(object) then adapter.destroy(object) end
            end
        end)
        if not ok then cleanup_failed = true; error(err) end
        rebuild, self.state, deadline = false, "destroying", clock() + 3
        self.poll()
    end
    function self.current(context)
        self.poll()
        if self.state == "destroying" then return false end
        if key and key ~= context.key or rebuild then self.stop(); return false end
        if self.state == "idle" then
            native()
            entries, signature = adapter.inventory(context)
            if #entries == 0 then return false end
            key, cursor, self.state, deadline = context.key, 1, "building", clock() + 5
            adapter.light(own("AVM_PortraitLight"))
            applied_intensity = 1.0
        end
        if applied_intensity ~= light_intensity and adapter.light_intensity then
            adapter.light_intensity(objects[1], light_intensity)
            applied_intensity = light_intensity
        end
        if self.state == "building" then
            assert(clock() < deadline, "Portrait mesh setup timeout")
            for _ = 1, 2 do
                if cursor > #entries then break end
                adapter.clone(own("AVM_PortraitMesh_" .. cursor), entries[cursor])
                cursor = cursor + 1
            end
            if cursor <= #entries then return false end
            local _, current_signature = adapter.inventory(context)
            if signature ~= current_signature then self.stop(); return false end
            if adapter.ready and not adapter.ready(entries) then return false end
            local api = native()
            bound = true
            assert(api.portrait_pose_bind(adapter.batch(entries)) == 0, api.portrait_pose_error())
            self.state, next_inventory = "ready", clock() + 0.5
            next_sync = nil
            if not self.sync(context) then return false end
            for _, object in ipairs(objects) do adapter.enable(object) end
        elseif clock() >= next_inventory then
            next_inventory = clock() + 0.5
            local _, current_signature = adapter.inventory(context)
            if signature ~= current_signature then self.stop(); return false end
        end
        return self.state == "ready"
    end
    -- LateUpdateBehavior 末段同步最终姿态、材质、部件和网格启用状态，只写自有副本。
    function self.sync(context)
        if self.state ~= "ready" or rebuild then return false end
        -- 以固定时间网格限频，只取最新姿态；卡顿后跳过错过的时隙，不补算历史帧。
        if refresh_fps > 0 then
            local now, interval = clock(), 1 / refresh_fps
            if next_sync and now + 1e-9 < next_sync then return true end
            next_sync = next_sync and next_sync + interval * math.max(1, math.floor((now - next_sync + 1e-9) / interval) + 1)
                or now + interval
        end
        local api = native()
        local result = api.portrait_pose_sync(adapter.offset(context))
        assert(result >= 0, api.portrait_pose_error())
        if result == 1 then
            rebuild = true
            for _, object in ipairs(objects) do if adapter.valid(object) then adapter.disable(object) end end
            return false
        end
        if adapter.light_follow then adapter.light_follow(objects[1], context) end
        return true
    end
    function self.shutdown()
        self.stop()
        if self.state == "destroying" then
            for i = #objects, 1, -1 do
                if adapter.release then adapter.release(objects[i]) end
                objects[i] = nil
            end
            entries, key, signature, self.state = {}, nil, nil, "idle"
        end
    end
    return self
end

return PortraitModel
