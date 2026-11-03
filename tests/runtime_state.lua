package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local source = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local GamePresets = require("ArmorVariantManager_Core.Games.Wilds.Presets")
local config = {
    default_preset = "Base", presets = { Base = { ["0"] = { materials = { cloth = true } } } },
    groups = { Lock = { is_global = true, default_preset = "On", presets = {
        On = { ["0"] = { materials = { cloth = true } } },
        Off = { ["0"] = { materials = { cloth = false } } }
    } } }
}
local a, b = { hidden = true }, { hidden = false }
local chars, outputs, last = { a, b }, {}, {}
local env = setmetatable({
    GamePresets = GamePresets,
    PresetSelection = require("ArmorVariantManager_Core.Presets.Selection"),
    actor_runtime = require("ArmorVariantManager_Core.Runtime.State").new(),
    GroundClippingFix = require("ArmorVariantManager_Core.GroundClippingFix"),
    active_overrides = {}, active_group_presets = {},
    get_all_characters = function() return chars end,
    get_local_player_character = function() return a end,
    get_character_body_id = function(char) return char.body or "armor" end,
    get_character_weapon_id = function() return nil end,
    load_config_data = function() return config end,
    sdk = { is_managed_object = function() return true end },
    ground_clipping_presets = { set_runtime = function() end },
    apply_preset_to_armor = function(char, data) outputs[char] = S.copy(data) end,
}, { __index = _G })
env.merge_preset_into_overrides = function(id, data) GamePresets.merge_into(env.active_overrides[id], data) end
env.merge_global_preset_into_overrides = function(id, data) GamePresets.merge_global_into(env.active_overrides[id], data) end
env.apply_all_defaults = function(id)
    env.active_overrides[id] = S.copy(config.presets.Base)
    env.active_group_presets[id] = { [""] = "Base", Lock = "On" }
end
env.apply_transform_rules_for_character = function(_, char, base)
    local target = char.hidden and "Off" or "On"
    local changed = last[char] ~= target
    last[char] = target
    return GamePresets.merge(base, config.groups.Lock.presets[target]), changed, { Lock = target }, { Lock = true }
end
local helpers = S.section(source, "-- 辅助函数：变身规则激活", "-- 辅助函数：获取当前分组的预设数据")
local helper_name = "resolve_character_overrides"
env[helper_name] = assert(load(helpers .. "\nreturn " .. helper_name, "actual-resolve", "t", env))()
env.Processor = require("ArmorVariantManager_Core.Runtime.Processor")
local processor_source = S.section(source, "local process_character = Processor.new", "re.on_frame(function()")
env.process_character = assert(load(processor_source .. "\nreturn process_character", "actual-processor", "t", env))()
local body = S.section(source, "    -- 遍历所有角色并应用规则引擎", "\nend)\n-- =============================================================================\n-- UI 绘制")
local frame = assert(load(body, "actual-frame", "t", env))
frame(); frame()
assert(outputs[a]["0"].materials.cloth == false, "Actor A must retain its global hide when actor B shares the armor")
assert(outputs[b]["0"].materials.cloth == true, "Actor B must retain its own global show")
S.equal(env.active_overrides.armor, config.presets.Base, "manual baseline")
assert(env.active_group_presets.armor.Lock == "On", "Conditions must not overwrite manual selections")
print("PASS: actual frame isolates same-armor global condition state")

local runtime = env.actor_runtime
local state_a = runtime:peek(tostring(a), "armor", "armor", config)
local state_b = runtime:peek(tostring(b), "armor", "armor", config)
assert(state_a ~= state_b and state_a.groups.Lock == "Off" and state_b.groups.Lock == "On")
a.hidden = false; b.hidden = true
frame()
assert(outputs[a]["0"].materials.cloth and not outputs[b]["0"].materials.cloth, "Both actors roll back independently")
local weapon_state = runtime:get(tostring(a), "weapon", "armor", config)
assert(weapon_state ~= state_a and weapon_state.groups == nil, "Same ID in different slots must not share state")
a.body = "replacement"
frame()
assert(runtime:peek(tostring(a), "armor", "armor", config) == nil, "Equipment change discards old context")
assert(runtime:peek(tostring(a), "armor", "replacement", config) ~= state_a)
chars = { a }; frame()
assert(runtime:peek(tostring(b), "armor", "armor", config) == nil, "Departed actor state is released")
chars = { a, b }; frame()
assert(runtime:peek(tostring(b), "armor", "armor", config) ~= state_b, "Returning actor gets fresh state")
local replaced = runtime:get(tostring(a), "armor", "replacement", {})
assert(replaced.overrides == nil, "Replacing config discards stale results")
runtime:clear()
assert(runtime:peek(tostring(b), "armor", "armor", config) == nil, "Scene reset releases every actor")

