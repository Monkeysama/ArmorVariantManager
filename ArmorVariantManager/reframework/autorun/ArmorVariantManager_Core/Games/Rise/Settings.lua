local Settings = {}

-- 创建游戏自己的全局默认值，不改写旧字段名称。
function Settings.new()
    return {
        language = "zh",
        scan_interval = 0.5,
        body_id_ttl = 1.0,
        scanner_batch_size = 100,
        enable_image_quality = false,
        image_quality_rate = 1.0,
        new_ui_enabled = true,
        new_ui_key = 0x24,
        new_ui_mute_game_input = true,
        new_ui_backend = "auto",
        new_ui_debug_force_visible = false,
        new_ui_debug_manual_picker = false,
        auto_set_selected_preset_as_default = true,
        debug_profile = false,
        enable_multiplayer = true,
        multiplayer_players_per_tick = 1,
        multiplayer_weapon_scan_interval = 2.0,
        scene_scan_batch = 24
    }
end

-- 保留旧配置的可选读取、布尔含义和数值范围。
function Settings.apply(global_config, loaded)
    if loaded.language then global_config.language = loaded.language end
    if loaded.scan_interval then global_config.scan_interval = loaded.scan_interval end
    if loaded.body_id_ttl then global_config.body_id_ttl = loaded.body_id_ttl end
    if loaded.scanner_batch_size then global_config.scanner_batch_size = loaded.scanner_batch_size end
    if loaded.enable_image_quality ~= nil then global_config.enable_image_quality = loaded.enable_image_quality end
    if loaded.image_quality_rate then global_config.image_quality_rate = loaded.image_quality_rate end
    if loaded.new_ui_enabled ~= nil then global_config.new_ui_enabled = loaded.new_ui_enabled == true end
    if loaded.new_ui_key then global_config.new_ui_key = loaded.new_ui_key end
    if loaded.new_ui_mute_game_input ~= nil then
        global_config.new_ui_mute_game_input = loaded.new_ui_mute_game_input == true
    end
    if loaded.new_ui_backend == "native" or loaded.new_ui_backend == "imgui"
        or loaded.new_ui_backend == "auto" then
        global_config.new_ui_backend = loaded.new_ui_backend
    end
    if loaded.new_ui_debug_force_visible ~= nil then
        global_config.new_ui_debug_force_visible = loaded.new_ui_debug_force_visible == true
    end
    if loaded.new_ui_debug_manual_picker ~= nil then
        global_config.new_ui_debug_manual_picker = loaded.new_ui_debug_manual_picker == true
    end
    if loaded.auto_set_selected_preset_as_default ~= nil then
        global_config.auto_set_selected_preset_as_default =
            loaded.auto_set_selected_preset_as_default == true
    end
    if loaded.debug_profile ~= nil then
        global_config.debug_profile = loaded.debug_profile == true
    end
    if loaded.enable_multiplayer ~= nil then
        global_config.enable_multiplayer = loaded.enable_multiplayer == true
    end
    if tonumber(loaded.multiplayer_players_per_tick) then
        local n = math.floor(tonumber(loaded.multiplayer_players_per_tick))
        if n < 0 then n = 0 elseif n > 8 then n = 8 end
        global_config.multiplayer_players_per_tick = n
    end
    if tonumber(loaded.multiplayer_weapon_scan_interval) then
        local v = tonumber(loaded.multiplayer_weapon_scan_interval)
        if v < 0.2 then v = 0.2 elseif v > 30.0 then v = 30.0 end
        global_config.multiplayer_weapon_scan_interval = v
    end
    if tonumber(loaded.scene_scan_batch) then
        local b = math.floor(tonumber(loaded.scene_scan_batch))
        if b < 4 then b = 4 elseif b > 128 then b = 128 end
        global_config.scene_scan_batch = b
    end
end

return Settings
