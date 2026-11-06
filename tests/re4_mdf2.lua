-- RE4 mdf2 解析与 RE Mesh Editor 材质预设导出(Games/RE4/Mdf2.lua)。
-- 用一份合成的 mdf2(v32 布局:参数 Padding、贴图、MMTRS、GPBF、中文名)检查解析、预设字段、类型判定、
-- 预设名校验、资源路径换算,以及 export():读到 mdf2 时用文件 + 当前值,读不到时退回运行时数据并给出原因。
-- (另用用户的示例 RE4_Sample.mdf2.32 与 RE Mesh Editor 自带解析器逐字段比对过:727 行一致,后备 Padding 规则 589 个参数全对。)
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local Mdf2 = require("ArmorVariantManager_Core.Games.RE4.Mdf2")

-- ---------------------------------------------------------------- 合成 mdf2
local function utf16(s)
    local out = {}
    for _, c in utf8.codes(s) do out[#out + 1] = string.pack("<I2", c) end
    out[#out + 1] = "\0\0"
    return table.concat(out)
end

-- props = { { name, values, pad_after } }
local function build(mat)
    local strings, string_at = {}, {}
    local function str(s)
        if not string_at[s] then string_at[s] = true; strings[#strings + 1] = s end
    end
    str(mat.name); str(mat.mmtr)
    for _, p in ipairs(mat.props) do str(p[1]) end
    for _, t in ipairs(mat.textures) do str(t[1]); str(t[2]) end
    for _, g in ipairs(mat.gpbf) do str(g[1]); str(g[2]) end
    local prop_headers = 16 + 100
    local tex_headers = prop_headers + #mat.props * 24
    local gpbf_at = tex_headers + #mat.textures * 32
    local mmtrs_at = gpbf_at + #mat.gpbf * 32
    local mmtrs_lists_at = mmtrs_at + 64
    local lists = {}
    local cursor = mmtrs_lists_at
    for i = 1, 8 do
        local l = mat.mmtrs[i] or {}
        lists[i] = { at = cursor, l = l }
        cursor = cursor + 4 + #l * 4
    end
    local str_at = cursor
    local offsets = {}
    for _, s in ipairs(strings) do offsets[s] = cursor; cursor = cursor + #utf16(s) end
    local data_at = cursor
    -- 参数数据
    local blob, poffs = {}, {}
    local off = mat.front or 0
    if off > 0 then blob[#blob + 1] = string.rep("\0", off) end
    for i, p in ipairs(mat.props) do
        poffs[i] = off
        for _, v in ipairs(p[2]) do blob[#blob + 1] = string.pack("<f", v) end
        off = off + #p[2] * 4
        if (p[3] or 0) > 0 then blob[#blob + 1] = string.rep("\0", p[3]); off = off + p[3] end
    end
    local out = { string.pack("<I4I2I2I8", Mdf2.MAGIC, 1, 1, 0) }
    out[#out + 1] = string.pack("<I8I4i4i4i4i4i4i4i4i4i4i4I8I8I8I8I8I8", offsets[mat.name], 0, off, #mat.props, #mat.textures,
        #mat.gpbf, #mat.gpbf, mat.bake, mat.shader, mat.flags, mat.flags_b, mat.lod,
        prop_headers, tex_headers, gpbf_at, data_at, offsets[mat.mmtr], #mat.mmtrs > 0 and mmtrs_at or 0)
    for i, p in ipairs(mat.props) do out[#out + 1] = string.pack("<I8I4I4i4I2I2", offsets[p[1]], 0, 0, poffs[i], #p[2], 0) end
    for _, t in ipairs(mat.textures) do out[#out + 1] = string.pack("<I8I4I4I8I8", offsets[t[1]], 0, 0, offsets[t[2]], 0) end
    for _, g in ipairs(mat.gpbf) do
        out[#out + 1] = string.pack("<I8I4I4", offsets[g[1]], 1, 2)
        out[#out + 1] = string.pack("<I8I4I4", offsets[g[2]], g[3], g[4])
    end
    for i = 1, 8 do out[#out + 1] = string.pack("<I8", lists[i].at) end
    for i = 1, 8 do
        out[#out + 1] = string.pack("<I4", #lists[i].l)
        for _, v in ipairs(lists[i].l) do out[#out + 1] = string.pack("<I4", v) end
    end
    for _, s in ipairs(strings) do out[#out + 1] = utf16(s) end
    out[#out + 1] = table.concat(blob)
    local bytes = table.concat(out)
    assert(#table.concat(out, "", 1, #out - 1) == data_at, "layout")
    return bytes
end

local MAT = {
    name = "身体_Body", mmtr = "_Chainsaw/MasterMaterial/Dimcirui/RE4_lilToon.mmtr", bake = 0, shader = 0,
    flags = -2147221349, flags_b = 7, lod = 2, front = 0,
    props = {
        { "UseDetail", { 1 }, 0 }, { "Roughness", { 0.5 }, 8 },        -- 两个 float 后对齐到 16
        { "BaseColor", { 0.25, 0.5, 0.75, 1 }, 0 }, { "Wind_SpeedXYZ", { 0, 1, 0, 0 }, 0 },
        { "Fade_Rate_Color", { 1, 2, 3, 4 }, 0 }, { "isMask", { 0 }, 12 },
    },
    textures = { { "BaseDielectricMap", "_Chainsaw/Character/ch/Body_ALBD.tex" }, { "NormalRoughnessMap", "systems/rendering/NullNormalRoughness.tex" } },
    mmtrs = { { 1, 2, 3 }, {}, { 9 } },
    gpbf = { { "Buf", "Path/To/Buf", 123, 456 } },
}
local bytes = build(MAT)
local parsed = Mdf2.parse(bytes)
local m = assert(Mdf2.find(parsed, "身体_Body"), "UTF-16 material name")
assert(m.mmtr == MAT.mmtr and m.flags == MAT.flags and m.flags_b == 7 and m.shader_lod == 2 and m.prop_block_size == 80)
assert(#m.props == 6 and m.props[3].name == "BaseColor" and m.props[3].offset == 16 and m.props[3].count == 4)
assert(m.props[2].padding == 8 and m.props[6].padding == 12 and m.props[1].front_padding == 0, "padding from offsets and block size")
assert(math.abs(m.props[3].values[2] - 0.5) < 1e-6)
assert(m.textures[2].path == "systems/rendering/NullNormalRoughness.tex")
assert(#m.mmtrs == 8 and m.mmtrs[1][3] == 3 and #m.mmtrs[2] == 0 and m.mmtrs[3][1] == 9)
assert(m.gpbf[1].name == "Buf" and m.gpbf[1].path == "Path/To/Buf" and m.gpbf[1].utf16_hash == 123)
assert(not pcall(Mdf2.parse, "nope"), "rejects non-mdf2 data")
print("PASS: mdf2 v32 parsing (header, UTF-16 names, property offsets / padding / values, textures, MMTRS, GPBF)")

-- 预设:字段齐全,类型照 RE Mesh Editor 的判定,当前值优先
local preset = Mdf2.preset_from_mdf(m, function(name) if name == "BaseColor" then return { 1, 0, 0, 1 } end end)
assert(preset.presetType == "RE_MDF_MATERIAL" and preset.MDFVersion == "RE4" and preset.presetVersion == 5)
assert(preset["Material Header"]["Master Material Path"] == MAT.mmtr and preset["Material Header"]["Material Shader Type"] == "0")
assert(preset.Flags.FlagBitFlag == MAT.flags and preset.Flags.FlagBitFlagB == 7 and preset.Flags.Ver32Unknown == -1)
local types, by = {}, {}
for _, p in ipairs(preset["Property List"]) do types[#types + 1] = p["Data Type"]; by[p["Property Name"]] = p end
assert(table.concat(types, ",") == "BOOL,FLOAT,COLOR,VEC4,VEC4,BOOL", table.concat(types, ","))
assert(by.UseDetail.Value == 1.0 and by.isMask.Value == 0.0 and by.Roughness.Padding == 8)
assert(by.BaseColor.Value[1] == 1 and by.BaseColor.Value[2] == 0, "live values override the file")
assert(math.abs(by.Wind_SpeedXYZ.Value[2] - 1) < 1e-6, "file values otherwise")
assert(preset["MMTRS Data"][1] == "1,2,3" and preset["MMTRS Data"][2] == "" and preset["GPBF Data"][1] == "Buf,Path/To/Buf,123,456")
assert(preset["Texture Bindings"][1]["Texture Type"] == "BaseDielectricMap")
-- 没有 MMTRS / GPBF 时不写这两项(空表会变成 JSON null,插件读 null 会出错)
local plain = Mdf2.preset_from_mdf({ name = "A", mmtr = "", shader_type = 0, flags = 0, flags_b = 0, shader_lod = 0,
    bake_texture_array_size = 0, props = {}, textures = {}, mmtrs = {}, gpbf = {} })
assert(plain["MMTRS Data"] == nil and plain["GPBF Data"] == nil)
print("PASS: RE Mesh Editor preset from mdf2 (header, flags, data types, padding, current values, MMTRS / GPBF strings)")

-- 名字、路径
for _, ok in ipairs({ "Body", "My Preset_01", "a-b" }) do assert(Mdf2.valid_name(ok), ok) end
for _, bad in ipairs({ "", " lead", "trail ", "中文", "a/b", "a.b", string.rep("x", 65) }) do assert(not Mdf2.valid_name(bad), bad) end
assert(Mdf2.file_path("_Chainsaw/Character/ch/a.mdf2") == "natives/STM/_Chainsaw/Character/ch/a.mdf2.32")
assert(Mdf2.file_path("natives\\STM\\x\\b.mdf2.32") == "natives/STM/x/b.mdf2.32")
assert(Mdf2.file_path("x/b.mesh") == nil and Mdf2.file_path(nil) == nil)
print("PASS: preset names are English-only file names; resource paths map to natives/STM/<path>.32")

-- export():假的 mesh + 原生读取
local Palette = { TYPE_FLOAT = 1 }
local vars = { UseDetail = { k = 0, t = 1 }, Roughness = { k = 1, t = 1 }, BaseColor = { k = 2, t = 4 }, Wind_SpeedXYZ = { k = 3, t = 4 },
    Fade_Rate_Color = { k = 4, t = 4 }, isMask = { k = 5, t = 1 } }
local current = { UseDetail = 1, Roughness = 0.9, BaseColor = { 0, 1, 0, 1 }, Wind_SpeedXYZ = { 0, 1, 0, 0 }, Fade_Rate_Color = { 1, 2, 3, 4 }, isMask = 0 }
function Palette.read_vars() return vars end
function Palette.read_value(_, _, var) for n, v in pairs(vars) do if v == var then return current[n] end end end
function Palette.read_textures() return {} end
function Palette.find_master() return { id = "_chainsaw/mastermaterial/dimcirui/re4_liltoon.mmtr" } end
local function holder(path) return { call = function() return path end } end
local mesh = { call = function(_, name, _, t)
    if name == "get_Material" then return holder("_Chainsaw/Character/ch/a.mdf2") end
    if name == "getMaterialTextureNum" then return 2 end
    if name == "getMaterialTextureName" then return MAT.textures[t + 1][1] end
    if name == "getMaterialTexture" then return holder(MAT.textures[t + 1][2]:gsub("/", "\\")) end
    if name == "getMaterialVariableNum" then return 6 end
end }
local asked
_G.avm_portrait = { read_game_file = function(rel) asked = rel; return bytes end }
local p1, reason = Mdf2.export(mesh, 0, "身体_Body", Palette, {})
assert(reason == nil and asked == "natives/STM/_Chainsaw/Character/ch/a.mdf2.32", "reads the mod's mdf2")
assert(p1.Flags.FlagBitFlag == MAT.flags and p1["Property List"][2].Padding == 8, "header and padding from the file")
assert(math.abs(p1["Property List"][2].Value - 0.9) < 1e-6 and p1["Property List"][3].Value[2] == 1)
-- 读不到:原因写明,退回运行时数据(Padding 按对齐推算,母材质由材质库认)
_G.avm_portrait = { read_game_file = function() return nil, "not found" end }
local p2, why = Mdf2.export(mesh, 0, "身体_Body", Palette, {})
assert(why and why:find("not found", 1, true), tostring(why))
assert(p2["Material Header"]["Master Material Path"] == "_chainsaw/mastermaterial/dimcirui/re4_liltoon.mmtr" and p2.Flags.FlagBitFlag == 0)
local pads = {}
for i, p in ipairs(p2["Property List"]) do pads[i] = p.Padding end
assert(table.concat(pads, ",") == "0,8,0,0,0,12", "computed padding matches the file: " .. table.concat(pads, ","))
assert(p2["Texture Bindings"][1]["Texture Path"] == "_Chainsaw/Character/ch/Body_ALBD.tex", "runtime texture paths keep their case, slashes normalised")
_G.avm_portrait = nil
local _, old = Mdf2.export(mesh, 0, "身体_Body", Palette, nil)
assert(old and old:find("native plugin too old", 1, true))
_G.avm_portrait = { read_game_file = function() return bytes end }
local _, missing = Mdf2.export(mesh, 0, "Other", Palette, nil)
assert(missing and missing:find("not in file", 1, true))
_G.avm_portrait = nil
print("PASS: export reads the mod's mdf2 through the native plugin and falls back to runtime data with a reason (pak, old plugin, material missing)")

-- 原地写入调色覆盖值:只改参数字节,长度不变;float 存数字,float4 只写改过的分量
local patched, written = Mdf2.patch(bytes, { ["身体_Body"] = { BaseColor = { y = 0.125 }, Roughness = 0.25, Missing = 1 }, Other = { BaseColor = 1 } })
assert(written == 2 and #patched == #bytes, "two components written, size unchanged")
local pm = Mdf2.find(Mdf2.parse(patched), "身体_Body")
assert(pm.props[2].values[1] == 0.25 and pm.props[3].values[2] == 0.125 and pm.props[3].values[1] == 0.25, "only the overridden components change")
local diff = 0
for i = 1, #bytes do if bytes:byte(i) ~= patched:byte(i) then diff = diff + 1 end end
assert(diff <= 8, "nothing outside the two values changes: " .. diff)
assert(select(2, Mdf2.patch(bytes, nil)) == 0)
-- 重载副本的名字 / 资源路径
assert(Mdf2.reload_rel("natives/STM/a/b.mdf2.32", 7) == "natives/STM/a/b_avmr7.mdf2.32")
assert(Mdf2.original_rel("natives/STM/a/b_avmr123.mdf2.32") == "natives/STM/a/b.mdf2.32" and Mdf2.original_rel("natives/STM/a/b.mdf2.32") == "natives/STM/a/b.mdf2.32")
assert(Mdf2.resource_path("natives/STM/a/b_avmr7.mdf2.32") == "a/b_avmr7.mdf2")
print("PASS: palette overrides are written into mdf2 bytes in place; reload copy names round-trip")

-- 替换流程:写原文件 + 重载副本,等 10 帧换上同一个 mdf2 的所有网格,同帧清调色状态与配置,清理旧副本
local Replace = require("ArmorVariantManager_Core.Games.RE4.MdfReplace")
local files = { ["natives/STM/_Chainsaw/Character/ch/a.mdf2.32"] = bytes, ["natives/STM/_Chainsaw/Character/ch/a_avmr1.mdf2.32"] = "old copy" }
local removed_keep
_G.avm_portrait = {
    read_game_file = function(rel) if files[rel] then return files[rel] end return nil, "not found" end,
    game_file_exists = function(rel) return files[rel] ~= nil end,
    write_game_file = function(rel, data) if not files[rel] then return false, "not found" end files[rel] = data; return true end,
    write_reload_copy = function(rel, data) files[rel] = data; return true end,
    remove_reload_copies = function(_, keep) removed_keep = keep; files["natives/STM/_Chainsaw/Character/ch/a_avmr1.mdf2.32"] = nil; return 1 end,
}
local loaded
_G.sdk = { create_resource = function(_, path)
    loaded = path
    local res = {}
    function res:add_ref() return self end
    function res:create_holder() return { add_ref = function(h) return h end, path = path } end
    return res
end }
local function rmesh(path, num)
    local m = { path = path, num = num, set = 0 }
    m.call = function(self, name, arg)
        if name == "get_Material" then return { call = function() return self.path end } end
        if name == "set_Material" then self.set = self.set + 1; self.path = arg.path; return end
        if name == "get_MaterialNum" then return self.num end
    end
    return m
end
local body = rmesh("_Chainsaw/Character/ch/a.mdf2", 1)
local puppet = rmesh("_Chainsaw/Character/ch/a.mdf2", 1)       -- 过场傀儡也用同一个 mdf2
local other = rmesh("_Chainsaw/Character/ch/hair.mdf2", 1)
local forgotten, cleared, reapplied = {}, nil, 0
local opts = { mesh = body, overrides = { ["身体_Body"] = { Roughness = 0.25 } }, meshes = function() return { body, puppet, other } end,
    forget = function(m) forgotten[#forgotten + 1] = m end, clear = function(names) cleared = names end,
    reapply = function() reapplied = reapplied + 1 end }
assert(Replace.check(body) == "ok" and Replace.check(other) == "packed")
local info = Replace.start(opts)
assert(info.path == "natives/STM/_Chainsaw/Character/ch/a.mdf2.32" and info.values == 1)
assert(files[info.path] ~= bytes and Mdf2.find(Mdf2.parse(files[info.path]), "身体_Body").props[2].values[1] == 0.25, "original rewritten")
assert(loaded and loaded:match("^_Chainsaw/Character/ch/a_avmr%d+%.mdf2$"), "loads a fresh reload copy: " .. tostring(loaded))
assert(Replace.busy() and not pcall(Replace.start, opts), "one replacement at a time")
for _ = 1, 9 do Replace.tick() end
assert(body.set == 0, "waits for the resource to load before swapping")
-- 第一次换上时材质数还不对(没加载完):再等一轮
body.num, puppet.num = 0, 0
Replace.tick()
assert(body.set == 1 and Replace.busy() and cleared == nil, "not ready: retry later, nothing cleared yet")
body.num, puppet.num = 1, 1
for _ = 1, 10 do Replace.tick() end
assert(body.set == 2 and puppet.set == 2 and other.set == 0, "every mesh using this mdf2 is swapped, others untouched")
assert(#forgotten == 2 and cleared and cleared["身体_Body"] and reapplied == 1, "palette state and overrides cleared in the same frame")
assert(not Replace.busy() and removed_keep == "natives/STM/" .. loaded .. ".32", "old reload copies removed, the new one kept")
-- 下一次替换:网格现在用的是重载副本,仍然认出原文件
assert(Replace.check(body) == "ok")
-- 拒绝:没有调色改动 / 不是松散文件 / 原生插件太旧
local function err_of(o) local ok, e = pcall(Replace.start, o); assert(not ok); return tostring(e) end
opts.overrides = {}
assert(err_of(opts):find("nothing to write", 1, true))
opts.mesh = other; opts.overrides = { ["身体_Body"] = { Roughness = 1 } }
assert(err_of(opts):find("not replaceable", 1, true))
_G.avm_portrait = { read_game_file = function() end }
assert(Replace.check(body) == "plugin")
_G.avm_portrait, _G.sdk = nil, nil
print("PASS: replace mdf writes the original and a fresh reload copy, swaps every mesh on that mdf2 after it loads (retrying if not ready), clears palette state and overrides together, cleans old copies")
