package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Editor = require("ArmorVariantManager_Core.Presets.Editor")
local legacy = dofile("tests/fixtures/legacy/preset_edits.lua")
local initial = {
    presets = { A = { ["1"] = { materials = { Body = false } } }, B = {} },
    default_preset = "A", preset_order = { "A", "B" },
    extension = { enabled = false }, group_order = { "Normal", "Global" },
    groups = {
        Normal = { presets = { A = {}, B = {} }, default_preset = "A", preset_order = { "A", "B" }, mask = { ["1"] = { Body = true } }, custom = 7 },
        Global = { presets = { A = { _empty = true }, B = {} }, default_preset = "A", preset_order = { "A", "B" }, is_global = true }
    }
}

for _, game in ipairs({ "Wilds", "Rise" }) do
    local schema = require("ArmorVariantManager_Core.Games." .. game .. ".Config")
    for _, group in ipairs({ "", "Normal", "Global" }) do
        local config = require("ArmorVariantManager_Core.Config.Normalize").apply(S.copy(initial), schema)
        local baseline = S.copy(config)
        local disk, fail, calls, preserve = nil, false, 0, nil
        local function persist(keep)
            calls, preserve = calls + 1, keep
            if fail then return false end
            disk = S.copy(config)
            return true
        end
        local target = Editor.target(config, group)
        local replacement = { ["1"] = { materials = { Body = true } }, _empty = false }
        assert(Editor.write(config, group, "A", replacement, persist) and not preserve)
        S.equal(target.preset_order, { "A", "B" })
        assert(target.presets.A == replacement)
        assert(Editor.write(config, group, "New", {}, persist))
        S.equal(target.preset_order, { "A", "B", "New" })
        assert(Editor.set_default(config, group, "New", persist) and preserve)
        local saved, order, preset = S.copy(config), target.preset_order, target.presets.A
        fail = true
        assert(not Editor.write(config, group, "A", {}, persist))
        assert(not Editor.write(config, group, "Failed", {}, persist))
        assert(not Editor.delete(config, group, "New", persist))
        assert(not Editor.set_default(config, group, "A", persist))
        assert(not Editor.reorder(config, group, { "New", "B", "A" }, persist))
        assert(not Editor.reorder_groups(config, { "Global", "Normal" }, persist))
        S.equal(config, saved, game .. " failed edits must restore full config")
        S.equal(disk, saved)
        assert(target.preset_order == order and target.presets.A == preset)
        fail = false

        -- 旧应用与新编辑层的成功删除/排序生成完全相同的 JSON。
        local old_env = setmetatable({ current_config = S.copy(config), current_group_name = group,
            get_body_id = function() return "armor" end,
            update_group_names_list = function() end, update_preset_names_list = function() end,
            save_current_config_to_file = function() return true end
        }, { __index = _G })
        local old = legacy(old_env)
        assert(old.delete_preset("New") and Editor.delete(config, group, "New", persist))
        old.reorder_presets({ "B", "A" }); assert(Editor.reorder(config, group, { "B", "A" }, persist))
        old.reorder_groups({ { name = "Global" }, { name = "Normal" } })
        assert(Editor.reorder_groups(config, { "Global", "Normal" }, persist))
        S.equal(config, old_env.current_config, game .. " legacy editing results")
        S.equal(config.extension, baseline.extension)
        assert(config.groups.Normal.custom == 7)
        local before = calls
        assert(not Editor.delete(config, group, "Missing", persist))
        assert(not Editor.set_default(config, group, "Missing", persist))
        assert(not Editor.reorder(config, "Missing", {}, persist))
        assert(calls == before)
    end
end

-- 旧保存入口允许创建缺少的列表；失败不能留下新组、空排序或空 presets。
local missing = {}
assert(not Editor.write(missing, "Group", "A", {}, function() return false end))
S.equal(missing, {})
assert(not Editor.write(missing, "", "A", {}, function() return false end))
S.equal(missing, {})
assert(Editor.write(missing, "Group", "A", { _empty = true }, function() return true end))
S.equal(missing, { groups = { Group = { presets = { A = { _empty = true } }, mask = {}, preset_order = { "A" } } } })

-- 正式应用操作：失败返回 false，成功只保存一次并刷新列表。
local config, writes, refreshed, fail = S.copy(initial), 0, 0, false
local env = setmetatable({ current_config = config, current_group_name = "Normal", PresetEditor = Editor,
    get_body_id = function() return "armor" end,
    save_current_config_to_file = function(id, keep)
        assert(id == "armor" and keep == false); writes = writes + 1; return not fail
    end,
    update_preset_names_list = function() refreshed = refreshed + 1 end,
    update_group_names_list = function() refreshed = refreshed + 1 end
}, { __index = _G })
local app=dofile("tests/app_fixture.lua").new("Wilds")
app.workspace.config, app.workspace.state.group=config,"Normal"
app.workspace.update_preset_names_list=env.update_preset_names_list
app.workspace.update_group_names_list=env.update_group_names_list
app.backend.save=function(id, data, keep) return env.save_current_config_to_file(id, keep) end
fail = true
assert(not app.delete_preset("A","armor") and config.groups.Normal.presets.A)
fail = false
assert(app.delete_preset("A","armor"))
assert(app.reorder_presets({ "B" },"armor"))
assert(app.reorder_groups({ "Global", "Normal" },"armor"))
S.equal(config.group_order, { "Global", "Normal" })
assert(writes == 4 and refreshed == 4)
app.workspace.config = nil
assert(not app.delete_preset("B","armor"))
assert(not app.reorder_presets({ "B" },"armor"))
assert(not app.reorder_groups({ "Normal" },"armor"))
assert(writes == 4 and refreshed == 4)
print("PASS: shared preset writes/defaults/delete/order, legacy JSON equality, failed-save rollback and application operations")
