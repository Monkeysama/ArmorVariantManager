package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Store = require("ArmorVariantManager_Core.Config.Store")
local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local Schema = require("ArmorVariantManager_Core.Games.Wilds.Config")
local source = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")

assert(Store.config_path("ch03_001_0000") == "ArmorVariantManager/ch03_001_0000.json")
assert(Store.backup_path("ch03_001_0000") == "ArmorVariantManager/backup/ch03_001_0000.json")
assert(Store.config_path(nil) == nil and Store.backup_path(nil) == nil)

-- 文件接口使用临时文件；编解码由 REFramework 提供，这里验证调用及失败时的写入边界。
local path = os.tmpname()
local original = { presets = { A = {} }, extension = { enabled = false } }
local errors, decodes = {}, 0
log = { error = function(message) errors[#errors + 1] = message end }
json = {
    load_string = function(text)
        decodes = decodes + 1
        assert(text == '{"presets":{"A":{}},"extension":{"enabled":false}}')
        return S.copy(original)
    end,
    dump_string = function(value, indent)
        S.equal(value, original)
        assert(indent == 4)
        return '{"presets":{"A":{}},"extension":{"enabled":false}}'
    end
}
assert(Store.load(path) == nil and decodes == 0)
assert(Store.save(path, original))
S.equal(Store.load(path), original)
local saved = S.read(path)
json.dump_string = function() error("codec failure") end
assert(not Store.save(path, original) and #errors == 1)
assert(S.read(path) == saved, "Serialization failure must preserve the previous file")
local file = assert(io.open(path, "w")); file:write("\239\187\191" .. saved); file:close()
S.equal(Store.load(path), original)
file = assert(io.open(path, "w")); file:write("invalid JSON"); file:close()
assert(Store.load(path) == nil)
os.remove(path)
assert(Store.load(path) == nil)

-- 运行真实入口的加载及备份比较，避免只验证模块而漏掉调用接线。
local disk, reads, refreshes = {}, 0, 0
local env = setmetatable({
    get_config_path = Store.config_path, get_backup_path = Store.backup_path,
    ConfigNormalize = Normalize, GameConfig = Schema, loaded_configs = {}, config_restored = {},
    safe_json_load = function(name) reads = reads + 1; return S.copy(disk[name]) end,
    TransformManager = { refresh_config_rules = function() refreshes = refreshes + 1 end },
    log = { info = function() end }
}, { __index = _G })
local detection = S.section(source, "local function deep_equal", "-- =============================================================================\n-- 预设和分组 UI")
local loading = S.section(source, "local function load_config_data", "-- 辅助函数：将预设数据合并")
local load_config = assert(load(detection .. loading .. "\nreturn load_config_data", "entry-config", "t", env))()
disk[Store.config_path("armor")] = S.copy(original)
disk[Store.backup_path("armor")] = S.copy(original)
local config = load_config("armor")
S.equal(config, Normalize.apply(S.copy(original), Schema))
assert(not env.config_restored.armor, "Compare raw files, not normalized defaults")
local before = reads
assert(load_config("armor") == config and reads == before and refreshes == 1)
disk[Store.backup_path("deleted")] = S.copy(original)
assert(load_config("deleted") == nil and env.config_restored.deleted)
before = reads
assert(load_config("deleted") == nil and reads == before, "Failed loads are cached")
disk[Store.config_path("changed")] = { presets = {} }
disk[Store.backup_path("changed")] = S.copy(original)
assert(load_config("changed") and env.config_restored.changed)
S.equal(disk[Store.backup_path("changed")], original, "Do not overwrite an unresolved backup")
assert(load_config(nil) == nil)
print("PASS: config paths, file IO, codec failure, cached entry loading and raw backup comparison")
