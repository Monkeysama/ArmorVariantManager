local Compose = require("ArmorVariantManager_Core.Presets.Compose")
local Groups = require("ArmorVariantManager_Core.Presets.Groups")
local Visibility = require("ArmorVariantManager_Core.Presets.Visibility")
local GroundClippingFix = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingFix")
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

-- 加载和切换配色时，显示项可覆盖主预设中的旧配色。普通组仍决定归属材质是否打开。
function Presets.apply_global_layer(config, target, layer)
    for part, data in pairs(layer) do
        local current = target[part] and target[part].materials or {}
        for name, enabled in pairs(data.materials) do
            if not enabled or current[name] == nil or not Groups.owner(config,part,name) then
                Visibility.set(target,part,name,enabled)
            end
        end
    end
end

return Presets
