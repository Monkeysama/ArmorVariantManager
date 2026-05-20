-- =============================================================================
-- 变身条件插件：盾斧状态 (Charge Blade State)
-- 描述：检测盾斧的剑/斧模式，以及剑强化、盾强化、斧强化的各种组合状态。
-- =============================================================================

local M = {}
M.id = "charge_blade"

local function get_charge_blade_state_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "sword" end
    
    local ok_shield, is_shield = pcall(function() return wh:call("get_IsShieldEnhanced") end)
    if not ok_shield then is_shield = false end
    local ok_axe, is_axe = pcall(function() return wh:call("get_IsAxeEnhanced") end)
    if not ok_axe then is_axe = false end
    local ok_sword, is_sword = pcall(function() return wh:call("get_IsSwordEnhanced") end)
    if not ok_sword then is_sword = false end
    local ok_mode, mode = pcall(function() return wh:call("get_Mode") end)
    if not ok_mode then mode = 0 end
    
    if is_shield and is_axe and is_sword then
        return "triple"
    end
    
    if mode == 0 then
        if is_shield and is_sword then
            return "sword_shield_sword"
        elseif is_shield then
            return "sword_shield"
        elseif is_sword then
            return "sword_sword"
        else
            return "sword"
        end
    else
        if is_axe then
            return "axe_axe"
        else
            return "axe"
        end
    end
end

function M.get_state(character)
    if not character then return "sword" end
    return get_charge_blade_state_direct(character)
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state(character)
    if config.charge_blade_transform_rules then
        for _, r in ipairs(config.charge_blade_transform_rules) do
            if r.state == state then return r, state end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M