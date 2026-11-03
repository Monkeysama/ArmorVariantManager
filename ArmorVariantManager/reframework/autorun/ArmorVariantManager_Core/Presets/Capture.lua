local Capture = {}

-- 部件发现和取值策略由游戏提供；同部位多个网格合并到旧 JSON 的同一个索引。
function Capture.read(parts, call, accepts, material_value, keep_mesh, keep_empty)
    local result = {}
    for index, meshes in pairs(parts) do
        local part = {materials={}}
        for _, mesh in ipairs(meshes) do
            if keep_mesh and part.mesh_enabled == nil then
                part.mesh_enabled = call(mesh, "get_Enabled")
            end
            local count = call(mesh, "get_MaterialNum")
            if count then
                for offset = 0, count - 1 do
                    local name = call(mesh, "getMaterialName", offset)
                    if accepts(index, name) then
                        part.materials[name] = material_value(index, name, mesh, offset, call)
                    end
                end
            end
        end
        if #meshes > 0 and (next(part.materials) or keep_empty) then result[tostring(index)] = part end
    end
    return result
end

return Capture
