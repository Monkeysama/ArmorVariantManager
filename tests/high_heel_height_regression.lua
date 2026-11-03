-- 高跟鞋核心与 JSON 接入的离线回归，不需要启动游戏或操作桌面。
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local Height = require("ArmorVariantManager_Core.GroundClippingFix")
local function copy(p) return { x = p.x, y = p.y, z = p.z } end
local function near(actual, expected, message)
    assert(math.abs(actual - expected) < 0.000001, (message or "position") .. ": " .. actual .. " ~= " .. expected)
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end
Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
local callbacks = { pre = {}, post = {}, reset = {}, hunter_end = {}, frame = {} }
re = {
    on_frame = function(fn) table.insert(callbacks.frame, fn) end,
    on_pre_application_entry = function(name, fn)
        assert(name == "UpdateMotion"); table.insert(callbacks.pre, fn)
    end,
    on_application_entry = function(name, fn)
        assert(name == "LateUpdateBehavior"); table.insert(callbacks.post, fn)
    end,
    on_script_reset = function(fn) table.insert(callbacks.reset, fn) end
}
local function run_callbacks(phase) for _, fn in ipairs(callbacks[phase]) do fn() end end
local function hunter_end(address)
    for _, fn in ipairs(callbacks.hunter_end) do fn({ [2] = address or 300 }) end
end
local function run(phase)
    if phase == "post" then
        -- Lua 实机顺序：UpdateMotion pre → 猎人末段钩子 → LateUpdateBehavior post。
        run_callbacks("pre")
        hunter_end()
        run_callbacks("post")
    else run_callbacks(phase) end
end
local errors, reflected, writes = 0, 0, 0
log = { error = function() errors = errors + 1 end, info = function() end }
local root, transform, hunter, player, manager
local riding, suspended, absent, fail_position, tilted = false, false, false, false, false
local body_id, hunter_address = "armor_a", 300
local configs = { armor_a = {} }
local function skeleton(transform_id, joint_id)
    root = { id = joint_id, position = { x = 1, y = 2, z = 3 } }
    function root:get_address() return self.id end
    transform = { id = transform_id }
    function transform:get_address() return self.id end
