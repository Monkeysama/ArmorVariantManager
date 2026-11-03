local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Binding = require("ArmorVariantManager_Core.Games.Rise.MeshBinding")
local Materials = {}

-- 只应用调用方已合成的角色结果；不从共享配置或本地界面推断远端角色意图。
function Materials.new(equipment, capture_mesh)
    local actors = {}
    local api = {}
    local function state(character)
        local key = tostring(character)
        if not actors[key] then actors[key] = {} end
        return actors[key]
    end

    local function bindings_alive(slot)
        if not slot or not slot.complete then return false end
        for _, mesh in pairs(slot.meshes) do
            if not SceneObject.is_alive(mesh) then return false end
        end
        return true
    end

    -- 首次发现直接应用；真正换装先清标识/网格，下一拍用新装备配置处理。
    local function sync_parts(character, st)
        local parts = equipment.parts(character)
        if not parts or st.parts_sig == parts.sig then return false end
        local changed = st.parts_sig ~= nil
        st.parts_sig, st.armor, st.weapon = parts.sig, nil, nil
        if changed then
            equipment.invalidate_body_id(character)
            equipment.clear_meshes()
        end
        return changed
    end

    local function same(slot, preset, options)
        return not options.special_cg and (options.version or 0) ~= 0 and slot
            and slot.id == options.body_id and slot.version == options.version
            and slot.output == preset and bindings_alive(slot)
    end

    local function new_slot(preset, options)
        return {id=options.body_id, version=options.version or 0,
            output=preset, meshes={}, complete=true}
    end

    -- 原值采样必须先于写入；同名材质所有索引由绑定模块处理。
    local function apply_part(slot, index, part, preset, options)
        if not part or not SceneObject.is_alive(part) then return end
        local data = preset[tostring(index)]
        if not data then return end
        local mesh = equipment.mesh(part)
        if not mesh then slot.complete = false; return end
        capture_mesh(options.body_id, tostring(index), mesh, data, SceneObject.call)
        slot.meshes[index] = mesh
        local operable = options.operable and function(name) return options.operable(index, name) end
        local visibility = options.hidden and function(name, enabled)
            return enabled and not options.hidden(index, name)
        end
        if not Binding.apply(mesh, data, operable, visibility) then slot.complete = false end
    end

    -- version=0 保留逐次检查；过场演员绕过版本快路径。
    function api.armor(character, preset, options)
        if not preset or not SceneObject.is_alive(character) or not options.body_id then return end
        local st = state(character)
        if sync_parts(character, st) then return end
        if same(st.armor, preset, options) then return end
        st.armor = new_slot(preset, options)
        local parts = equipment.parts(character)
        for index = 0, 4 do
            apply_part(st.armor, index, parts and parts[index], preset, options)
        end
    end

    function api.weapon(character, parts, preset, options)
        if not parts or not preset or not options.body_id then return end
        local st = SceneObject.is_alive(character) and state(character) or nil
        if st and sync_parts(character, st) then return end
        if st and same(st.weapon, preset, options) then return end
        local slot = new_slot(preset, options)
        if st then st.weapon = slot end
        -- 武器表可缺少盾牌等首部件；不能用 ipairs 漏掉后面的攻击部件。
        for index = 1, 8 do
            apply_part(slot, index - 1, parts[index], preset, options)
        end
    end

    -- 手动修改仍可能复用同一结果表，显式作废相关装备的应用缓存。
    function api.invalidate(body_id)
        for _, st in pairs(actors) do
            for _, kind in ipairs({"armor", "weapon"}) do
                if st[kind] and st[kind].id == body_id then st[kind] = nil end
            end
        end
    end

    function api.clear(character)
        if character then actors[tostring(character)] = nil else actors = {} end
        Binding.reset()
    end
    return api
end

return Materials
