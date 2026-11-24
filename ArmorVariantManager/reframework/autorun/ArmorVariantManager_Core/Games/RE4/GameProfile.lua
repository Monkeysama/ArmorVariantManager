-- RE4 适配同时服务 RE9:RE9 复用这里的 Main、配置模型和面板,只换角色目标(Games/RE9)。
-- 两者在模块层面的差异集中在这里,各模块不自己探测游戏。
--
-- Utils、Mdf2、Presets、Conditions/Registry、Reff 在加载时就读取 name / re9 / config_dir,
-- 所以 RE9/Main.lua 要在 require 任何 RE4 模块之前调用 select。没调用过时是 RE4。
--
-- 显隐开关(见 Utils.visibility_*):
--   materials   列出材质开关
--   groups_min  网格用到至少这么多个可见性组时才列出组开关(Viscon.lua)。RE4 原版网格全在组 0,
--               列出来只多一个整件开关,还会让已有预设的材质指纹对不上,所以 RE4 要 2 个以上
local GameProfile = { name = "RE4", re9 = false, config_dir = "ArmorVariantManager", materials = true, groups_min = 2 }

function GameProfile.select(name)
    GameProfile.name = name
    GameProfile.re9 = name == "RE9"
    GameProfile.config_dir = GameProfile.re9 and "ArmorVariantManagerRE9" or "ArmorVariantManager"
    -- RE9 移植版只按组切换,配置里只有组;材质开关在 RE9 中的效果未知
    GameProfile.materials = not GameProfile.re9
    GameProfile.groups_min = GameProfile.re9 and 1 or 2
end

return GameProfile
