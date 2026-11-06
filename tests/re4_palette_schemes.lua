-- RE4 调色方案(子预设):规范化、引用、解算时哪些方案生效与叠加顺序、合并、OpsV3 的增删改。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local Condition_HP = require("ArmorVariantManager_Core.Games.RE4.Conditions.Condition_HP")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local Palette = require("ArmorVariantManager_Core.Games.RE4.Palette")

Registry.eval_condition = function(c, ctx) return ctx[c.type] == true end
Condition_HP.get = function(ctx) return ctx.hp end
M3.clock = function() return 0 end

local function snap(slot, mats) return {[slot] = {materials = mats}} end
local function col(r, g, b) return {x = r, y = g, z = b} end
local function state(name, flag, extra)
    local st = {name = name, logic = "AND", conditions = flag and {{type = flag}} or {}, targets = {}}
    for k, v in pairs(extra or {}) do st[k] = v end
    return st
end

local function config(states)
    return M3.normalize({
        version = 3,
        base = {presets = {Full = snap("body", {a = true}), Shirt = snap("body", {a = false})},
            order = {"Full", "Shirt"}, active = "Full", palettes = {Full = "Warm", Ghost = "Warm"}},
        groups = {{name = "Face", scope = {"head/f"}, options = {Clean = {}, Hurt = {}}, active = "Clean",
            palettes = {Hurt = "Pale", Clean = ""}}},
        palette = {body = {Skin = {Base = col(1, 1, 1), Rough = 0.5}}},
        palettes = {
            Warm = {body = {Skin = {Base = {x = 0.9}}}},
            Pale = {body = {Skin = {Base = {y = 0.2}}}, head = {Face = {Base = col(0.3, 0.3, 0.3)}}},
            Dark = {body = {Skin = {Base = {x = 0.1}, Rough = 0.9}}},
            [""] = {}, [" pad"] = {},
        },
        palette_order = {"Pale", "Missing"},
        conditions = {states = states or {}},
    })
end

-- ============================================================ 规范化
do
    local cfg = config({state("s", "x", {palette = ""})})
    S.equal(cfg.palette_order, {"Pale", "Dark", "Warm"}, "order kept, missing dropped, rest appended by name")
    assert(cfg.palettes[""] == nil and cfg.palettes[" pad"] == nil, "invalid scheme names dropped")
    S.equal(cfg.base.palettes, {Full = "Warm"}, "refs to missing presets dropped")
    S.equal(cfg.groups[1].palettes, {Hurt = "Pale"}, "empty refs dropped")
    assert(M3.normalize({version = 3, palette_active = "Nope", palettes = {A = {}}}).palette_active == nil, "missing selection dropped")
    assert(M3.normalize({version = 3, palette_active = "A", palettes = {A = {}}}).palette_active == "A")
    assert(cfg.conditions.states[1].palette == nil, "empty state palette dropped")
    local plain = M3.normalize({version = 3})
    assert(plain.palettes == nil and plain.palette_order == nil and plain.base.palettes == nil)
end

-- ============================================================ 合并
do
    local out = Palette.merge({{body = {S = {C = col(1, 1, 1), F = 1}}}, {body = {S = {C = {y = 0}, F = 2}}}, nil})
    S.equal(out, {body = {S = {C = col(1, 0, 1), F = 2}}}, "later layers override per component")
    local a = {body = {S = {C = {x = 1}}}}
    Palette.merge({a, {body = {S = {C = {x = 2}}}}})
    assert(a.body.S.C.x == 1, "inputs untouched")
end

