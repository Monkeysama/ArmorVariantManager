local Store = {}

local function ensure_parent_directory(filepath)
    local dir = string.match(filepath, "^(.*)[/\\][^/\\]+$")
    if not dir then return true end
    if fs and fs.create_directory then
        local ok, created = pcall(fs.create_directory, dir)
        return ok and created ~= false
    end
    return true
end

-- 读取 JSON 文件：文件不存在、为空、或内容损坏一律返回 nil，且不产生错误日志。
function Store.load(filepath)
    if not filepath then return nil end
    local handle = io.open(filepath, "r")
    if not handle then return nil end
    local content = handle:read("a")
    handle:close()
    if not content then return nil end
    content = content:gsub("^\239\187\191", "") -- 去掉可能存在的 UTF-8 BOM
    -- 空文件/纯空白视为"暂无配置"，直接返回 nil，不进入解析器。
    if content:match("^%s*$") then return nil end
    local ok, data = pcall(json.load_string, content)
    if not ok then return nil end
    return data
end

-- 序列化成功后写入，并确认关闭时的落盘结果。
function Store.save(filepath, value)
    if not filepath or not value then return false end
    local ok_text, text = pcall(json.dump_string, value, 4)
    if not ok_text or type(text) ~= "string" or text == "" then
        log.error(string.format("[AVM] json 序列化失败，已跳过写入: %s", tostring(filepath)))
        return false
    end
    ensure_parent_directory(filepath)
    local handle = io.open(filepath, "w")
    if not handle then
        log.error(string.format("[AVM] 无法写入配置文件: %s", tostring(filepath)))
        return false
    end
    local written, write_error = handle:write(text)
    local closed, close_error = handle:close()
    if not written or not closed then
        local reason = string.format("[AVM] 配置写入失败: %s (%s)", tostring(filepath), tostring(write_error or close_error))
        log.error(reason)
        return false, reason
    end
    return true
end

-- 辅助函数：获取配置文件路径
function Store.config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end

-- 辅助函数：获取备份文件路径
function Store.backup_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/backup/" .. body_id .. ".json"
end

return Store