end
skeleton(100, 101)
hunter = { call = function(_, name)
    if name == "get_IsSetUp" then return true end
    if name == "get_IsPorterRiding" then return riding end
    error("Unexpected hunter call: " .. name)
end }
function hunter:get_address() return hunter_address end
player = { call = function(_, name)
    if name == "get_Character" then return hunter end
    if name == "get_Object" then
        return { call = function(_, method) assert(method == "get_Transform"); return transform end }
    end
    error("Unexpected player call: " .. name)
end }
manager = { call = function(_, name) assert(name == "getMasterPlayer"); return player end }
sdk = {
    to_int64 = function(value) return value end,
    hook = function(method, pre, post)
        assert(method.type_name == "app.HunterCharacter" and method.name == "doLateUpdateEnd" and post == nil)
        table.insert(callbacks.hunter_end, pre)
    end,
    get_managed_singleton = function(name)
        assert(name == "app.PlayerManager"); return not absent and manager or nil
    end,
    find_type_definition = function(type_name)
        reflected = reflected + 1
        return { get_method = function(_, name)
            return { type_name = type_name, name = name, call = function(_, object, ...)
                if type_name == "via.Transform" then
                    assert(name == "getJointByName" and object == transform and (...) == "root")
                    return root
                end
                assert(type_name == "via.Joint" and object == root)
                if name == "get_LocalPosition" then return copy(root.position) end
                if name == "get_Position" then
                    if fail_position then error("mock native failure") end
                    local p = root.position
                    if tilted then return { x = p.x, y = p.z, z = -p.y } end
                    return copy(p)
                end
                if name == "set_LocalPosition" or name == "set_Position" then
                    local p = (...)
                    if tilted and name == "set_Position" then
                        root.position = { x = p.x, y = -p.z, z = p.y }
                    else root.position = copy(p) end
                    writes = writes + 1
                    return
                end
                error("Unexpected native call: " .. name)
            end }
        end }
    end
}
local shutdown_count = 0
_G.HighHeelHeight = { shutdown = function() shutdown_count = shutdown_count + 1 end }
local deps = {
    is_suspended = function() return suspended end,
    get_settings = function()
        local config = configs[body_id]
        return Height.config_settings(config), body_id
    end
}
local api = Height.new(deps)
assert(shutdown_count == 1, "Standalone prototype must stop")
assert(Height.read_settings(nil).enabled == false)
assert(Height.read_settings(nil).height_cm == 10)
assert(Height.bounded_height(100) == 50 and Height.bounded_height(-50) == -10)
assert(Height.bounded_height(0 / 0) == 10 and Height.bounded_height(math.huge) == 10)
assert(Height.config_settings({ high_heel_height = { height_cm = 9 } }).height_cm == 9)
assert(Height.config_settings({ ground_clipping_fix = { enabled = false }, high_heel_height = { enabled = true } }).enabled == false)
run("post")
assert(writes == 0 and configs.armor_a.high_heel_height == nil, "Old JSON stays unchanged and disabled")
configs.armor_a.high_heel_height = { enabled = true, height_cm = 10 }
-- 复现用户现场日志：同帧地址必须在猎人末段之前准备，不能等全局末段回调。
run_callbacks("pre")
near(root.position.y, 2, "Preparing the frame must not raise root before IK")
hunter_end(999)
near(root.position.y, 2, "NPC and preview callbacks must not write local hunter")
local ik_base = root.position.y
hunter_end()
near(root.position.y, ik_base + 0.1, "Raise root only after hunter IK")
run_callbacks("post")
near(root.position.y, ik_base + 0.1, "Global late callback must not undo the current frame correction")
run("pre")
near(root.position.y, 2, "Next motion frame restores previous contribution")
hunter_address = 301
hunter_end(300); hunter_end(301)
near(root.position.y, 2, "Hunter replacement between preparation and callback must not write either skeleton")
run_callbacks("pre"); hunter_end(301)
near(root.position.y, 2.1, "New hunter is accepted only after preparing its own late update")
run("pre"); hunter_address = 300
-- 暂停状态必须在恢复后的同一帧被覆盖，不能在勾选后继续显示上一次暂停提示。
suspended = true; run("post")
assert(api.get_status().key == "heel_suspended")
suspended = false; run("post")
assert(api.get_status().key == "heel_applied", "Recovered frame must clear stale paused status")
run("pre")
for frame = 1, 1000 do
    run("pre")
    root.position = { x = 1, y = 2 + frame / 1000, z = 3 }
    run("post"); run("post")
    hunter_end(); hunter_end()
    near(root.position.y, 2 + frame / 1000 + 0.1, "No accumulation or duplicate callback")
