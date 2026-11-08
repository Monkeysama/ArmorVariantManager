-- 枚举/数值类的人物状态条件(2026-11-07 加)。档位一律从引擎枚举反射出来,
-- 反射失败时退回实测见过的值;标签用枚举名,中文再加一个注解。
--
--   last_hit_part  上次被打的部位   PlayerBaseContext.get_LastDamageCategory()  chainsaw.character.BodyPartsCategory
--   last_hit_side  上次被打的左右   PlayerBaseContext.get_LastDamageSide()      chainsaw.character.BodyPartsSide
--     这两个是"上一次"的记录,**被打之后一直保持到下一次被打**。想要"被打头的那一下"
--     就和「受击」或「上次掉血距今」一起用。实测静止时读到 Body(1) / Center(0)。
--   chapter        当前章节         CampaignManager.get_CurrentChapter()       chainsaw.ChapterID
--     实测本篇读到 22300。PlayerBaseContext.get_SituationType() 不是章节(只有几个 ch1a_* 段落,平时是 None)。
--   stage_id       所在区域 ID      PlayerBaseContext.get_CurrentStageID()     chainsaw.StageID
--     做成数值不做枚举:StageID 档位太多,塞进下拉框会把快照撑大(REFF 消息上限 256KB)。
--     数值形如 47410(= st47_410),同一大区前两位相同,所以可以用 >= / < 圈一片区域。
--   dead_type      死法             PlayerBaseContext.get_DeadType()           chainsaw.PlayerDefine.DeadType
--     平时是 None,只有死亡时才有值;用来做死亡画面的差分。

