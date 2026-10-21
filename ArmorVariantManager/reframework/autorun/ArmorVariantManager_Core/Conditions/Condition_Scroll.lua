-- Condition_Scroll.lua —— 红书 / 蓝书
local M = {}
M.id = "scroll"

local Utils = require("ArmorVariantManager_Core.Utils")

-- - 红蓝书状态是从本地玩家的 HUD 控件上读的，只对本地玩家成立。
--   联机时如果问的是队友，Utils 会返回 nil（= 不知道），于是队友身上不会激活
--   「书」规则 —— 这才是对的：队友的书不该跟着你的书来回变。
function M.get_state(handle)
    return Utils.get_current_scroll_state(handle) -- "red" / "blue" / nil
end

function M.evaluate(config, character, char_addr, player)
    local state = M.get_state(player or character)
    if state then
        if config.scroll_transform_rules then
            for _, r in ipairs(config.scroll_transform_rules) do
                if r.state == state then
                    return r, state
                end
            end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M
