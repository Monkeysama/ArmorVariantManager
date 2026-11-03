local mod_name = "ArmorVariantManager"
-- 开发中遵守
-- 版本号-开发状态-开发状态标识
local version = "4.3.4"
local author = "MK,Moon,AZUSA,Ensicht"

-- =============================================================================
-- 多语言与全局配置系统
-- =============================================================================

-- 全局配置路径
local global_config_path = "ArmorVariantManager/GlobalSettings.json"

-- 默认全局配置
local global_config = {
    language = "zh", -- 默认语言: zh (中文), en (英文)
    scan_interval = 0.5, -- 全量扫描间隔 (秒)
    body_id_ttl = 1.0, -- Body ID 缓存有效期 (秒)，默认缩短以加速换装检测
    scanner_batch_size = 200, -- 每帧扫描的对象数量
    new_ui_enabled = true, -- 是否启用新UI
    new_ui_key = 0x24, -- 新UI快捷键，默认 Home
    auto_set_selected_preset_as_default = true -- 选中预设时自动保存为默认预设
}

-- 本地化字典 (从外部模块加载)
local Localization = require("ArmorVariantManager_Core.Localization")
local TransformManager = require("ArmorVariantManager_Core.TransformManager")
local ConfigStore = require("ArmorVariantManager_Core.Config.Store")
local ConfigSession = require("ArmorVariantManager_Core.Config.Session")
local GameConfig = require("ArmorVariantManager_Core.Games.Wilds.Config")
-- REFramework 重载脚本时可能保留 Lua 模块缓存，新UI必须重新加载最新实现。
local refd2d_module_names = {
    "ArmorVariantManager_Core.PortraitCamera",
    "ArmorVariantManager_Core.PortraitModel",
    "ArmorVariantManager_Core.PortraitPreview",
    "ArmorVariantManager_Core.GroundClippingFix",
    "ArmorVariantManager_Core.GroundClippingTargets",
    "ArmorVariantManager_Core.UI.VariantManagerUI",
    "ArmorVariantManager_Core.Documentation",
    "ArmorVariantManager_UI",
    "ArmorVariantManager_UI.Component.Runtime",
    "ArmorVariantManager_UI.Component.Button",
    "ArmorVariantManager_UI.Component.Checkbox",
    "ArmorVariantManager_UI.Component.Input",
    "ArmorVariantManager_UI.Component.InputNumber",
    "ArmorVariantManager_UI.Component.List",
    "ArmorVariantManager_UI.Component.Panel",
    "ArmorVariantManager_UI.Component.Select",
    "ArmorVariantManager_UI.Component.Slider",
    "ArmorVariantManager_UI.Component.Tag",
    "ArmorVariantManager_UI.Component.Window",
    "ArmorVariantManager_UI.Service.BridgeRuntime",
    "ArmorVariantManager_UI.Service.DrawTransform",
    "ArmorVariantManager_UI.Service.InputBlocker",
    "ArmorVariantManager_UI.Service.NativeTextInput"
}
if package and package.loaded then
    for _, module_name in ipairs(refd2d_module_names) do
        package.loaded[module_name] = nil
    end
end
local VariantManagerUI = require("ArmorVariantManager_Core.UI.VariantManagerUI")
local GroundClippingFix = require("ArmorVariantManager_Core.GroundClippingFix")
local GroundClippingTargets = require("ArmorVariantManager_Core.GroundClippingTargets")
local GamePresets = require("ArmorVariantManager_Core.Games.Wilds.Presets")
local PresetGroups = require("ArmorVariantManager_Core.Presets.Groups")
local PresetEditor = require("ArmorVariantManager_Core.Presets.Editor")
local Processor = require("ArmorVariantManager_Core.Runtime.Processor")

-- 获取本地化字符串
local function T(key)
    if not key then return "nil" end
    local lang = global_config.language or "en"
    if not Localization[lang] then lang = "en" end
    return Localization[lang][key] or tostring(key)
end

local safe_json_load = ConfigStore.load
local safe_json_save = ConfigStore.save

-- 加载全局配置
local function load_global_settings()
    local loaded = safe_json_load(global_config_path)
    if type(loaded) == "table" then
        -- 新增镜头选项按需读取，保存常规设置时也保留旧文件中的未知扩展字段。
        for key, value in pairs(loaded) do
            if global_config[key] == nil then global_config[key] = value end
        end
        if loaded.language then global_config.language = loaded.language end
        if loaded.scan_interval then global_config.scan_interval = loaded.scan_interval end
        if loaded.body_id_ttl then global_config.body_id_ttl = loaded.body_id_ttl end
        if loaded.scanner_batch_size then global_config.scanner_batch_size = loaded.scanner_batch_size end
        -- 新字段使用可选读取，旧版 GlobalSettings.json 无需迁移。
        if loaded.new_ui_enabled ~= nil then global_config.new_ui_enabled = loaded.new_ui_enabled end
        if loaded.new_ui_key then global_config.new_ui_key = loaded.new_ui_key end
        if loaded.auto_set_selected_preset_as_default ~= nil then
            global_config.auto_set_selected_preset_as_default = loaded.auto_set_selected_preset_as_default == true
        end
    end
end

-- 保存全局配置
local function save_global_settings()
    safe_json_save(global_config_path, global_config)
end

-- 初始化加载
load_global_settings()

-- =============================================================================

local type_mesh = nil
local SceneObject = require("ArmorVariantManager_Core.Games.Wilds.SceneObject")
local Actors = require("ArmorVariantManager_Core.Games.Wilds.Actors")
local scene_object = SceneObject.new()
local safe_get_game_object = scene_object.game_object
local actors

-- 状态变量
local show_window = true
local last_body_id = nil
-- BODY_ID_CACHE_TTL 已移至全局配置 global_config.body_id_ttl
local config_session = ConfigSession.new(GameConfig, TransformManager.refresh_config_rules)
local loaded_configs = config_session.cache
local temp_applied_presets = {} -- 记录当前临时应用的预设 (BodyID -> PresetName)
local runtime_guard, variant_manager_ui

-- 只接受本轮 PlayerManager 提供的真实玩家。
local function can_use_transform(character)
    return actors.can_transform(character)
end

local function is_weapon_id(id)
    return id and (string.match(id, "^wp%d%d") ~= nil or string.match(id, "^it%d%d%d%d") ~= nil)
end

local appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance").new({
    load = config_session.load,
    rules = TransformManager,
    can_transform = can_use_transform,
    game_object = safe_get_game_object,
    is_weapon_id = is_weapon_id,
})
local active_overrides, active_group_presets = appearance.overrides, appearance.groups
local actor_runtime, ground_clipping_presets = appearance.state, appearance.height

-- 保留既有调用入口和四返回值。
local function apply_transform_rules_for_character(config, character, overrides, merge_fn)
    return appearance.transform(config, character, overrides, merge_fn)
end

-- 当前 Body 的配置数据结构 (用于 UI 编辑):
-- {
--   default_preset = "PresetName",
--   presets = {
--     ["PresetName"] = { ... part_data ... },
--     ...
--   }
-- }
local create_default_parallel_settings = GameConfig.default_parallel_settings

local current_config = {
    default_preset = "",
    presets = {},
    groups = {},
    transform_type = "hp",
    is_parallel = false,
    parallel_settings = create_default_parallel_settings(),
    transform_rules = {},
    weapon_transform_rules = {
        { state = "sheathed", targets = {} },
        { state = "drawn", targets = {} }
    },
    spirit_transform_rules = {
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} },
        { level = 4, targets = {} }
    },
    dual_blades_transform_rules = {
        { state = "normal", targets = {} },
        { state = "kijin", targets = {} },
        { state = "enhancement", targets = {} }
    },
    switch_axe_transform_rules = {
        { state = "sword_normal", targets = {} },
        { state = "sword_awakened", targets = {} },
        { state = "axe_normal", targets = {} },
        { state = "axe_enhanced", targets = {} }
    },
    insect_glaive_transform_rules = {
        { state = "none", targets = {} },
        { state = "white", targets = {} },
        { state = "orange", targets = {} },
        { state = "red", targets = {} },
        { state = "triple", targets = {} }
    },
    charge_blade_transform_rules = {
        { state = "sword", targets = {} },
        { state = "axe", targets = {} },
        { state = "sword_shield", targets = {} },
        { state = "sword_sword", targets = {} },
        { state = "sword_shield_sword", targets = {} },
        { state = "axe_axe", targets = {} },
        { state = "triple", targets = {} }
    },
    greatsword_type_transform_rules = {
        { state = "0", targets = {} },
        { state = "1", targets = {} },
        { state = "2", targets = {} },
        { state = "3", targets = {} },
        { state = "5", targets = {} },
        { state = "other", targets = {} }
    },
    greatsword_level_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    bow_level_transform_rules = {
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} },
        { level = 4, targets = {} }
    },
    hammer_level_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    }
}

-- 部位索引映射表 (用于日志和材质分组预览)
local PART_INDEX_TO_NAME = {
    [0] = "helm",
    [1] = "body",
    [2] = "arm",
    [3] = "waist",
    [4] = "leg",
    [5] = "slinger"
}

-- UI 状态变量
local new_preset_name = ""
local selected_preset_index = 1
local preset_names_list = {}
local auto_find_log = "" -- 用于显示自动查找的调试信息

-- 分组管理状态变量
local current_group_name = "" -- 当前选中的分组名称，空字符串表示主列表
local selected_group_index = 1 -- 分组下拉框选中的索引
local group_names_list = {} -- 分组名称列表
local new_group_name = "" -- 新建分组的名称输入
local new_group_is_global = false -- 新建分组时是否勾选了全局分组
-- 材质细粒度选择状态
local is_selection_mode = false -- 是否处于材质勾选模式
local pending_material_selections = {} -- 临时存储勾选的材质 { [part_idx_str] = { [mat_name] = true } }
-- 材质过滤输入框状态 { [part_index] = "filter_text" }
local mat_filter_text = {}
-- 排序面板状态
local sort_mode = nil -- nil: 不显示, "group": 分组排序, "preset": 预设排序
local sort_temp_list = {} -- 排序临时列表（可自由上下移动）
local sort_selected_index = 1 -- 排序面板中当前选中的项目索引

-- 辅助函数：获取类型定义 (Lazy Load)
local function get_type(name)
    return sdk.find_type_definition(name)
end

