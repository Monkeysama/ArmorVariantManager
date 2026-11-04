local PortraitCamera = {}
local USER = "ArmorVariantManager/Portrait/portrait_resources.user"
local PREFAB = "ArmorVariantManager/Portrait/portrait_camera.pfb"
local TARGET = "ArmorVariantManager/Portrait/portrait.rtex"
-- RenderOutputID 是位掩码，不是通道序号：第三路 Tertiary 的值为 4，不能用 Primary|Secondary 的 3。
local CHANNEL_INDEX = 2
local CHANNEL = 1 << CHANNEL_INDEX
local LEGACY_VIEW = { distance = 3.0, horizontal = 0.0, vertical = 0.0 }

-- 镜头选项独立于防具预设；旧配置使用默认取景，未知字段原样保留。
function PortraitCamera.settings(value)
    local result = {}
    if type(value) == "table" then
        for key, entry in pairs(value) do result[key] = entry end
    end
    for key, bounds in pairs({ distance = { 2.8, 1.0, 6.0 },
        horizontal = { 0.0, -1.5, 1.5 }, vertical = { 0.0, -1.5, 1.5 }, light_intensity = { 1.0, 0.0, 2.0 } }) do
        local number = result[key]
        if type(number) ~= "number" or number ~= number or math.abs(number) == math.huge then number = bounds[1] end
        result[key] = math.max(bounds[2], math.min(bounds[3], number)) + 0.0
    end
    if result.refresh_fps ~= 0 and result.refresh_fps ~= 30 and result.refresh_fps ~= 60 then result.refresh_fps = 30 end
    return result
end

local function address(object)
    return object and tostring(object:get_address()) or ""
end

