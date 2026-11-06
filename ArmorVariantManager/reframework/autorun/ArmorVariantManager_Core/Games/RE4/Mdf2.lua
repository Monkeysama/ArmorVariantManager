-- RE4 的 mdf2(材质定义,v32)解析,和导出成 RE Mesh Editor 的 mdf2 材质预设(presetType RE_MDF_MATERIAL,
-- presetVersion 5;放进插件的 Presets/RE4/ 目录后可在 Blender 里套用)。
--
-- 文件结构照 RE Mesh Editor 的 modules/mdf/file_re_mdf.py(NSA Cloud):
--   头 16 字节:magic u32("MDF\0")、version u16、materialCount u16、flags u64
--   材质条目 100 字节(v32):nameOffset u64, nameHash u32, propBlockSize i32, propertyCount i32, textureCount i32,
--     gpbfNameCount i32, gpbfPathCount i32, bakeTextureArraySize i32, shaderType i32, flags i32, flagsB i32,
--     shaderLODNum i32, propHeadersOffset u64, texHeadersOffset u64, gpuBufferOffset u64, propDataOffset u64,
--     mmtrPathOffset u64, mmtrsDataOffset u64
--   参数头 24 字节:nameOffset u64, hash u32, hash u32, dataOffset i32, paramCount u16, unknFlag u16
--   贴图绑定 32 字节:typeOffset u64, hash u32, hash u32, pathOffset u64, 8 字节保留
--   GPBF:名字 / 路径条目交替,每条 16 字节(nameOffset u64, utf16Hash u32, utf8Hash u32)
--   MMTRS:8 个 u64 偏移,各指向 count u32 + count 个 u32
--   字符串都是 UTF-16LE、以 0 结尾
-- 预设字段与取值规则照 modules/mdf/re_mdf_presets.py 和 blender_re_mdf.py(数据类型判定、Padding、MMTRS / GPBF 字符串)。
--
-- 读文件:REFramework 的 Lua io 限制在 reframework/data 里,mod 的 mdf2 在 natives/STM/ 下,
-- 由原生插件的 avm_portrait.read_game_file 读(只放行 natives/ 下的 .mdf2.<版本>)。
local Mdf2 = {}

Mdf2.MAGIC = 4605005
Mdf2.VERSION = 32
Mdf2.PRESET_VERSION = 5

