-- 溶解过渡(移植自 MHWilds 差分管理器 4.4.0-community 的 Dissolve.lua)。
--
-- 只对带 `Dissolve_Rate` 变量的材质生效(LIL_Toon_RE4_Dissolve 这类溶解模板);其余材质照旧瞬间开关。
-- 变量语义(实测 RE4 的 Shinano 溶解模板,和崛起 DissolveTransition 的已验证做法一致):
--   Dissolve_Rate  xyz = 已溶掉的比例 0..1(0 完整,1 全消失),w = Reversing(0 中心向外;1 外向中心)
--   Dissolve_Flag  mdf2 默认 (1,0,0,0);动画期间 y 固定写 0,x/z/w 保持原值
-- 消失 = 比例 0 → 1,结束时关掉材质;出现 = 先写成 1(全消失)再打开材质,比例 1 → 0,即消失倒放。
-- 以前出现方写 y = 1(IsMorphed)、比例 0 → 1,模板并不按"出现方"解释 y,出现时直接闪现。
-- 结束时变量恢复成 mdf2 的值。
--
-- 两种驱动:
--   * 定时过渡:Dissolve.use(settings) 选好本次开关用的过渡,再调 set_material;update() 每帧推进
--   * 血量驱动:drive_progress 给出平滑后的进度(缓入缓出地追向目标,约 DRIVE_SMOOTH 秒到位,
--     每秒最多变化 DRIVE_MAX_SPEED;血量一截截掉时也连续溶解),drive_material 按进度直接写;
--     进度在 (0,1) 内两方都开着,到 0 / 1 才关掉完全隐藏的一方。没有 Dissolve_Rate 的材质在进度过半时切换
local Dissolve = {}
local RATE, FLAG = "Dissolve_Rate", "Dissolve_Flag"
local OFF = { enabled = false, dur = 0, forward = true }
Dissolve.OFF = OFF
local DRIVE_SMOOTH = 0.8    -- 血量驱动:追向目标的平滑时间(秒,SmoothDamp 的 smoothTime)
local DRIVE_MAX_SPEED = 0.6 -- 血量驱动:进度每秒最多变化多少

local current = OFF         -- 本次 set_material 用的过渡(Dissolve.use)
local var_cache = {}        -- mesh_j_材质名 -> { rate = 序号, flag = 序号或 nil, flag0 = mdf2 原值 } 或 false
local mat_anims = {}        -- 每个材质一个:{ mesh, j, v, phase, forward, u, dur }
local drive_p = {}          -- 驱动键 -> 平滑后的进度
local drive_v = {}          -- 驱动键 -> 进度的变化速度(每秒)
local driven = {}           -- mesh_j -> 血量驱动上次写入的进度
local last_clock = os.clock()
local frame_dt = 0

local function try(f) local ok, r = pcall(f); if ok then return r end; return nil end

-- settings = { enabled, dur, forward };nil / 未启用 = 瞬间开关
function Dissolve.use(settings)
    if type(settings) ~= "table" or settings.enabled ~= true then current = OFF; return end
    current = { enabled = true, forward = settings.forward ~= false, dur = math.max(0, tonumber(settings.dur) or 0.5) }
end

local function find_var(mesh, j)
    local name = try(function() return mesh:call("getMaterialName", j) end) or ""
    local key = tostring(mesh) .. "_" .. tostring(j) .. "_" .. name
    local v = var_cache[key]
    if v == nil then
        local rate, flag
        for k = 0, (try(function() return mesh:call("getMaterialVariableNum", j) end) or 0) - 1 do
            local n = try(function() return mesh:call("getMaterialVariableName", j, k) end)
            if n == RATE then rate = k elseif n == FLAG then flag = k end
        end
        v = false
        if rate then
            local f0 = flag and try(function() return mesh:call("getMaterialFloat4", j, flag) end)
            v = { rate = rate, flag = f0 and flag or nil,
                  flag0 = f0 and { f0.x, f0.y, f0.z, f0.w } or nil }
        end
        var_cache[key] = v
    end
    return v or nil
end

