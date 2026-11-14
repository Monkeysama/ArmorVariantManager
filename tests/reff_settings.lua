package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Settings = require("ArmorVariantManager_Core.UI.Reff.Settings")
local Global = require("ArmorVariantManager_Core.Config.Global")
local Wilds = require("ArmorVariantManager_Core.Games.Wilds.SettingsModel")
local Rise = require("ArmorVariantManager_Core.Games.Rise.SettingsModel")
local Dissolve = require("ArmorVariantManager_Core.Games.Rise.DissolveTransition")
local Options = require("ArmorVariantManager_Core.Games.Rise.Options")
local count = 0
local function test(name, run)
    local ok, reason = pcall(run)
    assert(ok, name .. ": " .. tostring(reason))
    count = count + 1
end
local function serializable(value)
    if type(value) ~= "table" then
        assert(type(value) == "string" or type(value) == "number" or type(value) == "boolean" or value == nil)
        return
    end
    for key, item in pairs(value) do
        assert(type(key) == "string" or type(key) == "number")
        serializable(item)
    end
end
local function fields(snapshot)
    serializable(snapshot)
    local result = {}
    for _, section in ipairs(snapshot.sections) do
        assert(section.scope == "global" and section.id and section.label)
        for _, field in ipairs(section.fields) do result[field.id] = field end
    end
    return result
end
local function session(game, loaded)
    local state = { writes = 0, result = true }
    local global = Global.new(require("ArmorVariantManager_Core.Games." .. game .. ".Settings"), {
        load = function(path) assert(path == "ArmorVariantManager/GlobalSettings.json"); return loaded end,
        save = function(path, value)
            assert(path == "ArmorVariantManager/GlobalSettings.json")
            state.writes = state.writes + 1
            if state.throws then error("disk exception") end
            if not state.result then return false, "disk full" end
            state.saved = S.copy(value)
            return true
        end,
    })
    global.load()
    return global, state
end
local function new(global, model, on_saved)
    return Settings.new({ global_session = global, model = model, translate = function(key) return key end,
        on_saved = on_saved })
end
local function set(settings, id, value, context)
    return settings.action({ kind = "setting", id = id, value = value, bodyId = "stale equipment" }, context)
end

test("panel scaling remembers each supported theme in either game", function()
    for _, game in ipairs({ { "Rise", Rise }, { "Wilds", Wilds } }) do
        local id = "reff_scale_with_panel"
        local global, disk = session(game[1], { reff_scale_with_panel = false })
        local settings = new(global, game[2].new({ config = global.value }))
        assert(fields(settings.snapshot())[id].value == true)
        global.value.reff_theme = "custom"
        assert(fields(settings.snapshot())[id].value == false and set(settings, id, true))
        global.value.reff_theme = "reff"
        assert(fields(settings.snapshot())[id].value == false)
        for _, theme in ipairs({ "white", "black", "glass" }) do
            global.value.reff_theme = theme
            assert(fields(settings.snapshot())[id].value == true)
        end
        disk.result = false
        assert(not set(settings, id, false) and global.value.reff_panel_scale_by_theme.glass == nil)
        disk.result = true
        assert(set(settings, id, false))
        local reopened = session(game[1], disk.saved)
        assert(Settings.panel_theme(reopened.value.reff_theme) == "glass")
        local restored = new(reopened, game[2].new({ config = reopened.value }))
        reopened.value.reff_theme = "custom"
        assert(fields(restored.snapshot())[id].value == true)
        reopened.value.reff_theme = "white"
        assert(fields(restored.snapshot())[id].value == true)
        reopened.value.reff_theme = "reff"
        assert(fields(restored.snapshot())[id].value == false)
        assert(set(restored, id, true))
        reopened.value.reff_theme = "glass"
        assert(fields(restored.snapshot())[id].value == false)
        assert(set(restored, id, true) and fields(restored.snapshot())[id].value == true)
        reopened.value.reff_theme = "reff"
        assert(fields(restored.snapshot())[id].value == true)
    end
end)

