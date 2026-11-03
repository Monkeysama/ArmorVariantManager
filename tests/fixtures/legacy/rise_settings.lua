-- 冻结 093c61c 的默认值及加载规则，用作兼容对照。
return function(env)
 local _ENV=env
local global_config = {
    language = "zh", -- 默认语言: zh (中文), en (英文)
    scan_interval = 0.5, -- 全量扫描间隔 (秒)
    body_id_ttl = 1.0, -- 旧版本配置兼容；3.3.0 按部件有效性与签名更新
    scanner_batch_size = 100, -- 每帧扫描的对象数量
    enable_image_quality = false,      -- 是否启用自定义渲染比例
    image_quality_rate = 1.0,          -- 渲染比例（1.0 = 100%）
    new_ui_enabled = true,             -- 是否启用新版独立 UI 面板（关闭则使用旧版 ImGui 面板）
    new_ui_key = 0x24,                 -- 新版面板开关按键（默认 Home）
    new_ui_mute_game_input = true,     -- 面板打开时是否屏蔽游戏输入（释放鼠标 / 视角不乱转）
    -- 新版 UI 的绘制后端：
    --   "auto"   = 优先用原生 reframework-d2d 插件，没有则用内置 draw 绘制后端
    --   "imgui"  = 兼容旧配置名，强制使用内置 draw 后端（默认字体，无需原生插件）
    --   "native" = 优先使用原生插件，不可用时自动使用内置绘制
    new_ui_backend = "auto",
    new_ui_debug_force_visible = false, -- 调试用：强制显示新版面板（不需要按 Hotkey）
    new_ui_debug_manual_picker = false, -- 调试用：自动打开「手动查找预设」文件列表
    auto_set_selected_preset_as_default = true, -- 点击预设时是否自动记录为默认预设
    debug_profile = false,             -- 性能诊断：把每帧各环节耗时写入 ArmorVariantManager/Profile.json

    -- ===== 联机（多人）=====
    -- 差分配置是按「模型名（body_id）」保存的，所以同一套模型的玩家天然共用同一份配置。
    -- 打开后：除了本地玩家（主角），场景里的其他玩家也会被应用差分 —— 队友穿着同一套
    -- 模型时就能看到同样的差分效果（与荒野版本行为一致）。
    -- 关闭后：只处理本地玩家，行为与 v3.0.6 完全相同。
    enable_multiplayer = true,
    -- 每轮最多处理几个「其他玩家」（摊到多帧执行，避免多人时掉帧）。
    -- 本地玩家永远每轮都处理，不受这个值影响；其他玩家按轮询依次处理。
    multiplayer_players_per_tick = 1,
    -- 「其他玩家」的武器部件重新查找间隔（秒）。武器部件的递归查找偏贵，
    -- 所以对非本地玩家做限频；本地玩家不受影响。
    multiplayer_weapon_scan_interval = 2.0,
    -- 场景兜底扫描每帧处理多少个 Transform 组件。
    -- - 这个值直接决定「扫描期间每帧多花多少时间」：实测单个组件约 3.6us，
    --   24 个/帧 ≈ 0.086ms/帧（帧时间的 1.4%），野外的 8000 个组件约 2~3 秒扫完。
    --   调大 = 恢复更快但扫描期间更吃帧；调小 = 更省但恢复更慢。
    --   （只在「PlayerManager 完全给不出本地玩家」时才会真正扫描，正常游玩为 0。）
    scene_scan_batch = 24
}
local function load_global_settings()
    local loaded = json.load_file(global_config_path)
    if loaded then
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
end
return {value=global_config, load=load_global_settings}
end