-- u = 动画进度 0..1;消失方溶掉 u,出现方溶掉 1 - u。forward 只决定溶解图的走向
local function write(mesh, j, v, phase, forward, u)
    local rate = phase == "hide" and u or (1 - u)
    try(function() mesh:call("setMaterialFloat4", j, v.rate, Vector4f.new(rate, rate, rate, forward and 0 or 1)) end)
    if v.flag then
        local f = v.flag0
        try(function() mesh:call("setMaterialFloat4", j, v.flag, Vector4f.new(f[1], 0, f[3], f[4])) end)
    end
end

-- 恢复 mdf2 的值(进度 0,IsMorphed 按原值)
local function restore(mesh, j, v)
    try(function() mesh:call("setMaterialFloat4", j, v.rate, Vector4f.new(0, 0, 0, 0)) end)
    if v.flag then
        local f = v.flag0
        try(function() mesh:call("setMaterialFloat4", j, v.flag, Vector4f.new(f[1], f[2], f[3], f[4])) end)
    end
end

local function step(dur)
    return dur > 0 and (1 / dur) or math.huge
end

-- 反方向的动画还在跑:新动画从当前溶掉的比例接着走(消失到 u 时溶掉 u,出现从 1 - u 起也是溶掉 u)
local function start_u(a)
    return a and (1 - a.u) or 0
end

-- 一个材质这次开关该用哪一层的过渡。owner = 这一帧写出它的层,prev = 上一次写它的层,
-- trans[层键] = 这一层刚换选项时选好的过渡。
-- 状态组放手时(选回"无"),材质交还给整套造型;整套造型自己没换选项、没有过渡,
-- 只看 owner 的话出现那一下就是瞬间的(消失能溶解、显示不能)。所以 owner 没有过渡、
-- 而刚放手的那一层有,就用放手那一层的。
function Dissolve.transition_layer(owner, prev, trans)
    if owner and trans and trans[owner] then return owner end
    if prev and prev ~= owner and trans and trans[prev] then return prev end
    return owner or prev
end

-- 材质开关(setMaterialsEnable)。cur = 调用前的 getMaterialsEnable
function Dissolve.set_material(mesh, j, want, cur)
    local key = tostring(mesh) .. "_" .. tostring(j)
    if driven[key] then
        -- 血量驱动放手了:先恢复 mdf2 的值,再按常规开关
        local v = find_var(mesh, j)
        if v then restore(mesh, j, v) end
        driven[key] = nil
    end
    local a = mat_anims[key]
    local phase = want == false and "hide" or "show"
    if a and a.phase == phase then return end
    local v = current.enabled and find_var(mesh, j)
    if not v then
        if a then restore(mesh, j, a.v); mat_anims[key] = nil end
        if cur ~= (phase == "show") then mesh:call("setMaterialsEnable", j, phase == "show") end
        return
    end
    if cur == (phase == "show") and not a then return end
    local n = { mesh = mesh, j = j, v = v, phase = phase, forward = current.forward, u = start_u(a), dur = current.dur }
    write(mesh, j, v, phase, n.forward, n.u)
    if phase == "show" and cur ~= true then mesh:call("setMaterialsEnable", j, true) end
    mat_anims[key] = n
end

-- 调色盘改了 Dissolve_Flag 的 x / z / w(启用、UV2、关闭发光)时同步过渡用的底值,
-- 否则下一次过渡和结束时的恢复会把 mdf2 的旧值写回去。y 由过渡自己管,不动
function Dissolve.set_flag_base(mesh, j, value)
    local v = find_var(mesh, j)
    if not v or not v.flag0 or type(value) ~= "table" then return end
    v.flag0[1], v.flag0[3], v.flag0[4] = value[1], value[3], value[4]
end

