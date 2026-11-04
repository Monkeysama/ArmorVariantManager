local PortraitPreview = {}
local PortraitCamera = require("ArmorVariantManager_Core.Games.Wilds.PortraitCamera")

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- 正式入口使用自有相机和纹理，菜单头像始终由游戏自己管理。
function PortraitPreview.game_adapter()
    local camera = require("ArmorVariantManager_Core.Games.Wilds.PortraitCamera").new({
        log = function(message) log.info("[AVM Portrait] " .. message) end,
    })
    function camera.output()
        local definition = assert(sdk.find_type_definition("via.render.Renderer"))
        local hdr = assert(definition:get_method("get_HDRMode")):call(nil)
        assert(type(hdr) == "boolean", "Unknown HDR output contract")
        return hdr and 1 or 0, assert(definition:get_method("get_ColorSpace")):call(nil)
    end
    return camera
end

-- 保留已验证的菜单适配器供离线兼容验证；正式入口使用独立相机，不改原生取景参数。
function PortraitPreview.menu_adapter()
    local adapter = {}
    function adapter.current()
        local manager = sdk.get_managed_singleton("app.CameraManager")
        local system = manager and manager:call("get_Charamake")
        local accessor = system and system:get_field("_Accessor")
        if not system or not accessor or not system:call("isActive") or not accessor:call("get_IsActive") then return nil end
        return system
    end
    function adapter.identity(system)
        -- 同一系统可在切换菜单时换掉 accessor/相机参数，不能只比较系统单例地址。
        local accessor = system:get_field("_Accessor")
        local argument = adapter.argument(system)
        return tostring(system:get_address()) .. ":" .. tostring(accessor:get_address()) .. ":" .. tostring(argument:get_address())
    end
    function adapter.holder(system)
        local setting = system:call("getWipeSetting", 1)
        local holder = setting and setting:get_field("_Texture")
        assert(holder and holder:get_type_definition():get_full_name() == "via.render.RenderTargetTextureResourceHolder",
            "Unexpected portrait holder type")
        assert(holder:call("get_ResourcePath") == "GUI/ui_texture/tex_render/rtt010300_01.rtex", "Unexpected portrait texture")
        return holder:get_address()
    end
    function adapter.output()
        local definition = sdk.find_type_definition("via.render.Renderer")
        local hdr = definition and definition:get_method("get_HDRMode")
        local color = definition and definition:get_method("get_ColorSpace")
        assert(hdr and color, "Renderer output getters unavailable")
        local value = hdr:call(nil)
        assert(type(value) == "boolean", "Unknown HDR output contract")
        return value and 1 or 0, color:call(nil)
    end
    function adapter.argument(system)
        local controllers = system:get_field("_WipeCameraController")
        local controller = controllers and controllers:get_element(1)
        local argument = controller and controller:get_field("_Argument")
        assert(argument and argument:get_type_definition():get_full_name() == "app.cCameraParamArgument_FullConst",
            "Unexpected portrait camera argument")
        return argument
    end
    function adapter.read(argument)
        local offset = argument:get_field("AttachOffset")
        return { fov = argument:get_field("FOV"), x = offset.x, y = offset.y, z = offset.z }
    end
    function adapter.fov(argument, value) argument:set_field("FOV", value) end
    function adapter.offset(argument, value)
        argument:set_field("AttachOffset", Vector3f.new(value.x, value.y, value.z))
    end
    return adapter
end

