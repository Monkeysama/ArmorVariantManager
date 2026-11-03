local Visibility = {}

-- 修改手动草稿的一个字段，不改变已保存预设和分组选择。
function Visibility.set(draft, part, material, enabled)
    local key = tostring(part)
    local data = draft[key] or {materials = {}}
    draft[key] = data
    if material then
        data.materials = data.materials or {}
        data.materials[material] = enabled
    else
        data.mesh_enabled = enabled
    end
end

return Visibility
