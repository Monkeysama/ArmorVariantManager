package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
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
        assert(type(data.presets)=="table" and type(data.groups)=="table")
        assert(type(data.preset_order)=="table" and type(data.group_order)=="table")
        if input.presets then S.equal(data.presets,input.presets) end
        if input.default_preset then assert(data.default_preset==input.default_preset) end
        if input.group_order then S.equal(data.group_order,input.group_order) end
        if input.parallel_settings and input.parallel_settings.custom then
            S.equal(data.parallel_settings.custom,input.parallel_settings.custom)
            assert(data.parallel_settings.weapon.priority==17 and data.parallel_settings.weapon.extra=="keep")
        end
        if input.weapon_transform_rules then S.equal(data.weapon_transform_rules,input.weapon_transform_rules) end
        if input.transform_type=="hp" then
            if game=="Wilds" then
                S.equal(data.transform_rules,{{threshold=50,targets={}}})
                S.equal(data.damage_transform_rules,{{duration=7,targets={{preset="Hit"}}}})
            else S.equal(data.transform_rules,input.transform_rules) end
        end
        if index==#cases then
            assert(data.parallel_settings.hp.priority==1 and data.parallel_settings.weapon.priority==2)
            assert(data.parallel_settings.spirit.priority==(game=="Wilds" and 4 or 3))
            if game=="Wilds" then assert(data.parallel_settings.damage.priority==3) end
        end
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

-- 草稿不添加加载期字段；装备切换必须清空旧配置并只缓存成功加载的数据。
local Fixture = dofile("tests/app_fixture.lua")
for _, game in ipairs({"Wilds","Rise"}) do
    local schema = require("ArmorVariantManager_Core.Games." .. game .. ".Config")
    local first,second = schema.new(),schema.new()
    local initial = S.copy(second)
    assert(first.preset_order==nil and first.group_order==nil and first.damage_transform_rules==nil)
    first.weapon_transform_rules[1].targets[1]={preset="Private"}
    first.parallel_settings.weapon.priority=99
    first.presets.private,first.groups.private={},{}
    S.equal(second,initial,game.." independent drafts")
    for _,input in ipairs({"missing","present","nil"}) do
        local app=Fixture.new(game)
        local ws,trace=app.workspace,{}
        local previous={stale=true}
        local data=input=="present" and {presets={A={}},unknown={keep=1}} or nil
        ws.config=previous
        app.backend.load=function(id) trace[#trace+1]="load:"..id; return data end
        ws.update_group_names_list=function() trace[#trace+1]="groups" end
        ws.update_preset_names_list=function() trace[#trace+1]="presets" end
        ws.apply_all_defaults=function(id) trace[#trace+1]="defaults:"..id end
        local ok=ws.load_body_config(input~="nil" and "armor" or nil)
        assert(ok==(input=="present"))
        if input=="nil" then
            assert(ws.config==previous); S.equal(trace,{})
        elseif data then
            assert(ws.config==data and app.session.cache.armor==data)
            S.equal(trace,{"load:armor","groups","presets","defaults:armor"})
        else
            S.equal(ws.config,initial); assert(app.session.cache.armor==nil)
            S.equal(trace,{"load:armor","groups","presets"})
        end
    end
    local saved=current[game](schema.new())
    S.equal(current[game](S.copy(saved)),saved,game.." first save/reload")
end
print("PASS: independent drafts, equipment load/reset/cache and first save/reload")
