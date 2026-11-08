-- RE4 内置溶解样式(DissolveStyles.lua):全局溶解预设库(迁移、增删改名、默认 / 随机)、
-- 按过渡提示选预设、换噪声图 / 还原(只记路径不碰原 holder)、反向切换不重复记原值、光边覆盖(格子大小取倒数)、
-- 调色写入、定位复位、血量驱动、不带噪声槽的材质不管、"原样 + 无光边"的预设让给其他提供者。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

_G.Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
local now = 0
os.clock = function() return now end
_G.json = { load_file = function() return nil end, dump_file = function() return true end }

local Dissolve = require("ArmorVariantManager_Core.Games.RE4.Dissolve")
local Styles = require("ArmorVariantManager_Core.Games.RE4.DissolveStyles")

local function tex(path) return { path = path, call = function(self, m) if m == "get_ResourcePath" then return self.path end end } end

local function fake(id, with_noise)
    local m = { id = id, enabled = {}, tex = {}, sets = 0,
        values = { [0] = { x = 0, y = 0, z = 0, w = 0 }, [1] = { x = 1, y = 0, z = 0, w = 0 }, [2] = { x = 0.25, y = 0.6, z = 4, w = 0 },
            [3] = { x = 1, y = 1, z = 1.5, w = 1 } } }
    local vars = { [0] = "Dissolve_Rate", [1] = "Dissolve_Flag", [2] = "Dissolve_Edge", [3] = "Dissolve_Misc" }
    local slots = with_noise and { [0] = "BaseDielectricMap", [1] = "Dissolve_Map", [2] = "Dissolve_NoiseMap" } or { [0] = "BaseDielectricMap" }
    m.tex[0] = tex("orig/base.tex"); m.tex[1] = tex("orig/" .. id .. "_Dissolve_Map.tex"); m.tex[2] = tex("orig/Burn_NoiseMap.tex")
    function m:call(method, j, a, b)
        if method == "getMaterialName" then return "mat" .. j
        elseif method == "get_MaterialNum" then return 1
        elseif method == "getMaterialVariableNum" then return 4
        elseif method == "getMaterialVariableName" then return vars[a]
        elseif method == "getMaterialFloat4" then return self.values[a]
        elseif method == "setMaterialFloat4" then self.values[a] = b
        elseif method == "setMaterialsEnable" then self.enabled[j] = a
        elseif method == "getMaterialTextureNum" then return with_noise and 3 or 1
        elseif method == "getMaterialTextureName" then return slots[a]
        elseif method == "getMaterialTexture" then return self.tex[a]
        elseif method == "setMaterialTexture" then self.tex[a] = b; self.sets = self.sets + 1
        end
    end
    return setmetatable(m, { __tostring = function() return "mesh:" .. id end })
end

