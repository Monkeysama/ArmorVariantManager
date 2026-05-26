-- Utils.lua
local Utils = {}

function Utils.deep_copy_table(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[Utils.deep_copy_table(orig_key)] = Utils.deep_copy_table(orig_value)
        end
        setmetatable(copy, Utils.deep_copy_table(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

function Utils.get_type(name)
    return sdk.find_type_definition(name)
end

function Utils.get_player_manager()
    return sdk.get_managed_singleton("snow.player.PlayerManager") or sdk.get_managed_singleton("app.PlayerManager")
end

function Utils.get_master_player()
    local pm = Utils.get_player_manager()
    if not pm then return nil end
    if pm.getMasterPlayer then
        return pm:call("getMasterPlayer")
    elseif pm.findMasterPlayer then
        return pm:call("findMasterPlayer()")
    end
    return nil
end

function Utils.is_weapon_on(master_player)
    if not master_player then return false end
    if master_player.isWeaponOn then
        return master_player:isWeaponOn()
    end
    if master_player.get_IsWeaponOn then
        return master_player:get_IsWeaponOn()
    end
    return false
end

function Utils.get_current_scroll_state()
    local gui_manager = sdk.get_managed_singleton("snow.gui.GuiManager")
    if not gui_manager then return nil end
    local gui_hud = gui_manager:call("get_refGuiHud_WeaponTechniqueMySet")
    if not gui_hud then return nil end
    local pnl_scrollicon = gui_hud:get_field("pnl_scrollicon")
    if not pnl_scrollicon then return nil end
    local play_state = pnl_scrollicon:call("get_PlayState")
    if not play_state then return nil end
    if play_state == "DEFAULT_RED" or play_state == "RED_TO_BLUE" then
        return "red"
    elseif play_state == "DEFAULT_BLUE" or play_state == "BLUE_TO_RED" then
        return "blue"
    end
    return nil
end

return Utils