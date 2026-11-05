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

-- 灯组照搬模型鉴赏 set00:5 盏聚光,每盏的 rot 是单位四元数,且 -Z(照射方向)和实测一致
local function rotate(q, v)
    local w, x, y, z = q[1], q[2], q[3], q[4]
    local tx, ty, tz = 2 * (y * v[3] - z * v[2]), 2 * (z * v[1] - x * v[3]), 2 * (x * v[2] - y * v[1])
    return { v[1] + w * tx + (y * tz - z * ty), v[2] + w * ty + (z * tx - x * tz), v[3] + w * tz + (x * ty - y * tx) }
end
assert(#M.RIG == 5, "five spotlights")
local aims = { KeyMain = { -0.162, -0.588, -0.792 }, KeySub = { -0.283, -0.871, -0.401 }, Fill = { 0.728, 0.664, -0.171 },
    BackL = { 0.437, -0.208, 0.875 }, BackR = { -0.926, -0.27, 0.264 } }
for _, spec in ipairs(M.RIG) do
    local q = spec.rot
    assert(near(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2, 1, 1e-3), spec.name .. " rotation is unit")
    local f, a = rotate(q, { 0, 0, -1 }), aims[spec.name]
    assert(a and near(f[1], a[1], 2e-3) and near(f[2], a[2], 2e-3) and near(f[3], a[3], 2e-3), spec.name .. " aims as measured")
end

-- 根不转:灯在舞台原点 + 本地偏移;根转 90°:跟着转
local poses = M.rig_poses({ 1, 0, 0, 0 })
assert(near(poses[1].pos[1], M.RIG[1].pos[1]) and near(poses[1].pos[2], M.STAGE_Y + M.RIG[1].pos[2]), "identity root keeps rig offsets")
local turned = M.rig_poses(yaw90)
assert(near(turned[1].pos[1], M.RIG[1].pos[3], 1e-6) and near(turned[1].pos[3], -M.RIG[1].pos[1], 1e-6), "rig turns with the character")

-- 副本的 LIL_LightDir:鉴赏默认 (0.4, 0.8, 0.45) 归一化,随角色转身;权重 1
local d = M.lil_light_dir({ 1, 0, 0, 0 })
local n = math.sqrt(0.4 ^ 2 + 0.8 ^ 2 + 0.45 ^ 2)
assert(near(d[1], 0.4 / n) and near(d[2], 0.8 / n) and near(d[3], 0.45 / n) and d[4] == 1, "viewer default light dir")
local dt = M.lil_light_dir(yaw90)
assert(near(dt[1], 0.45 / n, 1e-6) and near(dt[3], -0.4 / n, 1e-6) and near(dt[2], d[2]), "light dir turns with the character")

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

-- 调色盘改了值(revision 变了):下一次同步重抄材质参数;没变就不抄
do
    local rev, refreshed = 0, 0
    local a2 = setmetatable({ refresh_params = function() refreshed = refreshed + 1 end }, { __index = adapter })
    local m2 = M.new({ adapter = a2, bridge = function() return api end, clock = function() return 0 end, revision = function() return rev end })
    assert(m2.current({ key = "leon" }) == true and refreshed == 0, "fresh copy already has the current params")
    assert(m2.sync({ key = "leon" }) and refreshed == 0, "unchanged revision: no recopy")
    rev = 3
    assert(m2.sync({ key = "leon" }) and refreshed == 1, "palette edit: recopy once")
    assert(m2.sync({ key = "leon" }) and refreshed == 1, "same revision: no second recopy")
    m2.shutdown()
end

-- 换人:旧副本(灯组 + 2 个网格)先销毁,模型回到 idle 后再建新的
assert(model.current({ key = "ashley" }) == false, "subject change stops first")
assert(next(live) == nil, "old copies destroyed")
assert(model.state == "idle")
assert(model.current({ key = "ashley" }) == true and model.state == "ready", "rebuilt for the new subject")
print("re4_portrait_copy ok")