-- 独立状态机不写任何 JSON；绘制回调只提交矩形/开关，所有 SDK 操作留在游戏帧。
function PortraitPreview.new(deps)
    deps = deps or {}
    local adapter = deps.adapter or PortraitPreview.game_adapter()
    local clock = deps.clock or os.clock
    local bridge = deps.bridge or function() return rawget(_G, "avm_portrait") or rawget(_G, "avm_bridge") end
    local self = { enabled = false, status = "preview_off", error = nil, host = "legacy",
        camera_settings = PortraitCamera.settings(deps.camera_settings) }
    local snapshot, context, rect, rect_at, next_tick, alive, failed = nil, nil, nil, 0, 0, true, false
    local pending_change = false
    local restore_attempts = 0
    local gpu_owned = false
    local first_draw
    local frame_error
    local requested_host, applied_host = "legacy", nil

    function self.reff_available()
        local native = bridge()
        if not native or not native.portrait_reff or not native.portrait_reff_ready then return false end
        local ok, ready = pcall(native.portrait_reff_ready)
        return ok and ready == 1
    end

    function self.set_host(value)
        assert(value == "legacy" or value == "reff", "Invalid preview host")
        self.host = value
        if requested_host ~= value then requested_host, next_tick = value, 0 end
    end

    -- 两字段独立还原并精确回读；失败保留原快照，不能让下一次启用覆盖它。
    local function restore()
        if not snapshot then return true end
        local a, original = snapshot.argument, snapshot.original
        local ok_fov, err_fov = pcall(adapter.fov, a, original.fov)
        local ok_offset, err_offset = pcall(adapter.offset, a, original)
        if not ok_fov or not ok_offset then error(tostring(err_fov or err_offset)) end
        local actual = adapter.read(a)
        for _, key in ipairs({ "fov", "x", "y", "z" }) do
            assert(actual[key] == original[key], "Camera restore readback mismatch: " .. key)
        end
        snapshot, context = nil, nil
        restore_attempts = 0
        return true
    end

    function self.stop(reason, keep_camera)
        local native = bridge()
        -- 只停止本控制器提交过的绘制；空闲界面不能反复清除其他独立预览的请求。
        if gpu_owned and native and native.portrait_update then
            local ok, result = pcall(native.portrait_update, 0, 0, 0, 0, 0, 0)
            if ok and result == 0 then gpu_owned, first_draw = false, nil end
        end
        local ok, err = true, nil
        if adapter.stop and not keep_camera then ok, err = pcall(adapter.stop) end
        if snapshot then
            if restore_attempts >= 3 then return false end
            restore_attempts = restore_attempts + 1
            ok, err = pcall(restore)
        end
        if not ok then
            if deps.log and self.error ~= tostring(err) then deps.log("Camera restore failed: " .. tostring(err)) end
            failed, self.status, self.error = true, "preview_restore_error", tostring(err)
            -- 独立预览的启用值表示用户开窗意图；清理失败显示错误卡片，而不是让按钮立即失效。
            if not adapter.independent then self.enabled = false end
        elseif not failed then
            self.status = reason or "preview_off"
        end
        return ok
    end

    function self.set_enabled(value)
        -- 控件回调可能位于渲染线程，只记录请求；还原与启用统一延迟到 tick。
        self.enabled, pending_change = value == true, true
        restore_attempts = 0
        next_tick = 0
        return true
    end

    function self.set_rectangle(value)
        if not value then rect = nil; return end
        for _, key in ipairs({ "x", "y", "w", "h" }) do assert(finite(value[key]), "Invalid preview rectangle") end
        rect, rect_at = { x = value.x, y = value.y, w = value.w, h = value.h }, clock()
        -- 只传屏幕坐标；资源检查仍由游戏更新处理，旧DLL继续保留原有更新路径。
        local native = bridge()
        if gpu_owned and self.enabled and not failed and native and native.portrait_rectangle then
            local ok, result = pcall(native.portrait_rectangle, rect.x, rect.y, rect.w, rect.h)
            if not ok or result ~= 0 then frame_error = "GPU rectangle update failed: " .. tostring(result) end
        end
    end

    -- 设置页位于绘制线程，只记录取景意图；相机写入留给下一次游戏更新。
    function self.set_camera_settings(value)
        self.camera_settings = PortraitCamera.settings(value)
        next_tick = 0
    end

    -- 不依赖主扫描器的成功分支：加载暂停、关闭窗口、停止绘制都能及时撤销自己的相机改动。
    function self.tick()
        if not alive then return end
        local now = clock()
        if now < next_tick then return end
        next_tick = now + 0.1
        if pending_change then
            pending_change = false
            local stopped = self.stop("preview_off")
            if not stopped or snapshot then
                if not adapter.independent then self.enabled = false end
                return
            end
            failed, self.error, frame_error = false, nil, nil
            self.status = self.enabled and "preview_waiting" or "preview_off"
        end
        if adapter.poll then
            local poll_ok, poll_error = pcall(adapter.poll)
            if not poll_ok then
                -- 首次错误含实际失败对象，后续故障锁只保留它，避免被通用 cleanup failed 覆盖。
                if not failed then
                    failed, self.status, self.error = true, "preview_restore_error", tostring(poll_error)
                    if not adapter.independent then self.enabled = false end
                    if deps.log then deps.log("Portrait cleanup failed: " .. self.error) end
                end
                self.stop("preview_restore_error")
                return
            end
        end
        if frame_error then
            failed, self.status, self.error = true, "preview_error", frame_error
            frame_error = nil
            self.stop("preview_error")
            if deps.log then deps.log(self.error) end
            return
        end
        local visible = not deps.should_show or deps.should_show()
        if not self.enabled or failed or not visible or not rect or now - rect_at > 0.5 then
            self.stop(self.enabled and "preview_waiting" or "preview_off")
            return
        end
        local ok, err = xpcall(function()
            local native = bridge()
            local required_version = adapter.independent and 4 or 3
            if not native or not native.portrait_version or native.portrait_version() < required_version or native.portrait_ready() ~= 1 then
                self.stop("preview_native_missing"); return
            end
            if applied_host ~= requested_host then
                if not self.stop("preview_waiting") then return end
                if requested_host == "reff" and not self.reff_available() then self.status = "preview_native_missing"; return end
                if native.portrait_reff then
                    assert(native.portrait_reff(requested_host == "reff" and 1 or 0) == 0, "Preview host unavailable")
                end
                applied_host = requested_host
            end
            if native.portrait_state() == -1 then error(native.portrait_error()) end
            local hdr, color = adapter.output()
            if native.portrait_output(hdr, color) ~= 0 then self.stop("preview_output_unsupported"); return end
            if adapter.configure then
                adapter.configure(self.camera_settings, requested_host == "reff" and rect.w / rect.h or nil)
            end
            local system = adapter.current()
            if not system then
                -- 构建仍每次最多两个网格，但不再在每批之间人为等待100ms。
                -- 仅加载/构建阶段逐游戏帧推进；等待角色、通道和正常运行保持原轮询频率。
                if adapter.independent and (adapter.state == "loading" or adapter.state == "building") then next_tick = now end
                self.stop("preview_waiting", adapter.independent); return
            end
            local identity = adapter.identity(system)
            if context and identity ~= context then self.stop("preview_waiting"); return end
            local holder = adapter.holder(system)
            -- 原生解析/输出模式先过关，才允许调整相机；第一帧可显示原头像。
            if requested_host == "reff" and first_draw == nil then first_draw = native.portrait_drawn() end
            gpu_owned = true
            assert(native.portrait_update(holder, 1, rect.x, rect.y, rect.w, rect.h) == 0, "GPU source unavailable")
            if adapter.independent then
                assert(native.portrait_alpha(0) == 0, "GPU alpha mode unavailable")
            elseif not snapshot then
                local argument = adapter.argument(system)
                local original = adapter.read(argument)
                for _, key in ipairs({ "fov", "x", "y", "z" }) do assert(finite(original[key]), "Invalid camera snapshot") end
                assert(original.fov >= 1 and original.fov <= 90, "Invalid camera FOV")
                snapshot, context = { argument = argument, original = original }, identity
                adapter.fov(argument, 40)
                adapter.offset(argument, { x = original.x, y = original.y - 0.75, z = 2.8 })
                assert(native.portrait_alpha(0) == 0, "GPU alpha mode unavailable")
            end
            -- 提供者接受纹理不代表 REFF 已消费槽位；旧宿主保持原状态语义。
            self.status = requested_host == "reff" and native.portrait_drawn() <= first_draw
                and "preview_compositor_waiting" or "preview_live"
        end, tostring)
        if not ok then
            failed, self.status, self.error = true, "preview_error", err
            self.stop("preview_error")
            if deps.log then deps.log(err) end
        end
    end

    -- 每帧跟随最终动画，控制状态仍由 UpdateBehavior 处理；失败只撤销自己的 GPU 请求并交回清理阶段。
    function self.frame()
        if not alive or not self.enabled or failed or frame_error or not adapter.frame then return end
        if deps.should_show and not deps.should_show() or not rect or clock() - rect_at > 0.5 then return end
        local ok, err = pcall(adapter.frame)
        if not ok or err == false then
            if not ok then frame_error = tostring(err) else self.status = "preview_waiting" end
            local native = bridge()
            if gpu_owned and native and native.portrait_update then
                local stopped, result = pcall(native.portrait_update, 0, 0, 0, 0, 0, 0)
                if stopped and result == 0 then gpu_owned = false end
            end
        end
    end

    function self.shutdown()
        self.enabled = false
        restore_attempts = 0
        self.stop("preview_off")
        if adapter.shutdown then
            local ok, err = pcall(adapter.shutdown)
            if not ok and deps.log then deps.log("Portrait shutdown failed: " .. tostring(err)) end
        end
        alive = false
    end
    if deps.register ~= false then
        -- 独立相机的加载、实例化与销毁放在游戏更新阶段，绘制回调只记录界面请求。
        if adapter.independent then
            re.on_application_entry("UpdateBehavior", self.tick)
            re.on_application_entry("LateUpdateBehavior", self.frame)
        else
            re.on_frame(self.tick)
        end
        re.on_script_reset(self.shutdown)
    end
    return self
end

return PortraitPreview
