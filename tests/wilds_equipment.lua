package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local root = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Wilds/"
local now = 0
local sdk_mock = { is_managed_object = function(object) return object and not object.dead end }
local function game_object(object) return not object.dead and (object.go or object) or nil end
local mesh_type = { get_runtime_type = function() return "mesh" end }
local env = setmetatable({ sdk = sdk_mock, os = { clock = function() return now end },
    safe_get_game_object = game_object, get_type = function() return mesh_type end,
    global_config = { body_id_ttl = 1 }, preview_character_names = { CharaMake_HunterXX = true },
}, { __index = _G })
local function module(name) return assert(loadfile(root .. name .. ".lua", "t", env))() end

local function mesh(names)
    return { names = names or {}, call = function(self, method, index)
        if method == "get_MaterialNum" then return #self.names end
        if method == "getMaterialName" then return self.names[index + 1] end
        error(method)
    end }
end
local function node(name, children, component)
    local go = { name = name, mesh = component, children = children or {} }
    go.transform = { go = go }
    function go.transform:call(method)
        if method == "get_Child" then return go.children[1] and go.children[1].transform end
        if method == "get_Next" then return self.next end
        error(method)
    end
    function go:call(method, index)
        if method == "get_Name" then return self.name end
        if method == "get_Transform" then return self.transform end
        if method == "getComponent(System.Type)" then return self.mesh end
        if method == "getParts" then return self.parts and self.parts[index] end
        error(method)
    end
    if component then component.go = go end
    for index, child in ipairs(go.children) do
        child.transform.next = go.children[index + 1] and go.children[index + 1].transform
    end
    return go
end

local Equipment = module("Equipment")
local equipment = Equipment.new(game_object, env.global_config, env.preview_character_names)
local weapon = node("it0100_0001_0")
local shield = node("it0100_0001_1")
local body = node("ch02_001_0002", nil, mesh())
local character = node("Pl000_00", { node("ch00_000_0002"), node("ch03_001_0003"), body,
    node("Wp_Parent", { weapon }), node("WpSub_Parent", { shield }),
    node("ReserveParent", { node("it0999_0001_0") }) })
assert(equipment.body_id(character) == body.name)
local id, objects = equipment.weapon_id(character)
assert(id == "it0100_0001" and #objects == 2 and objects[1] == weapon and objects[2] == shield)
character.parts = { [1] = node("custom_body") }
assert(equipment.body_id(character) == body.name, "Existing TTL remains in effect")
now = 2; assert(equipment.body_id(character) == "custom_body")
character.parts[1].name = "changed_body"
equipment.clear("weapon")
assert(equipment.body_id(character) == "custom_body", "Weapon mode does not discard armor cache")
equipment.clear("armor")
assert(equipment.body_id(character) == "changed_body")
now = 5; equipment.prune(now); assert(equipment.body_id(character)=="changed_body")
character.dead = true; assert(equipment.body_id(character)==nil and equipment.weapon_id(character)==nil)
local preview = node("CharaMake_HunterXX", { node("renamed") })
assert(equipment.body_id(preview) == "CharaMake_HunterXX")
local bare_preview = node("CharaMake_HunterXX")
assert(equipment.body_id(bare_preview) == nil)
equipment.clear()
print("PASS: equipment IDs, weapon parts/reserve exclusion, armor TTL, slot reset, dead actors and menu previews")

local meshes = module("Meshes").new(game_object, env.get_type)
local first, second, face = mesh({ "cloth", "trim" }), mesh({ "cloth", "trim" }), mesh({ "cloth", "trim" })
local custom = node("custom", { node("nested", nil, second), node("Player_Face", nil, face) }, first)
local actor = node("Pl000_00", { custom })
actor.parts = { [1] = custom }
assert(#meshes.part_meshes(actor, 1, { materials = { cloth = true } }) == 2, "All body meshes, never face")
assert(meshes.first(custom) == first)
actor.parts = nil
local matches = meshes.part_meshes(actor, 1, { materials = { cloth = true, trim = false } })
assert(#matches == 2, "Renamed PFB fallback retains equal best material matches")
local simple = node("Pl000_00", { node("ch00_000_0002", nil, mesh()), body })
assert(meshes.part(simple, 1) == body)
local slots = { [0] = 3, [1] = 2, [2] = 1, [3] = 5, [4] = 4, [5] = 6 }
for index, suffix in pairs(slots) do
    local part = node("ch02_001_000" .. suffix, nil, mesh())
    local parent = node("Pl000_00", { part })
    assert(meshes.part(parent, index) == part)
end
local cached = meshes.all(actor)
custom.mesh = mesh({ "new_material" })
assert(meshes.all(actor) == cached)
meshes.clear()
assert(meshes.all(actor)[1] == custom.mesh, "Scene reset must release cached mesh list")
now = now + 1
assert(meshes.part_meshes(actor,1,{materials={new_material=true}})[1]==custom.mesh)
print("PASS: getParts/renamed PFB discovery, all slot suffixes, face exclusion and mesh cache reset")
