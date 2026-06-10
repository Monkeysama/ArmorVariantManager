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

-- ============================================================================
-- 武器差分相关功能（基于“单一本地玩家”可工作的版本）
-- ============================================================================

-- 武器类型常量
Utils.WEAPON_TYPE = {
    GREATSWORD = 0,
    SWITCH_AXE = 1,
    LONGSWORD = 2,
    LIGHT_BOWGUN = 3,
    HEAVY_BOWGUN = 4,
    HAMMER = 5,
    GUNLANCE = 6,
    LANCE = 7,
    SWORD_SHIELD = 8,
    DUAL_BLADES = 9,
    HUNTING_HORN = 10,
    CHARGE_BLADE = 11,
    INSECT_GLAIVE = 12,
    BOW = 13
}

-- 武器部件前缀映射表
Utils.WEAPON_PARTS_MAP = {
    [Utils.WEAPON_TYPE.GREATSWORD] = {
        { name = "Blade", prefix = "G_Swd" }
    },
    [Utils.WEAPON_TYPE.SWITCH_AXE] = {
        { name = "Axe", prefix = "S_Axe" }
    },
    [Utils.WEAPON_TYPE.LONGSWORD] = {
        { name = "Sheath", prefix = "LS_Saya" },
        { name = "Blade", prefix = "LS_Swd" }
    },
    [Utils.WEAPON_TYPE.LIGHT_BOWGUN] = {
        { name = "Bowgun", prefix = "L_Bg" }
    },
    [Utils.WEAPON_TYPE.HEAVY_BOWGUN] = {
        { name = "Bowgun", prefix = "H_Bg" }
    },
    [Utils.WEAPON_TYPE.HAMMER] = {
        { name = "Hammer", prefix = "Ham" }
    },
    [Utils.WEAPON_TYPE.GUNLANCE] = {
        { name = "Shield", prefix = "GL_Sld" },
        { name = "Lance", prefix = "GL_Lan" }
    },
    [Utils.WEAPON_TYPE.LANCE] = {
        { name = "Shield", prefix = "L_Sld" },
        { name = "Lance", prefix = "L_Lan" }
    },
    [Utils.WEAPON_TYPE.SWORD_SHIELD] = {
        { name = "Shield", prefix = "SS_Sld" },
        { name = "Sword", prefix = "SS_Swd" }
    },
    [Utils.WEAPON_TYPE.DUAL_BLADES] = {
        { name = "Left", prefix = "DB_L" },
        { name = "Right", prefix = "DB_R" }
    },
    [Utils.WEAPON_TYPE.HUNTING_HORN] = {
        { name = "Horn", prefix = "Hrn" }
    },
    [Utils.WEAPON_TYPE.CHARGE_BLADE] = {
        { name = "Shield", prefix = "CA_Sld" },
        { name = "Sword", prefix = "CA_Swd" }
    },
    [Utils.WEAPON_TYPE.INSECT_GLAIVE] = {
        { name = "Insect", prefix = "IG_Ins" },
        { name = "Glaive", prefix = "IG_Gla" }
    },
    [Utils.WEAPON_TYPE.BOW] = {
        { name = "Bow", prefix = "B_Bow" },
        { name = "Quiver", prefix = "B_Ydt" }
    }
}

-- 获取当前玩家武器类型（直接使用主玩家）
function Utils.get_current_weapon_type()
    local master = Utils.get_master_player()
    if not master then return nil end
    local weaponType = master:get_field("_playerWeaponType")
    if type(weaponType) == "number" then
        return weaponType
    end
    return nil
end

-- 递归查找子物体中名称以指定前缀开头的 GameObject
local function find_child_with_prefix(transform, prefix, depth, maxDepth)
    if depth > maxDepth then return nil end
    local child = transform:call("get_Child")
    while child do
        local child_obj = child:call("get_GameObject")
        if child_obj then
            local name = child_obj:call("get_Name")
            if name and string.sub(name, 1, #prefix) == prefix then
                return child_obj
            end
            local deeper = find_child_with_prefix(child, prefix, depth + 1, maxDepth)
            if deeper then return deeper end
        end
        child = child:call("get_Next")
    end
    return nil
end

-- 获取当前武器部件列表（基于主玩家的 GameObject）
function Utils.get_current_weapon_parts()
    local master = Utils.get_master_player()
    if not master then return nil end
    local weaponType = Utils.get_current_weapon_type()
    if weaponType == nil then return nil end

    local partsConfig = Utils.WEAPON_PARTS_MAP[weaponType]
    if not partsConfig then return nil end

    -- 获取玩家的 GameObject
    local playerObj = master
    if not playerObj.get_Transform then
        local ok, go = pcall(function() return master:call("get_GameObject") end)
        if ok and go then
            playerObj = go
        else
            return nil
        end
    end

    local transform = playerObj:call("get_Transform")
    if not transform then return nil end

    local parts = {}
    for idx, partInfo in ipairs(partsConfig) do
        local prefix = partInfo.prefix
        local partObj = find_child_with_prefix(transform, prefix, 0, 5)
        parts[idx] = partObj
    end
    return parts
end

-- 获取武器模式配置文件名
function Utils.get_weapon_config_id()
    local weaponType = Utils.get_current_weapon_type()
    if weaponType == nil then return nil end
    return "weapon_" .. tostring(weaponType)
end

-- 获取武器部件显示名称
function Utils.get_weapon_part_name(weaponType, partIndex)
    local partsConfig = Utils.WEAPON_PARTS_MAP[weaponType]
    if not partsConfig or not partsConfig[partIndex + 1] then
        return "Part " .. tostring(partIndex)
    end
    return partsConfig[partIndex + 1].name
end

return Utils