-- ============================================================ 解算:哪些方案生效
do
    local cfg = config({
        state("Dark", "night", {palette = "Dark"}),
        state("Hurt", "hurt", {targets = {{group = "Face", option = "Hurt"}}}),
        state("Broken", "night", {palette = "Nope"}),
    })
    local r = M3.resolve(cfg, {})
    S.equal(M3.palette_layers(cfg, r), {"Warm"}, "base pick's scheme; Clean has none")
    cfg.palette_active = "Dark"
    S.equal(M3.palette_layers(cfg, r), {"Dark", "Warm"}, "the selected scheme is in effect, under referenced ones")
    cfg.palette_active = nil

    r = M3.resolve(cfg, {hurt = true})
    S.equal(M3.palette_layers(cfg, r), {"Warm", "Pale"}, "group option picked by a state brings its scheme")

    r = M3.resolve(cfg, {hurt = true, night = true})
    assert(r.status[1].kind == "active", "palette-only state counts as active")
    assert(r.targets[1].palette.kind == "win" and r.targets[3].palette.kind == "broken")
    S.equal(M3.palette_layers(cfg, r), {"Warm", "Pale", "Dark"}, "states above groups; broken skipped")
    local merged = M3.palette_of(cfg, M3.palette_layers(cfg, r))
    S.equal(merged.body.Skin, {Base = {x = 0.1, y = 0.2, z = 1}, Rough = 0.9}, "always-on layer at the bottom")
    S.equal(merged.head.Face, {Base = col(0.3, 0.3, 0.3)})

    -- 两个状态都带方案:高优先级的盖在上面
    cfg = config({state("A", "x", {palette = "Dark"}), state("B", "x", {palette = "Pale"})})
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {x = true})), {"Warm", "Pale", "Dark"})

    -- 独占状态挡住后面的方案
    cfg = config({state("A", "x", {exclusive = true}), state("B", "x", {palette = "Dark"})})
    r = M3.resolve(cfg, {x = true})
    assert(r.targets[2].palette.kind == "lose")
    S.equal(M3.palette_layers(cfg, r), {"Warm"})

    -- 关掉 / 暂停自动的状态不生效
    cfg = config({state("A", "x", {palette = "Dark", enabled = false})})
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {x = true})), {"Warm"})
end

-- 血量状态:血量进入区间时生效
do
    local cfg = config({state("Low", nil, {palette = "Dark", hp = {upper = 50, lower = 20}})})
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {hp = 80})), {"Warm"})
    local r = M3.resolve(cfg, {hp = 40})
    S.equal(M3.palette_layers(cfg, r), {"Warm", "Dark"})
    assert(r.status[1].kind == "active", "palette-only HP state shows active")
    cfg = config({state("High", nil, {palette = "Dark", hp = {upper = 50, lower = 20, invert = true}})})
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {hp = 10})), {"Warm"}, "inverted: low HP = off")
end