-- 辅助函数：深拷贝表
local function deep_copy_table(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deep_copy_table(orig_key)] = deep_copy_table(orig_value)
        end
        setmetatable(copy, deep_copy_table(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local equipment = require("ArmorVariantManager_Core.Games.Wilds.Equipment").new(
    safe_get_game_object, global_config, Actors.preview_names)
local get_character_body_id = equipment.body_id
local get_character_weapon_id = equipment.weapon_id
local meshes = require("ArmorVariantManager_Core.Games.Wilds.Meshes").new(safe_get_game_object, get_type)
local capture_materials = require("ArmorVariantManager_Core.Games.Wilds.Capture").new(meshes, equipment)

-- 场景变化只清运行状态，配置及手动预设选择保持不变。
local function reset_actor_context()
    appearance.reset()
    if variant_manager_ui then variant_manager_ui:invalidate_context() end
end

actors = Actors.new(global_config, scene_object, equipment, meshes, reset_actor_context)
runtime_guard = actors.guard
local tick_scanner = actors.tick
local get_all_characters = actors.all
local get_local_player_character = actors.local_player

local is_weapon_mode = false
-- 仅用于防具/武器模式往返时恢复用户当前分组；普通换装仍按默认分组初始化。
local mode_group_selection = {}
local pending_mode_group_restore = false

-- 辅助函数：获取当前本地玩家 Body 的 ID (Name) - 兼容旧接口
local function get_body_id()
    if is_weapon_mode then
        local id, _ = get_character_weapon_id(get_local_player_character())
        return id
    end
    return get_character_body_id(get_local_player_character())
end

-- 界面展示本地角色的条件结果；编辑基线仍按装备共享。
local function get_effective_group_presets(body_id)
    local character = get_local_player_character()
    local slot = is_weapon_id(body_id) and "weapon" or "armor"
    local context = character and actor_runtime:peek(tostring(character), slot, body_id, loaded_configs[body_id])
    return context and context.groups or active_group_presets[body_id] or {}
end

-- =============================================================================
-- 预设和分组 UI 辅助
-- =============================================================================
-- 辅助函数：更新预设名称列表 (用于 UI)
local function update_preset_names_list()
    preset_names_list = {}
    -- 根据当前分组获取对应的预设列表和排序
    local target_presets = nil
    local target_order = nil
    if current_group_name == "" then
        target_presets = current_config.presets
        target_order = current_config.preset_order
    else
        if current_config.groups and current_config.groups[current_group_name] then
            target_presets = current_config.groups[current_group_name].presets or {}
            target_order = current_config.groups[current_group_name].preset_order
        else
            target_presets = {}
        end
    end
    if target_presets then
        -- 优先按 order 排序，fallback 按字母排序
        if target_order and #target_order > 0 then
            -- 先按 order 中的顺序添加
            local added = {}
            for _, name in ipairs(target_order) do
                if target_presets[name] then
                    table.insert(preset_names_list, name)
                    added[name] = true
                end
            end
            -- 再稳定添加 order 中没有的预设，确保旧 UI 与新 UI 使用同一排序。
            local missing = {}
            for name, _ in pairs(target_presets) do
                if not added[name] then
                    table.insert(missing, name)
                end
            end
            table.sort(missing)
            for _, name in ipairs(missing) do table.insert(preset_names_list, name) end
        else
            for name, _ in pairs(target_presets) do
                table.insert(preset_names_list, name)
            end
            table.sort(preset_names_list)
        end
    end
    -- 2. 自动选中本地角色当前分组的活跃预设，未建立状态时回退默认预设
    local current_body_id = get_body_id and get_body_id() or nil
    local active_preset_name = ""
    if current_body_id then
        active_preset_name = get_effective_group_presets(current_body_id)[current_group_name] or ""
    end
    -- 如果当前角色没有选择记录，回退默认预设
    if active_preset_name == "" then
        if current_group_name == "" then
            active_preset_name = current_config.default_preset or ""
        else
            if current_config.groups and current_config.groups[current_group_name] then
                active_preset_name = current_config.groups[current_group_name].default_preset or ""
            end
        end
    end
    if active_preset_name ~= "" then
        local found = false
        for i, name in ipairs(preset_names_list) do
            if name == active_preset_name then selected_preset_index = i; found = true; break end
        end
        if not found then selected_preset_index = 1 end
    else
        selected_preset_index = 1
    end
    if #preset_names_list == 0 then selected_preset_index = 1
    elseif selected_preset_index > #preset_names_list then selected_preset_index = 1 end
end

-- 辅助函数：更新分组名称列表 (用于 UI)
local function update_group_names_list()
    group_names_list = {}
    if current_config.groups then
        -- 优先按 group_order 排序，fallback 按字母排序
        if current_config.group_order and #current_config.group_order > 0 then
            local added = {}
            for _, name in ipairs(current_config.group_order) do
                if current_config.groups[name] then
                    table.insert(group_names_list, name)
                    added[name] = true
                end
            end
            for name, _ in pairs(current_config.groups) do
                if not added[name] then
                    table.insert(group_names_list, name)
                end
            end
        else
            for name, _ in pairs(current_config.groups) do
                table.insert(group_names_list, name)
            end
            table.sort(group_names_list)
        end
    end
    if #group_names_list == 0 then selected_group_index = 1
    elseif selected_group_index > #group_names_list then selected_group_index = 1 end
end

-- =============================================================================
-- Mesh 和部位相关函数
-- =============================================================================
-- 辅助函数：递归收集 GameObject 及其所有子节点上的 Mesh 组件
-- 改名后的 PFB 可能不再符合原版节点命名规则，因此 Mesh 必须按对象树实际内容查找。
local get_mesh_component_recursive = meshes.first
local get_character_part = meshes.part
local get_character_part_meshes = meshes.part_meshes

-- 辅助函数：检测材质被哪个分组占用（全局组不计入归属，只有普通组才独占材质）
local function get_material_group_owner(part_index, mat_name)
    return PresetGroups.owner(current_config, part_index, mat_name)
end

-- 辅助函数：检测材质被哪些全局分组的 mask 覆盖（用于 UI 提示）
local function get_material_global_groups(part_index, mat_name)
    return PresetGroups.global_names(current_config, part_index, mat_name)
end

-- 切换防具/武器模式前保存当前配置的分组，下一帧加载目标配置后再恢复对应分组。
local function switch_variant_mode(weapon_mode)
    if is_weapon_mode == weapon_mode then return end
    if last_body_id then mode_group_selection[last_body_id] = current_group_name end
    is_weapon_mode = weapon_mode
    last_body_id = nil
    current_group_name = ""
    pending_mode_group_restore = true
    equipment.clear(weapon_mode and "weapon" or "armor")
end

-- 辅助函数：判断材质是否属于当前 UI 上下文 (主列表或当前分组)
local function is_material_in_current_context(part_index, mat_name)
    return PresetGroups.contains(current_config, current_group_name, part_index, mat_name)
end

-- 辅助函数：判断某材质是否被全局分组的当前预设锁定为隐藏
-- 返回 true 表示被全局隐藏，此时不允许将其显示出来
-- 注意：当前上下文本身就是全局分组时不做限制，允许在其内部自由编辑
local function is_globally_hidden(part_index, mat_name)
    -- 在全局分组上下文内操作时，不施加任何限制
    if current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global then
        return false
    end
    if not current_config.groups then return false end
    local s_idx = tostring(part_index)
    local body_id = get_body_id()
    local active_saved = body_id and get_effective_group_presets(body_id) or {}
    for g_name, g_data in pairs(current_config.groups) do
        if g_data.is_global and g_data.mask and g_data.mask[s_idx]
            and g_data.mask[s_idx][mat_name] == true then
            -- 优先用用户当前选中的预设，fallback 到默认预设
            local pname = active_saved[g_name]
            if not pname or pname == "" then pname = g_data.default_preset end
            if pname and pname ~= "" and g_data.presets and g_data.presets[pname] then
                local def = g_data.presets[pname]
                if def[s_idx] and def[s_idx].materials and def[s_idx].materials[mat_name] == false then
                    return true
                end
            end
        end
    end
    return false
end
-- 预设应用函数
-- =============================================================================
-- 仅在准备重新开启 Mesh 时读取原生隐藏状态。非猎人对象沿用原行为；
-- 猎人被原生隐藏且正在帐篷/临时换装时，不用预设强行显示。
local materials = require("ArmorVariantManager_Core.Games.Wilds.Materials").new(meshes, safe_get_game_object)

-- 旧调用入口保留；角色完整结果不受当前 UI 分组筛选影响。
local function apply_preset_to_armor(character, preset_data, ignore_context, force_apply)
    return materials.armor(character, preset_data,
        not ignore_context and is_material_in_current_context or nil,
        not ignore_context and is_globally_hidden or nil)
end

-- 辅助函数：应用指定预设到指定角色的武器
local function apply_preset_to_weapon(character, weapon_objs, preset_data, ignore_context, force_apply)
    return materials.weapon(character, weapon_objs, preset_data,
        not ignore_context and is_material_in_current_context or nil)
end

-- =============================================================================
-- 分组管理
-- =============================================================================
-- 分组管理核心函数
-- 辅助函数：创建材质级新分组
local function create_new_group(group_name, body_id, is_global)
    if not body_id then return false end
    if not PresetGroups.create(current_config, group_name, pending_material_selections, is_global, true) then return false end
    pending_material_selections = {}
    is_selection_mode = false
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

-- 辅助函数：删除材质级分组并归还控制权
local function delete_group(group_name, body_id)
    if not body_id or not PresetGroups.delete(current_config, group_name) then return false end
    if current_group_name == group_name then
        current_group_name = ""
        selected_group_index = 1
        update_preset_names_list()
    end
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

-- =============================================================================
-- 配置加载与保存
-- =============================================================================
-- 辅助函数：仅加载配置数据，不更新 UI 状态
local function load_config_data(body_id)
    return config_session.load(body_id)
end

-- 辅助函数：返回合并后的新复合状态表（不修改原表）
local function merge_overrides(base_data, add_data)
    return GamePresets.merge(base_data, add_data)
end

-- 辅助函数：应用一个 Body ID 的所有默认预设 (主列表 + 所有分组)
-- 合并顺序：主列表 → 普通分组 → 全局分组（最后）
local function apply_all_defaults(body_id)
    return appearance.defaults(body_id)
end

-- 辅助函数：变身规则激活结果仅属于当前角色及装备槽位。
local function resolve_character_overrides(body_id, config, character, slot)
    return appearance.resolve(body_id, config, character, slot)
end

-- 辅助函数：获取当前分组的预设数据
local function get_current_preset_data(preset_name)
    if current_group_name == "" then
        return current_config.presets and current_config.presets[preset_name]
    else
        if current_config.groups and current_config.groups[current_group_name] then
            return current_config.groups[current_group_name].presets and current_config.groups[current_group_name].presets[preset_name]
        end
    end
    return nil
end

-- 辅助函数：应用指定预设 (兼容旧接口，针对所有玩家)
local function apply_preset(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_body_id = get_body_id()
    if current_body_id then
        appearance.select(current_body_id, current_config, current_group_name, preset_name)
        temp_applied_presets[current_body_id] = preset_name
    end
    local all_chars = get_all_characters()
    -- 本地玩家是预设切换的直接目标；在装备箱/菜单等场景中，异步扫描缓存可能暂时漏掉它，
    -- 因此强制把本地角色补入本帧列表，保证自定义 Body ID 也能立即应用预设。
    local local_char_for_preset = get_local_player_character()
    if local_char_for_preset and sdk.is_managed_object(local_char_for_preset) then
        local local_seen = false
        for _, listed_char in ipairs(all_chars) do
            if listed_char == local_char_for_preset then
                local_seen = true
                break
            end
        end
        if not local_seen then
            table.insert(all_chars, local_char_for_preset)
        end
    end
    for _, char in ipairs(all_chars) do
        if is_weapon_id(current_body_id) then
            local char_weapon_id, w_objs = get_character_weapon_id(char)
            if char_weapon_id and char_weapon_id == current_body_id then
                local config = load_config_data(char_weapon_id)
                local new_overrides = resolve_character_overrides(char_weapon_id, config, char, "weapon")
                apply_preset_to_weapon(char, w_objs, new_overrides, true, true)
            end
        else
            local char_body_id = get_character_body_id(char)
            if char_body_id and char_body_id == current_body_id then
                local config = load_config_data(char_body_id)
                local new_overrides = resolve_character_overrides(char_body_id, config, char, "armor")
                apply_preset_to_armor(char, new_overrides, true, true)
            end
        end
    end
end

-- 辅助函数：加载指定 Body ID 的配置 (用于 UI 和本地玩家)
local function load_body_config(body_id)
    if not body_id then return false end
    -- 1. 重置当前内存配置，确保切换到新 Body 时不残留旧数据
    current_config = {
        default_preset = "",
        presets = {},
        groups = {},
        transform_type = "hp",
        is_parallel = false,
        parallel_settings = create_default_parallel_settings(),
        transform_rules = {},
        weapon_transform_rules = {
            { state = "sheathed", targets = {} },
            { state = "drawn", targets = {} }
        },
        spirit_transform_rules = {
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} },
            { level = 4, targets = {} }
        },
        dual_blades_transform_rules = {
            { state = "normal", targets = {} },
            { state = "kijin", targets = {} },
            { state = "enhancement", targets = {} }
        },
        switch_axe_transform_rules = {
            { state = "sword_normal", targets = {} },
            { state = "sword_awakened", targets = {} },
            { state = "axe_normal", targets = {} },
            { state = "axe_enhanced", targets = {} }
        },
        insect_glaive_transform_rules = {
            { state = "none", targets = {} },
            { state = "white", targets = {} },
            { state = "orange", targets = {} },
            { state = "red", targets = {} },
            { state = "triple", targets = {} }
        },
        charge_blade_transform_rules = {
            { state = "sword", targets = {} },
            { state = "axe", targets = {} },
            { state = "sword_shield", targets = {} },
            { state = "sword_sword", targets = {} },
            { state = "sword_shield_sword", targets = {} },
            { state = "axe_axe", targets = {} },
            { state = "triple", targets = {} }
        },
        greatsword_type_transform_rules = {
            { state = "0", targets = {} },
            { state = "1", targets = {} },
            { state = "2", targets = {} },
            { state = "3", targets = {} },
            { state = "5", targets = {} },
            { state = "other", targets = {} }
        },
        greatsword_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        bow_level_transform_rules = {
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} },
            { level = 4, targets = {} }
        },
        hammer_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        }
    }
    -- 2. 尝试加载数据
    local data = load_config_data(body_id)
    if data then
        current_config = data
        -- 写入缓存，避免重复尝试加载
        loaded_configs[body_id] = current_config
    end
    -- 3. 始终更新 UI 列表索引和名称列表，即使加载失败也要清除 UI
    update_group_names_list()
    update_preset_names_list()
    if data then
        -- 核心修复：调用 apply_all_defaults 进行全量合并加载
        apply_all_defaults(body_id)
        return true
    end
    return false
