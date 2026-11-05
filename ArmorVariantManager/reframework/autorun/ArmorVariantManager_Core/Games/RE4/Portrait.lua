-- RE4 全身预览:第二台相机把玩家渲染进随插件发布的 rtex,再由 ArmorVariantManager_Portrait.dll
-- 交给 REFF 的原生预览槽位显示在网页里(和荒野同一个 DLL,纹理布局按游戏区分)。
--
-- 做法参考 SKS 的表情镜(它在 RE4 上已验证):
--   * 相机只创建一次,之后只隐藏(set_DrawSelf),按名字找回 —— RE4 里反复销毁 / 重建渲染相机
--     会在渲染器里留下孤立输出。所以这里**从不销毁**相机。
--   * RenderOutput 先设成自己的输出位、再设渲染目标,永远不会变成主相机。
--   * 输出位用 Quateary(8):SKS 表情镜占 Tertiary(4),各改各的位,互不干扰。
--     玩家网格默认只有 Primary | Secondary,所以给玩家的网格加上这一位;场景里其他带这一位的
--     网格(道具默认带)清掉,画面里只有玩家。停下时按记录还原。
--   * 曝光跟主相机走(固定曝光 = 主相机实际生效的 EV,即 SnappedRealEV),调色每隔一阵从主相机复制。
--   * RE4 相机纹理的 alpha 不是覆盖率(网页里整张图被当成透明),合成时按不透明处理。
-- 相机挂在玩家根节点上(不挂骨骼),全身取景不随动作晃动。
local Portrait = {}

local CAMERA = "AVM_PortraitCamera"
local TARGET = "ArmorVariantManager/Portrait/portrait.rtex"
local CHANNEL = 8                      -- via.render.RenderOutputID.Quateary
local ASPECT = 660 / 720               -- rtex 尺寸,DLL 只接受 660×720
local COMPONENTS = { "via.Camera", "via.render.RenderOutput", "via.render.ToneMapping", "via.render.LDRPostProcess" }
local SCAN_STEP = 200                  -- 每次 tick 最多处理的场景网格数(一次读完一个区域会卡一帧)

local COMMON_SKIP = { Enabled = true, GameObject = true, InjectingGameObject = true, Valid = true, UpdateTiming = true, DrawTiming = true }
local TM_SKIP = { EV = true, AutoExposure = true, UseAutoExposure = true, MultiZoneMeteringTexture = true,
    OffsetEVCurve = true, ClearHistogram = true, TemporalAA = true }
for k in pairs(COMMON_SKIP) do TM_SKIP[k] = true end

function Portrait.settings(value)
    value = type(value) == "table" and value or {}
    local function num(v, d, lo, hi)
        v = tonumber(v)
        if not v or v ~= v then v = d end
        return math.max(lo, math.min(hi, v)) + 0.0
    end
    return { distance = num(value.distance, 3.0, 1.2, 8.0), height = num(value.height, 0.0, -1.0, 1.0) }
end

-- 网页上预览区的鼠标交互(滚轮缩放 / 左键平移 / 右键旋转)给出的相机参数。
--   yaw   绕角色竖轴转(弧度,0 = 正面)        pitch 俯仰(弧度,正 = 从上往下看)
--   zoom  放大倍数(1 = 竖向正好容纳约 1.95 m)  pan_x / pan_y 目标点在画面里的平移(米)
local CAMERA_DEFAULT = { yaw = 0.0, pitch = 0.0, zoom = 1.0, pan_x = 0.0, pan_y = 0.0 }
function Portrait.camera(value)
    value = type(value) == "table" and value or {}
    local function num(v, d, lo, hi)
        v = tonumber(v)
        if not v or v ~= v or v == math.huge or v == -math.huge then v = d end
        return math.max(lo, math.min(hi, v)) + 0.0
    end
    local yaw = num(value.yaw, 0, -1e6, 1e6)
    yaw = (yaw + math.pi) % (2 * math.pi) - math.pi
    return { yaw = yaw, pitch = num(value.pitch, 0, -1.2, 1.2), zoom = num(value.zoom, 1, 0.5, 8),
        pan_x = num(value.pan_x, 0, -2, 2), pan_y = num(value.pan_y, 0, -2, 2) }
end

