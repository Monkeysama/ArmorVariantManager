local HeightEditor = {}

function HeightEditor.new(app, driver)
    local workspace = app.workspace
    local state = workspace.state
    local active_overrides = app.appearance.overrides
    local ground_clipping_presets = app.appearance.height
    -- 新旧界面共用预设草稿，实时预览；新增或覆盖预设时才持久化到 JSON 和备份。
    local function get_ground_clipping_settings()
        local group = state.group == "" and workspace.config or workspace.config.groups and workspace.config.groups[state.group]
        local body_id = workspace.get_body_id()
        local selected = workspace.get_effective_group_presets(body_id)[state.group]
            or group and group.default_preset
        return ground_clipping_presets.get_editor(workspace.config, body_id, state.group, selected)
    end

    local function set_ground_clipping_settings(changes, body_id)
        if state.weapon or not body_id or body_id ~= state.body_id or body_id ~= workspace.get_body_id() then return false end
        local group = state.group == "" and workspace.config or workspace.config.groups and workspace.config.groups[state.group]
        local selected = workspace.get_effective_group_presets(body_id)[state.group]
            or group and group.default_preset
        local settings = ground_clipping_presets.edit(workspace.config, body_id, state.group, selected, changes)
        if not active_overrides[body_id] then active_overrides[body_id] = {} end
        -- 取消勾选只退出本预设的高度控制，不撤销之前的有效高度；归零需勾选并设置 0 cm。
        if settings.enabled then active_overrides[body_id].ground_clipping_fix = settings end
        driver.settings_changed()
        return true
    end

    return {get=get_ground_clipping_settings, set=set_ground_clipping_settings, status=driver.get_status}
end

return HeightEditor
