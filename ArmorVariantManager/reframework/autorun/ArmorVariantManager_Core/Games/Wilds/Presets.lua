local Compose = require("ArmorVariantManager_Core.Presets.Compose")
local GroundClippingFix = require("ArmorVariantManager_Core.GroundClippingFix")
local Presets = {}

-- 手动材质合成不写入高度，预览高度由现有高度状态管理。
function Presets.merge_into(target, preset)
    return Compose.merge_into(target, preset, "ground_clipping_fix")
end

-- 规则高度只接受已勾选的设置，包含显式归零。
function Presets.merge(base, added)
    local result = Compose.merge(base, added, "ground_clipping_fix")
    if added and added.ground_clipping_fix ~= nil then
        local settings = GroundClippingFix.read_settings(added.ground_clipping_fix)
        if settings.enabled then result.ground_clipping_fix = settings end
    end
    return result
end

function Presets.merge_global_into(target, preset)
    return Compose.merge_global_into(target, preset, true, "ground_clipping_fix")
end

return Presets
