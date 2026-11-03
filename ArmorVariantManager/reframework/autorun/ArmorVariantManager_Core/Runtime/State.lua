local State = {}

-- 角色只用会话内键定位；同一槽位换装或换配置时丢弃旧结果。
function State.new()
    local actors = {}
    local state = {}

    function state:get(actor, slot, equipment, config)
        local slots = actors[actor]
        if not slots then slots = {}; actors[actor] = slots end
        local context = slots[slot]
        if not context or context.equipment ~= equipment or context.config ~= config then
            context = { equipment = equipment, config = config }
            slots[slot] = context
        end
        return context
    end

    function state:peek(actor, slot, equipment, config)
        local context = actors[actor] and actors[actor][slot]
        if context and context.equipment == equipment and context.config == config then return context end
    end

    -- 每帧以实际处理的角色收敛，场景清理不依赖对象地址永久唯一。
    function state:retain(seen)
        for actor, slots in pairs(actors) do
            if not seen[actor] then
                actors[actor] = nil
            else
                for slot in pairs(slots) do
                    if not seen[actor][slot] then slots[slot] = nil end
                end
            end
        end
    end

    function state:clear()
        actors = {}
    end

    return state
end

return State
