local Settings = {}

-- 创建游戏自己的全局默认值，不改写旧字段名称。
function Settings.new()
    return {
        language = "zh",
        reff_scale_with_panel = false,
        scan_interval = 0.5,
        body_id_ttl = 1.0,
        scanner_batch_size = 200,
        new_ui_enabled = true,
        new_ui_key = 0x24,
        auto_set_selected_preset_as_default = true
    }
end

-- 保留旧配置的可选读取、布尔含义和数值范围。
function Settings.apply(global_config, loaded)
    if loaded.reff_scale_with_panel ~= nil then global_config.reff_scale_with_panel = loaded.reff_scale_with_panel == true end
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

return Settings
