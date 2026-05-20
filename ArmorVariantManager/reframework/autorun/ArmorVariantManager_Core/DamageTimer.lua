-- ==========================================================
-- 受击触发与倒计时独立状态机 (Damage Timer Module)
-- 功能：无视固定血量，在角色受到伤害的瞬间触发特定规则并开始倒计时
-- ==========================================================

local DamageTimer = {}

local timer_states = {}
local last_frame_hp = {}

function DamageTimer.evaluate_damage_rules(char_addr, cur_hp, damage_rule)
    if not damage_rule then return nil end
    if not cur_hp then return nil end

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
            return nil
        end
        return damage_rule
    end

    return nil
end

return DamageTimer