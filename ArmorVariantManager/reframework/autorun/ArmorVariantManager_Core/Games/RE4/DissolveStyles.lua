-- 内置溶解样式(2026-11-08):溶解开始时把材质的 Dissolve_NoiseMap 换成样式的噪声图(可选再改光边参数),
-- 这一轮溶解结束后换回原样。作为一个效果提供者注册(EffectProviders.lua),时机、随机、按角色合并都复用那边。
--
-- 只换噪声图(格子形状)和光边参数,不换 Dissolve_Map:后者按每个模型的 UV 烘焙(决定方向 / 顺序),不能跨模型通用。
-- 溶解模板读的贴图与参数(源码 + 游戏内探针核对过):
--   Dissolve_NoiseMap  uv1 × Dissolve_Misc.z 平铺;R = 格子各自的切换时间,G = 格子描边(边框处为 1)
--   Dissolve_Edge      x 光边宽度,y 噪声权重,z 光边强度,w 描边占比(0 整条光带,1 只亮格子边框)
--   Dissolve_EdgeColor rgb 光边颜色
--   Dissolve_Misc      z 噪声平铺,w 噪声滚动(Dissolve)/ 光边动画速度(AnimDissolve)
--
-- 换贴图的实测约束(2026-11-08,两次闪退后对照得出):
--   * 自己加载的 resource 和 holder 都要一直持有(存进表里),否则可能被回收
--   * 不要对 getMaterialTexture 拿回来的原 holder 做 add_ref;原贴图只记路径,还原时按路径重新取
--     (那份资源正被材质用着,create_resource 拿到的是已加载的缓存,马上能用)
--   * 新贴图要提前加载(异步,太早换上是黄白格子),所以启动后预加载全部样式的噪声图
local Styles = {}

Styles.PROVIDER_ID = "avm.builtin"
Styles.NOISE_SLOT = "Dissolve_NoiseMap"
local DIR = "ArmorVariantManager/Dissolve/"

-- 样式表。noise = 噪声图资源路径(nil = 不换);params[变量名] = { x, y, z, w },nil 的分量保持材质原值
Styles.LIST = {
    { id = "original", label = { ["zh-CN"] = "模组原样", ["en-US"] = "As authored" } },
    { id = "hex", label = { ["zh-CN"] = "六边形", ["en-US"] = "Hexagon" }, noise = DIR .. "Dissolve_Hex_NoiseMap.tex" },
    { id = "square", label = { ["zh-CN"] = "方块", ["en-US"] = "Square" }, noise = DIR .. "Dissolve_Square_NoiseMap.tex" },
    { id = "rect", label = { ["zh-CN"] = "矩形", ["en-US"] = "Rectangle" }, noise = DIR .. "Dissolve_Rect_NoiseMap.tex" },
}

-- 光边覆盖(全局一套,「溶解」页):每项 on = 是否覆盖,value = 覆盖值;关着就沿用材质自己的值。
-- 存在全局设置 dissolve_edge[key] = { on, value }。var / comp = 写到哪个变量的哪个分量(1..4)。
-- 「关闭发光边」不单列:Dissolve_Flag 由 Dissolve.lua 每帧写,光边强度设 0 效果相同。
Styles.EDGE = {
    { key = "color", var = "Dissolve_EdgeColor", kind = "color", default = { 1, 0.38, 0.06 } },
    { key = "width", var = "Dissolve_Edge", comp = 1, min = 0, max = 1, default = 0.25 },
    { key = "intensity", var = "Dissolve_Edge", comp = 3, min = 0, max = 10, default = 4 },
    { key = "border", var = "Dissolve_Edge", comp = 4, min = 0, max = 1, default = 0 },
    { key = "noise_weight", var = "Dissolve_Edge", comp = 2, min = 0, max = 2, default = 0.6 },
    -- 格子大小:界面上数值越大格子越大,写入的是噪声平铺 Misc.z = 1 / 大小(按各材质自己的 UV)
    { key = "cell_size", var = "Dissolve_Misc", comp = 3, min = 0.1, max = 10, default = 0.667, invert = true },
    -- 流动速度:Dissolve 模板是噪声 U 向滚动(每秒),AnimDissolve 是光边动画速度(0 视为 1)
    { key = "flow", var = "Dissolve_Misc", comp = 4, min = 0, max = 10, default = 1 },
}
local EDGE_BY_KEY = {}
for _, e in ipairs(Styles.EDGE) do EDGE_BY_KEY[e.key] = e end

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function round3(n) return math.floor(n * 1000 + 0.5) / 1000 end

