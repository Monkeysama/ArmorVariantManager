-- RE4 预设库(v3)。
--
-- 每个角色有一份"当前配置"(<角色名>.json),是唯一生效的那份;预设库是全局的一个目录,
-- 一个预设一个文件,只是"套用"的来源。套用是复制:当前配置先进自动保存,再被预设的内容覆盖。
-- **从不自动切换**:模型变了时只提醒有没有更合适的预设,换不换由用户决定。
--
--   ArmorVariantManager/presets/<id>.json   = { version = 3, name, source = "user"|"mod", character, updated, config }
--   ArmorVariantManager/autosave/<角色名>.json = { entries = { { name, time, config }, ... } }   最近 5 份,新的在前
--
-- 文件名用 ASCII 编号(p0001...),显示名放在文件里:改名不用动文件,也避开非 ASCII 路径。
-- json 接口删不了文件,删除 = 把文件写成墓碑 { deleted = true },列表跳过,新建时复用。
-- mod 作者随 mod 发布的预设也放在这个目录(source = "mod"),文件名随意。
--
-- 匹配:预设的"指纹"是它记录的材质名(整套造型快照 + 状态组作用域),按槛位和当前模型比:
--   full    当前模型每个有材质的槛位,材质名集合都和指纹完全相同
--   partial 至少一个槛位的重合度(交集 / 并集)达到 SLOT_MATCH_THRESHOLD
--   none    其他
-- 指纹里有、当前模型上没有的槛位(比如没穿护甲)不参与判断。
local Presets = {}

Presets.DIR = "ArmorVariantManager/presets/"
Presets.AUTOSAVE_DIR = "ArmorVariantManager/autosave/"
Presets.INDEX_ID = "_index"
Presets.INDEX = Presets.DIR .. Presets.INDEX_ID .. ".json"
Presets.PROBE_GAP = 8
Presets.AUTOSAVE_KEEP = 5
Presets.SLOT_MATCH_THRESHOLD = 0.25

local function is_tbl(v) return type(v) == "table" end

function Presets.deep_copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = Presets.deep_copy(x) end
    return o
end

-- ============================================================ 指纹与匹配
function Presets.fingerprint(cfg)
    local fp = {}
    local function add(slot, mat)
        fp[slot] = fp[slot] or {}
        fp[slot][mat] = true
    end
    for _, preset in pairs(is_tbl(cfg) and is_tbl(cfg.base) and is_tbl(cfg.base.presets) and cfg.base.presets or {}) do
        for slot, data in pairs(is_tbl(preset) and preset or {}) do
            if type(slot) == "string" and is_tbl(data) and is_tbl(data.materials) then
                for m in pairs(data.materials) do if type(m) == "string" then add(slot, m) end end
            end
        end
    end
    for _, g in ipairs(is_tbl(cfg) and is_tbl(cfg.groups) and cfg.groups or {}) do
        for _, key in ipairs(is_tbl(g.scope) and g.scope or {}) do
            local slot, mat = tostring(key):match("^([^/]+)/(.+)$")
            if slot then add(slot, mat) end
        end
    end
    return fp
end

-- live:Utils.all_enabled_preset 的结果 { slot = { materials = { 名 = true } } }
function Presets.live_sets(live)
    local out = {}
    for slot, data in pairs(is_tbl(live) and live or {}) do
        if is_tbl(data) and is_tbl(data.materials) and next(data.materials) then
            out[slot] = {}
            for m in pairs(data.materials) do out[slot][m] = true end
        end
    end
    return out
end

local function jaccard(a, b)
    local inter, union = 0, 0
    for k in pairs(a) do union = union + 1; if b[k] then inter = inter + 1 end end
    for k in pairs(b) do if not a[k] then union = union + 1 end end
    return union > 0 and inter / union or 0, inter == union
end

-- 返回 "full" | "partial" | "none", { [slot] = 重合度 }
function Presets.match(cfg, live_sets)
    local fp = Presets.fingerprint(cfg)
    local ratios, all_equal, any_ok, any_slot = {}, true, false, false
    for slot, live in pairs(live_sets) do
        any_slot = true
        local r, equal = jaccard(fp[slot] or {}, live)
        ratios[slot] = r
        if not equal then all_equal = false end
        if r >= Presets.SLOT_MATCH_THRESHOLD then any_ok = true end
    end
    if not any_slot then return "none", ratios end
    if all_equal then return "full", ratios end
    return any_ok and "partial" or "none", ratios
end

local RANK = { full = 0, partial = 1, none = 2 }
Presets.RANK = RANK

