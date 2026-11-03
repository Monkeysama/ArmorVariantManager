game = {wilds=true, prefix="ArmorVariantManager_Core.Games.Wilds."}
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Session = require("ArmorVariantManager_Core.Config.Session")
local Store = require("ArmorVariantManager_Core.Config.Store")
local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local source = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")

for _, game in ipairs({ "Wilds", "Rise" }) do
    local schema = require("ArmorVariantManager_Core.Games." .. game .. ".Config")
    local disk, reads, writes, fail = {}, 0, {}, false
    local io_store = {
        config_path = Store.config_path, backup_path = Store.backup_path,
        load = function(path) reads = reads + 1; return S.copy(disk[path]) end,
        save = function(path, data)
            if fail then return false, "disk full" end
            writes[#writes + 1] = path
            disk[path] = S.copy(data)
            return true
        end
    }
    local prepared = 0
    local session = Session.new(schema, function() prepared = prepared + 1 end, io_store)
    local main, backup = Store.config_path("armor"), Store.backup_path("armor")
    local author = { presets = { Author = {} }, extension = { enabled = false } }
    local player = { presets = { Mine = { ["1"] = { materials = { Body = false } } } }, default_preset = "Mine", custom = 12 }
    disk[main], disk[backup] = S.copy(author), S.copy(player)
    local loaded = session.load("armor")
    S.equal(loaded, Normalize.apply(S.copy(author), schema))
    assert(prepared == 1 and session.pending("armor"))
    local before = reads
    assert(session.load("armor") == loaded and reads == before)
    assert(session.save("armor", loaded))
    S.equal(disk[backup], player, "Autosave must not erase unresolved player backup")
    assert(#writes == 1 and writes[1] == main and session.pending("armor"))

    fail = true
    local restored,reason=session.restore("armor")
    assert(not restored and reason=="disk full" and session.pending("armor"))
    assert(session.cache.armor == loaded and session.handled.armor == nil)
    assert(not session.save("armor", loaded))
    assert(#writes == 1)
    fail = false

    -- 真正入口恢复函数还负责清除旧选择、重新应用默认值和刷新两套 UI 数据。
    local updated, defaults, cleared = 0, 0, 0
    local env = setmetatable({
        config_session = session, active_overrides = { armor = { old = true } },
        active_group_presets = { armor = { [""] = "Author" } },
        load_config_data = session.load,
        update_group_names_list = function() updated = updated + 1 end,
        update_preset_names_list = function() updated = updated + 1 end,
        apply_all_defaults = function(id) assert(id == "armor"); defaults = defaults + 1 end,
        TransformManager = { clear_last_state_cache = function() cleared = cleared + 1 end }
    }, { __index = _G })
    local restore_source = S.section(source, "local function restore_config_from_backup", "-- 辅助函数：捕获当前状态为新预设")
    local restore = assert(load(restore_source .. "\nreturn restore_config_from_backup", "restore", "t", env))()
    fail = true
    restored,reason=restore("armor")
    assert(not restored and reason=="disk full" and env.active_overrides.armor.old and updated == 0)
    fail = false
    assert(restore("armor"))
    S.equal(disk[main], player, "Restore writes original backup, not normalized defaults")
    S.equal(disk[backup], player)
    S.equal(env.current_config, Normalize.apply(S.copy(player), schema))
    assert(env.current_config == session.cache.armor and prepared == 2)
    assert(not env.active_overrides.armor and not env.active_group_presets.armor)
    assert(updated == 2 and defaults == 1 and cleared == 1 and not session.pending("armor"))

    -- 忽略提示只改变会话；下次保存才更新备份，新会话仍重新检查文件。
    disk[main] = S.copy(author)
    assert(session.detect("armor"))
    session.dismiss("armor")
    assert(not session.pending("armor"))
    S.equal(disk[backup], player)
    local next_session = Session.new(schema, nil, io_store)
    next_session.load("armor")
    assert(next_session.pending("armor"))
    assert(session.save("armor", loaded))
    S.equal(disk[main], loaded); S.equal(disk[backup], loaded)
    assert(session.handled.armor == nil and session.restored.armor == nil)

    disk[Store.backup_path("missing")] = S.copy(player)
    assert(session.load("missing") == nil and session.pending("missing"))
    before = reads
    assert(session.load("missing") == nil and reads == before)
    assert(session.restore("missing"))
    S.equal(session.load("missing"), Normalize.apply(S.copy(player), schema))
    assert(not session.pending("missing"))
    restored,reason=session.restore("no_backup")
    assert(not restored and reason=="没有可用的备份")
    restored,reason=session.restore(nil)
    assert(not restored and reason=="装备不可用")
    assert(session.load(nil) == nil and session.save(nil, loaded) == nil)
end
print("PASS: dual-game sessions, unresolved backup protection, restore failure/success, actual entry side effects and dismiss/restart")