end

-- 辅助函数：保存配置到文件
local function save_current_config_to_file(body_id, preserve_active_state)
    if not body_id then return end
    -- 新旧 UI 的规则、预设和分组修改都走此处，避免摘要在编辑后继续沿用旧结果。
    if not preserve_active_state then TransformManager.refresh_config_rules(current_config) end
    if not config_session.save(body_id, current_config) then return false end
    -- 允许调用方仅持久化数据，不重置用户当前选中的分组、预设与变身状态。
    if preserve_active_state then return true end
    -- 清除 active_overrides 缓存，强制下一帧重新合并所有默认预设
    if active_overrides[body_id] then
        active_overrides[body_id] = nil
    end
    -- 清除 active_group_presets 缓存，确保下一帧 apply_all_defaults 使用配置中的默认预设，
    -- 避免变身规则之前设置的全局分组预设残留导致状态不一致
    active_group_presets[body_id] = nil
    
    -- 清除状态机缓存，强制下一帧重新应用最新的预设内容
    if TransformManager.clear_last_state_cache then
        TransformManager.clear_last_state_cache()
    end
    return true
end

-- 将指定预设写为当前分组的默认预设，供旧 UI、新 UI 和自动保存开关共用。
local function set_preset_as_default(preset_name, body_id)
    if not body_id or not preset_name or preset_name == "" or not current_config then return false end
    if not PresetEditor.set_default(current_config, current_group_name, preset_name, function(preserve)
        return save_current_config_to_file(body_id, preserve)
    end) then return false end
    update_preset_names_list()
    return true
end

-- 删除与排序都通过编辑层保存，失败时保留原配置。
local function delete_preset(preset_name, body_id)
    if not body_id or not preset_name or preset_name == "" or not current_config then return false end
    local saved = PresetEditor.delete(current_config, current_group_name, preset_name, function(preserve)
        return save_current_config_to_file(body_id, preserve)
    end)
    update_preset_names_list()
    return saved
end

local function reorder_presets(names, body_id)
    if not body_id or not current_config then return false end
    local saved = PresetEditor.reorder(current_config, current_group_name, names, function(preserve)
        return save_current_config_to_file(body_id, preserve)
    end)
    update_preset_names_list()
    return saved
end

local function reorder_groups(names, body_id)
    if not body_id or not current_config then return false end
    local saved = PresetEditor.reorder_groups(current_config, names, function(preserve)
        return save_current_config_to_file(body_id, preserve)
    end)
    update_group_names_list()
    return saved
end

-- 开启自动保存时立即持久化当前选中预设，避免开关状态和当前默认预设不一致。
local function auto_set_selected_preset_as_default(body_id)
    if not global_config.auto_set_selected_preset_as_default then return false end
    return set_preset_as_default(preset_names_list[selected_preset_index], body_id)
end

-- 辅助函数：从备份恢复配置
-- 将 backup/<id>.json 的内容写回主配置文件并刷新内存状态，
-- 用于 mod 重装后一键还原玩家手动调整过的预设。
local function restore_config_from_backup(body_id)
    if not config_session.restore(body_id) then return false end
    active_overrides[body_id] = nil
    active_group_presets[body_id] = nil
    -- 重新加载并刷新 UI
    local data = load_config_data(body_id)
    if data then
        current_config = data
        update_group_names_list()
        update_preset_names_list()
        apply_all_defaults(body_id)
    end
    if TransformManager.clear_last_state_cache then
        TransformManager.clear_last_state_cache()
    end
    return true
end

-- 辅助函数：捕获当前状态为新预设
local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_body_id() end
    if not body_id then return false end
    local character = get_local_player_character()
    if not character then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = capture_materials(character, current_config, current_group_name,
        active_overrides[body_id], is_weapon_id(body_id), is_material_in_current_context)
    -- 与当前分组的材质状态一起捕获高度草稿；武器预设不保存防具修复。
    if not is_weapon_id(body_id) then
        local group = current_group_name == "" and current_config or current_config.groups[current_group_name]
        local selected = get_effective_group_presets(body_id)[current_group_name]
            or group and group.default_preset
        new_preset_data.ground_clipping_fix = ground_clipping_presets.get_editor(
            current_config, body_id, current_group_name, selected)
    end
    local saved = PresetEditor.write(current_config, current_group_name, preset_name, new_preset_data, function(preserve)
        return save_current_config_to_file(body_id, preserve)
    end)
    update_preset_names_list()
    return saved
end

-- 辅助函数：自动查找匹配的预设
local function find_auto_preset(target_body_id)
    if not target_body_id then return false, "No Body ID" end
    local character = get_local_player_character()
    if not character or not sdk.is_managed_object(character) then return false, "No Character" end
    local is_weapon_target = is_weapon_id(target_body_id)
    local current_mats = {}
    local current_weapon_mats = {}

    -- 防具读取身体部位材质；武器分别读取各部件材质，避免跨类型匹配。
    if is_weapon_target then
        local current_weapon_id, weapon_objs = get_character_weapon_id(character)
        if current_weapon_id ~= target_body_id or not weapon_objs or #weapon_objs == 0 then
            return false, "Weapon not found"
        end
        for index, weapon_obj in ipairs(weapon_objs) do
            local mesh = get_mesh_component_recursive(weapon_obj)
            if mesh then
                local mats = {}
                local mat_count = mesh:call("get_MaterialNum") or 0
                for material_index = 0, mat_count - 1 do
                    local name = mesh:call("getMaterialName", material_index)
                    if name then mats[name] = true end
                end
                if next(mats) then current_weapon_mats[tostring(index - 1)] = mats end
            end
        end
        if not next(current_weapon_mats) then return false, "No materials on Weapon" end
    else
        local body_part = get_character_part(character, 1) -- 1 is Body
        if not body_part then return false, "Body part not found" end
        local mesh = get_mesh_component_recursive(body_part)
        if not mesh then return false, "Mesh not found" end
        local mat_count = mesh:call("get_MaterialNum")
        if not mat_count or mat_count == 0 then return false, "No materials on Body" end
        for i = 0, mat_count - 1 do
            local name = mesh:call("getMaterialName", i)
            if name then current_mats[name] = true end
        end
    end
    -- 2. 遍历所有 JSON 文件
    if not fs or not fs.glob then return false, "fs.glob missing" end
    -- 尝试更广泛的搜索路径，包含反斜杠版本
    -- 注意：fs.glob 使用正则表达式，因此必须使用 valid regex syntax
    -- * -> .*
    -- . -> \.
    local search_patterns = {
        "reframework/data/ArmorVariantManager/.*\\.json",
        "reframework\\\\data\\\\ArmorVariantManager\\\\.*\\.json",
        "ArmorVariantManager/.*\\.json",
        "ArmorVariantManager\\\\.*\\.json",
        "data/ArmorVariantManager/.*\\.json"
    }
    local files = {}
    for _, pattern in ipairs(search_patterns) do
        local found = fs.glob(pattern)
        if found and #found > 0 then
            for _, f in ipairs(found) do table.insert(files, f) end
        end
    end
    if #files == 0 then return false, "No preset files found" end
    for _, file in ipairs(files) do
        -- 排除自身
        if not string.find(file, target_body_id) then
            -- 路径处理：json.load_file 通常需要相对于 reframework/data 的路径
            -- 如果 file 包含 reframework/data，尝试截取
            local load_path = file
            local data_prefix = "reframework\\data\\"
            local s, e = string.find(file, data_prefix)
            if not s then
                data_prefix = "reframework/data/"
                s, e = string.find(file, data_prefix)
            end
            if e then load_path = string.sub(file, e + 1) end
            local data = safe_json_load(load_path)
            if not data then data = safe_json_load(file) end
            if data and data.presets then
                -- 获取第一个预设
                local first_preset = nil
                for _, preset in pairs(data.presets) do first_preset = preset; break end
                if is_weapon_target then
                    -- 只匹配武器 ID 文件，并逐部件检查预设材质是否存在于当前武器。
                    local normalized_file = file:gsub("\\", "/")
                    local candidate_id = normalized_file:match("([^/]+)%.json$")
                    local match = candidate_id and is_weapon_id(candidate_id) and first_preset ~= nil
                    local match_count = 0
                    if match then
                        for part_index, part_data in pairs(first_preset) do
                            local preset_mats = part_data and part_data.materials
                            if preset_mats and next(preset_mats) then
                                local weapon_mats = current_weapon_mats[tostring(part_index)]
                                if not weapon_mats then match = false; break end
                                for mat_name, _ in pairs(preset_mats) do
                                    if not weapon_mats[mat_name] then match = false; break end
                                    match_count = match_count + 1
                                end
                                if not match then break end
                            end
                        end
                    end
                    if match and match_count > 0 then
                        current_config = data
                        save_current_config_to_file(target_body_id)
                        update_preset_names_list()
                        return true, "Success! Loaded from " .. file
                    end
                -- 检查防具 Body (1) 的材质匹配度
                elseif first_preset and first_preset["1"] and first_preset["1"].materials then
                    local preset_mats = first_preset["1"].materials
                    local match = true
                    local match_count = 0
                    for mat_name, _ in pairs(preset_mats) do
                        if not current_mats[mat_name] then match = false; break end
                        match_count = match_count + 1
                    end
                    if match and match_count > 0 then
                        -- 找到匹配！
                        current_config = data
                        save_current_config_to_file(target_body_id)
                        update_preset_names_list()
                        return true, "Success! Loaded from " .. file
                    end
                end
            end
        end
    end
    return false, "No matching preset found"
