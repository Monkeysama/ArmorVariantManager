local Palette = require("ArmorVariantManager_Core.Presets.Palette")
local Writer = require("ArmorVariantManager_Core.Runtime.Palette")
local Adapter = {}

-- 荒野接入调色：按角色当前解算的预设（含条件规则目标）合并覆盖，写到防具六个部位与武器对象的网格上。
-- deps.meshes：part_meshes / first；deps.writer 可替换（测试用）。
function Adapter.new(deps)
    local writer = deps.writer or Writer.new()
    local self = { writer = writer }

    local function meshes_of(character, slot, objects, part, part_data)
        if slot == "armor" then return deps.meshes.part_meshes(character, tonumber(part), part_data) or {} end
        local object = objects and objects[tonumber(part) + 1]
        local mesh = object and deps.meshes.first(object)
        return mesh and { mesh } or {}
    end

    -- 每帧对每个角色、每个槽位调用一次，在材质开关写入之后。context 为外观解算的角色上下文。
    function self.apply(character, slot, objects, context, config)
        local overrides = Palette.resolve(config, context.groups, context.targets)
        local result = context.overrides
        local actor = tostring(character) .. "|" .. slot
        if next(overrides) == nil and not writer.active(actor) then return end
        writer.begin(actor)
        local parts = {}
        if slot == "armor" then
            for index = 0, 5 do parts[#parts + 1] = tostring(index) end
        else
            for index = 1, #(objects or {}) do parts[#parts + 1] = tostring(index - 1) end
        end
        for _, part in ipairs(parts) do
            for _, mesh in ipairs(meshes_of(character, slot, objects, part, result and result[part])) do
                writer.apply(actor, mesh, overrides[part])
            end
        end
        writer.finish(actor)
    end

    -- 界面读取本地猎人某个部位、某个材质的参数；找不到网格或材质时返回空表。
    function self.inspect(character, slot, objects, part, material, part_data)
        local actor = tostring(character) .. "|" .. slot
        for _, mesh in ipairs(meshes_of(character, slot, objects, part, part_data)) do
            local params = writer.inspect(actor, mesh, material)
            if #params > 0 then return params end
        end
        return {}
    end

    -- 切场景时清空；离场角色的记录也在这时清掉。网格按对象本身匹配，地址复用不会套用旧原值。
    function self.reset() writer.reset() end

    return self
end

return Adapter
