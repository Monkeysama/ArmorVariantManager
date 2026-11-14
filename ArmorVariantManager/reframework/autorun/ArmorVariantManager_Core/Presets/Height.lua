local Height = {}

-- 旧 JSON 不需要迁移；缺失配置默认关闭，高度默认 10 cm。
function Height.bounded_height(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return 10 end
    return math.max(-10, math.min(50, value))
end

function Height.read_settings(value)
    value = type(value) == "table" and value or {}
    return { enabled = value.enabled == true, height_cm = Height.bounded_height(value.height_cm) }
end

-- 兼容开发过渡版保存过的字段；新修改只写入陷地修复自己的配置，不迁移旧预设结构。
function Height.config_settings(config)
    if type(config) ~= "table" then return nil end
    if config.ground_clipping_fix ~= nil then return config.ground_clipping_fix end
    return config.high_heel_height
end

-- 新预设自带启用状态和高度；旧预设继续读取过渡版的装备级配置。
function Height.preset_settings(preset, config)
    return Height.read_settings(type(preset) == "table" and preset.ground_clipping_fix
        or Height.config_settings(config))
end

-- 只有勾选的预设参与高度控制；勾选且为 0 cm 时仍是有效的归零指令。
function Height.participating_settings(preset, config)
    local settings = Height.preset_settings(preset, config)
    if settings.enabled then return settings end
    return nil
end

-- 多组同时加载时按默认分组、普通分组、全局分组顺序取最后一个勾选预设的高度。
-- 分组内使用 UI 排序，旧 JSON 缺少排序的部分按名称排序，避免 pairs 导致高度随机变化。
function Height.default_settings(config, global_default)
    config = config or {}
    local settings = Height.preset_settings(config.presets and config.presets[config.default_preset], config)
    local ordered, seen, missing = {}, {}, {}
    for _, name in ipairs(config.group_order or {}) do
        if config.groups and config.groups[name] and not seen[name] then
            ordered[#ordered + 1], seen[name] = name, true
        end
    end
    for name in pairs(config.groups or {}) do
        if not seen[name] then missing[#missing + 1] = name end
    end
    table.sort(missing)
    for _, name in ipairs(missing) do ordered[#ordered + 1] = name end
    for _, global in ipairs({ false, true }) do
        for _, name in ipairs(ordered) do
            local group = config.groups[name]
            local selected = global and group.is_global and global_default and global_default(group) or group.default_preset
            local preset = group.presets and group.presets[selected]
            if (group.is_global == true) == global and preset then
                settings = Height.participating_settings(preset, config) or settings
            end
        end
    end
    return settings
end

-- 草稿不写 JSON；新建或覆盖预设时才捕获。运行值按角色隔离，不受打开武器 UI 影响。
function Height.new_preset_state()
    local drafts, runtime = {}, setmetatable({}, { __mode = "k" })
    local state = {}
    function state.get_editor(config, body_id, group_name, preset_name)
        local body = drafts[body_id]
        local draft = body and body.config == config and body.groups[group_name]
        if draft and draft.preset_name == preset_name then return Height.read_settings(draft.settings) end
        local group = group_name == "" and config or config.groups and config.groups[group_name]
        return Height.preset_settings(group and group.presets and group.presets[preset_name], config)
    end
    function state.edit(config, body_id, group_name, preset_name, changes)
        local settings = state.get_editor(config, body_id, group_name, preset_name)
        if changes.enabled ~= nil then settings.enabled = changes.enabled == true end
        if changes.height_cm ~= nil then settings.height_cm = Height.bounded_height(changes.height_cm) end
        if not drafts[body_id] or drafts[body_id].config ~= config then drafts[body_id] = { config = config, groups = {} } end
        drafts[body_id].groups[group_name] = { preset_name = preset_name, settings = settings }
        return settings
    end
    function state.reset(body_id, group_name)
        if group_name == nil then drafts[body_id] = nil
        elseif drafts[body_id] then drafts[body_id].groups[group_name] = nil end
    end
    function state.set_runtime(character, config, settings)
        if not character or not config then return end
        -- SDK 可能为同一角色返回不同 Lua 包装对象；与主脚本角色缓存一样按稳定字符串标识索引。
        local entry = runtime[config]
        if not entry then entry = {}; runtime[config] = entry end
        entry[tostring(character)] = settings
    end
    function state.get_runtime(character, config, base)
        local entry = runtime[config]
        local settings = entry and entry[tostring(character)]
        if settings then return settings end
        return base or Height.default_settings(config)
    end
    return state
end

return Height
