local Visibility = {}

-- 界面提交意图，游戏侧提供对象读写；全局隐藏只约束显示，不覆盖草稿。
function Visibility.new(deps)
    local editor = {}
    function editor.mesh(id, part, meshes, enabled)
        if not deps.edit(id, part, nil, enabled) then return false end
        for _, mesh in ipairs(meshes or {}) do
            if deps.valid(mesh) then deps.call(mesh, "set_Enabled", enabled) end
        end
        return true
    end

    function editor.material(id, part, meshes, name, enabled)
        if not deps.edit(id, part, name, enabled) then return false end
        local rendered = enabled
        if enabled and deps.hidden(part, name) then rendered = false end
        for _, mesh in ipairs(meshes or {}) do
            if deps.valid(mesh) then
                local count = deps.call(mesh, "get_MaterialNum") or 0
                for index = 0, count - 1 do
                    if deps.call(mesh, "getMaterialName", index) == name then
                        deps.call(mesh, "setMaterialsEnable", index, rendered)
                    end
                end
            end
        end
        return true
    end
    return editor
end

return Visibility