test("both game defaults, legacy fields and global permission", function()
    for _, item in ipairs({ { "Wilds", Wilds, 200 }, { "Rise", Rise, 100 } }) do
        local global, disk = session(item[1], { extension = { enabled = true }, new_ui_key = 91,
            scan_interval = 1.2, body_id_ttl = 3, auto_set_selected_preset_as_default = false })
        local extension, calls = global.value.extension, 0
        local settings = new(global, item[2].new({ config = global.value }), function(id, value, context)
            assert(id == "language" and value == "en" and context == nil)
            assert(disk.saved.language == "en")
            calls = calls + 1
        end)
        local snapshot = fields(settings.snapshot(nil))
        if item[1] == "Wilds" then
            assert(snapshot.scanner_batch_size.value == item[3])
            assert(snapshot.scan_interval.value == 1.2 and snapshot.body_id_ttl.value == 3)
        else
            assert(not snapshot.scan_interval and not snapshot.body_id_ttl and not snapshot.scanner_batch_size,
                "Rise must not present unused Wilds scanner controls")
        end
        assert(not snapshot.auto_set_selected_preset_as_default.value)
        assert(snapshot.language.options[1].value == "zh" and snapshot.language.options[2].value == "en")
        assert(not snapshot.new_ui_key and not snapshot.debug_profile and not snapshot.theme)
        assert(set(settings, "language", "en"))
        assert(calls == 1 and disk.writes == 1 and global.value.extension == extension)
        S.equal(disk.saved.extension, { enabled = true })
        assert(disk.saved.new_ui_key == 91)
        assert(disk.saved.scan_interval == 1.2 and disk.saved.body_id_ttl == 3)
        assert(disk.saved.scanner_batch_size == item[3], "hidden legacy fields survive saving")
        local ok = set(settings, "language", "zh-CN")
        assert(not ok and global.value.language == "en" and disk.writes == 1)
        assert(not set(settings, "new_ui_key", 40))
    end
end)

test("Rise rejects unused scanner edits without changing legacy JSON", function()
    local global, disk = session("Rise", { scan_interval = 1.7, body_id_ttl = 4, scanner_batch_size = 88 })
    local settings = new(global, Rise.new({ config = global.value }))
    local previous = S.copy(global.value)
    for _, id in ipairs({ "scan_interval", "body_id_ttl", "scanner_batch_size" }) do
        local ok, reason = set(settings, id, 2)
        assert(not ok and reason == "设置项不存在" and disk.writes == 0)
        S.equal(global.value, previous)
    end
    for _, section in ipairs(settings.snapshot().sections) do
        assert(section.id ~= "performance", "no empty performance section in Rise")
    end
end)

test("global failure restores references and defers callbacks", function()
    local global, disk = session("Wilds", { extension = { keep = 7 } })
    local config, extension, calls = global.value, global.value.extension, 0
    local settings = new(global, Wilds.new({ config = config }), function() calls = calls + 1 end)
    disk.result = false
    local ok, reason = set(settings, "scan_interval", 2)
    assert(not ok and reason == "disk full" and config.scan_interval == 0.5 and calls == 0)
    disk.result, disk.throws = true, true
    ok, reason = set(settings, "language", "en")
    assert(not ok and reason:find("disk exception", 1, true) and config.language == "zh")
    assert(global.value == config and config.extension == extension and calls == 0)
    disk.throws = false
    assert(set(settings, "scan_interval", 99) and config.scan_interval == 5)
    assert(set(settings, "body_id_ttl", -1) and config.body_id_ttl == 0.1)
    assert(set(settings, "scanner_batch_size", 123.8) and config.scanner_batch_size == 123)
    local writes = disk.writes
    assert(set(settings, "scanner_batch_size", 123) and disk.writes == writes)
    assert(not set(settings, "body_id_ttl", 0/0) and disk.writes == writes)
end)

test("persisted setting reports subsequent equipment failure accurately", function()
    local global, disk = session("Wilds", { auto_set_selected_preset_as_default = false })
    local calls = 0
    local settings = new(global, Wilds.new({ config = global.value }), function(id, value, context)
        assert(id == "auto_set_selected_preset_as_default" and value and context.id == "armor")
        calls = calls + 1
        if calls == 1 then return false, "equipment save failed" end
    end)
    local ok, reason = set(settings, "auto_set_selected_preset_as_default", true, { id = "armor" })
    assert(not ok and reason == "设置已保存，但应用失败: equipment save failed")
    assert(global.value.auto_set_selected_preset_as_default and disk.saved.auto_set_selected_preset_as_default)
    assert(set(settings, "auto_set_selected_preset_as_default", true, { id = "armor" }))
    assert(calls == 2 and disk.writes == 1, "retry applies the saved setting without rewriting it")
end)

