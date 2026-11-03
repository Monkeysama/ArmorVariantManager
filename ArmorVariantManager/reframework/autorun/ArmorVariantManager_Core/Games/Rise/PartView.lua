local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Signals = require("ArmorVariantManager_Core.Games.Rise.Signals")
local Weapons = require("ArmorVariantManager_Core.Games.Rise.Weapons")
local PartView = {}

-- 保持崛起防具显示顺序；武器遍历到最后一个有效槽位，不被中间空槽截断。
function PartView.new(runtime)
    local equipment = runtime.equipment
    local call = SceneObject.call
    return function(character, player, weapon, baseline, translate)
        local rows = {}
        local function text(value) rows[#rows+1] = {text=value} end
        local function mesh(object, label, index) rows[#rows+1] = {object=object,label=label,index=index} end
        if weapon then
            local parts = equipment.weapons(character,player)
            local kind = Signals.get_current_weapon_type(player or character)
            local last = 0
            for index=1,8 do if parts and parts[index] then last=index end end
            if last == 0 then text(translate("weapon_not_equipped") or "No weapon equipped") end
            for index=1,last do
                local object = parts[index]
                if object and SceneObject.is_alive(object) then
                    local component = equipment.mesh(object)
                    local target = component and call(component,"get_GameObject")
                    if target then
                        mesh(target,string.format("%s [%s]",Weapons.part_name(kind,index-1),call(target,"get_Name")),index-1)
                    else text(string.format("Part %d [%s] (No Mesh)",index-1,call(object,"get_Name"))) end
                else text(string.format("Part %d (Missing)",index-1)) end
            end
        else
            local names = {"helm","body","arm","waist","leg"}
            local parts = equipment.parts(character)
            for _, index in ipairs({2,1,0,4,3}) do
                local object = parts and parts[index]
                local label = translate(names[index+1])
                if object then
                    local component = equipment.mesh(object)
                    local target = component and call(component,"get_GameObject")
                    if target then
                        mesh(target,string.format("%s [%s]",label,call(target,"get_Name")),index)
                    else text(string.format("%s [%s] (No Mesh)",label,call(object,"get_Name"))) end
                else text(label .. " " .. translate("not_equipped")) end
            end
        end
        return rows
    end
end

return PartView
