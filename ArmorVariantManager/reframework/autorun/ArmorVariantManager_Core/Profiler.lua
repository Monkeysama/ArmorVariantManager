-- ============================================================================
--  性能诊断模块（Profiler）—— 差分管理器（崛起版本）
-- ============================================================================

local Profiler = {}

Profiler.enabled = false                       -- 总开关
Profiler.output_path = "ArmorVariantManager/Profile.json"
Profiler.window_frames = 600                   -- 每 600 帧结算一次窗口（约 5~10 秒）
Profiler.flush_seconds = 20                    -- 窗口最多持续 20 秒（帧率很低时也能落盘）
Profiler.keep_windows = 8                      -- 报告里保留最近多少个窗口
Profiler.max_windows = 0                        -- 0 = 不限制；>0 时写够这么多窗口就自动关闭
Profiler.max_seconds = 0                        -- 0 = 不限制；>0 时超过这么多秒自动关闭

-- ---------------------------------------------------------------- 内部状态
local window_phases = {}        -- name -> { calls, total, max }
local window_counters = {}      -- name -> number
local cum_phases = {}           -- 同上，累计
local cum_counters = {}         -- 同上，累计
local recent_windows = {}       -- 最近若干窗口的报告

local frames_in_window = 0
local frame_index = 0
local last_frame_clock = nil
local window_start_clock = nil
local run_start_clock = nil

local window_frame_delta_sum = 0
local window_frame_delta_count = 0
local window_frame_delta_max = 0

local cum_frames = 0
local cum_frame_delta_sum = 0
local cum_frame_delta_count = 0
local cum_frame_delta_max = 0
local cum_plugin_total = 0
local cum_plugin_max = 0

local clock_quantum = nil
local windows_written = 0
local last_error = nil
local auto_disabled = false

-- 计时器刻度探测：记录见过的最小正差值，用来估算 os.clock() 的精度
local function observe_quantum(dt)
    if type(dt) ~= "number" or dt <= 0 then return end
    if clock_quantum == nil or dt < clock_quantum then clock_quantum = dt end
end

local function ensure_slot(t, name)
    local slot = t[name]
    if not slot then
        slot = { calls = 0, total = 0, max = 0 }
        t[name] = slot
    end
    return slot
end

-- ============================================================================
--  测量接口
-- ============================================================================

-- 返回本段的起始时间；关闭诊断时返回 nil（后续 finish 会直接忽略）
function Profiler.begin(name)
    if not Profiler.enabled then return nil end
    return os.clock()
end

-- 与 begin 配对；t0 为 nil（未启用）时立刻返回
function Profiler.finish(name, t0)
    if t0 == nil then return end
    local dt = os.clock() - t0
    if dt < 0 then dt = 0 end
    observe_quantum(dt)

    local w = ensure_slot(window_phases, name)
    w.calls = w.calls + 1
    w.total = w.total + dt
    if dt > w.max then w.max = dt end

    local c = ensure_slot(cum_phases, name)
    c.calls = c.calls + 1
    c.total = c.total + dt
    if dt > c.max then c.max = dt end
end

-- 计数类指标（调用次数、遍历节点数、磁盘读取次数等）
function Profiler.count(name, n)
    if not Profiler.enabled then return end
    n = tonumber(n) or 1
    window_counters[name] = (window_counters[name] or 0) + n
    cum_counters[name] = (cum_counters[name] or 0) + n
end

-- 记录一个「可能很大」的单次数值（例如某次遍历的节点数），报告里给最大值
function Profiler.max_value(name, value)
    if not Profiler.enabled then return end
    value = tonumber(value)
    if not value then return end
    local key = name .. "_max"
    if (window_counters[key] or -math.huge) < value then window_counters[key] = value end
    if (cum_counters[key] or -math.huge) < value then cum_counters[key] = value end
end

-- ============================================================================
--  每帧入口：统计帧间隔（= 真实帧时间 / FPS），窗口写满就落盘
-- ============================================================================
function Profiler.enter_frame()
    if not Profiler.enabled then return end
    local now = os.clock()
    if run_start_clock == nil then
        run_start_clock = now
        window_start_clock = now
        last_frame_clock = now
    end

    -- - 窗口结算放在这里，而不是帧末。
    --   调用 enter_frame 时「上一帧」的所有 finish 都已经执行完，
    --   所以此刻 window_phases 与 frames_in_window 是严格配对的：
    --   frames_in_window 帧的耗时，正好对应这 N 个帧间隔。
    --   （如果放在帧末结算，当前帧的 finish 还没跑，分子分母就会错位一帧。）
    if frames_in_window > 0 then
        local window_seconds = now - window_start_clock
        local hit_frame_limit = Profiler.window_frames and Profiler.window_frames > 0
            and frames_in_window >= Profiler.window_frames
        local hit_time_limit = Profiler.flush_seconds and Profiler.flush_seconds > 0
            and window_seconds >= Profiler.flush_seconds
        if hit_frame_limit or hit_time_limit then
            Profiler.flush()
        end
    end

    if last_frame_clock then
        local d = now - last_frame_clock
        if d > 0 then
            observe_quantum(d)
            window_frame_delta_sum = window_frame_delta_sum + d
            window_frame_delta_count = window_frame_delta_count + 1
            if d > window_frame_delta_max then window_frame_delta_max = d end
            cum_frame_delta_sum = cum_frame_delta_sum + d
            cum_frame_delta_count = cum_frame_delta_count + 1
            if d > cum_frame_delta_max then cum_frame_delta_max = d end
        end
    end
    last_frame_clock = now
    frame_index = frame_index + 1
    frames_in_window = frames_in_window + 1
    cum_frames = cum_frames + 1

    -- 诊断时长上限（0 = 不限制）
    if Profiler.max_seconds and Profiler.max_seconds > 0
        and (now - run_start_clock) > Profiler.max_seconds then
        Profiler.flush()
        Profiler.enabled = false
        auto_disabled = true
    end
