local Compose = {}

-- 预设合成不得修改配置或另一个角色持有的基线。
function Compose.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = Compose.copy(item) end
    return result
end

-- 合并网格与材质开关；预设级元数据由游戏适配层处理。
function Compose.merge_into(target, preset, metadata_key)
    for part, data in pairs(preset or {}) do
        if part ~= metadata_key then
            if not target[part] then target[part] = { materials = {} } end
            if data.mesh_enabled ~= nil then target[part].mesh_enabled = data.mesh_enabled end
            if data.materials then
                if not target[part].materials then target[part].materials = {} end
                for material, enabled in pairs(data.materials) do
                    target[part].materials[material] = enabled
                end
            end
        end
    end
    return target
end

-- 规则合成返回独立结果，手动应用则使用 merge_into 原地更新。
function Compose.merge(base, added, metadata_key)
    return Compose.merge_into(Compose.copy(base) or {}, added, metadata_key)
end

-- 全局组只覆盖材质，不覆盖网格开关；荒野还需补齐没有下层状态的显示项。
function Compose.merge_global_into(target, preset, fill_missing, metadata_key)
    for part, data in pairs(preset or {}) do
        if part ~= metadata_key and data.materials then
            if not target[part] then target[part] = { materials = {} } end
            if not target[part].materials then target[part].materials = {} end
            for material, enabled in pairs(data.materials) do
                if enabled == false or (fill_missing and enabled == true and target[part].materials[material] == nil) then
                    target[part].materials[material] = enabled
                end
            end
        end
    end
    return target
end

return Compose
