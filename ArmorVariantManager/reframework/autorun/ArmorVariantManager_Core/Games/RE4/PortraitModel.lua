-- RE4 全身预览的显示副本:不再拍世界里的真人,而是在远处舞台(Y = STAGE_Y)放一份副本来拍。
-- 世界里的真人会被游戏为主镜头做的处理带偏(贴近隐藏、按主镜头剔除、所在位置的灯光),
-- 副本只由我们写,预览相机拍它就不受这些影响。
--
-- 建副本 / 逐帧同步 / 换装重建的状态机照抄荒野(Games/Wilds/PortraitModel.lua 的 new,去掉找 COG
-- 挂相机那段);RE4 按方案 A 独立接入,不加载别的游戏的模块(re4_entrypoint 测试会拦)。RE4 自己的部分:
--   * 从角色根变换往下找网格(2026-11-05 实测:玩家根 ch0a0z0_body,body / head / hair / body_armor
--     各是子对象、各 946 个关节,武器 wp* 也是子对象;副本按名字能对上全部关节);
--   * 副本网格只放预览通道位(新建网格默认 RenderOutputID = 31,会被主镜头看到,必须改);
--   * 姿态、材质开关、部件开关由 ArmorVariantManager_Portrait.dll 的 portrait_pose_* 逐帧同步(代码不分游戏)。
local PortraitModel = {}
-- 调色盘(Palette.lua)每往原网格写一次材质参数就把 revision 加一;副本据此重抄参数。
-- 必须在脚本加载时 require:REFramework 只在加载 autorun 期间把 autorun 放进 package.path。
local ok_palette, Palette = pcall(require, "ArmorVariantManager_Core.Games.RE4.Palette")
local palette_revision = ok_palette and type(Palette) == "table" and Palette.revision or nil
-- 舞台高度。不能太远:float32 在 ±10000 附近的最小间隔约 0.001 m,副本每个关节的高度被各自取整到毫米格子上,
-- 预览里人物会微微抖(2026-11-05 实测:原角色头部高度平滑变化,副本在 1.4648 / 1.4658 / 1.4668 之间跳)。
-- -1000 处间隔约 0.00006 m,看不出来;地图底下 1 km 也不会有场景物体进到预览相机里。
PortraitModel.STAGE_Y = -1000
PortraitModel.CHANNEL = 8           -- 和 Portrait.lua 的相机输出位一致(via.render.RenderOutputID.Quateary)
-- 舞台打光照搬游戏「模型鉴赏」的灯组 FigureWindow_Light_set00(2026-11-05 用 FigureStageProbe.cs 实测):
-- 5 盏带软阴影的聚光(两盏主光、一盏下方补光、两盏冷色轮廓光),固定曝光 EV 4(见 Portrait.lua STAGE_EV)。
-- 位置 / 朝向都是角色根本地空间(脚底为原点,角色面向 +Z),随角色转身一起转;在哪里、什么环境预览都一个样子。
-- 鉴赏里的模型脚底在灯组原点下方 1 m,下面的 pos 已经换算到脚底。rot = { w, x, y, z },聚光沿 -Z 照射。
-- 强度单位跟鉴赏一样用 Unit = 2;阴影参数原样照抄(ShadowVariance 让阴影边缘柔和,是鉴赏里阴影顺滑的主因之一)。
-- 鉴赏另外还有一个 IBL 环境光(Exposure 7),这里还没有搬(贴图路径未知,也要先确认它不影响主画面)。
PortraitModel.RIG = {
    { name = "KeyMain", pos = { 1.254, 6.491, 8.088 }, rot = { 0.9467, -0.3107, 0.0854, -0.0005 },
      intensity = 6000, cone = 30, color = { 1, 1, 1 }, range = 15, ao = 0.1, detail = 1,
      variance = 0.006, depth_bias = 0.004, slope_bias = 0.004, bias = 0.001, near = 3.5 },
    { name = "KeySub", pos = { 1.584, 6.276, 2.647 }, rot = { 0.8364, -0.5138, 0.1884, 0.0312 },
      intensity = 1500, cone = 30, color = { 1, 1, 1 }, range = 10, ao = 0.08, detail = 1,
      variance = 0.006, depth_bias = 0.04, slope_bias = 0.04, bias = 0.001, near = 2 },
    { name = "Fill", pos = { -8.958, -7.502, 2.129 }, rot = { 0.7312, 0.2745, -0.5824, 0.2253 },
      intensity = 2000, cone = 40, color = { 1, 1, 1 }, range = 15, ao = 0.24, detail = 1,
      variance = 0.006, depth_bias = 0.04, slope_bias = 0.04, bias = 0, near = 4 },
    { name = "BackL", pos = { -4.198, 2.385, -7.023 }, rot = { 0.2114, 0.1146, -0.9615, -0.1334 },
      intensity = 3000, cone = 60, color = { 0.842, 0.961, 0.973 }, range = 10, ao = 0.19, detail = 0.5,
      variance = 0.006, depth_bias = 0.04, slope_bias = 0.04, bias = 0, near = 5 },
    { name = "BackR", pos = { 5.339, 2.737, -1.423 }, rot = { 0.5980, -0.0911, 0.7897, 0.1019 },
      intensity = 1500, cone = 45, color = { 0.572, 0.762, 1 }, range = 10, ao = 0.26, detail = 0.06,
      variance = 0.004, depth_bias = 0.04, slope_bias = 0.04, bias = 0.001, near = 5 },
}
-- lilToon(用户的 RE4 自定义材质)的阴影、阴影边缘色、背光、边缘阴影都看 LIL_LightDir =(指向光源的方向, 权重)。
-- 世界里的角色由 lil_toon_light_re4.lua 每帧按场景灯光写,副本绑定时会抄到那个值,所以副本要自己写一份。
-- 鉴赏里没人写它,材质保持默认 (0.4, 0.8, 0.45):这里也用这个方向(角色根本地空间,随角色转身)。
local LIL_VAR, LIL_HASH = "LIL_LightDir", 486944339
PortraitModel.LIL_DIR = { 0.4, 0.8, 0.45 }