end
run("pre"); near(root.position.y, 3)
assert(reflected == 6, "Native methods and hunter hook should be resolved once")
configs.armor_a.high_heel_height.height_cm = 25
api.settings_changed(); run("post"); near(root.position.y, 3.25)
configs.armor_a.high_heel_height.enabled = false
api.settings_changed(); run("post"); near(root.position.y, 3)
configs.armor_a.high_heel_height.enabled = true
run("post")
riding = true; run("post"); near(root.position.y, 3)
assert(api.get_status().key == "heel_riding")
riding = false; run("post")
suspended = true; run("post"); near(root.position.y, 3)
assert(api.get_status().key == "heel_suspended")
suspended = false; run("post")
root.position.y = 8
run("pre"); near(root.position.y, 8, "Do not overwrite another animation or MOD")
run("post"); near(root.position.y, 8.25)
run("pre")
tilted = true; run("post")
near(root.position.y, 8, "World-Y offset must not change local Y on tilted skeleton")
near(root.position.z, 3.25)
run("pre"); near(root.position.z, 3); tilted = false
run("post")
skeleton(200, 201); run("pre"); near(root.position.y, 2, "Never restore old scene skeleton")
run("post"); near(root.position.y, 2.25)
root = { id = 202, position = { x = 4, y = 5, z = 6 }, get_address = function(self) return self.id end }
run("pre"); near(root.position.y, 5, "Joint address change must not restore old joint")
body_id = "armor_b"; run("post"); near(root.position.y, 5)
assert(api.get_status().key == "heel_disabled", "Missing equipment JSON disables correction")
configs.armor_b = { ground_clipping_fix = { enabled = true, height_cm = -5 } }
run("post"); near(root.position.y, 4.95)
body_id = "armor_a"; run("post"); near(root.position.y, 5.25)
run("pre")
absent = true; run("post"); assert(api.get_status().key == "heel_waiting")
absent = false
fail_position = true; run("post")
assert(errors == 1 and api.get_status().key == "heel_error")
run("post"); assert(errors == 1, "Do not retry native errors every frame")
fail_position = false; api.settings_changed(); run("post"); near(root.position.y, 5.25)
local previous = api
api = Height.new(deps)
assert(not previous.is_alive()); near(root.position.y, 5, "Reload must restore old contribution")
run("post"); near(root.position.y, 5.25, "Old callbacks must be inert after reload")
assert(rawget(_G, "HighHeelHeight") == api, "Legacy alias must point to the integrated instance")
run("reset"); near(root.position.y, 5)
run("post"); near(root.position.y, 5)
assert(not api.is_alive() and _G.ArmorVariantManagerGroundClippingFix == nil)
-- 更新入口缺失或安装失败时，不回退到已知错误的全局写骨骼时机。
local normal_hook = sdk.hook
sdk.hook = function() error("mock hook installation failure") end
local broken = Height.new(deps)
assert(broken.get_status().key == "heel_error")
run("post"); near(root.position.y, 5, "Hook failure must leave skeleton unchanged")
broken.shutdown(); sdk.hook = normal_hook
print("PASS: 1000 frames, duplicate callbacks, world-Y, animation ownership, riding, transition, scene/joint replacement, equipment switch, faults, reload/reset and prototype ownership")
print("PASS: real Lua callback ordering, post-IK timing, paused status recovery, NPC filtering, hunter replacement and hook failure")

-- 提取主脚本中实际使用的保存函数，验证新增选项没有改变旧预设数据与备份保护。
local handle = assert(io.open("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua", "r"))
local source = handle:read("a"); handle:close()
local function extract(name, following)
    local first = assert(source:find("local function " .. name .. "(", 1, true))
    local last = assert(source:find(following, first + 1, true))
    return source:sub(first, last - 1)
end
local stored, fail_save = {}, false
local preset = { ["1"] = { mesh_enabled = true, materials = { Face = false } } }
local editor = Height.new_preset_state()
local mesh = { call = function(_, name)
    if name == "get_Enabled" then return true end
    if name == "get_MaterialNum" then return 1 end
    if name == "getMaterialName" then return "Face" end
    if name == "getMaterialsEnable" then return false end
    error(name)
end }
local env = setmetatable({
    current_config = { default_preset = "A", presets = { A = clone(preset) }, groups = {}, custom_legacy = { keep = true } },
    loaded_configs = {}, active_overrides = { armor_a = { temporary = true } },
    active_group_presets = { armor_a = { [""] = "A" } },
    config_restored = {}, config_restore_handled = {},
    TransformManager = { refresh_config_rules = function() end, clear_last_state_cache = function() end },
    get_config_path = function(id) return id .. ".json" end,
    get_backup_path = function(id) return "backup/" .. id .. ".json" end,
    safe_json_save = function(path, data)
        if fail_save then return false end
        stored[path] = clone(data); return true
    end,
    last_body_id = "armor_a", is_weapon_mode = false,
    get_body_id = function() return "armor_a" end,
    PresetEditor = require("ArmorVariantManager_Core.Presets.Editor"),
    PresetSelection = require("ArmorVariantManager_Core.Presets.Selection"),
    GamePresets = require("ArmorVariantManager_Core.Games.Wilds.Presets"),
    deep_copy_table = clone, GroundClippingFix = Height, ground_clipping_presets = editor,
    current_group_name = "", type_mesh = true, temp_applied_presets = {},
    get_local_player_character = function() return {} end,
    get_character_part = function() return {} end,
    get_character_part_meshes = function(_, index) return index == 1 and { mesh } or {} end,
    is_material_in_current_context = function() return true end,
    update_preset_names_list = function() end,
    is_weapon_id = function(id) return id == "weapon_a" end,
    get_all_characters = function() return {} end,
    get_character_body_id = function() return nil end,
    sdk = { is_managed_object = function() return true end },
    ground_clipping_fix = { settings_changed = function() end }
}, { __index = _G })
env.capture_materials = require("ArmorVariantManager_Core.Games.Wilds.Capture").new({
    part_meshes = function(...) return env.get_character_part_meshes(...) end,
    first = function(...) return env.get_mesh_component_recursive(...) end,
}, {weapon_id = function(...) return env.get_character_weapon_id(...) end})
env.appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance").new({
    load = function(id) return env.load_config_data(id) end,
    rules = setmetatable({}, {__index=function(_, key) return env.TransformManager[key] end}),
    can_transform = function(character) return env.can_use_transform(character) end,
    game_object = function(...) return env.safe_get_game_object(...) end,
    is_weapon_id = env.is_weapon_id,
})
env.appearance.overrides, env.appearance.groups = env.active_overrides, env.active_group_presets
env.appearance.height = editor
env.config_session = require("ArmorVariantManager_Core.Config.Session").new(
    require("ArmorVariantManager_Core.Games.Wilds.Config"), nil, {
        config_path = env.get_config_path, backup_path = env.get_backup_path,
        load = function(path) return clone(stored[path]) end,
        save = env.safe_json_save
    })
