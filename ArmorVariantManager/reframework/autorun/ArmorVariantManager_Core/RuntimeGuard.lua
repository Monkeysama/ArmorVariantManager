-- 场景生命周期与全屏任务菜单门禁。只保存状态，不扫描角色、不写入游戏对象。
local RuntimeGuard = {}

-- 每次脚本启动创建独立状态，避免 require 缓存把上一次的暂停标记带进来。
function RuntimeGuard.new(clear_runtime)
    local guard = { generation = 0, suspended = false, active = false }
    local pending_clear, end_seen, saw_loading, scene_changed = false, false, false, false
    local requires_fade_in, stable_scene_key = false, ""
    local quest_menu_id, gui_manager, menu_latched = nil, nil, false
    local scene_type = sdk.find_type_definition("via.SceneManager")
    local flow_type = sdk.find_type_definition("app.GameFlowManager")
    local loading_getter = flow_type and (flow_type:get_method("get_Loading") or flow_type:get_method("get_Loading()"))

    -- 只在场景过渡期间或已有扫描批次中读取场景原生地址，避免正常帧重复查询。
    function guard:get_scene()
        if not scene_type then return nil, "" end
        local ok, scene, key = pcall(function()
            local manager = sdk.get_native_singleton("via.SceneManager")
            local current = manager and sdk.call_native_func(manager, scene_type, "get_CurrentScene")
            if not current then return nil, "" end
            local address = current:get_address()
            if not address or address == 0 then return nil, "" end
            return current, tostring(address)
        end)
        if not ok then return nil, "" end
        return scene, key
    end

    -- Hook 只标记过渡；清理统一由下一次 update 执行，不在原生回调里枚举/释放缓存。
    function guard:begin_transition(fade_in)
        if not self.active then
            self.generation = self.generation + 1
            self.active = true
            saw_loading, scene_changed, requires_fade_in = false, false, false
        end
        pending_clear, end_seen = true, false
        requires_fade_in = requires_fade_in or fade_in == true
        self.suspended = true
    end

    -- 快速旅行必须等待自己的 fade-in；普通任务的 load-end 不能提前释放黑屏过渡。
    function guard:mark_load_end(fade_in)
        if self.active and (not requires_fade_in or fade_in == true) then end_seen = true end
    end

    -- 扫描器已有采样发现跨场景时，先隔离，下一帧再恢复，不使用旧快照。
    function guard:accept_scene(key)
        if key == "" then return false end
        if stable_scene_key == "" then stable_scene_key = key; return true end
        if stable_scene_key == key then return true end
        self:begin_transition(false)
        scene_changed = true
        return false
    end

    -- 场景暂不可读时仅隔离当前帧；单个扫描对象失效不进入全局暂停。
    function guard:block_frame()
        self.suspended = true
    end

    -- 首次看见任务列表激活才暂停；内部子页不解除，GUI050000真正退出才恢复。
    local function is_quest_menu_open()
        if quest_menu_id == nil then
            local ok, value = pcall(function()
                local definition = sdk.find_type_definition("app.GUIID.ID")
                local field = definition and definition:get_field("UI050000")
                return field and field:get_data(nil)
            end)
            if ok then quest_menu_id = value end
        end
        if quest_menu_id == nil then return false end
        if not gui_manager then gui_manager = sdk.get_managed_singleton("app.GUIManager") end
        if not gui_manager then return menu_latched end
        local ok, gui = pcall(function() return gui_manager:call("getGUI(app.GUIID.ID)", quest_menu_id) end)
        if not ok then gui_manager = nil; return menu_latched end
        if not gui then menu_latched = false; return false end
        if menu_latched then return true end
        local active_ok, active = pcall(function()
            local parts = gui:get_field("_QuestListParts")
            return parts and parts:call("get_IsActive")
        end)
        if active_ok then menu_latched = active == true end
        return menu_latched
    end

    -- 每帧一次轻量门禁；正常时不读取 Scene、不扫描角色。菜单暂停不清缓存。
    function guard:update()
        local ok, loading = pcall(function()
            local manager = loading_getter and sdk.get_managed_singleton("app.GameFlowManager")
            return manager and loading_getter:call(manager) == true or false
        end)
        if not ok then self.suspended = true; return true end
        if loading and not self.active then self:begin_transition(false) end
        if self.active then
            if pending_clear then
                clear_runtime()
                pending_clear = false
                gui_manager, menu_latched = nil, false
            end
            if loading then saw_loading = true; return true end
            local _, key = self:get_scene()
            local ready = requires_fade_in and end_seen
                or (not requires_fade_in and (end_seen or saw_loading or scene_changed))
            if not ready or key == "" then return true end
            stable_scene_key = key
            self.active = false
            end_seen, saw_loading, scene_changed, requires_fade_in = false, false, false, false
        end
        self.suspended = is_quest_menu_open()
        return self.suspended
    end

    -- 仅启动时安装低频生命周期 Hook；不改变原函数参数、返回值或执行流程。
    function guard:install_hooks()
        local function install(type_name, method_name, before, after)
            local definition = sdk.find_type_definition(type_name)
            local plain_name = method_name:gsub("%(%)$", "")
            local method = definition and (definition:get_method(method_name)
                or definition:get_method(plain_name))
            if not method then return false end
            return pcall(function()
                sdk.hook(method, function()
                    if before then before() end
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval)
                    if after then after() end
                    return retval
                end)
            end)
        end
        install("app.EnvironmentManager", "evSceneLoadBefore()", function() self:begin_transition(false) end)
        install("app.EnvironmentManager", "evSceneLoadEnd()", nil, function() self:mark_load_end(false) end)
        for _, name in ipairs({"evSceneLoadEnd()", "evSceneLoadEnd_FastTravel()",
            "evSceneLoadEnd_SceneTransition()", "evSceneLoadEnd_ThroughJunction()"}) do
            install("app.PlayerManager", name, nil, function() self:mark_load_end(false) end)
        end
        local fade_ready = install("app.CameraManager", "onSceneLoadFadeIn()", nil,
            function() if self.active and requires_fade_in then self:mark_load_end(true) end end)
        if fade_ready then
            install("app.mcFastTravel", "setupLoadingEvent", function()
                if not self.active then self:begin_transition(true) end
            end)
        end
    end
    return guard
end

return RuntimeGuard
