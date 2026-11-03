local Options = {}

-- 保留崛起原有帧率、渲染比例和多人选项，钩子与界面共用同一设置实例。
function Options.new(global_config, runtime, T, save_global_settings)
    local PlayerDir, DissolveTransition = runtime.actors, runtime.transition
    local app = sdk.get_native_singleton("via.Application")
    local set_MaxFps = app and sdk.find_type_definition("via.Application"):get_method("set_MaxFps")
    local render = sdk.get_native_singleton("via.render.Renderer")
    local set_ImageQualityRate = render and sdk.find_type_definition("via.render.Renderer"):get_method("set_ImageQualityRate")

    -- 应用帧率（自动模式：读取游戏选项中的帧率上限）
    local function apply_fps_cap()
        if not app or not set_MaxFps then return end
        local stmOptionManager = sdk.get_managed_singleton("snow.StmOptionManager")
        if stmOptionManager then
            local optionContainer = stmOptionManager:get_field("_StmOptionDataContainer")
            if optionContainer then
                local frameRateOption = optionContainer:call("getFrameRateOption") -- 返回 0~7 对应 fps_option 索引
                local fps_option = { 30, 60, 90, 120, 144, 165, 240, 600 }
                local desiredFPS = fps_option[frameRateOption + 1] or 60
                set_MaxFps:call(app, desiredFPS + 0.0)
            end
        end
    end

    -- 应用渲染比例
    local function apply_image_quality()
        if not render or not set_ImageQualityRate then return end
        if global_config.enable_image_quality then
            set_ImageQualityRate:call(render, global_config.image_quality_rate + 0.0)
        end
    end

    -- 钩子函数：当游戏选项改变或过场动画播放时刷新帧率
    local function on_game_option_changed()
        apply_fps_cap()
        apply_image_quality()
    end

    -- 安全 hook（如果目标函数存在）
    local function safe_hook(type_def, method_name, pre_cb, post_cb)
        if type_def and type_def.get_method then
            local method = type_def:get_method(method_name)
            if method then
                sdk.hook(method, pre_cb or function() end, post_cb or function(ret) return ret end)
                return true
            end
        end
        return false
    end

    -- Hook 游戏选项写入（修改帧率触发）
    local stmOptionManagerType = sdk.find_type_definition("snow.StmOptionManager")
    if stmOptionManagerType then
        safe_hook(stmOptionManagerType, "writeGraphicOptionOnIniFile", nil, on_game_option_changed)
    end

    -- Hook 过场动画播放（确保过场中帧率正确）
    local uniqueEventManagerType = sdk.find_type_definition("snow.eventcut.UniqueEventManager")
    if uniqueEventManagerType then
        safe_hook(uniqueEventManagerType, "playEventCommon", nil, on_game_option_changed)
    end

    -- Hook 渲染质量变更（确保渲染比例被重新应用）
    local renderAppManagerType = sdk.find_type_definition("snow.RenderAppManager")
    if renderAppManagerType then
        safe_hook(renderAppManagerType, "setSamplerQuality", nil, apply_image_quality)
    end

    -- 初始化时立即应用一次
    apply_fps_cap()
    apply_image_quality()

    local function draw_multiplayer_panel()
        if not imgui.tree_node(T("d2d_settings_multiplayer") .. "##avm_multiplayer") then
            return
        end
        local changed_multi, new_multi = imgui.checkbox(T("enable_multiplayer") .. "##mp_enable",
            global_config.enable_multiplayer ~= false)
        if changed_multi then
            global_config.enable_multiplayer = new_multi == true
            save_global_settings()
        end
        imgui.text(T("runtime_teammate_hint"))
        if global_config.enable_multiplayer == false then
            imgui.text_colored(T("multiplayer_local_only"), 0xFF80C0FF)
        else
            imgui.text_colored(T("multiplayer_desc"), 0xFF909090)
        end
        imgui.separator()
        imgui.text_colored(T("players_title"), 0xFF80C0FF)
        local dir = PlayerDir.get()
        if #dir.entries == 0 then
            imgui.text_colored(T("player_none"), 0xFF8080FF)
            imgui.text_colored(T("player_none_hint"), 0xFF909090)
        else
            for _, entry in ipairs(dir.entries) do
                -- - 用目录建表时缓存好的名字：这里每帧都会执行，
                --   不能每帧为每个玩家各做一次托管调用。
                local name = entry.name or "?"
                local tag = entry.is_local and T("player_local") or T("player_other")
                imgui.text(string.format(T("player_line"), tag, name, tostring(entry.index or "?")))
            end
            local local_name = (dir.local_entry and dir.local_entry.name) or "?"
            imgui.text_colored(string.format(T("players_summary"), #dir.entries, local_name), 0xFF80FF80)
        end
        imgui.tree_pop()
    end

    local function draw_performance()
        DissolveTransition:draw_ui(T)
        imgui.separator()
        local changed_iq_enable, new_iq_enable = imgui.checkbox(T("enable_image_quality") or "Enable Custom Image Quality", global_config.enable_image_quality)
        if changed_iq_enable then
            global_config.enable_image_quality = new_iq_enable
            save_global_settings()
            apply_image_quality()
        end
        if global_config.enable_image_quality then
            local current_rate = global_config.image_quality_rate
            local changed_rate, new_rate = imgui.slider_float(T("image_quality_rate") or "Image Quality (%)", current_rate, 0.1, 4.0)
            if changed_rate then
                global_config.image_quality_rate = new_rate
                save_global_settings()
                apply_image_quality()
            end
            imgui.same_line()
            imgui.text(string.format("(%d%%)", math.floor(global_config.image_quality_rate * 100)))
        end

    end
    return {multiplayer = draw_multiplayer_panel, performance = draw_performance}
end

return Options
