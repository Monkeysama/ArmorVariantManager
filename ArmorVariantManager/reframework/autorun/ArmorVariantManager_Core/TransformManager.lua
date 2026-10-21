-- TransformManager.lua
local TransformManager = {}

-- 引入条件注册表（所有条件模块）
local ConditionRegistry = {
    weapon = require("ArmorVariantManager_Core.Conditions.Condition_Weapon"),
    scroll = require("ArmorVariantManager_Core.Conditions.Condition_Scroll"),
    longsword = require("ArmorVariantManager_Core.Conditions.Condition_LongSword"),
    dual_blades = require("ArmorVariantManager_Core.Conditions.Condition_DualBlades"),
    switch_axe = require("ArmorVariantManager_Core.Conditions.Condition_SwitchAxe"),
    charge_axe = require("ArmorVariantManager_Core.Conditions.Condition_ChargeAxe"),
    greatsword_level = require("ArmorVariantManager_Core.Conditions.Condition_GreatSwordLevel"),
    hammer = require("ArmorVariantManager_Core.Conditions.Condition_Hammer"),
    bow = require("ArmorVariantManager_Core.Conditions.Condition_Bow"),
    monster_hp = require("ArmorVariantManager_Core.Conditions.Condition_MonsterHP")
}

-- 本地化支持（用于显示当前状态）
local Localization = require("ArmorVariantManager_Core.Localization")
local global_config_path = "ArmorVariantManager/GlobalSettings.json"

-- - 性能要点：原来每次调用 T() 都会 json.load_file(GlobalSettings.json)，
--   也就是**每取一次本地化文本就读一次硬盘**。T() 在面板绘制时会被调用很多次
--   （当前状态/档位名等），所以这里改成：
--     1. 优先读核心写好的 _G.__AVM_LANGUAGE（内存值）；
--     2. 拿不到时才回退读盘，并且把结果缓存下来。
local cached_language = nil
local function get_language()
    local lang = _G.__AVM_LANGUAGE
    if type(lang) == "string" and lang ~= "" then return lang end
    if cached_language then return cached_language end
    local P = _G.__AVM_PROFILER
    if P then P.count("transform_manager_json_reads") end
    local config = json.load_file(global_config_path)
    if config and config.language then
        cached_language = config.language
    else
        cached_language = "zh"
    end
    return cached_language
end

local function T(key)
    if not key then return "nil" end
    local lang = get_language()
    local dict = Localization[lang] or Localization["en"]
    return dict[key] or tostring(key)
end

-- 状态缓存（避免每帧重复评估相同状态）
-- 键格式：char_addr .. "|" .. context_id
local last_state_cache = {}
local model_bases = {}
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function model_id(context_id)
    local value=tostring(context_id)
    return value:match("^armor_(.*)$") or value:match("^weapon_(.*)$") or value
end

-- 普通预设的基础意图与规则输出分离。全局组在最后一层只叠加隐藏。
function TransformManager.set_model_base(body_id, normal, selected)
    local previous = model_bases[body_id]
    local restored = copy(normal or {})
    local originals = previous and previous.originals or {}
    for part, data in pairs(originals) do
        restored[part]=restored[part] or {materials={}}
        if restored[part].mesh_enabled==nil then restored[part].mesh_enabled=data.mesh_enabled end
        restored[part].materials=restored[part].materials or {}
        for name, value in pairs(data.materials or {}) do
            if restored[part].materials[name]==nil then restored[part].materials[name]=value end
        end
    end
    model_bases[body_id] = { normal = restored, originals=copy(originals),
        selected = copy(selected or {}),
        revision = (previous and previous.revision or 0) + 1 }
    return copy(restored)
end
function TransformManager.update_base_preset(body_id, config, group, preset, merge)
    local base = model_bases[body_id]
    if not base then return end
    base.selected[group or ""] = preset
    local data = group and group ~= "" and config.groups and config.groups[group] or nil
    local presets = data and data.presets or config.presets
    if not (data and data.is_global) and presets and presets[preset] then
        base.normal = merge(base.normal, presets[preset])
    end
    base.revision = base.revision + 1
