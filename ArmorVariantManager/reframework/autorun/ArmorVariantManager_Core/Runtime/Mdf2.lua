-- mdf2（材质定义）文件的解析、原地改参数值，以及导出成 RE Mesh Editor 的材质预设。不依赖具体游戏。
--
-- 结构照 RE Mesh Editor 的 modules/mdf/file_re_mdf.py（NSA Cloud），支持 v19 及以后的格式：
--   头 16 字节：magic u32（"MDF\0"）、version u16（固定为 1）、materialCount u16、flags u64
--   材质条目：v19~v30 80 字节，v31~v50 100 字节，v51 起 108 字节（多一个 u64 偏移）。
--     nameOffset u64, nameHash u32, propBlockSize i32, propertyCount i32, textureCount i32,
--     gpbfNameCount i32, gpbfPathCount i32, [v31+ bakeTextureArraySize i32], shaderType i32, flags i32,
--     [v31+ flagsB i32, shaderLODNum i32], [v51+ unknOffset u64], propHeadersOffset u64, texHeadersOffset u64,
--     gpuBufferOffset u64, propDataOffset u64, mmtrPathOffset u64, [v31+ mmtrsDataOffset u64]
--   参数头 24 字节：nameOffset u64, hash u32, hash u32, dataOffset i32, paramCount u16, unknFlag u16
--   贴图绑定 32 字节：typeOffset u64, hash u32, hash u32, pathOffset u64, 8 字节保留
--   GPBF：名字 / 路径条目交替，每条 16 字节（nameOffset u64, utf16Hash u32, utf8Hash u32）
--   MMTRS：8 个 u64 偏移，各指向 count u32 + count 个 u32
--   字符串都是 UTF-16LE、以 0 结尾
-- 格式版本看文件扩展名（xxx.mdf2.45），不看头里的 version。
-- 预设字段与取值规则照 modules/mdf/re_mdf_presets.py 和 blender_re_mdf.py。
local Mdf2 = {}

Mdf2.MAGIC = 4605005
Mdf2.PRESET_VERSION = 5
-- RE Mesh Editor 预设里的 MDFVersion（也是插件 Presets/ 下的目录名）
Mdf2.GAME_NAMES = { [19] = "RE8", [21] = "RE2RT", [23] = "MHRSB", [31] = "SF6", [32] = "RE4", [40] = "DD2",
    [45] = "MHWILDS", [46] = "ONI2", [51] = "RE9" }

local function layout(version)
    if type(version) ~= "number" or version < 19 then error("unsupported mdf2 version " .. tostring(version)) end
    local v31, v51 = version >= 31, version >= 51
    local o = {}
    o.size = v51 and 108 or v31 and 100 or 80
    local at = 32                                   -- gpbfPathCount 之后
    if v31 then o.bake = at; at = at + 4 end
    o.shader = at; o.flags = at + 4; at = at + 8
    if v31 then o.flags_b = at; o.shader_lod = at + 4; at = at + 8 end
    if v51 then at = at + 8 end
    o.prop_headers, o.tex_headers, o.gpu_buffer, o.prop_data, o.mmtr = at, at + 8, at + 16, at + 24, at + 32
    if v31 then o.mmtrs = at + 40 end
    return o
end

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

