-- Utils.lua
local Utils = {}
local SceneObject = require("ArmorVariantManager_Core.SceneObject")

-- ============================================================================
--  玩家句柄解析
-- ============================================================================

-- 判断一个句柄是不是 snow.player.Player（而不是 GameObject）：
-- 只有 Player 才有 getPlayerIndex()，这是最稳的判别方式。
local function is_player_object(handle)
    if not SceneObject.is_alive(handle) then return false end
    local ok, idx = pcall(function() return SceneObject.call(handle, "getPlayerIndex") end)
    return ok and type(idx) == "number"
end

-- 返回 player（可能为 nil）, game_object（可能为 nil）
local function resolve_player(handle)
    if handle == nil then
        local master = Utils.get_master_player()
        if not master then return nil, nil end
        local ok, go = pcall(function() return SceneObject.call(master, "get_GameObject") end)
        return master, (ok and go) or nil
    end
    if not SceneObject.is_alive(handle) then return nil, nil end
    if is_player_object(handle) then
        local ok, go = pcall(function() return SceneObject.call(handle, "get_GameObject") end)
        return handle, (ok and go) or nil
    end
    -- 传进来的是 GameObject
    return nil, handle
end
Utils.is_player_object = is_player_object
Utils.resolve_player = resolve_player

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
    -- - 崛起里实测可用的是 findMasterPlayer()（Lua Bone System / Lua Face System 也是这么拿的）；
    --   getMasterPlayer 作为兜底，兼容其它版本。
    local ok, master = pcall(function() return pm:call("findMasterPlayer()") end)
    if ok and master and SceneObject.is_alive(master) then return master end
    ok, master = pcall(function() return pm:call("getMasterPlayer") end)
    if ok and master and SceneObject.is_alive(master) then return master end
    return nil
end

function Utils.is_weapon_on(handle)
    local player = resolve_player(handle)
    if not player then return false end
    if player.isWeaponOn then
        local ok, v = pcall(function() return player:isWeaponOn() end)
        if ok then return v end
    end
    if player.get_IsWeaponOn then
        local ok, v = pcall(function() return player:get_IsWeaponOn() end)
        if ok then return v end
    end
    return false
end

function Utils.get_current_scroll_state(handle)
    -- 红蓝书状态是从本地玩家的 HUD 控件上读的，只对本地玩家有意义。
    -- 联机时如果问的是「别的玩家」，正确答案是「不知道」，
    -- 而不是把主角的状态套到队友身上（那样队友的书会跟着你的书乱变）。
    if handle ~= nil then
        local player, go = resolve_player(handle)
        local master = Utils.get_master_player()
        local master_go = nil
        if master then
            local ok, g = pcall(function() return SceneObject.call(master, "get_GameObject") end)
            if ok then master_go = g end
        end
        if player ~= nil then
            if master == nil or player ~= master then return nil end
        elseif master_go ~= nil and go ~= master_go then
            return nil
        end
    end
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

-- 获取武器类型（_playerWeaponType）
-- handle 可以是 Player 托管对象 / GameObject / nil（= 本地玩家）。
-- - 联机关键：传入队友的 Player 对象时读到的是**他自己**的武器类型。
--   拿不到指定玩家时兜底回本地玩家，保证旧调用点的行为不变。
function Utils.get_current_weapon_type(handle)
    local player = resolve_player(handle)
    if not player then player = Utils.get_master_player() end
    if not player then return nil end
    local ok, weaponType = pcall(function() return player:get_field("_playerWeaponType") end)
    if ok and type(weaponType) == "number" then
        return weaponType
    end
    return nil
end

-- 递归查找子物体中名称以指定前缀开头的 GameObject
-- （dfs_nodes 只用于性能诊断：统计一次查找到底访问了多少个节点）
local dfs_nodes = 0
local function find_child_with_prefix(transform, prefix, depth, maxDepth)
    if depth > maxDepth then return nil end
    local child = SceneObject.call(transform, "get_Child")
    while child do
        dfs_nodes = dfs_nodes + 1
        local child_obj = SceneObject.call(child, "get_GameObject")
        if child_obj then
            local name = SceneObject.call(child_obj, "get_Name")
            if name and string.sub(name, 1, #prefix) == prefix then
                return child_obj
            end
            local deeper = find_child_with_prefix(child, prefix, depth + 1, maxDepth)
            if deeper then return deeper end
        end
        child = SceneObject.call(child, "get_Next")
    end
    return nil
end

-- 获取武器部件列表
-- handle 可以是 Player 托管对象 / GameObject / nil（= 本地玩家）。
-- - 联机关键：武器类型与 GameObject 必须来自**同一个玩家**，
--   否则队友会被套上主角的武器部件（旧实现就是这样）。
local function get_current_weapon_parts_impl(handle)
    dfs_nodes = 0
    local player, go = resolve_player(handle)
    if not go then return nil end
    -- 用同一个玩家的类型去查表；player 为 nil（只给了 GameObject）时，
    -- get_current_weapon_type 会兜底回本地玩家，与旧行为一致。
    local weaponType = Utils.get_current_weapon_type(player or go)
    if weaponType == nil then return nil end

    local partsConfig = Utils.WEAPON_PARTS_MAP[weaponType]
    if not partsConfig then return nil end

    local ok_tf, transform = pcall(function() return SceneObject.call(go, "get_Transform") end)
    if not (ok_tf and transform) then return nil end

    local parts = {}
    for idx, partInfo in ipairs(partsConfig) do
        local prefix = partInfo.prefix
        local partObj = find_child_with_prefix(transform, prefix, 0, 5)
        parts[idx] = partObj
    end
    return parts
end
function Utils.get_current_weapon_parts(handle)
    local P = _G.__AVM_PROFILER
    local t0 = P and P.begin("utils_weapon_parts")
    local parts = get_current_weapon_parts_impl(handle)
    if P then
        P.finish("utils_weapon_parts", t0)
        P.count("utils_weapon_parts_calls")
        P.count("utils_weapon_dfs_nodes", dfs_nodes)
        P.max_value("utils_weapon_dfs_nodes_one_call", dfs_nodes)
    end
    return parts
end

-- 获取武器模式配置文件名
function Utils.get_weapon_config_id(handle)
    local weaponType = Utils.get_current_weapon_type(handle)
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