-- 停掉这个 mesh 上所有溶解(定时过渡和血量驱动),变量恢复成 mdf2 的值。
-- 定位预览用:预览要的是"只显示这一个材质"的瞬间结果,不能被溶解动画拉扯。
function Dissolve.reset_mesh(mesh)
    local prefix = tostring(mesh) .. "_"
    for key, a in pairs(mat_anims) do
        if key:sub(1, #prefix) == prefix then restore(a.mesh, a.j, a.v); mat_anims[key] = nil end
    end
    for key in pairs(driven) do
        if key:sub(1, #prefix) == prefix then
            local j = tonumber(key:sub(#prefix + 1))
            local v = j and find_var(mesh, j)
            if v then restore(mesh, j, v) end
            driven[key] = nil
        end
    end
end

function Dissolve.is_animating(mesh, j)
    local key = tostring(mesh) .. "_" .. tostring(j)
    return mat_anims[key] ~= nil or driven[key] ~= nil
end

-- 有没有正在跑的定时过渡(有的话差分每帧都要核对,反向切换才接得上)
function Dissolve.any_running()
    return next(mat_anims) ~= nil
end

-- SmoothDamp(临界阻尼弹簧的近似,同 Unity Mathf.SmoothDamp):从当前速度出发缓入缓出地追向目标,不过冲
local function smooth_damp(cur, target, vel, smooth, max_speed, dt)
    smooth = math.max(0.0001, smooth)
    local omega = 2 / smooth
    local x = omega * dt
    local e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    local change = cur - target
    local max_change = max_speed * smooth
    change = math.max(-max_change, math.min(max_change, change))
    local goal = cur - change
    local temp = (vel + omega * change) * dt
    vel = (vel - omega * temp) * e
    local out = goal + (change + temp) * e
    if (target - cur > 0) == (out > target) then
        out = target
        vel = dt > 0 and (out - target) / dt or 0
    end
    return out, vel
end

-- 血量驱动:平滑后的进度(target = 未平滑的进度);第一次直接跳到目标
function Dissolve.drive_progress(key, target)
    local p = drive_p[key]
    if p == nil then
        p = target
        drive_v[key] = 0
    elseif frame_dt > 0 then
        p, drive_v[key] = smooth_damp(p, target, drive_v[key] or 0, DRIVE_SMOOTH, DRIVE_MAX_SPEED, frame_dt)
        if math.abs(target - p) < 1e-4 and math.abs(drive_v[key]) < 1e-3 then p = target; drive_v[key] = 0 end
    end
    drive_p[key] = p
    return p
end

function Dissolve.drive_end(key)
    drive_p[key] = nil
    drive_v[key] = nil
end

-- 血量驱动一个在两种外观里开关不同的材质。with_on = 在"终点外观"里的开关,p = 平滑后的进度。
-- 正在跑的定时过渡由它接管。
function Dissolve.drive_material(mesh, j, with_on, p, cur)
    local key = tostring(mesh) .. "_" .. tostring(j)
    local a = mat_anims[key]
    mat_anims[key] = nil
    local v = find_var(mesh, j)
    if v and p > 0 and p < 1 then
        if cur ~= true then mesh:call("setMaterialsEnable", j, true) end
        if driven[key] ~= p or a then
            write(mesh, j, v, with_on and "show" or "hide", true, p)
            driven[key] = p
        end
        return
    end
    local at_end = v and p >= 1 or (not v and p >= 0.5)
    local on = at_end == with_on
    local rv = v or (a and a.v)
    if (driven[key] or a) and rv then restore(mesh, j, rv) end
    driven[key] = nil
    if cur ~= on then mesh:call("setMaterialsEnable", j, on) end
end

-- 推进所有定时过渡;每帧调一次
function Dissolve.update()
    local now = os.clock()
    local dt = math.min(math.max(now - last_clock, 0), 0.1)
    last_clock = now
    frame_dt = dt
    for key, a in pairs(mat_anims) do
        if not try(function() return a.mesh:call("get_MaterialNum") end) then
            mat_anims[key] = nil
        else
            a.u = math.min(1, a.u + dt * step(a.dur))
            if a.u >= 1 then
                if a.phase == "hide" then try(function() a.mesh:call("setMaterialsEnable", a.j, false) end) end
                restore(a.mesh, a.j, a.v)
                mat_anims[key] = nil
            else
                write(a.mesh, a.j, a.v, a.phase, a.forward, a.u)
            end
        end
    end
end

return Dissolve
