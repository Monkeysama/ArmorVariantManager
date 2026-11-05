-- 模型高度:只抬高画面上的骨架,不改角色坐标、碰撞和物理(思路同 Wilds 的 GroundClippingFix)。
--
-- 做法:每帧动画开始前(pre UpdateMotion)还原上一帧写的偏移,在 pre LateUpdateBehavior 把骨架
-- 根骨骼 root 的世界坐标 y 加上 N 厘米;身体 / 头 / 头发 / 外套都是 SameJointsConstraint 的子对象、
-- 武器挂在 root 上,会一起跟上。
--
-- 时机是实测选的(tools/height_probe,2026-11-05,Leon):
--   * LateUpdateBehavior 之后 / 身体更新器 lateUpdate 之后 / PrepareRendering 之前也都能让部件跟上,
--     但镜头已经按没抬高的骨骼算好了 —— 第一人称开镜会先停在偏低处 0.5~1 秒再上抬归位;
--   * LateUpdateBehavior 之前写,镜头、瞄具、模型读的是同一个姿态,开镜正常,代价是视角跟着抬高
--     (穿高跟本来眼睛就高,几厘米感觉不到)。
-- 另在 pre PrepareRendering 兜底:那时还没抬上(比如这一帧刚出现的目标),或者被别的东西改回去了,就补一次。
--
-- 还原只在 root 的局部坐标仍是我们写的值时才做 —— 别的动画或 MOD 改过就不碰。
--
-- 用法:local hf = HeightFix.new({ skeleton_of = fn(source) -> via.Transform })
--       每帧 hf.set_targets({ { source = ..., cm = 8 }, ... })(cm 为 0 / nil 的不用传)
local HeightFix = {}

local function same(a, b)
    return a and b and math.abs(a.x - b.x) < 1e-5 and math.abs(a.y - b.y) < 1e-5 and math.abs(a.z - b.z) < 1e-5
end
local function vec(v) return v and Vector3f.new(v.x, v.y, v.z) or nil end

-- deps.skeleton_of(source) -> 带 root 关节的 Transform;deps.on_error(msg) 可选;
-- deps.re 只给测试替换回调注册用
function HeightFix.new(deps)
    local re_ = deps.re or re
    local api = {}
    local wanted = {}         -- 本帧要抬的:{ { source, cm } }
    local applied = {}        -- 关节地址 -> { joint, base, written }
    local alive = true
    local reported = {}

    local function report(err)
        local msg = tostring(err)
        if reported[msg] then return end
        reported[msg] = true
        if deps.on_error then pcall(deps.on_error, msg) end
    end

    local function root_of(source)
        local tr = deps.skeleton_of(source)
        return tr and tr:call("getJointByName", "root")
    end

    local function restore_all()
        for key, a in pairs(applied) do
            applied[key] = nil
            local ok, err = pcall(function()
                if same(a.joint:call("get_LocalPosition"), a.written) then
                    a.joint:call("set_LocalPosition", a.base)
                end
            end)
            if not ok then report(err) end
        end
    end

    -- 抬一个目标;同一副骨架只抬一次(两个目标共用骨架时不叠加)
    local function lift(entry, only_missing)
        local root = root_of(entry.source)
        if not root then return end
        local key = root:get_address()
        local a = applied[key]
        if a then
            -- 兜底:已经抬过且没被改动 → 不动;被改回去了 → 以现在的值为底重新抬
            if only_missing and same(root:call("get_LocalPosition"), a.written) then return end
            if not only_missing then return end
        end
        local base = vec(root:call("get_LocalPosition"))
        local p = root:call("get_Position")
        root:call("set_Position", Vector3f.new(p.x, p.y + entry.cm / 100.0, p.z))
        applied[key] = { joint = root, base = base, written = vec(root:call("get_LocalPosition")) }
    end

    local function lift_all(only_missing)
        for _, entry in ipairs(wanted) do
            local ok, err = pcall(lift, entry, only_missing)
            if not ok then report(err) end
        end
    end

    function api.set_targets(list)
        local out = {}
        for _, e in ipairs(type(list) == "table" and list or {}) do
            local cm = tonumber(e.cm)
            if e.source and cm and math.abs(cm) >= 0.05 then out[#out + 1] = { source = e.source, cm = cm } end
        end
        wanted = out
    end

    function api.shutdown()
        alive = false
        wanted = {}
        restore_all()
    end

    -- 测试用
    api._restore, api._lift, api._fallback = restore_all, function() lift_all(false) end, function() lift_all(true) end

    re_.on_pre_application_entry("UpdateMotion", function() if alive then restore_all() end end)
    re_.on_pre_application_entry("LateUpdateBehavior", function() if alive then lift_all(false) end end)
    re_.on_pre_application_entry("PrepareRendering", function() if alive then lift_all(true) end end)
    if re_.on_script_reset then re_.on_script_reset(api.shutdown) end
    return api
end

return HeightFix
