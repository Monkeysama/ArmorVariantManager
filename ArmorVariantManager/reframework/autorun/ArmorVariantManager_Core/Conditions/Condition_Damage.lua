-- ==========================================================
-- 变身条件插件：受击触发与倒计时
-- 功能：无视固定血量，在角色受到伤害的瞬间触发特定规则并开始倒计时
-- 依赖：需要读取 Condition_HP 的状态来计算血量差值
-- ==========================================================

local M = {}
M.id = "damage"

local timer_states = {}
local last_frame_hp = {}

-- 由于此条件需要获取HP，在 evaluate 中会动态调用 hp 插件
local Condition_HP = require("ArmorVariantManager_Core.Conditions.Condition_HP")

function M.evaluate(config, character, char_addr)
    -- 受击状态目前只取列表的第一条规则
    local damage_rule = nil
    if config.damage_transform_rules and config.damage_transform_rules[1] then
        damage_rule = config.damage_transform_rules[1]
    end
    
    if not damage_rule then return nil, "dmg" end

    -- 获取当前血量
    local cur_hp = Condition_HP.get_state(character)
    if not cur_hp then return nil, "dmg" end

    -- 1. 检测受击状态 (对比上一帧血量)
    local prev_hp = last_frame_hp[char_addr]
    local took_damage = false
    if prev_hp and (prev_hp - cur_hp) > 0.1 then
        took_damage = true
    end
    last_frame_hp[char_addr] = cur_hp

    local current_time = os.clock()
    local current_timer = timer_states[char_addr]

    -- 2. 如果受击，更新倒计时
    if took_damage then
        current_timer = {
            end_time = (damage_rule.duration and damage_rule.duration > 0) and (current_time + damage_rule.duration) or 0,
            finished = false
        }
        timer_states[char_addr] = current_timer
    end

    -- 3. 判断是否处于受击持续期间
    if current_timer and not current_timer.finished then
        if current_timer.end_time > 0 and current_time >= current_timer.end_time then
            current_timer.finished = true
            timer_states[char_addr] = nil
            return nil, "dmg"
        end
        return damage_rule, "dmg"
    end

    return nil, "dmg"
end

function M.get_remaining_time(char_addr)
    local current_timer = timer_states[char_addr]
    if current_timer and not current_timer.finished then
        local remaining = current_timer.end_time - os.clock()
        if remaining > 0 then return remaining end
    end
    return 0
end

return M