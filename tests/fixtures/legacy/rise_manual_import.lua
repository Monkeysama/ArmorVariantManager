-- Frozen manual import from 093c61c.
return function(env)
    local _ENV = env
local function list_manual_preset_files()
    if not fs or not fs.glob then return {} end
    local search_patterns = {
        "reframework/data/ArmorVariantManager/.*\\.json",
        "reframework\\\\data\\\\ArmorVariantManager\\\\.*\\.json",
        "ArmorVariantManager/.*\\.json",
        "ArmorVariantManager\\\\.*\\.json",
        "data/ArmorVariantManager/.*\\.json"
    }
    local all_files = {}
    for _, pattern in ipairs(search_patterns) do
        local found = fs.glob(pattern)
        if found then
            for _, f in ipairs(found) do table.insert(all_files, f) end
        end
    end
    -- 武器部件前缀集合（用于在防具模式下过滤武器预设）
    local weapon_prefixes = {}
    if Utils and Utils.WEAPON_PARTS_MAP then
        for _, parts in pairs(Utils.WEAPON_PARTS_MAP) do
            for _, part in ipairs(parts) do weapon_prefixes[part.prefix] = true end
        end
    end
    local seen = {}
    local result = {}
    for _, raw in ipairs(all_files) do
        -- 注意：这个模式捕获到的是**不带 .json 的文件名**（([^/\\]+) 后面才跟 %.json），
        -- 所以下面判断设置文件时必须拿掉扩展名再比，否则 GlobalSettings 会漏进列表。
        local file_name = string.match(raw, "([^/\\]+)%.json$") or raw
        local base_name = string.gsub(file_name, "%.json$", "")
        local lower_raw = string.lower(raw)
        local skip = base_name == "GlobalSettings" or string.find(lower_raw, "runtime") ~= nil
        if not skip then
            local is_weapon_preset = false
            for prefix, _ in pairs(weapon_prefixes) do
                if string.sub(base_name, 1, #prefix) == prefix then
                    is_weapon_preset = true
                    break
                end
            end
            if is_weapon_mode or not is_weapon_preset then
                if not seen[raw] then
                    seen[raw] = true
                    local is_backup = string.find(lower_raw, "backup") ~= nil
                    table.insert(result, {
                        path = raw,
                        name = is_backup and ("[备份] " .. base_name) or base_name
                    })
                end
            end
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- 加载指定的预设文件并立即应用到当前角色（沿用旧版面板手动查找的完整流程）
local function load_manual_preset_file(file_path, body_id)
    if not file_path or not body_id then return false, T("load_failed") end
    local data = json.load_file(file_path)
    if not data then data = json.load_file("reframework/data/" .. file_path) end
    if not data then
        local alt_path = string.gsub(file_path, "^[Aa]rmor[Vv]ariant[Mm]anager[/\\]", "")
        data = json.load_file(alt_path)
    end
    if not data or type(data) ~= "table" then
        return false, T("load_failed")
    end
    current_config = data
    save_current_config_to_file(body_id)
    update_preset_names_list()
    update_group_names_list()
    apply_all_defaults(body_id)
    local primary_apply = get_primary_player()
    if primary_apply then
        if is_weapon_mode then
            local weapon_parts = Utils.get_current_weapon_parts(primary_apply)
            if weapon_parts then
                apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
            end
        else
            apply_preset_to_character(primary_apply, active_overrides[body_id], true)
        end
    end
    -- 让新版 UI 下一帧重新读取配置
    new_ui_config_body_id = nil
    return true
end


return {list=list_manual_preset_files, load=load_manual_preset_file}
end
