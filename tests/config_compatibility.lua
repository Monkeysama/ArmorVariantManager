package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local legacy = {
    Wilds = dofile("tests/fixtures/legacy/wilds_config.lua"),
    Rise = dofile("tests/fixtures/legacy/rise_config.lua")
}
local current = {}
for _, game in ipairs({ "Wilds", "Rise" }) do
    local schema = require("ArmorVariantManager_Core.Games." .. game .. ".Config")
    current[game] = function(data) return Normalize.apply(data, schema) end
end
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
    local first, second = normalize({}), normalize({})
    first.weapon_transform_rules[1].targets[1] = { preset = "OnlyFirst" }
    first.parallel_settings.weapon.priority = 99
    assert(#second.weapon_transform_rules[1].targets == 0 and second.parallel_settings.weapon.priority ~= 99,
        game .. " configurations must not share mutable defaults")
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

-- 新装备草稿不是已加载 JSON：不提前添加旧入口没有保存的字段。
local Fixture = dofile("tests/app_fixture.lua")
for _, game in ipairs({ "Wilds", "Rise" }) do
    local schema = require("ArmorVariantManager_Core.Games." .. game .. ".Config")
    local legacy_factory = dofile("tests/fixtures/legacy/" .. game:lower() .. "_config_draft.lua")
    local first, second = schema.new(), schema.new()
    local initial = legacy_factory(setmetatable({}, { __index = _G }))
    S.equal(first, initial(), game .. " initial draft")
    first.weapon_transform_rules[1].targets[1] = { preset = "Private" }
    first.parallel_settings.weapon.priority = 99
    first.presets.private = {}
    first.groups.private = {}
    S.equal(second, initial(), game .. " independent draft")
    for _, input in ipairs({ "missing", "present", "nil" }) do
        local function run(old)
            local trace = {}
            local data = input == "present" and { presets = { A = {} }, unknown = { keep = 1 } } or nil
            local env = setmetatable({ GameConfig = schema, loaded_configs = {}, current_config = { stale = true } }, { __index = _G })
            env.load_config_data = function(id) trace[#trace + 1] = "load:" .. id; return data end
            env.update_group_names_list = function() trace[#trace + 1] = "groups" end
            env.update_preset_names_list = function() trace[#trace + 1] = "presets" end
            env.apply_all_defaults = function(id) trace[#trace + 1] = "defaults:" .. id end
            local load
            if old then local _; _, load = legacy_factory(env)
            else
                local app=Fixture.new(game)
                local ws=app.workspace
                ws.config=env.current_config
                env.loaded_configs=app.session.cache
                app.backend.load=env.load_config_data
                ws.update_group_names_list=env.update_group_names_list
                ws.update_preset_names_list=env.update_preset_names_list
                ws.apply_all_defaults=env.apply_all_defaults
                load=function(id)
                    local ok=ws.load_body_config(id)
                    env.current_config=ws.config
                    env.loaded_configs=app.session.cache
                    return ok
                end
            end
            local ok = load(input ~= "nil" and "armor" or nil)
            if data then assert(env.current_config == data and env.loaded_configs.armor == data) end
            return { ok = ok, current = env.current_config, cache = env.loaded_configs, trace = trace }
        end
        S.equal(run(false), run(true), game .. " draft load " .. input)
    end
    local saved = current[game](schema.new())
    S.equal(current[game](S.copy(saved)), saved, game .. " first save/reload")
end

print("PASS: both games' initial/reset drafts, independent defaults, missing/loaded/nil equipment and first save/reload")
