local Conditions = {}

local function find_definition(model, id)
    for _, definition in ipairs(model.definitions) do
        if definition.id == id then return definition end
    end
end

-- 规则与实时状态使用同一套游戏枚举名，不把引擎对象传入快照。
function Conditions.format_state(model, id, value, T)
    if value == nil then return nil end
    if id == "hp" or id == "monster_hp" then return string.format("%.1f%%", value) end
    if id == "damage" then
        return value > 0 and string.format(T("damage_countdown"), value) or T("damage_idle")
    end
    if id == "weapon" and type(value) == "boolean" then value = value and "drawn" or "sheathed" end
    local definition = find_definition(model, id)
    for _, state in ipairs(definition and definition.states or {}) do
        if state.value == value then return T(state.label) end
    end
    return tostring(value)
end

local function new_rule(definition)
    local rule = { targets = {} }
    for _, field in ipairs(definition.fields) do rule[field.key] = field.default end
    if definition.damage then rule.chain_nodes = { { duration = 1, targets = {} } } end
    return rule
end

local function default_rules(definition)
    if definition.variable then return {} end
    if definition.damage then return { new_rule(definition) } end
    local rules = {}
    for _, state in ipairs(definition.states) do
        rules[#rules + 1] = { [definition.state_key] = state.value, targets = {} }
    end
    return rules
end

local function ordered_names(values, order)
    local names, seen, remaining = {}, {}, {}
    for _, name in ipairs(order or {}) do
        if values[name] ~= nil and not seen[name] then names[#names + 1] = name; seen[name] = true end
    end
    for name in pairs(values) do if not seen[name] then remaining[#remaining + 1] = name end end
    table.sort(remaining)
    for _, name in ipairs(remaining) do names[#names + 1] = name end
    return names
end

local function target_snapshot(targets)
    local result = {}
    for index, target in ipairs(targets or {}) do
        result[index] = { index = index, group = target.group or "", preset = target.preset or "" }
    end
    return result
end

local function number(value)
    assert(type(value) == "number" and value == value and math.abs(value) < math.huge, "条件数值无效")
    return value
end

local function indexed(list, index, message)
    assert(type(index) == "number" and index % 1 == 0 and index >= 1 and list[index], message)
    return list[index]
end

-- Web 只编辑明确的旧字段；保存失败按修改记录原位撤销，保留调用方持有的表引用。
function Conditions.new(deps)
    local model, T = deps.model, deps.translate
    local self = {}

    function self.snapshot(context)
        local config = context.config
        local snapshot = { enabled = not model.enabled_field or config[model.enabled_field] == true,
            canEnable = model.enabled_field ~= nil, parallel = config.is_parallel == true,
            selected = config.transform_type or model.default_selected, definitions = {}, targets = {},
            canTestHp = deps.test_hp ~= nil, canTestDamage = deps.test_damage ~= nil }
        local owners = { { name = "", label = T("main_list"), owner = config } }
        for _, name in ipairs(ordered_names(config.groups or {}, config.group_order)) do
            owners[#owners + 1] = { name = name, label = name, owner = config.groups[name] }
        end
        for _, item in ipairs(owners) do
            snapshot.targets[#snapshot.targets + 1] = { name = item.name, label = item.label,
                global = item.owner.is_global == true,
                presets = ordered_names(item.owner.presets or {}, item.owner.preset_order) }
        end
        for priority, definition in ipairs(model.definitions) do
            local setting = config.parallel_settings and config.parallel_settings[definition.id] or {}
            local row = { id = definition.id, label = T("condition_" .. definition.id),
                enabled = setting.enabled == true, priority = tonumber(setting.priority) or priority,
                canAdd = definition.variable == true, canRemove = definition.variable == true,
                fields = {}, rules = {} }
            if setting.enabled == nil then row.enabled = definition.id == model.default_selected end
            if deps.state then row.stateLabel, row.warning = deps.state(context, definition.id) end
            for _, field in ipairs(definition.fields) do
                local item = { key = field.key, label = T(field.label), kind = field.kind,
                    min = field.min, max = field.max, default = field.default }
                if field.options then
                    item.options = {}
                    for _, option in ipairs(field.options) do
                        item.options[#item.options + 1] = { value = option.value, label = T(option.label) }
                    end
                end
                if field.modes then
                    item.modes = {}; for _, mode in ipairs(field.modes) do item.modes[#item.modes + 1] = mode end
                end
                row.fields[#row.fields + 1] = item
            end
            for index, rule in ipairs(config[definition.field] or default_rules(definition)) do
                local item = { index = index, label = row.label, targets = target_snapshot(rule.targets) }
                if definition.state_key then
                    item[definition.state_key] = rule[definition.state_key]
                    item.label = Conditions.format_state(model, definition.id, rule[definition.state_key], T) or row.label
                end
                for _, field in ipairs(definition.fields) do
                    item[field.key] = rule[field.key]; if item[field.key] == nil then item[field.key] = field.default end
                end
                if definition.damage then
                    item.chain_nodes = {}
                    for node_index, node in ipairs(rule.chain_nodes or { { duration = 1, targets = {} } }) do
                        item.chain_nodes[node_index] = { index = node_index, duration = node.duration or 1,
                            targets = target_snapshot(node.targets) }
                    end
                end
                row.rules[#row.rules + 1] = item
            end
            snapshot.definitions[#snapshot.definitions + 1] = row
        end
        return snapshot
    end

    function self.action(request, context)
        if request.op == "test_hp" then
            if not deps.test_hp then return false, "当前游戏不支持血量测试" end
            local ok, value = pcall(number, request.value)
            if not ok then return false, value end
            return deps.test_hp(context, math.max(0, math.min(100, value)))
        elseif request.op == "test_damage" then
            if not deps.test_damage then return false, "当前游戏不支持受击测试" end
            return deps.test_damage(context)
        end
        local config, undo = context.config, {}
        local function set(owner, key, value)
            if owner[key] == value then return end
            local previous = owner[key]
            undo[#undo + 1] = function() owner[key] = previous end
            owner[key] = value
        end
        local function ensure(owner, key, value)
            if owner[key] == nil then set(owner, key, value or {}) end
            assert(type(owner[key]) == "table", "条件配置不是列表")
            return owner[key]
        end
        local function add(list, value)
            table.insert(list, value)
            undo[#undo + 1] = function() table.remove(list) end
        end
        local function remove(list, index)
            local previous = indexed(list, index, "条件节点已不存在")
            table.remove(list, index)
            undo[#undo + 1] = function() table.insert(list, index, previous) end
        end
        local function edit()
            local op, value = request.op, request.value
            if op == "parallel" or op == "enabled" then
                assert(type(value) == "boolean", "条件开关无效")
                assert(op ~= "enabled" or model.enabled_field, "当前游戏没有条件总开关")
                set(config, op == "parallel" and "is_parallel" or model.enabled_field, value)
                return
            elseif op == "select" then
                assert(find_definition(model, value), "条件类型无效")
                set(config, "transform_type", value)
                return
            end
            local definition = assert(find_definition(model, request.condition), "条件类型无效")
            if op == "setting" then
                assert(request.field == "enabled" or request.field == "priority", "并行条件字段无效")
                if request.field == "enabled" then assert(type(value) == "boolean", "条件开关无效") else number(value) end
                local settings = ensure(config, "parallel_settings")
                local priority
                for index, item in ipairs(model.definitions) do if item == definition then priority = index end end
                local setting = ensure(settings, definition.id,
                    { enabled = definition.id == model.default_selected, priority = priority })
                set(setting, request.field, value)
                return
            end
            local rules = ensure(config, definition.field, default_rules(definition))
            if op == "rule_add" or op == "rule_delete" then
                assert(definition.variable, "固定状态规则不能增删")
                if op == "rule_add" then add(rules, new_rule(definition)) else remove(rules, request.rule) end
                return
            end
            local rule = indexed(rules, request.rule, "条件规则已不存在")
            if op == "rule_set" then
                local field
                for _, item in ipairs(definition.fields) do if item.key == request.field then field = item end end
                assert(field, "条件规则字段不可编辑")
                if field.kind == "number" then
                    number(value)
                    if field.min then value = math.max(field.min, value) end
                    if field.max then value = math.min(field.max, value) end
                else
                    local valid = false
                    for _, option in ipairs(field.options) do if option.value == value then valid = true end end
                    assert(valid, "条件选项无效")
                end
                set(rule, field.key, value)
                return
            end
            local owner = rule
            if op == "chain_add" or op == "chain_delete" or op == "chain_set" or request.node ~= nil then
                assert(definition.damage, "当前条件没有链式节点")
                local nodes = ensure(rule, "chain_nodes", { { duration = 1, targets = {} } })
                if op == "chain_add" then add(nodes, { duration = 1, targets = {} }); return end
                if op == "chain_delete" then remove(nodes, request.node); return end
                owner = indexed(nodes, request.node, "链式节点已不存在")
                if op == "chain_set" then
                    assert(request.field == "duration", "链式节点字段不可编辑")
                    set(owner, "duration", math.max(0, number(value)))
                    return
                end
            end
            assert(op == "target_add" or op == "target_delete" or op == "target_set", "条件操作无效")
            local targets = ensure(owner, "targets")
            if op == "target_add" then
                local preset = ""
                if model.default_target_preset then
                    preset = config.default_preset or ""
                    if preset == "" then preset = next(config.presets or {}) or "" end
                end
                add(targets, { group = "", preset = preset })
            elseif op == "target_delete" then remove(targets, request.target)
            else
                local target = indexed(targets, request.target, "目标预设已不存在")
                assert(type(value) == "string", "目标名称无效")
                if request.field == "group" then
                    assert(value == "" or config.groups and config.groups[value], "目标分组已不存在")
                    if target.group ~= value then set(target, "group", value); set(target, "preset", "") end
                elseif request.field == "preset" then
                    local group = target.group or ""
                    local source = group == "" and config or config.groups and config.groups[group]
                    assert(value == "" or source and source.presets and source.presets[value] ~= nil, "目标预设已不存在")
                    set(target, "preset", value)
                else error("目标字段不可编辑") end
            end
        end
        local ok, reason = pcall(edit)
        if ok and #undo == 0 then return true end
        if ok then
            local saved, result, save_reason = pcall(deps.save, context)
            ok = saved and result == true
            reason = saved and save_reason or result
        end
        if not ok then
            for index = #undo, 1, -1 do undo[index]() end
            return false, reason or "条件配置保存失败"
        end
        if deps.refresh then deps.refresh(context) end
        return true
    end

    return self
end

return Conditions