test("Wilds camera uses old JSON and applies only after save", function()
    local global, disk = session("Wilds", { portrait_camera = { distance = 3.2, extension = { keep = 1 } } })
    local camera, extension = global.value.portrait_camera, global.value.portrait_camera.extension
    local enabled, updates = nil, 0
    local preview = {
        set_enabled = function(value) assert(disk.saved.portrait_enabled == value); enabled = value end,
        set_camera_settings = function(value)
            assert(disk.saved.portrait_camera.distance == value.distance and value == camera)
            updates = updates + 1
        end,
    }
    local settings = new(global, Wilds.new({ config = global.value, get_portrait_preview = function() return preview end }))
    local snapshot = fields(settings.snapshot({ suspended = true }))
    assert(not snapshot.portrait_enabled.value and not snapshot.portrait_enabled.disabled)
    assert(snapshot["portrait_camera.distance"].value == 3.2)
    assert(snapshot["portrait_camera.refresh_fps"].value == 30)
    assert(set(settings, "portrait_camera.distance", 4.2))
    assert(updates == 1 and camera.distance == 4.2 and camera.extension == extension)
    assert(set(settings, "portrait_enabled", false) and enabled == false)
    disk.result = false
    assert(not set(settings, "portrait_camera.distance", 5) and camera.distance == 4.2 and updates == 1)
    assert(not set(settings, "portrait_camera.vertical", 0.5) and camera.vertical == nil)
    assert(not set(settings, "portrait_enabled", true) and enabled == false and global.value.portrait_enabled == false)
    disk.result = true
    assert(set(settings, "portrait_camera.refresh_fps", 0) and camera.refresh_fps == 0)
    assert(not set(settings, "portrait_camera.refresh_fps", 15))
    preview = nil
    snapshot = fields(settings.snapshot())
    assert(snapshot.portrait_enabled.disabled and snapshot.portrait_enabled.reason)
    assert(not set(settings, "portrait_enabled", true))
end)

test("missing camera object is rolled back on failed save", function()
    local global, disk = session("Wilds")
    local settings = new(global, Wilds.new({ config = global.value,
        get_portrait_preview = function() return { set_camera_settings = function() error("not saved") end } end }))
    disk.result = false
    assert(not set(settings, "portrait_camera.distance", 4) and global.value.portrait_camera == nil)
end)

test("game apply failure keeps the successfully saved global value", function()
    local global, disk = session("Wilds")
    local notified = false
    local settings = new(global, Wilds.new({ config = global.value,
        get_portrait_preview = function()
            return { set_enabled = function() return false, "preview apply failed" end }
        end }), function() notified = true end)
    local ok, reason = set(settings, "portrait_enabled", true)
    assert(not ok and reason == "设置已保存，但应用失败: preview apply failed" and not notified)
    assert(global.value.portrait_enabled and disk.saved.portrait_enabled)
end)

test("camera reset changes only five legacy values and restores in place on failure", function()
    local global, disk = session("Wilds", { portrait_camera = {
        distance = 4, horizontal = 0.3, vertical = -0.5, light_intensity = 1.5, refresh_fps = 0,
        extension = { keep = 4 },
    } })
    local camera, extension, applied = global.value.portrait_camera, global.value.portrait_camera.extension, 0
    local settings = new(global, Wilds.new({ config = global.value, get_portrait_preview = function()
        return { set_camera_settings = function(value)
            assert(value == camera and disk.saved.portrait_camera.distance == 1.5)
            applied = applied + 1
        end }
    end }))
    local snapshot = fields(settings.snapshot())
    assert(snapshot["portrait_camera.reset"].type == "action" and snapshot["portrait_camera.reset"].value == nil)
    local previous = S.copy(camera)
    disk.result = false
    assert(not set(settings, "portrait_camera.reset"))
    assert(global.value.portrait_camera == camera and camera.extension == extension and applied == 0)
    S.equal(camera, previous)
    disk.result = true
    assert(set(settings, "portrait_camera.reset"))
    assert(global.value.portrait_camera == camera and camera.extension == extension and applied == 1)
    S.equal(camera, { distance = 1.5, horizontal = 0, vertical = 0, light_intensity = 1, refresh_fps = 30,
        extension = { keep = 4 } })
    S.equal(disk.saved.portrait_camera, camera)
    local writes = disk.writes
    assert(set(settings, "portrait_camera.reset") and disk.writes == writes and applied == 2)

    global.value.portrait_camera, disk.result = nil, false
    assert(not set(settings, "portrait_camera.reset") and global.value.portrait_camera == nil)
end)

