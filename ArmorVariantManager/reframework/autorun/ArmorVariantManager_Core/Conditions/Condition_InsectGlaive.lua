-- =============================================================================
-- 变身条件插件：操虫棍猎虫精华 (Insect Glaive Extracts)
-- 描述：检测操虫棍当前点亮的精华灯色(红、白、橙或三灯齐聚)。
--       使用了时间戳记录最后点亮的灯色作为当前主导状态。
-- =============================================================================

local M = {}
M.id = "insect_glaive"

local insect_glaive_timestamps = {}

local function get_insect_glaive_state_direct(character, char_addr)
    local ok1, wh = pcall(function() return character:call("get_WeaponHandling") end)
    if not ok1 or not wh then return "none" end
    
    local function get_lamp(method)
        local ok, val = pcall(function() return wh:call(method) end)
        return ok and val == true or false
    end
    
    local is_white = get_lamp("get_IsWhite")
    local is_orange = get_lamp("get_IsOrange")
    local is_red = get_lamp("get_IsRed")
    local is_triple = get_lamp("get_IsTrippleUp")
    
    if is_triple then return "triple" end
    
    if not insect_glaive_timestamps[char_addr] then insect_glaive_timestamps[char_addr] = {} end
    local stamps = insect_glaive_timestamps[char_addr]
    local current_time = os.clock()
    
    if is_white and not stamps.white then stamps.white = current_time
    elseif not is_white then stamps.white = nil end
    if is_orange and not stamps.orange then stamps.orange = current_time
    elseif not is_orange then stamps.orange = nil end
    if is_red and not stamps.red then stamps.red = current_time
    elseif not is_red then stamps.red = nil end
    
    local active_lamps = {}
    if is_white then table.insert(active_lamps, { name = "white", time = stamps.white }) end
    if is_orange then table.insert(active_lamps, { name = "orange", time = stamps.orange }) end
    if is_red then table.insert(active_lamps, { name = "red", time = stamps.red }) end
    
    if #active_lamps == 0 then return "none" end
    table.sort(active_lamps, function(a,b) return a.time > b.time end)
    return active_lamps[1].name
end

function M.get_state(character)
    if not character then return "none" end
    local char_go_ok, char_go = pcall(function() return character:call("get_GameObject") end)
    local char_addr = (char_go_ok and char_go) and tostring(char_go) or tostring(character)
    return get_insect_glaive_state_direct(character, char_addr)
end

function M.evaluate(config, character, char_addr)
    local state = M.get_state(character)
    if config.insect_glaive_transform_rules then
        for _, r in ipairs(config.insect_glaive_transform_rules) do
            if r.state == state then return r, state end
        end
    end
    return nil, state
end

function M.has_getter() return true end

return M