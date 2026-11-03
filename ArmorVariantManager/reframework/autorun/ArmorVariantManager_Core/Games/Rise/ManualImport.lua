local Weapons = require("ArmorVariantManager_Core.Games.Rise.Weapons")
local ManualImport = {}

local SEARCH_PATTERNS = {
    "reframework/data/ArmorVariantManager/.*\\.json",
    "reframework\\\\data\\\\ArmorVariantManager\\\\.*\\.json",
    "ArmorVariantManager/.*\\.json",
    "ArmorVariantManager\\\\.*\\.json",
    "data/ArmorVariantManager/.*\\.json",
}

-- 只读取候选；保存与应用由配置会话和游戏应用层处理。
function ManualImport.new(files)
    files = files or {fs=fs,load=json and json.load_file}
    local service = {}

    function service.list(weapon)
        if not files.fs or not files.fs.glob then return {} end
        local all_files = {}
        for _, pattern in ipairs(SEARCH_PATTERNS) do
            for _, path in ipairs(files.fs.glob(pattern) or {}) do
                all_files[#all_files + 1] = path
            end
        end
        local weapon_prefixes = {}
        for _, parts in pairs(Weapons.WEAPON_PARTS_MAP) do
            for _, part in ipairs(parts) do weapon_prefixes[part.prefix] = true end
        end
        local seen, result = {}, {}
        for _, raw in ipairs(all_files) do
            local file_name = raw:match("([^/\\]+)%.json$") or raw
            local base_name = file_name:gsub("%.json$", "")
            local lower_raw = raw:lower()
            local skip = base_name == "GlobalSettings" or lower_raw:find("runtime") ~= nil
            if not skip and not weapon then
                for prefix in pairs(weapon_prefixes) do
                    if base_name:sub(1, #prefix) == prefix then skip = true; break end
                end
            end
            if not skip and not seen[raw] then
                seen[raw] = true
                result[#result + 1] = {
                    path=raw,
                    name=lower_raw:find("backup") and ("[备份] " .. base_name) or base_name,
                }
            end
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end

    function service.load(path)
        if type(path) ~= "string" or path == "" then return nil, "未选择预设文件" end
        local paths = {
            path,
            "reframework/data/" .. path,
            (path:gsub("^[Aa]rmor[Vv]ariant[Mm]anager[/\\]", "")),
        }
        local reason
        for _, candidate in ipairs(paths) do
            local ok, data, read_reason = pcall(files.load, candidate)
            if not ok then
                return nil, tostring(data)
            elseif data then
                if type(data) ~= "table" then
                    return nil, "预设文件内容不是配置对象: " .. candidate
                end
                return data
            elseif read_reason then
                reason = reason or tostring(read_reason)
            end
        end
        return nil, reason or ("预设文件读取失败: " .. path)
    end

    return service
end

return ManualImport
