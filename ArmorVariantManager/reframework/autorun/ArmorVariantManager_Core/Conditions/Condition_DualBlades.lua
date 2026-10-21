-- Condition_DualBlades.lua —— 双刀：普通 / 鬼人化 / 鬼人强化
local M = {}
M.id = "dual_blades"

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

    -- 双刀类型为 9
    if field(player, "_playerWeaponType") ~= 9 then
        return nil
    end

    -- 基础状态（0=普通，1=鬼人化）；非战斗场景读不到时视为普通
    local stateValue = field(player, "<DBState>k__BackingField")
    if stateValue == nil then stateValue = 0 end

    -- 鬼人强化标志
    if field(player, "IsKijinKyouka") == true then
        return 2
    end
    return stateValue
end

function M.evaluate(config, character, char_addr, player)
    local state = M.get_state(player or character)
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