-- 相机在角色根节点本地空间里的姿态(纯函数,便于离线测试)。
-- 根节点 +Z 朝前、+Y 朝上;相机本身沿本地 -Z 看。旋转 = 绕 Y 转 yaw,再绕 X 转 -pitch,
-- 四元数按 Quaternion.new(w, x, y, z)(同 Wilds 的 PortraitCamera)。
-- distance 只决定透视(背景多少);人物大小由 zoom 决定:竖向可见高度 = 1.95 m / zoom。
-- aspect = 槽位宽 / 高;DLL 等比裁切,槽位比 rtex 扁时裁上下,这时放大竖向视角补回来。
function Portrait.pose(settings, camera, aspect, rtex_aspect)
    local d, c = settings.distance, camera
    local cy, sy = math.cos(c.yaw), math.sin(c.yaw)
    local cp, sp = math.cos(c.pitch), math.sin(c.pitch)
    local right = { cy, 0.0, -sy }
    local up = { -sp * sy, cp, -sp * cy }
    local back = { cp * sy, sp, cp * cy }
    local target = { 0.0, 0.95 + settings.height, 0.0 }
    for i = 1, 3 do target[i] = target[i] + right[i] * c.pan_x + up[i] * c.pan_y end
    local pos = { target[1] + back[1] * d, target[2] + back[2] * d, target[3] + back[3] * d }
    local hy, hx = math.cos(c.yaw * 0.5), math.sin(c.yaw * 0.5)
    local hp, hq = math.cos(-c.pitch * 0.5), math.sin(-c.pitch * 0.5)
    local rot = { hy * hp, hy * hq, hx * hp, -hx * hq }
    local half = math.atan(0.975 / c.zoom / d)
    local ratio = (rtex_aspect or aspect) / aspect
    if ratio < 1 then half = math.atan(math.tan(half) / ratio) end
    return { pos = pos, rot = rot, fov = math.deg(half * 2), far = d + 4.0 }
end

