-- 护甲槛位是否已加载(布尔类)。
--
-- 实测(2026-08-24,里昂,用户反馈 + MeshProbe.lua):`armor` 槛位**不是战斗状态**,
-- 是跟**当前穿的皮肤**绑定的 —— 默认皮肤下 `get_HasArmorMesh() = true`,
-- 切到别的皮肤就变回 `false`。和"穿没穿护甲"这种游戏内动作没关系,纯粹是模型选择。
--
-- 而且护甲槛位一旦出现,**通常会替掉部分 body 材质**(实测这具模型上 body 和 armor
-- 两个槛位各有 24 个材质、名字大量重叫 BeltRibon/Jacket/Metal4 这些 —— armor 是按
-- body 的结构重新导出的一份,armor 出现时对应的 body 材质在视觉上就是重复/穿模的)。
-- **这不是这个插件能自动处理的**:引擎不会告诉我们"哪些 body 材质被这份 armor 盖住了",
-- 那是模型作者的私有知识。这个条件只负责回答"armor 现在在不在",
-- 剩下的("armor 在的时候把这几个 body 材质关掉")留给用户自己配一个状态组 + 这个条件。
--
-- 之所以做成条件而不是让用户手动切:皮肤是可以在游戏里随时换的,做成条件才能让
-- "body 材质被 armor 盖住"这件事跟着皮肤自动联动,不用每次换皮肤都手动去关一次。
--
-- 无状态、不需要 tick():armor 在不在是当前帧就能问到的事实,不是历史。

local M = {
    id = "has_armor_mesh",
    kind = "bool",
    label_key = "cond_has_armor_mesh",
}

-- 2026-11-07 起和 PlayerBaseContext.get_IsArmorCostume() 取「或」:两者任一为真就算有护甲
-- (用户要求;IsArmorCostume 是游戏对"当前服装带护甲"的判定,两边各自可能漏)。
-- 两个都读不到才返回 nil。
local function armor_costume(context)
    local ok, v = pcall(function() return context:call("get_IsArmorCostume") end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

function M.get(context)
    if not context then return nil end
    local has = nil
    local ok, bu = pcall(function() return context:call("get_BodyUpdater") end)
    if ok and bu and sdk.is_managed_object(bu) then
        local ok_h, v = pcall(function() return bu:call("get_HasArmorMesh") end)
        if ok_h and type(v) == "boolean" then has = v end
    end
    if has == true then return true end
    local costume = armor_costume(context)
    if costume ~= nil then return costume end
    return has
end

return M
