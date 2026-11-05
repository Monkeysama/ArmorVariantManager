-- 血量变化(布尔类,有状态)。两个条件:`hp_decreased`(血量减少)/ `hp_increased`(血量增加)。
--
-- **它俩都是瞬时的** —— 只在"这一帧比上一帧少/多"的那一两帧为真。所以单独用几乎看不见,
-- **必须配规则上的「命中后保持 N 秒」**(受伤配 1~2 秒,回血配 0.5~1 秒)。
-- 这正是加了 hold 之后才敢做成布尔的原因:在那之前只能做成"上次掉血距今多少秒"
-- 那种数值条件,把"发生了"和"亮多久"揉在一个条件里。
--
-- 取代了原来的 `hp_drop_elapsed`(存档在 tools/re4/attic/)。**丢掉的能力**:反向表达
-- "已经 10 秒没被打了"(`hp_drop_elapsed > 10`)—— 布尔表达不了。真需要就把那个模块捡回来。
--
-- 比较的是**绝对血量**而不是百分比:百分比的分母会变(血量上限升级),
-- 上限一变百分比就跳,会误报一次变化。
--
-- 采样只在 tick 里做,`get()` 保持纯读 —— get() 每帧被调多次(规则求值、快速切换、规则概览),
-- 把采样塞进去就会把"上一帧的血量"冲成"这一帧的",两个标志永远为假。
--
-- **两个 def 挂的是同一个 tick 函数**,靠 Registry 传进来的帧号去重(同一帧只采一次)。
-- 不这么做的话:Registry.tick 会对每个 def 各调一次 tick,第二次调用时"上一帧血量"已经
-- 被第一次调用更新过了,于是算出来的差值恒为 0。

local last_hp = nil
local last_frame = -1
local dec, inc = false, false

local function current_hp(context)
    if not context then return nil end
    local ok, hp = pcall(function() return context:call("get_HitPoint") end)
    if not ok or not hp or not sdk.is_managed_object(hp) then return nil end
    local ok_v, v = pcall(function() return hp:call("get_CurrentHitPoint") end)
    if ok_v and type(v) == "number" then return v end
    return nil
end

-- frame 由 Registry.tick 传进来。**别改成自己数帧** —— 这个函数一帧会被调用两次
-- (两个 def 各一次),自己数就分不清"新的一帧"和"同一帧的第二次调用"。
local function sample(context, frame)
    if frame == last_frame then return end
    last_frame = frame

    local hp = current_hp(context)
    if hp == nil then
        -- 读不到(过场、切角色)时**不报变化**,并且把基线清掉:
        -- 否则恢复读数的那一帧会拿"很久以前的血量"比出一个巨大的假变化
        last_hp, dec, inc = nil, false, false
        return
    end
    if last_hp == nil then
        last_hp, dec, inc = hp, false, false
        return
    end
    dec = hp < last_hp
    inc = hp > last_hp
    last_hp = hp
end

return {
    {
        id = "hp_decreased",
        kind = "bool",
        label_key = "cond_hp_decreased",
        tick = sample,
        get = function(context)
            if not context then return nil end
            return dec
        end,
    },
    {
        id = "hp_increased",
        kind = "bool",
        label_key = "cond_hp_increased",
        tick = sample,
        get = function(context)
            if not context then return nil end
            return inc
        end,
    },
}
