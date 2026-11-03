local Controller = {}

-- 网页与原生界面共用上下文和操作，只向桥接返回值类型。
function Controller.new(deps)
    local controller = {}
    function controller.snapshot()
        local context = deps.context()
        local snapshot = {
            game=deps.game, version=deps.version, bodyId=context.id or "", weapon=context.weapon,
            suspended=context.suspended, groups={}, group=context.group or "", presets={},
            selectedPreset=context.selected or "", parts={}, theme=deps.theme(), language=deps.language(),
            selectionMode=context.selecting, pending={},
        }
        if not context.id then return snapshot end
        snapshot.groups[1] = {name="", label=deps.main_label(), global=false}
        for _, name in ipairs(context.group_names) do
            local group = context.config.groups[name]
            if group then snapshot.groups[#snapshot.groups+1] = {name=name,label=name,global=group.is_global == true} end
        end
        local group = context.group == "" and context.config or context.config.groups[context.group]
        for _, name in ipairs(context.preset_names) do
            snapshot.presets[#snapshot.presets+1] = {
                name=name, default=group and group.default_preset == name or false, active=context.selected == name,
            }
        end
        snapshot.parts = deps.parts(context)
        for part, materials in pairs(context.pending) do
            local copy = {}
            for name, selected in pairs(materials) do copy[name] = selected == true end
            snapshot.pending[tostring(part)] = copy
        end
        return snapshot
    end

    -- 换装和场景切换后的旧网页请求不能修改新装备。
    function controller.action(request)
        assert(type(request) == "table", "操作参数无效")
        local kind = request.kind
        if kind == "theme" then
            assert(request.value == "custom" or request.value == "reff", "主题选项无效")
            assert(deps.set_theme(request.value), "主题保存失败")
        elseif kind == "mode" then
            assert(type(request.weapon) == "boolean", "装备模式无效")
            deps.set_mode(request.weapon)
        else
            local context = deps.context()
            assert(context.id and not context.suspended, "角色不可用或正在切换装备")
            assert(request.bodyId == context.id, "装备已变化，请重新操作")
            local operation = deps.operations[kind]
            assert(operation, "未知操作: " .. tostring(kind))
            local success, reason = operation(request, context)
            assert(success, reason or "操作未保存，请重试")
        end
        return controller.snapshot()
    end
    return controller
end

return Controller
