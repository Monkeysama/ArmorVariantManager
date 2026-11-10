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

-- 旧的常驻调色迁移成「常驻」方案,外观不变
do
    local old = {body = {Skin = {Base = col(1, 1, 1), Rough = 0.5}}}
    local cfg = M3.normalize({version = 3, palette = old})
    assert(cfg.palette == nil and cfg.palette_active == "常驻" and cfg.palette_order[1] == "常驻")
    S.equal(cfg.palettes["常驻"], old)
    -- 已经选了别的方案:常驻的值补进选中的方案(它原来就叠在常驻上),选中的值优先
    cfg = M3.normalize({version = 3, palette = old, palette_active = "A", palettes = {A = {body = {Skin = {Base = {x = 0}}}}}})
    assert(cfg.palette == nil and cfg.palette_active == "A" and cfg.palettes["常驻"] == nil)
    S.equal(cfg.palettes.A.body.Skin, {Base = {x = 0, y = 1, z = 1}, Rough = 0.5})
    -- 同名方案已存在:换个名字
    cfg = M3.normalize({version = 3, palette = old, palettes = {["常驻"] = {}}})
    assert(cfg.palette_active == "常驻 2")
    -- 选着初始时调色:自动新建并选中
    cfg = M3.normalize({version = 3})
    assert(OpsV3.ensure_palette(cfg, "方案") == "方案 1" and cfg.palette_active == "方案 1")
    assert(OpsV3.ensure_palette(cfg, "方案") == "方案 1", "already selected")
    assert(OpsV3.set_palette_active(cfg, ""))
    assert(OpsV3.ensure_palette(cfg, "方案") == "方案 2")
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
    S.equal(merged.body.Skin, {Base = {x = 0.1, y = 0.2}, Rough = 0.9}, "nothing under the schemes but the original")
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

-- 随血量变色:血量状态带来的方案按血量进度加权(进度 0 也列出,权重 0,好让平滑退场)
do
    local cfg = config({
        state("Yellow", nil, {palette = "Pale", hp = {upper = 100, lower = 50}}),
        state("Red", nil, {palette = "Dark", hp = {upper = 50, lower = 0}}),
    })
    local function sources(hp)
        local names, src, w = M3.palette_sources(cfg, M3.resolve(cfg, {hp = hp}))
        return names, src, w
    end
    local names, src, w = sources(100)
    S.equal(names, {"Warm", "Pale", "Dark"}, "both HP schemes listed; the deeper range (red) on top whatever the state order")
    assert(src[2] == 1 and src[3] == 2, "sources follow the reorder")
    assert(w[1] == nil and w[2] == 0 and w[3] == 0, "full HP: both weights 0")
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {hp = 100})), {"Warm"}, "weight 0 is not shown as active")
    names, src, w = sources(75)
    assert(math.abs(w[2] - 0.5) < 1e-9 and w[3] == 0, "75%: yellow halfway, red not yet")
    names, src, w = sources(25)
    assert(w[2] == 1 and math.abs(w[3] - 0.5) < 1e-9, "25%: yellow full, red halfway on top")
    S.equal(M3.palette_layers(cfg, M3.resolve(cfg, {hp = 25})), {"Warm", "Pale", "Dark"})
    -- 状态顺序反过来,叠加顺序不变
    cfg = config({
        state("Red", nil, {palette = "Dark", hp = {upper = 50, lower = 0}}),
        state("Yellow", nil, {palette = "Pale", hp = {upper = 100, lower = 50}}),
    })
    S.equal((sources(25)), {"Warm", "Pale", "Dark"}, "independent of state order")
end

-- Palette.blend:权重 1 = merge;0~1 从下面已叠好的值(没有就是原值)插值;枚举过半切换;0 跳过
do
    local orig = {
        ["body|Skin|Base"] = {0.0, 0.0, 0.0, 1.0}, ["body|Skin|Rough"] = 0.2, ["body|Skin|Mode"] = 0,
    }
    local function original(slot, mat, param) return orig[slot .. "|" .. mat .. "|" .. param] end
    local green = {body = {Skin = {Base = col(0, 1, 0)}}}
    local yellow = {body = {Skin = {Base = col(1, 1, 0), Rough = 0.6, Mode = 2}}}
    local red = {body = {Skin = {Base = col(1, 0, 0)}}}
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    S.equal(Palette.blend({green, yellow}, {1, 1}, original), Palette.merge({green, yellow}), "weight 1 = merge")
    local out = Palette.blend({green, yellow}, {1, 0.5}, original, {Mode = true})
    local b = out.body.Skin
    assert(near(b.Base.x, 0.5) and near(b.Base.y, 1) and near(b.Base.z, 0), "colour: halfway from green to yellow")
    assert(near(b.Rough, 0.4), "untouched below: from the original 0.2 to 0.6")
    assert(b.Mode == 2, "enum switches at half")
    out = Palette.blend({green, yellow}, {1, 0.4}, original, {Mode = true})
    assert(out.body.Skin.Mode == 0, "enum below half keeps the original")
    out = Palette.blend({green, yellow, red}, {1, 1, 0.25}, original)
    assert(near(out.body.Skin.Base.x, 1) and near(out.body.Skin.Base.y, 0.75), "red a quarter over yellow")
    out = Palette.blend({green, red}, {1, 0}, original)
    S.equal(out, Palette.merge({green}), "weight 0 skipped")
    out = Palette.blend({{body = {Hair = {Tint = 0.8}}}}, {0.3}, function() return nil end)
    assert(out.body == nil, "no original and under half: nothing written")
    out = Palette.blend({{body = {Hair = {Tint = 0.8}}}}, {0.6}, function() return nil end)
    assert(out.body.Hair.Tint == 0.8, "no original and over half: take the value")
