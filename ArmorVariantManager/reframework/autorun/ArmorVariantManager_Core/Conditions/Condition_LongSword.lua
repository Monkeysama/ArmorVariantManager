-- Condition_LongSword.lua
local M = {}
M.id = "longsword"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 检查武器类型，太刀序号为 2
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType == nil then
        return nil
    end
    if weaponType ~= 2 then
        return nil -- 非太刀
    end

    local gaugeLevel = masterPlayer:get_field("_LongSwordGaugeLv")
    -- 若无法获取气刃等级（例如非战斗场景），则视为无刃（0）
    if gaugeLevel == nil then
        return 0
    end
    if type(gaugeLevel) == "number" then
        return gaugeLevel
    end
    return nil
end

function M.evaluate(config, character, char_addr)
    local level = M.get_state()
    if level ~= nil and config.longsword_transform_rules then
        for _, r in ipairs(config.longsword_transform_rules) do
            if r.level == level then
                return r, level
            end
        end
    end
    return nil, level
end

function M.has_getter() return true end

return M