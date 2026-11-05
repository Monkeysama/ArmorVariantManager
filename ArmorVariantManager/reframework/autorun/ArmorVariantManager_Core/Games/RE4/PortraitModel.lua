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
-- 舞台高度。不能太远:float32 在 ±10000 附近的最小间隔约 0.001 m,副本每个关节的高度被各自取整到毫米格子上,
-- 预览里人物会微微抖(2026-11-05 实测:原角色头部高度平滑变化,副本在 1.4648 / 1.4658 / 1.4668 之间跳)。
-- -1000 处间隔约 0.00006 m,看不出来;地图底下 1 km 也不会有场景物体进到预览相机里。
PortraitModel.STAGE_Y = -1000
PortraitModel.CHANNEL = 8           -- 和 Portrait.lua 的相机输出位一致(via.render.RenderOutputID.Quateary)
-- 舞台打光是固定的"摄影棚":不跟世界的灯,也不跟预览相机,只相对角色固定,在哪里、什么环境预览都一个样子。
--   主光:从角色的上方偏一侧照下来。方向取自 2026-11-05 用户选的基准场景(雨夜林子,月光):
--         lil_toon_light_re4.lua 在那里算出的主光方向,换算到角色根的本地空间约 (0.43, 0.88, 0.19)。
--   补光:很弱,跟着预览相机,只是不让转到暗面时一片死黑。
-- 强度在固定曝光 EV 3.5(见 Portrait.lua STAGE_EV)下和用户在游戏里调;荒野的 60000 在 RE4 会整个发白。
local KEY_DIR = { 0.43, 0.88, 0.19 }   -- 角色根本地空间,指向主光(未归一化)
local KEY_DISTANCE = 3.0
local KEY_INTENSITY = 300.0
local FILL_INTENSITY = 60.0
-- lilToon(用户的 RE4 自定义材质)的阴影、阴影边缘色、背光、边缘阴影都看 LIL_LightDir =(指向光源的方向, 权重)。
-- 世界里的角色由 lil_toon_light_re4.lua 每帧按场景灯光写;副本没人写就退回与光无关的样子(暗部发灰),
-- 所以副本自己写一份,指向舞台主光。
local LIL_VAR, LIL_HASH = "LIL_LightDir", 486944339
local LIL_HEAD = 1.45               -- 估算的头部高度(角色根在舞台原点)

local function identity(value) return tostring(value:get_address()) end

local function require_native(bridge)
    local api = bridge()
    assert(api and api.portrait_pose_version and api.portrait_pose_version() >= 3,
        "Portrait visibility native module missing; restart with the updated ArmorVariantManager_Portrait.dll")
    return api
end

-- context = { key = 角色标识, root = 角色根 Transform, anchor = 骨架的 root 关节(没有时为 nil),
--             light = { x, y, z } | nil(补光的世界位置) }
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
    local fill_object = nil

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
        mesh:call("set_DrawShadowCast", false)
        entry.copy, entry.copy_mesh = object, mesh
    end
    -- 远处舞台没有场景光,放两盏只照预览通道的点光(有限光源,不会照到世界):key 主光、fill 补光
    local function point_light(object, intensity)
        local light = component(object, "via.render.PointLight")
        light:call("set_RenderOutputID", PortraitModel.CHANNEL)
        light:call("set_Color", Vector3f.new(1, 1, 1))
        -- System.Single 必须传 Lua 浮点数,整数会按整数打包成 0
        light:call("set_Intensity", intensity + 0.0)
        light:call("set_Radius", 8.0)
        light:call("set_ShadowEnable", false)
        object:call("get_Transform"):call("set_Position", Vector3f.new(0, PortraitModel.STAGE_Y + 2.0, 2.0))
    end
    function adapter.light(key, fill)
        point_light(key, KEY_INTENSITY)
        if fill then point_light(fill, FILL_INTENSITY); fill_object = fill end
    end
    -- 主光按角色朝向摆在固定的相对位置;补光跟着预览相机(Portrait 每帧算好位置放进 context.light)。
    -- 主光方向变了(角色转身)才重写副本的 LIL_LightDir
    function adapter.light_follow(object, context)
        local q = anchor_of(context):call("get_Rotation")
        local key = PortraitModel.key_light({ q.w, q.x, q.y, q.z })
        object:call("get_Transform"):call("set_Position", Vector3f.new(key[1], key[2], key[3]))
        local p = context.light
        if p and fill_object then fill_object:call("get_Transform"):call("set_Position", Vector3f.new(p[1], p[2], p[3])) end
        local dir = PortraitModel.lil_light_dir(key)
        local key = string.format("%.3f|%.3f|%.3f", dir[1], dir[2], dir[3])
        if key == lil_key or not lil_entries then return end
        local value = Vector4f.new(dir[1], dir[2], dir[3], dir[4])
        for _, entry in ipairs(lil_entries) do
            for _, slot in ipairs(entry.lil or {}) do entry.copy_mesh:call("setMaterialFloat4", slot[1], slot[2], value) end
        end
        lil_key = key
    end
    function adapter.light_intensity(object, value)
        local light = assert(object:call("getComponent(System.Type)", sdk.typeof("via.render.PointLight")))
        light:call("set_Intensity", KEY_INTENSITY * value)
    end
    -- 绑定后把原网格当前的材质参数(float / float4)整份抄到副本:AVM 改的颜色、溶解进度,
    -- 以及别的脚本写的参数都在原网格的实例上,副本只拿到 mdf2 默认值。顺便记下 LIL_LightDir 的位置。
    -- 只在建副本时抄一次;之后实时跟着变的参数另外处理。
    function adapter.after_bind(entries)
        for _, entry in ipairs(entries) do
            local src, dst = entry.source, entry.copy_mesh
            entry.lil = {}
            -- 新建的网格组件不会按资源分配形态键权重槽(2026-11-05 实测副本 BlendShapeChannelWeightCount = 0,
            -- 原网格头部 513),不设的话 DLL 的权重镜像因两边通道数不同直接跳过
            pcall(function()
                local count = src:call("get_BlendShapeChannelWeightCount")
                if count and count > 0 and dst:call("get_BlendShapeChannelWeightCount") ~= count then
                    dst:call("set_BlendShapeChannelWeightCount", count)
                end
            end)
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
        lil_entries, lil_key = entries, nil
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
    local refresh_fps, next_sync = 0, nil
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
            adapter.light(own("AVM_PortraitLight"), own("AVM_PortraitFill"))
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
            if adapter.after_bind then adapter.after_bind(entries) end
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

-- 舞台主光的世界坐标:KEY_DIR(角色根本地)按角色根朝向转到世界,从舞台上的头部位置出发 KEY_DISTANCE 米。
-- root_rot = { w, x, y, z }。纯函数,便于离线测试。
function PortraitModel.key_light(root_rot)
    local len = math.sqrt(KEY_DIR[1] ^ 2 + KEY_DIR[2] ^ 2 + KEY_DIR[3] ^ 2)
    local v = { KEY_DIR[1] / len * KEY_DISTANCE, KEY_DIR[2] / len * KEY_DISTANCE + LIL_HEAD, KEY_DIR[3] / len * KEY_DISTANCE }
    local pose = PortraitModel.stage_pose(root_rot, { pos = v, rot = { 1, 0, 0, 0 } })
    return pose.pos
end

-- 副本的 LIL_LightDir:从头部指向主光的单位向量,权重 1(满阴影)。light = 主光世界坐标。
function PortraitModel.lil_light_dir(light)
    local x, y, z = light[1], light[2] - (PortraitModel.STAGE_Y + LIL_HEAD), light[3]
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