-- data：整个文件内容；version：扩展名里的版本号。返回 { version, materials = { 材质... } }，格式不对时报错
function Mdf2.parse(data, version)
    if type(data) ~= "string" or #data < 16 then error("not an mdf2 file") end
    if u(data, "<I4", 0) ~= Mdf2.MAGIC then error("not an mdf2 file") end
    local o = layout(version)
    local count = u(data, "<I2", 6)
    if 16 + count * o.size > #data then error("truncated mdf2 header") end
    local out = { version = version, materials = {} }
    local function block(offset, elements, stride)
        if elements < 0 or offset < 0 or offset > #data or elements > (#data - offset) // stride then
            error("invalid mdf2 table bounds")
        end
    end
    for m = 0, count - 1 do
        local b = 16 + m * o.size
        local mat = {
            name = utf16(data, u(data, "<I8", b)),
            prop_block_size = u(data, "<i4", b + 12),
            bake_texture_array_size = o.bake and u(data, "<i4", b + o.bake) or 0,
            shader_type = u(data, "<i4", b + o.shader),
            flags = u(data, "<i4", b + o.flags),
            flags_b = o.flags_b and u(data, "<i4", b + o.flags_b) or 0,
            shader_lod = o.shader_lod and u(data, "<i4", b + o.shader_lod) or 0,
            props = {}, textures = {}, mmtrs = {}, gpbf = {},
        }
        local prop_count, tex_count = u(data, "<i4", b + 16), u(data, "<i4", b + 20)
        local gpbf_names = u(data, "<i4", b + 24)
        local prop_headers, tex_headers = u(data, "<I8", b + o.prop_headers), u(data, "<I8", b + o.tex_headers)
        local gpu_buffer, prop_data = u(data, "<I8", b + o.gpu_buffer), u(data, "<I8", b + o.prop_data)
        mat.prop_data = prop_data
        mat.mmtr = utf16(data, u(data, "<I8", b + o.mmtr))
        local mmtrs_offset = o.mmtrs and u(data, "<I8", b + o.mmtrs) or 0
        block(prop_headers, prop_count, 24)
        block(tex_headers, tex_count, 32)
        block(gpu_buffer, gpbf_names, 32)
        block(prop_data, mat.prop_block_size, 1)
        for i = 0, prop_count - 1 do
            local h = prop_headers + i * 24
            local p = { name = utf16(data, u(data, "<I8", h)), offset = u(data, "<i4", h + 16), count = u(data, "<I2", h + 20), values = {} }
            if p.offset < 0 or p.offset + 4 * p.count > mat.prop_block_size then
                error("invalid mdf2 parameter range")
            end
            for k = 0, p.count - 1 do p.values[k + 1] = u(data, "<f", prop_data + p.offset + k * 4) end
            mat.props[#mat.props + 1] = p
        end
        -- Padding：到下一个参数（最后一个到块尾）之间的空隙；FrontPadding 只有第一个参数有
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
            block(mmtrs_offset, 8, 8)
            for k = 0, 7 do
                local offset = u(data, "<I8", mmtrs_offset + k * 8)
                local list = {}
                local n = u(data, "<I4", offset)
                block(offset + 4, n, 4)
                for j = 0, n - 1 do list[#list + 1] = u(data, "<I4", offset + 4 + j * 4) end
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

-- RE Mesh Editor 导入 mdf 时的数据类型判定（blender_re_mdf.addPropsToPropList）
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

local function preset_base(version, name, mmtr, shader_type)
    return {
        presetType = "RE_MDF_MATERIAL", MDFVersion = Mdf2.GAME_NAMES[version] or tostring(version),
        presetVersion = Mdf2.PRESET_VERSION,
        ["Material Header"] = { ["Material Name"] = name, ["Master Material Path"] = mmtr or "",
            ["Material Shader Type"] = tostring(shader_type or 0) },
    }
end

-- 用 mdf2 里的材质生成预设。live(参数名) 可选：返回运行时的当前值（数字或 { x, y, z, w } 数组），调色改过的值以它为准
function Mdf2.preset_from_mdf(version, mat, live)
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
    local preset = preset_base(version, mat.name, mat.mmtr, mat.shader_type)
    preset.Flags = { Ver32Unknown = -1, Ver32Unknown1 = -1, Ver32Unknown2 = -1, FlagBitFlag = mat.flags, FlagBitFlagB = mat.flags_b,
        ShaderLODNum = mat.shader_lod, BakeTextureArraySize = mat.bake_texture_array_size }
    preset["Property List"], preset["Texture Bindings"] = props, textures
    -- 空数组在 REFramework 的 json 里会变成 null，插件读到 null 会出错：没有就不写这两项（插件允许缺省）
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

-- 读不到 mdf2 时（原版材质在 pak 里、原生插件太旧）只用运行时能拿到的。
-- props = { { name, count, values } ... }（按材质参数顺序）；textures = { { type, path } ... }。
-- Padding 按 16 字节对齐推算（float4 从 16 字节边界开始，块尾对齐到 16），母材质路径、Flags、Shader Type 留空或填 0。
function Mdf2.preset_from_runtime(version, name, props, textures)
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
    local preset = preset_base(version, name, "", 0)
    preset.Flags = { Ver32Unknown = -1, Ver32Unknown1 = -1, Ver32Unknown2 = -1, FlagBitFlag = 0, FlagBitFlagB = 0,
        ShaderLODNum = 0, BakeTextureArraySize = 0 }
    preset["Property List"], preset["Texture Bindings"] = out, tex
    return preset
end

-- 预设名：RE Mesh Editor 用它当文件名。只允许英文字母、数字、空格、- 和 _，1~64 个字符，首尾不能是空格
function Mdf2.valid_name(name)
    return type(name) == "string" and #name >= 1 and #name <= 64 and name:match("^[%w_%-][%w _%-]*$") ~= nil
        and not name:match("%s$")
end

-- 把调色覆盖值原地写进 mdf2：只改参数值所在的字节，文件结构不变。
-- overrides = { [材质名] = { [参数] = 数字 | { x =, y =, z =, w = }（只写改过的分量） } }（预设 palette 字段里的一个部位）。
-- 返回新内容、写入的分量个数、解析结果、写到的参数 { [材质名] = { [参数] = true } }
local COMP = { x = 0, y = 1, z = 2, w = 3 }
function Mdf2.patch(data, version, overrides)
    local parsed = Mdf2.parse(data, version)
    local writes, written = {}, {}
    for _, mat in ipairs(parsed.materials) do
        local ov = type(overrides) == "table" and overrides[mat.name]
        if type(ov) == "table" then
            for _, p in ipairs(mat.props) do
                local o = ov[p.name]
                local base = mat.prop_data + p.offset
                local hit = false
                if type(o) == "number" and p.count >= 1 then
                    writes[#writes + 1] = { base, o }
                    hit = true
                elseif type(o) == "table" then
                    for c, i in pairs(COMP) do
                        if type(o[c]) == "number" and i < p.count then
                            writes[#writes + 1] = { base + i * 4, o[c] }
                            hit = true
                        end
                    end
                end
                if hit then
                    written[mat.name] = written[mat.name] or {}
                    written[mat.name][p.name] = true
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
    return table.concat(out), #writes, parsed, written
end

-- 资源路径 → 游戏目录下的相对文件路径（natives/STM/<路径>.<版本>）
function Mdf2.file_path(resource_path, version)
    if type(resource_path) ~= "string" or resource_path == "" then return nil end
    local p = resource_path:gsub("\\", "/"):gsub("^@", "")
    p = p:gsub("^[Nn][Aa][Tt][Ii][Vv][Ee][Ss]/[Ss][Tt][Mm]/", "")
    if not p:lower():match("%.mdf2$") and not p:lower():match("%.mdf2%.%d+$") then return nil end
    if not p:match("%.%d+$") then p = p .. "." .. tostring(version) end
    return "natives/STM/" .. p
end
-- 相对文件路径 → 资源路径（去掉 natives/STM/ 和版本号）
function Mdf2.resource_path(rel)
    return (rel:gsub("^[Nn][Aa][Tt][Ii][Vv][Ee][Ss]/[Ss][Tt][Mm]/", ""):gsub("%.%d+$", ""))
end
function Mdf2.version_of(rel)
    return tonumber(type(rel) == "string" and rel:match("%.[Mm][Dd][Ff]2%.(%d+)$") or nil)
end

-- 重载副本：同一路径的资源引擎会缓存，文件改了也不会重新读，所以写一份 <名字>_avmr<数字>.mdf2.<版本> 再加载它
function Mdf2.original_rel(rel)
    if type(rel) ~= "string" then return nil end
    return (rel:gsub("_avmr%d+(%.[Mm][Dd][Ff]2%.%d+)$", "%1"))
end
function Mdf2.reload_rel(original, n)
    return (original:gsub("(%.[Mm][Dd][Ff]2%.%d+)$", "_avmr" .. tostring(n) .. "%1"))
end

return Mdf2
