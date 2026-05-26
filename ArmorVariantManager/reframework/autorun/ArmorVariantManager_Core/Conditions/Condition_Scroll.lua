-- Condition_Scroll.lua
local M = {}
M.id = "scroll"

local Utils = require("ArmorVariantManager_Core.Utils")

function M.get_state(character)
    return Utils.get_current_scroll_state() -- "red" or "blue" or nil
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state(character)
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