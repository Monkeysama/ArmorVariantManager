local Store = require("ArmorVariantManager_Core.Config.Store")
local Global = {}
local PATH = "ArmorVariantManager/GlobalSettings.json"

-- 读写共用文件入口，默认值及旧字段解释由当前游戏提供。
function Global.new(schema, store)
    store = store or Store
    local session = {value=schema.new()}
    function session.load()
        local loaded = store.load(PATH)
        if type(loaded) ~= "table" then return end
        -- 扩展字段随设置一起保存；已存在的已知字段由游戏规则处理。
        for key, value in pairs(loaded) do
            if session.value[key] == nil then session.value[key] = value end
        end
        schema.apply(session.value, loaded)
    end
    function session.save()
        return store.save(PATH, session.value)
    end
    return session
end

return Global
