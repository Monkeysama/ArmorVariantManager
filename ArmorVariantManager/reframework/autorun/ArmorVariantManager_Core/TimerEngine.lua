-- ==========================================================
-- 复杂状态机与定时器引擎 (Timer Engine Module)
-- 完美修复链式变身死循环与悬停逻辑
-- ==========================================================
local TimerEngine = {}
local DamageMonitor = require("ArmorVariantManager_Core.DamageMonitor")
local timer_states = {}

function TimerEngine.evaluate_rules(char_addr, cur_hp, rules)
    if not rules then return nil, nil, nil end
    
    -- 验证规则是否为空，防范字典表格式
    local has_rules = false
    for _ in pairs(rules) do has_rules = true; break end
    if not has_rules then return nil, nil, nil end

    local took_damage = DamageMonitor.check_damage(char_addr, cur_hp)
    local current_time = os.clock()
    local state = timer_states[char_addr]

    -- 安全清理条件变更导致的废弃状态
    if state and state.rule then
        local r_dmg = state.rule.trigger_on_damage or false
        local s_dmg = state.was_damage_triggered or false
        if s_dmg ~= r_dmg then
            state = nil
            timer_states[char_addr] = nil
        end
    end

    local matched_rule = nil
    local sorted_rules = {}
    for _, r in pairs(rules) do table.insert(sorted_rules, r) end
    table.sort(sorted_rules, function(a, b)
        local a_dmg = a.trigger_on_damage or false
        local b_dmg = b.trigger_on_damage or false
        if a_dmg and not b_dmg then return true end
        if not a_dmg and b_dmg then return false end
        return (a.threshold or 100) < (b.threshold or 100)
    end)

    for _, r in ipairs(sorted_rules) do
        if r.trigger_on_damage then
            if took_damage then matched_rule = r; break end
        else
            if cur_hp <= (r.threshold or 100) then matched_rule = r; break end
        end
    end

    -- 保护正在执行中的受击变身，不被常规血量变身打断
    if state and state.phase ~= "finished" and state.was_damage_triggered then
        if not (took_damage and matched_rule and matched_rule.trigger_on_damage) then
            matched_rule = state.rule
        end
    end

    -- 触发引擎启动判定
    if matched_rule then
        local should_start_new = false
        if not state or state.phase == "finished" then 
            should_start_new = true
        elseif matched_rule.trigger_on_damage and took_damage then 
            should_start_new = true
        elseif not (state.rule.trigger_on_damage) and matched_rule ~= state.rule then 
            should_start_new = true 
        end

        if should_start_new then
            state = {
                rule = matched_rule,
                trigger_type = (matched_rule.trigger_on_damage and took_damage) and "damage" or "hp",
                phase = (matched_rule.condition_delay and matched_rule.condition_delay > 0) and "delay" or "running",
                phase_start = current_time,
                loop_iteration = 0, chain_idx = 1, is_healed = false,
                was_damage_triggered = matched_rule.trigger_on_damage or false
            }
            timer_states[char_addr] = state
        else 
            state.is_healed = false 
        end
    else
        if state then state.is_healed = true end
    end

    -- 状态机核心时序推进
    if state and state.phase ~= "finished" then
        local elapsed = current_time - state.phase_start
        local r = state.rule
        local mode = r.mode or 1

        -- 【全局安全中断】：如果玩家喝药回血了，且不是纯受击变身，立刻终止任何状态的变身
        if state.is_healed and not r.trigger_on_damage then
            state.phase = "finished"
        end

        if state.phase == "delay" then
            if elapsed >= (r.condition_delay or 0) then 
                state.phase = "running"
                state.phase_start = current_time
                elapsed = 0 
            end
        elseif state.phase == "running" then
            if mode == 1 then
                local dur = r.duration or 0
                if dur > 0 and elapsed >= dur then
                    if r.keep_until_state_ends then 
                        state.phase = "holding"
                    else 
                        state.phase = "finished" 
                    end
                elseif dur == 0 and r.trigger_on_damage and elapsed > 0.5 then
                    state.phase = "finished"
                end
                
            elseif mode == 2 then
                local dur = r.duration or 0
                if dur > 0 and elapsed >= dur then
                    state.loop_iteration = state.loop_iteration + 1
                    if (r.loop_count or 0) > 0 and state.loop_iteration >= r.loop_count then 
                        state.phase = "holding" -- 【修复】循环结束后挂起，不被无限重置
                    else 
                        state.phase = "inactive"
                        state.phase_start = current_time 
                    end
                end
                
            elseif mode == 3 then
                local nodes = r.chain_nodes or {}
                local node = nil
                for k, v in pairs(nodes) do if tostring(k) == tostring(state.chain_idx) then node = v; break end end
                
                if node then
                    local dur = node.duration or 0
                    if dur > 0 and elapsed >= dur then
                        state.chain_idx = state.chain_idx + 1
                        local node_count = 0; for _ in pairs(nodes) do node_count = node_count + 1 end
                        
                        if state.chain_idx > node_count then
                            state.loop_iteration = state.loop_iteration + 1
                            if (r.chain_loop_count or 1) > 0 and state.loop_iteration >= r.chain_loop_count then 
                                -- 【修复】链式播放完毕后，冻结在最后一个节点的帧上！直到回血才消失
                                state.phase = "holding"
                                state.chain_idx = node_count
                            else 
                                state.chain_idx = 1
                                state.phase_start = current_time 
                            end
                        else 
                            state.phase_start = current_time 
                        end
                    end
                else 
                    state.phase = "finished" 
                end
            end
            
        elseif state.phase == "inactive" then
            local off_time = r.loop_inactive_time or 0
            if elapsed >= off_time then 
                state.phase = "running"
                state.phase_start = current_time 
            end
        end
        
        -- 受击触发(闪烁)的变身通常没有悬停的意义，播放完毕就强行释放
        if state.phase == "holding" and r.trigger_on_damage then
             state.phase = "finished"
        end
    end

    -- 向主程序回传渲染目标
    if state and state.phase ~= "finished" then
        if state.phase == "delay" or state.phase == "inactive" then return nil, nil, nil end
        
        local state_id = state.phase .. "_" .. state.loop_iteration .. "_" .. state.chain_idx
        local r = state.rule
        local mode = r.mode or 1
        
        local targets_out = nil
        if mode == 1 or mode == 2 then 
            targets_out = r.targets
        elseif mode == 3 then 
            local nodes = r.chain_nodes or {}
            for k, v in pairs(nodes) do 
                if tostring(k) == tostring(state.chain_idx) then targets_out = v.targets; break end 
            end
        end
        
        if not targets_out then return nil, nil, nil end
        return r, targets_out, state_id
    end
    
    -- 彻底退出清理内存
    if state and state.phase == "finished" and state.is_healed then 
        timer_states[char_addr] = nil 
    end
    
    return nil, nil, nil
end

function TimerEngine.reset_states()
    timer_states = {}
end

return TimerEngine