-- ==========================================================
-- 受击触发与倒计时独立状态机 (Damage Timer Module)
-- 功能：无视固定血量，在角色受到伤害的瞬间触发特定规则并开始倒计时
-- ==========================================================

local DamageTimer = {}

local timer_states = {}
local last_frame_hp = {}

function DamageTimer.evaluate_hp_rules(char_addr, cur_hp, rules)
    if not rules or #rules == 0 then return nil end
    if not cur_hp then return nil end

    -- 1. 检测受击状态 (对比上一帧血量)
    local prev_hp = last_frame_hp[char_addr]
    local took_damage = false
    if prev_hp and (prev_hp - cur_hp) > 0.1 then
        took_damage = true
    end
    last_frame_hp[char_addr] = cur_hp

    -- 2. 获取当前角色身上的计时器状态
    local current_time = os.clock()
    local current_timer = timer_states[char_addr]

    -- 【重要修复】：如果用户在 UI 面板中途修改了触发类型（如从“血量触发”改为“受击触发”），立刻废除旧的残留计时状态
    if current_timer and current_timer.rule then
        if current_timer.was_damage_triggered ~= current_timer.rule.trigger_on_damage then
            current_timer = nil
            timer_states[char_addr] = nil
        end
    end

    -- 3. 匹配最高优先级的规则
    local matched_rule = nil
    local sorted_rules = {}
    for _, r in ipairs(rules) do table.insert(sorted_rules, r) end
    table.sort(sorted_rules, function(a, b)
        if a.trigger_on_damage and not b.trigger_on_damage then return true end
        if not a.trigger_on_damage and b.trigger_on_damage then return false end
        return a.threshold < b.threshold
    end)

    for _, r in ipairs(sorted_rules) do
        if r.trigger_on_damage then
            if took_damage then matched_rule = r; break end
        else
            if cur_hp <= r.threshold then matched_rule = r; break end
        end
    end

    -- 4. 保护处于激活状态的受击倒计时
    if current_timer and not current_timer.finished and current_timer.was_damage_triggered then
        local is_time_valid = (current_timer.end_time == 0) or (current_time < current_timer.end_time)
        if is_time_valid then
            -- 除非再次受击触发了新的受击规则，否则保持当前倒计时不受其他规则干扰
            if not (took_damage and matched_rule and matched_rule.trigger_on_damage) then
                matched_rule = current_timer.rule
            end
        end
    end

    -- 5. 状态机更新
    if matched_rule then
        -- 如果是新受击，或者规则变了，或者还没有计时器，则重启/新建计时器
        if (matched_rule.trigger_on_damage and took_damage) or not current_timer or current_timer.rule ~= matched_rule then
            current_timer = { 
                rule = matched_rule, 
                end_time = (matched_rule.duration and matched_rule.duration > 0) and (current_time + matched_rule.duration) or 0, 
                finished = false, 
                is_healed = false,
                was_damage_triggered = matched_rule.trigger_on_damage -- 严格记录启动时的触发类型
            }
            timer_states[char_addr] = current_timer
        else
            -- 规则没变，持续激活状态
            current_timer.is_healed = false
        end
    else
        -- 没有任何规则匹配当前状态，标记为已恢复健康
        if current_timer then current_timer.is_healed = true end
    end
    
    -- 6. 输出判定结果
    if current_timer and not current_timer.finished then
        local rule = current_timer.rule
        local has_timer = (current_timer.end_time > 0)
        local is_timer_running = has_timer and (current_time < current_timer.end_time)
        local is_state_active = (matched_rule == rule)
        
        local should_show = false
        
        if rule.trigger_on_damage then
            -- 受击触发：纯看计时器
            if has_timer then
                should_show = is_timer_running
            else
                should_show = true -- 如果持续时间设为0，则永久变身
            end
        else
            -- 传统血量阈值触发：看计时器与当前血量状态
            if has_timer then
                if rule.keep_until_state_ends then
                    should_show = is_timer_running or is_state_active
                else
                    should_show = is_timer_running
                end
            else
                -- 无计时器且不是受击触发：纯看当前血量
                should_show = is_state_active
            end
        end
        
        if should_show then 
            return rule 
        else 
            current_timer.finished = true
        end
    end
    
    -- 7. 垃圾回收
    if current_timer and current_timer.finished and current_timer.is_healed then 
        timer_states[char_addr] = nil 
    end
    
    return nil
end

return DamageTimer