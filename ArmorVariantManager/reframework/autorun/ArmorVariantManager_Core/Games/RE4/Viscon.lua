-- 网格可见性组(Viscon,via.render.Mesh 的 PartsEnable)。导出模型时给几何分配的组号,同一组的几何一起开关。
-- 和材质开关是两套独立的开关:引擎只画两者都开着的几何,一边写开拉不回另一边关掉的。
--
-- 改过的组记下原值,网格不再是目标(refresh)或脚本重置(reset)时还原;还原前核对当前值仍是我们写的,
-- 别处改过的不动。缓存按对象地址,refresh 时用资源路径核对:同一地址换了网格就丢掉旧记录。
-- 生命周期由目标收集方负责:RE9 由 Games/RE9/Targets.lua 扫描时调用,RE4 由 Main 的帧循环调用。
--
-- 本模块也负责 RE9 的材质开关(见下面「材质位图」),和组共用同一套原值记录与生命周期。
local Viscon = {}

-- 组号 → 配置里的键名。RE9 移植版就用这个格式存配置,沿用以免旧配置失效
function Viscon.name(id) return string.format("Viscon %03d", id) end
function Viscon.is_name(name) return type(name) == "string" and name:match("^Viscon %d%d%d$") ~= nil end

-- 一个部位里材质、组两类开关有没有被预设用到,界面据此决定默认展开哪一段。
--   full   整套造型的 { 名字 → 布尔 } 列表:出现「关」才算用到(抓取时全部记成开,全开等于没动过)
--   sparse 状态组选项的 { 名字 → 布尔 } 列表:写了就算用到(只存刻意改过的开关)
-- 返回 materials_used, groups_used
function Viscon.usage(full, sparse)
    local used = { material = false, group = false }
    local function mark(name) used[Viscon.is_name(name) and "group" or "material"] = true end
    for _, values in ipairs(full or {}) do
        for name, v in pairs(values) do if v == false then mark(name) end end
    end
    for _, values in ipairs(sparse or {}) do
        for name, v in pairs(values) do if type(v) == "boolean" then mark(name) end end
    end
    return used.material, used.group
end

-- 默认展开:只有一类用到就只展开那一类;都没用到时展开材质(原来就是按材质切换);都用到就都展开
function Viscon.default_open(materials_used, groups_used)
    return materials_used or not groups_used, groups_used
end