local function utf16(data, offset)
    if type(offset) ~= "number" or offset < 0 or offset + 2 > #data then return "" end
    local out = {}
    local i = offset + 1
    while i + 1 <= #data do
        local c = string.unpack("<I2", data, i)
        i = i + 2
        if c == 0 then break end
        if c >= 0xD800 and c <= 0xDBFF and i + 1 <= #data then
            local c2 = string.unpack("<I2", data, i)
            if c2 >= 0xDC00 and c2 <= 0xDFFF then
                i = i + 2
                c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00)
            end
        end
        out[#out + 1] = utf8.char(c)
    end
    return table.concat(out)
end

local function u(data, fmt, offset)
    local ok, a = pcall(string.unpack, fmt, data, offset + 1)
    if not ok then error("mdf2 truncated at " .. tostring(offset)) end
    return a
end

-- data:整个文件内容。返回 { version, materials = { [i] = 材质 } };不是 mdf2 / 版本不对时报错
function Mdf2.parse(data)
    if type(data) ~= "string" or #data < 16 then error("not an mdf2 file") end
    if u(data, "<I4", 0) ~= Mdf2.MAGIC then error("not an mdf2 file") end
    -- 头里的 version 字段固定是 1;mdf2 的格式版本看文件扩展名(RE4 是 .32,只支持它),插件也是这样认的
    local count = u(data, "<I2", 6)
    local out = { version = Mdf2.VERSION, materials = {} }
    for m = 0, count - 1 do
        local b = 16 + m * 100
        local mat = {
            name = utf16(data, u(data, "<I8", b)),
            prop_block_size = u(data, "<i4", b + 12),
            bake_texture_array_size = u(data, "<i4", b + 32),
            shader_type = u(data, "<i4", b + 36),
            flags = u(data, "<i4", b + 40),
            flags_b = u(data, "<i4", b + 44),
            shader_lod = u(data, "<i4", b + 48),
            props = {}, textures = {}, mmtrs = {}, gpbf = {},
        }
        local prop_count, tex_count = u(data, "<i4", b + 16), u(data, "<i4", b + 20)
        local gpbf_names = u(data, "<i4", b + 24)
        local prop_headers, tex_headers = u(data, "<I8", b + 52), u(data, "<I8", b + 60)
        local gpu_buffer, prop_data = u(data, "<I8", b + 68), u(data, "<I8", b + 76)
        mat.prop_data = prop_data
        mat.mmtr = utf16(data, u(data, "<I8", b + 84))
        local mmtrs_offset = u(data, "<I8", b + 92)
        for i = 0, prop_count - 1 do
            local h = prop_headers + i * 24
            local p = { name = utf16(data, u(data, "<I8", h)), offset = u(data, "<i4", h + 16), count = u(data, "<I2", h + 20), values = {} }
            for k = 0, p.count - 1 do p.values[k + 1] = u(data, "<f", prop_data + p.offset + k * 4) end
            mat.props[#mat.props + 1] = p
        end
        -- Padding:到下一个参数(最后一个到块尾)之间的空隙;FrontPadding 只有第一个参数有
        for i, p in ipairs(mat.props) do
            local next_offset = mat.props[i + 1] and mat.props[i + 1].offset or mat.prop_block_size
            p.padding = next_offset - (p.offset + p.count * 4)
            p.front_padding = (i == 1) and p.offset or 0
        end
        for i = 0, tex_count - 1 do
            local h = tex_headers + i * 32
            mat.textures[#mat.textures + 1] = { type = utf16(data, u(data, "<I8", h)), path = utf16(data, u(data, "<I8", h + 16)) }
        end
        if mmtrs_offset ~= 0 then
            for k = 0, 7 do
                local o = u(data, "<I8", mmtrs_offset + k * 8)
                local list = {}
                local n = u(data, "<I4", o)
                for j = 0, n - 1 do list[#list + 1] = u(data, "<I4", o + 4 + j * 4) end
                mat.mmtrs[#mat.mmtrs + 1] = list
            end
        end
        for i = 0, gpbf_names - 1 do
            local h = gpu_buffer + i * 32
            mat.gpbf[#mat.gpbf + 1] = { name = utf16(data, u(data, "<I8", h)), path = utf16(data, u(data, "<I8", h + 16)),
                utf16_hash = u(data, "<I4", h + 24), utf8_hash = u(data, "<I4", h + 28) }
        end
        out.materials[#out.materials + 1] = mat
    end
    return out
end

function Mdf2.find(parsed, name)
    for _, m in ipairs(parsed and parsed.materials or {}) do
        if m.name == name then return m end
    end
    return nil
end

-- RE Mesh Editor 导入 mdf 时的数据类型判定(blender_re_mdf.addPropsToPropList)
local BOOL_NAMES = { BackFaceNormalFilp = true, uv1or2_AlphaMap = true }
function Mdf2.data_type(name, count)
    local lower = name:lower()
    if count == 4 and (lower:find("color", 1, true) or lower:find("_col_", 1, true)) and not lower:find("rate", 1, true) then
        return "COLOR"
    end
    if (count == 1 and (name:find("Use", 1, true) or name:find("_or_", 1, true) or name:sub(1, 2) == "is")) or BOOL_NAMES[name] then
        return "BOOL"
    end
    if count > 1 then return "VEC4" end
    return "FLOAT"
end

local function value_for(kind, values)
    if kind == "BOOL" then return (values[1] or 0) ~= 0 and 1.0 or 0.0 end
    if kind == "FLOAT" then return values[1] or 0.0 end
    return { values[1] or 0.0, values[2] or 0.0, values[3] or 0.0, values[4] or 0.0 }
end

local function header(name, mmtr, shader_type)
    return { ["Material Name"] = name, ["Master Material Path"] = mmtr or "", ["Material Shader Type"] = tostring(shader_type or 0) }
end

-- 用 mdf2 里的材质生成预设。live(name) 可选:返回运行时的当前值(数字或 {x,y,z,w}),调色改过的值以它为准
function Mdf2.preset_from_mdf(mat, live)
    local props = {}
    for _, p in ipairs(mat.props) do
        local values = p.values
        local cur = live and live(p.name)
        if type(cur) == "number" then values = { cur }
        elseif type(cur) == "table" then values = { cur[1], cur[2], cur[3], cur[4] } end
        local kind = Mdf2.data_type(p.name, p.count)
        props[#props + 1] = { ["Property Name"] = p.name, ["Data Type"] = kind, ["Value"] = value_for(kind, values),
            ["Padding"] = p.padding, ["FrontPadding"] = p.front_padding }
    end
    local textures = {}
    for _, t in ipairs(mat.textures) do textures[#textures + 1] = { ["Texture Type"] = t.type, ["Texture Path"] = t.path } end
    local preset = {
        presetType = "RE_MDF_MATERIAL", MDFVersion = "RE4", presetVersion = Mdf2.PRESET_VERSION,
        ["Material Header"] = header(mat.name, mat.mmtr, mat.shader_type),
        Flags = { Ver32Unknown = -1, Ver32Unknown1 = -1, Ver32Unknown2 = -1, FlagBitFlag = mat.flags, FlagBitFlagB = mat.flags_b,
            ShaderLODNum = mat.shader_lod, BakeTextureArraySize = mat.bake_texture_array_size },
        ["Property List"] = props, ["Texture Bindings"] = textures,
    }
    -- 空数组在 REFramework 的 json 里会变成 null,插件读到 null 会出错:没有就不写这两项(插件允许缺省)
    if #mat.mmtrs > 0 then
        local list = {}
        for i, indices in ipairs(mat.mmtrs) do
            local s = {}
            for k, v in ipairs(indices) do s[k] = tostring(v) end
            list[i] = table.concat(s, ",")
        end
        preset["MMTRS Data"] = list
    end
    if #mat.gpbf > 0 then
        local list = {}
        for i, g in ipairs(mat.gpbf) do list[i] = string.format("%s,%s,%d,%d", g.name, g.path, g.utf16_hash, g.utf8_hash) end
        preset["GPBF Data"] = list
    end
    return preset
end

-- 读不到 mdf2 时(原版打包在 pak 里,或原生插件太旧):只用运行时能拿到的。
-- props = { { name, count, values } ...}(按材质参数顺序);textures = { { type, path } ... };mmtr 可能为 ""。
-- Padding 按 16 字节对齐推算(float4 从 16 字节边界开始,块尾对齐到 16),Flags / Shader Type 填 0。
function Mdf2.preset_from_runtime(name, props, textures, mmtr)
    local offset, out = 0, {}
    local entries = {}
    for _, p in ipairs(props) do
        if p.count == 4 and offset % 16 ~= 0 then
            local pad = 16 - offset % 16
            if #entries > 0 then entries[#entries].padding = entries[#entries].padding + pad end
            offset = offset + pad
        end
        entries[#entries + 1] = { p = p, padding = 0 }
        offset = offset + p.count * 4
    end
    if #entries > 0 and offset % 16 ~= 0 then entries[#entries].padding = entries[#entries].padding + (16 - offset % 16) end
    for _, e in ipairs(entries) do
        local kind = Mdf2.data_type(e.p.name, e.p.count)
        out[#out + 1] = { ["Property Name"] = e.p.name, ["Data Type"] = kind, ["Value"] = value_for(kind, e.p.values),
            ["Padding"] = e.padding, ["FrontPadding"] = 0 }
    end
    local tex = {}
    for _, t in ipairs(textures) do tex[#tex + 1] = { ["Texture Type"] = t.type, ["Texture Path"] = t.path } end
    return {
        presetType = "RE_MDF_MATERIAL", MDFVersion = "RE4", presetVersion = Mdf2.PRESET_VERSION,
        ["Material Header"] = header(name, mmtr, 0),
        Flags = { Ver32Unknown = -1, Ver32Unknown1 = -1, Ver32Unknown2 = -1, FlagBitFlag = 0, FlagBitFlagB = 0,
            ShaderLODNum = 0, BakeTextureArraySize = 0 },
        ["Property List"] = out, ["Texture Bindings"] = tex,
    }
end

-- 运行时材质 j 的预设。先读 mod 的 mdf2;读不到时退回运行时数据。返回 preset, reason(nil = 来自 mdf2)
-- palette:Palette 模块(读参数);effects_index:离线材质库(认母材质,给后备方案填 mmtr 路径)
function Mdf2.export(mesh, j, material, palette, effects_index)
    local vars = palette.read_vars(mesh, j)
    local live = function(name)
        local var = vars[name]
        return var and palette.read_value(mesh, j, var) or nil
    end
    local reason
    local ok, preset = pcall(function()
        local holder = mesh:call("get_Material")
        local rel = Mdf2.file_path(holder and holder:call("get_ResourcePath"))
        if not rel then error("no mdf2 resource path") end
        local bridge = rawget(_G, "avm_portrait")
        local reader = type(bridge) == "table" and bridge.read_game_file
        if type(reader) ~= "function" then error("native plugin too old (no read_game_file)") end
        local data, err = reader(rel)
        if not data then error(rel .. ": " .. tostring(err)) end
        local mat = Mdf2.find(Mdf2.parse(data), material)
        if not mat then error(rel .. ": material " .. tostring(material) .. " not in file") end
        return Mdf2.preset_from_mdf(mat, live)
    end)
    if ok then return preset, nil end
    reason = tostring(preset):gsub("^.-%.lua:%d+: ", "")
    -- 后备:参数按序号,贴图按序号(原始路径),母材质能认出来就填
    local list = {}
    for n, var in pairs(vars) do list[#list + 1] = { name = n, var = var } end
    table.sort(list, function(a, b) return a.var.k < b.var.k end)
    local props = {}
    for _, e in ipairs(list) do
        local v = palette.read_value(mesh, j, e.var)
        local is4 = e.var.t ~= palette.TYPE_FLOAT
        props[#props + 1] = { name = e.name, count = is4 and 4 or 1, values = is4 and (v or {}) or { v or 0 } }
    end
    local textures = {}
    local n = tonumber(mesh:call("getMaterialTextureNum", j)) or 0
    for t = 0, n - 1 do
        local tname = mesh:call("getMaterialTextureName", j, t)
        local holder = mesh:call("getMaterialTexture", j, t)
        local path = holder and holder:call("get_ResourcePath") or ""
        if type(tname) == "string" then
            textures[#textures + 1] = { type = tname, path = (tostring(path):gsub("\\", "/")) }
        end
    end
    local mmtr = ""
    if effects_index then
        pcall(function()
            local master = palette.find_master(effects_index, mesh:call("getMaterialVariableNum", j), palette.read_textures(mesh, j))
            if master then mmtr = master.id end
        end)
    end
    return Mdf2.preset_from_runtime(material, props, textures, mmtr), reason
end

-- 网格当前 mdf2 文件里某个材质参数的值(原版值):float 返回数值,float4 返回 { x, y, z, w } 数组。
-- cache 可选:{ [相对路径] = 解析结果 | false },一次操作里读很多参数时避免重复读文件。
-- 读不到(材质打包在 pak 里、原生插件太旧、文件里没有这个材质 / 参数)返回 nil, 原因
function Mdf2.file_value(mesh, material, param, cache)
    local ok, v, why = pcall(function()
        local holder = mesh:call("get_Material")
        local rel = Mdf2.original_rel(Mdf2.file_path(holder and holder:call("get_ResourcePath")))
        if not rel then return nil, "no mdf2 resource path" end
        local parsed = cache and cache[rel]
        if parsed == nil then
            local bridge = rawget(_G, "avm_portrait")
            local reader = type(bridge) == "table" and bridge.read_game_file
            if type(reader) ~= "function" then return nil, "native plugin too old (no read_game_file)" end
            local data = reader(rel)
            parsed = data and Mdf2.parse(data) or false
            if cache then cache[rel] = parsed end
        end
        if not parsed then return nil, rel .. ": not readable" end
        local mat = Mdf2.find(parsed, material)
        if not mat then return nil, "material not in file" end
        for _, p in ipairs(mat.props) do
            if p.name == param then
                if p.count == 1 then return p.values[1] end
                return { p.values[1], p.values[2], p.values[3], p.values[4] }
            end
        end
        return nil, "parameter not in file"
    end)
    if not ok then return nil, tostring(v) end
    return v, why
end

-- 预设名:RE Mesh Editor 用它当文件名。只允许英文字母、数字、空格、- 和 _,1~64 个字符,首字符不能是空格
function Mdf2.valid_name(name)
    return type(name) == "string" and #name >= 1 and #name <= 64 and name:match("^[%w_%-][%w _%-]*$") ~= nil
        and not name:match("%s$")
end

-- 把调色覆盖值原地写进 mdf2(「替换 mdf」用):只改参数值所在的字节,文件结构不变。
-- overrides = { [材质名] = { [参数] = 数字 | { x =, y =, z =, w = }(只写改过的分量) } }(即 cfg.palette[槽位])。
-- 返回新内容和写入的分量个数
local COMP = { x = 0, y = 1, z = 2, w = 3 }
function Mdf2.patch(data, overrides)
    local parsed = Mdf2.parse(data)
    local writes = {}
    for _, mat in ipairs(parsed.materials) do
        local ov = type(overrides) == "table" and overrides[mat.name]
        if type(ov) == "table" then
            for _, p in ipairs(mat.props) do
                local o = ov[p.name]
                local base = mat.prop_data + p.offset
                if type(o) == "number" and p.count >= 1 then
                    writes[#writes + 1] = { base, o }
                elseif type(o) == "table" then
                    for c, i in pairs(COMP) do
                        if type(o[c]) == "number" and i < p.count then writes[#writes + 1] = { base + i * 4, o[c] } end
                    end
                end
            end
        end
    end
    table.sort(writes, function(a, b) return a[1] < b[1] end)
    local out, at = {}, 0
    for _, w in ipairs(writes) do
        if w[1] >= at and w[1] + 4 <= #data then
            out[#out + 1] = data:sub(at + 1, w[1])
            out[#out + 1] = string.pack("<f", w[2])
            at = w[1] + 4
        end
    end
    out[#out + 1] = data:sub(at + 1)
    return table.concat(out), #writes, parsed
end

-- 重载副本:同一路径的资源引擎会缓存(2026-11-05 实测:文件改了,同路径重新 create_resource 拿到的还是旧的),
-- 所以写一份 <名字>_avmr<数字>.mdf2.32 再加载它。
function Mdf2.original_rel(rel)
    if type(rel) ~= "string" then return nil end
    return (rel:gsub("_avmr%d+(%.[Mm][Dd][Ff]2%.%d+)$", "%1"))
end
function Mdf2.reload_rel(original, n)
    return (original:gsub("(%.[Mm][Dd][Ff]2%.%d+)$", "_avmr" .. tostring(n) .. "%1"))
end
-- 相对文件路径 → 资源路径(去掉 natives/STM/ 和版本号)
function Mdf2.resource_path(rel)
    return (rel:gsub("^[Nn][Aa][Tt][Ii][Vv][Ee][Ss]/[Ss][Tt][Mm]/", ""):gsub("%.%d+$", ""))
end

-- 资源路径 → 游戏目录下的相对文件路径(natives/STM/<路径>.32)
function Mdf2.file_path(resource_path)
    if type(resource_path) ~= "string" or resource_path == "" then return nil end
    local p = resource_path:gsub("\\", "/"):gsub("^@", "")
    p = p:gsub("^[Nn][Aa][Tt][Ii][Vv][Ee][Ss]/[Ss][Tt][Mm]/", "")
    if not p:lower():match("%.mdf2$") and not p:lower():match("%.mdf2%.%d+$") then return nil end
    if not p:match("%.%d+$") then p = p .. "." .. Mdf2.VERSION end
    return "natives/STM/" .. p
end

return Mdf2
