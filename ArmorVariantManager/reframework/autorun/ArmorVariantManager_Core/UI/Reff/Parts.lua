local Parts = {}

-- 托管对象只存在于当前调用；输出不包含对象、地址或组件。
function Parts.new(deps)
    local parts = {}
    function parts.rows(context)
        return deps.collect(context.character, context.player, context.weapon, context.baseline, deps.translate)
    end
    function parts.find(context, index)
        for _, row in ipairs(parts.rows(context)) do
            if tonumber(row.index) == index and row.object and deps.access.valid(row.object) then
                local mesh = deps.access.mesh(row.object)
                if mesh then return mesh, row end
            end
        end
    end
    function parts.snapshot(context)
        local output = {}
        for _, row in ipairs(parts.rows(context)) do
            local index = tonumber(row.index)
            local mesh
            if row.object and deps.access.valid(row.object) then mesh = deps.access.mesh(row.object) end
            local result = {index=index or -(#output+1),label=row.label or row.text,available=mesh ~= nil,
                enabled=false,meshLocked=context.weapon and deps.access.weapon_mesh_locked == true,materials={}}
            if mesh then
                result.enabled = result.meshLocked or deps.access.call(mesh,"get_Enabled") == true
                local baseline = context.baseline and context.baseline[tostring(index)]
                local intents = baseline and baseline.materials or {}
                local seen = {}
                for offset=0, deps.access.call(mesh,"get_MaterialNum")-1 do
                    local name = deps.access.call(mesh,"getMaterialName",offset)
                    local in_context = name and deps.contains(index,name) == true
                    -- 主列表展示全部材质；被普通组占用的条目仍由所属组编辑。
                    if name and not seen[name] and (context.selecting or context.group == "" or in_context) then
                        seen[name] = true
                        local enabled = intents[name]
                        if enabled == nil then enabled = deps.access.call(mesh,"getMaterialsEnable",offset) end
                        result.materials[#result.materials+1] = {name=name,
                            enabled=enabled == true,editable=in_context,owner=deps.owner(index,name),
                            hidden=deps.hidden(index,name) == true,groups=deps.global_names(index,name)}
                    end
                end
            end
            output[#output+1] = result
        end
        return output
    end
    return parts
end

return Parts
