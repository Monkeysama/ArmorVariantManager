-- =============================================================================
-- 变身条件插件：太刀气刃等级 (Long Sword Spirit Level)
-- 描述：检测太刀当前的炼气槽等级(白、黄、红刃等)。
-- =============================================================================

local M = {}
M.id = "spirit"

local spirit_level_getter = nil
local function get_spirit_level_direct(character)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return nil end
    local ok2, level = pcall(function() return wh:call("get_AuraLevel") end)
    if not ok2 then return nil end
    if type(level) == "number" then return level end
    return nil
end

local function init_spirit_level_reflection(character)
    if spirit_level_getter then return end
    local type_def = character:get_type_definition()
    if not type_def then return end
    local get_wh = type_def:get_method("get_WeaponHandling")
    if get_wh then
        local wh_type = get_wh:get_return_type()
        if wh_type then
            local get_aura = wh_type:get_method("get_AuraLevel")
            if get_aura then
                spirit_level_getter = { call = function(_, target)
                    local wh = get_wh:call(target)
                    if not wh then return nil end
                    local level = get_aura:call(wh)
                    return type(level) == "number" and level or nil
                end }
                return
            end
        end
    end
    local direct_aura = type_def:get_method("get_AuraLevel")
    if direct_aura then
        spirit_level_getter = { call = function(_, target) return direct_aura:call(target) end }
        return
    end
end

function M.get_state(character)
    if not character then return nil end
    local level = get_spirit_level_direct(character)
    if level then return level end
    if spirit_level_getter == nil then init_spirit_level_reflection(character) end
    if spirit_level_getter then
        local ok, result = pcall(function() return spirit_level_getter:call(character) end)
        if ok and result then return result end
    end
    return nil
end

function M.evaluate(config, character, char_addr)
    local level = M.get_state(character)
    if level and config.spirit_transform_rules then
        for _, r in ipairs(config.spirit_transform_rules) do
            if r.level == level then return r, level end
        end
    end
    return nil, level
end

function M.is_initialized() return true end
function M.has_getter() return true end

return M