end

-- 辅助函数：安全地获取组件并控制可见性
local function draw_mesh_toggle(game_object, label, body_id, part_index)
    if not game_object then return end
    if not sdk.is_managed_object(game_object) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then
            imgui.text_colored(label .. " " .. T("type_loading"), 0xFF808080)
            return
        end
    end
    -- 获取 Mesh 组件
    local mesh_component = game_object:call("getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh_component then
        if imgui.tree_node(label) then
            -- 1. 整体 Mesh 开关
            local is_enabled = mesh_component:call("get_Enabled")
            local changed, new_value = imgui.checkbox(T("enable_mesh"), is_enabled)
            if changed then
                mesh_component:call("set_Enabled", new_value)
                -- 更新 active_overrides
                if body_id and part_index then
                    local s_idx = tostring(part_index)
                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                    active_overrides[body_id][s_idx].mesh_enabled = new_value
                end
            end

            -- 2. 遍历材质
            local mat_count = mesh_component:call("get_MaterialNum")
            if mat_count and mat_count > 0 then
                local s_idx = tostring(part_index)

                -- 辅助：判断某材质在当前模式下是否"可操作"（过滤后可见且未被普通分组占用）
                local function mat_is_operable(mn)
                    local flt = mat_filter_text[part_index] or ""
                    if flt ~= "" and not string.find(string.lower(mn), string.lower(flt), 1, true) then
                        return false
                    end
                    if is_selection_mode then
                        return get_material_group_owner(part_index, mn) == nil
                    else
                        return is_material_in_current_context(part_index, mn)
                    end
                end

                -- 全选 / 反选 / 过滤框：与"启用模型"checkbox 同行
                imgui.same_line()
                if imgui.button(T("select_all") .. "##sa_" .. s_idx) then
                    -- 收集所有可操作材质的当前状态
                    local all_on = true
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not (pending_material_selections[s_idx] and pending_material_selections[s_idx][mn]) then
                                    all_on = false; break
                                end
                            else
                                -- 优先用意图值判断全选状态
                                local intent = (active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mn])
                                local cur_on = (intent ~= nil) and intent or mesh_component:call("getMaterialsEnable", k)
                                if not cur_on then
                                    all_on = false; break
                                end
                            end
                        end
                    end
                    local target_val = not all_on
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                pending_material_selections[s_idx][mn] = target_val or nil
                            else
                                -- 全局隐藏锁：意图值正常存储，渲染时应用锁
                                local render_val
                                if target_val == true and is_globally_hidden(part_index, mn) then
                                    render_val = false
                                else
                                    render_val = target_val
                                end
                                mesh_component:call("setMaterialsEnable", k, render_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = target_val  -- 存意图值
                                end
                            end
                        end
                    end
                end

                imgui.same_line()

                -- 反选按钮：将可操作材质的当前状态取反
                if imgui.button(T("invert_select") .. "##inv_" .. s_idx) then
                    for k = 0, mat_count - 1 do
                        local mn = mesh_component:call("getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                local cur = pending_material_selections[s_idx][mn]
                                pending_material_selections[s_idx][mn] = (not cur) or nil
                            else
                                local cur = mesh_component:call("getMaterialsEnable", k)
                                local nv = not cur
                                -- 全局隐藏锁：意图值正常存储，渲染时应用锁
                                local render_val
                                if nv == true and is_globally_hidden(part_index, mn) then
                                    render_val = false
                                else
                                    render_val = nv
                                end
                                mesh_component:call("setMaterialsEnable", k, render_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = nv  -- 存意图值
                                end
                            end
                        end
                    end
                end

                -- 过滤输入框（与全选/反选同行）
                imgui.same_line()
                imgui.set_next_item_width(140)
                local flt_cur = mat_filter_text[part_index] or ""
                local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                if flt_changed then mat_filter_text[part_index] = flt_val end
                if flt_cur ~= "" then
                    imgui.same_line()
                    if imgui.button("x##fltclr_" .. s_idx) then mat_filter_text[part_index] = "" end
                end

                -- 材质列表
                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")

                -- 材质列表（过滤后显示）
                local filter_str = string.lower(mat_filter_text[part_index] or "")
                for i = 0, mat_count - 1 do
                    local mat_name = mesh_component:call("getMaterialName", i)
                    if mat_name then
                        -- 过滤：名称不含关键字则跳过
                        if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                            local is_mat_enabled = mesh_component:call("getMaterialsEnable", i)
                            local owner = get_material_group_owner(part_index, mat_name)
                            local global_groups = get_material_global_groups(part_index, mat_name)
                            -- A. 分组创建模式
                            if is_selection_mode then
                                local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                                if owner and not new_group_is_global then
                                    -- 普通分组不能选择已被其他普通分组占用的材质
                                    imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF808080)
                                else
                                    local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                    if changed_sel then
                                        if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                        pending_material_selections[s_idx][mat_name] = new_sel
                                    end
                                    if #global_groups > 0 then
                                        local bid_hint = get_body_id()
                                        local ag_saved = (bid_hint and get_effective_group_presets(bid_hint)) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname = ag_saved[gname]
                                            if not pname or pname == "" then pname = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname and g_data.presets and g_data.presets[pname]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            else
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_visible"), gname), 0xFF80C0FF)
                                            end
                                        end
                                    end
                                end
                            else
                                -- B. 正常管理模式
                                if is_material_in_current_context(part_index, mat_name) then
                                    local mat_label = string.format("[%d] %s", i, mat_name)
                                    -- 优先用 active_overrides 里的意图值显示 checkbox，避免全局锁强制隐藏后 checkbox 跳回未勾选
                                    local intent_val = (active_overrides[body_id]
                                        and active_overrides[body_id][s_idx]
                                        and active_overrides[body_id][s_idx].materials
                                        and active_overrides[body_id][s_idx].materials[mat_name])
                                    local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                    local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                    if mat_changed then
                                        -- 记录用户意图值到 active_overrides（全局锁不影响存储的意图）
                                        if body_id and part_index then
                                            if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                            if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                            if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                            active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                        end
                                        -- 实际渲染时应用全局锁：被全局隐藏的材质始终保持隐藏
                                        local render_val
                                        if mat_new_val == true and is_globally_hidden(part_index, mat_name) then
                                            render_val = false
                                        else
                                            render_val = mat_new_val
                                        end
                                        mesh_component:call("setMaterialsEnable", i, render_val)
                                    end
                                    if #global_groups > 0 then
                                        local bid_hint2 = get_body_id()
                                        local ag_saved2 = (bid_hint2 and get_effective_group_presets(bid_hint2)) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname2 = ag_saved2[gname]
                                            if not pname2 or pname2 == "" then pname2 = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname2 and g_data.presets and g_data.presets[pname2]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            end
                                        end
                                    end
                                else
                                    if current_group_name == "" and owner then
                                        imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF804040)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            imgui.tree_pop()
        end
    else
        -- 如果没有 Mesh 组件，显示禁用状态的文本
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end

-- =============================================================================
-- 新UI
-- 基于原生 UI Runtime 的差分管理器界面。
-- 独立解析战斗、菜单与过场角色；各骨架按自己的防具读取预设，不依赖 MasterPlayer 存在。
local collect_ground_clipping_targets = GroundClippingTargets.new({
    get_scene = function() return runtime_guard:get_scene() end,
    get_game_object = safe_get_game_object
})
local ground_clipping_fix = GroundClippingFix.new({
    is_suspended = function() return runtime_guard.scene_suspended end,
    get_targets = collect_ground_clipping_targets,
    get_status_target = function()
        local object = safe_get_game_object(get_local_player_character(), "ground_clipping_status")
        local transform = object and object:call("get_Transform")
        return transform and transform:get_address()
    end,
    get_settings = function(hunter)
        local body_id = get_character_body_id(hunter)
        if not body_id then return nil end
        local config = not is_weapon_mode and body_id == last_body_id and current_config
            or load_config_data(body_id)
        local base = active_overrides[body_id] and active_overrides[body_id].ground_clipping_fix
        return ground_clipping_presets.get_runtime(hunter, config, base), body_id
    end
})

-- 新旧界面共用预设草稿，实时预览；新增或覆盖预设时才持久化到 JSON 和备份。
local function get_ground_clipping_settings()
    local group = current_group_name == "" and current_config or current_config.groups and current_config.groups[current_group_name]
    local body_id = get_body_id()
    local selected = get_effective_group_presets(body_id)[current_group_name]
        or group and group.default_preset
    return ground_clipping_presets.get_editor(current_config, body_id, current_group_name, selected)
end

local function set_ground_clipping_settings(changes, body_id)
    if is_weapon_mode or not body_id or body_id ~= last_body_id or body_id ~= get_body_id() then return false end
    local group = current_group_name == "" and current_config or current_config.groups and current_config.groups[current_group_name]
    local selected = get_effective_group_presets(body_id)[current_group_name]
        or group and group.default_preset
    local settings = ground_clipping_presets.edit(current_config, body_id, current_group_name, selected, changes)
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    -- 取消勾选只退出本预设的高度控制，不撤销之前的有效高度；归零需勾选并设置 0 cm。
    if settings.enabled then active_overrides[body_id].ground_clipping_fix = settings end
    ground_clipping_fix.settings_changed()
    return true
end

variant_manager_ui = VariantManagerUI.new({
    is_suspended = function() return runtime_guard.suspended end,
    config = global_config,
    translate = T,
    version = version,
    author = author,
    save_settings = save_global_settings,
    get_ground_clipping_settings = get_ground_clipping_settings,
    set_ground_clipping_settings = set_ground_clipping_settings,
    get_ground_clipping_status = ground_clipping_fix.get_status,

    -- 提供新 UI 所需的当前装备上下文。
    get_context = function()
        local body_id = get_body_id()
        -- 初次打开新 UI 时主动对齐当前实际应用预设；活跃状态尚未建立时回退当前分组默认预设。
        local active_preset_name = get_effective_group_presets(body_id)[current_group_name] or ""
        if not active_preset_name or active_preset_name == "" then
            if current_group_name == "" then
                active_preset_name = current_config.default_preset or ""
            else
                local group = current_config.groups and current_config.groups[current_group_name]
                active_preset_name = group and group.default_preset or ""
            end
        end
        if active_preset_name ~= "" then
            for index, preset_name in ipairs(preset_names_list) do
                if preset_name == active_preset_name then
                    selected_preset_index = index
                    break
                end
            end
        end
        return {
            body_id = body_id,
            character = get_local_player_character(),
            weapon_mode = is_weapon_mode,
            group_name = current_group_name,
            group_names = group_names_list,
            preset_names = preset_names_list,
            selected_preset_index = selected_preset_index,
            -- 新 UI 按名称选中，不能在分组切换过渡帧通过旧索引反查上一分组的预设。
            selected_preset_name = active_preset_name ~= "" and active_preset_name
                or preset_names_list[selected_preset_index],
            config_restored = body_id and config_session.pending(body_id),
            config = current_config
        }
    end,

    -- 判断配置中是否已有任意预设，兼容默认分组、普通分组和旧 JSON 缺少排序字段的情况。
    has_any_presets = function(config)
        if config and config.presets and next(config.presets) then return true end
        for _, group in pairs((config and config.groups) or {}) do
            if group.presets and next(group.presets) then return true end
        end
        return false
    end,

    -- 新 UI 直接复用旧 UI 的材质匹配逻辑，避免产生第二套 JSON 查找和保存规则。
    auto_find_preset = function(body_id)
        local ok, found, message = pcall(find_auto_preset, body_id)
        if not ok then return false, tostring(found) end
        return found == true, message
    end,

    -- 备份恢复与忽略继续使用旧 UI 的会话标记，恢复后会自动刷新当前分组和预设列表。
    -- "已处理"标记由 restore_config_from_backup 在写回成功后设置：
    -- 失败时不能提前置位，否则横幅会消失、备份也不再受保护。
    restore_backup = function(body_id)
        if not body_id then return false end
        return restore_config_from_backup(body_id) == true
    end,

    dismiss_backup = function(body_id)
        if not body_id then return end
        config_session.dismiss(body_id)
    end,

    -- 新 UI 切换模式时与旧 UI 共用分组记忆和缓存刷新规则。
    set_mode = function(weapon_mode)
        switch_variant_mode(weapon_mode)
    end,

    -- 新 UI 选择分组后，恢复该分组当前已应用的预设，不强制回退为默认预设。
    select_group = function(group_name)
        group_name = group_name or ""
        -- 换装重建期间列表可能暂时来自上一帧，忽略已经失效的分组名称。
        if group_name ~= "" and (not current_config.groups or not current_config.groups[group_name]) then
            group_name = ""
        end
        current_group_name = group_name
        selected_group_index = 1
        for i, name in ipairs(group_names_list) do
            if name == current_group_name then
                selected_group_index = i + 1
                break
            end
        end
        variant_manager_ui.material_offset = 0
        update_preset_names_list()
        local body_id = get_body_id()
        local active_preset = get_effective_group_presets(body_id)[current_group_name]
        if active_preset and active_preset ~= "" then
            for index, preset_name in ipairs(preset_names_list) do
                if preset_name == active_preset then
                    selected_preset_index = index
                    break
                end
            end
        end
    end,

    select_preset = function(index)
        selected_preset_index = index
    end,

    -- 新 UI 拖动普通分组后写回旧 UI 共用的 group_order。
    reorder_groups = function(items)
        local names = {}
        for _, item in ipairs(items or {}) do
            if item.name and item.name ~= "" then names[#names + 1] = item.name end
        end
        return reorder_groups(names, get_body_id())
    end,

    -- 新 UI 创建分组时复用旧 UI 的材质剥离、全局重叠和 group_order 逻辑。
    create_group = function(group_name, is_global, selections)
        local body_id = get_body_id()
        if not body_id then return false end
        pending_material_selections = selections or {}
        local created = create_new_group(group_name, body_id, is_global == true)
        if created then
            current_group_name = group_name
            selected_group_index = 1
            for i, name in ipairs(group_names_list) do
                if name == current_group_name then selected_group_index = i + 1; break end
            end
            selected_preset_index = 1
            update_group_names_list()
            update_preset_names_list()
        else
            pending_material_selections = {}
        end
        return created == true
    end,

    -- 新 UI 删除分组时复用旧 UI 的配置清理和当前分组回退逻辑。
    delete_group = function(group_name)
        local body_id = get_body_id()
        if not body_id then return false end
        local deleted = delete_group(group_name, body_id)
        if deleted then
            selected_preset_index = 1
            variant_manager_ui.material_offset = 0
            update_group_names_list()
            update_preset_names_list()
        end
        return deleted == true
    end,

    -- 新 UI 拖动预设后写回默认分组或当前分组的 preset_order。
    reorder_presets = function(items)
        return reorder_presets(items, get_body_id())
    end,

    -- 新 UI 新增预设，复用旧 UI 的 save_preset、排序与配置保存逻辑。
    create_preset = function(preset_name)
        local body_id = get_body_id()
        if not body_id or not preset_name or preset_name == "" then return false end
        local saved = save_preset(preset_name, body_id)
        if saved then update_preset_names_list() end
        return saved == true
    end,

    -- 新 UI 覆盖当前预设，保留旧 UI 对分组和全局分组的保存行为。
    overwrite_preset = function(preset_name)
        local body_id = get_body_id()
        if not body_id or not preset_name or preset_name == "" then return false end
        local saved = save_preset(preset_name, body_id)
        if saved then update_preset_names_list() end
        return saved == true
    end,

    -- 新 UI 删除预设，并同步移除默认预设和排序数组中的名称。
    delete_preset = function(preset_name)
        return delete_preset(preset_name, get_body_id())
    end,

    -- 新 UI 设置当前选中预设为默认预设，沿用旧 UI 的分组配置写入规则。
    set_default_preset = function(preset_name)
        return set_preset_as_default(preset_name, get_body_id())
    end,

    -- 新 UI 勾选自动保存后立即写入当前预设，配置本身保存到 GlobalSettings.json。
    set_auto_default_enabled = function(enabled, preset_name, body_id)
        global_config.auto_set_selected_preset_as_default = enabled == true
        save_global_settings()
        if global_config.auto_set_selected_preset_as_default then
            return set_preset_as_default(preset_name, body_id or get_body_id())
        end
        return true
    end,

    -- 新 UI 选择预设后调用，顺序保持与旧 UI 一致：先应用预设，再保存默认预设。
    auto_set_default_preset = function(preset_name, body_id)
        if not global_config.auto_set_selected_preset_as_default then return false end
        return set_preset_as_default(preset_name, body_id or get_body_id())
    end,

    apply_preset = apply_preset,

    -- 新 UI 变身管理复用当前配置的原始保存入口，保持旧 JSON 字段不变。
    save_transform = function(context)
        local body_id = context and context.body_id or get_body_id()
        if body_id then save_current_config_to_file(body_id) end
    end,

    -- 为新 UI 提供当前条件状态，实际条件读取仍由 TransformManager 负责。
    get_transform_state = function(type_key, character)
        if not can_use_transform(character)
            or not TransformManager.has_configured_condition(current_config, type_key) then return nil end
        if type_key == "damage" then
            -- 受击条件以角色地址维护倒计时，地址生成方式与旧 UI 保持一致。
            local ok, remaining = pcall(function()
                local game_object = safe_get_game_object(character, "transform_state_damage")
                local character_address = tostring(game_object or character)
                return TransformManager.get_damage_remaining_time(character_address)
            end)
            return ok and remaining or nil
        end
        local getters = {
            hp = TransformManager.get_character_hp_percent,
            weapon = TransformManager.get_character_weapon_drawn,
            spirit = TransformManager.get_character_spirit_level,
            dual_blades = TransformManager.get_character_dual_blades_state,
            switch_axe = TransformManager.get_character_switch_axe_state,
            insect_glaive = TransformManager.get_character_insect_glaive_state,
            charge_blade = TransformManager.get_character_charge_blade_state,
            greatsword_type = TransformManager.get_character_greatsword_charge_type,
            greatsword_level = TransformManager.get_character_greatsword_charge_level,
            bow_level = TransformManager.get_character_bow_charge_level,
            hammer_level = TransformManager.get_character_hammer_charge_level
        }
        local getter = getters[type_key]
        if not getter then return nil end
        local ok, value = pcall(function() return getter(character) end)
        -- false 是武器“收刀”等有效状态，不能用 Lua 的 and/or 简写转成 nil。
        if ok then return value end
        return nil
    end,

    -- 生命值测试沿用旧 UI 的 TransformManager 写入接口，仅用于当前本地角色。
    set_test_hp = function(character, percent)
        if not can_use_transform(character) then return false end
        local ok, result = pcall(function()
            return TransformManager.set_character_hp_percent(character, percent)
        end)
        return ok and result ~= false
    end,

    -- 获取当前部位候选 Mesh，兼容自定义 Body ID 和旧 JSON 结构。
    get_meshes = function(character, body_id, part_index)
        if not character or not body_id then return {} end
        if is_weapon_mode then
            local _, weapon_objs = get_character_weapon_id(character)
            local weapon_obj = weapon_objs and weapon_objs[part_index + 1]
            local mesh = weapon_obj and get_mesh_component_recursive(weapon_obj)
            return mesh and { mesh } or {}
        end
        local reference = active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
        return get_character_part_meshes(character, part_index, reference)
    end,

    -- 读取当前部位的 Mesh 和材质状态，UI 不直接耦合装备扫描细节。
    get_mesh_view = function(meshes, body_id, part_index)
        local mesh = meshes and meshes[1]
        if not mesh or not sdk.is_managed_object(mesh) then return nil end
        local view = {
            mesh_enabled = mesh:call("get_Enabled") ~= false,
            materials = {}
        }
        local count = mesh:call("get_MaterialNum") or 0
        for i = 0, count - 1 do
            table.insert(view.materials, {
                name = mesh:call("getMaterialName", i),
                enabled = mesh:call("getMaterialsEnable", i) ~= false,
                index = i
            })
        end
        return view
    end,

    get_override = function(body_id, part_index)
        return active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
    end,

    -- 切换 Mesh 显示状态，并写回旧 UI 共用的 active_overrides。
    set_mesh_enabled = function(body_id, part_index, meshes, enabled)
        if not body_id then return end
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        local key = tostring(part_index)
        if not active_overrides[body_id][key] then
            active_overrides[body_id][key] = { materials = {} }
        elseif not active_overrides[body_id][key].materials then
            active_overrides[body_id][key].materials = {}
        end
        active_overrides[body_id][key].mesh_enabled = enabled
        for _, mesh in ipairs(meshes or {}) do
            if sdk.is_managed_object(mesh) then mesh:call("set_Enabled", enabled) end
        end
    end,

    -- 切换材质显示状态，并遵守全局隐藏分组的优先级。
    set_material_enabled = function(body_id, part_index, meshes, material_name, enabled)
        if not body_id then return end
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        local key = tostring(part_index)
        if not active_overrides[body_id][key] then
            active_overrides[body_id][key] = { materials = {} }
        elseif not active_overrides[body_id][key].materials then
            active_overrides[body_id][key].materials = {}
        end
        active_overrides[body_id][key].materials[material_name] = enabled
        local render_enabled = enabled
        if enabled and is_globally_hidden(part_index, material_name) then render_enabled = false end
        for _, mesh in ipairs(meshes or {}) do
            if sdk.is_managed_object(mesh) then
                local count = mesh:call("get_MaterialNum") or 0
                for i = 0, count - 1 do
                    if mesh:call("getMaterialName", i) == material_name then
                        mesh:call("setMaterialsEnable", i, render_enabled)
                    end
                end
            end
        end
    end,

    is_material_in_context = is_material_in_current_context,

    -- 为新 UI 返回与旧 UI 完全一致的普通分组占用、全局分组占用和可操作状态。
    get_material_occupancy = function(part_index, material_name)
        return {
            owner = get_material_group_owner(part_index, material_name),
            global_groups = get_material_global_groups(part_index, material_name),
            in_context = is_material_in_current_context(part_index, material_name)
        }
    end,

    get_part_count = function(character, weapon_mode)
        if not weapon_mode then return 6 end
        local _, weapon_objs = get_character_weapon_id(character)
        return weapon_objs and #weapon_objs or 1
    end,

    -- 武器部件优先显示旧 UI 括号内的真实 Mesh 名称，不再使用“武器 0”之类的序号名称。
    get_part_label = function(character, weapon_mode, part_index)
        if not weapon_mode then return nil end
        local _, weapon_objs = get_character_weapon_id(character)
        local weapon_obj = weapon_objs and weapon_objs[part_index + 1]
        if not weapon_obj or not sdk.is_managed_object(weapon_obj) then return nil end
        local mesh = get_mesh_component_recursive(weapon_obj)
        local target = safe_get_game_object(mesh, "part_label") or weapon_obj
        local ok, name = pcall(function() return target:call("get_Name") end)
        return ok and name or nil
    end
})
-- REFramework 重载脚本时可能复用 require 缓存，兼容旧缓存实例缺少原型方法的情况。
if variant_manager_ui and not variant_manager_ui.update then
    setmetatable(variant_manager_ui, { __index = VariantManagerUI })
end

-- Debug 状态
local show_debug_window = false

-- =============================================================================
-- =============================================================================

-- 辅助函数：在 UI 中绘制条件的目标列表（捕获外部的 body_id 和 current_config）
local function draw_targets_ui(targets, rule_type, rule_idx)
    local body_id = last_body_id
    for j, target in ipairs(targets) do
        imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)

        -- 分组选择
        -- 准备分组下拉框的数据（按 group_order 排序）
        local all_groups = { "" }
        local all_groups_display = { T("main_list") or "Main" }
        local global_label_t = T("global_group_label") or "[Global]"
        if current_config.groups then
            -- 按 group_order 排序，fallback 字母序
            local ordered_gnames = {}
            local in_order = {}
            if current_config.group_order then
                for _, gname in ipairs(current_config.group_order) do
                    if current_config.groups[gname] then
                        table.insert(ordered_gnames, gname)
                        in_order[gname] = true
                    end
                end
            end
            for gname, _ in pairs(current_config.groups) do
                if not in_order[gname] then table.insert(ordered_gnames, gname) end
            end
            for _, gname in ipairs(ordered_gnames) do
                local g_data = current_config.groups[gname]
                table.insert(all_groups, gname)
                if g_data.is_global then
                    table.insert(all_groups_display, global_label_t .. " " .. gname)
                else
                    table.insert(all_groups_display, gname)
                end
            end
        end
        local g_idx = 1
        for idx, g in ipairs(all_groups) do
            if g == (target.group or "") then g_idx = idx; break end
        end
        imgui.set_next_item_width(120)
        local c_g, v_g = imgui.combo("##group", g_idx, all_groups_display)
        if c_g then
            target.group = all_groups[v_g]
            target.preset = "" -- 分组改变时重置预设
            save_current_config_to_file(body_id)
        end

        imgui.same_line()

        -- 预设选择（按 preset_order 排序）
        local target_presets = {}
        if target.group == "" or target.group == nil then
            if current_config.presets then
                -- 按 preset_order 排序，fallback 字母序
                local in_order = {}
                if current_config.preset_order then
                    for _, pname in ipairs(current_config.preset_order) do
                        if current_config.presets[pname] then
                            table.insert(target_presets, pname)
                            in_order[pname] = true
                        end
                    end
                end
                for pname, _ in pairs(current_config.presets) do
                    if not in_order[pname] then table.insert(target_presets, pname) end
                end
            end
        else
            if current_config.groups and current_config.groups[target.group] and current_config.groups[target.group].presets then
                local g_data = current_config.groups[target.group]
                -- 按分组的 preset_order 排序，fallback 字母序
                local in_order = {}
                if g_data.preset_order then
                    for _, pname in ipairs(g_data.preset_order) do
                        if g_data.presets[pname] then
                            table.insert(target_presets, pname)
                            in_order[pname] = true
                        end
                    end
                end
                for pname, _ in pairs(g_data.presets) do
                    if not in_order[pname] then table.insert(target_presets, pname) end
                end
            end
        end
        
        local p_idx = 1
        local found = false
        for idx, p in ipairs(target_presets) do
            if p == target.preset then p_idx = idx; found = true; break end
        end
        
        if not found and #target_presets > 0 then
            target.preset = target_presets[1]
            save_current_config_to_file(body_id)
        end
        
        if #target_presets == 0 then table.insert(target_presets, "None") end

        imgui.set_next_item_width(150)
        local c_p, v_p = imgui.combo("##preset", p_idx, target_presets)
        if c_p and target_presets[v_p] ~= "None" then
            target.preset = target_presets[v_p]
            save_current_config_to_file(body_id)
        end

        imgui.same_line()
        if imgui.button(T("delete_condition") .. "##del_cond") then
            table.remove(targets, j)
            save_current_config_to_file(body_id)
        end
        imgui.pop_id()
    end
end

-- =============================================================================
-- 每一帧执行
-- =============================================================================
-- temp_applied_presets 已在文件头部定义
runtime_guard:install_hooks()
-- 运行时与界面共用同一配置、默认意图和角色规则入口。
local process_character = Processor.new({
    identify = function(character, slot)
        if slot == "armor" then return get_character_body_id(character) end
        return get_character_weapon_id(character)
    end,
    load = load_config_data,
    initialize = function(id)
        if not active_overrides[id] then apply_all_defaults(id) end
    end,
    resolve = resolve_character_overrides,
    apply = function(character, slot, objects, result, changed)
        if slot == "armor" then apply_preset_to_armor(character, result, true, changed)
        else apply_preset_to_weapon(character, objects, result, true, changed) end
    end,
})

re.on_frame(function()
    local suspended = runtime_guard:update()
    variant_manager_ui:set_suspended(suspended)
    if suspended then return end
    -- 0.1 执行分帧扫描器
    if not tick_scanner() then variant_manager_ui:set_suspended(true); return end

    -- D2D 新 UI 自己维护快捷键按下沿和弹窗状态。
    variant_manager_ui:update()

    -- 1. 维护本地玩家 UI 状态
    local local_body_id = get_body_id()
    if local_body_id then
        if local_body_id ~= last_body_id then
            last_body_id = local_body_id
            -- 切换装备后分组属于新的 Body，必须回到默认分组，避免沿用上一件装备的分组名称。
            current_group_name = ""
            local restoring_mode_group = pending_mode_group_restore == true
            if not restoring_mode_group then
                -- 真实换装回到旧装备时只读取 JSON 默认预设，不恢复上次临时选择或手动覆盖。
                active_group_presets[local_body_id] = nil
                active_overrides[local_body_id] = nil
                temp_applied_presets[local_body_id] = nil
            end
            -- 如果该 body_id 已有 active_overrides（说明之前已加载过），只更新 UI 不重置状态
            if active_overrides[local_body_id] then
                -- 仅更新 UI 配置和列表
                local data = load_config_data(local_body_id)
                if data then
                    current_config = data
                    update_group_names_list()
                    update_preset_names_list()
                else
                    -- 手动开关会留下 active_overrides，但没有 JSON 时必须清空上一件装备的预设 UI。
                    load_body_config(local_body_id)
                end
            else
                -- 全新加载：重置状态并应用默认预设
                temp_applied_presets[local_body_id] = nil
                load_body_config(local_body_id)
            end
            -- 仅模式切换后恢复同一配置 ID 的分组；新装备没有记录时仍使用默认分组。
            if restoring_mode_group then
                pending_mode_group_restore = false
                local saved_group = mode_group_selection[local_body_id]
                if saved_group and saved_group ~= "" and current_config.groups
                    and current_config.groups[saved_group] then
                    current_group_name = saved_group
                    for index, group_name in ipairs(group_names_list) do
                        if group_name == saved_group then
                            selected_group_index = index + 1
                            break
                        end
                    end
                    update_preset_names_list()
                end
            end
        end
    end
    -- 当 local_body_id 为 nil 时不重置 last_body_id，避免模型短暂重建期间丢失状态

    -- 遍历所有角色并应用规则引擎
    -- 2. 遍历所有玩家并应用配置
    local all_chars = get_all_characters()
    -- 本地玩家是每帧预设应用的直接目标；角色扫描在模型重建或菜单场景中可能暂时漏掉它，
    -- 因此补入 MasterPlayer 角色，保证自定义 Body ID 也能持续应用预设状态。
    local local_char_for_frame = get_local_player_character()
    if local_char_for_frame and sdk.is_managed_object(local_char_for_frame) then
        local local_seen = false
        for _, listed_char in ipairs(all_chars) do
            if listed_char == local_char_for_frame then
                local_seen = true
                break
            end
        end
        if not local_seen then
            table.insert(all_chars, local_char_for_frame)
        end
    end
    local seen = {}
    for _, char in ipairs(all_chars) do
        if char and sdk.is_managed_object(char) then
            seen[tostring(char)] = process_character(char)
        end
    end
    actor_runtime:retain(seen)
end)
-- =============================================================================
-- UI 绘制
-- =============================================================================
local draw_game_conditions = require("ArmorVariantManager_Core/Games/Wilds/ImGuiConditions").new({
    translate = T,
    rules = TransformManager,
    save = save_current_config_to_file,
    draw_targets = draw_targets_ui,
    can_transform = can_use_transform,
    game_object = safe_get_game_object,
})

-- UI 绘制回调
re.on_draw_ui(function()
    -- D2D与旧ImGui回调都读取同一状态，不在这里重复轮询游戏菜单/加载状态。
    if imgui.tree_node(T("mod_name")) then
        if runtime_guard.suspended then
            imgui.text(T("runtime_paused"))
            imgui.tree_pop()
            return
        end
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()

        -- 新 UI 设置和旧 UI 隐藏逻辑由独立模块处理。
        if variant_manager_ui:draw_settings() then
            imgui.tree_pop()
            return
        end

        if show_debug_window then
            if imgui.tree_node("Debug Info") then
                local all_chars = get_all_characters()
                imgui.text("Detected Characters: " .. tostring(#all_chars))
                if imgui.begin_table("DebugTable", 3) then
                    imgui.table_setup_column("Index")
                    imgui.table_setup_column("Address")
                    imgui.table_setup_column("BodyID")
                    imgui.table_headers_row()
                    for i, char in ipairs(all_chars) do
                        imgui.table_next_row()
                        imgui.table_set_column_index(0)
                        imgui.text(tostring(i))
                        imgui.table_set_column_index(1)
                        local addr = "N/A"
                        if char and sdk.is_managed_object(char) then
                            local ok, game_obj = (function() local go = safe_get_game_object(char, "ui_body_mesh") if not go then return false end return true, go end)()
                            if ok and game_obj then addr = tostring(game_obj) end
                        else
                            addr = "Invalid/Destroyed"
                        end
                        imgui.text(addr)
                        imgui.table_set_column_index(2)
                        imgui.text(get_character_body_id(char) or "Unknown")
                    end
                    imgui.end_table()
                end
                imgui.separator()
                imgui.text("Cache Status:")
                for k, v in pairs(actors.cached()) do
                    imgui.text("Key: " .. tostring(k) .. " | Valid: " .. tostring(sdk.is_managed_object(v.char)))
                end
                imgui.tree_pop()
            end
        end

        -- 使用 pcall 包裹核心绘制逻辑，防止 Lua 错误导致 ImGui 状态异常
        local status, err = pcall(function()
            -- 模式切换 Tabs (使用 Radio Button 替代 Tab Bar，因为 REFramework 某些版本不支持 begin_tab_bar)
            local armor_mode_text = T("armor_mode") or "Armor Variant"
            local weapon_mode_text = T("weapon_mode") or "Weapon Variant"
            
            -- 使用 Checkbox 模拟切换，因为部分版本也没有 radio_button
            local changed_armor, new_armor = imgui.checkbox(armor_mode_text, not is_weapon_mode)
            if changed_armor and new_armor then
                switch_variant_mode(false)
            end
            
            imgui.same_line()
            local changed_weapon, new_weapon = imgui.checkbox(weapon_mode_text, is_weapon_mode)
            if changed_weapon and new_weapon then
                switch_variant_mode(true)
            end
            imgui.separator()

            local character = get_local_player_character()
            if character and sdk.is_managed_object(character) then
                local body_id = get_body_id()
                -- imgui.text(T("current_body_id") .. tostring(body_id))
                if body_id then
                    -- ========== 预设管理区域 ==========
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")") then
                        -- 使用 pcall 包裹整个预设管理区域，防止 UI 脚本报错导致 ImGui Mismatch 崩溃
                        local ui_status, ui_err = pcall(function()
                            -- 配置被还原提示横幅：检测到主配置被 mod 重装覆盖时，提供一键恢复入口
                            -- 恢复/忽略后由配置会话立即隐藏横幅。
                            if config_session.pending(body_id) then
                                imgui.text_colored(T("config_restored_warning"), 0xFF00CCFF)
                                if imgui.button(T("restore_from_backup") .. "##restore_backup") then
                                    -- "已处理"标记由 restore_config_from_backup 在写回成功后设置。
                                    restore_config_from_backup(body_id)
                                end
                                imgui.same_line()
                                if imgui.button(T("dismiss") .. "##dismiss_restore") then
                                    config_session.dismiss(body_id)
                                end
                                imgui.separator()
                            end
                            -- 1. 准备数据
                            local global_label = T("global_group_label") or "[Global]"
                            local full_group_list = {T("main_list")}
                            for _, gname in ipairs(group_names_list) do
                                local g_data = current_config.groups and current_config.groups[gname]
                                if g_data and g_data.is_global then
                                    table.insert(full_group_list, global_label .. " " .. gname)
                                else
                                    table.insert(full_group_list, gname)
                                end
                            end
                            local current_group_combo_index = 1
                            if current_group_name ~= "" then
                                for i, gname in ipairs(group_names_list) do
                                    if gname == current_group_name then current_group_combo_index = i + 1; break end
                                end
                            end

                            -- 2. 预设与分组选择 (左右分区布局)
                            if imgui.begin_table("PresetsLayout", 2, 512) then
                                imgui.table_setup_column("PresetArea", 2048, 1.0)
                                imgui.table_setup_column("GroupArea", 2048, 1.0)
                                -- 第一行
                                imgui.table_next_row()
                                imgui.table_next_column()
                                imgui.text(T("preset") .. ":")
                                imgui.table_next_column()
                                imgui.text(T("group") .. ":")

                                -- 第二行
                                imgui.table_next_row()
                                imgui.table_next_column()
                                imgui.set_next_item_width(-1)
                                if #preset_names_list > 0 then
                                    local changed_idx, idx = imgui.combo("##preset_selector", selected_preset_index, preset_names_list)
                                    if changed_idx then
                                        selected_preset_index = idx
                                        local current_preset_name = preset_names_list[selected_preset_index]
                                        if current_preset_name then apply_preset(current_preset_name) end
                                        auto_set_selected_preset_as_default(body_id)
                                    end
                                else
                                    local no_preset_key = is_weapon_mode and "no_weapon_presets" or "no_presets"
                                    imgui.text_colored("[" .. T(no_preset_key) .. "]", 0xFF808080)
                                end

                                imgui.table_next_column()
                                imgui.set_next_item_width(-1)
                                local changed_g, g_idx = imgui.combo("##group_selector", current_group_combo_index, full_group_list)
                                if changed_g then
                                    current_group_name = (g_idx == 1) and "" or group_names_list[g_idx - 1]
                                    selected_group_index = g_idx
                                    update_preset_names_list()
                                end

                                -- 第三行
                                imgui.table_next_row()
                                imgui.table_next_column()
                                -- 预设操作
                                if #preset_names_list > 0 then
                                    local current_preset_name = preset_names_list[selected_preset_index]
                                    local ctx_default = (current_group_name == "") and current_config.default_preset or
                                                       (current_config.groups[current_group_name] and current_config.groups[current_group_name].default_preset)
                                    if imgui.button(T("delete_preset")) then
                                        delete_preset(current_preset_name, body_id)
                                    end
                                    imgui.same_line()
                                    if not global_config.auto_set_selected_preset_as_default
                                        and imgui.button(T("set_as_default")) then
                                        set_preset_as_default(current_preset_name, body_id)
                                    end
                                    -- 预设状态提示
                                    imgui.same_line()
                                    if ctx_default == current_preset_name then
                                        imgui.text_colored(T("selected_and_default"), 0xFF00FF00)
                                    else
                                        imgui.text_colored(T("selected_not_default"), 0xFF00CCFF)
                                    end
                                    -- 排序按钮
                                    imgui.same_line()
                                    if imgui.button(T("sort") .. "##p_sort") then
                                        sort_mode = "preset"
                                        -- 初始化排序临时列表
                                        sort_temp_list = {}
                                        for _, pn in ipairs(preset_names_list) do
                                            table.insert(sort_temp_list, pn)
                                        end
                                        sort_selected_index = selected_preset_index
                                    end
                                end

                                -- 自动保存为全局设置；开启时立即将当前选中预设写为当前分组默认值。
                                imgui.spacing()
                                local changed_auto, auto_enabled = imgui.checkbox(
                                    T("auto_set_selected_preset_as_default"),
                                    global_config.auto_set_selected_preset_as_default == true)
                                if changed_auto then
                                    global_config.auto_set_selected_preset_as_default = auto_enabled == true
                                    save_global_settings()
                                    if global_config.auto_set_selected_preset_as_default then
                                        auto_set_selected_preset_as_default(body_id)
                                    end
                                end

                                -- 新增预设 UI (在预设列)
                                imgui.spacing()
                                imgui.text(T("create_new_preset"))
                                imgui.set_next_item_width(-1)
                                local cp, ptext = imgui.input_text("##new_preset_name_input", new_preset_name)
                                if cp then new_preset_name = ptext end
                                if imgui.button(T("save_preset") .. "##p_left") then
                                    if new_preset_name ~= "" then
                                        if save_preset(new_preset_name, body_id) then
                                            new_preset_name = ""
                                            update_preset_names_list()
                                        end
                                    end
                                end
                                -- 覆盖当前预设按钮
                                if #preset_names_list > 0 then
                                    imgui.same_line()
                                    if imgui.button(T("overwrite_preset") .. "##p_overwrite") then
                                        local current_preset_name = preset_names_list[selected_preset_index]
                                        if current_preset_name and current_preset_name ~= "" then
                                            save_preset(current_preset_name, body_id)
                                        end
                                    end
                                end

                                imgui.table_next_column()
                                -- 分组操作
                                if not is_selection_mode then
                                    if imgui.button(T("start_selection") .. "##right") then
                                        is_selection_mode = true
                                        pending_material_selections = {}
                                    end
                                    if current_group_name ~= "" then
                                        imgui.same_line()
                                        if imgui.button(T("delete_group") .. "##right") then
                                            delete_group(current_group_name, body_id)
                                        end
                                    end
                                    -- 分组排序按钮（有分组时才显示）
                                    if current_config.groups and next(current_config.groups) then
                                        imgui.same_line()
                                        if imgui.button(T("sort") .. "##g_sort") then
                                            sort_mode = "group"
                                            sort_temp_list = {}
                                            for _, gn in ipairs(group_names_list) do
                                                table.insert(sort_temp_list, gn)
                                            end
                                            sort_selected_index = 1
                                            if current_group_name ~= "" then
                                                for gi, gn in ipairs(sort_temp_list) do
                                                    if gn == current_group_name then sort_selected_index = gi; break end
                                                end
                                            end
                                        end
                                    end
                                else
                                    -- 选择模式活跃状态
                                    imgui.text_colored(T("selection_mode") .. " ", 0xFF00FFFF)
                                    imgui.text_colored(T("selection_mode_desc") .. " ", 0xFF00FFFF)
                                    local cg, gtext = imgui.input_text(T("name") .. "##gn", new_group_name)
                                    if cg then new_group_name = gtext end
                                    -- 全局分组勾选框
                                    local cg_global, new_is_global = imgui.checkbox(T("is_global_group") .. "##gisgl", new_group_is_global)
                                    if cg_global then new_group_is_global = new_is_global end
                                    if new_group_is_global then
                                        imgui.same_line()
                                        imgui.text_colored(T("is_global_group_desc"), 0xFF80FFFF)
                                    end
                                    if imgui.button(T("confirm_creation") .. "##gconfirm") then
                                        if new_group_name ~= "" and create_new_group(new_group_name, body_id, new_group_is_global) then
                                            current_group_name = new_group_name
                                            new_group_name = ""
                                            new_group_is_global = false
                                            is_selection_mode = false
                                            update_group_names_list()
                                            update_preset_names_list()
                                        end
                                    end
                                    imgui.same_line()
                                    if imgui.button(T("cancel") .. "##gcancel") then
                                        is_selection_mode = false
                                        new_group_is_global = false
                                    end
                                end
                                imgui.end_table()
                            end

                            -- 分组材质预览
                            -- 4. 分组预览
                            if current_group_name ~= "" then
                                local group_data = current_config.groups[current_group_name]
                                if group_data and group_data.mask and imgui.tree_node(T("materials") .. " in " .. current_group_name) then
                                    for p_idx, mats in pairs(group_data.mask) do
                                        local part_name = T(PART_INDEX_TO_NAME[tonumber(p_idx)]) or p_idx
                                        for m_name, _ in pairs(mats) do
                                            imgui.text("  • [" .. part_name .. "] " .. tostring(m_name))
                                        end
                                    end
                                    imgui.tree_pop()
                                end
                            end

                            -- C. 自动查找 (仅在没有任何预设数据时显示)
                            local has_any_data = (next(current_config.presets) ~= nil)
                            if not has_any_data and current_config.groups then
                                for _, g in pairs(current_config.groups) do
                                    if g.presets and next(g.presets) then has_any_data = true; break end
                                end
                            end
                            if not has_any_data then
                                imgui.separator()
                                if imgui.button(T("auto_find_preset")) then
                                    local st, res, m = pcall(find_auto_preset, body_id)
                                    if st and res then
                                        auto_find_log = T("auto_find_success") .. tostring(m or "")
                                    elseif st and m == "No matching preset found" then
                                        auto_find_log = T("auto_find_fail")
                                    else
                                        auto_find_log = st and ("Failed: " .. tostring(m)) or "Lua Error: " .. tostring(res)
                                    end
                                end
                                if auto_find_log ~= "" then imgui.text_colored(auto_find_log, 0xFF00FFFF) end
                            end

                            -- 陷地修复放在预设、分组及自动查找按钮和结果提示下方。
                            if not is_weapon_mode then
                                imgui.separator()
                                local settings = get_ground_clipping_settings()
                                local changed, value = imgui.checkbox(T("heel_title"), settings.enabled)
                                if changed then set_ground_clipping_settings({ enabled = value }, body_id) end
                                imgui.same_line()
                                imgui.set_next_item_width(160)
                                changed, value = imgui.slider_float("##ground_clipping_height", settings.height_cm, -10, 50, "%.1f cm")
                                if changed then set_ground_clipping_settings({ height_cm = value }, body_id) end
                                imgui.same_line()
                                if imgui.button(T("heel_reset_short") .. "##ground_clipping_reset") then
                                    set_ground_clipping_settings({ enabled = true, height_cm = 0 }, body_id)
                                end
                                imgui.separator()
                            end
                        end)
                        if not ui_status then
                            imgui.text_colored("UI Error: " .. tostring(ui_err), 0xFFFF0000)
                            pcall(imgui.end_table)
                        end

                        -- 排序面板（在 pcall 外渲染，独立区域）
                        if sort_mode then
                            imgui.separator()
                            local sort_title = (sort_mode == "group") and (T("sort") .. " - " .. T("group")) or (T("sort") .. " - " .. T("preset"))
                            imgui.text_colored(sort_title, 0xFF00FFFF)
                            imgui.spacing()
                            -- 提示文字
                            if sort_selected_index and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                imgui.text_colored(T("sort_hint_selected") .. ": " .. sort_temp_list[sort_selected_index], 0xFFFFFF80)
                            else
                                imgui.text_colored(T("sort_hint_click"), 0xFF808080)
                            end
                            imgui.spacing()
                            for si, sname in ipairs(sort_temp_list) do
                                -- 上移按钮
                                if si <= 1 then imgui.begin_disabled() end
                                if imgui.button(T("move_up") .. "##su_" .. si) then
                                    if si > 1 then
                                        sort_temp_list[si], sort_temp_list[si - 1] = sort_temp_list[si - 1], sort_temp_list[si]
                                        if sort_selected_index == si then sort_selected_index = si - 1
                                        elseif sort_selected_index == si - 1 then sort_selected_index = si end
                                    end
                                end
                                if si <= 1 then imgui.end_disabled() end
                                imgui.same_line()
                                -- 下移按钮
                                if si >= #sort_temp_list then imgui.begin_disabled() end
                                if imgui.button(T("move_down") .. "##sd_" .. si) then
                                    if si < #sort_temp_list then
                                        sort_temp_list[si], sort_temp_list[si + 1] = sort_temp_list[si + 1], sort_temp_list[si]
                                        if sort_selected_index == si then sort_selected_index = si + 1
                                        elseif sort_selected_index == si + 1 then sort_selected_index = si end
                                    end
                                end
                                if si >= #sort_temp_list then imgui.end_disabled() end
                                imgui.same_line()
                                -- 名称按钮（点击选中，选中项高亮）
                                if si == sort_selected_index then
                                    imgui.push_style_color(21, 0xFF00AAFF) -- ImGuiCol_Button 高亮
                                end
                                if imgui.button(tostring(si) .. ". " .. sname .. "##sn_" .. si) then
                                    sort_selected_index = si
                                end
                                if si == sort_selected_index then
                                    imgui.pop_style_color(1)
                                end
                                -- 插入按钮：将选中项移动到第si行的位置
                                if sort_selected_index and sort_selected_index ~= si and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                    imgui.same_line()
                                    if imgui.button(T("sort_insert_here") .. "##si_" .. si) then
                                        local item = table.remove(sort_temp_list, sort_selected_index)
                                        table.insert(sort_temp_list, si, item)
                                        sort_selected_index = si
                                    end
                                end
                            end
                            -- 底部按钮
                            imgui.spacing()
                            if imgui.button(T("sort_confirm") .. "##sort_ok") then
                                local saved
                                if sort_mode == "group" then
                                    saved = reorder_groups(sort_temp_list, body_id)
                                elseif sort_mode == "preset" then
                                    saved = reorder_presets(sort_temp_list, body_id)
                                end
                                if saved then
                                    sort_mode = nil
                                    sort_temp_list = {}
                                end
                            end
                            imgui.same_line()
                            if imgui.button(T("sort_cancel") .. "##sort_no") then
                                sort_mode = nil
                                sort_temp_list = {}
                            end
                        end
                        imgui.tree_pop()
                    end

                    imgui.separator()

                    -- ========== 变身管理区域 ==========
                    if imgui.tree_node(T("transform_manager") .. " (" .. body_id .. ")") then
                        local inner_status, inner_err = pcall(function()
                            draw_game_conditions(current_config, body_id, character)
                        end)
                        if not inner_status then
                            imgui.text_colored("UI Error: " .. tostring(inner_err), 0xFFFF0000)
                        end
                        imgui.tree_pop()
                    end

                    imgui.separator()

                    -- ========== 防具/武器部位列表 ==========
                    if is_weapon_mode then
                        if imgui.tree_node(T("weapon_parts") or "Weapon Parts") then
                            local w_id, w_objs = get_character_weapon_id(character)
                            if w_objs and #w_objs > 0 then
                                for idx, w_obj in ipairs(w_objs) do
                                    if sdk.is_managed_object(w_obj) then
                                        local mesh_comp = get_mesh_component_recursive(w_obj)
                                        local mesh_game_obj = mesh_comp and safe_get_game_object(mesh_comp, "draw_weapon_mesh") or nil
                                        if mesh_game_obj then
                                            local obj_name = mesh_game_obj:call("get_Name")
                                            draw_mesh_toggle(mesh_game_obj, string.format("Weapon %d [%s]", idx - 1, obj_name), body_id, tostring(idx - 1))
                                        else
                                            local obj_name = w_obj:call("get_Name")
                                            imgui.text_colored(string.format("Weapon %d [%s] (No Mesh)", idx - 1, obj_name), 0xFF808080)
                                        end
                                    end
                                end
                            else
                                imgui.text_colored("Weapon " .. T("not_equipped"), 0xFF808080)
                            end
                            imgui.tree_pop()
                        end
                    else
                        -- 1. 遍历防具部位 (Helm, Body, Arm, Waist, Leg)
                        local armor_parts = {
                            [0] = T("helm"),
                            [1] = T("body"),
                            [2] = T("arm"),
                            [3] = T("waist"),
                            [4] = T("leg"),
                            [5] = T("slinger")
                        }
                        if imgui.tree_node(T("armor_parts")) then
                            for i = 0, 5 do
                                local part_obj = get_character_part(character, i)
                                local part_name = armor_parts[i]
                                local reference_part_data = active_overrides[body_id]
                                    and active_overrides[body_id][tostring(i)]
                                local mesh_components = get_character_part_meshes(character, i, reference_part_data)
                                local mesh_game_obj = mesh_components[1] and safe_get_game_object(mesh_components[1], "draw_part_mesh") or nil
                                if mesh_game_obj then
                                    -- UI 每个部位只显示主 Mesh；附属 Mesh 由预设应用逻辑同步控制。
                                    local obj_name = mesh_game_obj:call("get_Name") or "Mesh"
                                    draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, i)
                                elseif part_obj and not is_player_face_object(part_obj) then
                                    local obj_name = part_obj:call("get_Name")
                                    imgui.text_colored(string.format("%s [%s] (No Mesh)", part_name, obj_name), 0xFF808080)
                                else
                                    imgui.text_colored(part_name .. " " .. T("not_equipped"), 0xFF808080)
                                end
                            end
                            imgui.tree_pop()
                        end
                    end

                    imgui.separator()

                    -- ========== 语言切换 ==========
                    if imgui.tree_node(T("language")) then
                        -- 使用 Checkbox 模拟 RadioButton (因为 radio_button 可能不可用)
                        local is_en = global_config.language == "en"
                        local changed_en, new_en = imgui.checkbox("English", is_en)
                        if changed_en and new_en then
                            global_config.language = "en"
                            save_global_settings()
                        end
                        imgui.same_line()
                        local is_zh = global_config.language == "zh"
                        local changed_zh, new_zh = imgui.checkbox("中文", is_zh)
                        if changed_zh and new_zh then
                            global_config.language = "zh"
                            save_global_settings()
                        end
                        imgui.tree_pop()
                    end

                    imgui.separator()

                    -- ========== 性能设置 ==========
                    if imgui.tree_node(T("performance_settings")) then
                        imgui.text(T("performance_desc"))
                        imgui.spacing()
                        -- 1. 扫描间隔
                        local changed_si, val_si = imgui.slider_float(T("scan_interval"), global_config.scan_interval, 0.1, 5.0)
                        if changed_si then
                            global_config.scan_interval = val_si
                            save_global_settings()
                        end
                        -- 2. 刷新间隔 (Body ID TTL)
                        local changed_ttl, val_ttl = imgui.slider_float(T("refresh_interval"), global_config.body_id_ttl, 0.1, 10.0)
                        if changed_ttl then
                            global_config.body_id_ttl = val_ttl
                            save_global_settings()
                        end
                        -- 3. 分帧扫描步频
                        local changed_bs, val_bs = imgui.slider_int(T("scanner_batch_size"), global_config.scanner_batch_size, 10, 1000)
                        if changed_bs then
                            global_config.scanner_batch_size = val_bs
                            save_global_settings()
                        end
                        imgui.tree_pop()
                    end
                else
                    imgui.text_colored(T("no_body_part"), 0xFF0000FF)
                end
            else
                imgui.text_colored(T("waiting_for_player"), 0xFF0000FF)
            end
        end)
        -- 如果发生错误，显示错误信息
        if not status then
            imgui.text_colored(T("lua_error") .. tostring(err), 0xFF0000FF)
        end
        imgui.tree_pop()
    end
end)
