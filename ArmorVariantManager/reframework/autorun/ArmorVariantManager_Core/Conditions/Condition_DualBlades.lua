-- Condition_DualBlades.lua
local M = {}
M.id = "dual_blades"

function M.get_state()
    local playerManager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if not playerManager then return nil end
    local masterPlayer = playerManager:call("findMasterPlayer()")
    if not masterPlayer then return nil end

    -- 武器类型检查（双刀类型为9）
    local weaponType = masterPlayer:get_field("_playerWeaponType")
    if weaponType ~= 9 then
        return nil
    end

    -- 获取基础状态（0=普通，1=鬼人化）
    local stateValue = masterPlayer:get_field("<DBState>k__BackingField")
    if stateValue == nil then
        -- 非战斗场景无法读取，视为普通状态
        stateValue = 0
    end

    -- 检查鬼人强化标志
    local isKyouka = masterPlayer:get_field("IsKijinKyouka")
    if isKyouka == true then
        return 2  -- 鬼人强化
    end

    return stateValue
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state()
    if state ~= nil and config.dual_blades_transform_rules then
        for _, r in ipairs(config.dual_blades_transform_rules) do
            if r.state == state then
                return r, state
            end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M