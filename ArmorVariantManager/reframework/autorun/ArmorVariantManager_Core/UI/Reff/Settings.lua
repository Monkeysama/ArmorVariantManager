local Settings = {}

-- 两款游戏都有运行消费者的全局选项；专属设置由游戏模型补充。
function Settings.sections(defaults)
    return {
        { id = "general", label = "d2d_settings_tab", scope = "global", fields = {
            { id = "language", label = "d2d_settings_language", type = "select", default = defaults.language,
                options = { { value = "zh", label = "d2d_language_chinese" },
                    { value = "en", label = "d2d_language_english" } } },
            { id = "auto_set_selected_preset_as_default", label = "auto_set_selected_preset_as_default",
                type = "boolean", default = defaults.auto_set_selected_preset_as_default },
        } },
    }
end

local function read(config, field)
    if field.read then return field.read() end
    local owner = field.owner or config
    local path = field.path or { field.id }
    for _, key in ipairs(path) do
        if type(owner) ~= "table" then return field.default end
        owner = owner[key]
    end
    if owner == nil then return field.default end
    return owner
end

local function validate(field, value)
    if field.type == "action" then
        return nil
    elseif field.type == "boolean" then
        assert(type(value) == "boolean", "设置开关无效")
    elseif field.type == "number" then
        assert(type(value) == "number" and value == value and math.abs(value) < math.huge, "设置数值无效")
        if field.integer then value = math.floor(value) end
        if field.min then value = math.max(field.min, value) end
        if field.max then value = math.min(field.max, value) end
    else
        local valid = false
        for _, option in ipairs(field.options or {}) do if option.value == value then valid = true end end
        assert(valid, "设置选项无效")
    end
    return value
end

-- 只输出元数据与值。写盘前的字段修改可原位撤销，写盘后才应用游戏副作用。
function Settings.new(deps)
    local model, session, T = deps.model, deps.global_session, deps.translate
    local config, self = session.value, {}
    local function apply_saved(id, value, context)
        local function apply(callback)
            if not callback then return true end
            local applied, result, apply_reason = pcall(callback, id, value, context)
            if not applied or result == false then
                return false, "设置已保存，但应用失败: " .. tostring(applied and apply_reason or result)
            end
            return true
        end
        local applied, reason = apply(model.on_saved)
        if not applied then return false, reason end
        return apply(deps.on_saved)
    end

    function self.snapshot(_context)
        local result = { sections = {} }
        for _, section in ipairs(model.sections) do
            local row = { id = section.id, label = T(section.label), scope = section.scope, fields = {} }
            if section.description then row.description = T(section.description) end
            for _, field in ipairs(section.fields) do
                local item = { id = field.id, label = T(field.label), type = field.type,
                    min = field.min, max = field.max, step = field.step }
                if field.type ~= "action" then item.value = read(config, field) end
                if field.description then item.description = T(field.description) end
                if field.available then
                    local available, reason = field.available()
                    if not available then item.disabled, item.reason = true, reason end
                end
                if field.options then
                    item.options = {}
                    for _, option in ipairs(field.options) do
                        item.options[#item.options + 1] = { value = option.value, label = T(option.label) }
                    end
                end
                row.fields[#row.fields + 1] = item
            end
            result.sections[#result.sections + 1] = row
        end
        return result
    end

    function self.action(request, context)
        local field
        for _, section in ipairs(model.sections) do
            for _, item in ipairs(section.fields) do if item.id == request.id then field = item end end
        end
        if not field then return false, "设置项不存在" end
        if field.available then
            local available, reason = field.available()
            if not available then return false, reason end
        end
        local valid, value = pcall(validate, field, request.value)
        if not valid then return false, value end
        local owner, undo = field.owner or config, {}
        local function set(target, key, entry)
            local previous = target[key]
            if previous == entry then return end
            undo[#undo + 1] = function() target[key] = previous end
            target[key] = entry
        end
        local ok, reason = pcall(function()
            local path = field.path or { field.id }
            for index = 1, #path - 1 do
                local key = path[index]
                if owner[key] == nil then set(owner, key, {}) end
                assert(type(owner[key]) == "table", "设置配置不是对象")
                owner = owner[key]
            end
            local key = path[#path]
            if field.type == "action" then
                if owner[key] == nil then set(owner, key, {}) end
                assert(type(owner[key]) == "table", "设置配置不是对象")
                for name, entry in pairs(field.reset_values) do set(owner[key], name, entry) end
            else set(owner, key, value) end
        end)
        if ok and #undo == 0 then return apply_saved(request.id, value, context) end
        if ok then
            local saved, result, save_reason = pcall(field.save or session.save)
            ok, reason = saved and result == true, saved and save_reason or result
        end
        if not ok then
            for index = #undo, 1, -1 do undo[index]() end
            return false, reason or "设置保存失败"
        end
        return apply_saved(request.id, value, context)
    end

    return self
end

return Settings
