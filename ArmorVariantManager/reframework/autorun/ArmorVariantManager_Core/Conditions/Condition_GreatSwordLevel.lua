-- Condition_GreatSwordLevel.lua —— 大剑：蓄力等级
local M = {}
M.id = "greatsword_level"

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

    -- 大剑类型为 0
    if field(player, "_playerWeaponType") ~= 0 then
        return nil
    end

    -- 蓄力等级字段 _TameLv
    local tameLv = field(player, "_TameLv")
    if tameLv == nil then return 0 end  -- 读不到视为无蓄力
    if type(tameLv) == "number" then return tameLv end  -- 0~3
    return 0
end

function M.evaluate(config, character, char_addr, player)
    local level = M.get_state(player or character)
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
