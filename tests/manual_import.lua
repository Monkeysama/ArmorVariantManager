package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Weapons = require("ArmorVariantManager_Core.Games.Rise.Weapons")
local legacy = dofile("tests/fixtures/legacy/rise_manual_import.lua")

local patterns = {
    "reframework/data/ArmorVariantManager/.*\\.json",
    "reframework\\\\data\\\\ArmorVariantManager\\\\.*\\.json",
    "ArmorVariantManager/.*\\.json",
    "ArmorVariantManager\\\\.*\\.json",
    "data/ArmorVariantManager/.*\\.json",
}

local function files_for(results, responses)
    local trace, index = {}, 0
    return {
        fs={glob=function(pattern)
            trace[#trace + 1] = {"glob", pattern}
            index = index + 1
            return (results or {})[index]
        end},
        load=function(path)
            trace[#trace + 1] = {"load", path}
            local response = (responses or {})[path]
            if type(response) == "function" then return response() end
            return response
        end,
    }, trace
end

local function old_import(files, weapon)
    local env = setmetatable({
        fs=files.fs, json={load_file=files.load}, is_weapon_mode=weapon,
        Utils=Weapons, T=function(key) return key end,
        save_current_config_to_file=function() end,
        update_preset_names_list=function() end,
        update_group_names_list=function() end,
        apply_all_defaults=function() end,
        get_primary_player=function() return nil end,
    }, {__index=_G})
    return legacy(env), env
end

local results = {
    {"ArmorVariantManager/zeta.json", "ArmorVariantManager/GlobalSettings.json",
     "ArmorVariantManager/Runtime/ignored.json", "ArmorVariantManager/runtime_export.json"},
    {"reframework\\data\\ArmorVariantManager\\beta.json", "ArmorVariantManager/backup/archived.json"},
    {"ArmorVariantManager/alpha.json", "ArmorVariantManager/zeta.json"},
    {"ArmorVariantManager\\gamma.json", "ArmorVariantManager\\Backup\\older.json"},
    {"data/ArmorVariantManager/delta.json", "ArmorVariantManager/globalsettings.json"},
}
local armor = {
    {path="ArmorVariantManager/backup/archived.json",name="[备份] archived"},
    {path="ArmorVariantManager\\Backup\\older.json",name="[备份] older"},
    {path="ArmorVariantManager/alpha.json",name="alpha"},
    {path="reframework\\data\\ArmorVariantManager\\beta.json",name="beta"},
    {path="data/ArmorVariantManager/delta.json",name="delta"},
    {path="ArmorVariantManager\\gamma.json",name="gamma"},
    {path="ArmorVariantManager/globalsettings.json",name="globalsettings"},
    {path="ArmorVariantManager/zeta.json",name="zeta"},
}
local weapon = S.copy(armor)
local prefixes = {}
for _, parts in pairs(Weapons.WEAPON_PARTS_MAP) do
    for _, part in ipairs(parts) do prefixes[part.prefix] = true end
end
for prefix in pairs(prefixes) do
    local path = "ArmorVariantManager/" .. prefix .. "001.json"
    results[1][#results[1] + 1] = path
    weapon[#weapon + 1] = {path=path,name=prefix .. "001"}
end
table.sort(weapon, function(a, b) return a.name < b.name end)

local function check_list(factory, label)
    for _, mode in ipairs({false, true}) do
        local files, trace = files_for(results)
        S.equal(factory(files, mode).list(mode), mode and weapon or armor, label .. " file list")
        local expected = {}
        for _, pattern in ipairs(patterns) do expected[#expected + 1] = {"glob", pattern} end
        S.equal(trace, expected, label .. " five path patterns")
    end
    S.equal(factory({load=function() error("unexpected load") end}, false).list(false), {})
    S.equal(factory({fs={},load=function() error("unexpected load") end}, false).list(false), {})
end

local candidate = {presets={one={}}, groups={}, unknown={nested={keep=7}}, enable_transform=false}
local loads = {
    {path="ArmorVariantManager/direct.json",success="ArmorVariantManager/direct.json"},
    {path="ArmorVariantManager/prefixed.json",success="reframework/data/ArmorVariantManager/prefixed.json"},
    {path="ArmorVariantManager/relative.json",success="relative.json"},
    {path="armorVariantmanager\\mixed.json",success="mixed.json"},
    {path="ArmorVariantManager/missing.json"},
    {path="ArmorVariantManager/false.json",value=false,success="false.json"},
    {path="ArmorVariantManager/scalar.json",value="not a table"},
    {path="ArmorVariantManager/empty-table.json",value={}},
}

local function loading(factory, scenario)
    local responses = {}
    if scenario.value ~= nil then responses[scenario.path] = scenario.value end
    if scenario.success then responses[scenario.success] = candidate end
    local files, trace = files_for(nil, responses)
    local service, env = factory(files, false)
    local data, reason
    if env then
        local ok
        ok, reason = service.load(scenario.path, "armor")
        if ok then data = env.current_config end
    else
        data, reason = service.load(scenario.path)
    end
    return data, trace, reason
end

-- 冻结旧函数先建立列表、路径回退和未知字段的可达行为基线。
check_list(old_import, "legacy")
for _, scenario in ipairs(loads) do
    local data, trace = loading(old_import, scenario)
    local expected = scenario.success and candidate or type(scenario.value) == "table" and scenario.value or nil
    S.equal(data, expected, "legacy load " .. scenario.path)
    local paths = {scenario.path, "reframework/data/" .. scenario.path,
        (scenario.path:gsub("^[Aa]rmor[Vv]ariant[Mm]anager[/\\]", ""))}
    local count = 3
    for index, path in ipairs(paths) do
        if path == scenario.success or index == 1 and scenario.value then count = index; break end
    end
    local expected_trace = {}
    for index = 1, count do expected_trace[#expected_trace + 1] = {"load", paths[index]} end
    S.equal(trace, expected_trace, "legacy fallback " .. scenario.path)
end
print("PASS: legacy manual import baseline")

local ManualImport = require("ArmorVariantManager_Core.Games.Rise.ManualImport")
local function modern(files) return ManualImport.new(files) end
check_list(modern, "modern")
for _, scenario in ipairs(loads) do
    local actual, trace = loading(modern, scenario)
    local expected, old_trace = loading(old_import, scenario)
    S.equal(actual, expected, "manual load " .. scenario.path)
    S.equal(trace, old_trace, "manual load paths " .. scenario.path)
end

-- 文件读取只返回候选；不复制或补齐数据，空 table 保持旧 JSON 的接受条件。
local files = files_for(nil, {[loads[1].path]=candidate})
assert(modern(files).load(loads[1].path) == candidate)
S.equal(candidate, {presets={one={}},groups={},unknown={nested={keep=7}},enable_transform=false})

-- 相同文件名的两种原始路径各自可选，不做路径标准化后去重。
files = files_for({{"ArmorVariantManager/alias.json", "ArmorVariantManager\\alias.json"}})
local aliases = modern(files).list(false)
assert(#aliases == 2 and aliases[1].path ~= aliases[2].path)
assert(aliases[1].name == "alias" and aliases[2].name == "alias")

-- 正式入口不必重复传入 REFramework 的文件与 JSON 依赖。
local previous_fs, previous_json = fs, json
files = files_for(results, {[loads[1].path]=candidate})
fs, json = files.fs, {load_file=files.load}
local default = ManualImport.new()
S.equal(default.list(false), armor)
assert(default.load(loads[1].path) == candidate)
fs, json = previous_fs, previous_json

-- 真实读取原因不可被默认失败消息覆盖；nil/false 继续旧路径回退。
local function failure(path)
    if path == "ArmorVariantManager/broken.json" then return false, "JSON decode failed at line 4" end
end
local service = modern({load=failure})
local data, reason = service.load("ArmorVariantManager/broken.json")
assert(data == nil and reason:find("JSON decode failed at line 4", 1, true))
files = files_for(nil, {
    [loads[1].path]=function() return false, "raw path unavailable" end,
    ["reframework/data/" .. loads[1].path]=candidate,
})
assert(modern(files).load(loads[1].path) == candidate)
data, reason = modern({load=function() error("permission denied", 0) end}).load("ArmorVariantManager/broken.json")
assert(data == nil and reason:find("permission denied", 1, true))
local trace
files, trace = files_for(nil, {
    [loads[1].path]=function() error("JSON parse failed", 0) end,
    ["reframework/data/" .. loads[1].path]=candidate,
})
data, reason = modern(files).load(loads[1].path)
assert(data == nil and reason == "JSON parse failed")
S.equal(trace, {{"load",loads[1].path}}, "parse failure must not import a different file")
for _, path in ipairs({false, ""}) do
    data, reason = modern({load=function() error("must not read") end}).load(path)
    assert(data == nil and type(reason) == "string" and reason ~= "")
end
data, reason = modern({load=function() error("must not read") end}).load(nil)
assert(data == nil and type(reason) == "string" and reason ~= "")
data, reason = modern({load=function() return "not a table" end}).load("ArmorVariantManager/scalar.json")
assert(data == nil and type(reason) == "string" and reason ~= "")
data, reason = modern({load=function() return nil end}).load("ArmorVariantManager/missing.json")
assert(data == nil and reason:find("ArmorVariantManager/missing.json", 1, true))
print("PASS: Rise manual file listing, path fallbacks, unknown fields and read failures")