end

-- ============================================================ OpsV3
do
    local cfg = config({state("A", "x", {palette = "Pale"})})
    assert(not OpsV3.new_palette(cfg, "Pale"), "duplicate name")
    assert(not OpsV3.new_palette(cfg, "", nil), "empty name")
    assert(not OpsV3.new_palette(cfg, "X", "Nope"), "copy from missing")
    local ok, _, name = OpsV3.new_palette(cfg, "Copy", "Dark")
    assert(ok and name == "Copy" and cfg.palette_active == "Copy", "new scheme is selected")
    S.equal(cfg.palettes.Copy, cfg.palettes.Dark, "copied")
    cfg.palettes.Copy.body.Skin.Rough = 0.1
    assert(cfg.palettes.Dark.body.Skin.Rough == 0.9, "deep copy")
    assert(OpsV3.new_palette(cfg, "Blank") and next(cfg.palettes.Blank) == nil, "blank = empty = original")
    assert(not OpsV3.new_palette(cfg, "X", ""), "no always-on layer to copy any more")
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
    -- 脚本重载后:网格上还留着改过的值(0.9),新的状态表不知道原值;给了文件原值就还原到文件的值
    local fresh = {}
    local file = function(_, _, material, param) return material == "Skin" and param == "Rough" and 0.25 or nil end
    Palette.apply_mesh(mesh, {Skin = {Rough = 0.7}}, fresh, nil, file)
    assert(vals[0] == 0.7)
    Palette.apply_mesh(mesh, nil, fresh, nil, file)
    assert(vals[0] == 0.25, "restored to the mdf2 value, not to what the mesh held")
    -- 文件读不到:退回网格上读到的值
    local fallback = {}
    Palette.apply_mesh(mesh, {Skin = {Base = {y = 0}}}, fallback, nil, file)
    Palette.apply_mesh(mesh, nil, fallback, nil, file)
    assert(vals[1].y == 0.5)
end

-- mdf2 文件里的原值:用一份最小的 mdf2(一个材质、一个 float 和一个 float4)走一遍解析
do
    local Mdf2 = require("ArmorVariantManager_Core.Games.RE4.Mdf2")
    local function u16(s) local t = {} for _, c in utf8.codes(s) do t[#t + 1] = string.pack("<I2", c) end return table.concat(t) .. "\0\0" end
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

-- ============================================================ 状态组选项引用的方案只作用于这个选项设为开 / 关的材质
do
    local cfg = config({ state("Hurt", "hurt", {targets = {{group = "Face", option = "Hurt"}}}) })
    local r = M3.resolve(cfg, {hurt = true})
    local names, _, _, masks = M3.palette_sources(cfg, r)
    S.equal(names, {"Warm", "Pale"})
    assert(masks[1] == nil, "base preset refs are not masked")
    S.equal(masks[2], {}, "an option that writes no material masks everything out")
    local merged = M3.palette_of(cfg, names, masks)
    assert(merged.head == nil or merged.head.Face == nil, "Pale does not reach materials the option leaves at -")
    S.equal(merged.body.Skin, {Base = {x = 0.9}}, "only Warm (from the base preset) reaches Skin")

    -- 选项把 head/Face 设为开:Pale 只改 Face,不改 body/Skin
    M3.find_group(cfg, "Face").options.Hurt = {head = {materials = {Face = true, Other = false}}}
    names, _, _, masks = M3.palette_sources(cfg, M3.resolve(cfg, {hurt = true}))
    S.equal(masks[2], {head = {Face = true, Other = true}}, "on and off both count; - does not")
    merged = M3.palette_of(cfg, names, masks)
    S.equal(merged.head.Face, {Base = col(0.3, 0.3, 0.3)}, "Pale reaches the option's materials")
    S.equal(merged.body.Skin, {Base = {x = 0.9}}, "but not body/Skin")
    -- 血量加权叠加同样按范围过滤
    local blended = M3.palette_blend_of(cfg, names, {1, 1}, function() return nil end, {}, masks)
    assert(blended.head.Face and blended.body.Skin.Base.y == nil, "blend is masked the same way")
end

print("PASS: palette schemes: normalize, merge, layers from base / groups / states (priority, exclusive, broken, HP), selected scheme, OpsV3 edits and preset ref bookkeeping, option refs limited to the option's materials")
