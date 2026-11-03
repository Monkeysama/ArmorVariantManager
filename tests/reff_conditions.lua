package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Conditions = require("ArmorVariantManager_Core.UI.Reff.Conditions")
local failures, passed = {}, 0

local function test(name, run)
    local ok, reason = pcall(run)
    if ok then passed = passed + 1 else failures[#failures + 1] = name .. ": " .. tostring(reason) end
end

local function T(key)
    return key == "damage_countdown" and "Countdown: %.1f s" or key
end

local function serializable(value, seen)
    local kind = type(value)
    if kind == "boolean" or kind == "string" then return end
    if kind == "number" then assert(value == value and math.abs(value) < math.huge); return end
    assert(kind == "table" and getmetatable(value) == nil, "not a plain value")
    seen = seen or {}; assert(not seen[value], "cycle"); seen[value] = true
    local strings, numbers, last = 0, 0, 0
    for key, item in pairs(value) do
        if type(key) == "string" then strings = strings + 1 else
            assert(type(key) == "number" and key % 1 == 0 and key > 0, "invalid array key")
            numbers = numbers + 1; last = math.max(last, key)
        end
        serializable(item, seen)
    end
    assert(strings == 0 or numbers == 0, "mixed array/object")
    assert(numbers == last, "sparse array")
    seen[value] = nil
end

local function fixture(game)
    local prefix = "ArmorVariantManager_Core.Games." .. game .. "."
    local model = require(prefix .. "ConditionModel")
    local config = require(prefix .. "Config").new()
    config.presets = { Base = {}, Other = {} }; config.preset_order = { "Other", "Base" }
    config.groups = { Global = { is_global = true, presets = { Hide = {} } },
        Local = { is_global = false, presets = { LocalBase = {} } } }
    config.group_order = { "Local" }
    config.unknown = { plugin = "retained" }
    config.parallel_settings.unknown = { enabled = true, priority = -5, extra = "retained" }
    local f = { model = model, config = config, saved = 0, refreshed = 0, save_ok = true }
    f.context = { id = "armor", config = config, character = {} }
    f.deps = { model = model, translate = T,
        save = function(context)
            assert(context == f.context and context.config == f.config)
            f.saved = f.saved + 1
            if f.throw_save then error("disk disconnected") end
            return f.save_ok, "disk unavailable"
        end,
        refresh = function(context) assert(context == f.context); f.refreshed = f.refreshed + 1 end,
        state = function(context, id)
            assert(context == f.context)
            return "state:" .. id, id == "weapon" and "module unavailable" or nil
        end }
    f.api = Conditions.new(f.deps)
    function f.act(op, fields)
        local request = fields or {}; request.kind = "condition"; request.op = op
        local ok, reason = f.api.action(request, f.context)
        assert(ok, tostring(reason))
    end
    return f
end

local function row_for(snapshot, id)
    for _, row in ipairs(snapshot.definitions) do if row.id == id then return row end end
    error("missing condition: " .. id)
end

for _, game in ipairs({ "Wilds", "Rise" }) do
    test(game .. " all condition, field and state labels exist in both actual languages", function()
        local f = fixture(game)
        local localization = require(game == "Wilds" and "ArmorVariantManager_Core.Localization"
            or "ArmorVariantManager_Core.Games.Rise.Localization")
        for _, language in ipairs({ "en", "zh" }) do
            local function translated(key)
                assert(type(localization[language][key]) == "string" and localization[language][key] ~= "",
                    game .. " " .. language .. " missing label: " .. key)
                return localization[language][key]
            end
            translated("main_list")
            for _, definition in ipairs(f.model.definitions) do
                translated("condition_" .. definition.id)
                for _, field in ipairs(definition.fields) do
                    translated(field.label)
                    for _, option in ipairs(field.options or {}) do translated(option.label) end
                end
                for _, state in ipairs(definition.states or {}) do translated(state.label) end
            end
            if game == "Wilds" then translated("damage_countdown"); translated("damage_idle") end
        end
    end)

    test(game .. " detached read-only snapshot covers every original condition", function()
        local f = fixture(game)
        local before = S.copy(f.config)
        local snapshot = f.api.snapshot(f.context)
        serializable(snapshot); S.equal(f.config, before)
        assert(#snapshot.definitions == (game == "Wilds" and 12 or 10))
        assert(snapshot.canEnable == (game == "Rise") and snapshot.enabled == (game == "Wilds"))
        assert(snapshot.parallel == false and snapshot.selected == f.model.default_selected)
        S.equal(snapshot.targets, {
            { name = "", label = "main_list", global = false, presets = { "Other", "Base" } },
            { name = "Local", label = "Local", global = false, presets = { "LocalBase" } },
            { name = "Global", label = "Global", global = true, presets = { "Hide" } },
        })
        for priority, definition in ipairs(f.model.definitions) do
            local row = row_for(snapshot, definition.id)
            assert(row.priority == priority and row.enabled == (definition.id == f.model.default_selected))
            assert(row.stateLabel == "state:" .. definition.id)
            assert(row.canAdd == (definition.variable == true) and row.canRemove == row.canAdd)
            if definition.states then
                assert(#row.rules == #definition.states)
                for index, state in ipairs(definition.states) do
                    assert(row.rules[index][definition.state_key] == state.value)
                    assert(row.rules[index].label == T(state.label))
                end
            end
        end
        assert(row_for(snapshot, "weapon").warning == "module unavailable")
        snapshot.targets[1].presets[1] = "changed"
        snapshot.definitions[1].enabled = false
        S.equal(f.config, before)
        assert(f.saved == 0 and f.refreshed == 0)
    end)

    test(game .. " switches and priorities preserve old settings and unknown fields", function()
        local f = fixture(game)
        local settings = f.config.parallel_settings
        local weapon = settings.weapon; weapon.extra = { retained = true }
        f.act("parallel", { value = true })
        f.act("select", { value = "dual_blades" })
        f.act("setting", { condition = "weapon", field = "enabled", value = false })
        f.act("setting", { condition = "weapon", field = "priority", value = -12.5 })
        assert(f.config.is_parallel == true and f.config.transform_type == "dual_blades")
        assert(f.config.parallel_settings == settings and settings.weapon == weapon)
        assert(not weapon.enabled and weapon.priority == -12.5 and weapon.extra.retained)
        assert(settings.unknown.priority == -5 and f.config.unknown.plugin == "retained")
        if game == "Rise" then f.act("enabled", { value = true }); assert(f.config.enable_transform) end
        local saved = f.saved
        f.act("select", { value = "dual_blades" })
        assert(f.saved == saved and f.refreshed == saved)
    end)

    test(game .. " all fixed rules edit targets without changing states or order", function()
        local f = fixture(game)
        for _, definition in ipairs(f.model.definitions) do
            if definition.states then
                local rules = f.config[definition.field]
                for index, rule in ipairs(rules) do
                    rule.extra = "retained"
                    f.act("target_add", { condition = definition.id, rule = index })
                    local target = rule.targets[1]; target.extra = { retained = true }
                    assert(target.group == "")
                    assert(target.preset == "" or game == "Rise" and f.config.presets[target.preset])
                    f.act("target_set", { condition = definition.id, rule = index, target = 1, field = "preset", value = "Base" })
                    f.act("target_set", { condition = definition.id, rule = index, target = 1, field = "group", value = "Global" })
                    assert(target.preset == "" and target.extra.retained)
                    f.act("target_set", { condition = definition.id, rule = index, target = 1, field = "preset", value = "Hide" })
                    assert(rule.targets[1] == target and target.preset == "Hide")
                    assert(rule[definition.state_key] == definition.states[index].value and rule.extra == "retained")
                    f.act("target_delete", { condition = definition.id, rule = index, target = 1 })
                    assert(#rule.targets == 0)
                end
                assert(f.config[definition.field] == rules)
            end
        end
    end)

    test(game .. " HP nodes keep game-specific limits and add/delete behavior", function()
        local f = fixture(game)
        local id = game == "Wilds" and "hp" or "monster_hp"
        local definition = assert((function()
            for _, item in ipairs(f.model.definitions) do if item.id == id then return item end end
        end)())
        local rules = f.config[definition.field]
        f.act("rule_add", { condition = id })
        local rule = rules[1]; assert(rule.threshold == 50 and #rule.targets == 0)
        f.act("rule_set", { condition = id, rule = 1, field = "threshold", value = 0 })
        assert(rule.threshold == (game == "Wilds" and 1 or 0))
        f.act("rule_set", { condition = id, rule = 1, field = "threshold", value = 150 })
        assert(rule.threshold == 100)
        f.act("rule_set", { condition = id, rule = 1, field = "threshold", value = 37.5 })
        f.act("rule_add", { condition = id })
        f.act("rule_delete", { condition = id, rule = 2 })
        assert(#rules == 1 and rules[1] == rule and rule.threshold == 37.5)
    end)

    test(game .. " stale references remain visible but invalid edits do not save", function()
        local f = fixture(game)
        f.config.weapon_transform_rules[1].targets = { { group = "Deleted", preset = "Missing", unknown = true } }
        local snapshot = f.api.snapshot(f.context)
        S.equal(row_for(snapshot, "weapon").rules[1].targets, { { index = 1, group = "Deleted", preset = "Missing" } })
        local before = S.copy(f.config)
        local requests = {
            { op = "select", value = "unknown" }, { op = "parallel", value = "true" },
            { op = "setting", condition = "weapon", field = "priority", value = "one" },
            { op = "rule_add", condition = "weapon" }, { op = "rule_delete", condition = "weapon", rule = 1 },
            { op = "rule_set", condition = "weapon", rule = 1, field = "state", value = "drawn" },
            { op = "target_set", condition = "weapon", rule = 1, target = 1, field = "preset", value = "Missing" },
            { op = "target_set", condition = "weapon", rule = 1, target = 1, field = "group", value = "Deleted" },
            { op = "target_delete", condition = "weapon", rule = 1, target = 2 },
            { op = "target_add", condition = "weapon", rule = 1.5 },
            { op = "chain_add", condition = "weapon", rule = 1 },
            { op = "rule_set", condition = game == "Wilds" and "hp" or "monster_hp", rule = 1, field = "threshold", value = 0/0 },
            { op = "not-an-operation", condition = "weapon", rule = 1 },
        }
        if game == "Wilds" then requests[#requests + 1] = { op = "enabled", value = false } end
        for _, request in ipairs(requests) do
            local ok, reason = f.api.action(request, f.context)
            assert(not ok and type(reason) == "string", request.op .. " should be rejected")
            S.equal(f.config, before)
        end
        assert(f.saved == 0 and f.refreshed == 0)
    end)

    test(game .. " failed saves restore fields, lists and original table identities", function()
        local f = fixture(game)
        local hp = game == "Wilds" and "hp" or "monster_hp"
        f.act("rule_add", { condition = hp })
        f.act("target_add", { condition = "weapon", rule = 1 })
        f.act("target_set", { condition = "weapon", rule = 1, target = 1, field = "preset", value = "Base" })
        local rule = f.config.weapon_transform_rules[1]
        local targets, target, settings = rule.targets, rule.targets[1], f.config.parallel_settings
        target.extra = { retained = true }
        local before, refreshed = S.copy(f.config), f.refreshed
        f.save_ok = false
        local requests = {
            { op = "parallel", value = true }, { op = "select", value = "dual_blades" },
            { op = "setting", condition = "weapon", field = "enabled", value = not settings.weapon.enabled },
            { op = "setting", condition = "weapon", field = "priority", value = 100 },
            { op = "rule_add", condition = hp }, { op = "rule_delete", condition = hp, rule = 1 },
            { op = "rule_set", condition = hp, rule = 1, field = "threshold", value = 12 },
            { op = "target_add", condition = "weapon", rule = 1 },
            { op = "target_delete", condition = "weapon", rule = 1, target = 1 },
            { op = "target_set", condition = "weapon", rule = 1, target = 1, field = "group", value = "Local" },
            { op = "target_set", condition = "weapon", rule = 1, target = 1, field = "preset", value = "Other" },
        }
        if game == "Rise" then requests[#requests + 1] = { op = "enabled", value = true } end
        for _, request in ipairs(requests) do
            local ok, reason = f.api.action(request, f.context)
            assert(not ok and reason == "disk unavailable", request.op .. ": " .. tostring(reason))
            S.equal(f.config, before)
            assert(f.config.parallel_settings == settings and f.config.weapon_transform_rules[1] == rule)
            assert(rule.targets == targets and targets[1] == target and f.refreshed == refreshed)
        end
        f.throw_save = true
        local ok, reason = f.api.action({ op = "parallel", value = true }, f.context)
        assert(not ok and reason:find("disk disconnected", 1, true))
        S.equal(f.config, before)
    end)

    test(game .. " absent optional tables are read-only until an edit and rolled back on failure", function()
        local f = fixture(game)
        f.config.weapon_transform_rules = nil; f.config.parallel_settings = nil
        local before = S.copy(f.config)
        assert(#row_for(f.api.snapshot(f.context), "weapon").rules == 2)
        S.equal(f.config, before)
        f.save_ok = false
        assert(not f.api.action({ op = "target_add", condition = "weapon", rule = 2 }, f.context))
        assert(not f.api.action({ op = "setting", condition = "weapon", field = "priority", value = 20 }, f.context))
        S.equal(f.config, before)
        f.save_ok = true
        f.act("target_add", { condition = "weapon", rule = 2 })
        assert(#f.config.weapon_transform_rules == 2 and #f.config.weapon_transform_rules[2].targets == 1)
        f.act("setting", { condition = "weapon", field = "priority", value = 20 })
        assert(f.config.parallel_settings.weapon.priority == 20)
    end)

    test(game .. " legacy-loaded rule order, target extensions and defaults survive editing", function()
        local f = fixture(game)
        local legacy = dofile("tests/fixtures/legacy/" .. game:lower() .. "_config.lua")
        f.config = legacy({ presets = { Base = {}, Other = {} }, default_preset = "Base",
            weapon_transform_rules = { { state = "drawn", targets = { { group = "", preset = "Base", extra = 9 } }, extra = 7 },
                { state = "sheathed", targets = {} } },
            transform_rules = { { threshold = 80, targets = {} }, { threshold = 20, targets = {} } },
            monster_hp_transform_rules = { { threshold = 70, targets = {} }, { threshold = 0, targets = {} } },
            parallel_settings = { weapon = { enabled = false, priority = "-3", extra = 5 } },
            extension = { unknown = true } })
        f.context.config = f.config
        local before = S.copy(f.config)
        local snapshot = f.api.snapshot(f.context)
        S.equal(f.config, before)
        local weapon = row_for(snapshot, "weapon")
        assert(weapon.rules[1].state == "drawn" and weapon.rules[2].state == "sheathed")
        assert(weapon.priority == -3 and not weapon.enabled)
        local hp = row_for(snapshot, game == "Wilds" and "hp" or "monster_hp")
        assert(hp.rules[1].threshold == (game == "Wilds" and 80 or 70))
        assert(hp.rules[2].threshold == (game == "Wilds" and 20 or 0))
        f.act("target_set", { condition = "weapon", rule = 1, target = 1, field = "preset", value = "Other" })
        before.weapon_transform_rules[1].targets[1].preset = "Other"
        S.equal(f.config, before)
        local saved = S.copy(f.config)
        f.config = legacy(S.copy(saved)); f.context.config = f.config
        S.equal(f.config, saved)
    end)
end

test("Wilds hit modes and chain nodes cover original fields without normalization", function()
    local f = fixture("Wilds")
    local before = S.copy(f.config)
    local row = row_for(f.api.snapshot(f.context), "damage")
    assert(#row.fields == 6 and #row.rules == 1 and row.rules[1].duration == 5)
    assert(row.rules[1].chain_loop_count == 1 and row.rules[1].chain_nodes[1].duration == 1)
    S.equal(f.config, before)
    f.act("rule_set", { condition = "damage", rule = 1, field = "mode", value = 2 })
    local rule = f.config.damage_transform_rules[1]; rule.extra = { retained = true }
    local values = { condition_delay = 0.5, duration = 3.5, loop_inactive_time = 1.5, loop_count = 0, chain_loop_count = 0 }
    for field, value in pairs(values) do
        f.act("rule_set", { condition = "damage", rule = 1, field = field, value = value })
        assert(rule[field] == value)
    end
    f.act("rule_set", { condition = "damage", rule = 1, field = "mode", value = 3 })
    f.act("chain_add", { condition = "damage", rule = 1 })
    local node = rule.chain_nodes[2]; node.extra = "retained"
    f.act("chain_set", { condition = "damage", rule = 1, node = 2, field = "duration", value = 0 })
    f.act("target_add", { condition = "damage", rule = 1, node = 2 })
    f.act("target_set", { condition = "damage", rule = 1, node = 2, target = 1, field = "preset", value = "Base" })
    assert(node.duration == 0 and node.extra == "retained" and rule.extra.retained)
    assert(node.targets[1].preset == "Base")
    local snapshot = row_for(f.api.snapshot(f.context), "damage").rules[1]
    assert(snapshot.mode == 3 and snapshot.chain_loop_count == 0 and snapshot.chain_nodes[2].targets[1].preset == "Base")
    serializable(snapshot)
    f.save_ok = false
    local saved_config, nodes, targets = S.copy(f.config), rule.chain_nodes, node.targets
    for _, request in ipairs({
        { op = "chain_add" }, { op = "chain_delete", node = 1 },
        { op = "chain_set", node = 2, field = "duration", value = 10 },
        { op = "target_add", node = 2 }, { op = "target_delete", node = 2, target = 1 },
    }) do
        request.condition = "damage"; request.rule = 1
        local ok, reason = f.api.action(request, f.context)
        assert(not ok and reason == "disk unavailable")
        S.equal(f.config, saved_config)
        assert(rule.chain_nodes == nodes and nodes[2] == node and node.targets == targets)
    end
    f.save_ok = true
    f.act("target_delete", { condition = "damage", rule = 1, node = 2, target = 1 })
    f.act("chain_delete", { condition = "damage", rule = 1, node = 1 })
    assert(#rule.chain_nodes == 1 and rule.chain_nodes[1] == node)
end)

test("runtime labels preserve false, numeric/string enums and HP tests never save configuration", function()
    local f = fixture("Wilds")
    assert(Conditions.format_state(f.model, "weapon", false, T) == "weapon_sheathed")
    assert(Conditions.format_state(f.model, "greatsword_type", "0", T) == "greatsword_type_0")
    assert(Conditions.format_state(f.model, "hp", 45.25, T) == "45.2%")
    assert(Conditions.format_state(f.model, "damage", 2.5, T) == "Countdown: 2.5 s")
    assert(Conditions.format_state(f.model, "damage", 0, T) == "damage_idle")
    assert(Conditions.format_state(f.model, "hp", nil, T) == nil)
    local rise = fixture("Rise")
    assert(Conditions.format_state(rise.model, "dual_blades", 0, T) == "dual_normal")
    assert(Conditions.format_state(rise.model, "bow", 0, T) == "bow_level_0")
    local hp, hits = nil, 0
    f.deps.test_hp = function(context, value) assert(context == f.context); hp = value; return true end
    f.deps.test_damage = function(context) assert(context == f.context); hits = hits + 1; return true end
    local snapshot = f.api.snapshot(f.context)
    assert(snapshot.canTestHp and snapshot.canTestDamage)
    f.act("test_hp", { value = 125 }); assert(hp == 100)
    f.act("test_hp", { value = -1 }); assert(hp == 0)
    f.act("test_damage"); assert(hits == 1)
    f.deps.test_damage = function() return false, "HP module unavailable" end
    local ok, reason = f.api.action({ op = "test_damage" }, f.context)
    assert(not ok and reason == "HP module unavailable")
    assert(not f.api.action({ op = "test_hp", value = "invalid" }, f.context))
    assert(not rise.api.action({ op = "test_hp", value = 50 }, rise.context))
    assert(f.saved == 0 and f.refreshed == 0)
end)

assert(#failures == 0, table.concat(failures, "\n"))
print("PASS: REFF condition models, old JSON edits and rollback (" .. passed .. " checks)")