-- ============================================================ OpsV3
do
    local cfg = config({state("A", "x", {palette = "Pale"})})
    assert(not OpsV3.new_palette(cfg, "Pale"), "duplicate name")
    assert(not OpsV3.new_palette(cfg, "", nil), "empty name")
    assert(not OpsV3.new_palette(cfg, "X", "Nope"), "copy from missing")
    local ok, _, name = OpsV3.new_palette(cfg, "Copy", "")
    assert(ok and name == "Copy" and cfg.palette_active == "Copy", "new scheme is selected")
    S.equal(cfg.palettes.Copy, cfg.palette, "copied from always-on")
    cfg.palettes.Copy.body.Skin.Rough = 0.1
    assert(cfg.palette.body.Skin.Rough == 0.5, "deep copy")
    assert(OpsV3.new_palette(cfg, "Copy2", "Pale"))
    S.equal(cfg.palettes.Copy2, cfg.palettes.Pale)
    assert(cfg.palette_order[#cfg.palette_order] == "Copy2")

    assert(OpsV3.set_palette_active(cfg, "Pale") and cfg.palette_active == "Pale")
    assert(not OpsV3.set_palette_active(cfg, "Pale"), "no change")
    assert(not OpsV3.set_palette_active(cfg, "Nope"), "missing scheme")
    assert(OpsV3.rename_palette(cfg, "Pale", "Sick"))
    assert(cfg.palette_active == "Sick", "selection follows the rename")
    assert(OpsV3.set_palette_active(cfg, "") and cfg.palette_active == nil)
    assert(cfg.groups[1].palettes.Hurt == "Sick" and cfg.conditions.states[1].palette == "Sick")
    assert(cfg.palettes.Pale == nil and cfg.palettes.Sick)
    assert(not OpsV3.rename_palette(cfg, "Sick", "Warm"), "rename onto existing")

    assert(OpsV3.delete_palette(cfg, "Warm"))
    assert(cfg.base.palettes.Full == "Warm", "refs kept as broken")
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {})), {}, "broken ref skipped")

    assert(OpsV3.set_palette_ref(cfg, "base", "Shirt", "Dark"))
    assert(cfg.base.palettes.Shirt == "Dark")
    assert(not OpsV3.set_palette_ref(cfg, "base", "Shirt", "Nope"), "missing scheme refused")
    assert(not OpsV3.set_palette_ref(cfg, "base", "Nope", "Dark"), "missing preset refused")
    assert(OpsV3.set_palette_ref(cfg, "Face", "Hurt", ""))
    assert(cfg.groups[1].palettes == nil, "last ref removed -> nil")
    assert(not OpsV3.set_palette_ref(cfg, "Face", "Hurt", ""), "no change")
    assert(OpsV3.set_state_palette(cfg, 1, "Dark") and cfg.conditions.states[1].palette == "Dark")
    assert(OpsV3.set_state_palette(cfg, 1, "") and cfg.conditions.states[1].palette == nil)

    assert(OpsV3.set_palette_active(cfg, "Dark"))

    -- 预设的复制 / 改名 / 删除带着引用走
    assert(OpsV3.set_palette_ref(cfg, "base", "Full", "Dark"))
    local _, _, dup = Ops.duplicate_preset(cfg.base, "Full")
    assert(cfg.base.palettes[dup] == "Dark")
    assert(OpsV3.rename_base(cfg, "Full", "Main") and cfg.base.palettes.Main == "Dark" and cfg.base.palettes.Full == nil)
    assert(OpsV3.delete_base(cfg, "Main") and cfg.base.palettes.Main == nil)
    assert(OpsV3.set_palette_ref(cfg, "Face", "Clean", "Dark"))
    assert(OpsV3.rename_option(cfg, "Face", "Clean", "Neat") and cfg.groups[1].palettes.Neat == "Dark")

    assert(OpsV3.delete_palette(cfg, "Dark") and cfg.palette_active == nil, "deleting the selected scheme clears the selection")
    -- 删光所有方案:字段清掉
    for _, n in ipairs({table.unpack(cfg.palette_order)}) do assert(OpsV3.delete_palette(cfg, n)) end
    assert(cfg.palettes == nil and cfg.palette_order == nil)
end

-- 护甲同步身体外观:护甲照抄身体的调色,护甲自己的值不丢
do
    local pal = {body = {Skin = {Base = col(1, 0, 0)}}, armor = {Plate = {Base = col(0, 1, 0)}}, head = {Face = {R = 1}}}
    local m = M3.mirror_palette(pal, true)
    assert(m.armor == pal.body and m.head == pal.head, "armor = body")
    assert(pal.armor.Plate, "input untouched")
    assert(M3.mirror_palette(pal, false) == pal, "off = as is")
    assert(M3.mirror_palette(nil, true) == nil)
    assert(M3.mirror_palette({armor = {Plate = {}}}, true).armor == nil, "no body colours = armor back to original")
end

-- 原值:写过的取记下的原值,没写过的读当前值
do
    _G.Vector4f = {new = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end}
    local vals = {[0] = 0.5, [1] = {x = 1, y = 0.5, z = 0.25, w = 1}}
    local mesh = {call = function(_, m, j, k, v)
        if m == "getMaterialVariableNum" then return 2
        elseif m == "getMaterialVariableName" then return k == 0 and "Rough" or "Base"
        elseif m == "getMaterialVariableType" then return k == 0 and Palette.TYPE_FLOAT or Palette.TYPE_FLOAT4
        elseif m == "getMaterialFloat" or m == "getMaterialFloat4" then return vals[k]
        elseif m == "setMaterialFloat" or m == "setMaterialFloat4" then vals[k] = v
        elseif m == "get_MaterialNum" then return 1
        elseif m == "getMaterialName" then return "Skin" end
    end}
    S.equal(Palette.original({}, mesh, 0, "Base"), {1, 0.5, 0.25, 1}, "never written = current value")
    assert(Palette.original(nil, mesh, 0, "Rough") == 0.5)
    assert(Palette.original({}, mesh, 0, "Nope") == nil)
    local state = {}
    Palette.apply_mesh(mesh, {Skin = {Base = {x = 0}, Rough = 0.9}}, state)
    assert(vals[0] == 0.9 and vals[1].x == 0, "written")
    S.equal(Palette.original(state, mesh, 0, "Base"), {1, 0.5, 0.25, 1}, "written = recorded original")
    assert(Palette.original(state, mesh, 0, "Rough") == 0.5)
