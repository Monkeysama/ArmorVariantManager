-- Condition_ChargeAxe.lua
local M = {}
M.id = "charge_axe"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 武器类型检查（盾斧类型为11）
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType ~= 11 then
        return nil
    end

    -- 获取基础形态：get_Mode() 返回 0=剑, 1=斧
    local rawMode = masterPlayer:call("get_Mode")
    if type(rawMode) ~= "number" then
        rawMode = 0
    end
    -- 转换为内部状态：0=斧, 1=剑
    local mode = (rawMode == 1) and 0 or 1

    -- 获取各Buff状态
    local shieldBuff = masterPlayer:get_field("_ShieldBuffTimer") or 0   -- 红盾（剑形态）
    local swordBuff = masterPlayer:get_field("_SwordBuffTimer") or 0     -- 红剑（剑形态）
    local axeBuff = masterPlayer:get_field("_IsChainsawBuff") or false   -- 红斧（斧形态，布尔值）

    if mode == 0 then  -- 斧形态
        if axeBuff == true then
            return 2  -- 斧形态 + 红斧
        else
            return 0  -- 斧形态无Buff
        end
    else  -- 剑形态
        local hasRedShield = shieldBuff > 0
        local hasRedSword = swordBuff > 0
        if hasRedShield and hasRedSword then
            return 5  -- 剑形态 + 红盾 + 红剑
        elseif hasRedShield then
            return 3  -- 剑形态 + 红盾
        elseif hasRedSword then
            return 4  -- 剑形态 + 红剑
        else
            return 1  -- 剑形态无Buff
        end
    end
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state()
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