local Compose = require("ArmorVariantManager_Core.Presets.Compose")
local Height = require("ArmorVariantManager_Core.Presets.Height")
local Presets = {}
function Presets.merge_into(target, preset)
    return Compose.merge_into(target, preset, "ground_clipping_fix")
end
function Presets.merge(base, added)
    local result = Compose.merge(base, added, "ground_clipping_fix")
    if added and added.ground_clipping_fix then
        result.ground_clipping_fix = Height.participating_settings(added) or result.ground_clipping_fix
    end
    return result
end

-- 崛起旧全局组仅覆盖隐藏项，不补写显示状态。
function Presets.merge_global_into(target, preset)
    return Compose.merge_global_into(target, preset, false, "ground_clipping_fix")
end

-- 保留旧全局默认选择：先用排序表，未指定名称时再取首项。
function Presets.default_global(group)
    local name = group.default_preset
    if (not name or name == "") and group.presets and next(group.presets) then
        for _, candidate in ipairs(group.preset_order or {}) do
            if group.presets[candidate] then name = candidate; break end
        end
        if not name then name = next(group.presets) end
    end
    return name
end

return Presets