end

-- mdf2 文件里的原值:用一份最小的 mdf2(一个材质、一个 float 和一个 float4)走一遍解析
do
    local Mdf2 = require("ArmorVariantManager_Core.Games.RE4.Mdf2")
    local function u16(s) local t = {} for _, c in utf8.codes(s) do t[#t + 1] = string.pack("<I2", c) end return table.concat(t) .. "  " end
    -- 布局:头 16 + 材质条目 100 + 参数头 2×24,之后是字符串和参数数据
    local strings_at = 16 + 100 + 48
    local mat_name, p1, p2 = u16("Skin"), u16("Rough"), u16("Base")
    local mat_off, p1_off, p2_off = strings_at, strings_at + #mat_name, strings_at + #mat_name + #p1
    local data_off = p2_off + #p2
    local entry = string.pack("<I8I4i4i4i4i4i4i4i4i4i4i4I8I8I8I8I8I8", mat_off, 0, 20, 2, 0, 0, 0, 0, 0, 0, 0, 0,
        16 + 100, 0, 0, data_off, 0, 0)
    local heads = string.pack("<I8I4I4i4I2I2", p1_off, 0, 0, 0, 1, 0) .. string.pack("<I8I4I4i4I2I2", p2_off, 0, 0, 4, 4, 0)
    local file = string.pack("<I4I2I2I8", Mdf2.MAGIC, 1, 1, 0) .. entry .. heads .. mat_name .. p1 .. p2
        .. string.pack("<fffff", 0.5, 1, 0.5, 0.25, 1)
    local reads = 0
    _G.avm_portrait = {read_game_file = function(rel) reads = reads + 1; return rel == "natives/STM/ch/skin.mdf2.32" and file or nil end}
    local holder = {call = function(_, m) if m == "get_ResourcePath" then return "ch/skin.mdf2" end end}
    local mesh = {call = function(_, m) if m == "get_Material" then return holder end end}
    local cache = {}
    assert(Mdf2.file_value(mesh, "Skin", "Rough", cache) == 0.5)
    S.equal(Mdf2.file_value(mesh, "Skin", "Base", cache), {1, 0.5, 0.25, 1})
    assert(reads == 1, "parsed once per cache")
    local v, why = Mdf2.file_value(mesh, "Skin", "Nope", cache)
    assert(v == nil and why == "parameter not in file")
    assert(Mdf2.file_value(mesh, "Other", "Rough", cache) == nil)
    _G.avm_portrait = nil
    assert(Mdf2.file_value(mesh, "Skin", "Rough") == nil, "no native plugin = nil (falls back)")
end

-- set_in / reset_in 作用在任意一份覆盖表上
do
    local pal = {}
    assert(Palette.set_in(pal, {slot = "body", material = "S", param = "C", component = "x", value = 0.25}))
    assert(not Palette.set_in(pal, {slot = "body", material = "S", param = "C", component = "x", value = 0.25}), "same value")
    assert(Palette.reset_in(pal, "body", "S", "C", "x"))
    S.equal(pal, {}, "empty tables pruned")
    assert(not Palette.reset_in(nil, "body", "S"))
end

print("PASS: palette schemes: normalize, merge, layers from base / groups / states (priority, exclusive, broken, HP), selected scheme, OpsV3 edits and preset ref bookkeeping")
