-- Condition_Bow.lua —— 弓：蓄力等级
local M = {}
M.id = "bow"

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

    -- 武器类型检查（弓为 13）
    if field(player, "_playerWeaponType") ~= 13 then
        return nil
    end

    -- get_ChargeLv() 取得蓄力等级（0~3）
    local ok, chargeLevel = pcall(function() return player:call("get_ChargeLv") end)
    if not ok or chargeLevel == nil then
        return 0
    end
    if type(chargeLevel) == "number" then
        return chargeLevel
    elseif type(chargeLevel) == "userdata" then
        -- 返回枚举对象时取 value__
        local val = field(chargeLevel, "value__")
        if type(val) == "number" then return val end
    end
    return 0
end

function M.evaluate(config, character, char_addr, player)
    local level = M.get_state(player or character)
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