end
function TransformManager.edit_base_field(body_id, part, material, value)
    local base = model_bases[body_id]
    if not base then return end
    part = tostring(part)
    base.normal[part] = base.normal[part] or { materials = {} }
    if material then
        base.normal[part].materials = base.normal[part].materials or {}
        base.normal[part].materials[material] = value
    else base.normal[part].mesh_enabled = value end
    base.revision = base.revision + 1
end

-- 稀疏预设未记录原值时，在第一次写入前采样，退出规则时能恢复实际初始值。
function TransformManager.capture_mesh(body_id, part, mesh, intent, call)
    local base = model_bases[body_id]
    if not base or not intent then return end
    part = tostring(part)
    local data = base.normal[part] or { materials = {} }
    base.originals=base.originals or {}
    base.originals[part]=base.originals[part] or {materials={}}
    local original=base.originals[part]
    base.normal[part] = data
    data.materials = data.materials or {}
    local changed = false
    if intent.mesh_enabled ~= nil and data.mesh_enabled == nil then
        local ok, value = pcall(call, mesh, "get_Enabled")
        if ok and type(value) == "boolean" then
            data.mesh_enabled = value; original.mesh_enabled=value; changed = true
        end
    end
    local missing = false
    for name in pairs(intent.materials or {}) do
        if data.materials[name] == nil then missing = true; break end
    end
    if missing then
        local ok, count = pcall(call, mesh, "get_MaterialNum")
        if ok and type(count) == "number" then
            for i = 0, count - 1 do
                local name = call(mesh, "getMaterialName", i)
                if name and intent.materials[name] ~= nil and data.materials[name] == nil then
                    local read_ok, value = pcall(call, mesh, "getMaterialsEnable", i)
                    if read_ok and type(value) == "boolean" then
                        data.materials[name] = value; original.materials[name]=value; changed = true
                    end
                end
            end
        end
    end
    if changed then base.revision = base.revision + 1 end
end

