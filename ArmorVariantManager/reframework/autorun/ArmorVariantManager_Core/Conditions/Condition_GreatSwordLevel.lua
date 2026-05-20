-- =============================================================================
-- 变身条件插件：大剑蓄力等级 (Great Sword Charge Level)
-- 描述：检测大剑当前蓄力的段数(0-3段)。
-- =============================================================================

local M = {}
M.id = "greatsword_level"

local function get_greatsword_charge_level_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return 0 end
    local ok, level = pcall(function() return wh:call("get_ChargeLevel") end)
    if ok and type(level) == "number" then
        if level >= 0 and level <= 3 then return level end
    end
    return 0
end

function M.get_state(character)
    if not character then return 0 end
    return get_greatsword_charge_level_direct(character)
end

function M.evaluate(config, character, char_addr)
    local level = M.get_state(character)
    if config.greatsword_level_transform_rules then
        for _, r in ipairs(config.greatsword_level_transform_rules) do
            if r.level == level then return r, level end
        end
    end
    return nil, level
end

function M.has_getter() return true end

return M