local function identity(value) return tostring(value:get_address()) end

local function require_native(bridge)
    local api = bridge()
    assert(api and api.portrait_pose_version and api.portrait_pose_version() >= 3,
        "Portrait visibility native module missing; restart with the updated ArmorVariantManager_Portrait.dll")
    return api
end

-- context = { key = 角色标识, root = 角色根 Transform, anchor = 骨架的 root 关节(没有时为 nil) }
-- 摆副本、相机、主光都读 anchor:同步在帧开头,关节是上一帧的最终姿态,而角色根变换在算完关节之后
-- 还会被角色控制器 / 贴地挪一点,用根变换算偏移的话,角色一走动副本就在舞台上抖(2026-11-05 用户发现)。
-- root 关节和其他关节同一时刻算出,静止时和根变换重合。
function PortraitModel.anchor(root)
    local ok, joint = pcall(root.call, root, "getJointByName(System.String)", "root")
    return ok and joint or nil
end
local function anchor_of(context) return context.anchor or context.root end

function PortraitModel.game_adapter(deps)
    deps = deps or {}
    local adapter = {}
    local bridge = deps.bridge or function() return rawget(_G, "avm_portrait") or rawget(_G, "avm_bridge") end
    local object_type = assert(sdk.find_type_definition("via.GameObject"))
    local function component(object, name)
        return assert(object:call("createComponent(System.Type)", sdk.typeof(name)), "Portrait component creation failed: " .. name)
    end
    local skip = deps.skip or {}   -- 不复制的对象名(预览相机等)
    local lil_entries, lil_key = nil, nil

    -- 只收集当前画得出来的网格(对象 Draw 为真、网格已就绪);收起的武器、隐藏的瞄准线不复制,
    -- 拿出来时签名变了就整体重建。
    function adapter.inventory(context)
        local root = assert(context.root, "Portrait subject root missing")
        local queue, visited, cursor = {{ node = root, depth = 0 }}, { [identity(root)] = true }, 1
        local entries, signature = {}, {}
        while queue[cursor] do
            local item = queue[cursor]; cursor = cursor + 1
            local object = item.node:call("get_GameObject")
            local name = object and object:call("get_Name")
            local components = object and not skip[name] and object:call("get_Valid") and object:call("get_Draw")
                and object:call("get_Components")
            for i = 0, components and components:call("get_Length") - 1 or -1 do
                local mesh = components:call("Get(System.Int32)", i)
                if mesh and mesh:get_type_definition():is_a("via.render.Mesh") and mesh:call("get_ReadyToDraw") then
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
            if item.depth < 31 and not skip[name] then
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
        mesh:call("set_RenderOutputID", PortraitModel.CHANNEL)
        -- 鉴赏里模型自投影(衣服、头发落在身上的阴影);舞台灯只照预览通道,远在地图下方,不会投到世界里
        mesh:call("set_DrawShadowCast", true)
        entry.copy, entry.copy_mesh = object, mesh
    end
    -- 舞台灯组:每盏一个对象 + SpotLight,只照预览通道(有限光源,不会照到世界)
    local rig_lights = {}
    local function try(light, method, value) pcall(light.call, light, method, value) end
    function adapter.light(objects)
        rig_lights = {}
        for i, spec in ipairs(PortraitModel.RIG) do
            local light = component(objects[i], "via.render.SpotLight")
            light:call("set_RenderOutputID", PortraitModel.CHANNEL)
            light:call("set_Color", Vector3f.new(spec.color[1], spec.color[2], spec.color[3]))
            -- System.Single 必须传 Lua 浮点数,整数会按整数打包成 0
            try(light, "set_Unit", 2)
            try(light, "set_UsingSameIntensity", true)
            try(light, "set_BlackBodyRadiation", false)
            light:call("set_Intensity", spec.intensity + 0.0)
            light:call("set_Cone", spec.cone + 0.0)
            try(light, "set_Spread", 10.0)
            try(light, "set_Falloff", 1.0)
            try(light, "set_Radius", 1.0)
            try(light, "set_ReferenceEffectiveRange", spec.range + 0.0)
            try(light, "set_AOEfficiency", spec.ao + 0.0)
            try(light, "set_DetailShadow", spec.detail + 0.0)
            light:call("set_ShadowEnable", true)
            try(light, "set_ShadowVariance", spec.variance + 0.0)
            try(light, "set_ShadowDepthBias", spec.depth_bias + 0.0)
            try(light, "set_ShadowSlopeBias", spec.slope_bias + 0.0)
            try(light, "set_ShadowBias", spec.bias + 0.0)
            try(light, "set_ShadowNearPlane", spec.near + 0.0)
            rig_lights[i] = light
        end
    end
    -- 灯组按角色根(anchor)的朝向摆在舞台原点周围;角色转身才重写副本的 LIL_LightDir
    function adapter.light_follow(objects, context)
        local q = anchor_of(context):call("get_Rotation")
        local root = { q.w, q.x, q.y, q.z }
        for i, pose in ipairs(PortraitModel.rig_poses(root)) do
            local tr = objects[i] and objects[i]:call("get_Transform")
            if tr then
                tr:call("set_Position", Vector3f.new(pose.pos[1], pose.pos[2], pose.pos[3]))
                tr:call("set_Rotation", Quaternion.new(pose.rot[1], pose.rot[2], pose.rot[3], pose.rot[4]))
            end
        end
        local dir = PortraitModel.lil_light_dir(root)
        local key = string.format("%.3f|%.3f|%.3f", dir[1], dir[2], dir[3])
        if key == lil_key or not lil_entries then return end
        local value = Vector4f.new(dir[1], dir[2], dir[3], dir[4])
        for _, entry in ipairs(lil_entries) do
            for _, slot in ipairs(entry.lil or {}) do entry.copy_mesh:call("setMaterialFloat4", slot[1], slot[2], value) end
        end
        lil_key = key
    end
    -- 「灯光强度」设置:整组按比例缩放
    function adapter.light_intensity(_, value)
        for i, light in ipairs(rig_lights) do
            pcall(light.call, light, "set_Intensity", PortraitModel.RIG[i].intensity * value + 0.0)
        end
    end
    -- 把原网格当前的材质参数(float / float4)整份抄到副本:AVM 改的颜色、调色盘、溶解进度,
    -- 以及别的脚本写的参数都在原网格的实例上,副本只拿到 mdf2 默认值。顺便记下 LIL_LightDir 的位置。
    -- 建副本时抄一次;调色盘改了值(Palette.revision 变了)再抄一次,见 refresh_params。
    local function copy_params(entry)
        local src, dst = entry.source, entry.copy_mesh
        entry.lil = {}
        for m = 0, math.min(src:call("get_MaterialNum"), dst:call("get_MaterialNum")) - 1 do
            -- 个别材质读写失败只跳过这一个材质,不让整个预览报错
            pcall(function()
            local n = src:call("getMaterialVariableNum", m)
            if n == dst:call("getMaterialVariableNum", m) then
                for v = 0, n - 1 do
                    local kind = src:call("getMaterialVariableType", m, v)
                    if kind == 4 then
                        dst:call("setMaterialFloat4", m, v, src:call("getMaterialFloat4", m, v))
                    elseif kind == 1 then
                        dst:call("setMaterialFloat", m, v, src:call("getMaterialFloat", m, v) + 0.0)
                    end
                end
                local idx = dst:call("getMaterialVariableIndex", m, LIL_HASH)
                if idx and idx >= 0 and idx < n and dst:call("getMaterialVariableName", m, idx) == LIL_VAR then
                    entry.lil[#entry.lil + 1] = { m, idx }
                end
            end
            end)
        end
    end
    function adapter.after_bind(entries)
        for _, entry in ipairs(entries) do
            local src, dst = entry.source, entry.copy_mesh
            -- 新建的网格组件不会按资源分配形态键权重槽(2026-11-05 实测副本 BlendShapeChannelWeightCount = 0,
            -- 原网格头部 513),不设的话 DLL 的权重镜像因两边通道数不同直接跳过
            pcall(function()
                local count = src:call("get_BlendShapeChannelWeightCount")
                if count and count > 0 and dst:call("get_BlendShapeChannelWeightCount") ~= count then
                    dst:call("set_BlendShapeChannelWeightCount", count)
                end
            end)
            copy_params(entry)
        end
        lil_entries, lil_key = entries, nil
    end
    -- 调色盘改了原网格的参数:重抄到副本。抄过来的 LIL_LightDir 是世界里的值,清掉 lil_key 让下一次
    -- light_follow 改回舞台的方向。
    function adapter.refresh_params(entries)
        for _, entry in ipairs(entries) do
            if entry.copy_mesh then pcall(copy_params, entry) end
        end
        lil_key = nil
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
    -- 角色根落在舞台原点 (0, STAGE_Y, 0)
    function adapter.offset(context)
        local root = anchor_of(context):call("get_Position")
        return -root.x, PortraitModel.STAGE_Y - root.y, -root.z
    end
    function adapter.valid(object) return sdk.is_managed_object(object) and object:call("get_Valid") == true end
    function adapter.destroy(object)
        assert(object_type:get_method("destroy(via.GameObject)")):call(nil, object)
    end
    return adapter
end

-- 装备变化先停旧副本并确认销毁,再重建;每次更新最多创建两个网格,避免一次性构造整套装备。
function PortraitModel.new(deps)
    deps = deps or {}
    local bridge = deps.bridge or function() return rawget(_G, "avm_portrait") or rawget(_G, "avm_bridge") end
    local adapter, clock = deps.adapter or PortraitModel.game_adapter({ bridge = bridge, skip = deps.skip }), deps.clock or os.clock
    local self = { state = "idle" }
    local objects, entries, signature, key, cursor, next_inventory, deadline = {}, {}, nil, nil, 1, 0, 0
    local bound, rebuild, cleanup_failed, failed_reference = false, false, false, nil
    local light_intensity, applied_intensity = 1.0, nil
    local rig = {}                       -- 灯组对象(也在 objects 里,随副本一起销毁)
    local refresh_fps, next_sync = 0, nil
    local revision_of = deps.revision or palette_revision   -- 调色盘版本号(没有调色盘时为 nil)
    local params_revision = nil
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
            rig = {}
            for _, spec in ipairs(PortraitModel.RIG) do rig[#rig + 1] = own("AVM_PortraitLight_" .. spec.name) end
            adapter.light(rig)
            applied_intensity = 1.0
        end
        if applied_intensity ~= light_intensity and adapter.light_intensity then
            adapter.light_intensity(rig, light_intensity)
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
            if adapter.after_bind then adapter.after_bind(entries) end
            params_revision = revision_of and revision_of() or nil
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
        -- 形态键权重(SKS / 游戏 / 其他 MOD 写在原网格实例上)镜像到副本;旧 DLL 没有这个接口就跳过
        if api.portrait_blend_sync then assert(api.portrait_blend_sync() == 0, api.portrait_pose_error()) end
        -- 调色盘改了值:副本重抄材质参数(只改参数,网格实例不变,不用重建)
        if revision_of and adapter.refresh_params then
            local current = revision_of()
            if current ~= params_revision then adapter.refresh_params(entries); params_revision = current end
        end
        if adapter.light_follow then adapter.light_follow(rig, context) end
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

-- 灯组每盏灯的世界姿态:RIG 的 pos / rot(角色根本地)按角色根朝向转到舞台原点。root_rot = { w, x, y, z }。
-- 纯函数,便于离线测试。
function PortraitModel.rig_poses(root_rot)
    local out = {}
    for i, spec in ipairs(PortraitModel.RIG) do out[i] = PortraitModel.stage_pose(root_rot, spec) end
    return out
end

-- 副本的 LIL_LightDir:LIL_DIR(角色根本地)按角色根朝向转到世界,权重 1。
function PortraitModel.lil_light_dir(root_rot)
    local pose = PortraitModel.stage_pose(root_rot, { pos = PortraitModel.LIL_DIR, rot = { 1, 0, 0, 0 } })
    local x, y, z = pose.pos[1], pose.pos[2] - PortraitModel.STAGE_Y, pose.pos[3]
    local len = math.sqrt(x * x + y * y + z * z)
    if len < 1e-4 then return { 0.0, 1.0, 0.0, 1.0 } end
    return { x / len, y / len, z / len, 1.0 }
end

-- 舞台上的相机世界姿态:局部姿态(Portrait.pose 的 pos / rot,角色根空间)按角色根的朝向转到舞台原点。
-- root_rot = { w, x, y, z };返回 { pos = {x,y,z}, rot = {w,x,y,z} }。纯函数,便于离线测试。
function PortraitModel.stage_pose(root_rot, pose)
    local w, x, y, z = root_rot[1], root_rot[2], root_rot[3], root_rot[4]
    local v = pose.pos
    -- q * v * q^-1
    local ix = w * v[1] + y * v[3] - z * v[2]
    local iy = w * v[2] + z * v[1] - x * v[3]
    local iz = w * v[3] + x * v[2] - y * v[1]
    local iw = -x * v[1] - y * v[2] - z * v[3]
    local px = ix * w - iw * x - iy * z + iz * y
    local py = iy * w - iw * y - iz * x + ix * z
    local pz = iz * w - iw * z - ix * y + iy * x
    local b = pose.rot
    local rot = {
        w * b[1] - x * b[2] - y * b[3] - z * b[4],
        w * b[2] + x * b[1] + y * b[4] - z * b[3],
        w * b[3] - x * b[4] + y * b[1] + z * b[2],
        w * b[4] + x * b[3] - y * b[2] + z * b[1],
    }
    return { pos = { px, PortraitModel.STAGE_Y + py, pz }, rot = rot }
end

return PortraitModel
