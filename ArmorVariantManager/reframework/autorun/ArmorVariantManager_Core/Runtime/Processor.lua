local Processor = {}

-- 两游戏共用配置到材质的顺序；角色句柄、规则与写入由各自适配器处理。
-- identify(actor, slot)、load(id, actor)、initialize(id, config)、
-- resolve(id, config, actor, slot)、apply(actor, slot, objects, result, changed, id, config)。
function Processor.new(callbacks)
    return function(actor)
        local seen = {}
        for _, slot in ipairs({"armor", "weapon"}) do
            local id, objects = callbacks.identify(actor, slot)
            if id and (slot == "armor" or objects) then
                local config = callbacks.load(id, actor)
                if config then
                    callbacks.initialize(id, config)
                    seen[slot] = true
                    local result, changed = callbacks.resolve(id, config, actor, slot)
                    callbacks.apply(actor, slot, objects, result, changed, id, config)
                end
            end
        end
        return seen
    end
end

return Processor
