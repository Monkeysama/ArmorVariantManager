-- RE4 预设库:指纹匹配三档、预设文件读写(编号 / 墓碑复用 / mod 预设只读)、自动保存只留 5 份。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
local Presets = require("ArmorVariantManager_Core.Games.RE4.Presets")

local function cfg_with(body, head, scope)
    return {
        version = 3,
        base = {presets = {A = {body = {materials = body}, head = {materials = head}}}},
        groups = {{name = "G", scope = scope or {}, options = {}}},
        conditions = {states = {}},
    }
end
local function live(body, head, armor)
    local function set(names) local t = {} for _, n in ipairs(names or {}) do t[n] = true end return t end
    return Presets.live_sets({body = {materials = set(body)}, head = {materials = set(head)},
        hair = {materials = {}}, armor = {materials = set(armor)}})
end

-- ============================================================ 匹配
do
    local cfg = cfg_with({a = true, b = false}, {h = true}, {"body/c"})
    local fp = Presets.fingerprint(cfg)
    S.equal(fp.body, {a = true, b = true, c = true}, "fingerprint includes group scope")

    assert(Presets.match(cfg, live({"a", "b", "c"}, {"h"})) == "full")
    -- 没穿护甲:指纹里没有的槛位不在当前模型上 —— 不影响
    assert(Presets.match(cfg, live({"a", "b", "c"}, {"h"}, {})) == "full")
    -- 当前模型多了一个槛位(护甲),预设不认识它
    assert(Presets.match(cfg, live({"a", "b", "c"}, {"h"}, {"x"})) == "partial")
    -- 改了材质:body 少一个
    local m, ratios = Presets.match(cfg, live({"a", "b"}, {"h"}))
    assert(m == "partial" and math.abs(ratios.body - 2 / 3) < 1e-9 and ratios.head == 1)
    -- 完全是另一个模型
    assert(Presets.match(cfg, live({"q", "r", "s", "t"}, {"z"})) == "none")
    assert(Presets.match(cfg, live({}, {})) == "none", "no live slots")
end

