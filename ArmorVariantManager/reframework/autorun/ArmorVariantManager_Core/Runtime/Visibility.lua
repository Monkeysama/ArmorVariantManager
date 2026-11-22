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

    function editor.materials(id, part, meshes, changes, active_groups)
        if not deps.edit(id, part, changes, nil, meshes and meshes[1]) then return false end
        local rendered = {}
        for name, enabled in pairs(changes) do
            rendered[name] = enabled and not deps.hidden(part, name, active_groups)
        end
        for _, mesh in ipairs(meshes or {}) do
            if deps.valid(mesh) then
                local count = deps.call(mesh, "get_MaterialNum") or 0
                for index = 0, count - 1 do
                    local value = rendered[deps.call(mesh, "getMaterialName", index)]
                    if value ~= nil and deps.call(mesh, "getMaterialsEnable", index) ~= value then
                        deps.call(mesh, "setMaterialsEnable", index, value)
                    end
                end
            end
        end
        return true
    end
    return editor
end

return Visibility
