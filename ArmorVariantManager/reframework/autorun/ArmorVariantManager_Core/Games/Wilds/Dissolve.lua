local Core = require("ArmorVariantManager_Core.Runtime.Dissolve")
local Dissolve = {}

-- 荒野接入溶解核心。条件规则引起的防具切换按规则字段溶解，界面上的切换按全局设置溶解，武器始终瞬间切换。
-- 规则字段（各条件规则表通用）：dissolve_enabled、dissolve_hide_time（进入该状态，秒）、
-- dissolve_show_time（回到默认外观，秒），缺省时长 0.5 秒。全局设置：ui_dissolve_enabled、ui_dissolve_time。
-- 荒野溶解模板支持 IsMorphed，出现方式为原地互换。
local RULE_TABLES = { "transform_rules", "damage_transform_rules", "weapon_transform_rules", "spirit_transform_rules",
    "dual_blades_transform_rules", "switch_axe_transform_rules", "insect_glaive_transform_rules",
    "charge_blade_transform_rules", "greatsword_type_transform_rules", "greatsword_level_transform_rules",
    "bow_level_transform_rules", "hammer_level_transform_rules" }
Dissolve.DEFAULT_RULE_TIME, Dissolve.DEFAULT_UI_TIME, Dissolve.MAX_UI_TIME = 0.5, 1.0, 30

local function rule_place(config, rule)
    for _, key in ipairs(RULE_TABLES) do
        local list = type(config) == "table" and config[key]
        if type(list) == "table" then
            for index, item in ipairs(list) do
                if item == rule then return key, index end
            end
        end
    end
end

local function rule_settings(rule, forward, field)
    if type(rule) ~= "table" or rule.dissolve_enabled ~= true then return nil end
    return Core.settings(tonumber(rule[field]) or Dissolve.DEFAULT_RULE_TIME, forward, Core.MORPH)
end

-- deps.config：全局设置；deps.weapon_mode()：界面当前编辑武器时为 true；deps.core 可替换核心（测试用）。
function Dissolve.new(deps)
    deps = deps or {}
    local core = deps.core or Core.new({valid=deps.valid_mesh})
    local self = { core = core }
    local transitions, last_rules = {}, {}

    -- 首次应用只记下生效规则，不溶解。
    function self.reset_character(key, rules)
        core:finish_all(function(a) return a.owner == key end)
        local now = {}
        for _, rule in ipairs(rules or {}) do now[rule] = true end
        last_rules[key], transitions[key] = now, nil
    end

    -- 生效规则变化时由引起变化的规则决定过渡：新生效的规则用淡入；没有新规则时，结束的规则用淡出。
    -- 进入状态默认前进；替换同一列表中排在后面的规则时后退（如气刃等级 4 -> 3）。
    -- 规则集合不变的状态变化（如血量数值）沿用上一次的过渡。
    function self.rules_changed(key, rules, config)
        local previous, now, started, ended = last_rules[key] or {}, {}, nil, {}
        for _, rule in ipairs(rules or {}) do
            now[rule] = true
            if not started and not previous[rule] then started = rule end
        end
        for rule in pairs(previous) do
            if not now[rule] then ended[#ended + 1] = rule end
        end
        last_rules[key] = now
        if started then
            local list, index = rule_place(config, started)
            local forward = true
            for _, rule in ipairs(ended) do
                local other, position = rule_place(config, rule)
                if list and other == list and position and position > index then forward = false end
            end
            transitions[key] = rule_settings(started, forward, "dissolve_hide_time")
        elseif ended[1] then
            transitions[key] = rule_settings(ended[1], false, "dissolve_show_time")
        end
    end

    function self.character(key) return transitions[key] end

    function self.ui_settings()
        local config = deps.config or {}
        if config.ui_dissolve_enabled == false then return nil end
        local duration = tonumber(config.ui_dissolve_time) or Dissolve.DEFAULT_UI_TIME
        return Core.settings(math.max(0, math.min(Dissolve.MAX_UI_TIME, duration)), true, Core.MORPH)
    end

    -- 在指定过渡下执行一次写入，之后恢复为瞬间开关。
    function self.with(settings, fn, ...)
        core:use(settings)
        local ok, result = pcall(fn, ...)
        core:use(nil)
        if not ok then error(result, 0) end
        return result
    end

    function self.settings_for(key, manual)
        if manual then
            local settings = self.ui_settings()
            if settings then settings.owner, settings.ui = key, true end
            return settings
        end
        local settings = transitions[key]
        if settings then settings.owner = key end
        return settings
    end

    -- 显隐读写入口：动画期间读取返回目标值，写入经过当前选定的过渡。
    function self.call(object, method, ...)
        if method == "getMaterialsEnable" then
            local target = core:material_target(object, ...)
            if target ~= nil then return target end
        elseif method == "get_Enabled" then
            local target = core:mesh_target(object)
            if target ~= nil then return target end
        elseif method == "setMaterialsEnable" then
            local j, want = ...
            return core:set_material(object, j, want, object:call("getMaterialsEnable", j))
        elseif method == "set_Enabled" then
            local want = ...
            return core:set_mesh(object, want, object:call("get_Enabled"))
        end
        return object:call(method, ...)
    end

    -- 界面上的勾选：防具按界面设置溶解，编辑武器时瞬间切换。
    function self.ui_call(object, method, ...)
        if method == "setMaterialsEnable" or method == "set_Enabled" then
            local settings = not (deps.weapon_mode and deps.weapon_mode()) and self.settings_for(deps.actor_key and deps.actor_key(), true) or nil
            return self.with(settings, self.call, object, method, ...)
        end
        return self.call(object, method, ...)
    end

    function self.update() core:update() end

    -- 每帧按实际处理的角色收敛，离场角色的过渡记录随之清除。
    function self.retain(seen)
        local function has_armor(key) return seen[key] and seen[key].armor end
        core:finish_all(function(a) return a.owner and not has_armor(a.owner) end)
        for key in pairs(last_rules) do
            if not has_armor(key) then last_rules[key], transitions[key] = nil, nil end
        end
    end

    function self.reset()
        core:abandon()
        transitions, last_rules = {}, {}
    end

    function self.finish() return core:finish_all() end
    function self.finish_ui() return core:finish_all(function(a) return a.ui end) end

    return self
end

return Dissolve
