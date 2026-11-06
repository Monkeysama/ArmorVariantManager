-- 当前手持武器的粗分类(枚举类):枪械 / 刀 / 投掷物 / 徒手 / 其他。
--
-- 取值路径(2026-11-05 用 MCP 实测):PlayerBaseContext:get_HeadUpdater()
--   → 字段 <Equipment>k__BackingField(chainsaw.PlayerEquipment)
--   → get_IsEquipGun / get_IsEquipKnife / get_IsEquipGrenade / get_IsBareHands。
-- **PlayerEquipment 不挂在 body GameObject 上**(挂在 ch0a0z0_head 那个对象上),
-- 对 body 做 getComponent 是拿不到的 —— 所以走 HeadUpdater 的字段。
--
-- **为什么只做粗分,不做手枪/霰弹枪/步枪这种细种类**:引擎里有 chainsaw.WeaponCategory,
-- 但能摸到的 WeaponID→种类 表(PlayerHeadUpdater.WeaponMountUserdata._Datas)只是
-- "特殊挂载位置"的覆盖表,只列了 22 把,实测手里拿过的 wp4001/wp4100/wp4600 都不在里面。
-- 按 WeaponID 编号段推(40xx 手枪、41xx 霰弹枪……)在艾达篇 6xxx 段就不成立
-- (wp6001 是霰弹枪),归错了还没有任何提示。粗分用的是引擎现成的四个布尔,不用猜。
-- 想按具体某一把武器触发,另做「当前武器 = wpXXXX」那种条件,别回头去拼编号段。
--
-- 判定顺序就是优先级:枪 > 刀 > 投掷物 > 徒手,都不是 = 其他(撬棍、临时武器之类)。
-- 值是写进配置的整数,**发布后不要改**;新增档位只能往后加。

local M = {
    id = "weapon_kind",
    kind = "enum",
    label_key = "cond_weapon_kind",
}

local GUN, KNIFE, THROWABLE, BARE, OTHER = 0, 1, 2, 3, 4

local OPTIONS = {
    { value = GUN,       zh = "枪械",   en = "Gun" },
    { value = KNIFE,     zh = "刀",     en = "Knife" },
    { value = THROWABLE, zh = "投掷物", en = "Throwable" },
    { value = BARE,      zh = "徒手",   en = "Bare hands" },
    { value = OTHER,     zh = "其他",   en = "Other" },
}

local function label_of(entry, lang)
    return lang == "zh" and entry.zh or entry.en
end

function M.options(context, lang)
    local out = {}
    for _, e in ipairs(OPTIONS) do
        out[#out + 1] = { value = e.value, label = label_of(e, lang) }
    end
    return out
end

function M.value_label(value, lang)
    for _, e in ipairs(OPTIONS) do
        if e.value == value then return label_of(e, lang) end
    end
    return tostring(value)
end

local function equipment(context)
    local ok, hu = pcall(function() return context:call("get_HeadUpdater") end)
    if not ok or not hu then return nil end
    local ok_e, eq = pcall(function() return hu:get_field("<Equipment>k__BackingField") end)
    if ok_e and eq and sdk.is_managed_object(eq) then return eq end
    return nil
end

local function flag(eq, method)
    local ok, v = pcall(function() return eq:call(method) end)
    return ok and v == true
end

function M.get(context)
    if not context then return nil end
    local eq = equipment(context)
    if not eq then return nil end
    if flag(eq, "get_IsEquipGun") then return GUN end
    if flag(eq, "get_IsEquipKnife") then return KNIFE end
    if flag(eq, "get_IsEquipGrenade") then return THROWABLE end
    if flag(eq, "get_IsBareHands") then return BARE end
    return OTHER
end

return M
