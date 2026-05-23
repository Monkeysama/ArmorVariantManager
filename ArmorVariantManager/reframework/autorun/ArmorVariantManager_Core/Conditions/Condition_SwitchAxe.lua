local M = {}
M.id = "switch_axe"
local function get_switch_axe_state_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "axe_normal" end
    local ok_mode, mode = pcall(function() return wh:call("get_Mode") end)
    if not ok_mode then mode = 1 end
    local ok_axe_enh, axe_enh = pcall(function() return wh:call("get_IsAxeEnhanced") end)
    if not ok_axe_enh then axe_enh = false end
    local ok_sword_awaken, sword_awaken = pcall(function() return wh:call("get_IsSwordAwaken") end)
    if not ok_sword_awaken then sword_awaken = false end
    if mode == 0 then
        if axe_enh then return "axe_enhanced"
        else return "axe_normal" end
    else
        if sword_awaken then return "sword_awakened"
        else return "sword_normal" end
    end
end
function M.get_state(character)
    if not character then return "axe_normal" end
    return get_switch_axe_state_direct(character)
end
function M.evaluate(config, character, char_addr)
    local state = M.get_state(character)
    if config.switch_axe_transform_rules then
        for _, r in ipairs(config.switch_axe_transform_rules) do
            if r.state == state then return r, state end
        end
    end
    return nil, state
end
function M.has_getter() return true end
return M
