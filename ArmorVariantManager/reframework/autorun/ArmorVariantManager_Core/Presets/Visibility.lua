local Visibility = {}

-- 更新单个部件的手动草稿，材质可逐项或按名称批量写入。
function Visibility.set(draft, part, material, enabled)
    local key = tostring(part)
    local data = draft[key] or {materials = {}}
    draft[key] = data
    if type(material) == "table" then
        data.materials = data.materials or {}
        for name, value in pairs(material) do data.materials[name] = value end
    elseif material then
        data.materials = data.materials or {}
        data.materials[material] = enabled
    else
        data.mesh_enabled = enabled
    end
end

return Visibility
