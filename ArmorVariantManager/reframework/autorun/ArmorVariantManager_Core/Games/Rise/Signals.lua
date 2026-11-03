-- Signals.lua
local Signals = {}
local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")

local sample_epoch, samples
local actor_aliases=setmetatable({}, {__mode='k'})
local NIL={}
function Signals.begin_frame(epoch)
    if sample_epoch~=epoch then sample_epoch,samples=epoch,{} end
end
function Signals.invalidate_samples() sample_epoch,samples=nil,nil end
-- 场景清理同时释放玩家别名，避免沿用已离场的句柄。
function Signals.clear()
    Signals.invalidate_samples()
    actor_aliases=setmetatable({}, {__mode='k'})
end
function Signals.forget_actor(game_object) actor_aliases[game_object]=nil end
function Signals.bind_actor(player,game_object)
    if player and game_object then actor_aliases[game_object]=player end
end
local function memo(handle,key,reader)
    if not samples then return reader() end
    handle=handle or NIL
    local values=samples[handle]
    if not values then values={};samples[handle]=values end
    local value=values[key]
    if value~=nil then if value==NIL then return nil end;return value end
    value=reader();values[key]=value==nil and NIL or value
    return value
end
function Signals.read_player_field(player,name)
    return memo(player,name,function()
        local ok,value=pcall(function() return player:get_field(name) end)
        if ok then return value end
    end)
end
function Signals.sample_condition(kind,handler,character,player)
    local handle=player or character
    local owner=actor_aliases[handle] or handle
    return memo(owner,'condition:'..kind,function()
        return handler.get_state(player or character)
    end)
end


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
        local master = Signals.get_master_player()
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
Signals.is_player_object = is_player_object
Signals.resolve_player = function(handle)
    local result=memo(handle,'resolved_player',function() return table.pack(resolve_player(handle)) end)
    return table.unpack(result,1,result.n)
end

function Signals.get_player_manager()
    return sdk.get_managed_singleton("snow.player.PlayerManager") or sdk.get_managed_singleton("app.PlayerManager")
end

local function get_master_player_uncached()
    local pm = Signals.get_player_manager()
    if not pm then return nil end
    -- - 崛起里实测可用的是 findMasterPlayer()（Lua Bone System / Lua Face System 也是这么拿的）；
    --   getMasterPlayer 作为兜底，兼容其它版本。
    local ok, master = pcall(function() return pm:call("findMasterPlayer()") end)
    if ok and master and SceneObject.is_alive(master) then return master end
    ok, master = pcall(function() return pm:call("getMasterPlayer") end)
    if ok and master and SceneObject.is_alive(master) then return master end
    return nil
end

function Signals.get_master_player() return memo(nil,'master',get_master_player_uncached) end

function Signals.is_weapon_on(handle)
    local player = Signals.resolve_player(handle)
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

function Signals.get_current_scroll_state(handle)
    -- 红蓝书状态是从本地玩家的 HUD 控件上读的，只对本地玩家有意义。
    -- 联机时如果问的是「别的玩家」，正确答案是「不知道」，
    -- 而不是把主角的状态套到队友身上（那样队友的书会跟着你的书乱变）。
    if handle ~= nil then
        local player, go = Signals.resolve_player(handle)
        local master = Signals.get_master_player()
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

-- 获取武器类型（_playerWeaponType）
-- handle 可以是 Player 托管对象 / GameObject / nil（= 本地玩家）。
-- - 联机关键：传入队友的 Player 对象时读到的是**他自己**的武器类型。
--   拿不到指定玩家时兜底回本地玩家，保证旧调用点的行为不变。
function Signals.get_current_weapon_type(handle)
    local player = Signals.resolve_player(handle)
    if not player then player = Signals.get_master_player() end
    if not player then return nil end
    local weaponType = Signals.read_player_field(player, "_playerWeaponType")
    if type(weaponType) == "number" then
        return weaponType
    end
    return nil
end

return Signals
