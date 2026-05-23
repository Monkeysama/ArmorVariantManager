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
    if config.damage_transform_rules then
        -- 使用 pairs 遍历防范 JSON 字典化 Bug
        for _, r in pairs(config.damage_transform_rules) do
            damage_rule = r
            break
        end
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
    local state = timer_states[char_addr]

    -- 2. 如果受击，启动/重置状态机
    if took_damage then
        state = {
            rule = damage_rule,
            phase = (damage_rule.condition_delay and damage_rule.condition_delay > 0) and "delay" or "running",
            phase_start = current_time,
            loop_iteration = 0,
            chain_idx = 1
        }
        timer_states[char_addr] = state
    end

    -- 3. 状态机时序推进
    if state and state.phase ~= "finished" then
        local elapsed = current_time - state.phase_start
        local r = state.rule
        local mode = r.mode or 1

        if state.phase == "delay" then
            if elapsed >= (r.condition_delay or 0) then
                state.phase = "running"
                state.phase_start = current_time
                elapsed = 0
            end
        elseif state.phase == "running" then
            if mode == 1 then
                local dur = r.duration or 0.5
                if dur > 0 and elapsed >= dur then
                    state.phase = "finished"
                end
            elseif mode == 2 then
                local dur = r.duration or 0.5
                if dur > 0 and elapsed >= dur then
                    state.loop_iteration = state.loop_iteration + 1
                    if (r.loop_count or 0) > 0 and state.loop_iteration >= r.loop_count then
                        state.phase = "finished"
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
                    local dur = node.duration or 0.5
                    if dur > 0 and elapsed >= dur then
                        state.chain_idx = state.chain_idx + 1
                        local node_count = 0; for _ in pairs(nodes) do node_count = node_count + 1 end
                        
                        if state.chain_idx > node_count then
                            state.loop_iteration = state.loop_iteration + 1
                            if (r.chain_loop_count or 1) > 0 and state.loop_iteration >= r.chain_loop_count then
                                state.phase = "finished"
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
    end

    -- 4. 返回状态与虚拟规则
    if state and state.phase ~= "finished" then
        if state.phase == "delay" or state.phase == "inactive" then
            return nil, "dmg_" .. state.phase
        end
        
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
        
        if targets_out then
            -- Create a proxy rule to return so TransformManager can read its targets
            local proxy_rule = { targets = targets_out }
            return proxy_rule, "dmg_" .. state_id
        end
    end

    -- 5. 清理已完成的状态
    if state and state.phase == "finished" then
        timer_states[char_addr] = nil
    end

    return nil, "dmg"
end

function M.get_remaining_time(char_addr)
    local state = timer_states[char_addr]
    if state and state.phase ~= "finished" then
        local r = state.rule
        local mode = r.mode or 1
        local elapsed = os.clock() - state.phase_start
        if state.phase == "running" then
            local dur = 0
            if mode == 1 or mode == 2 then
                dur = r.duration or 0.5
            elseif mode == 3 then
                local nodes = r.chain_nodes or {}
                for k, v in pairs(nodes) do if tostring(k) == tostring(state.chain_idx) then dur = v.duration or 0.5; break end end
            end
            local remaining = dur - elapsed
            if remaining > 0 then return remaining end
        elseif state.phase == "delay" then
            return (r.condition_delay or 0) - elapsed
        elseif state.phase == "inactive" then
            return (r.loop_inactive_time or 0) - elapsed
        end
    end
    return 0
end

return M