-- 清除指定角色和上下文的缓存
function TransformManager.clear_cache(char_addr, context_id, keep_bases)
    -- Rule edits may keep exactly the same weapon state. Invalidate composed outputs as well.
    for _,base in pairs(model_bases) do
        base.composed=nil; base.composed_order=nil
        base.revision=base.revision+1
    end
    if char_addr and context_id then
        local key = char_addr .. "|" .. tostring(context_id)
        last_state_cache[key] = nil
    elseif char_addr then
        -- 清除该角色所有缓存
        local prefix = char_addr .. "|"
        for k, _ in pairs(last_state_cache) do
            if string.sub(k, 1, #prefix) == prefix then
                last_state_cache[k] = nil
            end
        end
    else
        last_state_cache = {}
        if not keep_bases then model_bases = {} end
    end
end

-- 由核心根据「是否有配置真的用到怪物血量条件」来开关怪物 HP 跟踪。
-- 关掉之后，sdk.hook(snow.enemy.EnemyCharacterBase:update) 的回调会在第一行直接返回，
-- 不再做任何托管 API 调用。
-- 实测数据：该钩子约 43 次/帧，270 秒内被调用 162 万次，累计 6037ms，
-- 是插件里最贵的一项；而其中只有 1.41% 真正命中了任务目标怪。
function TransformManager.set_monster_hp_tracking(enabled)
    local handler = ConditionRegistry.monster_hp
    if handler and handler.set_tracking then
        handler.set_tracking(enabled == true)
    end
end

-- 获取指定条件类型的激活规则（内部函数）
-- player：该角色的 snow.player.Player 托管对象（联机时用来读**这名玩家自己**的状态）。
--         为 nil 时条件模块会退回「本地玩家」，与旧行为一致。
local function get_active_rule_for_type(t_type, config, character, char_addr, player)
    local handler = ConditionRegistry[t_type]
    if handler then
        return handler.evaluate(config, character, char_addr, player)
    end
    return nil, nil
end

-- 核心函数：应用变身规则，返回最终的 overrides、是否变化、激活的分组预设、所有被引用的分组
-- 新增 context_id 参数，用于区分防具/武器等不同配置上下文
-- 新增 player 参数（可选）：联机时指定「这是哪个玩家的角色」
-- 说明：真正的实现放在 apply_transform_rules_impl，外面这层只做性能统计。
local RULE_FIELDS = {
    weapon = "weapon_transform_rules", scroll = "scroll_transform_rules",
    longsword = "longsword_transform_rules", dual_blades = "dual_blades_transform_rules",
    switch_axe = "switch_axe_transform_rules", charge_axe = "charge_axe_transform_rules",
    greatsword_level = "greatsword_level_transform_rules", hammer = "hammer_transform_rules",
    bow = "bow_transform_rules", monster_hp = "monster_hp_transform_rules"
}

local function apply_transform_rules_impl(char_addr, context_id, config, character, active_overrides, merge, player)
    if not active_overrides then return active_overrides, false, {}, {} end
    local id = model_id(context_id)
    local base = model_bases[id]
    if not base then
        TransformManager.set_model_base(id, active_overrides, {})
        base = model_bases[id]
    end
    local active, states, all_groups = {}, {}, {}
    local function evaluate(kind, priority)
        if not ConditionRegistry[kind] then return end
        -- 所有可能被规则引用的分组都要返回，退出某状态时调用方才知道归还默认组。
        for _, candidate in ipairs(config[RULE_FIELDS[kind]] or {}) do
            for _, target in ipairs(candidate.targets or {}) do all_groups[target.group or ""] = true end
        end
        local rule, state = get_active_rule_for_type(kind, config, character, char_addr, player)
        states[#states + 1] = kind .. ":" .. tostring(state)
        if rule then active[#active + 1] = {rule = rule, priority = priority or 1, kind = kind} end
    end
    if config.is_parallel then
        for kind, setting in pairs(config.parallel_settings or {}) do
            if setting.enabled then evaluate(kind, setting.priority) end
        end
    else evaluate(config.transform_type, 1) end
    table.sort(states)
    local signature = table.concat(states, "|") .. "@" .. base.revision
    local key = tostring(char_addr) .. "|" .. tostring(context_id)
    local previous = last_state_cache[key]
    if previous and previous.signature == signature then
        -- 同模型队友拥有独立输出；不能把上一个玩家的变身结果直接传回来。
        return previous.output, active_overrides ~= previous.output, previous.targets, all_groups
    end
    -- Same-model players in the same state can share an immutable result; avoid version churn.
    local cached=base.composed and base.composed[signature]
    if cached then
        last_state_cache[key]=cached
        return cached.output,active_overrides~=cached.output,cached.targets,all_groups
    end
    local output, targets = copy(base.normal), {}
    -- 数字 1 为最高优先级，保留已有排序语义；同优先级按条件名稳定排序。
    table.sort(active, function(a, b)
        if a.priority == b.priority then return a.kind < b.kind end
        return a.priority > b.priority
    end)
    for _, item in ipairs(active) do
        for _, target in ipairs(item.rule.targets or {}) do
            local group, name = target.group or "", target.preset
            local data = group ~= "" and config.groups and config.groups[group] or nil
            local presets = group == "" and config.presets or data and data.presets
            local preset = presets and presets[name]
            if name and name ~= "None" and preset then
                targets[group] = name
                if not (data and data.is_global) then output = merge(output, preset) end
            end
        end
    end
    -- 全局组始终最后只锁隐藏，默认隐藏不会残留在普通基础层里。
    for group, data in pairs(config.groups or {}) do
        if data.is_global then
            local name = targets[group] or base.selected[group] or data.default_preset
            local preset = data.presets and data.presets[name]
            for part, values in pairs(preset or {}) do
                for material, enabled in pairs(values.materials or {}) do
                    if enabled == false then
                        output[part] = output[part] or {materials = {}}
                        output[part].materials = output[part].materials or {}
                        output[part].materials[material] = false
                    end
                end
            end
        end
    end
    local entry={signature = signature, output = output, targets = targets}
    last_state_cache[key] = entry
    base.composed=base.composed or {}
    base.composed_order=base.composed_order or {}
    base.composed[signature]=entry
    base.composed_order[#base.composed_order+1]=signature
    if #base.composed_order>16 then base.composed[table.remove(base.composed_order,1)]=nil end
    return output, true, targets, all_groups
end

function TransformManager.apply_transform_rules(char_addr, context_id, config, character, active_overrides, merge_overrides, player)
    local P = _G.__AVM_PROFILER
    local t0 = P and P.begin("transform_rules")
    local new_overrides, changed, activated_targets, all_targeted_groups =
        apply_transform_rules_impl(char_addr, context_id, config, character, active_overrides, merge_overrides, player)
    if P then
        P.finish("transform_rules", t0)
        P.count("transform_rules_calls")
    end
    return new_overrides, changed, activated_targets, all_targeted_groups
end

-- 获取当前状态的显示字符串（用于 UI）
function TransformManager.get_current_state_display(config, character)
    if not config then return "" end
    if config.is_parallel then
        return ""
    end

    local t_type = config.transform_type
    if t_type and ConditionRegistry[t_type] then
        local _, state = get_active_rule_for_type(t_type, config, character, "")
        if state ~= nil then
            if t_type == "weapon" then
                return (state == "sheathed") and T("weapon_sheathed") or T("weapon_drawn")
            elseif t_type == "scroll" then
                return (state == "red") and T("scroll_red") or T("scroll_blue")
            elseif t_type == "longsword" then
                local level_names = {
                    [0] = T("spirit_level_0"),
                    [1] = T("spirit_level_1"),
                    [2] = T("spirit_level_2"),
                    [3] = T("spirit_level_3")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "dual_blades" then
                local state_names = {
                    [0] = T("dual_normal"),
                    [1] = T("dual_kijin"),
                    [2] = T("dual_enhancement")
                }
                return state_names[state] or tostring(state)
            elseif t_type == "switch_axe" then
                local state_names = {
                    [0] = T("switch_axe_axe"),
                    [1] = T("switch_axe_sword"),
                    [2] = T("switch_axe_awakened")
                }
                return state_names[state] or tostring(state)
            elseif t_type == "charge_axe" then
                local state_names = {
                    [0] = T("charge_axe_axe"),
                    [1] = T("charge_axe_sword"),
                    [2] = T("charge_axe_axe_enhanced"),
                    [3] = T("charge_axe_shield"),
                    [4] = T("charge_axe_sword_enhanced"),
                    [5] = T("charge_axe_triple")
                }
                return state_names[state] or tostring(state)
            elseif t_type == "greatsword_level" then
                local level_names = {
                    [0] = T("greatsword_level_0"),
                    [1] = T("greatsword_level_1"),
                    [2] = T("greatsword_level_2"),
                    [3] = T("greatsword_level_3")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "hammer" then
                local level_names = {
                    [0] = T("hammer_level_0"),
                    [1] = T("hammer_level_1"),
                    [2] = T("hammer_level_2")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "bow" then
                local level_names = {
                    [0] = T("bow_level_0"),
                    [1] = T("bow_level_1"),
                    [2] = T("bow_level_2"),
                    [3] = T("bow_level_3")
                }
                return level_names[state] or tostring(state)
            elseif t_type == "monster_hp" then
                if state then
                    return string.format("%.1f%%", state)
                else
                    return T("no_monster_target")
                end
            else
                return tostring(state)
            end
        end
    end

    local default_preset = config.default_preset
    if default_preset and default_preset ~= "" then
        return string.format(T("default_preset_display") or "Default: %s", default_preset)
    end
    return T("no_active_condition") or "None"
end

-- 获取当前状态的原始值（用于 UI 中的阈值比较等）
function TransformManager.get_current_raw_state(config, character)
    if not config then return nil end
    if config.is_parallel then return nil end
    local t_type = config.transform_type
    if not t_type or not ConditionRegistry[t_type] then return nil end
    local _, state = get_active_rule_for_type(t_type, config, character, "")
    return state
end

-- 以下函数用于 UI 判断模块是否可用（总是返回 true，因为所有条件模块已实现）
function TransformManager.has_weapon_getter() return true end
function TransformManager.has_scroll_getter() return true end
function TransformManager.has_longsword_getter() return true end
function TransformManager.has_dual_blades_getter() return true end
function TransformManager.has_switch_axe_getter() return true end
function TransformManager.has_charge_axe_getter() return true end
function TransformManager.has_greatsword_level_getter() return true end
function TransformManager.has_hammer_getter() return true end
function TransformManager.has_bow_getter() return true end
function TransformManager.has_monster_hp_getter() return true end

return TransformManager
