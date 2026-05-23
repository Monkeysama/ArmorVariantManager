local M = {}
M.id = "weapon"
local weapon_state_initialized = false
local weapon_state_getter = nil
local type_hunter_character = nil
local function get_hunter_character(character)
    if not character then return nil end
    local type_name = character:get_type_definition():get_name()
    if type_name and string.find(type_name, "HunterCharacter") then return character end
    if not type_hunter_character then
        type_hunter_character = sdk.find_type_definition("app.HunterCharacter")
        if not type_hunter_character then
            type_hunter_character = sdk.typeof("app.HunterCharacter")
        end
    end
    local ok, game_obj = pcall(function() return character:call("get_GameObject") end)
    if ok and game_obj and type_hunter_character then
        local runtime_type = type_hunter_character
        if type(type_hunter_character.get_runtime_type) == "function" then
            runtime_type = type_hunter_character:get_runtime_type()
        end
        local hc_ok, hc = pcall(function() return game_obj:call("getComponent(System.Type)", runtime_type) end)
        if hc_ok and hc then
            return hc
        end
    end
    return character
end
local function init_weapon_state_reflection(character)
    if weapon_state_initialized then return end
    local type_def = character:get_type_definition()
    if not type_def then return end
    local field_weapon_on = type_def:get_field("_IsWeaponOn")
    if field_weapon_on then
        weapon_state_getter = { field = field_weapon_on, is_field = true }
        weapon_state_initialized = true
        return
    end
    local method_names = {
        "get_IsWeaponDraw", "get_isWeaponDraw", "isWeaponDraw",
        "isDrawWeapon", "get_IsDrawWeapon"
    }
    for _, name in ipairs(method_names) do
        local m = type_def:get_method(name)
        if m then
            weapon_state_getter = { method = m, invert = false, is_field = false }
            weapon_state_initialized = true
            return
        end
    end
    if type_def:get_method("get_WeaponState") then
        local m = type_def:get_method("get_WeaponState")
        weapon_state_getter = { method = m, is_enum = true, is_field = false }
        weapon_state_initialized = true
        return
    end
end
function M.get_state(character)
    if not character then return false end
    local target_char = get_hunter_character(character)
    if not weapon_state_initialized then init_weapon_state_reflection(target_char) end
    if not weapon_state_getter then return false end
    if weapon_state_getter.is_field then
        local ok, res = pcall(function() return weapon_state_getter.field:get_data(target_char) end)
        if ok then return res == true end
        return false
    else
        local ok, res = pcall(function() return weapon_state_getter.method:call(target_char) end)
        if ok and res ~= nil then
            if weapon_state_getter.is_enum then
                return tonumber(res) > 0
            else
                return weapon_state_getter.invert and not res or (res == true)
            end
        end
    end
    return false
end
function M.evaluate(config, character, char_addr)
    local drawn = M.get_state(character)
    local target = drawn and "drawn" or "sheathed"
    local rules = config.weapon_transform_rules
    if rules then
        for _, r in ipairs(rules) do
            if r.state == target then
                return r, target
            end
        end
    end
    return nil, target
end
function M.has_getter()
    return weapon_state_getter ~= nil
end
return M
