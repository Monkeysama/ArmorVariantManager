-- Condition_SwitchAxe.lua —— 斩击斧：斧 / 剑 / 高出力
local M = {}
M.id = "switch_axe"

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

    -- 斩击斧类型为 1
    if field(player, "_playerWeaponType") ~= 1 then
        return nil
    end

    -- 高出力模式剩余时间
    local awakeTimer = field(player, "_BottleAwakeDurationTimer")
    if awakeTimer ~= nil and awakeTimer > 0 then
        return 2
    end

    -- get_Mode 直接返回数字（0=斧, 1=剑）
    local ok, mode = pcall(function() return player:call("get_Mode") end)
    if ok and type(mode) == "number" then
        return mode
    end

    -- 无法获取形态时默认普通
    return 0
end

function M.evaluate(config, character, char_addr, player)
    local state = M.get_state(player or character)
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
