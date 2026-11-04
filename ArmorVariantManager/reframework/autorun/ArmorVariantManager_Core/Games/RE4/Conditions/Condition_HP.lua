-- HP 百分比条件(数值类)。
--
-- 实测(2026-08-22,里昂/ch0_a0z0):chainsaw.PlayerBaseContext:get_HitPoint() 返回
-- chainsaw.HitPoint,其上 get_HitPointRatio() 直接给 0..1 的血量比例。
-- 这里统一按 0..100 对外(UI 里填的也是百分数)。
--
-- 注意:游戏自己还有一套血量**分级**(chainsaw.character.Vital:Fine/Caution/Danger/Poison/Dead),
-- 跟百分比不是一回事——实测 HP 54.9% 时 Vital 仍是 Fine,阈值由游戏定,而且 Poison
-- 是百分比表达不了的状态。那个当独立条件另开,见 AGENTS.md 的条件 backlog。

local M = {
    id = "hp_ratio",
    kind = "number",
    label_key = "cond_hp_ratio",
}

local function get_hitpoint(context)
    if not context then return nil end
    local ok, hp = pcall(function() return context:call("get_HitPoint") end)
    if ok and hp and sdk.is_managed_object(hp) then return hp end
    return nil
end

function M.get(context)
    local hp = get_hitpoint(context)
    if not hp then return nil end
    local ok, ratio = pcall(function() return hp:call("get_HitPointRatio") end)
    if ok and type(ratio) == "number" then return ratio * 100 end
    return nil
end

-- 测试用改血,不参与条件判定。**当前没有 UI 调它** —— 唯一的入口是已经移除的
-- 「条件判断」面板(见 tools/re4/attic/)。留着是因为 TransformManager 还导出了一层
-- (set_character_hp_percent),调试时在控制台里直接用很方便。
function M.set_percent(context, percent)
    local hp = get_hitpoint(context)
    if not hp then return end
    local ok_max, default_hp = pcall(function() return hp:call("get_DefaultHitPoint") end)
    if not ok_max or type(default_hp) ~= "number" or default_hp <= 0 then return end
    local target = math.floor((percent / 100) * default_hp + 0.5)
    pcall(function() hp:call("set_CurrentHitPoint", target) end)
end

return M
