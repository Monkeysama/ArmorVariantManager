local ShapeKeyLink = {}

-- AVM → ShapeKeySystem（SKS）键组联动：把本地猎人当前生效预设里的键组选项交给 SKS。
-- 只调用 _G.ShapeKeySystemAPI 的公开接口，不选捏脸配置，也不写形态键数值。
-- 荒野与崛起的 SKS 只驱动本地猎人，调用时不传 opts.actor。没装 SKS 时什么都不做，配置原样保留。
ShapeKeyLink.OWNER = "ArmorVariantManager"

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

-- deps.api() 可替换接口来源，供离线测试使用。
function ShapeKeyLink.new(deps)
    deps = deps or {}
    local link = {}
    local api_ref, sent, errors = nil, nil, {}

    -- SKS 每次扫描后可能换了捏脸配置，失败的键组下次推送时重试。
    local function on_scan()
        if sent then
            for group in pairs(errors) do sent[group] = nil end
        end
    end

    local function api()
        local value = deps.api and deps.api() or rawget(_G, "ShapeKeySystemAPI")
        if type(value) ~= "table" or type(value.select_group_option) ~= "function" then value = nil end
        if value ~= api_ref then
            -- SKS 重置后旧选择已失效，下一次推送全部重发。
            api_ref, sent, errors = value, nil, {}
            if value and type(value.on) == "function" then pcall(value.on, "scan", on_scan) end
        end
        return value
    end

    local function select(sks, group, option)
        local ok, done, code = pcall(sks.select_group_option, ShapeKeyLink.OWNER, group, option)
        if ok and done then errors[group] = nil
        else errors[group] = ok and (type(code) == "string" and code or "E_FAILED") or "E_CALL" end
    end

    -- want = { [键组] = 选项名 | 0 }；nil 表示本帧不动 SKS（场景切换、角色不在或结果未就绪）。
    -- 不再被任何预设写到的键组交还给 SKS：优先 clear_selection 回到捏脸配置保存的选项，
    -- 旧版 SKS 没有该接口时发 0。只发有变化的键组，SKS 对重复选择不做处理。
    function link.push(want)
        local sks = api()
        if not sks or type(want) ~= "table" then return end
        local previous = sent or {}
        local released = {}
        for group in pairs(previous) do
            if want[group] == nil then released[#released + 1] = group end
        end
        if #released > 0 then
            if type(sks.clear_selection) == "function" then
                pcall(sks.clear_selection, ShapeKeyLink.OWNER)
                previous = {}
            else
                for _, group in ipairs(released) do
                    if not errors[group] then pcall(sks.select_group_option, ShapeKeyLink.OWNER, group, 0) end
                end
            end
        end
        for group, option in pairs(want) do
            if previous[group] ~= option then select(sks, group, option) end
        end
        for group in pairs(errors) do
            if want[group] == nil then errors[group] = nil end
        end
        sent = copy(want)
    end

    -- 给界面读取的只读状态。available 为 false 时其他字段为空。
    -- groups：SKS 当前捏脸配置的键组 { name, options, value }，value 为生效选项名或 0；
    -- sent：AVM 正在接管的键组；errors：发送失败或当前配置缺少的键组及错误码；
    -- failure：联动自身出错后停止推送的原因（由调用方写入 link.failure）。
    function link.view()
        local sks = api()
        local view = { available = sks ~= nil, groups = {}, sent = copy(sent), errors = copy(errors),
            failure = link.failure }
        if not sks then return view end
        if type(sks.key_groups) == "function" then
            local ok, list = pcall(sks.key_groups)
            for _, item in ipairs(ok and type(list) == "table" and list or {}) do
                if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
                    local options, value = {}, 0
                    for index, option in ipairs(type(item.options) == "table" and item.options or {}) do
                        if type(option) == "string" then
                            options[#options + 1] = option
                            if item.value == index then value = option end
                        end
                    end
                    view.groups[#view.groups + 1] = { name = item.name, options = options, value = value }
                end
            end
        end
        -- 角色的键位尚未扫描时 SKS 先收下选择，之后应用时才报告当前配置缺少的键组。
        if type(sks.selection) == "function" then
            local ok, selection = pcall(sks.selection)
            if ok and type(selection) == "table" and selection.owner == ShapeKeyLink.OWNER then
                for _, group in ipairs(type(selection.skipped) == "table" and selection.skipped or {}) do
                    if sent and sent[group] ~= nil and not view.errors[group] then view.errors[group] = "E_NOT_FOUND" end
                end
            end
        end
        return view
    end

    function link.available() return api() ~= nil end

    return link
end

return ShapeKeyLink
