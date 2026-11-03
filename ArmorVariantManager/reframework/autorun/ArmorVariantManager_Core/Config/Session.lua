local Store = require("ArmorVariantManager_Core.Config.Store")
local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local Session = {}

local function equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for key, value in pairs(a) do
        if not equal(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- 一次脚本会话共享配置与恢复提示；角色、规则输出和界面状态由调用方管理。
function Session.new(schema, on_loaded, store)
    store = store or Store
    local session = { cache = {}, restored = {}, handled = {} }

    -- 比较原始文件，不能拿补齐默认字段后的配置与备份比较。
    function session.detect(id)
        if not id then return false end
        local backup = store.load(store.backup_path(id))
        if not backup then return false end
        local raw = store.load(store.config_path(id))
        if raw and equal(raw, backup) then
            session.restored[id] = nil
            return false
        end
        session.restored[id] = true
        if log and log.info then
            log.info(string.format("[ArmorVariantManager] 主配置与备份不一致，已提示玩家还原（处理前不覆盖备份）: %s", tostring(id)))
        end
        return true
    end

    function session.load(id)
        if not id then return nil end
        local cached = session.cache[id]
        if cached then
            if cached == "LOAD_FAILED" then return nil end
            return cached
        end
        local data = store.load(store.config_path(id))
        if data then Normalize.apply(data, schema) end
        session.detect(id)
        if data and on_loaded then on_loaded(data) end
        session.cache[id] = data or "LOAD_FAILED"
        return data
    end

    function session.pending(id)
        return session.restored[id] == true and session.handled[id] ~= true
    end

    function session.dismiss(id)
        if not id then return end
        session.handled[id] = true
        session.restored[id] = nil
    end

    -- 主文件写入成功才更新恢复标记；未决备份不得被自动保存覆盖。
    function session.save(id, data)
        if not id then return nil end
        session.cache[id] = data
        if not store.save(store.config_path(id), data) then return false end
        if not session.pending(id) then
            store.save(store.backup_path(id), data)
            session.restored[id] = nil
            session.handled[id] = nil
        end
        return true
    end

    -- 只恢复文件与配置缓存，调用方在成功后重建外观并刷新界面。
    function session.restore(id)
        if not id then return false end
        local backup = store.load(store.backup_path(id))
        if not backup then
            if log and log.warn then
                log.warn(string.format("[ArmorVariantManager] 没有可用的备份，无法还原: %s", tostring(id)))
            end
            return false
        end
        local path = store.config_path(id)
        if not store.save(path, backup) then
            if log and log.error then
                log.error(string.format("[ArmorVariantManager] 还原备份失败，主配置未能写回: %s", tostring(path)))
            end
            return false
        end
        session.dismiss(id)
        session.cache[id] = nil
        if log and log.info then
            log.info(string.format("[ArmorVariantManager] 已从备份还原玩家配置: %s", tostring(id)))
        end
        return true
    end

    return session
end

return Session
