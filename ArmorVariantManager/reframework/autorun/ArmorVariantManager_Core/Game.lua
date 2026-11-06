local Game = {}

-- REFramework 的游戏标识只在入口解析一次，不在共享业务中探测游戏类型。
function Game.detect(name)
    local games = {mhwilds = "Wilds", mhrise = "Rise"}
    local selected = games[string.lower(name or "")]
    if not selected then return nil, "ArmorVariantManager: unsupported game " .. tostring(name) end
    return {name = selected, wilds = selected == "Wilds", prefix = "ArmorVariantManager_Core.Games." .. selected .. "."}
end

return Game