-- ============================================================ 预设库
-- io = { load(path) -> table|nil, dump(path, table), glob(pattern) -> { path... } | nil, now() -> 秒 }
function Presets.library(io)
    local lib = {}
    local cache = nil     -- { [id] = 条目 },按需从磁盘读一次

    local function file_of(id) return Presets.DIR .. id .. ".json" end

    local function read(id)
        local data = io.load(file_of(id))
        if is_tbl(data) and data.deleted ~= true and is_tbl(data.config) then
            cache[id] = {
                id = id,
                name = (type(data.name) == "string" and data.name ~= "") and data.name or id,
                source = data.source == "mod" and "mod" or "user",
                character = type(data.character) == "string" and data.character or nil,
                updated = tonumber(data.updated) or 0,
                config = data.config,
            }
        elseif is_tbl(data) and data.deleted == true then
            cache[id] = false    -- 墓碑:可复用的编号
        end
        return data ~= nil
    end

    -- 目录索引:glob 成功时写一份,glob 用不了时靠它(加上顺序探测 pNNNN)找回预设
    local function write_index()
        local ids = {}
        for id in pairs(cache) do ids[#ids + 1] = id end
        table.sort(ids)
        pcall(io.dump, Presets.INDEX, { ids = ids })
    end

    local function scan()
        cache = {}
        -- REFramework 的 fs.glob 会遍历整个 reframework/data(含别的 mod 和 WebView2 缓存),
        -- 任何一个文件名转不成系统代码页(中文系统是 GBK,比如韩文、部分日文)就整体抛错:
        -- "No mapping for the Unicode character exists in the target multi-byte code page."
        -- 所以 glob 必须包 pcall,失败时退回索引 + 探测,不能让一次扫描把整个请求打断。
        local ok, found = false, nil
        if io.glob then ok, found = pcall(io.glob, "ArmorVariantManager[/\\\\]presets[/\\\\].*\\.json") end
        if ok and type(found) == "table" then
            for _, raw in ipairs(found) do
                local id = tostring(raw):match("([^/\\]+)%.json$")
                if id and cache[id] == nil and id ~= Presets.INDEX_ID then read(id) end
            end
            write_index()
            return
        end
        local index = io.load(Presets.INDEX)
        for _, id in ipairs(is_tbl(index) and is_tbl(index.ids) and index.ids or {}) do
            if type(id) == "string" and cache[id] == nil then read(id) end
        end
        -- 索引之外新存的 pNNNN:顺序探测,连续 PROBE_GAP 个空号就停
        local misses, n = 0, 0
        while misses < Presets.PROBE_GAP do
            n = n + 1
            local id = string.format("p%04d", n)
            if cache[id] ~= nil or read(id) then misses = 0 else misses = misses + 1 end
        end
    end

    function lib.refresh() cache = nil end

    -- 全部有效预设(不排序;排序由调用方按匹配程度来)
    function lib.list()
        if not cache then scan() end
        local out = {}
        for _, e in pairs(cache) do if e then out[#out + 1] = e end end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end

    function lib.get(id)
        if not cache then scan() end
        return cache[id] or nil
    end

    local function next_id()
        if not cache then scan() end
        local best
        for id, e in pairs(cache) do
            if e == false and id:match("^p%d+$") and (not best or id < best) then best = id end
        end
        if best then return best end
        local n = 0
        for id in pairs(cache) do
            local k = tonumber(id:match("^p(%d+)$"))
            if k and k > n then n = k end
        end
        return string.format("p%04d", n + 1)
    end

    local function write(e)
        io.dump(file_of(e.id), { version = 3, name = e.name, source = e.source, character = e.character,
            updated = e.updated, config = e.config })
    end

    -- 存为新预设:复制一份配置进去,source_preset 不进预设
    function lib.save_new(name, cfg, character)
        if type(name) ~= "string" or name == "" or not is_tbl(cfg) then return nil end
        local config = Presets.deep_copy(cfg)
        config.source_preset = nil
        local e = { id = next_id(), name = name, source = "user", character = character,
            updated = io.now and io.now() or 0, config = config }
        cache[e.id] = e
        write(e)
        write_index()
        return e.id
    end

    -- 存回:只能覆盖自己保存的预设,mod 发布的不改
    function lib.update(id, cfg)
        local e = lib.get(id)
        if not e or e.source ~= "user" or not is_tbl(cfg) then return false end
        e.config = Presets.deep_copy(cfg)
        e.config.source_preset = nil
        e.updated = io.now and io.now() or e.updated
        write(e)
        return true
    end

    function lib.rename(id, name)
        local e = lib.get(id)
        if not e or e.source ~= "user" or type(name) ~= "string" or name == "" or e.name == name then return false end
        e.name = name
        write(e)
        return true
    end

    function lib.delete(id)
        local e = lib.get(id)
        if not e or e.source ~= "user" then return false end
        cache[id] = false
        io.dump(file_of(id), { deleted = true })
        return true
    end

    -- ======================================================== 自动保存(每个角色一个文件)
    local autosave_cache = {}
    local function autosave_file(char) return Presets.AUTOSAVE_DIR .. char .. ".json" end
    local function autosave_entries(char)
        if autosave_cache[char] == nil then
            local data = io.load(autosave_file(char))
            local entries = {}
            for _, a in ipairs(is_tbl(data) and is_tbl(data.entries) and data.entries or {}) do
                if is_tbl(a) and is_tbl(a.config) then
                    entries[#entries + 1] = { name = tostring(a.name or ""), time = tonumber(a.time) or 0, config = a.config }
                end
            end
            autosave_cache[char] = entries
        end
        return autosave_cache[char]
    end

    function lib.autosaves(char) return autosave_entries(char) end

    function lib.autosave_push(char, name, cfg)
        local entries = autosave_entries(char)
        table.insert(entries, 1, { name = name, time = io.now and io.now() or 0, config = Presets.deep_copy(cfg) })
        while #entries > Presets.AUTOSAVE_KEEP do table.remove(entries) end
        io.dump(autosave_file(char), { entries = entries })
        return true
    end

    function lib.autosave_take(char, k)
        local entries = autosave_entries(char)
        k = tonumber(k)
        local a = k and entries[k]
        if not a then return nil end
        table.remove(entries, k)
        io.dump(autosave_file(char), { entries = entries })
        return a
    end

    return lib
end

-- 按匹配程度排好的预设列表:{ { entry, match, ratios }, ... }
function Presets.ranked(lib, live_sets)
    local out = {}
    for _, e in ipairs(lib.list()) do
        local m, ratios = Presets.match(e.config, live_sets)
        out[#out + 1] = { entry = e, match = m, ratios = ratios }
    end
    table.sort(out, function(a, b)
        if RANK[a.match] ~= RANK[b.match] then return RANK[a.match] < RANK[b.match] end
        return a.entry.name < b.entry.name
    end)
    return out
end

return Presets
