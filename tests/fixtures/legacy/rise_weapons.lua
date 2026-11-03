-- MHR 093c61c：冻结武器映射和递归查找。
local source = [====[
local Utils = {resolve_player=resolve_player,get_current_weapon_type=get_current_weapon_type}
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
    local player, go = Utils.resolve_player(handle)
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

return Utils
]====]
return function(env) return assert(load(source, "legacy-rise-weapons", "t", env))() end
