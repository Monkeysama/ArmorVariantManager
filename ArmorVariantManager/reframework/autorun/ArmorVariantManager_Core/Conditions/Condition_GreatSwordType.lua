local M = {}
M.id = "greatsword_type"
local function get_greatsword_charge_type_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "other" end
    local ok, charge_type = pcall(function() return wh:call("get_ChargeType") end)
    if not ok then return "other" end
    if type(charge_type) == "number" then
        if charge_type == 0 then return "0"
        elseif charge_type == 1 then return "1"
        elseif charge_type == 2 then return "2"
        elseif charge_type == 3 then return "3"
        elseif charge_type == 5 then return "5"
        else return "other" end
    end
    return "other"
end
function M.get_state(character)
    if not character then return "other" end
    return get_greatsword_charge_type_direct(character)
end
function M.evaluate(config, character, char_addr)
    local state = M.get_state(character)
    if config.greatsword_type_transform_rules then
        for _, r in ipairs(config.greatsword_type_transform_rules) do
            if r.state == state then return r, state end
        end
    end
    return nil, state
end
function M.has_getter() return true end
return M