-- 网格实际用到的组号,升序。getPartsEnableIndices 会重复、也可能超出组数,两样都滤掉。
-- 读不到(不是 Mesh、还没加载好)时返回空表
local function read_parts(mesh)
    local result, seen = {}, {}
    local ok = pcall(function()
        local count = mesh:call("getPartsEnableIndicesCount")
        local limit = mesh:call("getPartsEnableCount")
        if type(count) ~= "number" or type(limit) ~= "number" then return end
        for index = 0, count - 1 do
            local part = mesh:call("getPartsEnableIndices", index)
            if type(part) == "number" and part < limit and not seen[part] then
                seen[part] = true
                result[#result + 1] = part
            end
        end
    end)
    if not ok then return {} end
    table.sort(result)
    return result
end

local cache = {}
local function info(mesh)
    local key = mesh:get_address()
    local entry = cache[key]
    if not entry then
        entry = { mesh = mesh, parts = read_parts(mesh), originals = {}, mat_originals = {}, shadows = {} }
        cache[key] = entry
    end
    return entry
end

local function ready(mesh)
    local go = mesh:call("get_GameObject")
    return go and go:call("get_Valid") and mesh:call("get_MeshReady")
end

-- ============================================================ 材质位图(RE9)
-- RE9 的 TDB 没有 get/setMaterialsEnable,但 Mesh 里仍有材质开关位图:紧跟在组位图(PartsEnable)之后,
-- 第 j 位 = 材质 j。只写位图渲染端不会更新,要把组件关掉再打开、让它重建渲染数据才生效;重建不改位图,
-- 也不动组开关。位图偏移随游戏版本可能变,第一次用到时校准(calibrate):翻一个网格没用到的组位,
-- 比对内存找到组位图,材质位图在它后面。校准不出来就不提供材质开关,界面只列组。
local SCAN_FROM, SCAN_TO = 0x100, 0x5F0   -- 在 Mesh 对象里找位图的范围(RE9 的 via.render.Mesh 大小 0x5F0)
local MAX_ATTEMPTS = 3
local calib = { offset = nil, error = nil, attempts = 0 }   -- offset:nil 未校准,false 放弃,数字 = 材质位图偏移
local dirty = {}                                            -- [地址] = mesh:改过材质位、帧末重建

local function bit_of(mesh, base, index)
    return (mesh:read_byte(base + (index // 8)) >> (index % 8)) & 1 == 1
end

local function calibrate(mesh)
    local limit = mesh:call("getPartsEnableCount")
    if type(limit) ~= "number" or limit < 8 or limit % 8 ~= 0 then return nil, "parts count " .. tostring(limit) end
    local used = {}
    for _, p in ipairs(read_parts(mesh)) do used[p] = true end
    local probe = limit - 1
    while probe >= 0 and used[probe] do probe = probe - 1 end
    if probe < 0 then return nil, "no unused part to probe" end
    local before = {}
    for off = SCAN_FROM, SCAN_TO - 1 do before[off] = mesh:read_byte(off) end
    local current = mesh:call("getPartsEnable", probe)
    local mask = 1 << (probe % 8)
    mesh:call("setPartsEnable", probe, not current)
    -- 候选:恰好翻了那一位的字节。包围盒、LOD 这类字段可能被渲染线程同时改写,所以再要求还原后回到原值
    local candidates = {}
    for off = SCAN_FROM, SCAN_TO - 1 do
        if (mesh:read_byte(off) ~ before[off]) == mask then candidates[#candidates + 1] = off end
    end
    mesh:call("setPartsEnable", probe, current)
    local hits = {}
    for _, off in ipairs(candidates) do
        if mesh:read_byte(off) == before[off] then hits[#hits + 1] = off end
    end
    if #hits ~= 1 then return nil, "probe matched " .. #hits .. " bytes" end
    local parts_base = hits[1] - (probe // 8)
    for p in pairs(used) do
        if bit_of(mesh, parts_base, p) ~= (mesh:call("getPartsEnable", p) == true) then return nil, "parts bitmap mismatch" end
    end
    local base = parts_base + limit // 8
    if base + 32 > SCAN_TO then return nil, "material bitmap out of range" end
    return base
end

-- 这个网格能不能按位图开关材质;第一次调用时拿它校准,失败几次后放弃
function Viscon.material_ready(mesh)
    if calib.offset == nil then
        local ok, base, err = pcall(calibrate, mesh)
        if not ok then base, err = nil, tostring(base) end
        calib.attempts = calib.attempts + 1
        if base then
            calib.offset, calib.error = base, nil
        else
            calib.error = err
            if calib.attempts >= MAX_ATTEMPTS then calib.offset = false end
        end
        if log and log.info then
            log.info("[ArmorVariantManager] material bitmap " .. (base and string.format("at 0x%X", base) or ("unavailable: " .. tostring(err))))
        end
    end
    return type(calib.offset) == "number"
end

function Viscon.material_error() return calib.error end

function Viscon.get_material(mesh, index)
    if type(calib.offset) ~= "number" then return nil end
    return bit_of(mesh, calib.offset, index)
end

local function write_material(mesh, index, enabled)
    local addr = calib.offset + (index // 8)
    local mask = 1 << (index % 8)
    local b = mesh:read_byte(addr)
    mesh:write_byte(addr, enabled and (b | mask) or (b & (~mask & 0xFF)))
    dirty[mesh:get_address()] = mesh
end

local function set_material(entry, index, enabled)
    local mesh = entry.mesh
    local current = Viscon.get_material(mesh, index)
    if current == nil or current == enabled then return end
    local record = entry.mat_originals[index]
    local original = current
    if record and current == record.applied then original = record.value end
    write_material(mesh, index, enabled)
    entry.mat_originals[index] = { value = original, applied = enabled }
end

function Viscon.set_material(mesh, index, enabled)
    if type(calib.offset) ~= "number" then return end
    local entry = info(mesh)
    set_material(entry, index, enabled)
    for _, shadow in ipairs(entry.shadows) do
        if ready(shadow) then set_material(info(shadow), index, enabled) end
    end
end

-- 关掉再打开组件让渲染端读新位图。本来就关着的组件不碰(游戏藏起来的不能被我们打开),它下次启用时自然会读
local function rebuild(mesh)
    if mesh:call("get_Enabled") then
        mesh:call("set_Enabled", false)
        mesh:call("set_Enabled", true)
    end
end

-- 帧末调用:这一帧改过材质位的网格各重建一次
function Viscon.flush()
    if next(dirty) == nil then return end
    local list = dirty
    dirty = {}
    for _, mesh in pairs(list) do
        pcall(function() if ready(mesh) then rebuild(mesh) end end)
    end
end

local function restore(entry)
    if not entry then return end
    pcall(function()
        if not ready(entry.mesh) then return end
        for part, original in pairs(entry.originals) do
            if entry.mesh:call("getPartsEnable", part) == original.applied then
                entry.mesh:call("setPartsEnable", part, original.value)
            end
        end
        local touched = false
        for index, original in pairs(entry.mat_originals) do
            if Viscon.get_material(entry.mesh, index) == original.applied then
                write_material(entry.mesh, index, original.value)
                touched = true
            end
        end
        if touched then
            dirty[entry.mesh:get_address()] = nil
            rebuild(entry.mesh)
        end
    end)
    entry.originals = {}
    entry.mat_originals = {}
end

-- seen = { [网格地址] = 资源路径 }:这一轮仍是目标的网格。不在里面的还原后移出;路径变了的只移出;
-- 读写时顺手建的记录(还没有路径)在第一次 refresh 时记下路径
function Viscon.refresh(seen)
    for address, entry in pairs(cache) do
        local resource = seen[address]
        if resource == nil then
            restore(entry)
            cache[address] = nil
            dirty[address] = nil
        elseif entry.resource == nil then
            entry.resource = resource
        elseif resource ~= entry.resource then
            cache[address] = nil
            dirty[address] = nil
        end
    end
end

-- 登记一个目标网格;shadows = 同一资源的阴影网格,开关跟着主网格走
function Viscon.add(mesh, resource, shadows)
    local entry = info(mesh)
    entry.resource = resource
    entry.shadows = shadows or {}
    return mesh
end

function Viscon.groups(mesh)
    return info(mesh).parts
end

function Viscon.get(mesh, part)
    return mesh:call("getPartsEnable", part)
end

local function set(entry, part, enabled)
    local mesh = entry.mesh
    local current = mesh:call("getPartsEnable", part)
    if current == enabled then return end
    local record = entry.originals[part]
    local original = current
    if record and current == record.applied then original = record.value end
    mesh:call("setPartsEnable", part, enabled)
    entry.originals[part] = { value = original, applied = enabled }
end

function Viscon.set(mesh, part, enabled)
    local entry = info(mesh)
    set(entry, part, enabled)
    for _, shadow in ipairs(entry.shadows) do
        if ready(shadow) then set(info(shadow), part, enabled) end
    end
end

-- 脚本重置:还原全部改动,下次用到时重新校准
function Viscon.reset()
    for _, entry in pairs(cache) do restore(entry) end
    cache = {}
    dirty = {}
    calib = { offset = nil, error = nil, attempts = 0 }
end

return Viscon
