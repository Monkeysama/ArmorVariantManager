-- 血量等级(枚举类)。游戏自己的血量分级,不是百分比。
--
-- 实测(2026-08-23,里昂):chainsaw.PlayerBaseContext:getHitPointVital() 返回整数枚举。
-- 反复测下来**只见到 Fine(0) 和 Danger(2)** —— HP 54.9% 时还是 Fine,阈值由游戏定;
-- 中间的 1 一次没见过(用「条件判断」面板底部的改血输入框扫过也没扫到)。
--
-- **和 hp_ratio 不冗余**:阈值是游戏自己的,而且这套分级里可能有百分比根本表达不了的档
-- (原版 RE 系列有中毒档)。想按"游戏认为你危险了"触发就用这个,想按精确血线就用 hp_ratio。
--
-- 选项列表**从枚举类型的静态字段反射出来**,不硬编码 —— 这样这个游戏版本里真实存在的档
-- 会全部自动出现在下拉框里(名字也是引擎里的真名),不用我们猜有几档。
-- 反射失败才退回实测见过的那几档。中文注解只给已知的几个名字,查不到就直接显示引擎名。
--
-- **为什么内部一定得有整数,不能"只按名字判"**:引擎给的就是整数
-- (`getHitPointVital()` 返回 int),名字是我们反射枚举类型的静态字段**反查**出来的。
-- 名字只活在显示层:下拉框显示名字、配置里存整数、判定拿整数比。
-- 所以 UI 上没必要露出整数(已经不露了),但代码里绕不开它。

local M = {
    id = "hp_vital",
    kind = "enum",
    label_key = "cond_hp_vital",
}

-- 引擎名 → 中文。查不到就用引擎名原样显示(比编个译名安全)。
local ZH_GLOSS = {
    Fine = "良好",
    Caution = "注意",
    Danger = "残血",
    Poison = "中毒",
    Dead = "死亡",
}

-- 实测见过的档。反射拿不到枚举字段时用它兜底,保证下拉框不会是空的。
-- 值是实测读出来的,不是猜的:Fine=0 / Danger=2 / Dead=4(0 血时读到 4,2026-08-23)。
-- 中间的 1 和 3 没见过 —— 不往这里补,宁可少一档也不写没读到过的值:
-- 反射正常工作时这张表根本用不上,补错的值反而会在反射失效时给出一个假档位。
local FALLBACK = {
    { value = 0, name = "Fine" },
    { value = 2, name = "Danger" },
    { value = 4, name = "Dead" },
}

local function vital_type_name(context)
    if not context then return nil end
    local ok, td = pcall(function() return context:get_type_definition() end)
    if not ok or not td then return nil end
    local cur = td
    while cur do
        local ok_m, m = pcall(function() return cur:get_method("getHitPointVital") end)
        if ok_m and m then
            local ok_rt, rt = pcall(function() return m:get_return_type() end)
            if ok_rt and rt then
                local ok_n, n = pcall(function() return rt:get_full_name() end)
                if ok_n and n then return n end
            end
            return nil
        end
        local ok_p, p = pcall(function() return cur:get_parent_type() end)
        if not ok_p then return nil end
        cur = p
    end
    return nil
end

-- 枚举档位列表。按值升序,顺序稳定 —— 存进配置的是 value,所以下拉框顺序变了也不会失配。
local cached_options = nil
local function build_options(context)
    if cached_options then return cached_options end
    local list = {}
    local tn = vital_type_name(context)
    local td = tn and sdk.find_type_definition(tn) or nil
    if td then
        local ok, fields = pcall(function() return td:get_fields() end)
        if ok and fields then
            for _, f in ipairs(fields) do
                local ok_s, is_static = pcall(function() return f:is_static() end)
                if ok_s and is_static then
                    local ok_v, v = pcall(function() return f:get_data(nil) end)
                    if ok_v and type(v) == "number" then
                        table.insert(list, { value = v, name = f:get_name() })
                    end
                end
            end
        end
    end
    if #list == 0 then
        for _, e in ipairs(FALLBACK) do table.insert(list, { value = e.value, name = e.name }) end
    end
    table.sort(list, function(a, b) return a.value < b.value end)
    cached_options = list
    return list
end

-- 档位名。**标签里刻意不带枚举整数** —— 用户从来不需要输入它:下拉框选的是名字,
-- 存进配置的是 value,判定也是拿 value 比。数字对使用者是纯噪音。
-- (要看原始整数就去「条件判断」面板的取值组,那里是诊断视角,显示 "Danger (2)"。)
local function label_of(entry, lang)
    local gloss = ZH_GLOSS[entry.name]
    if lang == "zh" and gloss then return gloss .. " (" .. entry.name .. ")" end
    return entry.name
end

-- 面板用:{ { value, label }, ... }
function M.options(context, lang)
    local out = {}
    for _, e in ipairs(build_options(context)) do
        table.insert(out, { value = e.value, label = label_of(e, lang) })
    end
    return out
end

-- 单个值的显示名。给规则列表里"这条规则写的是什么"用,所以查不到也得给个能看的东西。
function M.value_label(value, lang)
    for _, e in ipairs(cached_options or FALLBACK) do
        if e.value == value then return label_of(e, lang) end
    end
    -- 认不出来的值:只能显示原始整数。会走到这里的情形是"配置里存了一个这个版本
    -- 不再声明的档",宁可显示成 hp_vital == 7 也别装作认识它。
    return tostring(value)
end

function M.get(context)
    if not context then return nil end
    local ok, v = pcall(function() return context:call("getHitPointVital") end)
    if ok and type(v) == "number" then return v end
    return nil
end

return M
