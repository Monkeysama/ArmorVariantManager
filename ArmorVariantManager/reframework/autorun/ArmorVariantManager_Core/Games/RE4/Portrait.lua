-- RE4 全身预览:第二台相机把角色渲染进随插件发布的 rtex,再由 ArmorVariantManager_Portrait.dll
-- 交给 REFF 的原生预览槽位显示在网页里(和荒野同一个 DLL,纹理布局按游戏区分)。
--
-- 拍的是远处舞台上的显示副本(PortraitModel.lua),不是世界里的真人:真人会被游戏为主镜头做的
-- 贴近隐藏、剔除和所在位置的灯光带偏。副本网格只带预览通道位,舞台上也没有别的东西,
-- 所以不再需要给场景网格清位。
--
-- 做法参考 SKS 的表情镜(它在 RE4 上已验证):
--   * 相机只创建一次,之后只隐藏(set_DrawSelf),按名字找回 —— RE4 里反复销毁 / 重建渲染相机
--     会在渲染器里留下孤立输出。所以这里**从不销毁**相机。
--   * RenderOutput 先设成自己的输出位、再设渲染目标,永远不会变成主相机。
--   * 输出位用 Quateary(8):SKS 表情镜占 Tertiary(4),各改各的位,互不干扰。
--   * 曝光固定(STAGE_EV,舞台只有自己的灯组),调色每隔一阵从主相机复制。
--   * RE4 相机纹理的 alpha 不是覆盖率(网页里整张图被当成透明),合成时按不透明处理。
-- 相机按角色根的朝向摆在舞台原点周围(不跟骨骼),全身取景不随动作晃动。
local Portrait = {}
local PortraitModel = require("ArmorVariantManager_Core.Games.RE4.PortraitModel")

