package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
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
local old = dofile("tests/fixtures/legacy/wilds_equipment.lua")(env)
local function same_id(character)
    assert(equipment.body_id(character) == old.body_id(character))
    local id, objects = equipment.weapon_id(character)
    local old_id, old_objects = old.weapon_id(character)
    assert(id == old_id)
    assert((objects == nil) == (old_objects == nil))
    for i, object in ipairs(objects or {}) do assert(object == old_objects[i]) end
    return id, objects
end
local weapon = node("it0100_0001_0")
local shield = node("it0100_0001_1")
local body = node("ch02_001_0002", nil, mesh())
local character = node("Pl000_00", { node("ch00_000_0002"), node("ch03_001_0003"), body,
    node("Wp_Parent", { weapon }), node("WpSub_Parent", { shield }),
    node("ReserveParent", { node("it0999_0001_0") }) })
same_id(character)
assert(equipment.body_id(character) == body.name)
local id, objects = equipment.weapon_id(character)
assert(id == "it0100_0001" and #objects == 2 and objects[1] == weapon and objects[2] == shield)
character.parts = { [1] = node("custom_body") }
assert(equipment.body_id(character) == body.name, "Existing TTL remains in effect")
now = 2; same_id(character)
assert(equipment.body_id(character) == "custom_body")
character.parts[1].name = "changed_body"
equipment.clear("weapon")
assert(equipment.body_id(character) == "custom_body", "Weapon mode does not discard armor cache")
equipment.clear("armor")
assert(equipment.body_id(character) == "changed_body")
now = 5; equipment.prune(now); same_id(character)
character.dead = true; same_id(character)
local preview = node("CharaMake_HunterXX", { node("renamed") })
same_id(preview); assert(equipment.body_id(preview) == "CharaMake_HunterXX")
local bare_preview = node("CharaMake_HunterXX")
same_id(bare_preview); assert(equipment.body_id(bare_preview) == nil)
equipment.clear()
print("PASS: legacy equipment IDs, weapon parts/reserve exclusion, armor TTL, slot reset, dead actors and menu previews")

local meshes = module("Meshes").new(game_object, env.get_type)
local old_meshes = dofile("tests/fixtures/legacy/wilds_meshes.lua")(env)
local function same_meshes(actor, index, data)
    assert(meshes.part(actor, index) == old_meshes.part(actor, index))
    local actual, expected = meshes.part_meshes(actor, index, data), old_meshes.part_meshes(actor, index, data)
    assert(#actual == #expected)
    for i, value in ipairs(actual) do assert(value == expected[i]) end
    return actual
end
local first, second, face = mesh({ "cloth", "trim" }), mesh({ "cloth", "trim" }), mesh({ "cloth", "trim" })
local custom = node("custom", { node("nested", nil, second), node("Player_Face", nil, face) }, first)
local actor = node("Pl000_00", { custom })
actor.parts = { [1] = custom }
assert(#same_meshes(actor, 1, { materials = { cloth = true } }) == 2, "All body meshes, never face")
assert(meshes.first(custom) == first)
actor.parts = nil
local matches = same_meshes(actor, 1, { materials = { cloth = true, trim = false } })
assert(#matches == 2, "Renamed PFB fallback retains equal best material matches")
local simple = node("Pl000_00", { node("ch00_000_0002", nil, mesh()), body })
assert(meshes.part(simple, 1) == body and old_meshes.part(simple, 1) == body)
local slots = { [0] = 3, [1] = 2, [2] = 1, [3] = 5, [4] = 4, [5] = 6 }
for index, suffix in pairs(slots) do
    local part = node("ch02_001_000" .. suffix, nil, mesh())
    local parent = node("Pl000_00", { part })
    assert(meshes.part(parent, index) == part and old_meshes.part(parent, index) == part)
end
local cached = meshes.all(actor)
custom.mesh = mesh({ "new_material" })
assert(meshes.all(actor) == cached)
meshes.clear()
assert(meshes.all(actor)[1] == custom.mesh, "Scene reset must release cached mesh list")
now = now + 1
same_meshes(actor, 1, { materials = { new_material = true } })
print("PASS: legacy getParts/renamed PFB discovery, all slot suffixes, face exclusion and mesh cache reset")

-- 使用同一批输入比较真实旧应用函数与新适配器产生的所有写入。
local Materials = module("Materials")
local function run_materials(legacy, kind, settings)
    local writes, visibility_reads = {}, 0
    local function render_mesh()
        local value = { enabled = false, values = { true, false, false }, names = { "cloth", "trim", "cloth" } }
        function value:call(method, index, enabled)
            if method == "get_MaterialNum" then return #self.names end
            if method == "getMaterialName" then return self.names[index + 1] end
            if method == "get_Enabled" then return self.enabled end
            if method == "getMaterialsEnable" then return self.values[index + 1] end
            if method == "set_Enabled" then self.enabled = index; writes[#writes + 1] = { method, index }; return end
            if method == "setMaterialsEnable" then
                self.values[index + 1] = enabled; writes[#writes + 1] = { method, index, enabled }; return
            end
            error(method)
        end
        return value
    end
    local m1, m2 = render_mesh(), render_mesh()
    local hunter = { get_type_definition = function() return { get_full_name = function() return settings.type or "app.HunterCharacter" end } end }
    function hunter:call(method)
        visibility_reads = visibility_reads + 1
        if settings.fail then error("destroyed visibility") end
        if method == "get_IsDrawOff" then return settings.off end
        if method == "get_IsInAllTent" then return settings.tent end
        error(method)
    end
    local objects = { node("weapon", nil, m1), node("shield", nil, m2) }
    local lookup = { part_meshes = function(_, index) return index == 0 and { m1, m2 } or {} end,
        first = function(object) return object.mesh end }
    local operable = function(_, name) return name ~= "trim" end
    local hidden = function(_, name) return name == "cloth" end
    local preset = { ["0"] = { mesh_enabled = true, materials = { cloth = true, trim = true } },
        ["1"] = { mesh_enabled = false, materials = { cloth = false } } }
    local apply
    if legacy then
        local context = setmetatable({ sdk = sdk_mock, type_mesh = mesh_type, safe_get_game_object = game_object,
            get_character_part_meshes = lookup.part_meshes, get_mesh_component_recursive = lookup.first,
            is_material_in_current_context = operable, is_globally_hidden = hidden,
        }, { __index = _G })
        local methods = dofile("tests/fixtures/legacy/wilds_materials.lua")(context)
        apply = function()
            if kind == "armor" then methods.armor(hunter, preset, settings.ignore, true)
            else methods.weapon(hunter, objects, preset, settings.ignore, true) end
        end
    else
        local methods = Materials.new(lookup, game_object)
        apply = function()
            if kind == "armor" then methods.armor(hunter, preset, not settings.ignore and operable, not settings.ignore and hidden)
            else methods.weapon(hunter, objects, preset, not settings.ignore and operable) end
        end
    end
    apply(); apply()
    return { writes = writes, visibility_reads = visibility_reads,
        first = { enabled = m1.enabled, values = m1.values }, second = { enabled = m2.enabled, values = m2.values } }
end
for _, kind in ipairs({ "armor", "weapon" }) do
    for _, settings in ipairs({ { off = false }, { off = true, tent = true }, { off = true, tent = false },
        { fail = true }, { type = "via.Transform" }, { off = false, ignore = true } }) do
        S.equal(run_materials(false, kind, settings), run_materials(true, kind, settings), kind)
    end
end
print("PASS: legacy armor/weapon writes, native hiding/tent/error recovery, duplicate material names and UI filters")
