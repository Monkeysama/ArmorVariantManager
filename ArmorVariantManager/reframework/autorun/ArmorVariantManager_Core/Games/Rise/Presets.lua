local Compose = require("ArmorVariantManager_Core.Presets.Compose")
local Presets = { merge_into = Compose.merge_into, merge = Compose.merge }

-- 崛起旧全局组仅覆盖隐藏项，不补写显示状态。
function Presets.merge_global_into(target, preset)
    return Compose.merge_global_into(target, preset, false)
end

return Presets