local function enum_list(type_name, fallback)
    local list = {}
    local td = sdk.find_type_definition(type_name)
    if td then
        local ok, fields = pcall(function() return td:get_fields() end)
        if ok and fields then
            for _, f in ipairs(fields) do
                local ok_s, is_static = pcall(function() return f:is_static() end)
                if ok_s and is_static then
                    local ok_v, v = pcall(function() return f:get_data(nil) end)
                    if ok_v and type(v) == "number" then list[#list + 1] = { value = v, name = f:get_name() } end
                end
            end
        end
    end
    if #list == 0 then for _, e in ipairs(fallback) do list[#list + 1] = { value = e.value, name = e.name } end end
    table.sort(list, function(a, b) return a.value < b.value end)
    return list
end

local function enum_def(spec)
    local M = { id = spec.id, kind = "enum", label_key = "cond_" .. spec.id }
    local cached = nil
    local function list()
        if not cached then cached = enum_list(spec.type_name, spec.fallback) end
        return cached
    end
    local function label(e, lang)
        local g = spec.gloss and spec.gloss[e.name]
        if lang == "zh" and g then return g .. " (" .. e.name .. ")" end
        return e.name
    end
    function M.options(_, lang)
        local out = {}
        for _, e in ipairs(list()) do
            if not (spec.hide and spec.hide[e.name]) then out[#out + 1] = { value = e.value, label = label(e, lang) } end
        end
        return out
    end
    function M.value_label(value, lang)
        for _, e in ipairs(list()) do if e.value == tonumber(value) then return label(e, lang) end end
        return tostring(value)
    end
    function M.get(context)
        local ok, v = pcall(spec.read, context)
        if ok and type(v) == "number" then return v end
        return nil
    end
    return M
end

-- jack_kind  敌人联动动作类型(枚举)。身体 MotionFsm2 第 1 层节点以 "Jacked" 开头时,按正在播的联动动作名分类:
--   名字含 hold 且含 escape → 2 挣脱反击;含 hold → 1 被抓;其它 → 3(如横扫后空翻闪避);不在 Jacked → 0。
--   2026-11-07 用 F6 录制实测(各一个样本,换敌人类型可能有别的名字):
--     被抓  chc0_jack_pl_0th_com_0051_hold_B_start   不无敌,IsInGrappleDamage 为真
--     挣脱  chc0_jack_pl_0th_com_0070_hold_escape    无敌约 2.2 秒,挣脱和反击是同一段动作
--     闪避  cha0_enemy_0002_escape_B_VerC            无敌全程,约 1.2 秒
--   切换帧里动作层可能一帧为空,那一帧沿用上一个分类。
local fsm_cache = setmetatable({}, { __mode = "k" })
local jack_last = 0
local JACK_VALUES = {
    { v = 0, zh = "无", en = "None" },
    { v = 1, zh = "被抓", en = "Grabbed" },
    { v = 2, zh = "挣脱反击", en = "Breaking free" },
    { v = 3, zh = "其它（如横扫闪避）", en = "Other (e.g. sweep dodge)" },
}
local function jack_motion_name(context)
    local motion = context:call("get_BodyUpdater"):call("get_Motion")
    local n = motion:call("getLayerCount") or 0
    for i = n - 1, 0, -1 do
        local ok, name = pcall(function()
            local node = motion:call("getLayer", i):call("get_HighestWeightMotionNode")
            return node and node:call("get_MotionName")
        end)
        if ok and type(name) == "string" and (name:find("_jack_", 1, true) or name:find("_enemy_", 1, true)) then
            return name
        end
    end
    return nil
end
local jack_kind = { id = "jack_kind", kind = "enum", label_key = "cond_jack_kind" }
function jack_kind.options(_, lang)
    local out = {}
    for _, e in ipairs(JACK_VALUES) do out[#out + 1] = { value = e.v, label = lang == "zh" and e.zh or e.en } end
    return out
end
function jack_kind.value_label(value, lang)
    for _, e in ipairs(JACK_VALUES) do if e.v == tonumber(value) then return lang == "zh" and e.zh or e.en end end
    return tostring(value)
end
function jack_kind.get(context)
    if not context then return nil end
    local ok, node = pcall(function()
        local go = context:call("get_BodyGameObject")
        local fsm = fsm_cache[go]
        if fsm == nil then
            fsm = go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2")) or false
            fsm_cache[go] = fsm
        end
        return fsm and fsm:call("getCurrentNodeName(System.UInt32)", 1)
    end)
    if not ok or type(node) ~= "string" then return nil end
    if node:sub(1, 6) ~= "Jacked" then jack_last = 0; return 0 end
    local ok_n, name = pcall(jack_motion_name, context)
    if not ok_n or not name then return jack_last ~= 0 and jack_last or 3 end
    local v = 3
    if name:find("hold", 1, true) then v = name:find("escape", 1, true) and 2 or 1 end
    jack_last = v
    return v
end

-- invincible_source  无敌来源(枚举)。游戏里无敌有两个来源:动作片段上的无敌轨道(chainsaw.PlayerInvincibleTracks),
--   和动作状态机节点上的无敌动作(chainsaw.PlayerBehaviorTreeAction_MFSM_Invincible)。
--   无敌为真时,看各动作层正在播的动作有没有挂无敌轨道:有 → 1 动作自带,没有 → 2 其它;不无敌 → 0。
--   轨道哈希 = murmur3(UTF-16LE 类型全名, 种子 0xFFFFFFFF),PlayerInvincibleTracks = F18A8050
--   (用 chainsaw.PlayerSetNextAddArm = 8812F647 验证过算法)。按动作名缓存结果。
--   2026-11-07 用动作浏览器探针收集 9278 个动作实测,挂无敌轨道的:
--     横扫闪避 cha0_enemy_0000_escape_B_VerA / 0002_escape_B_VerC / 0030_escape_crouch / 0042_escape_FB;
--     被打倒类受击 cha0_damage strike_* / blowoff_* / explosion_FL / tripped_*;跳窗落地 window_jumpoff_end。
--     抓取挣脱 *_hold_escape 一律没挂(它的无敌来自状态机) → 2。
--   只说明"正在播的动作挂了这条轨道",不精确到轨道在哪几帧开启;无敌为真时才判断,所以足够区分。
local INV_TRACK = 0xF18A8050
local inv_track_cache = {}
local motion_info = nil
local function motion_has_inv_track(motion, node)
    local name = node:call("get_MotionName")
    if type(name) ~= "string" then return false end
    local hit = inv_track_cache[name]
    if hit ~= nil then return hit end
    hit = false
    local read = false
    pcall(function()
        if not motion_info then motion_info = sdk.create_instance("via.motion.MotionInfo"):add_ref() end
        local bank, id = node:call("get_MotionBankID"), node:call("get_MotionID")
        if bank == nil or id == nil then return end
        if motion:call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank, id, motion_info) then
            read = true
            local n = motion_info:call("get_TracksCount") or 0
            for t = 0, n - 1 do
                local h = motion_info:call("getTracksNameHash(System.UInt32)", t)
                if type(h) == "number" and (math.tointeger(h) or 0) & 0xFFFFFFFF == INV_TRACK then hit = true; break end
            end
        end
    end)
    if read then inv_track_cache[name] = hit end
    return hit
end
local INV_VALUES = {
    { v = 0, zh = "不无敌", en = "Not invincible" },
    { v = 1, zh = "动作自带（闪避、被打飞等）", en = "From the motion (dodges, knockdowns)" },
    { v = 2, zh = "其它（挣脱反击等）", en = "Other (grab escapes, etc.)" },
}
local invincible_source = { id = "invincible_source", kind = "enum", label_key = "cond_invincible_source" }
function invincible_source.options(_, lang)
    local out = {}
    for _, e in ipairs(INV_VALUES) do out[#out + 1] = { value = e.v, label = lang == "zh" and e.zh or e.en } end
    return out
end
function invincible_source.value_label(value, lang)
    for _, e in ipairs(INV_VALUES) do if e.v == tonumber(value) then return lang == "zh" and e.zh or e.en end end
    return tostring(value)
end
function invincible_source.get(context)
    if not context then return nil end
    local ok, inv = pcall(function() return context:call("get_IsInvincible") end)
    if not ok or type(inv) ~= "boolean" then return nil end
    if not inv then return 0 end
    local from_track = false
    pcall(function()
        local motion = context:call("get_BodyUpdater"):call("get_Motion")
        local n = motion:call("getLayerCount") or 0
        for i = 0, n - 1 do
            local node = motion:call("getLayer", i):call("get_HighestWeightMotionNode")
            if node and motion_has_inv_track(motion, node) then from_track = true; break end
        end
    end)
    return from_track and 1 or 2
end

-- is_dodge_motion  闪避动作(布尔):任一动作层正在播的动作名属于闪避类。
--   游戏自带的 IsDodging 不管用:2026-11-07 录制横扫后空翻时它全程为假;主动闪避模组
--   (Dodge Roll & Sprint,alphaZomega)用的也是它自己的变量,注释里写明步闪"never set is_dodging"。
--   所以照那个模组的做法认动作名。名单来自它借用的动作 + 动作浏览器收集到的名字:
--     横扫 / QTE 闪避  cha0_enemy_00xx_escape_*(艾达是 cha8_enemy);抓取挣脱是 *_hold_escape,不匹配
--     步闪            cha0_general_0330~0333_step_F/B/L/R(stepup / stepdown 是翻越地形,不匹配)
--     各种 dodge      ch0_970_DODGE、npc_dodge_*、佣兵的 chi2 *dodge*
--     翻滚            模组的地面翻滚 / 鱼跃翻滚借用的 window_jumpoff_end / window_Jumpout
--                     (真的跳窗也会亮,配合「无敌」时跳窗落地那一下也算)
--     克劳萨步法      chi2 开头且含 step
--   通常和「无敌」一起用:无敌 + 闪避动作 = 闪避带来的无敌。
local DODGE_PATTERNS = {
    "_enemy_%d+_escape_",
    "_general_033%d_step_",
    "dodge",
    "window_jumpoff_end",
    "window_jumpout",
    "^chi2.*step",
}
local dodge_cache = {}
local function is_dodge_name(name)
    local hit = dodge_cache[name]
    if hit ~= nil then return hit end
    local l = name:lower()
    hit = false
    for _, p in ipairs(DODGE_PATTERNS) do if l:find(p) then hit = true; break end end
    dodge_cache[name] = hit
    return hit
end
local dodge_motion = { id = "is_dodge_motion", kind = "bool", label_key = "cond_is_dodge_motion" }
function dodge_motion.get(context)
    if not context then return nil end
    local ok, hit = pcall(function()
        local motion = context:call("get_BodyUpdater"):call("get_Motion")
        local n = motion:call("getLayerCount") or 0
        for i = 0, n - 1 do
            local node = motion:call("getLayer", i):call("get_HighestWeightMotionNode")
            local name = node and node:call("get_MotionName")
            if type(name) == "string" and is_dodge_name(name) then return true end
        end
        return false
    end)
    if ok then return hit end
    return nil
end

local function ctx_call(method)
    return function(context)
        if not context then return nil end
        return context:call(method)
    end
end

return {
    jack_kind,
    invincible_source,
    dodge_motion,
    enum_def({
        id = "last_hit_part", type_name = "chainsaw.character.BodyPartsCategory",
        read = ctx_call("get_LastDamageCategory"),
        fallback = { { value = 1, name = "Body" } },
        gloss = { Head = "头", Body = "躯干", Arms = "手臂", Legs = "腿", Armor = "护甲", Unique = "特殊部位" },
    }),
    enum_def({
        id = "last_hit_side", type_name = "chainsaw.character.BodyPartsSide",
        read = ctx_call("get_LastDamageSide"),
        fallback = { { value = 0, name = "Center" } },
        gloss = { Center = "中", Left = "左", Right = "右" },
    }),
    enum_def({
        id = "chapter", type_name = "chainsaw.ChapterID",
        read = function()
            local cm = sdk.get_managed_singleton("chainsaw.CampaignManager")
            return cm and cm:call("get_CurrentChapter")
        end,
        fallback = { { value = 22300, name = "22300" } },
        hide = { Invalid = true },
    }),
    enum_def({
        id = "dead_type", type_name = "chainsaw.PlayerDefine.DeadType",
        read = ctx_call("get_DeadType"),
        fallback = { { value = 0, name = "None" } },
        gloss = { None = "无", Normal = "普通", Beheaded = "斩首", BodyCut = "腰斩", Breast = "胸口",
                  Burn = "烧死", Burst = "炸死", BurstFall = "炸飞坠落", CarryUpDead = "被举起",
                  CautionDead = "警告死亡", Crushed = "压死", Fall = "坠落", Freeze = "冻死",
                  Ladder = "梯子上", PartnerDead = "同伴死亡", Popup = "弹出" },
    }),
    {
        -- 游戏暂停中:share.PauseManager:isPaused()。2026-11-07 实测暂停菜单打开时为 true。
        -- 用来给其他条件当基准(暂停时人物状态冻结),不依赖人物 context。
        id = "is_paused", kind = "bool", label_key = "cond_is_paused",
        get = function()
            local pm = sdk.get_managed_singleton("share.PauseManager")
            if not pm then return nil end
            local ok, v = pcall(function() return pm:call("isPaused()") end)
            if ok and type(v) == "boolean" then return v end
            return nil
        end,
    },
    {
        id = "stage_id", kind = "number", label_key = "cond_stage_id",
        get = function(context)
            if not context then return nil end
            local ok, v = pcall(function() return context:call("get_CurrentStageID") end)
            if ok and type(v) == "number" then return v end
            return nil
        end,
    },
}
