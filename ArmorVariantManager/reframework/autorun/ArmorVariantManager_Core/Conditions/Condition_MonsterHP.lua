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
local enemyUpdateMethod = sdk.find_type_definition("snow.enemy.EnemyCharacterBase"):get_method("update")
sdk.hook(enemyUpdateMethod,
    function(args)
        local enemy = sdk.to_managed_object(args[2])
        local monsterId = enemy:get_field("<EnemyType>k__BackingField")
        if monsterId == nil then return end
        local isTarget = false
        for _, id in ipairs(targetMonsterIds) do
            if monsterId == id then isTarget = true; break end
        end
        if not isTarget then return end
        
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