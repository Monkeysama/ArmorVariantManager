-- Condition_Hammer.lua
local M = {}
M.id = "hammer"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 武器类型检查（大锤类型为5）
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType ~= 5 then
        return nil
    end

    -- 读取蓄力等级 backing field
    local chargeLevel = masterPlayer:get_field("<NowChargeLevel>k__BackingField")
    if chargeLevel == nil then
        return 0
    end
    if type(chargeLevel) == "number" then
        return chargeLevel  -- 0,1,2
    end
    return 0
end

function M.evaluate(config, character, char_addr)
    local level = M.get_state()
    if level ~= nil and config.hammer_transform_rules then
        for _, r in ipairs(config.hammer_transform_rules) do
            if r.level == level then
                return r, level
            end
        end
    end
    return nil, level
end

function M.has_getter() return true end

return M