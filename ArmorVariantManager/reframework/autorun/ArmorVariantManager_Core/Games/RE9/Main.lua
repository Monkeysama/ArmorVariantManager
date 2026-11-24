-- RE9(Resident Evil Requiem)入口:选定 GameProfile 后交给 RE4 的 Main。
-- RE9 的显隐按网格可见性组(Viscon,见 Visibility.lua),角色目标见 Targets.lua;
-- 其余配置模型、条件、预设与面板沿用 RE4 适配。
local Main = {}
function Main.start(ctx)
    local visibility = require("ArmorVariantManager_Core.Games.RE9.Visibility")
    -- 必须先于下面的 require:Targets 引入的 RE4 Utils 等模块加载时读取 GameProfile
    require("ArmorVariantManager_Core.Games.RE4.GameProfile").select("RE9", visibility)
    local targets = require("ArmorVariantManager_Core.Games.RE9.Targets")
    re.on_script_reset(visibility.reset)
    ctx.targets = targets
    require("ArmorVariantManager_Core.Games.RE4.Main").start(ctx)
    log.info("[ArmorVariantManager] RE9 port loaded")
end
return Main
