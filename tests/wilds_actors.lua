-- 通过完整适配器验证角色来源、规则资格、场景清理与失效对象冷却。
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local root = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Wilds/"
local now, scene_id = 10, 1
local characters, transforms, players, master = {}, {}, {}, nil
local object_reads, clears, resets = 0, 0, 0
local scene = {}
local function array(items) return { get_elements = function() return items end } end
function scene:get_address() return scene_id end
function scene:call(name, kind)
    assert(name == "findComponents(System.Type)")
    return array(kind == "app.Character" and characters or transforms)
end
local manager = { call = function(_, name, index)
    if name == "get_InstancedPlayerNum" then return #players end
    if name == "getInstancedPlayer" then return players[index + 1] end
    if name == "getMasterPlayer" then return master end
    error(name)
end }
local env = setmetatable({ os = { clock = function() return now end } }, { __index = _G })
env.sdk = {
    typeof = function(name) return { get_runtime_type = function() return name end } end,
    is_managed_object = function(object) return object and object.valid ~= false end,
    get_managed_singleton = function(name) if name == "app.PlayerManager" then return manager end end,
    get_native_singleton = function() return {} end,
    call_native_func = function() return scene end,
    find_type_definition = function(name)
        if name:sub(1, 4) == "app." then return nil end
        return { get_method = function(_, method)
            return { call = function(_, object, ...)
                if name == "via.Component" then
                    object_reads = object_reads + 1
                    if object.dead then error("destroyed component") end
                    return object.go
                end
                return object:call(method, ...)
            end }
        end }
    end,
}
local guard = assert(loadfile(root .. "RuntimeGuard.lua", "t", env))()
env.require = function(name)
    if name == "ArmorVariantManager_Core.Games.Wilds.RuntimeGuard" then return guard end
    return require(name)
end
local objects = assert(loadfile(root .. "SceneObject.lua", "t", env))().new()
local function actor(name, body_id)
    local char = { body_id = body_id }
    local go = { name = name, draw = true }
    char.go = go
    function go:call(method)
        if method == "get_Name" then return self.name end
        if method == "get_Draw" then return self.draw end
        if method == "getComponent(System.Type)" then return char end
        error(method)
    end
    return char
end
local function player(char) return { call = function() return char end } end
local local_char = actor("Pl000_00", "custom_local")
local remote = actor("Pl001_00", "custom_remote")
local preview = actor("CharaMake_HunterXX", "custom_preview")
local npc = actor("NPC", "custom_npc")
local cached = actor("Pl002_00", "ch03_cache")
players, master = { player(local_char), player(remote) }, player(local_char)
characters = { local_char, remote, preview, npc, cached }
transforms = characters
local Actors = assert(loadfile(root .. "Actors.lua", "t", env))()
local actors = Actors.new({ scan_interval = 0.5, scanner_batch_size = 100 }, objects,
    { body_id = function(char) return char.body_id end, prune = function() end,
      clear = function() clears = clears + 1 end },
    { clear = function() clears = clears + 1 end }, function() resets = resets + 1 end)
assert(actors.tick())
local function members(list)
    local result = {}
    for _, char in ipairs(list) do assert(not result[char], "Duplicate actor"); result[char] = true end
    return result
end
local found = members(actors.all())
assert(found[local_char] and found[remote] and found[preview] and found[cached] and not found[npc])
assert(actors.can_transform(local_char) and actors.can_transform(remote))
assert(not actors.can_transform(preview) and not actors.can_transform(cached) and not actors.can_transform(npc))
assert(actors.local_player() == preview, "Visible editor preview takes precedence over master")
preview.go.draw = false
assert(actors.local_player() == local_char)
remote.go.draw = false
found = members(actors.all())
assert(not found[preview] and not found[remote], "Hidden game actors must not receive overrides")
assert(actors.cached()[tostring(preview.go)] == nil)
now = now + 11
assert(not members(actors.all())[cached], "Expired scanner result removed")
players, master = {}, nil
assert(actors.local_player() == nil, "Local-player grace expires")
assert(not actors.can_transform(local_char), "Rule eligibility follows current player list")
master = player(local_char)
assert(actors.local_player() == local_char)
master = nil
now = now + 0.2
assert(actors.local_player() == local_char, "Brief player disappearance keeps UI selection")

-- 新场景隔离旧扫描结果，清理回调只由 guard.update 执行。
actors.guard:begin_transition(false)
assert(resets == 0 and not actors.can_transform(local_char))
assert(actors.guard:update() and resets == 1 and clears == 2)
assert(next(actors.cached()) == nil and actors.local_player() == nil)
characters, transforms, scene_id = {}, {}, 2
actors.guard:mark_load_end(false)
assert(not actors.guard:update())
assert(actors.tick() and resets == 1)

local dead = actor("Pl003_00", "ch03_dead")
dead.dead = true
local before = object_reads
assert(objects.game_object(dead) == nil and object_reads == before + 1)
assert(objects.game_object(dead) == nil and object_reads == before + 1)
now = now + 1
assert(objects.game_object(dead) == nil and object_reads == before + 2)
dead.dead = false
objects.clear()
assert(objects.game_object(dead) == dead.go, "Scene cleanup clears stale-object cooldown")
dead.go.valid = false
assert(objects.game_object(dead) == nil, "Invalid GameObject rejected")

print("PASS: Wilds actor sources, visibility, rule eligibility, scene cleanup and dead-object cooldown")