-- ============================================================ 预设文件
local files, clock = {}, 100
local io = {
    load = function(p) return files[p] and Presets.deep_copy(files[p]) or nil end,
    dump = function(p, t) files[p] = Presets.deep_copy(t) end,
    glob = function()
        local out = {}
        for p in pairs(files) do
            if p:find("^ArmorVariantManager/presets/") then out[#out + 1] = "reframework\\data\\" .. p:gsub("/", "\\") end
        end
        return out
    end,
    now = function() clock = clock + 1; return clock end,
}
files["ArmorVariantManager/presets/author_pack.json"] = {version = 3, name = "作者推荐", source = "mod",
    config = cfg_with({a = true}, {h = true})}
files["ArmorVariantManager/presets/broken.json"] = {name = "坏的"}

do
    local lib = Presets.library(io)
    local list = lib.list()
    assert(#list == 1 and list[1].id == "author_pack" and list[1].source == "mod", "mod preset listed, broken skipped")
    assert(not lib.delete("author_pack") and not lib.rename("author_pack", "x"))

    local cfg = cfg_with({a = true, b = true}, {h = true})
    cfg.source_preset = "author_pack"
    local id1 = lib.save_new("日常", cfg, "Leon")
    local id2 = lib.save_new("战斗", cfg, "Leon")
    assert(id1 == "p0001" and id2 == "p0002")
    local stored = files["ArmorVariantManager/presets/p0001.json"]
    assert(stored.name == "日常" and stored.character == "Leon" and stored.config.source_preset == nil)
    cfg.base.presets.A.body.materials.a = false
    assert(stored.config.base.presets.A.body.materials.a == true, "saved a deep copy")

    assert(lib.update(id1, cfg) and files["ArmorVariantManager/presets/p0001.json"].config.base.presets.A.body.materials.a == false)
    assert(lib.rename(id2, "战斗特化") and lib.get(id2).name == "战斗特化")
    assert(lib.delete(id1) and files["ArmorVariantManager/presets/p0001.json"].deleted == true)
    assert(lib.get(id1) == nil and #lib.list() == 2)

    -- 重新扫描:墓碑被识别、新建时复用最小的空号
    local lib2 = Presets.library(io)
    assert(#lib2.list() == 2)
    assert(lib2.save_new("又一个", cfg) == "p0001", "tombstone id reused")
    assert(lib2.save_new("再一个", cfg) == "p0003")

    -- glob 抛错(data 目录里有转不成 GBK 的文件名):退回索引 + 顺序探测,不打断请求
    assert(files[Presets.INDEX] and #files[Presets.INDEX].ids >= 3, "index written")
    local broken_io = setmetatable({ glob = function() error("No mapping for the Unicode character exists in the target multi-byte code page.") end }, { __index = io })
    local lib3 = Presets.library(broken_io)
    local names = {}
    for _, e in ipairs(lib3.list()) do names[e.id] = true end
    assert(names.author_pack and names.p0001 and names.p0002 and names.p0003, "index + probe recover every preset")
    assert(lib3.get(Presets.INDEX_ID) == nil, "index is not a preset")
    files[Presets.INDEX] = nil
    local lib4 = Presets.library(broken_io)
    assert(lib4.get("p0003") and lib4.get("author_pack") == nil, "without index only pNNNN can be probed")
    assert(lib4.save_new("索引重建", cfg) == "p0004" and files[Presets.INDEX], "saving rebuilds the index")

    -- 排序:完全适用 > 部分适用 > 不适用
    local ranked = Presets.ranked(lib2, live({"a"}, {"h"}))
    assert(ranked[1].entry.id == "author_pack" and ranked[1].match == "full")
    assert(ranked[2].match == "partial")
end

-- ============================================================ 自动保存
do
    local lib = Presets.library(io)
    for i = 1, 7 do lib.autosave_push("Leon", "第" .. i .. "次", cfg_with({a = i % 2 == 0}, {})) end
    local entries = lib.autosaves("Leon")
    assert(#entries == 5 and entries[1].name == "第7次" and entries[5].name == "第3次", "keeps newest 5")
    local again = Presets.library(io).autosaves("Leon")
    assert(#again == 5 and again[1].name == "第7次", "persisted")
    local taken = lib.autosave_take("Leon", 2)
    assert(taken.name == "第6次" and #lib.autosaves("Leon") == 4)
    assert(lib.autosave_take("Leon", 9) == nil)
    assert(#Presets.library(io).autosaves("Ashley") == 0)
end

-- ============================================================ 覆盖模组预设:不改模组文件,另存一份代替它
do
    local fs = {}
    local io2 = setmetatable({
        load = function(p) return fs[p] and Presets.deep_copy(fs[p]) or nil end,
        dump = function(p, t) fs[p] = Presets.deep_copy(t) end,
        glob = function()
            local out = {}
            for p in pairs(fs) do if p:find("^ArmorVariantManager/presets/") then out[#out + 1] = p end end
            return out
        end,
    }, { __index = io })
    local MOD = "ArmorVariantManager/presets/author_pack.json"
    fs[MOD] = { version = 3, name = "作者推荐", source = "mod", config = cfg_with({ a = true }, { h = true }) }
    local lib = Presets.library(io2)
    local ok, written = lib.update("author_pack", cfg_with({ a = false }, { h = true }))
    assert(ok and written == "p0001", "overwriting a mod preset writes an own copy")
    assert(fs[MOD].config.base.presets.A.body.materials.a == true, "the mod file is untouched")
    local copy = fs["ArmorVariantManager/presets/p0001.json"]
    assert(copy.source == "user" and copy.overrides == "author_pack" and copy.name == "作者推荐")
    local list = lib.list()
    assert(#list == 1 and list[1].id == "p0001" and list[1].override_of == "author_pack", "the copy replaces the mod preset in the list")
    assert(lib.effective("author_pack").id == "p0001", "effective() follows the overwrite")
    assert(not lib.rename("p0001", "别的"), "an overwrite keeps the mod preset's name")
    ok, written = lib.update("author_pack", cfg_with({ a = true }, { h = false }))
    assert(ok and written == "p0001", "overwriting again reuses the same copy")
    -- 重新扫描后照样认得
    local lib2 = Presets.library(io2)
    assert(#lib2.list() == 1 and lib2.list()[1].override_of == "author_pack")
    -- 恢复原版:删掉副本,模组预设重新出现
    local rok, mod_id = lib2.revert("p0001")
    assert(rok and mod_id == "author_pack" and fs["ArmorVariantManager/presets/p0001.json"].deleted == true)
    list = lib2.list()
    assert(#list == 1 and list[1].id == "author_pack" and list[1].source == "mod", "mod preset is back")
    assert(not lib2.revert("author_pack"), "nothing to restore")
    -- 模组被卸载:副本当作普通自定义预设
    lib2.update("author_pack", cfg_with({ a = false }, { h = true }))
    fs[MOD] = nil
    local lib3 = Presets.library(io2)
    list = lib3.list()
    assert(#list == 1 and list[1].source == "user" and list[1].override_of == nil, "orphaned copy is a plain user preset")
end

-- ============================================================ 双语预设名
do
    local fs, lang = {}, "zh"
    local io3 = {
        load = function(p) return fs[p] and Presets.deep_copy(fs[p]) or nil end,
        dump = function(p, t) fs[p] = Presets.deep_copy(t) end,
        glob = function()
            local out = {}
            for p in pairs(fs) do if p:find("^ArmorVariantManager/presets/") then out[#out + 1] = p end end
            return out
        end,
        now = function() return 1 end,
        lang = function() return lang end,
    }
    fs["ArmorVariantManager/presets/m.json"] = {version = 3, name = "B 作者推荐", name_en = "0 Author pick", source = "mod",
        config = cfg_with({a = true}, {h = true})}
    fs["ArmorVariantManager/presets/n.json"] = {version = 3, name = "A 只有中文", name_en = "", source = "mod",
        config = cfg_with({a = true}, {h = true})}
    local lib = Presets.library(io3)
    local m, n = lib.get("m"), lib.get("n")
    assert(lib.label(m) == "B 作者推荐" and lib.label(n) == "A 只有中文", "zh shows name")
    assert(n.name_en == nil, "empty name_en is ignored")
    lang = "en"
    assert(lib.label(m) == "0 Author pick" and lib.label(n) == "A 只有中文", "en shows name_en, falls back to name")
    assert(Presets.label(m, "zh") == "B 作者推荐" and Presets.label(nil, "en") == "")
    assert(lib.list()[1].id == "m", "en sorts by English label")
    lang = "zh"
    assert(lib.list()[1].id == "n", "zh sorts by default name")
    -- 覆盖至:副本带上英文名
    lib.update("m", cfg_with({a = false}, {h = true}))
    local copy = fs["ArmorVariantManager/presets/p0001.json"]
    assert(copy.name == "B 作者推荐" and copy.name_en == "0 Author pick", "overwrite copy keeps both names")
    -- 改名:改界面上看到的那个名字
    fs["ArmorVariantManager/presets/p0005.json"] = {version = 3, name = "日常", name_en = "Daily", source = "user",
        config = cfg_with({a = true}, {h = true})}
    lib.refresh()
    lang = "en"
    assert(lib.rename("p0005", "Everyday"))
    assert(fs["ArmorVariantManager/presets/p0005.json"].name == "日常" and fs["ArmorVariantManager/presets/p0005.json"].name_en == "Everyday")
    assert(not lib.rename("p0005", "Everyday"), "same label is a no-op")
    lang = "zh"
    assert(lib.rename("p0005", "平时") and lib.get("p0005").name == "平时" and lib.get("p0005").name_en == "Everyday")
    -- 没有英文名的自定义预设,英文界面改名改的是 name,不凭空加 name_en
    local id = lib.save_new("战斗", cfg_with({a = true}, {h = true}), "Leon")
    lang = "en"
    assert(lib.rename(id, "Combat") and lib.get(id).name == "Combat" and lib.get(id).name_en == nil)
    assert(fs["ArmorVariantManager/presets/" .. id .. ".json"].name_en == nil)
end

print("PASS: preset fingerprint matching (full / partial / none, missing armor), preset files (ids, tombstone reuse, read-only mod presets, deep copies), mod preset overwrite / restore, ranking and 5-entry auto-save, bilingual preset names")