env.loaded_configs = env.config_session.cache
env.config_restored = env.config_session.restored
env.config_restore_handled = env.config_session.handled
env.get_effective_group_presets = function(id) return env.active_group_presets[id] or {} end
local save_source = extract("save_current_config_to_file", "\n-- 将指定预设写为")
env.save_current_config_to_file = assert(load(save_source .. "\nreturn save_current_config_to_file", "save", "t", env))()
local set_source = extract("set_ground_clipping_settings", "\nvariant_manager_ui =")
local set = assert(load(set_source .. "\nreturn set_ground_clipping_settings", "settings", "t", env))()
local capture_source = extract("save_preset", "\nlocal function find_auto_preset")
local capture = assert(load(capture_source .. "\nreturn save_preset", "capture", "t", env))()
env.PresetDefaults = require("ArmorVariantManager_Core.Presets.Defaults")
local defaults_source = extract("apply_all_defaults", "\n-- 辅助函数：变身规则激活")
env.load_config_data = function() return env.current_config end
local defaults = assert(load(defaults_source .. "\nreturn apply_all_defaults", "defaults", "t", env))()
local merges_source = extract("merge_overrides", "\n-- 辅助函数：应用一个 Body ID")
env.merge_overrides = assert(load(merges_source .. "\nreturn merge_overrides", "merge", "t", env))()
local apply_source = extract("get_current_preset_data", "\n-- 辅助函数：加载指定 Body ID")
local apply
apply, env.get_current_preset_data = assert(load(apply_source .. "\nreturn apply_preset, get_current_preset_data", "apply", "t", env))()
local set_default_source = extract("set_preset_as_default", "\n-- 开启自动保存时")
local set_default = assert(load(set_default_source .. "\nreturn set_preset_as_default", "default", "t", env))()
assert(set({ enabled = true, height_cm = 12.5 }, "armor_a"))
assert(next(stored) == nil and env.current_config.ground_clipping_fix == nil, "Preview must not write armor JSON")
assert(env.active_group_presets.armor_a[""] == "A" and env.active_overrides.armor_a.temporary)
assert(capture("A", "armor_a"))
assert(stored["armor_a.json"].ground_clipping_fix == nil)
assert(stored["armor_a.json"].presets.A.ground_clipping_fix.height_cm == 12.5)
assert(stored["backup/armor_a.json"].presets.A.ground_clipping_fix.height_cm == 12.5)
assert(stored["armor_a.json"].presets.A["1"].materials.Face == false)
assert(stored["armor_a.json"].custom_legacy.keep)
defaults("armor_a")
env.config_restored.armor_a = true
assert(set({ height_cm = 14 }, "armor_a"))
assert(capture("A", "armor_a"))
assert(stored["armor_a.json"].presets.A.ground_clipping_fix.height_cm == 14)
assert(stored["backup/armor_a.json"].presets.A.ground_clipping_fix.height_cm == 12.5, "Pending backup must be preserved")
assert(env.config_restored.armor_a == true)
fail_save = true
assert(not env.save_current_config_to_file("armor_a", true))
assert(stored["armor_a.json"].presets.A.ground_clipping_fix.height_cm == 14, "Failed write must preserve disk contents")
assert(set({ height_cm = 40 }, "armor_a"))
assert(not capture("A", "armor_a"))
near(env.current_config.presets.A.ground_clipping_fix.height_cm, 14, "Failed overwrite must restore prior preset")
assert(not capture("FailedNew", "armor_a"))
assert(env.current_config.presets.FailedNew == nil, "Failed create must not leave phantom preset")
fail_save = false
assert(not set({ enabled = true }, "armor_b"), "Reject stale equipment context")
env.is_weapon_mode = true
assert(not set({ enabled = true }, "armor_a"), "Do not write height into weapon JSON")
env.is_weapon_mode = false
local preview_height = env.active_overrides.armor_a.ground_clipping_fix.height_cm
assert(set({ enabled = false, height_cm = 0 }, "armor_a"))
near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, preview_height, "Unchecking in the editor must not revoke an applied height")
assert(set({ height_cm = -8 }, "armor_a"))
near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, preview_height, "Editing an unchecked height must not control the model")
assert(set({ height_cm = 0 }, "armor_a"))
assert(capture("B", "armor_a"))
assert(not stored["armor_a.json"].presets.B.ground_clipping_fix.enabled)
assert(stored["armor_a.json"].presets.B.ground_clipping_fix.height_cm == 0)
defaults("armor_a")
near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 14, "Load armor default height")
apply("B"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 14, "Unchecked preset must keep the current height")
assert(env.active_overrides.armor_a.ground_clipping_fix.enabled)
env.current_config.presets.Zero = { ground_clipping_fix = { enabled = true, height_cm = 0 } }
apply("Zero"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 0, "Checked zero must reset height")
assert(env.active_overrides.armor_a.ground_clipping_fix.enabled)
apply("B"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 0, "Unchecked preset must preserve checked zero")
apply("A"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 14)
assert(set({ height_cm = 25 }, "armor_a"))
apply("B"); apply("A")
near(editor.get_editor(env.current_config, "armor_a", "", "A").height_cm, 14, "Selecting presets discards unsaved draft")
env.current_config.groups.Boots = { default_preset = "High", presets = {
    High = { ground_clipping_fix = { enabled = true, height_cm = 30 } },
    Low = { ground_clipping_fix = { enabled = true, height_cm = 5 } }
} }
env.current_config.group_order = { "Boots" }
defaults("armor_a"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 30)
env.current_group_name = "Boots"
apply("Low"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 5)
assert(set({ height_cm = 7 }, "armor_a")); assert(capture("Low", "armor_a"))
near(stored["armor_a.json"].groups.Boots.presets.Low.ground_clipping_fix.height_cm, 7)
near(stored["armor_a.json"].presets.A.ground_clipping_fix.height_cm, 14, "Group saves must not modify other presets")
env.current_config.ground_clipping_fix = { enabled = true, height_cm = 11 }
env.current_config.presets.Legacy = clone(preset)
env.current_group_name = ""
apply("Legacy"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 11, "Legacy armor setting fallback")
apply("B"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 11, "Explicit unchecked must skip legacy fallback and preserve height")
env.current_config.ground_clipping_fix = nil
apply("Legacy"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 11, "Old preset without settings does not control height")
assert(not Height.default_settings({ presets = { Legacy = {} }, default_preset = "Legacy" }).enabled, "Old JSON initially defaults off")
env.current_group_name = "Boots"
apply("High")
env.current_config.groups.Global = { is_global = true, default_preset = "Off", presets = { Off = {
    ground_clipping_fix = { enabled = false, height_cm = 0 }, ["1"] = { materials = { Face = false } }
} } }
env.current_group_name = "Global"
apply("Off"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 30, "Global material rebuild must preserve height for unchecked presets")
near(Height.default_settings(env.current_config).height_cm, 30, "Unchecked global default must not override checked ordinary default")
env.current_config.groups.Global.presets.Zero = { ground_clipping_fix = { enabled = true, height_cm = 0 } }
local zero_defaults = clone(env.current_config)
zero_defaults.groups.Global.default_preset = "Zero"
near(Height.default_settings(zero_defaults).height_cm, 0, "Checked zero global default must override height")
assert(Height.default_settings(zero_defaults).enabled)
apply("Zero"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 0, "Checked global zero must reset height")
apply("Off"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 0, "Global rebuild must retain zero")
env.current_group_name = "Boots"
apply("High"); near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 30, "Other global material locks must not override manual height")
assert(not env.active_overrides.armor_a["1"].materials.Face)
assert(set_default("High", "armor_a"))
near(env.active_overrides.armor_a.ground_clipping_fix.height_cm, 30, "Automatic default saving must preserve selected height")
assert(env.active_group_presets.armor_a.Boots == "High", "Automatic default saving must preserve active preset selections")
fail_save = true
assert(not set_default("Low", "armor_a"))
assert(env.current_config.groups.Boots.default_preset == "High", "Failed default save must roll back")
fail_save = false
env.current_config.groups.config = { presets = {} }
env.current_group_name = "config"
assert(set({ enabled = true, height_cm = 19 }, "armor_a"))
near(editor.get_editor(env.current_config, "armor_a", "config", nil).height_cm, 19, "User group names must not collide with state metadata")
env.current_group_name = "Boots"
apply("High")
local hunter_a, hunter_b = {}, {}
editor.set_runtime(hunter_a, env.current_config, { enabled = true, height_cm = 35 })
near(editor.get_runtime(hunter_a, env.current_config).height_cm, 35)
near(editor.get_runtime(hunter_b, env.current_config, { height_cm = 3 }).height_cm, 3, "Characters must not share transformed height")
near(editor.get_runtime(hunter_a, {}, { height_cm = 4 }).height_cm, 4, "Reload must reject stale runtime configuration")
local weapon_config = {}
editor.set_runtime(hunter_a, weapon_config, { height_cm = 50 })
near(editor.get_runtime(hunter_a, env.current_config).height_cm, 35, "Weapon rules must not overwrite armor runtime")
local function hunter_wrapper() return setmetatable({}, { __tostring = function() return "ManagedObject: 0x12345" end }) end
editor.set_runtime(hunter_wrapper(), env.current_config, { enabled = true, height_cm = 22 })
near(editor.get_runtime(hunter_wrapper(), env.current_config).height_cm, 22, "SDK wrappers of the same hunter share runtime settings")

