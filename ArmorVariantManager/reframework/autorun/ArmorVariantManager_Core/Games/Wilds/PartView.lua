local PartView = {}

-- 六个防具槽位只展示主网格；附属网格仍由应用服务同步。
function PartView.new(runtime)
    local equipment, meshes = runtime.equipment, runtime.meshes
    local game_object = runtime.scene_object.game_object
    return function(character, player, weapon, baseline, translate)
        local rows = {}
        local function text(value) rows[#rows+1] = {text=value} end
        local function mesh(object, label, index) rows[#rows+1] = {object=object,label=label,index=index} end
        if weapon then
            local _, objects = equipment.weapon_id(character)
            if objects and #objects > 0 then
                for index, object in ipairs(objects) do
                    if sdk.is_managed_object(object) then
                        local component = meshes.first(object)
                        local target = component and game_object(component, "draw_weapon_mesh")
                        if target then
                            mesh(target, string.format("Weapon %d [%s]", index-1, target:call("get_Name")), tostring(index-1))
                        else
                            text(string.format("Weapon %d [%s] (No Mesh)", index-1, object:call("get_Name")))
                        end
                    end
                end
            else text("Weapon " .. translate("not_equipped")) end
        else
            local names = {"helm","body","arm","waist","leg","slinger"}
            for index=0,5 do
                local object = meshes.part(character,index)
                local label = translate(names[index+1])
                local components = meshes.part_meshes(character,index,baseline and baseline[tostring(index)])
                local target = components[1] and game_object(components[1],"draw_part_mesh")
                if target then
                    mesh(target,string.format("%s [%s]",label,target:call("get_Name") or "Mesh"),index)
                elseif object and not meshes.is_face(object) then
                    text(string.format("%s [%s] (No Mesh)",label,object:call("get_Name")))
                else text(label .. " " .. translate("not_equipped")) end
            end
        end
        return rows
    end
end

return PartView
