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

local function ctx_call(method)
    return function(context)
        if not context then return nil end
        return context:call(method)
    end
end

return {
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