-- 使用真实变身引擎及主脚本包装器验证条件激活、优先级、关闭和回退，条件取值离线注入。
local condition_names = { "HP", "Damage", "Weapon", "LongSword", "DualBlades", "SwitchAxe",
    "InsectGlaive", "ChargeBlade", "GreatSwordType", "GreatSwordLevel", "BowLevel", "HammerLevel" }
local original_conditions, trigger = {}, { hp = true, weapon = true }
for _, name in ipairs(condition_names) do
    local path = "ArmorVariantManager_Core.Games.Wilds.Conditions.Condition_" .. name
    original_conditions[path] = package.loaded[path]
    local mode = name == "HP" and "hp" or "weapon"
    package.loaded[path] = { evaluate = function(config)
        return trigger[mode] and (mode == "hp" and config.transform_rules[1] or config.weapon_transform_rules[1]) or nil,
            tostring(trigger[mode])
    end }
end
local engine = dofile("ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/TransformManager.lua")
for _, name in ipairs(condition_names) do
    local path = "ArmorVariantManager_Core.Games.Wilds.Conditions.Condition_" .. name
    package.loaded[path] = original_conditions[path]
end
env.TransformManager = engine
env.can_use_transform = function() return true end
env.safe_get_game_object = function(character) return character end
local wrapper_source = extract("apply_transform_rules_for_character", "\n-- 当前 Body 的配置数据结构")
local transform = assert(load(wrapper_source .. "\nreturn apply_transform_rules_for_character", "transform", "t", env))()
local config = env.current_config
config.transform_type, config.is_parallel = "hp", true
config.parallel_settings = { hp = { enabled = true, priority = 1 }, weapon = { enabled = true, priority = 2 } }
config.transform_rules = { { targets = { { group = "Boots", preset = "Low" } } } }
config.weapon_transform_rules = { { targets = { { group = "Global", preset = "Off" } } } }
local base = clone(env.active_overrides.armor_a)
local result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 7, "Higher priority target height wins")
near(editor.get_runtime(hunter_a, config).height_cm, 7, "Runtime uses transformed preset")
near(base.ground_clipping_fix.height_cm, 30, "Transform must not mutate manual baseline")
trigger.hp = false
result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 30, "Unchecked condition target must preserve manual baseline")
trigger.hp = true
config.groups.Global.presets.Off.ground_clipping_fix = { enabled = true, height_cm = 0 }
config.parallel_settings.weapon.priority = 0
result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 0, "Higher priority checked zero must override checked height")
assert(result.ground_clipping_fix.enabled)
config.groups.Global.presets.Off.ground_clipping_fix.enabled = false
result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 7, "Unchecked higher priority target must not block lower priority height")
trigger.hp = false
trigger.weapon = false
result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 30, "Conditions ending restore manual baseline")
local repeated, changed = transform(config, hunter_a, base, env.merge_overrides)
assert(not changed and repeated.ground_clipping_fix.height_cm == 30, "Stable conditions preserve full height metadata")
config.is_parallel, config.transform_type = false, "hp"
config.transform_rules[1].targets[1] = { group = "", preset = "Legacy" }
engine.refresh_config_rules(config)
trigger.hp = true
result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 30, "Legacy condition preset without settings does not control height")
config.ground_clipping_fix = { enabled = true, height_cm = 11 }
result = transform(config, hunter_a, base, env.merge_overrides)
near(result.ground_clipping_fix.height_cm, 11, "Legacy condition preset respects armor fallback")
engine.refresh_config_rules({})
transform({}, hunter_a, { ["0"] = { materials = {} } }, env.merge_overrides)
near(editor.get_runtime(hunter_a, config).height_cm, 11, "Weapon evaluation keeps armor transform settings")
local languages = require("ArmorVariantManager_Core.Localization")
for key in pairs(languages.zh) do
    if key:match("^heel_") then assert(type(languages.en[key]) == "string", key) end