-- 一项覆盖值规范化;不合法返回 nil
local function clean_value(e, v)
    if e.kind == "color" then
        if type(v) ~= "table" then return nil end
        local out = {}
        for i = 1, 3 do
            local n = tonumber(v[i])
            if not n then return nil end
            out[i] = round3(clamp(n, 0, 1))
        end
        return out
    end
    local n = tonumber(v)
    return n and round3(clamp(n, e.min, e.max)) or nil
end

-- 读盘 / 外来的表 → 完整的覆盖表(每项都在,缺的用默认值、关着)
function Styles.clean_edge(t)
    local out = {}
    t = type(t) == "table" and t or {}
    for _, e in ipairs(Styles.EDGE) do
        local src = type(t[e.key]) == "table" and t[e.key] or {}
        local v = clean_value(e, src.value)
        if v == nil then v = e.kind == "color" and { e.default[1], e.default[2], e.default[3] } or e.default end
        out[e.key] = { on = src.on == true, value = v }
    end
    return out
end

-- 改一项:on / value 都可以不给(不改);不认识的项或不合法的值返回 false
function Styles.set_edge(edge, key, on, value)
    local e = EDGE_BY_KEY[key]
    if not e or type(edge) ~= "table" or type(edge[key]) ~= "table" then return false end
    if on ~= nil and type(on) ~= "boolean" then return false end
    local v = edge[key].value
    if value ~= nil then
        v = clean_value(e, value)
        if v == nil then return false end
    end
    if on ~= nil then edge[key].on = on end
    edge[key].value = v
    return true
end

-- 给界面:[{ key, kind, on, value, min, max }]
function Styles.edge_list(edge)
    local out = {}
    for _, e in ipairs(Styles.EDGE) do
        local cur = type(edge) == "table" and edge[e.key] or nil
        out[#out + 1] = { key = e.key, kind = e.kind or "float", on = cur and cur.on == true or false,
            value = cur and cur.value or e.default, min = e.min, max = e.max }
    end
    return out
end

-- 开着的覆盖 → { [变量名] = { x, y, z, w } }(没覆盖的分量为 nil)
local function edge_params(edge)
    local out
    for _, e in ipairs(Styles.EDGE) do
        local cur = type(edge) == "table" and edge[e.key] or nil
        if cur and cur.on == true then
            out = out or {}
            local p = out[e.var] or {}
            out[e.var] = p
            if e.kind == "color" then p[1], p[2], p[3] = cur.value[1], cur.value[2], cur.value[3]
            elseif e.invert then p[e.comp] = 1 / cur.value
            else p[e.comp] = cur.value end
        end
    end
    return out
end
Styles.edge_params = edge_params

-- ============================================================ 溶解预设(全局库,「溶解」页)
-- 一个预设 = 形状(Styles.LIST 的 id 或 "random")+ 光边覆盖(clean_edge 的表)。
-- 库存在全局设置 dissolve_presets = { order = { 名字... }, items = { [名字] = { shape, edge } }, default = 名字 | "random" | nil }。
-- 条件状态 / 整套造型预设 / 状态组选项按名字引用(角色配置里),一次溶解用哪个见 Main 的 choose_transition;
-- 引用的预设不存在就退回 default。
Styles.DEFAULT_PRESET = "默认"
local SHAPE_IDS = {}
for _, s in ipairs(Styles.LIST) do SHAPE_IDS[s.id] = true end

function Styles.valid_preset_name(n)
    return type(n) == "string" and n:match("%S") ~= nil and #n <= 48 and not n:find("%c") and n ~= "random"
end
local function clean_shape(v) return (v == "random" or SHAPE_IDS[v]) and v or "original" end