-- 适配层管理自有相机和副本，并在普通场景临时排除公共 GI 的预览通道；不改其他输出。
function PortraitCamera.game_adapter()
    local adapter = {}
    local model
    local attachment
    local isolated_gi = {}
    -- 换装、关闭和场景切换均在副本销毁之前解绑；失败时保留状态供现有清理错误路径处理。
    local function detach()
        if not attachment then return end
        if sdk.is_managed_object(attachment.camera) then
            attachment.camera:call("set_ParentJoint", "")
            attachment.camera:call("set_Parent", nil)
        end
        attachment = nil
    end
    local scene_type = assert(sdk.find_type_definition("via.SceneManager"))
    local renderer_type = assert(sdk.find_type_definition("via.render.Renderer"))
    local function scene_get(name)
        local manager = assert(sdk.get_native_singleton("via.SceneManager"))
        return sdk.call_native_func(manager, scene_type, name)
    end
    local function renderer_get(name)
        return assert(renderer_type:get_method(name)):call(nil)
    end
    local function component(object, name)
        return assert(object:call("getComponent(System.Type)", sdk.typeof(name)), "Missing portrait component: " .. name)
    end
    local function vector(x, y, z)
        for _, value in ipairs({ x, y, z }) do
            assert(type(value) == "number" and value == value and math.abs(value) < math.huge, "Invalid portrait position")
        end
        return Vector3f.new(x, y, z)
    end

    -- 菜单演员与世界猎人不是同一对象；普通场景只接受 MasterPlayer 的有效角色。
    function adapter.context()
        if scene_get("get_Loading") then return nil end
        local scene, view = scene_get("get_CurrentScene"), scene_get("get_MainView")
        local primary = view and view:call("get_PrimaryCamera")
        if not scene or not primary then return nil end
        local manager = sdk.get_managed_singleton("app.CameraManager")
        local system = manager and manager:call("get_Charamake")
        local actor
        if system and system:call("isActive") then
            local argument = system:call("getArgument(System.Int32)", 0)
            actor = argument and argument:get_field("GameObject")
            if not actor or not actor:call("get_Valid")
                or not actor:call("get_Name"):match("^CharaMake_Hunter") then return nil end
        else
            local players = sdk.get_managed_singleton("app.PlayerManager")
            local info = players and players:call("getMasterPlayer")
            if not info or not info:call("get_CharacterValid") then return nil end
            actor = info:call("get_Object")
            if not actor or not actor:call("get_Valid") then return nil end
        end
        return { key = address(scene) .. ":" .. address(primary) .. ":" .. address(actor), actor = actor,
            scene = scene, menu = system and system:call("isActive") == true }
    end

    -- 使用现有可用通道；周期检查所有加载场景，发现其他输出占用时让本相机退让。
    function adapter.channel_free(owned)
        if renderer_get("get_RenderOutputIDCount") <= CHANNEL_INDEX then return false end
        local scenes = assert(scene_get("get_Scenes"), "Scene inventory unavailable")
        assert(scenes:get_size() <= 64, "Scene inventory bound exceeded")
        for i = 0, scenes:get_size() - 1 do
            local scene = assert(scenes:get_element(i), "Stale scene inventory")
            local outputs = assert(scene:call("findComponents(System.Type)", sdk.typeof("via.render.RenderOutput")))
            assert(outputs:get_size() <= 256, "Output inventory bound exceeded")
            for j = 0, outputs:get_size() - 1 do
                local output = assert(outputs:get_element(j), "Stale output inventory")
                local object = assert(output:call("get_GameObject"))
                if not object:call("get_Valid") then return false end
                if (output:call("get_RenderOutputID") & CHANNEL) ~= 0 and address(object) ~= address(owned) then return false end
            end
        end
        return true
    end

    -- 公共天空 GI 的 All 掩码包含远端舞台；仅借用预览位，菜单演员保留原有照明。
    function adapter.isolate_gi(context)
        if context.menu then return end
        local scenes = assert(scene_get("get_Scenes"), "Scene inventory unavailable")
        assert(scenes:get_size() <= 64, "Scene inventory bound exceeded")
        for i = 0, scenes:get_size() - 1 do
            local scene = assert(scenes:get_element(i), "Stale scene inventory")
            local components = assert(scene:call("findComponents(System.Type)", sdk.typeof("via.render.DynamicProbeGI")))
            for j = 0, components:call("get_Length") - 1 do
                local gi = assert(components:call("Get(System.Int32)", j), "Stale GI inventory")
                if adapter.valid(gi) then
                    local mask = gi:call("get_RenderOutputID")
                    if (mask & CHANNEL) ~= 0 then
                        -- 写入前登记，部分失败也能由停止路径归还此位。
                        isolated_gi[address(gi)] = gi
                        gi:call("set_RenderOutputID", mask & ~CHANNEL)
                        assert(gi:call("get_RenderOutputID") == (mask & ~CHANNEL), "Portrait GI isolation readback mismatch")
                    end
                end
            end
        end
    end
    -- 只归还本次移除的位，保留其他输出的合法变化；一个组件失败不能跳过其余恢复。
    function adapter.restore_gi()
        local failure
        for key, gi in pairs(isolated_gi) do
            local ok, err = pcall(function()
                if adapter.valid(gi) then
                    local mask = gi:call("get_RenderOutputID")
                    if (mask & CHANNEL) == 0 then
                        gi:call("set_RenderOutputID", mask | CHANNEL)
                        assert(gi:call("get_RenderOutputID") == (mask | CHANNEL), "Portrait GI restore readback mismatch")
                    end
                end
            end)
            if ok then isolated_gi[key] = nil else failure = failure or err end
        end
        if failure then error(failure) end
    end

    function adapter.load()
        -- 工厂按指定类型创建并按路径缓存对象；不能用基类替代 USER 的真实根类型。
        local resource = assert(sdk.create_userdata("app.user_data.CameraManagerSetting", USER), "Portrait USER unavailable")
        local typename = resource:get_type_definition():get_full_name()
        assert(typename == "app.user_data.CameraManagerSetting", "Unexpected portrait USER: " .. typename .. "; " .. USER)
        return resource
    end
    function adapter.prefab(resource)
        -- USER 已创建不等于引用字段已反序列化；未就绪时由加载状态继续等待。
        local prefab = resource:get_field("_FacilityRenderCameraPrefab")
        if not prefab then return nil end
        assert(prefab:get_type_definition():get_full_name() == "via.Prefab", "Unexpected portrait prefab type")
        assert(prefab:call("get_ResourcePath") == PREFAB, "Unexpected portrait prefab path")
        return prefab
    end
    function adapter.ready(prefab) return prefab:call("get_Ready") == true end
    function adapter.instantiate(prefab)
        local object = assert(prefab:call("instantiate(via.vec3)", vector(0, 0, 0)), "Portrait instantiate failed")
        -- 将新建的局部对象纳入 Lua 托管；add_ref 是幂等登记，不是可再手动扣除的额外引用。
        object:add_ref()
        return object
    end
    -- destroy 后托管身份可能已经撤销；先检查宿主对象边界，不能向已销毁对象反射调用 get_Valid。
    function adapter.valid(object) return sdk.is_managed_object(object) and object:call("get_Valid") == true end
    function adapter.disable(object)
        local draw_ok, draw_error = pcall(object.call, object, "set_DrawSelf", false)
        local update_ok, update_error = pcall(object.call, object, "set_UpdateSelf", false)
        assert(draw_ok and update_ok, tostring(draw_error or update_error))
    end
    function adapter.prepare(object)
        assert(object:call("get_Name") == "AVM_PortraitCamera", "Unexpected portrait object")
        if object:call("get_UpdateSelf") or object:call("get_DrawSelf") then
            adapter.disable(object)
            error("Portrait prefab must start inactive")
        end
        local output = component(object, "via.render.RenderOutput")
        local camera = component(object, "via.Camera")
        local target = assert(output:call("get_RenderTarget"))
        assert(target:call("get_ResourcePath") == TARGET, "Unexpected portrait target")
        assert(output:call("get_RenderOutputID") == 2, "Unexpected prefab channel")
        output:call("set_RenderOutputID", CHANNEL)
        -- 反射参数按 Lua 数字类型打包，System.Single 不能使用整数字面量。
        camera:call("set_FOV", 40.0)
        camera:call("set_AspectRatio", 220 / 240)
        camera:call("set_FarClipPlane", 10.0)
    end
    function adapter.follow(object, context, settings)
        settings = settings or LEGACY_VIEW
        local anchor = not context.menu and model and model.camera_anchor()
        if anchor and attachment and attachment.anchor == anchor
            and attachment.distance == settings.distance and attachment.horizontal == settings.horizontal
            and attachment.vertical == settings.vertical then return end
        local transform = assert(context.actor:call("get_Transform"))
        local position, forward = transform:call("get_Position"), transform:call("get_AxisZ")
        if not context.menu then
            -- 普通世界的网格掩码与猎人重叠，改拍远处的自有显示副本，避免把地图和 HUD 带入卡片。
            position = vector(0, require("ArmorVariantManager_Core.Games.Wilds.PortraitModel").STAGE_Y, 0)
        end
        local camera = assert(object:call("get_Transform"))
        if anchor then
            if not attachment or attachment.anchor ~= anchor then
                detach()
                -- 用首次同步后的 COG 坐标系校准原有取景，保留不同模型的骨骼朝向和缩放。
                attachment = { camera = camera, anchor = anchor, forward = forward,
                    inverse = anchor.joint:call("get_WorldMatrix"):inverse(),
                    rotation = anchor.joint:call("get_Rotation"):inverse() }
                camera:call("set_Parent", anchor.transform)
                camera:call("set_ParentJoint", "COG")
            end
            forward = attachment.forward
        end
        local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
        assert(length > 0.001, "Invalid portrait facing")
        local fx, fz = forward.x / length, forward.z / length
        local distance = settings.distance
        -- 左右、上下平移同时移动相机与目标，不改变演员或显示副本的位置。
        local target_position = vector(position.x + fx * distance + fz * settings.horizontal,
            position.y + 1 + settings.vertical, position.z + fz * distance - fx * settings.horizontal)
        -- 相机沿本地 -Z 取景；显式写入世界旋转，不能沿用捏脸中恰好朝向角色的单位旋转。
        local yaw, pitch = math.atan(fx, fz), -math.atan(0.1, distance)
        local cy, sy, cp, sp = math.cos(yaw * 0.5), math.sin(yaw * 0.5), math.cos(pitch * 0.5), math.sin(pitch * 0.5)
        local rotation = Quaternion.new(cy * cp, cy * sp, sy * cp, -sy * sp)
        if anchor then
            local local_position = attachment.inverse * Vector4f.new(target_position.x, target_position.y, target_position.z, 1.0)
            camera:call("set_LocalPosition", vector(local_position.x, local_position.y, local_position.z))
            camera:call("set_LocalRotation", attachment.rotation * rotation)
            attachment.distance, attachment.horizontal, attachment.vertical = distance, settings.horizontal, settings.vertical
        else
            camera:call("set_Position", target_position)
            camera:call("set_Rotation", rotation)
        end
    end
    function adapter.stage_ready(context, settings)
        if context.menu then return true end
        if not model then model = require("ArmorVariantManager_Core.Games.Wilds.PortraitModel").new({ before_stop = detach }) end
        model.configure(settings)
        return model.current(context)
    end
    function adapter.stage_poll() if model then model.poll() end end
    function adapter.stage_stop() if model then model.stop() end end
    function adapter.stage_shutdown() if model then model.shutdown() end end
    function adapter.frame(object, context, settings)
        if not context.menu and (not model or not model.sync(context)) then return false end
        adapter.follow(object, context, settings)
        return true
    end
    function adapter.enable(object)
        object:call("set_UpdateSelf", true)
        object:call("set_DrawSelf", true)
    end
    function adapter.holder(object)
        local output = component(object, "via.render.RenderOutput")
        assert(output:call("get_RenderOutputID") == CHANNEL, "Portrait output channel changed")
        local holder = assert(output:call("get_RenderTarget"))
        assert(holder:call("get_ResourcePath") == TARGET, "Portrait target changed")
        return holder:get_address()
    end
    function adapter.destroy(object)
        assert(sdk.find_type_definition("via.GameObject"):get_method("destroy(via.GameObject)")):call(nil, object)
    end
    return adapter
