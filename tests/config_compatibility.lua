package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local source = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local helpers = S.section(source, "local parallel_condition_order =", "local current_config =")
local body = S.section(source, "        -- 确保结构完整", "        -- 检测主配置是否被外部还原")
local current_wilds = assert(load(helpers .. "\nreturn function(loaded_data)\n" .. body .. "\nreturn loaded_data end"))()
local legacy = {
    Wilds = dofile("tests/fixtures/legacy/wilds_config.lua"),
    Rise = dofile("tests/fixtures/legacy/rise_config.lua")
}
local current = { Wilds = current_wilds, Rise = legacy.Rise }
local cases = {
    {},
    { presets = { Z = {}, A = {} }, groups = { Boots = { presets = { High = {}, Flat = {} } } } },
    { presets = { Normal = { ["1"] = { mesh_enabled = false, materials = { Cape = false, Skin = true } } } },
      default_preset = "Normal", preset_order = { "Normal" }, group_order = { "Overlay" },
      groups = { Overlay = { is_global = true, presets = { Hide = {} }, author_note = "keep" } },
      enable_transform = true, is_parallel = true,
      parallel_settings = { weapon = { enabled = false, priority = 17, extra = "keep" }, custom = { enabled = true, priority = 33 } },
      unknown = { nested = { 1, false, "中文" } },
      weapon_transform_rules = { { state = "drawn", targets = { { group = "", preset = "Normal", extra = true } }, extension = 9 } } },
    { transform_type = "hp", transform_rules = {
        { threshold = 50, targets = {} }, { trigger_on_damage = true, duration = 7, targets = { { preset = "Hit" } } }
      }, spirit_transform_rules = { { level = 4, targets = {} } },
      longsword_transform_rules = { { level = 0, targets = {} } } },
    { transform_type = "scroll", scroll_transform_rules = { { state = "red" } },
      charge_axe_transform_rules = { { state = 5, targets = {} } },
      monster_hp_transform_rules = { { threshold = 25, targets = {} } } }
}
local old_order = { "hp", "weapon", "spirit", "dual_blades", "switch_axe", "insect_glaive",
    "charge_blade", "greatsword_type", "greatsword_level", "bow_level", "hammer_level" }
local old_settings = {}
for index, key in ipairs(old_order) do old_settings[key] = { enabled = key == "hp", priority = index } end
cases[#cases + 1] = { parallel_settings = old_settings }
for game, normalize in pairs(current) do
    for index, input in ipairs(cases) do
        local data = S.copy(input)
        assert(normalize(data) == data, "Normalize must preserve the loaded table")
        S.equal(data, legacy[game](S.copy(input)), game .. " case " .. index)
        local saved = S.copy(data)
        S.equal(normalize(S.copy(saved)), saved, game .. " save/reload")
        if input.unknown then S.equal(data.unknown, input.unknown, "unknown fields") end
    end
end
local wilds, rise = current.Wilds({}), current.Rise({})
assert(wilds.transform_type == "hp" and rise.transform_type == "weapon")
assert(wilds.spirit_transform_rules[1].level == 1 and wilds.spirit_transform_rules[4].level == 4)
assert(rise.longsword_transform_rules[1].level == 0 and rise.longsword_transform_rules[4].level == 3)
assert(wilds.longsword_transform_rules == nil and rise.spirit_transform_rules == nil)
assert(wilds.enable_transform == nil and rise.enable_transform == false)
assert(wilds.dual_blades_transform_rules[1].state == "normal" and rise.dual_blades_transform_rules[1].state == 0)
local names = { presets = { Z = {}, A = {} } }
assert(#current.Wilds(S.copy(names)).preset_order == 0)
S.equal(current.Rise(S.copy(names)).preset_order, { "A", "Z" })
print("PASS: per-game legacy fields/defaults/order, damage migration, unknown fields and table save/reload")
