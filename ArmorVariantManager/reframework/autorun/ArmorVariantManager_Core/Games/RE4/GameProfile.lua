-- RE4 适配同时服务 RE9:RE9 复用这里的 Main、配置模型和面板,只换角色目标与显隐(Games/RE9)。
-- 两者在模块层面的差异集中在这里,各模块不自己探测游戏。
--
-- Utils、Mdf2、Presets、Conditions/Registry、Reff 在加载时就读取 name / re9 / config_dir,
-- 所以 RE9/Main.lua 要在 require 任何 RE4 模块之前调用 select。没调用过时是 RE4。
local GameProfile = { name = "RE4", re9 = false, config_dir = "ArmorVariantManager", visibility = nil }

-- visibility:按下标读写显隐的模块(count / name / get / set);nil = 按材质开关(RE4)
function GameProfile.select(name, visibility)
    GameProfile.name = name
    GameProfile.re9 = name == "RE9"
    GameProfile.config_dir = GameProfile.re9 and "ArmorVariantManagerRE9" or "ArmorVariantManager"
    GameProfile.visibility = visibility
end

return GameProfile
