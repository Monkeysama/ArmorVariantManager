-- Condition_Bow.lua
local M = {}
M.id = "bow"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 武器类型检查（弓箭类型为13）
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType ~= 13 then
        return nil
    end

    -- 调用 get_ChargeLv() 方法获取蓄力等级（0~3）
    local chargeLevel = masterPlayer:call("get_ChargeLv")
    if chargeLevel == nil then
        return 0
    end
    -- 如果返回的是枚举对象，取 value__；如果是数字，直接使用
    if type(chargeLevel) == "number" then
        return chargeLevel
    elseif type(chargeLevel) == "userdata" then
        local val = chargeLevel:get_field("value__")
        if type(val) == "number" then
            return val
        end
    end
    return 0
end

function M.evaluate(config, character, char_addr)
    local level = M.get_state()
    if level ~= nil and config.bow_transform_rules then
        for _, r in ipairs(config.bow_transform_rules) do
            if r.level == level then
                return r, level
            end
        end
    end
    return nil, level
end

function M.has_getter() return true end

return M