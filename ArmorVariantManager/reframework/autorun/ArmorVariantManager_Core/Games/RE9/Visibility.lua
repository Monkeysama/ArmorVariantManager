local Visibility = {}

local function parts(mesh)
    local count = mesh:call("getPartsEnableIndicesCount")
    local result, seen = {}, {}
    local limit = mesh:call("getPartsEnableCount")
    for index = 0, count - 1 do
        local part = mesh:call("getPartsEnableIndices", index)
        if part < limit and not seen[part] then
            seen[part] = true
            result[#result + 1] = part
        end
    end
    table.sort(result)
    return result
end

local cache = {}
local function info(mesh)
    local key = mesh:get_address()
    local entry = cache[key]
    if not entry then
        entry = { mesh = mesh, parts = parts(mesh), originals = {}, shadows = {} }
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

function Visibility.refresh(entries)
    for address, entry in pairs(cache) do
        if entries[address] ~= entry.resource then
            if entries[address] == nil then restore(entry) end
            cache[address] = nil
        end
    end
end

function Visibility.add(mesh, resource, shadows)
    local entry = info(mesh)
    entry.resource = resource
    entry.shadows = shadows or {}
    return entry.mesh
end

function Visibility.count(mesh)
    return #info(mesh).parts
end

function Visibility.name(mesh, index)
    local part = info(mesh).parts[index + 1]
    if part ~= nil then return string.format("Viscon %03d", part) end
end

function Visibility.get(mesh, index)
    local part = info(mesh).parts[index + 1]
    if part ~= nil then return mesh:call("getPartsEnable", part) end
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

function Visibility.set(mesh, index, enabled)
    local entry = info(mesh)
    local part = entry.parts[index + 1]
    if part == nil then return end
    set(entry, part, enabled)
    for _, shadow in ipairs(entry.shadows) do
        if ready(shadow) then set(info(shadow), part, enabled) end
    end
end

function Visibility.reset()
    for _, entry in pairs(cache) do restore(entry) end
    cache = {}
end
return Visibility
