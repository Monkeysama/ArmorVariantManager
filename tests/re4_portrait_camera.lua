-- RE4 全身预览相机:默认参数与原来的固定机位一致;环绕时始终看向目标点;缩放只改视角;
-- 平移沿画面的右 / 上方向;相机参数的清洗。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local P = require("ArmorVariantManager_Core.Games.RE4.Portrait")

local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end
local ASPECT = 660 / 720

-- 用四元数 (w, x, y, z) 旋转向量
local function rotate(q, v)
    local w, x, y, z = q[1], q[2], q[3], q[4]
    local ix = w * v[1] + y * v[3] - z * v[2]
    local iy = w * v[2] + z * v[1] - x * v[3]
    local iz = w * v[3] + x * v[2] - y * v[1]
    local iw = -x * v[1] - y * v[2] - z * v[3]
    return { ix * w + iw * -x + iy * -z - iz * -y, iy * w + iw * -y + iz * -x - ix * -z, iz * w + iw * -z + ix * -y - iy * -x }
end

local settings = P.settings({ distance = 3, height = 0.1 })

-- 默认相机 = 原来的机位:根前方 distance 处、高度 0.95 + height、不旋转、竖向容纳 1.95 m
local base = P.pose(settings, P.camera(nil), ASPECT, ASPECT)
assert(near(base.pos[1], 0) and near(base.pos[2], 1.05) and near(base.pos[3], 3), "default position unchanged")
assert(near(base.rot[1], 1) and near(base.rot[2], 0) and near(base.rot[3], 0) and near(base.rot[4], 0), "default rotation identity")
assert(near(base.fov, math.deg(2 * math.atan(0.975 / 3))), "default fov fits 1.95 m")

-- 环绕:任意 yaw / pitch 下,相机的前方(-Z)都指向目标点,且到目标点距离 = distance
for _, c in ipairs({ { yaw = 0.7, pitch = 0.4 }, { yaw = -2.5, pitch = -0.9 }, { yaw = 3.0, pitch = 1.1 } }) do
    local cam = P.camera(c)
    local pose = P.pose(settings, cam, ASPECT, ASPECT)
    local target = { 0, 1.05, 0 }
    local to = { target[1] - pose.pos[1], target[2] - pose.pos[2], target[3] - pose.pos[3] }
    local len = math.sqrt(to[1] ^ 2 + to[2] ^ 2 + to[3] ^ 2)
    assert(near(len, 3, 1e-5), "orbit keeps the distance")
    local fwd = rotate(pose.rot, { 0, 0, -1 })
    assert(near(fwd[1], to[1] / len, 1e-5) and near(fwd[2], to[2] / len, 1e-5) and near(fwd[3], to[3] / len, 1e-5),
        "camera looks at the target")
    local up = rotate(pose.rot, { 0, 1, 0 })
    assert(up[2] > 0, "camera stays upright")
end
-- pitch 为正 = 从上往下看
assert(P.pose(settings, P.camera({ pitch = 0.5 }), ASPECT, ASPECT).pos[2] > 1.05)

-- 缩放只改视角,不动机位;放大 2 倍时竖向可见高度减半
local zoomed = P.pose(settings, P.camera({ zoom = 2 }), ASPECT, ASPECT)
assert(near(zoomed.pos[3], 3) and near(math.tan(math.rad(zoomed.fov / 2)) * 2, math.tan(math.rad(base.fov / 2))),
    "zoom halves the visible height")

-- 平移:pan_x 正 = 目标点往画面右边移(相机跟着右移),pan_y 正 = 往上
local panned = P.pose(settings, P.camera({ pan_x = 0.3, pan_y = 0.2 }), ASPECT, ASPECT)
assert(near(panned.pos[1], 0.3) and near(panned.pos[2], 1.25) and near(panned.pos[3], 3), "pan along screen right / up")
-- 转到侧面后,右方向随之转动
local side = P.pose(settings, P.camera({ yaw = math.pi / 2, pan_x = 0.3 }), ASPECT, ASPECT)
assert(near(side.pos[1], 3, 1e-5) and near(side.pos[3], -0.3, 1e-5), "pan follows the orbit")

-- 槽位比 rtex 扁时放大竖向视角(同原来的裁切补偿)
local wide = P.pose(settings, P.camera(nil), 2.0, ASPECT)
assert(wide.fov > base.fov)

-- 清洗:范围、非数、yaw 归一化
local c = P.camera({ yaw = 7, pitch = 9, zoom = 0, pan_x = "x", pan_y = -9 })
assert(near(c.yaw, 7 - 2 * math.pi) and c.pitch == 1.2 and c.zoom == 0.5 and c.pan_x == 0 and c.pan_y == -2)
local n = P.camera({ zoom = 0 / 0, yaw = math.huge })
assert(n.zoom == 1 and near(n.yaw, 0))

print("PASS: RE4 portrait camera keeps the default framing, orbits around the target, zooms by fov, pans in screen space and sanitizes input")
