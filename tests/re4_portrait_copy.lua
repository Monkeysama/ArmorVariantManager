-- RE4 全身预览显示副本:舞台相机姿态(按角色根朝向转到舞台原点),以及 RE4 的 PortraitModel.new
-- 把 adapter 交给共用状态机(建副本 → 绑定 → 同步 → 换人重建)。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local M = require("ArmorVariantManager_Core.Games.RE4.PortraitModel")

local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end

-- 根不转:相机就是局部姿态平移到舞台原点
local pose = { pos = { 0.5, 1.2, 3.0 }, rot = { 1, 0, 0, 0 } }
local w = M.stage_pose({ 1, 0, 0, 0 }, pose)
assert(near(w.pos[1], 0.5) and near(w.pos[2], M.STAGE_Y + 1.2) and near(w.pos[3], 3.0), "identity root keeps local offset")
assert(near(w.rot[1], 1) and near(w.rot[2], 0) and near(w.rot[3], 0) and near(w.rot[4], 0), "identity root keeps rotation")

-- 根绕 Y 转 90°(+Z 转到 +X):角色正前方的相机跟着转到 +X
local h = math.sqrt(0.5)
local yaw90 = { h, 0, h, 0 }
w = M.stage_pose(yaw90, { pos = { 0, 1, 3 }, rot = { 1, 0, 0, 0 } })
assert(near(w.pos[1], 3, 1e-6) and near(w.pos[2], M.STAGE_Y + 1) and near(w.pos[3], 0, 1e-6), "camera follows root yaw")
assert(near(w.rot[1], h) and near(w.rot[3], h), "camera rotation composes with root yaw")

-- 副本的 LIL_LightDir:从头部(舞台原点上方)指向补光,单位向量 + 权重 1
local d = M.lil_light_dir({ 0, M.STAGE_Y + 1.45, 2 })
assert(near(d[1], 0) and near(d[2], 0) and near(d[3], 1) and d[4] == 1, "light in front of the head")
d = M.lil_light_dir({ 3, M.STAGE_Y + 1.45 + 4, 0 })
assert(near(d[1], 0.6) and near(d[2], 0.8) and near(d[3], 0), "normalized toward the light")

-- 舞台主光相对角色固定:根不转时在角色上方偏一侧,角色转身主光跟着转;LIL_LightDir 指向它
local key = M.key_light({ 1, 0, 0, 0 })
assert(key[2] > M.STAGE_Y + 3 and key[1] > 0, "key light above and to the side")
local kd = M.lil_light_dir(key)
assert(kd[2] > 0.8 and kd[4] == 1, "LIL_LightDir points at the key light")
local turned = M.key_light(yaw90)   -- 根绕 Y 转 90°:本地 +X 转到世界 -Z
assert(near(turned[2], key[2]) and near(turned[3], -key[1], 1e-6) and near(turned[1], key[3], 1e-6), "key light turns with the character")

-- 状态机:两个网格,每次 current 最多建两个,建完绑定、同步;key 变了先销毁再重建
local log = {}
local live = {}
local adapter = {
    inventory = function(ctx) return { { source = "a" }, { source = "b" } }, ctx.key end,
    create = function(name) local o = { name = name }; live[o] = true; return o end,
    disable = function() end, enable = function(o) log[#log + 1] = "enable " .. o.name end,
    clone = function(o, e) e.copy, e.copy_mesh = o, o end,
    light = function() end, light_follow = function() end,
    ready = function() return true end,
    batch = function(entries) return { #entries } end,
    after_bind = function(entries) log[#log + 1] = "after_bind " .. #entries end,
    offset = function() return 0, M.STAGE_Y, 0 end,
    valid = function(o) return live[o] == true end,
    destroy = function(o) live[o] = nil end,
}
local api = {
    portrait_pose_version = function() return 3 end,
    portrait_pose_bind = function(n) log[#log + 1] = "bind " .. tostring(n[1]); return 0 end,
    portrait_pose_sync = function() log[#log + 1] = "sync"; return 0 end,
    portrait_blend_sync = function() log[#log + 1] = "blend"; return 0 end,
    portrait_pose_clear = function() log[#log + 1] = "clear" end,
    portrait_pose_error = function() return "" end,
}
local model = M.new({ adapter = adapter, bridge = function() return api end, clock = function() return 0 end })
assert(model.current({ key = "leon" }) == true, "two meshes build, bind and sync in one call")
assert(model.state == "ready")
local joined = table.concat(log, ",")
assert(joined:find("bind 2,after_bind 2", 1, true) and joined:find("sync", 1, true), "bound both copies then synced: " .. joined)
assert(joined:find("sync,blend", 1, true), "blend shapes mirrored right after the pose: " .. joined)
assert(model.sync({ key = "leon" }) == true, "per-frame sync")
-- 旧 DLL 没有 portrait_blend_sync:照常同步姿态
api.portrait_blend_sync = nil
assert(model.sync({ key = "leon" }) == true, "old DLL without blend sync still syncs")

-- 换人:旧副本(1 盏灯 + 2 个网格)先销毁,模型回到 idle 后再建新的
assert(model.current({ key = "ashley" }) == false, "subject change stops first")
assert(next(live) == nil, "old copies destroyed")
assert(model.state == "idle")
assert(model.current({ key = "ashley" }) == true and model.state == "ready", "rebuilt for the new subject")
print("re4_portrait_copy ok")
