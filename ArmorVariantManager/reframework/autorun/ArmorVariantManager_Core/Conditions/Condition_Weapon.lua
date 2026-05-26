-- Condition_Weapon.lua
local M = {}
M.id = "weapon"

local Utils = require("ArmorVariantManager_Core.Utils")

function M.get_state(character)
    local master = Utils.get_master_player()
    if not master then
        return nil  -- 无法获取玩家对象（如存档界面），不返回状态
    end
    return Utils.is_weapon_on(master)
end

function M.evaluate(config, character, char_addr)
    local drawn = M.get_state(character)
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