-- Condition_LongSword.lua —— 太刀：气刃等级
local M = {}
M.id = "longsword"

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

    -- 太刀类型为 2
    local weaponType = field(player, "_playerWeaponType")
    if weaponType == nil then return nil end
    if weaponType ~= 2 then return nil end  -- 非太刀

    -- 气刃等级：读不到（例如非战斗场景）视为无刃（0）
    local gaugeLevel = field(player, "_LongSwordGaugeLv")
    if gaugeLevel == nil then return 0 end
    if type(gaugeLevel) == "number" then return gaugeLevel end
    return nil
end

function M.evaluate(config, character, char_addr, player)
    local level = M.get_state(player or character)
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