-- deps = { settings() -> { enabled, distance, height }, player() -> { root = 玩家根 Transform, meshes = { Mesh... } } | nil,
--          should_show() -> bool, log(msg), clock, bridge() -> 原生接口表 }
function Portrait.new(deps)
    local clock = deps.clock or os.clock
    local bridge = deps.bridge or function() return rawget(_G, "avm_portrait") or rawget(_G, "avm_bridge") end
    local self = { status = "preview_off", error = nil }
    local res, R, masks, scan = {}, {}, {}, nil
    local rect, rect_at, next_tick, scanned_at, copied_at, shown_at = nil, 0, 0, nil, nil, nil
    local gpu_owned, first_draw, host_applied, failed, last_enabled = false, nil, false, false, nil
    local live_player, live_settings = nil, nil   -- 预览显示中:每帧回调用它们跟上网页的相机操作
    local subject_root = nil                       -- 当前拍的是哪个角色(根变换地址);换人时先还原遮挡
    local prop_cache = {}
    local T = {}

    local function note(msg) if deps.log then deps.log(msg) end end
    local function component(go, name) return go:call("getComponent(System.Type)", sdk.typeof(name)) end
    local function scene_manager() return sdk.get_native_singleton("via.SceneManager") end
    local function scene() return sdk.call_native_func(scene_manager(), T.SceneManager, "get_CurrentScene") end
    local function main_camera_go()
        local view = sdk.call_native_func(scene_manager(), T.SceneManager, "get_MainView")
        local cam = view and view:call("get_PrimaryCamera")
        return cam and cam:call("get_GameObject")
    end

    function self.reff_available()
        local native = bridge()
        if not native or not native.portrait_reff or not native.portrait_reff_ready then return false end
        local ok, ready = pcall(native.portrait_reff_ready)
        return ok and ready == 1
    end

    -- ------------------------------------------------------------ 只显示玩家
    local function restore_masks()
        for _, m in pairs(masks) do pcall(m[1].call, m[1], "set_RenderOutputID", m[2]) end
        masks, scan, scanned_at = {}, nil, nil
    end
    local function remember(mesh)
        local addr = mesh:get_address()
        local m = masks[addr]
        if not m then m = { mesh, mesh:call("get_RenderOutputID") or 3 }; masks[addr] = m end
        return m
    end
    local function mark_player(player)
        local seen = {}
        local function show(mesh)
            if not mesh or seen[mesh:get_address()] then return end
            seen[mesh:get_address()] = true
            local m = remember(mesh)
            if mesh:call("get_RenderOutputID") ~= (m[2] | CHANNEL) then mesh:call("set_RenderOutputID", m[2] | CHANNEL) end
        end
        for _, mesh in ipairs(player.meshes or {}) do show(mesh) end
        -- 挂在玩家根节点下的其他网格(饰品、背着的武器)也一起拍进来
        local function visit(tr, depth)
            for _ = 1, 64 do
                if not tr then return end
                local go = tr:call("get_GameObject")
                local mesh = go and go:call("get_Name") ~= CAMERA and component(go, "via.render.Mesh")
                if mesh then show(mesh) end
                if depth < 4 then visit(tr:call("get_Child"), depth + 1) end
                tr = tr:call("get_Next")
            end
        end
        visit(player.root:call("get_Child"), 0)
    end
    -- 场景里其他网格清掉这一位;见过的按地址跳过,每 3 秒再扫一次新出现的网格
    local function step_scan(now)
        if not scan then
            if scanned_at and now - scanned_at < 3 then return end
            local arr = scene():call("findComponents(System.Type)", sdk.typeof("via.render.Mesh"))
            if not arr then return end
            scan = { list = arr:get_elements(), i = 1 }
        end
        local last = math.min(#scan.list, scan.i + SCAN_STEP - 1)
        for k = scan.i, last do
            local mesh = scan.list[k]
            if not masks[mesh:get_address()] then
                local m = remember(mesh)
                if (m[2] & CHANNEL) ~= 0 then mesh:call("set_RenderOutputID", m[2] & ~CHANNEL) end
            end
        end
        scan.i = last + 1
        if scan.i > #scan.list then scan, scanned_at = nil, now end
    end

    -- ------------------------------------------------------------ 相机
    local function load_resources()
        if res.holder then return true end
        local r = sdk.create_resource("via.render.RenderTargetTextureResource", TARGET)
        if not r then return false end
        res.rt = r:add_ref()
        -- 这个 holder 一直由 Lua 持有,地址交给 DLL 解析纹理
        res.holder = res.rt:create_holder("via.render.RenderTargetTextureResourceHolder"):add_ref()
        return res.holder ~= nil
    end
    local function find_camera()
        local go = scene():call("findGameObject(System.String)", CAMERA)
        if not go then
            go = T.create:call(nil, CAMERA)
            if not go then return false end
            go:call("set_DrawSelf", false)
            for _, name in ipairs(COMPONENTS) do go:call("createComponent(System.Type)", sdk.typeof(name)) end
            note("preview camera created")
        end
        go:call("set_DrawSelf", false)
        R = { go = go, tr = go:call("get_Transform"), cam = component(go, "via.Camera"),
            out = component(go, "via.render.RenderOutput"), tm = component(go, "via.render.ToneMapping"),
            ldr = component(go, "via.render.LDRPostProcess"), shown = false }
        assert(R.tr and R.cam and R.out and R.tm, "preview camera components missing")
        R.out:call("set_RenderOutputID", CHANNEL)   -- 先设输出位,再设目标:永远不会成为主相机
        R.out:call("set_RenderTarget", res.holder)
        R.tm:call("setTemporalAA", T.taa_off)        -- TAA 的历史帧会留下重影
        R.cam:call("set_AspectRatio", ASPECT)
        return true
    end
    local function place(player, settings)
        local root = player.root
        if R.attached ~= root:get_address() then
            R.tr:call("set_Parent", root)
            R.tr:call("set_ParentJoint", "")
            R.attached, R.pose = root:get_address(), nil
        end
        local aspect = rect and rect.w > 0 and rect.h > 0 and rect.w / rect.h or ASPECT
        local camera = Portrait.camera(deps.camera and deps.camera() or nil)
        local key = string.format("%g|%g|%g|%g|%g|%g|%g|%g", settings.distance, settings.height, aspect,
            camera.yaw, camera.pitch, camera.zoom, camera.pan_x, camera.pan_y)
        if R.pose == key then return end
        local pose = Portrait.pose(settings, camera, aspect, ASPECT)
        R.tr:call("set_LocalPosition", Vector3f.new(pose.pos[1], pose.pos[2], pose.pos[3]))
        R.tr:call("set_LocalRotation", Quaternion.new(pose.rot[1], pose.rot[2], pose.rot[3], pose.rot[4]))
        R.cam:call("set_FOV", pose.fov + 0.0)
        R.cam:call("set_NearClipPlane", 0.05)
        R.cam:call("set_FarClipPlane", pose.far + 0.0)
        R.pose = key
    end
    local function props_of(obj, skip)
        local td = obj:get_type_definition()
        local name = td:get_full_name()
        if prop_cache[name] then return prop_cache[name] end
        local list, t = {}, td
        while t and t:get_full_name() ~= "via.Component" do
            for _, m in ipairs(t:get_methods()) do
                local g = m:get_name()
                if m:get_num_params() == 0 and not m:is_static() then
                    local prop, setter
                    if g:sub(1, 4) == "get_" then prop = g:sub(5); setter = "set_" .. prop
                    elseif g:match("^get%u") then prop = g:sub(4); setter = "set" .. prop end
                    if prop and not skip[prop] and t:get_method(setter) then list[#list + 1] = { g, setter } end
                end
            end
            t = t:get_parent_type()
        end
        prop_cache[name] = list
        return list
    end
    local function copy_props(src, dst, skip)
        for _, p in ipairs(props_of(src, skip)) do
            pcall(function()
                local v = src:call(p[1])
                if v == nil or type(v) == "string" then return end
                if sdk.is_managed_object(v) and not v:get_type_definition():get_full_name():find("Holder$") then return end
                dst:call(p[2], v)
            end)
        end
    end
    local function update_image(now)
        local main = main_camera_go()
        local main_tm = main and component(main, "via.render.ToneMapping")
        if not main_tm then return end
        if not copied_at or now - copied_at >= 2 then
            copied_at = now
            copy_props(main_tm, R.tm, TM_SKIP)
            local main_ldr = component(main, "via.render.LDRPostProcess")
            if main_ldr and R.ldr then copy_props(main_ldr, R.ldr, COMMON_SKIP) end
        end
        if R.auto ~= 2 then R.tm:call("setAutoExposure", 2); R.auto = 2 end
        -- SnappedRealEV 已经包含主相机的补偿,再加一次 EV 会暗 3~4 档
        local real = main_tm:call("get_SnappedRealEV")
        if real and real == real then R.tm:call("set_EV", real + 0.0) end
    end
    local function show(value)
        if R.go and R.shown ~= value then pcall(R.go.call, R.go, "set_DrawSelf", value); R.shown = value end
    end

    -- ------------------------------------------------------------ 状态机
    function self.stop(reason)
        local native = bridge()
        if gpu_owned and native and native.portrait_update then
            local ok, result = pcall(native.portrait_update, 0, 0, 0, 0, 0, 0)
            if ok and result == 0 then gpu_owned, first_draw = false, nil end
        end
        show(false)
        live_player, live_settings, subject_root = nil, nil, nil
        if next(masks) then pcall(restore_masks) end
        shown_at = nil
        if not failed then self.status = reason or "preview_off" end
    end

    function self.set_rectangle(value)
        if not value then rect = nil; return end
        rect, rect_at = { x = value.x, y = value.y, w = value.w, h = value.h }, clock()
        local native = bridge()
        if gpu_owned and native and native.portrait_rectangle then pcall(native.portrait_rectangle, rect.x, rect.y, rect.w, rect.h) end
    end

    function self.reset_error() failed, self.error = false, nil end

    -- tick 只有 10 Hz;鼠标旋转 / 缩放 / 平移要每帧跟上,否则画面每秒只动 10 下。
    -- 只摆相机(参数没变时 place 直接返回),资源、遮挡、曝光仍在 tick 里做。
    function self.frame()
        if not gpu_owned or not live_player or not R.tr then return end
        if not pcall(place, live_player, live_settings) then live_player = nil end
    end

    function self.tick()
        local now = clock()
        if now < next_tick then return end
        next_tick = now + 0.1
        local s = deps.settings()
        -- 重新打开预览时清掉上次的错误,允许重试
        if s.enabled ~= last_enabled then
            last_enabled = s.enabled
            if s.enabled then failed, self.error = false, nil end
        end
        local want = s.enabled and not failed and rect and now - rect_at <= 0.5 and (not deps.should_show or deps.should_show())
        if not want then
            if gpu_owned or R.shown or next(masks) or self.status ~= (s.enabled and "preview_waiting" or "preview_off") then
                self.stop(failed and self.status or (s.enabled and "preview_waiting" or "preview_off"))
            end
            return
        end
        local ok, err = xpcall(function()
            local native = bridge()
            if not native or not native.portrait_version or native.portrait_version() < 4 or native.portrait_ready() ~= 1 then
                self.stop("preview_native_missing"); return
            end
            if not host_applied then
                if not self.reff_available() then self.status = "preview_native_missing"; return end
                assert(native.portrait_reff(1) == 0, "Preview host unavailable")
                host_applied = true
            end
            if native.portrait_state() == -1 then error(native.portrait_error()) end
            local renderer = T.Renderer
            local hdr = renderer:get_method("get_HDRMode"):call(nil)
            if native.portrait_output(hdr and 1 or 0, renderer:get_method("get_ColorSpace"):call(nil)) ~= 0 then
                self.stop("preview_output_unsupported"); return
            end
            local player = deps.player()
            if not player then self.stop("preview_waiting"); return end
            if not R.go or not sdk.is_managed_object(R.go) or not R.go:call("get_Valid") then
                if not load_resources() then error("Preview render target missing: " .. TARGET) end
                R = {}
                if not find_camera() then self.stop("preview_waiting"); return end
            end
            local settings = Portrait.settings(s)
            -- 换了角色:旧角色的网格还带着预览通道位,场景扫描又会跳过记录过的网格,
            -- 不还原的话两个人会一起出现在预览里
            local root_addr = player.root:get_address()
            if subject_root and subject_root ~= root_addr and next(masks) then restore_masks() end
            subject_root = root_addr
            place(player, settings)
            live_player, live_settings = player, settings
            mark_player(player)
            step_scan(now)
            update_image(now)
            show(true)
            -- 相机刚显示的那一帧纹理里还没有画面,等一下再交给 DLL
            shown_at = shown_at or now
            if now - shown_at < 0.1 then self.status = "preview_waiting"; return end
            if first_draw == nil then first_draw = native.portrait_drawn() end
            gpu_owned = true
            assert(native.portrait_update(res.holder:get_address(), 1, rect.x, rect.y, rect.w, rect.h) == 0, "GPU source unavailable")
            -- 2 = 不透明(新版 DLL);旧 DLL 只认 0/1,退回直通
            if native.portrait_alpha(2) ~= 0 then assert(native.portrait_alpha(0) == 0, "GPU alpha mode unavailable") end
            self.status = native.portrait_drawn() <= first_draw and "preview_compositor_waiting" or "preview_live"
        end, tostring)
        if not ok then
            failed, self.status, self.error = true, "preview_error", err
            self.stop("preview_error")
            note(err)
        end
    end

    function self.shutdown()
        self.stop("preview_off")
        R, res = {}, {}
    end

    -- 游戏类型缺失(游戏更新后改名之类)时不注册,预览显示为不可用,其余功能照常
    function self.register()
        local ok = pcall(function()
            T.SceneManager = sdk.find_type_definition("via.SceneManager")
            T.Renderer = sdk.find_type_definition("via.render.Renderer")
            T.create = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)")
            T.taa_off = sdk.find_type_definition("via.render.ToneMapping.TemporalAA"):get_field("Disable"):get_data(nil)
            assert(T.SceneManager and T.Renderer and T.create and T.taa_off ~= nil)
        end)
        if not ok or not re.on_application_entry then return false end
        re.on_application_entry("UpdateBehavior", self.tick)
        re.on_application_entry("LateUpdateBehavior", self.frame)
        re.on_script_reset(self.shutdown)
        return true
    end
    return self
end

-- 网页接口:心跳只记录意图(可见、尺寸),资源操作都在游戏帧里做。
function Portrait.connect(deps)
    local clock = deps.clock or os.clock
    local deadline = 0
    local camera = Portrait.camera(nil)   -- 网页上鼠标交互给的相机参数,只在内存里,重载脚本即复位
    local function reff_visible()
        local native = rawget(_G, "reff_native")
        return native and native.is_visible and native.is_visible() == true
    end
    local preview = Portrait.new({
        settings = deps.settings, player = deps.player, log = deps.log, clock = clock, bridge = deps.bridge,
        camera = function() return camera end,
        should_show = function() return deadline > clock() and reff_visible() end,
    })
    local web = {}
    function web.snapshot()
        return { available = preview.reff_available(), enabled = deps.settings().enabled == true,
            status = preview.status, error = preview.error }
    end
    function web.action(request)
        assert(type(request) == "table" and type(request.visible) == "boolean", "invalid preview request")
        if type(request.camera) == "table" then camera = Portrait.camera(request.camera) end
        if request.visible and reff_visible() and preview.reff_available() then
            deadline = clock() + 0.5
            preview.set_rectangle({ x = 0, y = 0, w = tonumber(request.width) or 330, h = tonumber(request.height) or 360 })
        else
            deadline = 0
            preview.set_rectangle(nil)
        end
        return web.snapshot()
    end
    return preview, web
end

return Portrait