end

-- ============================================================================
--  报告生成
-- ============================================================================

local function build_phase_table(source, frames)
    local out = {}
    for name, slot in pairs(source) do
        local total_ms = slot.total * 1000
        out[name] = {
            calls = slot.calls,
            ms_total = total_ms,
            ms_per_call = slot.calls > 0 and (total_ms / slot.calls) or 0,
            ms_per_frame = frames > 0 and (total_ms / frames) or 0,
            max_ms = slot.max * 1000
        }
    end
    return out
end

local function build_overall(frames, seconds, plugin_total, plugin_max,
                             delta_sum, delta_count, delta_max)
    local frame_ms_avg = delta_count > 0 and (delta_sum / delta_count * 1000) or 0
    local plugin_ms_avg = frames > 0 and (plugin_total / frames * 1000) or 0
    return {
        frames = frames,
        seconds = seconds,
        fps = seconds > 0 and (frames / seconds) or 0,
        frame_ms_avg = frame_ms_avg,
        frame_ms_max = delta_max * 1000,
        plugin_ms_avg = plugin_ms_avg,          -- 差分管理器每帧占用的毫秒数
        plugin_ms_max = plugin_max * 1000,
        plugin_percent_of_frame = frame_ms_avg > 0 and (plugin_ms_avg / frame_ms_avg * 100) or 0
    }
end

function Profiler.flush()
    if not Profiler.enabled then return end
    if frames_in_window == 0 then return end

    local ok, err = pcall(function()
        local now = os.clock()
        local window_seconds = 0
        if window_start_clock then window_seconds = now - window_start_clock end

        local plugin_slot = window_phases["plugin_frame"]
        local window_plugin_total = plugin_slot and plugin_slot.total or 0
        local window_plugin_max = plugin_slot and plugin_slot.max or 0

        local report = {
            time = os.date("%Y-%m-%d %H:%M:%S"),
            overall = build_overall(frames_in_window, window_seconds,
                window_plugin_total, window_plugin_max,
                window_frame_delta_sum, window_frame_delta_count, window_frame_delta_max),
            phases = build_phase_table(window_phases, frames_in_window),
            counters = window_counters
        }

        windows_written = windows_written + 1
        table.insert(recent_windows, 1, report)
        while #recent_windows > (Profiler.keep_windows or 12) do
            table.remove(recent_windows)
        end

        -- 累计口径
        local cum_seconds = 0
        if run_start_clock then cum_seconds = now - run_start_clock end
        local cum_plugin_slot = cum_phases["plugin_frame"]
        local cumulative = {
            windows = windows_written,
            overall = build_overall(cum_frames, cum_seconds,
                cum_plugin_slot and cum_plugin_slot.total or 0,
                cum_plugin_slot and cum_plugin_slot.max or 0,
                cum_frame_delta_sum, cum_frame_delta_count, cum_frame_delta_max),
            phases = build_phase_table(cum_phases, cum_frames),
            counters = cum_counters
        }

        local dump = {
            generated_at = os.date("%Y-%m-%d %H:%M:%S"),
            note = "时间单位=毫秒；ms_per_frame=该环节每帧平均占用；counters=调用/遍历次数；clock_quantum_ms=os.clock 实测刻度（越小越可信）",
            script_uptime_seconds = cum_seconds,
            clock_quantum_ms = (clock_quantum or 0) * 1000,
            windows_written = windows_written,
            auto_disabled = auto_disabled,
            last_error = last_error,
            cumulative = cumulative,
            recent_windows = recent_windows
        }

        json.dump_file(Profiler.output_path, dump)

        -- 重置窗口累计
        window_phases = {}
        window_counters = {}
        frames_in_window = 0
        window_start_clock = now
        window_frame_delta_sum = 0
        window_frame_delta_count = 0
        window_frame_delta_max = 0
    end)

    if not ok then last_error = tostring(err) end

    if Profiler.max_windows and Profiler.max_windows > 0
        and windows_written >= Profiler.max_windows then
        Profiler.enabled = false
        auto_disabled = true
    end
end

-- 清空所有统计（重置脚本 / 手动调用）
function Profiler.reset()
    window_phases = {}
    window_counters = {}
    cum_phases = {}
    cum_counters = {}
    recent_windows = {}
    frames_in_window = 0
    frame_index = 0
    last_frame_clock = nil
    window_start_clock = nil
    run_start_clock = nil
    window_frame_delta_sum = 0
    window_frame_delta_count = 0
    window_frame_delta_max = 0
    cum_frames = 0
    cum_frame_delta_sum = 0
    cum_frame_delta_count = 0
    cum_frame_delta_max = 0
    cum_plugin_total = 0
    cum_plugin_max = 0
    clock_quantum = nil
    windows_written = 0
    auto_disabled = false
end

return Profiler