-- 验证单角色合成顺序与条件结束后的全局选择回退。
local Selection = env.PresetSelection
local selected, rebuild = Selection.resolve_groups(config, { Lock = "Off" }, nil, { Lock = true })
assert(rebuild and selected.Lock == "On", "Inactive targeted global group falls back to default")
selected, rebuild = Selection.resolve_groups(config, { Lock = "Off" }, nil, nil)
assert(not rebuild and selected.Lock == "Off", "Unrelated manual global selection survives")
config.groups.Local = { default_preset = "Hide", presets = {
    Hide = { ["0"] = { materials = { cloth = false } } },
    Show = { ["0"] = { materials = { cloth = true } } }
} }
local height = { enabled = true, height_cm = 17 }
local composed = Selection.compose(config, { Lock = "On" }, { Local = "Show" }, { ground_clipping_fix = height }, GamePresets)
assert(composed["0"].materials.cloth == true and composed.ground_clipping_fix == height)
composed = Selection.compose(config, { Lock = "Off" }, { Local = "Show" }, {}, GamePresets)
assert(composed["0"].materials.cloth == false, "Global hide wins after ordinary rule targets")
print("PASS: actor/slot/equipment/config lifecycle and global selection composition")
-- 普通条件不能突破手动全局隐藏；菜单演员不继承其他猎人的结果。
env.active_group_presets.armor.Lock = "Off"
env.apply_transform_rules_for_character = function(_, char, base)
    return GamePresets.merge(base, { ["0"] = { materials = { cloth = true } } }), true, {}, {}
end
local result = env.resolve_character_overrides("armor", config, b, "armor")
assert(result["0"].materials.cloth == false)
S.equal(env.active_overrides.armor, config.presets.Base, "manual baseline after ordinary condition")
env.apply_transform_rules_for_character = function(_, char, base) return base, false end
env.active_group_presets.armor.Lock = "On"
result = env.resolve_character_overrides("armor", config, b, "armor")
assert(result["0"].materials.cloth == true, "No-combat actor only uses manual baseline")

-- 帧循环确实分别处理防具/武器；卸下武器时清掉该槽位。
local weapon_output
b.weapon = "wp01"
env.get_character_weapon_id = function(char) return char.weapon, char.weapon and {} end
env.apply_preset_to_weapon = function(char, objects, data) weapon_output = S.copy(data) end
frame()
assert(weapon_output and runtime:peek(tostring(b), "weapon", "wp01", config))
b.weapon = nil; frame()
assert(runtime:peek(tostring(b), "weapon", "wp01", config) == nil)

-- 界面读取本地角色快照而不是最后处理的远端角色；配置替换后退回手动选择。
env.loaded_configs = { armor = config }
env.is_weapon_id = function(id) return id:sub(1, 2) == "wp" end
local display_source = S.section(source, "local function get_effective_group_presets", "-- =============================================================================\n-- 预设和分组 UI")
local display = assert(load(display_source .. "\nreturn get_effective_group_presets", "actual-display", "t", env))()
a.body = nil
local a_context = runtime:get(tostring(a), "armor", "armor", config)
a_context.groups = { Lock = "Off" }
assert(display("armor").Lock == "Off")
env.loaded_configs.armor = {}
assert(display("armor").Lock == "On")

