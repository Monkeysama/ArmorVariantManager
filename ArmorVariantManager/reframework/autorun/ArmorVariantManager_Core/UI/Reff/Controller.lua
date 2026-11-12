local themes = {custom=true, reff=true, white=true, black=true, glass=true}
local Controller = {}

-- 网页与原生界面共用上下文和操作，只向桥接返回值类型。
function Controller.theme(value)
    return themes[value] and value or "custom"
end

function Controller.new(deps)
    local controller = {}
    function controller.snapshot()
        local context = deps.context()
        local snapshot = {
            game=deps.game, version=deps.version, bodyId=context.id or "", weapon=context.weapon,
            suspended=context.suspended, groups={}, group=context.group or "", presets={},
            selectedPreset=context.selected or "", parts={}, theme=deps.theme(), language=deps.language(),
            selectionMode=context.selecting, pending={}, backupPending=false, canImport=deps.imports ~= nil,
        }
        if deps.settings then snapshot.settings = deps.settings.snapshot(context) end
        if deps.preview then snapshot.preview = deps.preview.snapshot() end
        if not context.id then return snapshot end
        snapshot.backupPending = deps.backup_pending and deps.backup_pending(context.id) == true or false
        snapshot.groups[1] = {name="", label=deps.main_label(), global=false}
        for _, global in ipairs({true,false}) do
            for _, name in ipairs(context.group_names) do
                local group = context.config.groups[name]
                if group and (group.is_global == true) == global then
                    snapshot.groups[#snapshot.groups+1] = {name=name,label=name,global=global}
                end
            end
        end
        local group = context.group == "" and context.config or context.config.groups[context.group]
        for _, name in ipairs(context.preset_names) do
            snapshot.presets[#snapshot.presets+1] = {
                name=name, default=group and group.default_preset == name or false, active=context.selected == name,
            }
        end
        snapshot.parts = deps.parts(context)
        if deps.conditions then snapshot.conditions = deps.conditions.snapshot(context) end
        for part, materials in pairs(context.pending) do
            local copy = {}
            for name, selected in pairs(materials) do copy[name] = selected == true end
            snapshot.pending[tostring(part)] = copy
        end
        return snapshot
    end

    function controller.preview(request)
        return deps.preview and deps.preview.action(request) or {available=false,enabled=false,status="preview_native_missing"}
    end

    -- 长文档按需读取，不随每秒装备快照重复传输。
    function controller.documentation()
        return deps.documentation and deps.documentation() or {sections={}}
    end

    -- 文件清单只在选择器打开时读取，不随装备快照扫描磁盘。
    function controller.imports()
        local context = deps.context()
        local result = {bodyId=context.id or "", files={}}
        if not deps.imports or not context.id or context.suspended then return result end
        for _, file in ipairs(deps.imports(context)) do
            result.files[#result.files+1] = {path=file.path, name=file.name}
        end
        return result
    end

    -- 换装和场景切换后的旧网页请求不能修改新装备。
    function controller.action(request)
        assert(type(request) == "table", "操作参数无效")
        local kind = request.kind
        if kind == "theme" then
            assert(themes[request.value] == true, "主题选项无效")
            assert(deps.set_theme(request.value), "主题保存失败")
        elseif kind == "mode" then
            assert(type(request.weapon) == "boolean", "装备模式无效")
            deps.set_mode(request.weapon)
        elseif kind == "setting" then
            assert(deps.settings, "设置不可用")
            local success, reason = deps.settings.action(request, deps.context())
            assert(success, reason or "设置未保存，请重试")
        else
            local context = deps.context()
            assert(context.id and not context.suspended, "角色不可用或正在切换装备")
            assert(request.bodyId == context.id, "装备已变化，请重新操作")
            local operation = kind == "condition" and deps.conditions and deps.conditions.action or deps.operations[kind]
            assert(operation, "未知操作: " .. tostring(kind))
            local success, reason = operation(request, context)
            assert(success, reason or "操作未保存，请重试")
        end
        return controller.snapshot()
    end
    return controller
end

return Controller
