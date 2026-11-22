local Capture = require("ArmorVariantManager_Core.Presets.Capture")
local Adapter = {}

-- 防具按六部位捕获；自定义 PFB 的多网格沿用当前意图作为发现参考。
function Adapter.new(meshes, equipment)
    return function(character, config, group, baseline, weapon, accepts)
        local parts = {}
        if weapon then
            local _, objects = equipment.weapon_id(character)
            for index, object in ipairs(objects or {}) do
                local mesh = meshes.first(object)
                if mesh then parts[index - 1] = {mesh} end
            end
        else
            for index = 0, 5 do
                parts[index] = meshes.part_meshes(character, index, baseline and baseline[tostring(index)])
            end
        end
        local global = group ~= "" and config.groups and config.groups[group] and config.groups[group].is_global
        return Capture.read(parts, function(mesh, method, ...) return mesh:call(method, ...) end, accepts,
            function(index, name, mesh, offset, call)
                local part = baseline and baseline[tostring(index)]
                if not global and part and part.materials and part.materials[name] ~= nil then
                    return part.materials[name]
                end
                return call(mesh, "getMaterialsEnable", offset)
            end, not global, group == "")
    end
end

return Adapter
