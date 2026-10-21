-- Condition_Weapon.lua —— 武器「收起 / 拔出」
local M = {}
M.id = "weapon"

local Utils = require("ArmorVariantManager_Core.Utils")

-- handle：指定玩家的句柄（Player 对象 / GameObject / nil = 本地玩家）
function M.get_state(handle)
    local player = Utils.resolve_player(handle)
    if not player then player = Utils.get_master_player() end
    if not player then
        return nil  -- 拿不到玩家对象（存档界面 / 读图中），不返回状态
    end
    return Utils.is_weapon_on(player)
end

function M.evaluate(config, character, char_addr, player)
    local drawn = M.get_state(player or character)
    if drawn == nil then
        return nil, nil  -- 未检测到状态，不激活规则
    end
    local state = drawn and "drawn" or "sheathed"
    if config.weapon_transform_rules then
        for _, r in ipairs(config.weapon_transform_rules) do
            if r.state == state then
                return r, state
            end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M