end
print("PASS: checked-only height control, checked zero reset, unchecked preview/manual/global/default/transform isolation, preset persistence, backups, legacy fallback, priority/rollback and per-character runtime")
local preset_ui = assert(source:find('if imgui.tree_node(T("presets_manager")', 1, true))
local correction_ui = assert(source:find('imgui.checkbox(T("heel_title")', preset_ui, true))
local preset_table = assert(source:find('imgui.begin_table("PresetsLayout"', preset_ui, true))
local preset_table_end = assert(source:find('imgui.end_table()', preset_table, true))
local group_preview = assert(source:find('-- 分组材质预览', preset_table_end, true))
local auto_find_button = assert(source:find('imgui.button(T("auto_find_preset"))', group_preview, true))
local auto_find_result = assert(source:find('if auto_find_log ~= "" then imgui.text_colored', auto_find_button, true))
local preset_ui_end = assert(source:find('-- 排序面板', auto_find_result, true))
assert(correction_ui > auto_find_result and correction_ui < preset_ui_end,
    "Legacy correction controls must follow preset/group controls, auto-find button and results inside preset management")
assert(not source:find('imgui.tree_node(T("heel_title"))', 1, true), "No standalone legacy correction section")

-- 用实际 D2D 组件验证防具面板底部工具条，数值与轨道分离，列表恢复顶部对齐。
local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local Button = require("ArmorVariantManager_UI.Component.Button")
local Checkbox = require("ArmorVariantManager_UI.Component.Checkbox")
local Slider = require("ArmorVariantManager_UI.Component.Slider")
local UI = require("ArmorVariantManager_Core.UI.VariantManagerUI")
local Preview = require("ArmorVariantManager_Core.PortraitPreview")
local mouse = { x = -100, y = -100, down = false, clicked = false }
imgui = {
    get_mouse = function() return { x = mouse.x, y = mouse.y } end,
    is_mouse_down = function() return mouse.down end,
    is_mouse_clicked = function() return mouse.clicked end
}
local function font(size)
    return { measure = function(_, text)
        local width = 0
        for _, code in utf8.codes(text) do width = width + (code < 128 and size * 0.53 or size) end
        return width, size
    end }
