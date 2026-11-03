game = {wilds=true, prefix="ArmorVariantManager_Core.Games.Wilds."}
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Groups = require("ArmorVariantManager_Core.Presets.Groups")
local Height = require("ArmorVariantManager_Core.GroundClippingFix")

local function environment(config)
    local env = setmetatable({ current_config = S.copy(config), current_group_name = "",
        active_overrides = {}, pending_material_selections = {}, deep_copy_table = S.copy,
        GroundClippingFix = Height, calls = {}, is_selection_mode = true, selected_group_index = 2 }, { __index = _G })
    for _, name in ipairs({ "bump_overrides_version", "update_group_names_list", "update_preset_names_list", "save_current_config_to_file" }) do
        env[name] = function(arg) env.calls[#env.calls + 1] = { name, arg } end
    end
    return env
end

local config = { presets = { Base = { ["1"] = { mesh_enabled = true, materials = { Cape = true, Skin = true, Boots = false } } } },
    groups = { Shoes = { mask = { ["1"] = { Boots = true } }, presets = {} } }, group_order = { "Shoes" }, unknown = { keep = true } }
local preset = { ["1"] = { mesh_enabled = false, materials = { Cape = false, Skin = true, Extra = true } },
    ["2"] = { materials = { Hair = true } } }
local base = { ["1"] = { mesh_enabled = true, materials = { Cape = true, Skin = false }, extension = "keep" } }
local legacy_factories = {}
for _, game in ipairs({ "Wilds", "Rise" }) do
    local legacy = dofile("tests/fixtures/legacy/" .. game:lower() .. "_presets.lua")
    legacy_factories[game] = legacy
    local Presets = require("ArmorVariantManager_Core.Games." .. game .. ".Presets")
    local old_env = environment(config)
    local old = legacy(old_env)
    local added = S.copy(preset)
    if game == "Wilds" then added.ground_clipping_fix = { enabled = true, height_cm = 0 } end
    local untouched = S.copy(added)
    local result = Presets.merge(base, added)
    S.equal(result, old.merge_overrides(base, added), game .. " composed override")
    S.equal(Presets.merge(base, nil), old.merge_overrides(base, nil))
    result["1"].materials.Skin = true
    assert(base["1"].materials.Skin == false, "Composed results must not alias the base")
    local target = S.copy(base)
    old_env.active_overrides.armor = S.copy(base)
    old.merge_preset_into_overrides("armor", added)
    Presets.merge_into(target, added)
    S.equal(target, old_env.active_overrides.armor, game .. " manual override")
    target = S.copy(base)
    old_env.active_overrides.armor = S.copy(base)
    old.merge_global_preset_into_overrides("armor", added)
    Presets.merge_global_into(target, added)
    S.equal(target, old_env.active_overrides.armor, game .. " global override")
    assert(target["1"].mesh_enabled == true and target["1"].materials.Cape == false and target["1"].materials.Skin == false)
    assert(target["1"].materials.Extra == (game == "Wilds" and true or nil))
    S.equal(added, untouched, "Config preset remains unchanged")
    if game == "Wilds" then
        local height_base = { ground_clipping_fix = { enabled = true, height_cm = 20 } }
        for _, enabled in ipairs({ true, false }) do
            local next_height = { ground_clipping_fix = { enabled = enabled, height_cm = 0 } }
            S.equal(Presets.merge(height_base, next_height), old.merge_overrides(height_base, next_height))
        end
    end

    -- 取消勾选的 false 在两分支均可由旧 UI 产生，按各自旧行为保留。
    for _, mask in ipairs({ {}, { ["1"] = {} }, { ["1"] = { Cape = false } }, { ["1"] = { Cape = true, Skin = false } } }) do
        for _, global in ipairs({ false, true }) do
            old_env = environment(config)
            old_env.pending_material_selections = S.copy(mask)
            old = legacy(old_env)
            local current = S.copy(config)
            local expected = old.create_new_group("Overlay", "armor", global)
            assert(Groups.create(current, "Overlay", mask, global, game == "Wilds") == expected)
            S.equal(current, old_env.current_config, game .. " group creation")
            for _, group in ipairs({ "", "Shoes", "Overlay" }) do
                old_env.current_group_name = group
                for _, material in ipairs({ "Cape", "Skin", "Boots", "Unknown" }) do
                    assert(Groups.owner(current, 1, material) == old.get_material_group_owner(1, material))
                    assert(Groups.contains(current, group, 1, material) == old.is_material_in_current_context(1, material))
                end
            end
            assert(Groups.delete(current, "Overlay") == old.delete_group("Overlay", "armor"))
            S.equal(current, old_env.current_config, game .. " group deletion")
        end
    end
end

-- 实际荒野入口继续负责保存、UI 选择和活动表；纯模块不接管这些副作用。
local file = assert(io.open("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua", "r"))
local source = file:read("a"); file:close()
local env, old_env = environment(config), environment(config)
env.PresetGroups = Groups
env.deep_copy_table = S.copy
env.TransformManager = {}
env.GamePresets = require("ArmorVariantManager_Core.Games.Wilds.Presets")
local old = legacy_factories.Wilds(old_env)
local current = {}
for _, name in ipairs({ "create_new_group", "delete_group" }) do
    local first = assert(source:find("local function " .. name .. "(", 1, true))
    local last = assert(source:find("\nend", first, true)) + 3
    current[name] = assert(load(source:sub(first, last) .. "\nreturn " .. name, name, "t", env))()
end
env.pending_material_selections, old_env.pending_material_selections = { ["1"] = { Cape = true } }, { ["1"] = { Cape = true } }
for _, args in ipairs({ { "", "armor" }, { "Overlay", false }, { "Overlay", "armor" }, { "Overlay", "armor" } }) do
    assert(current.create_new_group(table.unpack(args)) == old.create_new_group(table.unpack(args)))
end
env.current_group_name, old_env.current_group_name = "Overlay", "Overlay"
assert(current.delete_group("Overlay", "armor") == old.delete_group("Overlay", "armor"))
for _, key in ipairs({ "current_config", "active_overrides", "current_group_name", "pending_material_selections", "is_selection_mode", "selected_group_index" }) do
    S.equal(env[key], old_env[key], "Entry " .. key)
end
S.equal(Groups.global_names({ groups = { Z = { is_global = true, mask = { ["1"] = { Cape = true } } },
    A = { is_global = true, mask = { ["1"] = { Cape = true } } } } }, 1, "Cape"), { "A", "Z" })
print("PASS: both games' legacy preset composition, global priority, height, group ownership/create/delete and live entry side effects")