end

-- 资源加载、启用与延迟销毁统一在游戏帧推进；无可用上下文时保持空闲，不安装额外回调。
function PortraitCamera.new(deps)
    deps = deps or {}
    local adapter, clock = deps.adapter or PortraitCamera.game_adapter(), deps.clock or os.clock
    local self = { independent = true, state = "idle" }
    local resource, prefab, object, context_key, deadline, next_inventory, retry_at
    local settings
    local pending_destroy, cleanup_failed, activated = false, false, false
    local function note(message) if deps.log then deps.log(message) end end

    -- 确认销毁后清除 Lua 强引用，由宿主 GC 回收；非 SDK 适配器仍可提供自己的 release。
    local function poll()
        if not pending_destroy then return end
        if object and adapter.valid(object) then
            if clock() >= deadline then cleanup_failed = true; error("Portrait destruction timeout; references retained") end
            return
        end
        if object then
            if adapter.release then adapter.release(object) end
            object = nil
        end
        prefab = nil
        resource = nil
        pending_destroy, self.state, context_key = false, "idle", nil
        note("Dedicated camera released")
    end
    function self.poll()
        if cleanup_failed then error("Portrait cleanup failed; references retained") end
        local ok, result = pcall(function()
            if adapter.stage_poll then adapter.stage_poll() end
            return poll()
        end)
        if not ok then cleanup_failed = true; error(result) end
        return result
    end
    local function stop()
        if cleanup_failed then return false end
        if pending_destroy then self.poll(); return not pending_destroy end
        activated = false
        if object and adapter.valid(object) then adapter.disable(object) end
        if adapter.stage_stop then adapter.stage_stop() end
        if object then
            if adapter.valid(object) then
                adapter.destroy(object)
            end
            pending_destroy, self.state, deadline = true, "destroying", clock() + 3
            self.poll()
            return not pending_destroy
        end
        prefab, context_key = nil, nil
        resource = nil
        self.state = "idle"
        return true
    end
    function self.stop()
        local ok, result = pcall(stop)
        -- 销毁/模型清理已失败或被锁定时，公共 GI 仍必须独立恢复。
        local gi_ok, gi_error = true, nil
        if adapter.restore_gi then gi_ok, gi_error = pcall(adapter.restore_gi) end
        if not ok then cleanup_failed = true; error(result) end
        if not gi_ok then cleanup_failed = true; error(gi_error) end
        return result
    end
    -- 控制器在游戏更新中交付设置；调整镜头不需要重新创建相机或网格副本。
    function self.configure(value)
        settings = value
    end
    function self.current()
        if cleanup_failed then error("Portrait cleanup failed; reload required") end
        self.poll()
        if pending_destroy then return nil end
        local context = adapter.context()
        if not context or context_key and context.key ~= context_key then self.stop(); return nil end
        if not resource then
            if retry_at and clock() < retry_at then return nil end
            if not adapter.channel_free(nil) then retry_at = clock() + 2; return nil end
            context_key = context.key
            resource = assert(adapter.load())
            self.state, deadline = "loading", clock() + 5
            return nil
        end
        if not object then
            assert(clock() < deadline, prefab and "Portrait prefab load timeout" or "Portrait USER prefab load timeout: " .. USER)
            if not prefab then
                prefab = adapter.prefab(resource)
                if not prefab then return nil end
            end
            if not adapter.ready(prefab) then return nil end
            -- 等待加载期间其他系统可能取得通道，实例化前再次核对。
            if not adapter.channel_free(nil) then self.stop(); retry_at = clock() + 2; return nil end
            object = assert(adapter.instantiate(prefab))
            adapter.prepare(object)
            self.state, next_inventory = "building", clock() + 2
        end
        assert(adapter.valid(object), "Portrait camera invalidated")
        if clock() >= next_inventory then
            next_inventory = clock() + 2
            if not adapter.channel_free(object) then self.stop(); retry_at = clock() + 2; return nil end
            if activated and adapter.isolate_gi then adapter.isolate_gi(context) end
        end
        if adapter.stage_ready and not adapter.stage_ready(context, settings) then
            if activated then adapter.disable(object); activated = false end
            self.state = "building"
            return nil
        end
        adapter.follow(object, context, settings)
        if not activated then
            if adapter.isolate_gi then adapter.isolate_gi(context) end
            adapter.enable(object)
            activated, self.state, deadline = true, "rendering", clock() + 0.1
            note("Dedicated camera enabled")
            return nil
        end
        return clock() >= deadline and object or nil
    end
    -- 动作与装备约束在主更新之后才结束，按最终世界姿态同步自有副本，不能沿用 100ms 的控制轮询。
    function self.frame()
        if not object or not activated or pending_destroy or cleanup_failed then return end
        local context = adapter.context()
        if not context or context.key ~= context_key then return false end
        if adapter.frame then return adapter.frame(object, context, settings) end
        return true
    end
    function self.identity(value) return address(value) end
    function self.holder(value) return adapter.holder(value) end
    function self.reset() retry_at = nil end
    -- VM 关闭前不能阻塞等待下一帧；销毁请求已提交后清空强引用，交由宿主统一回收。
    function self.shutdown()
        self.stop()
        if cleanup_failed then return false end
        if adapter.stage_shutdown then adapter.stage_shutdown() end
        if pending_destroy then
            if object then
                if adapter.release then adapter.release(object) end
                object = nil
            end
            prefab = nil
            resource = nil
            pending_destroy, self.state = false, "idle"
            note("Script reset: owned camera disabled, destruction queued, Lua references released")
        end
        return true
    end
    return self
end

return PortraitCamera
