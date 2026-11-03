local Parts = {}

-- 折叠时不枚举引擎对象，展开后按游戏提供的顺序展示部件。
function Parts.new(collect, translate, draw_materials)
    return function(character, body_id, weapon, baseline, player)
        local title = weapon and (translate("weapon_parts") or "Weapon Parts") or translate("armor_parts")
        if not imgui.tree_node(title) then return end
        for _, row in ipairs(collect(character,player,weapon,baseline,translate)) do
            if row.object then draw_materials(row.object,row.label,body_id,row.index)
            else imgui.text_colored(row.text,0xFF808080) end
        end
        imgui.tree_pop()
    end
end

return Parts
