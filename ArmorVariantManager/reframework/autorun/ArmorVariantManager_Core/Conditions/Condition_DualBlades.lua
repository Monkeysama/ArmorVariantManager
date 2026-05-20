-- =============================================================================
-- 变身条件插件：双剑鬼人状态 (Dual Blades State)
-- 描述：检测双剑是否处于普通、鬼人化或鬼人强化状态。
-- =============================================================================

local M = {}
M.id = "dual_blades"

local function get_dual_blades_state_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "normal" end
    local ok2, kijin = pcall(function() return wh:call("get_IsKijinOn") end)
    if not ok2 then kijin = false end
    local ok3, enhance = pcall(function() return wh:call("get_IsKijinEnhancement") end)
    if not ok3 then enhance = false end
    if enhance then return "enhancement"
    elseif kijin then return "kijin"
    else return "normal" end
end

function M.get_state(character)
    if not character then return "normal" end
    return get_dual_blades_state_direct(character)
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state(character)
    if config.dual_blades_transform_rules then
        for _, r in ipairs(config.dual_blades_transform_rules) do
            if r.state == state then return r, state end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M