end
local fonts = { body = font(18), small = font(16), tiny = font(13) }
local drawn = {}
local track_right = 0
local draw = {
    text = function(f, text, x, y, color)
        assert(type(color) == "number")
        table.insert(drawn, { text = text, x = x, y = y, w = f:measure(text) })
    end,
    fill_rounded_rect = function(x, y, w, h, rx, ry, color)
        assert(type(color) == "number", "Slider must not pass a boolean as its color")
        if h == 5 then track_right = math.max(track_right, x + w) end
    end,
    outline_rect = function() end, line = function() end
}
local edited = { enabled = false, height_cm = 10 }
local language, saves = "zh", 0
local ui = UI.new({
    config = { language = "zh", scan_interval = 0.5, body_id_ttl = 1, scanner_batch_size = 200 },
    portrait_preview = Preview.new({ adapter = {}, register = false }),
    translate = function(key) return assert(languages[language][key], key) end,
    get_ground_clipping_settings = function() return clone(edited) end,
    set_ground_clipping_settings = function(changes, id)
        assert(id == "armor_a")
        for key, value in pairs(changes) do edited[key] = value end
        saves = saves + 1; return true
    end,
    get_ground_clipping_status = function() return { key = "heel_disabled" } end,
    get_part_count = function() return 6 end,
    save_settings = function() end
})
ui.d2d, ui.fonts = draw, fonts
ui.button = Button.new(draw, ui.colors, fonts)
ui.checkbox = Checkbox.new(draw, ui.colors, fonts)
ui.panel = { draw = function() end }
ui.draw_part_content = function(self, x, y, w, h)
    assert(y == 42 and h > 300 and y + h <= 410,
        "Armor parts must start at the original top and stop above the footer")