local CAMERA = "AVM_PortraitCamera"
local TARGET = "ArmorVariantManager/Portrait/portrait.rtex"
local CHANNEL = 8                      -- via.render.RenderOutputID.Quateary
local ASPECT = 660 / 720               -- rtex 尺寸,DLL 只接受 660×720
-- 舞台只有自己的灯组,曝光固定(跟主相机走的话,暗处主相机提曝光,灯一照就整片发白)。
-- 和游戏「模型鉴赏」一样用 EV 4(2026-11-05 实测),配 PortraitModel.RIG 照搬的鉴赏灯组
local STAGE_EV = 4.0
local COMPONENTS = { "via.Camera", "via.render.RenderOutput", "via.render.ToneMapping", "via.render.LDRPostProcess" }

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
    local res, R = {}, {}
    local rect, rect_at, next_tick, copied_at, shown_at = nil, 0, 0, nil, nil
    local gpu_owned, first_draw, host_applied, failed, last_enabled = false, nil, false, false, nil
    local live_player, live_settings = nil, nil   -- 预览显示中:每帧回调用它们同步副本、跟上网页的相机操作
    local context = nil                            -- 交给副本模型的 { key, root, light }
    -- 副本模型第一次用到时才建(建的时候要查游戏类型)
    local model = deps.model
    local function ensure_model()
        model = model or PortraitModel.new({ bridge = bridge, clock = clock, skip = { [CAMERA] = true } })
        return model
    end
    local function model_state() return model and model.state or "idle" end
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
    -- 相机不挂在任何对象上(旧版挂在玩家根下,这里先摘下来),每帧按角色根的朝向摆到舞台上
    local function place(player, settings)
        if not R.detached then
            R.tr:call("set_ParentJoint", "")
            R.tr:call("set_Parent", nil)
            R.detached = true
        end
        local aspect = rect and rect.w > 0 and rect.h > 0 and rect.w / rect.h or ASPECT
        local camera = Portrait.camera(deps.camera and deps.camera() or nil)
        local key = string.format("%g|%g|%g|%g|%g|%g|%g|%g", settings.distance, settings.height, aspect,
            camera.yaw, camera.pitch, camera.zoom, camera.pan_x, camera.pan_y)
        if R.pose ~= key then
            R.local_pose = Portrait.pose(settings, camera, aspect, ASPECT)
            R.cam:call("set_FOV", R.local_pose.fov + 0.0)
            R.cam:call("set_NearClipPlane", 0.05)
            R.cam:call("set_FarClipPlane", R.local_pose.far + 0.0)
            R.pose = key
        end
        local q = (context and context.anchor or player.root):call("get_Rotation")
        local world = PortraitModel.stage_pose({ q.w, q.x, q.y, q.z }, R.local_pose)
        R.tr:call("set_Position", Vector3f.new(world.pos[1], world.pos[2], world.pos[3]))
        R.tr:call("set_Rotation", Quaternion.new(world.rot[1], world.rot[2], world.rot[3], world.rot[4]))
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
    -- 主相机的调色(LUT + 调色元素)在 LDRPostProcess 的 ColorCorrect 子对象里;copy_props 不复制子对象,
    -- 不单独抄的话预览没有游戏的调色,颜色比画面鲜艳(2026-11-05 实测主相机开着、预览相机关着)
    local function copy_color_correct(src_ldr, dst_ldr)
        local a, b = src_ldr:call("get_ColorCorrect"), dst_ldr:call("get_ColorCorrect")
        if not a or not b then return end
        copy_props(a, b, COMMON_SKIP)   -- ColorCube0/1/2、混合比例等
        local n = a:call("getColorCubeElementCount") or 0
        b:call("setColorCubeElementCount", n)
        for i = 0, n - 1 do b:call("setColorCubeElement", i, a:call("getColorCubeElement", i)) end
        local m = a:call("get_LinearParamsCount") or 0
        b:call("set_LinearParamsCount", m)
        for i = 0, m - 1 do b:call("setLinearParamsAt", i, a:call("getLinearParamsAt", i)) end
        b:call("set_Enabled", a:call("get_Enabled") == true)
    end
    local function update_image(now)
        local main = main_camera_go()
        local main_tm = main and component(main, "via.render.ToneMapping")
        if not main_tm then return end
        if not copied_at or now - copied_at >= 2 then
            copied_at = now
            copy_props(main_tm, R.tm, TM_SKIP)
            local main_ldr = component(main, "via.render.LDRPostProcess")
            if main_ldr and R.ldr then
                copy_props(main_ldr, R.ldr, COMMON_SKIP)
                local ok, err = pcall(copy_color_correct, main_ldr, R.ldr)
                if not ok and not R.cc_noted then R.cc_noted = true; note("color correct copy failed: " .. tostring(err)) end
            end
        end
        if R.auto ~= 2 then R.tm:call("setAutoExposure", 2); R.auto = 2 end
        if R.ev ~= STAGE_EV then R.tm:call("set_EV", STAGE_EV + 0.0); R.ev = STAGE_EV end
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
        live_player, live_settings, context = nil, nil, nil
        if model_state() ~= "idle" then
            local ok, err = pcall(model.stop)
            if not ok then note(tostring(err)) end
        end
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

    -- 每帧在 UpdateBehavior 之前:把真人上一帧的最终姿态同步到副本,再按同一时刻的根朝向摆相机。
    -- (tick 只有 10 Hz,放在 tick 里副本和鼠标操作每秒只动 10 下;建副本、曝光仍在 tick 里做。)
    -- 为什么是这个时机(2026-11-05 实测):
    --   * 头发、外套、尾巴的物理(Chain)在 PrepareRendering 之后才写进关节,LateUpdateBehavior 时关节里
    --     只有动画姿态 —— 在那里同步,副本没有物理;
    --   * 在 BeginRendering 前同步,关节数据是对的,但渲染这一帧的数据已经准备好了,副本画面不动;
    --   * 从 BeginRendering 到下一帧 UpdateMotion 开始,关节都保持着上一帧的最终姿态(含物理),
    --     到 UpdateMotion 才被动画重置。所以在 UpdateBehavior 前同步:带物理、能被渲染,只晚一帧。
    --     (HeightFix 在 UpdateMotion 前才还原抬高量,这里读到的仍是抬高后的姿态,和画面一致。)
    function self.frame()
        if not live_player or not R.tr or model_state() ~= "ready" then return end
        local ok, err = pcall(function()
            if model.sync(context) then place(live_player, live_settings) end
        end)
        if not ok then live_player = nil; note(tostring(err)) end
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
            if gpu_owned or R.shown or model_state() ~= "idle" or self.status ~= (s.enabled and "preview_waiting" or "preview_off") then
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
            -- 换了角色 key 就变了,副本模型会先销毁旧副本再重建
            local key = tostring(player.root:get_address())
            if not context or context.key ~= key then
                context = { key = key, root = player.root, anchor = PortraitModel.anchor(player.root) }
            end
            if not ensure_model().current(context) then
                live_player = nil
                self.status = "preview_waiting"; return
            end
            place(player, settings)
            live_player, live_settings = player, settings
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
        if model then pcall(model.shutdown) end
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
        if not ok or not re.on_application_entry or not re.on_pre_application_entry then return false end
        re.on_application_entry("UpdateBehavior", self.tick)
        re.on_pre_application_entry("UpdateBehavior", self.frame)
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