test("Rise settings use actual option callbacks and transition file", function()
    local writes, hooks, app, renderer = {}, {}, {}, {}
    sdk = {
        get_native_singleton = function(name) return name == "via.Application" and app or renderer end,
        get_managed_singleton = function()
            return { get_field = function() return { call = function() return 3 end } end }
        end,
        find_type_definition = function(name)
            return { get_method = function(_, method)
                return { id = name .. "." .. method, call = function(_, object, value)
                    assert(math.type(value) == "float")
                    assert(object == (method == "set_MaxFps" and app or renderer))
                    writes[#writes + 1] = { method, value }
                end }
            end }
        end,
        hook = function(method, pre, post) hooks[method.id] = { pre = pre, post = post } end,
    }
    local global, disk = session("Rise", { enable_multiplayer = false, extension = { keep = true } })
    local transition_disk = { enabled = true, duration = 0.42, extension = { keep = 9 } }
    local transition_result, transition_saved, finishes, transition_writes = false, nil, 0, 0
    local transition = Dissolve.new({ clock = function() return 0 end, valid = function() return true end,
        store = {
            load = function(path) assert(path == "ArmorVariantManager/DissolveTransitions.json"); return transition_disk end,
            save = function(path, value)
                assert(path == "ArmorVariantManager/DissolveTransitions.json")
                transition_writes = transition_writes + 1
                if not transition_result then return false, "transition disk full" end
                transition_saved = S.copy(value)
                return true
            end,
        } })
    transition.finish_all = function(self)
        assert(not self.enabled and transition_saved.enabled == false)
        finishes = finishes + 1
    end
    local options = Options.new(global.value, { actors = { get = function() return { entries = {} } end },
        transition = transition }, function(key) return key end, global.save)
    writes = {}
    local settings = new(global, Rise.new({ config = global.value, transition = transition, options = options }))
    local snapshot = fields(settings.snapshot())
    assert(not snapshot.enable_multiplayer.value and snapshot.dissolve_enabled.value)
    assert(snapshot.dissolve_duration.value == 0.42 and snapshot.image_quality_rate.value == 1)
    assert(not snapshot.fps and not snapshot.debug_profile and not snapshot.multiplayer_players_per_tick)
    assert(set(settings, "enable_multiplayer", true) and disk.saved.enable_multiplayer)
    assert(set(settings, "enable_image_quality", true))
    S.equal(writes, { { "set_ImageQualityRate", 1 } })
    assert(set(settings, "image_quality_rate", 1.75))
    S.equal(writes[#writes], { "set_ImageQualityRate", 1.75 })
    disk.result = false
    local previous_writes = #writes
    assert(not set(settings, "image_quality_rate", 2) and global.value.image_quality_rate == 1.75)
    assert(#writes == previous_writes)
    disk.result = true
    assert(set(settings, "enable_image_quality", false) and #writes == previous_writes)
    options.apply_fps_cap()
    S.equal(writes[#writes], { "set_MaxFps", 120 })
    local global_writes = disk.writes
    local ok, reason = set(settings, "dissolve_enabled", false)
    assert(not ok and reason == "transition disk full" and transition.enabled and finishes == 0)
    assert(transition_disk.enabled and transition_disk.duration == 0.42)
    transition_result = true
    assert(set(settings, "dissolve_enabled", false) and finishes == 1)
    assert(disk.writes == global_writes and transition_writes == 2)
    S.equal(transition_saved, { enabled = false, duration = 0.42, extension = { keep = 9 } })
    transition_result = false
    assert(not set(settings, "dissolve_duration", 0.8) and transition.duration == 0.42)
    assert(transition_disk.duration == 0.42)
    transition_result = true
    assert(set(settings, "dissolve_duration", 5) and transition.duration == 2 and transition_saved.duration == 2)
    assert(finishes == 1)

    -- 原生设置沿用同一保存入口，失败时不能先结束正在进行的溶解动画。
    transition.enabled, transition_disk.enabled = true, true
    transition_result = false
    local errors = {}
    imgui = { checkbox = function() return true, false end,
        text_colored = function(value) errors[#errors + 1] = value end }
    transition:draw_ui(function(key) return key end)
    assert(transition.enabled and finishes == 1 and errors[1] == "transition disk full")
    transition_result = true
    transition:draw_ui(function(key) return key end)
    assert(not transition.enabled and finishes == 2 and not transition.settings_error)
end)

test("optional Rise capabilities are explicit and cannot mutate global fields", function()
    local global, disk = session("Rise", { enabled = false, duration = 9 })
    local settings = new(global, Rise.new({ config = global.value }))
    local snapshot = fields(settings.snapshot())
    assert(snapshot.dissolve_enabled.disabled and snapshot.dissolve_enabled.value)
    assert(snapshot.image_quality_rate.disabled)
    assert(not set(settings, "dissolve_enabled", false) and disk.writes == 0)
    assert(not set(settings, "image_quality_rate", 2) and disk.writes == 0)
    assert(global.value.enabled == false and global.value.duration == 9)
end)

test("saved dissolve disable retains failed materials across tick and retries without saving again", function()
    for _, method in ipairs({ "setMaterialsEnable", "setMaterialFloat4" }) do
        local function vector(x, y, z, w) return { x = x, y = y, z = z, w = w } end
        local mesh = { visible = true, vectors = { [0] = vector(.2, .3, .4, .5), vector(.6, .7, .8, .9) } }
        function mesh:call(name, index, variable, value)
            if name == self.failure then error(name .. " failed") end
            if name == "getMaterialName" then return "cloth" end
            if name == "get_MaterialNum" then return 1 end
            if name == "getMaterialVariableNum" then return 2 end
            if name == "getMaterialVariableName" then return variable == 0 and "Dissolve_Flag" or "Dissolve_Rate" end
            if name == "getMaterialFloat4" then return self.vectors[variable] end
            if name == "setMaterialFloat4" then self.vectors[variable] = value; return end
            if name == "getMaterialsEnable" then return self.visible end
            if name == "setMaterialsEnable" then self.visible = variable; return end
            if name == "get_Enabled" then return true end
            error(name)
        end
        local original = S.copy(mesh.vectors)
        local writes, saved = 0
        local transition = Dissolve.new({ clock = function() return 0 end, valid = function() return true end,
            vector = vector, store = {
                load = function() return { enabled = true, duration = .355, extension = 7 } end,
                save = function(_, value) writes = writes + 1; saved = S.copy(value); return true end,
            } })
        local global = session("Rise")
        local settings = new(global, Rise.new({ config = global.value, transition = transition }))
        transition:set_material_enabled(mesh, 0, false)
        mesh.failure = method
        local ok, reason = set(settings, "dissolve_enabled", false)
        assert(not ok and reason:find("设置已保存，但应用失败:", 1, true)
            and reason:find(method .. " failed", 1, true), "the saved setting must report native apply failure")
        assert(not transition.enabled and saved.enabled == false and saved.extension == 7 and writes == 1)
        assert(next(transition.active), "failed material must remain retryable")
        transition:tick()
        assert(next(transition.active), "disabled runtime tick must retain the failed material")
        mesh.failure = nil
        assert(set(settings, "dissolve_enabled", false))
        assert(writes == 1 and not next(transition.active) and not mesh.visible)
        S.equal(mesh.vectors, original)
    end
end)

print("PASS: " .. count .. " REFF settings schema, legacy persistence, rollback and game effects")