end
ui.sliders = {}
for _, key in ipairs({ "high_heel_height", "scan_interval", "body_id_ttl", "scanner_batch_size" }) do
    ui.sliders[key] = Slider.new(draw, ui.colors, fonts)
end
local context = { body_id = "armor_a", character = {}, weapon_mode = false }
local panel_width = 550
local function frame(x, y, down, clicked)
    mouse.x, mouse.y, mouse.down, mouse.clicked = x, y, down == true, clicked == true
    Runtime.capture_input(); Runtime.begin_input_frame()
end
local function paint()
    drawn, track_right = {}, 0
    ui:draw_parts(0, 0, panel_width, 518, context); Runtime.end_input_frame()
end
Runtime.reset_pending_input(); frame(-100, -100); paint()
for _, lang in ipairs({ "zh", "en" }) do
    language = lang
    for _, width in ipairs({ 430, 550 }) do
        panel_width = width
        frame(-100, -100); paint()
        for _, item in ipairs(drawn) do
            assert(item.x >= 0 and item.x + item.w <= width + 0.1, lang .. ": horizontal overflow: " .. item.text)
            assert(item.y >= 0 and item.y + 18 <= 518, lang .. ": vertical overflow: " .. item.text)
            if item.text:match("^[%d%.%-]+ cm$") then
                assert(item.x > track_right, "Slider number must be to the right of the track, not over it")
            end
            assert(not item.text:find(languages[lang].heel_scope_hint, 1, true), "Do not repeat save-status prose in toolbar")
        end
    end
end
panel_width = 550
frame(35, 445, true, true); paint()
assert(edited.enabled and saves == 1, "Actual checkbox must toggle enabled")
frame(35, 445, false); paint()
frame(350, 479, true, true); paint()
assert(edited.height_cm > 10 and saves == 2, "Actual slider must update height")
frame(350, 479, false); paint()
frame(494, 445, true, true); paint()
assert(edited.enabled and edited.height_cm == 0 and saves == 3, "Actual reset button must check the option and set zero")
frame(494, 445, false); paint()
context.weapon_mode = true
ui.draw_part_content = function() end
frame(-100, -100); paint(); assert(saves == 3, "Weapon settings must be read-only")
for _, item in ipairs(drawn) do assert(item.text ~= languages.en.heel_title, "Weapon UI must not show armor correction") end
context.weapon_mode = false
drawn = {}; frame(-100, -100); ui:draw_settings_panel(0, 0, 550, 518); Runtime.end_input_frame()
for _, item in ipairs(drawn) do assert(item.text ~= languages.en.heel_title, "Global settings must not contain armor correction") end
print("PASS: compact armor footer, legacy controls inside preset management, Chinese/English 430/550 px geometry, separate slider values, checkbox/slider/reset and armor-only settings")
