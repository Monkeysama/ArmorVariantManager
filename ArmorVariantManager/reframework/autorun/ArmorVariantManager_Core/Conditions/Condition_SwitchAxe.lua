-- Condition_SwitchAxe.lua
local M = {}
M.id = "switch_axe"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 武器类型检查（斩斧类型为1）
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType ~= 1 then
        return nil
    end

    -- 检查高出力模式剩余时间
    local awakeTimer = masterPlayer:get_field("_BottleAwakeDurationTimer")
    if awakeTimer ~= nil and awakeTimer > 0 then
        return 2  -- 高出力模式
    end

    -- 获取武器形态：get_Mode 直接返回数字（0=斧, 1=剑）
    local mode = masterPlayer:call("get_Mode")
    if type(mode) == "number" then
        return mode
    end

    -- 无法获取形态时默认普通
    return 0
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state()
    if state ~= nil and config.switch_axe_transform_rules then
        for _, r in ipairs(config.switch_axe_transform_rules) do
            if r.state == state then
                return r, state
            end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M