-- 实际材质写入：远端结果不再被 UI 本地角色的全局锁二次覆盖。
local material = false
local mesh = { call = function(_, method, index, value)
    if method == "get_MaterialNum" then return 1 end
    if method == "getMaterialName" then return "cloth" end
    if method == "getMaterialsEnable" then return material end
    if method == "setMaterialsEnable" then material = value; return end
    error(method)
end }
local render_env = setmetatable({
    sdk = env.sdk, type_mesh = {}, applied_parts_cache = {},
    safe_get_game_object = function(char) return char end,
    get_character_part_meshes = function() return { mesh } end,
    is_globally_hidden = function() return true end,
    is_material_in_current_context = function() return true end,
}, { __index = _G })
render_env.materials = assert(loadfile("ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Wilds/Materials.lua", "t", render_env))()
    .new({ part_meshes = render_env.get_character_part_meshes }, render_env.safe_get_game_object)
local render_source = S.section(source, "local function apply_preset_to_armor", "-- 辅助函数：应用指定预设到指定角色的武器")
local render = assert(load(render_source .. "\nreturn apply_preset_to_armor", "actual-render", "t", render_env))()
render(b, config.presets.Base, true, true)
assert(material, "Actor result must not use local UI hide lock")
render(b, config.presets.Base, false, true)
assert(not material, "Local UI edits still respect hide lock")
print("PASS: ordinary/global precedence, weapon removal, local display and actual material write")

-- 全局组重算保留本角色已经按优先级求出的高度（包括显式零值）。
for _, height in ipairs({ 17, 0 }) do
    env.apply_transform_rules_for_character = function(_, char, base)
        local result = S.copy(base)
        result.ground_clipping_fix = { enabled = true, height_cm = height }
        return result, true, { Lock = "Off" }, { Lock = true }
    end
    result = env.resolve_character_overrides("armor", config, b, "armor")
    assert(result.ground_clipping_fix.enabled and result.ground_clipping_fix.height_cm == height)
    assert(env.active_overrides.armor.ground_clipping_fix == nil)
end
print("PASS: global recomposition preserves per-actor conditional height and checked zero")

-- 共用选择合成保留两游戏对全局显示项的区别。
local fill_config = { groups = { Global = { is_global = true, default_preset = "Show",
    presets = { Show = { ["0"] = { materials = { cloth = true } } } } } } }
local wilds = Selection.compose(fill_config, {}, {}, {}, GamePresets)
local rise = Selection.compose(fill_config, {}, {}, {}, require("ArmorVariantManager_Core.Games.Rise.Presets"))
assert(wilds["0"].materials.cloth == true and rise["0"].materials.cloth == nil)

-- 新界面上下文与分组切换同样读取本地角色快照。
env.loaded_configs.armor = config
env.get_effective_group_presets = display
env.get_body_id = function() return "armor" end
env.current_config, env.current_group_name = config, "Lock"
env.preset_names_list, env.group_names_list = { "On", "Off" }, { "Lock" }
env.selected_preset_index = 1
env.config_session = require("ArmorVariantManager_Core.Config.Session").new(
    require("ArmorVariantManager_Core.Games.Wilds.Config"))
local ui_source = S.section(source, "    get_context = function()", "    -- 判断配置中是否已有任意预设")
local ui_context = assert(load("return {" .. ui_source .. "}", "actual-ui-context", "t", env))().get_context
assert(ui_context().selected_preset_name == "Off")
assert(env.selected_preset_index == 2)
local group_source = S.section(source, "    select_group = function(group_name)", "    select_preset = function(index)")
env.variant_manager_ui = {}
env.update_preset_names_list = function() end
env.selected_preset_index = 1
local select_group = assert(load("return {" .. group_source .. "}", "actual-ui-group", "t", env))().select_group
select_group("Lock")
assert(env.selected_preset_index == 2)
print("PASS: shared game policies and actual UI context/group selection")

local editor_selection
local editor_source = S.section(source, "local function get_ground_clipping_settings()", "local function set_ground_clipping_settings")
env.ground_clipping_presets.get_editor = function(_, _, _, selected) editor_selection = selected end
assert(load(editor_source .. "\nreturn get_ground_clipping_settings", "actual-height-editor", "t", env))()()
assert(editor_selection == "Off", "Height editor follows displayed local preset")
