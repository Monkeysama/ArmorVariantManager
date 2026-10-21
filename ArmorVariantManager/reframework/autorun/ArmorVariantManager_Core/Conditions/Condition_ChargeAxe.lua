-- Condition_ChargeAxe.lua —— 盾斧：斧 / 剑 形态 + 红盾 / 红剑 / 红斧
local M = {}
M.id = "charge_axe"

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

    -- 盾斧类型为 11
    if field(player, "_playerWeaponType") ~= 11 then
        return nil
    end

    -- get_Mode() 返回 0=剑, 1=斧；这里换算成内部状态 0=斧, 1=剑
    local ok, rawMode = pcall(function() return player:call("get_Mode") end)
    if not ok or type(rawMode) ~= "number" then rawMode = 0 end
    local mode = (rawMode == 1) and 0 or 1

    -- 各 Buff 状态
    local shieldBuff = field(player, "_ShieldBuffTimer") or 0    -- 红盾
    local swordBuff = field(player, "_SwordBuffTimer") or 0      -- 红剑
    local axeBuff = field(player, "_IsChainsawBuff") or false    -- 红斧（布尔）

    if mode == 0 then  -- 斧形态
        if axeBuff == true then return 2 end
        return 0
    end
    -- 剑形态
    local hasRedShield = shieldBuff > 0
    local hasRedSword = swordBuff > 0
    if hasRedShield and hasRedSword then return 5 end
    if hasRedShield then return 3 end
    if hasRedSword then return 4 end
    return 1
end

function M.evaluate(config, character, char_addr, player)
    local state = M.get_state(player or character)
    if state ~= nil and config.charge_axe_transform_rules then
        for _, r in ipairs(config.charge_axe_transform_rules) do
            if r.state == state then
                return r, state
            end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M
