-- Condition_Hammer.lua —— 大锤：蓄力等级
local M = {}
M.id = "hammer"

local Utils = require("ArmorVariantManager_Core.Utils")

local function field(player, name)
    local ok, v = pcall(function() return player:get_field(name) end)
    if ok then return v end
    return nil
end

-- handle：指定玩家的句柄（Player 对象 / GameObject / nil = 本地玩家）
function M.get_state(handle)
    local player = Utils.resolve_player(handle)
    if not player then player = Utils.get_master_player() end
    if not player then return nil end

    -- 大锤类型为 5
    if field(player, "_playerWeaponType") ~= 5 then
        return nil
    end

    local chargeLevel = field(player, "<NowChargeLevel>k__BackingField")
    if chargeLevel == nil then return 0 end
    if type(chargeLevel) == "number" then return chargeLevel end  -- 0,1,2
    return 0
end

function M.evaluate(config, character, char_addr, player)
    local level = M.get_state(player or character)
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
