local Main = {}
function Main.start(ctx)
    local targets = require("ArmorVariantManager_Core.Games.RE9.Targets")
    local visibility = require("ArmorVariantManager_Core.Games.RE9.Visibility")
    re.on_script_reset(visibility.reset)
    ctx.targets = targets
    require("ArmorVariantManager_Core.Games.RE4.Main").start(ctx)
    log.info("[ArmorVariantManager] RE9 port loaded")
end
return Main
