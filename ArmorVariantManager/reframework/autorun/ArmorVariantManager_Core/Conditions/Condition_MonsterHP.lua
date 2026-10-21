-- Condition_MonsterHP.lua
local M = {}
M.id = "monster_hp"

-- 缓存数据
local totalCurrentHP = 0
local totalMaxHP = 0
local targetMonsterIds = {}
local monstersHP = {}
local questTargetNum = 0
local isInQuest = false

local questManagerTypeDef = sdk.find_type_definition("snow.QuestManager")
local questTargetDataTypeDef = questManagerTypeDef:get_field("_QuestTargetData"):get_type()
local questTargetDataItemMethod = questTargetDataTypeDef:get_method("get_Item")

-- 游戏状态变化监听
local function onGameStatusChanged(args)
    local flow_state = sdk.to_int64(args[3])
    if flow_state == 1 then
        totalCurrentHP = 0
        totalMaxHP = 0
        targetMonsterIds = {}
        monstersHP = {}
        questTargetNum = 0
        isInQuest = false
    elseif flow_state == 2 then
        totalCurrentHP = 0
        totalMaxHP = 0
        targetMonsterIds = {}
        monstersHP = {}
        questTargetNum = 0
        isInQuest = true
        local questManager = sdk.get_managed_singleton("snow.QuestManager")
        if questManager then
            local questTargetDataList = questManager:get_field("_QuestTargetData")
            if questTargetDataList then
                for i = 0, 10 do
                    local questTargetData = questTargetDataItemMethod(questTargetDataList, i)
                    if questTargetData then
                        local id = questTargetData:get_field("ID")
                        local tgtNum = questTargetData:get_field("TgtNum") or 1
                        questTargetNum = questTargetNum + tgtNum
                        for _ = 1, tgtNum do
                            table.insert(targetMonsterIds, id)
                        end
                    end
                end
            end
        end
    end
end
sdk.hook(questManagerTypeDef:get_method("onChangedGameStatus"), onGameStatusChanged, function(retval) return retval end)

-- Hook 怪物更新函数
-- 注意：这个钩子对**每一只怪物的每一帧 update** 都会进一次 Lua，
--       是本文件最需要关注的开销来源，所以单独加了性能统计点。
local enemyUpdateMethod = sdk.find_type_definition("snow.enemy.EnemyCharacterBase"):get_method("update")
-- ============================================================================
--  跟踪开关
-- ----------------------------------------------------------------------------
--  - 性能要点：下面那个 sdk.hook 挂在 snow.enemy.EnemyCharacterBase:update 上，
--    对「每一只怪物的每一帧 update」都会进一次 Lua（实测约 43 次/帧）。
--    如果当前的差分配置里根本没有启用「怪物血量」条件，这些托管 API 调用
--    就完全是白费帧数，所以由核心（ArmorVariantManager.lua）在加载/保存配置后
--    调用 M.set_tracking() 来整体开关。
-- ============================================================================
local tracking_enabled = false

function M.set_tracking(enabled)
    tracking_enabled = enabled == true
end

function M.is_tracking()
    return tracking_enabled
end

local function on_enemy_update(args)
        -- 没被任何配置用到时直接走人（0 次托管 API 调用）
        if not tracking_enabled then return end
        -- - 性能要点：这段代码对「每一只怪物的每一帧 update」都会执行。
        --   先用纯 Lua 判断挡掉绝大多数调用（0 次托管 API 调用）：
        --   不在任务里、或当前任务没有目标怪时，血量数据根本不可能被用到
        --   （M.get_state() 在这种情况下本来也会返回 nil）。
        if not isInQuest or questTargetNum == 0 then return end
        local enemy = sdk.to_managed_object(args[2])
        local monsterId = enemy:get_field("<EnemyType>k__BackingField")
        if monsterId == nil then return end
        local isTarget = false
        for _, id in ipairs(targetMonsterIds) do
            if monsterId == id then isTarget = true; break end
        end
        if not isTarget then return end
        local P = _G.__AVM_PROFILER
        if P then P.count("monster_hp_hook_target") end
        
        local vitals = enemy:get_field("<PhysicalParam>k__BackingField")
        if not vitals then return end
        local vital = vitals:call("getVital", 0, 0)
        if not vital then return end
        local currentHP = vital:call("get_Current") or 0
        local maxHP = vital:call("get_Max") or 0
        if maxHP == 0 then return end
        
        if monstersHP[enemy] == nil then
            monstersHP[enemy] = { current = currentHP, max = maxHP }
            totalCurrentHP = totalCurrentHP + currentHP
            totalMaxHP = totalMaxHP + maxHP
        else
            totalCurrentHP = totalCurrentHP - monstersHP[enemy].current + currentHP
            monstersHP[enemy].current = currentHP
            if monstersHP[enemy].max ~= maxHP then
                totalMaxHP = totalMaxHP - monstersHP[enemy].max + maxHP
                monstersHP[enemy].max = maxHP
            end
        end
end
sdk.hook(enemyUpdateMethod,
    function(args)
        local P = _G.__AVM_PROFILER
        if not (P and P.enabled) then
            -- 正常使用（没开性能诊断）时走这条最短路：一次函数调用 + 几个 Lua 判断
            on_enemy_update(args)
            return
        end
        -- 开了性能诊断时分开统计：
        --   monster_hp_hook_total = 钩子被调用的总代价（含 Lua 派发开销与门控判断）
        --   门控关掉后 on_enemy_update 会在第一行返回，真正的血量工作耗时不会计入任何阶段
        P.count("monster_hp_hook_invocations")
        local t0 = P.begin("monster_hp_hook_total")
        on_enemy_update(args)
        P.finish("monster_hp_hook_total", t0)
    end,
    function(retval) return retval end
)

function M.get_state()
    if not isInQuest or questTargetNum == 0 then return nil end
    if totalMaxHP <= 0 then return nil end
    return (totalCurrentHP / totalMaxHP) * 100
end

function M.evaluate(config, character, char_addr)
    local percent = M.get_state()
    if percent == nil then return nil, nil end
    local rules = config.monster_hp_transform_rules
    if not rules or #rules == 0 then return nil, percent end
    
    -- 关键修复：按阈值升序排序，取第一个满足条件的节点（即最严格的阈值）
    local sorted = {}
    for _, r in ipairs(rules) do table.insert(sorted, r) end
    table.sort(sorted, function(a, b) return a.threshold < b.threshold end)
    for _, r in ipairs(sorted) do
        if percent <= r.threshold then
            return r, percent
        end
    end
    return nil, percent
end

function M.has_getter() return true end

return M