-- 网格可见性组(Viscon,via.render.Mesh 的 PartsEnable)。导出模型时给几何分配的组号,同一组的几何一起开关。
-- 和材质开关是两套独立的开关:引擎只画两者都开着的几何,一边写开拉不回另一边关掉的。
--
-- 改过的组记下原值,网格不再是目标(refresh)或脚本重置(reset)时还原;还原前核对当前值仍是我们写的,
-- 别处改过的不动。缓存按对象地址,refresh 时用资源路径核对:同一地址换了网格就丢掉旧记录。
-- 生命周期由目标收集方负责:RE9 由 Games/RE9/Targets.lua 扫描时调用,RE4 由 Main 的帧循环调用。
local Viscon = {}

-- 组号 → 配置里的键名。RE9 移植版就用这个格式存配置,沿用以免旧配置失效
function Viscon.name(id) return string.format("Viscon %03d", id) end
function Viscon.is_name(name) return type(name) == "string" and name:match("^Viscon %d%d%d$") ~= nil end

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
        entry = { mesh = mesh, parts = read_parts(mesh), originals = {}, shadows = {} }
        cache[key] = entry
    end
    return entry
end

local function ready(mesh)
    local go = mesh:call("get_GameObject")
    return go and go:call("get_Valid") and mesh:call("get_MeshReady")
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
    end)
    entry.originals = {}
end

-- seen = { [网格地址] = 资源路径 }:这一轮仍是目标的网格。不在里面的还原后移出;路径变了的只移出;
-- 读写时顺手建的记录(还没有路径)在第一次 refresh 时记下路径
function Viscon.refresh(seen)
    for address, entry in pairs(cache) do
        local resource = seen[address]
        if resource == nil then
            restore(entry)
            cache[address] = nil
        elseif entry.resource == nil then
            entry.resource = resource
        elseif resource ~= entry.resource then
            cache[address] = nil
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

function Viscon.reset()
    for _, entry in pairs(cache) do restore(entry) end
    cache = {}
end

return Viscon
