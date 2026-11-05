local Game = {}

-- REFramework 的游戏标识只在入口解析一次，不在共享业务中探测游戏类型。
-- standalone 的游戏数据模型与共享应用不同，入口只把版本信息交给它自己的 Main.start。
function Game.detect(name)
    local games = {mhwilds = "Wilds", mhrise = "Rise", re4 = "RE4"}
    local standalone = {RE4 = true}
    local selected = games[string.lower(name or "")]
    if not selected then return nil, "ArmorVariantManager: unsupported game " .. tostring(name) end
    return {name = selected, wilds = selected == "Wilds", standalone = standalone[selected] == true,
        prefix = "ArmorVariantManager_Core.Games." .. selected .. "."}
end

return Game
