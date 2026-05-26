-- Condition_GreatSwordLevel.lua
local M = {}
M.id = "greatsword_level"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 武器类型检查（大剑类型为0）
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType ~= 0 then
        return nil
    end

    -- 读取蓄力等级字段 _TameLv
    local tameLv = masterPlayer:get_field("_TameLv")
    if tameLv == nil then
        return 0  -- 无法读取时视为无蓄力
    end
    if type(tameLv) == "number" then
        return tameLv  -- 0~3
    end
    return 0
end

function M.evaluate(config, character, char_addr)
    local level = M.get_state()
    if level ~= nil and config.greatsword_level_transform_rules then
        for _, r in ipairs(config.greatsword_level_transform_rules) do
            if r.level == level then
                return r, level
            end
        end
    end
    return nil, level
end

function M.has_getter() return true end

return M