-- 读盘的库 → 规范化;没有库时用 legacy = { shape, edge }(旧版的全局形状和光边)建一个「默认」预设
function Styles.clean_presets(t, legacy)
    local out = { order = {}, items = {} }
    t = type(t) == "table" and t or nil
    local items = t and type(t.items) == "table" and t.items or nil
    if items then
        local seen = {}
        local function add(n)
            local it = items[n]
            if seen[n] or not Styles.valid_preset_name(n) or type(it) ~= "table" then return end
            seen[n] = true
            out.items[n] = { shape = clean_shape(it.shape), edge = Styles.clean_edge(it.edge) }
            out.order[#out.order + 1] = n
        end
        for _, n in ipairs(type(t.order) == "table" and t.order or {}) do add(n) end
        local rest = {}
        for n in pairs(items) do if not seen[n] then rest[#rest + 1] = n end end
        table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
        for _, n in ipairs(rest) do add(n) end
    elseif not t then
        legacy = type(legacy) == "table" and legacy or {}
        local n = Styles.DEFAULT_PRESET
        out.items[n] = { shape = clean_shape(legacy.shape), edge = Styles.clean_edge(legacy.edge) }
        out.order[1] = n
    end
    local d = t and t.default
    if d == nil and not t then d = Styles.DEFAULT_PRESET end
    out.default = (d == "random" or out.items[d]) and d or out.order[1]
    return out
end

function Styles.preset_new(lib, name, from)
    if not Styles.valid_preset_name(name) or lib.items[name] then return false end
    local src = from and lib.items[from]
    if from and not src then return false end
    lib.items[name] = src and { shape = src.shape, edge = Styles.clean_edge(src.edge) } or { shape = "original", edge = Styles.clean_edge(nil) }
    lib.order[#lib.order + 1] = name
    if lib.default == nil then lib.default = name end
    return true
end

function Styles.preset_rename(lib, old, new)
    if not lib.items[old] or not Styles.valid_preset_name(new) or lib.items[new] then return false end
    lib.items[new], lib.items[old] = lib.items[old], nil
    for i, n in ipairs(lib.order) do if n == old then lib.order[i] = new end end
    if lib.default == old then lib.default = new end
    return true
end

-- 删除后引用保留,解算时退回默认
function Styles.preset_delete(lib, name)
    if not lib.items[name] then return false end
    lib.items[name] = nil
    for i, n in ipairs(lib.order) do if n == name then table.remove(lib.order, i); break end end
    if lib.default == name then lib.default = lib.order[1] end
    return true
end

function Styles.preset_shape(lib, name, shape)
    local it = lib.items[name]
    if not it or not (shape == "random" or SHAPE_IDS[shape]) then return false end
    if it.shape == shape then return false end
    it.shape = shape
    return true
end

function Styles.preset_edge(lib, name, key, on, value)
    local it = lib.items[name]
    return it ~= nil and Styles.set_edge(it.edge, key, on, value)
end

function Styles.preset_default(lib, name)
    if name ~= "random" and not lib.items[name] then return false end
    if lib.default == name then return false end
    lib.default = name
    return true
end

-- 给界面:{ default, list = { { name, shape, edge = edge_list } }, shapes = { { id, label } } }
function Styles.presets_view(lib)
    local list = {}
    for _, n in ipairs(lib.order) do
        local it = lib.items[n]
        list[#list + 1] = { name = n, shape = it.shape, edge = Styles.edge_list(it.edge) }
    end
    local shapes = {}
    for _, s in ipairs(Styles.LIST) do shapes[#shapes + 1] = { id = s.id, label = s.label } end
    return { default = lib.default or "", list = list, shapes = shapes }
end

-- 这个预设会不会改动材质(形状不是"原样",或开了光边覆盖)
local function takes_over(it)
    return it ~= nil and (it.shape ~= "original" or edge_params(it.edge) ~= nil)
end
Styles.takes_over = takes_over

local function try(f) local ok, r = pcall(f); if ok then return r end; return nil end
local function path_of(h)
    return h and try(function() return h:call("get_ResourcePath") end) or nil
end

-- opt = {
--   load_texture(path) -> holder 或 nil  (负责 create_resource + 持有引用;同一路径只会调一次)
--   presets() -> 全局预设库            (clean_presets 的表)
--   random(n) -> 1..n                   (可选,测试注入)
--   vec4(x, y, z, w) -> 写入用的向量    (游戏里是 Vector4f.new)
-- }
function Styles.new(opt)
    local by_id = {}
    for _, s in ipairs(Styles.LIST) do by_id[s.id] = s end
    local holders = {}      -- 路径 -> holder 或 false(加载失败)
    local slot_cache = {}   -- mesh_j_材质名 -> 噪声槽序号 或 false
    local var_cache = {}    -- mesh_j_材质名 -> { [变量名] = 序号 }
    local txs = {}          -- tx_id -> { style, rows = { [mesh_j] = row } }
    local active = {}       -- mesh_j -> row(正被某个事务改着的材质)

    local function holder(path)
        if not path then return nil end
        if holders[path] == nil then
            local ok, h = pcall(opt.load_texture, path)
            holders[path] = (ok and h) or false
        end
        return holders[path] or nil
    end

    local function mat_key(mesh, j)
        local name = try(function() return mesh:call("getMaterialName", j) end) or ""
        return tostring(mesh) .. "_" .. tostring(j) .. "_" .. name
    end

    local function noise_slot(mesh, j, key)
        local v = slot_cache[key]
        if v == nil then
            v = false
            for t = 0, (try(function() return mesh:call("getMaterialTextureNum", j) end) or 0) - 1 do
                if try(function() return mesh:call("getMaterialTextureName", j, t) end) == Styles.NOISE_SLOT then v = t; break end
            end
            slot_cache[key] = v
        end
        return v or nil
    end

    local function var_index(mesh, j, key, name)
        local vars = var_cache[key]
        if not vars then
            vars = {}
            for k = 0, (try(function() return mesh:call("getMaterialVariableNum", j) end) or 0) - 1 do
                local n = try(function() return mesh:call("getMaterialVariableName", j, k) end)
                if n then vars[n] = k end
            end
            var_cache[key] = vars
        end
        return vars[name]
    end

    local function write_param(row, name)
        local p = row.params[name]
        local want = row.want[name]
        local o = p.orig
        local v = opt.vec4(want[1] or o[1], want[2] or o[2], want[3] or o[3], want[4] or o[4])
        try(function() row.mesh:call("setMaterialFloat4", row.j, p.index, v) end)
    end

    local function restore(row)
        if row.slot and row.orig_path then
            local h = holder(row.orig_path)
            if h then try(function() row.mesh:call("setMaterialTexture", row.j, row.slot, h) end) end
        end
        for _, p in pairs(row.params) do
            local o = p.orig
            try(function() row.mesh:call("setMaterialFloat4", row.j, p.index, opt.vec4(o[1], o[2], o[3], o[4])) end)
        end
        active[row.mkey] = nil
    end

    -- 启动后调一次:把所有样式的噪声图先加载上
    local api = {}
    function api.preload()
        for _, s in ipairs(Styles.LIST) do holder(s.noise) end
    end

    local pool = {}     -- 形状选"随机"时从这些里抽
    for _, s in ipairs(Styles.LIST) do if s.noise or s.params then pool[#pool + 1] = s.id end end
    local rand = opt.random or math.random

    -- 这一轮用哪个预设:提示里的名字(条件状态 / 预设 / 选项引用的)存在就用它,否则用默认;返回名字或 "random" 或 nil
    local function resolve(hint)
        local lib = opt.presets and opt.presets()
        if type(lib) ~= "table" or type(lib.items) ~= "table" then return nil, nil end
        local name = type(hint) == "table" and hint.preset or nil
        if not (name and lib.items[name]) then name = lib.default end
        return name, lib
    end

    api.provider = {
        api_version = 1,
        id = Styles.PROVIDER_ID,
        name = { ["zh-CN"] = "内置样式", ["en-US"] = "Built-in" },
        -- 内置样式在注册表里只有一个占位效果:用哪个预设由每次过渡的提示决定(见 resolve),不走注册表的选择
        effects = { "preset" },
        default = "preset",
        -- 用到的预设不改动材质(原样 + 没开光边)就不接管,让给其他 mod;只管带噪声槽的溶解模板材质
        supports = function(mesh, j, hint)
            local name, lib = resolve(hint)
            if not name then return false end
            if name == "random" then
                local any = false
                for _, it in pairs(lib.items) do if takes_over(it) then any = true; break end end
                if not any then return false end
            elseif not takes_over(lib.items[name]) then
                return false
            end
            return noise_slot(mesh, j, mat_key(mesh, j)) ~= nil
        end,
        begin_transaction = function(info)
            local name, lib = resolve(info.hint)
            if not name then return false end
            if name == "random" then
                if #lib.order == 0 then return false end
                name = lib.order[rand(#lib.order)]
            end
            local it = lib.items[name]
            if not it then return false end
            local shape = it.shape
            if shape == "random" then shape = pool[rand(#pool)] end
            -- 光边在开始时定下,这一轮里改设置不影响
            txs[info.id] = { style = by_id[shape] or by_id.original, preset = name, ep = edge_params(it.edge) or {}, rows = {} }
            return true
        end,
        bind_material = function(tx_id, mesh, j)
            local tx = txs[tx_id]
            if not tx then return false end
            local mkey = tostring(mesh) .. "_" .. tostring(j)
            if active[mkey] then return true end    -- 已经被某个事务改着(反向切换等),不重复记原值
            local key = mat_key(mesh, j)
            local style = tx.style
            -- 要写的参数 = 样式自带的 + 预设的光边覆盖(覆盖优先)
            local want = {}
            for name, comps in pairs(style.params or {}) do want[name] = { comps[1], comps[2], comps[3], comps[4] } end
            for name, comps in pairs(tx.ep) do
                local w = want[name] or {}
                for i = 1, 4 do if comps[i] ~= nil then w[i] = comps[i] end end
                want[name] = w
            end
            local row = { mesh = mesh, j = j, mkey = mkey, style = style, want = want, params = {} }
            if style.noise then
                local h = holder(style.noise)
                local slot = noise_slot(mesh, j, key)
                if h and slot then
                    -- 只记原贴图的路径,不碰原 holder(见文件头的实测约束)
                    row.orig_path = path_of(try(function() return mesh:call("getMaterialTexture", j, slot) end))
                    if row.orig_path then
                        row.slot = slot
                        try(function() mesh:call("setMaterialTexture", j, slot, h) end)
                    end
                end
            end
            for name in pairs(want) do
                local index = var_index(mesh, j, key, name)
                local cur = index and try(function() return mesh:call("getMaterialFloat4", j, index) end)
                if cur then
                    row.params[name] = { index = index, orig = { cur.x, cur.y, cur.z, cur.w } }
                    write_param(row, name)
                end
            end
            tx.rows[mkey] = row
            active[mkey] = row
            return true
        end,
        end_transaction = function(tx_id)
            local tx = txs[tx_id]
            if tx then
                for _, row in pairs(tx.rows) do restore(row) end
                txs[tx_id] = nil
            end
            return true
        end,
        reset_mesh = function(mesh)
            local mk = tostring(mesh) .. "_"
            for _, tx in pairs(txs) do
                for k, row in pairs(tx.rows) do
                    if k:sub(1, #mk) == mk then restore(row); tx.rows[k] = nil end
                end
            end
        end,
        reset = function()
            for _, tx in pairs(txs) do for _, row in pairs(tx.rows) do restore(row) end end
            txs, active = {}, {}
        end,
    }

    -- 调色盘在溶解期间改了样式也在改的参数:记成新的原值(结束时还原成它),样式的值重新写上
    function api.on_param_write(mesh, j, param, value)
        local row = active[tostring(mesh) .. "_" .. tostring(j)]
        local p = row and row.params[param]
        if not p or type(value) ~= "table" then return end
        p.orig = { value[1] or p.orig[1], value[2] or p.orig[2], value[3] or p.orig[3], value[4] or p.orig[4] }
        write_param(row, param)
    end

    function api.loaded_count()
        local n = 0
        for _, h in pairs(holders) do if h then n = n + 1 end end
        return n
    end

    return api
end

return Styles