-- ---------------------------------------------------------------- 预设库
local lib = Styles.clean_presets(nil, { shape = "hex", edge = { width = { on = true, value = 0.5 } } })
assert(#lib.order == 1 and lib.order[1] == Styles.DEFAULT_PRESET and lib.default == Styles.DEFAULT_PRESET, "legacy migrates to one default preset")
assert(lib.items[Styles.DEFAULT_PRESET].shape == "hex" and lib.items[Styles.DEFAULT_PRESET].edge.width.on, "legacy shape and edge kept")
assert(Styles.clean_presets(nil, { shape = "bogus" }).items[Styles.DEFAULT_PRESET].shape == "original", "unknown legacy shape -> original")
local read = Styles.clean_presets({ order = { "b", "a", "a" }, items = { a = { shape = "square" }, b = { shape = "zzz" }, random = {}, [""] = {}, c = {} },
    default = "gone" })
assert(table.concat(read.order, ",") == "b,a,c" and read.items.b.shape == "original" and read.items.random == nil, "order / names / shapes cleaned")
assert(read.default == "b", "missing default falls back to the first")
assert(Styles.clean_presets({ items = {}, default = "random" }).default == "random", "random default kept")
assert(Styles.clean_presets({}, nil).default == nil and #Styles.clean_presets({}, nil).order == 0, "empty library stays empty")
assert(Styles.preset_new(lib, "蓝光", nil) and lib.items["蓝光"].shape == "original")
assert(not Styles.preset_new(lib, "蓝光"), "duplicate name rejected")
assert(not Styles.preset_new(lib, "random"), "reserved name rejected")
assert(Styles.preset_new(lib, "复制", Styles.DEFAULT_PRESET) and lib.items["复制"].shape == "hex" and lib.items["复制"].edge.width.value == 0.5)
lib.items["复制"].edge.width.value = 0.9
assert(lib.items[Styles.DEFAULT_PRESET].edge.width.value == 0.5, "duplicate is a deep copy")
assert(Styles.preset_shape(lib, "蓝光", "square") and not Styles.preset_shape(lib, "蓝光", "nope"))
assert(Styles.preset_edge(lib, "蓝光", "color", true, { 0.1, 0.2, 1 }) and lib.items["蓝光"].edge.color.on)
assert(not Styles.preset_edge(lib, "没有", "color", true))
assert(Styles.preset_rename(lib, "复制", "金光") and lib.items["金光"] and not lib.items["复制"] and lib.order[3] == "金光")
assert(Styles.preset_default(lib, "金光") and lib.default == "金光")
assert(Styles.preset_rename(lib, "金光", "金") and lib.default == "金", "rename follows the default")
assert(Styles.preset_delete(lib, "金") and lib.default == Styles.DEFAULT_PRESET, "deleting the default falls back to the first")
assert(Styles.preset_default(lib, "random") and not Styles.preset_default(lib, "没有"))
local view = Styles.presets_view(lib)
assert(view.default == "random" and #view.list == 2 and view.list[2].name == "蓝光" and #view.list[2].edge == #Styles.EDGE and #view.shapes == #Styles.LIST)

-- ---------------------------------------------------------------- 按过渡用预设
local presets = Styles.clean_presets({ order = { "原样", "六边形", "只改光边", "随机形状" }, items = {
    ["原样"] = { shape = "original" },
    ["六边形"] = { shape = "hex" },
    ["只改光边"] = { shape = "original", edge = { width = { on = true, value = 0.5 }, border = { on = true, value = 1 },
        cell_size = { on = true, value = 2 } } },
    ["随机形状"] = { shape = "random" },
}, default = "原样" }, nil)
local loaded = {}
local styles = Styles.new({
    load_texture = function(path) loaded[#loaded + 1] = path; return tex(path) end,
    presets = function() return presets end,
    random = function(n) return n end,
    vec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
})
Dissolve.register_effect_provider(styles.provider)
local function tick(n) for _ = 1, n do now = now + 0.1; Dissolve.update() end end
local function run(preset, mesh, want, cur)
    Dissolve.use({ enabled = true, dur = 0.5, forward = true, preset = preset })
    Dissolve.set_material(mesh, 0, want, cur)
    Dissolve.use(nil)
end

styles.preload(); styles.preload()
assert(#loaded == 3 and styles.loaded_count() == 3, "preload each style noise once")

local a = fake("a", true)
run(nil, a, false, true)
assert(a.sets == 0 and a.values[2].x == 0.25, "default original preset does not take over")
tick(10)

run("六边形", a, true, false)
assert(a.tex[2].path == "ArmorVariantManager/Dissolve/Dissolve_Hex_NoiseMap.tex", "hinted preset swaps the noise")
assert(a.tex[1].path == "orig/a_Dissolve_Map.tex" and a.tex[0].path == "orig/base.tex", "other slots untouched")
tick(2)
run("六边形", a, false, true)
assert(a.tex[2].path:find("Hex"), "still hex during reversal")
tick(10)
assert(a.tex[2].path == "orig/Burn_NoiseMap.tex", "restored to the original path: " .. a.tex[2].path)
assert(loaded[#loaded] == "orig/Burn_NoiseMap.tex", "restore loads the original by path")

local b = fake("b", true)
run("已删除", b, false, true)
assert(b.sets == 0, "missing preset falls back to the default")
tick(10)

local c = fake("c", true)
run("只改光边", c, false, true)
assert(c.sets == 0, "original shape keeps the noise map")
assert(c.values[2].x == 0.5 and c.values[2].y == 0.6 and c.values[2].z == 4 and c.values[2].w == 1, "only overridden edge components written")
assert(c.values[3].z == 0.5 and c.values[3].w == 1, "cell size 2 -> tiling 0.5")
tick(10)
assert(c.values[2].x == 0.25 and c.values[2].w == 0 and c.values[3].z == 1.5, "edge restored after the round")

local r = fake("r", true)
run("随机形状", r, false, true)
assert(r.tex[2].path:find("Rect"), "random shape draws from the styles: " .. r.tex[2].path)
tick(10)

presets.default = "random"
local d = fake("d", true)
run(nil, d, false, true)
assert(d.tex[2].path:find("Rect"), "random default draws among presets")
tick(10)
presets.default = "原样"

local plain = fake("plain", false)
run("六边形", plain, false, true)
assert(plain.sets == 0, "materials without a noise slot are left alone")
tick(10)

local e = fake("e", true)
run("六边形", e, false, true)
assert(e.tex[2].path:find("Hex"))
Dissolve.reset_mesh(e)
assert(e.tex[2].path == "orig/Burn_NoiseMap.tex", "preview reset restores immediately")

local f = fake("f", true)
run("只改光边", f, false, true)
styles.on_param_write(f, 0, "Dissolve_Edge", { 0.3, 0.7, 4, 0 })
assert(f.values[2].x == 0.5 and f.values[2].y == 0.7 and f.values[2].w == 1, "palette write updates the base, overrides re-applied")
tick(10)
assert(f.values[2].x == 0.3 and f.values[2].y == 0.7 and f.values[2].w == 0, "restore to the palette-updated value")

presets.default = "六边形"
local h = fake("h", true)
for i = 1, 5 do Dissolve.drive_material(h, 0, true, 0.15 * i, true) end
assert(h.tex[2].path:find("Hex") and h.sets == 1, "HP drive swaps once with the default preset")
Dissolve.drive_material(h, 0, true, 1, true)
tick(1)
assert(h.tex[2].path == "orig/Burn_NoiseMap.tex", "HP drive end restores")
presets.default = "原样"

-- ---------------------------------------------------------------- 光边覆盖的规范化 / 校验
local edge = Styles.clean_edge({ width = { on = true, value = 5 }, color = { on = true, value = { 2, 0.5, "x" } }, tiling = { on = true, value = 3 } })
assert(edge.width.on and edge.width.value == 1, "width clamped")
assert(edge.color.value[1] == 1 and edge.color.value[2] == 0.38, "invalid colour falls back to the default")
assert(edge.tiling == nil, "old tiling key ignored")
assert(not Styles.set_edge(edge, "nope", true) and not Styles.set_edge(edge, "width", "yes") and not Styles.set_edge(edge, "color", nil, { 1, 2 }))
Styles.set_edge(edge, "cell_size", nil, 0)
assert(edge.cell_size.value == 0.1, "cell size clamped above zero")

-- ---------------------------------------------------------------- 角色配置里的引用(OpsV3 / ModelV3 / Ops)
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local cfg = M3.normalize({ base = { presets = { ["日常"] = {}, ["战斗"] = {} }, order = { "日常", "战斗" },
    dissolves = { ["日常"] = "六边形", ["不存在的预设"] = "x", ["战斗"] = 3 } },
    groups = { { name = "外套", options = { ["穿"] = {}, ["脱"] = {} }, order = { "穿", "脱" }, dissolves = { ["脱"] = "金光" } } },
    conditions = { states = { { name = "低血量", conditions = {}, targets = {}, dissolve = "蓝光" }, { name = "空", conditions = {}, targets = {}, dissolve = "" } } } })
assert(cfg.base.dissolves["日常"] == "六边形" and cfg.base.dissolves["不存在的预设"] == nil and cfg.base.dissolves["战斗"] == nil, "base refs cleaned")
assert(cfg.groups[1].dissolves["脱"] == "金光" and cfg.conditions.states[1].dissolve == "蓝光" and cfg.conditions.states[2].dissolve == nil)
assert(OpsV3.set_dissolve_ref(cfg, "base", "战斗", "蓝光") and cfg.base.dissolves["战斗"] == "蓝光")
assert(not OpsV3.set_dissolve_ref(cfg, "base", "没有", "蓝光") and not OpsV3.set_dissolve_ref(cfg, "没有的组", "穿", "x"))
assert(OpsV3.set_dissolve_ref(cfg, "外套", "脱", "") and cfg.groups[1].dissolves == nil, "clearing the last ref drops the table")
assert(OpsV3.set_state_dissolve(cfg, 2, "金光") and cfg.conditions.states[2].dissolve == "金光" and not OpsV3.set_state_dissolve(cfg, 9, "x"))
assert(OpsV3.rename_dissolve_refs(cfg, "蓝光", "冰蓝") and cfg.base.dissolves["战斗"] == "冰蓝" and cfg.conditions.states[1].dissolve == "冰蓝")
assert(not OpsV3.rename_dissolve_refs(cfg, "没有", "x"), "nothing to rename")
-- 预设改名 / 删除时引用跟着走
assert(Ops.rename_preset(cfg.base, "日常", "平时"))
assert(cfg.base.dissolves["平时"] == "六边形" and cfg.base.dissolves["日常"] == nil, "preset rename carries the dissolve ref")

print("PASS: RE4 built-in dissolve styles (preset library: migrate / clean / new / duplicate / rename / delete / default / random; per-transition preset, missing -> default, noise swap/restore by path, reversal, edge-only presets, cell size inverted, random shape, plain materials, preview reset, palette write, HP drive)")
