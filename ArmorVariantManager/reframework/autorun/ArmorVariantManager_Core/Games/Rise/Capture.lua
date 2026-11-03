local Capture = require("ArmorVariantManager_Core.Presets.Capture")
local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Adapter = {}

-- 武器槽位可稀疏；全局组只记录隐藏项，空结果保留旧 _empty 标记。
function Adapter.new(equipment)
    return function(character, player, config, group, weapon, accepts)
        local parts = {}
        local objects = weapon and equipment.weapons(character, player) or equipment.parts(character)
        for index = weapon and 1 or 0, weapon and 8 or 4 do
            local object = objects and objects[index]
            local mesh = object and equipment.mesh(object)
            if mesh then parts[weapon and index - 1 or index] = {mesh} end
        end
        local global = group ~= "" and config.groups and config.groups[group] and config.groups[group].is_global
        local result = Capture.read(parts, SceneObject.call, accepts, function(_, _, mesh, offset, call)
            local visible = call(mesh, "getMaterialsEnable", offset)
            if not global or visible == false then return visible end
        end, true, not global)
        if global and not next(result) then result._empty = true end
        return result
    end
end

return Adapter
