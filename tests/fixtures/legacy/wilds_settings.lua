-- 冻结 4883c8e 的默认值及加载规则，用作兼容对照。
return function(env)
 local _ENV=env
local global_config = {
    language = "zh", -- 默认语言: zh (中文), en (英文)
    scan_interval = 0.5, -- 全量扫描间隔 (秒)
    body_id_ttl = 1.0, -- Body ID 缓存有效期 (秒)，默认缩短以加速换装检测
    scanner_batch_size = 200, -- 每帧扫描的对象数量
    new_ui_enabled = true, -- 是否启用新UI
    new_ui_key = 0x24, -- 新UI快捷键，默认 Home
    auto_set_selected_preset_as_default = true -- 选中预设时自动保存为默认预设
}
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
return {value=global_config, load=load_global_settings}
end
