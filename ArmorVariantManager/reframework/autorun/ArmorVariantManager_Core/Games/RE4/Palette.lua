-- 调色盘:按材质映射(PaletteProfiles.lua + data 目录里的 JSON)显示和修改材质参数。
--
--   映射只决定界面(分组、含义、拆开的分量、注释);用户调的值存在角色配置里:
--     cfg.palette = { [slot] = { [材质名] = { [参数名] = 数值 | { x =, y =, z =, w = } } } }
--   float 参数存数值;float4 只存改过的分量(稀疏表),没改的分量保持材质当前的值。
--   所以改动或删除映射不会丢掉已调的值。
--
--   识别按参数名:一份主映射(match 命中、priority 最高)+ 所有命中的附加映射(addon)。
--   都不命中时用 generic:列出名字以 Color 结尾的 float4。
--
--   写入:应用循环在材质开关重写的同一时机调用 apply。第一次写某个参数前记下它的原值
--   (按 mesh 实例),取消覆盖时把原值写回。mesh 换实例(换装、读档)后原值重新记。
local Palette = {}

Palette.FORMAT = 1
Palette.COMPONENTS = { "x", "y", "z", "w" }
local COMP_INDEX = { x = 1, y = 2, z = 3, w = 4 }
Palette.TYPE_FLOAT, Palette.TYPE_FLOAT4 = 1, 4
local KINDS = { color = true, float = true, enum = true, bool = true, vec = true }

local function is_tbl(v) return type(v) == "table" end
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- ============================================================ 映射
-- 只留格式对的部分;不合格的项丢掉而不是让整份映射失效
local function clean_profile(p)
    if not is_tbl(p) or type(p.id) ~= "string" or p.id == "" or not is_tbl(p.groups) then return nil end
    local match = is_tbl(p.match) and p.match or {}
    local function names(list)
        local out = {}
        for _, n in ipairs(is_tbl(list) and list or {}) do if type(n) == "string" then out[#out + 1] = n end end
        return out
    end
    local out = {
        id = p.id, label = is_tbl(p.label) and p.label or { zh = p.id, en = p.id },
        addon = p.addon == true, priority = tonumber(p.priority) or 0,
        -- master:按离线材质库认出的母材质(mmtr 路径)匹配,给自动生成的原版母材质映射用
        match = { all = names(match.all), any = names(match.any), none = names(match.none),
                  master = names(type(match.master) == "string" and { match.master } or match.master) },
        enums = is_tbl(p.enums) and p.enums or {}, ignore = names(p.ignore), groups = {},
    }
    if #out.match.all == 0 and #out.match.any == 0 and #out.match.master == 0 then return nil end
    for _, g in ipairs(p.groups) do
        if is_tbl(g) and type(g.id) == "string" and is_tbl(g.params) then
            local params = {}
            for _, e in ipairs(g.params) do
                if is_tbl(e) and type(e.param) == "string" and KINDS[e.kind] then
                    local comp = e.component
                    local needs_comp = e.kind == "float" or e.kind == "enum" or e.kind == "bool"
                    if not needs_comp or comp == nil or COMP_INDEX[comp] then params[#params + 1] = e end
                end
            end
            if #params > 0 then
                out.groups[#out.groups + 1] = { id = g.id, label = g.label, note = g.note,
                    -- other:含义只能按参数名推断、可能不准的项,单独放在基本 / 进阶之外
                    tier = (g.tier == "more" or g.tier == "other") and g.tier or "basic", params = params,
                    section = type(g.section) == "string" and g.section or nil }
            end
        end
    end
    -- 类别(界面上把同类的组放在一起,例如主色 / 第二层 / 第三层都是「颜色层」);顺序即显示顺序
    out.sections = {}
    for _, s in ipairs(is_tbl(p.sections) and p.sections or {}) do
        if is_tbl(s) and type(s.id) == "string" then out.sections[#out.sections + 1] = { id = s.id, label = s.label } end
    end
    return out
end
Palette.clean_profile = clean_profile

-- builtin:PaletteProfiles 的列表;extras:data 目录读到的表(同 id 覆盖内置)。返回按 priority 从高到低
function Palette.load_profiles(builtin, extras)
    local by_id, order = {}, {}
    local function add(p, source)
        local c = clean_profile(p)
        if not c then return end
        c.source = source
        if not by_id[c.id] then order[#order + 1] = c.id end
        by_id[c.id] = c
    end
    for _, p in ipairs(is_tbl(builtin) and builtin or {}) do add(p, "builtin") end
    for _, p in ipairs(is_tbl(extras) and extras or {}) do add(p, "data") end
    local list = {}
    for i, id in ipairs(order) do list[#list + 1] = { p = by_id[id], i = i } end
    table.sort(list, function(a, b)
        if a.p.priority ~= b.p.priority then return a.p.priority > b.p.priority end
        return a.i < b.i
    end)
    local out = {}
    for _, x in ipairs(list) do out[#out + 1] = x.p end
    return out, by_id
end

local function matches(p, has, master)
    if #p.match.master > 0 then
        local hit = false
        for _, id in ipairs(p.match.master) do if id == master then hit = true; break end end
        if not hit then return false end
    end
    for _, n in ipairs(p.match.all) do if not has[n] then return false end end
    if #p.match.any > 0 then
        local any = false
        for _, n in ipairs(p.match.any) do if has[n] then any = true; break end end
        if not any then return false end
    end
    for _, n in ipairs(p.match.none) do if has[n] then return false end end
    return true
end

-- has = { [参数名] = 类型 },master = 认出的母材质 id(可为 nil)。返回 main(可能 nil)、addons 列表
function Palette.match(profiles, has, master)
    local main, addons = nil, {}
    for _, p in ipairs(profiles) do
        if matches(p, has, master) then
            if p.addon then addons[#addons + 1] = p elseif not main then main = p end
        end
    end
    return main, addons
end

-- 一个映射项在这个材质上能不能用:参数存在,类型对得上(分量 / 颜色 / vec 要 float4)
function Palette.entry_usable(e, has)
    local t = has[e.param]
    if not t then return false end
    if e.kind == "color" or e.kind == "vec" or e.component then return t == Palette.TYPE_FLOAT4 end
    return t == Palette.TYPE_FLOAT
end

-- 没被任何主映射认出来时:名字以 Color 结尾的 float4,按名字排序
function Palette.generic(has)
    local names = {}
    for n, t in pairs(has) do
        if t == Palette.TYPE_FLOAT4 and n:match("Color$") then names[#names + 1] = n end
    end
    table.sort(names)
    return names
end

-- ============================================================ 配置
-- cfg.palette 清洗:只留 { slot = { mat = { param = number | {x..w 的数值} } } }
function Palette.clean(pal)
    local out = {}
    for slot, mats in pairs(is_tbl(pal) and pal or {}) do
        if type(slot) == "string" and is_tbl(mats) then
            local ms = {}
            for mat, params in pairs(mats) do
                if type(mat) == "string" and is_tbl(params) then
                    local ps = {}
                    for name, v in pairs(params) do
                        if type(name) == "string" then
                            if finite(v) then ps[name] = v
                            elseif is_tbl(v) then
                                local c = {}
                                for _, k in ipairs(Palette.COMPONENTS) do if finite(v[k]) then c[k] = v[k] end end
                                if next(c) then ps[name] = c end
                            end
                        end
                    end
                    if next(ps) then ms[mat] = ps end
                end
            end
            if next(ms) then out[slot] = ms end
        end
    end
    return out
end

-- 一次写入:{ slot, material, param, component = "x".."w" | nil, value = 数值 }
-- component 为 nil 表示 float 参数。返回 changed
local function round(v) return math.floor(v * 1e5 + 0.5) / 1e5 end
function Palette.set(cfg, w)
    if not is_tbl(w) or type(w.slot) ~= "string" or type(w.material) ~= "string" or type(w.param) ~= "string" then return false end
    local v = tonumber(w.value)
    if not finite(v) then return false end
    v = round(v)
    if w.component ~= nil and not COMP_INDEX[w.component] then return false end
    cfg.palette = is_tbl(cfg.palette) and cfg.palette or {}
    local slot = cfg.palette[w.slot] or {}
    local mat = slot[w.material] or {}
    local cur = mat[w.param]
    if w.component == nil then
        if cur == v then return false end
        mat[w.param] = v
    else
        local t = is_tbl(cur) and cur or {}
        if t[w.component] == v then return false end
        t[w.component] = v
        mat[w.param] = t
    end
    slot[w.material], cfg.palette[w.slot] = mat, slot
    return true
end

-- 取消覆盖:param 为 nil = 这个材质的全部;component 为 nil = 这个参数的全部分量
function Palette.reset(cfg, slot, material, param, component)
    local pal = is_tbl(cfg.palette) and cfg.palette or nil
    local mats = pal and pal[slot]
    local params = mats and mats[material]
    if not params then return false end
    if param == nil then
        mats[material] = nil
    else
        local cur = params[param]
        if cur == nil then return false end
        if component ~= nil and is_tbl(cur) then
            if cur[component] == nil then return false end
            cur[component] = nil
            if next(cur) == nil then params[param] = nil end
        else
            params[param] = nil
        end
        if next(params) == nil then mats[material] = nil end
    end
    if next(mats) == nil then pal[slot] = nil end
    return true
end

-- ============================================================ 引擎读写
-- 参数表:{ [参数名] = { k = 序号, t = 类型 } },按 mesh_材质序号 缓存(mesh 换实例就是新键)
local function try(f) local ok, r = pcall(f); if ok then return r end; return nil end

-- 版本号:每次真的往 mesh 上写了调色值(或还原)就加一。全身预览的显示副本只在建副本时
-- 抄一次原网格的材质参数,之后靠比较这个数字知道要不要重新抄(Palette.revision())。
local revision = 0
function Palette.revision() return revision end

function Palette.read_vars(mesh, j)
    local vars = {}
    local n = try(function() return mesh:call("getMaterialVariableNum", j) end) or 0
    for k = 0, n - 1 do
        local name = try(function() return mesh:call("getMaterialVariableName", j, k) end)
        local t = try(function() return mesh:call("getMaterialVariableType", j, k) end)
        if type(name) == "string" and (t == Palette.TYPE_FLOAT or t == Palette.TYPE_FLOAT4) then vars[name] = { k = k, t = t } end
    end
    return vars
end

function Palette.read_value(mesh, j, var)
    if var.t == Palette.TYPE_FLOAT then return try(function() return mesh:call("getMaterialFloat", j, var.k) end) end
    local v = try(function() return mesh:call("getMaterialFloat4", j, var.k) end)
    return v and { v.x, v.y, v.z, v.w } or nil
end

local function write_value(mesh, j, var, value)
    revision = revision + 1
    if var.t == Palette.TYPE_FLOAT then
        mesh:call("setMaterialFloat", j, var.k, value)
    else
        mesh:call("setMaterialFloat4", j, var.k, Vector4f.new(value[1], value[2], value[3], value[4]))
    end
end

-- 每个目标一份状态:{ [mesh 键] = { vars = { [j] = 参数表 }, orig = { ["j|参数"] = 原值 }, touched = { ["j|参数"] = { 分量集合 | true } } } }
-- slot_overrides = cfg.palette[slot];on_write(mesh, j, param, value) 可选(溶解用来同步 Dissolve_Flag 的底值)
function Palette.apply_mesh(mesh, slot_overrides, state, on_write)
    local key = tostring(mesh)
    local st = state[key]
    if not st then st = { vars = {}, orig = {}, touched = {} }; state[key] = st end
    local count = try(function() return mesh:call("get_MaterialNum") end) or 0
    local overrides = is_tbl(slot_overrides) and slot_overrides or {}
    for j = 0, count - 1 do
        local name = try(function() return mesh:call("getMaterialName", j) end)
        local ov = name and overrides[name]
        local prefix = j .. "|"
        local any_touched = false
        for tk in pairs(st.touched) do if tk:sub(1, #prefix) == prefix then any_touched = true; break end end
        if ov or any_touched then
            st.vars[j] = st.vars[j] or Palette.read_vars(mesh, j)
            local vars = st.vars[j]
            -- 这次要写的参数:覆盖里有的 + 上次写过的(要还原的)
            local params = {}
            for p in pairs(ov or {}) do params[p] = true end
            for tk in pairs(st.touched) do
                if tk:sub(1, #prefix) == prefix then params[tk:sub(#prefix + 1)] = true end
            end
            for p in pairs(params) do
                local var = vars[p]
                local tk = prefix .. p
                if var then
                    local want = ov and ov[p]
                    if st.orig[tk] == nil then st.orig[tk] = Palette.read_value(mesh, j, var) end
                    local orig = st.orig[tk]
                    if var.t == Palette.TYPE_FLOAT then
                        local v = finite(want) and want or orig
                        if v ~= nil then
                            write_value(mesh, j, var, v)
                            if on_write then on_write(mesh, j, p, v) end
                        end
                        st.touched[tk] = finite(want) and true or nil
                    elseif orig then
                        -- 只动改过的分量和要还原的分量;其余分量保持当前值(可能正被溶解动画写着)
                        local cur = Palette.read_value(mesh, j, var) or orig
                        local comps = is_tbl(want) and want or {}
                        local prev = is_tbl(st.touched[tk]) and st.touched[tk] or {}
                        local out, now = { cur[1], cur[2], cur[3], cur[4] }, {}
                        for c, i in pairs(COMP_INDEX) do
                            if finite(comps[c]) then out[i] = comps[c]; now[c] = true
                            elseif prev[c] then out[i] = orig[i] end
                        end
                        write_value(mesh, j, var, out)
                        if on_write then on_write(mesh, j, p, out) end
                        st.touched[tk] = next(now) and now or nil
                    end
                    if not st.touched[tk] then st.orig[tk] = nil end
                else
                    st.touched[tk] = nil
                end
            end
        end
    end
end

-- 只保留当前还在的 mesh 的状态(换装后的旧 mesh 不再还原:它已经不显示了)
function Palette.prune(state, live)
    for key in pairs(state) do if not live[key] then state[key] = nil end end
end

-- ============================================================ 默认贴图导致的失效
-- 材质的某个贴图槽绑的是游戏内置的 null 贴图(纯黑、某通道为 0……)时,和它相乘 / 被它遮罩的参数改了也看不出变化。
-- 规则来自离线材质库(MaterialEffects.lua,由 tools/re4/gen_material_effects.py 生成);母材质按签名认
-- (参数个数 + 贴图槽名集合),认不出来就不判断。

-- 贴图路径规范化:小写、正斜杠、去掉 natives/stm/ 前缀和 .tex(.版本号) 后缀,和材质库的写法一致
function Palette.norm_texture(path)
    if type(path) ~= "string" or path == "" then return nil end
    local p = path:gsub("\\", "/"):lower():gsub("^natives/stm/", "")
    p = p:gsub("%.tex%.%d+$", ""):gsub("%.tex$", "")
    return p
end

-- 一个材质各贴图槽现在用的贴图:{ [槽名] = 规范化路径 }
function Palette.read_textures(mesh, j)
    local out = {}
    local n = try(function() return mesh:call("getMaterialTextureNum", j) end) or 0
    for t = 0, n - 1 do
        local name = try(function() return mesh:call("getMaterialTextureName", j, t) end)
        local holder = try(function() return mesh:call("getMaterialTexture", j, t) end)
        local path = holder and try(function() return holder:call("get_ResourcePath") end)
        if type(name) == "string" then out[name] = Palette.norm_texture(path) or false end
    end
    return out
end

local function signature(params, names)
    local list = {}
    for _, n in ipairs(names) do list[#list + 1] = n end
    table.sort(list)
    return tostring(params) .. "|" .. table.concat(list, ",")
end

-- effects = MaterialEffects 模块。返回查询用的索引(建一次就行)
function Palette.effects_index(effects)
    local index = { nulls = {}, by_sig = {}, by_tex = {} }
    for i, path in ipairs(is_tbl(effects) and is_tbl(effects.nulls) and effects.nulls or {}) do index.nulls[path] = i end
    for _, m in ipairs(is_tbl(effects) and is_tbl(effects.masters) and effects.masters or {}) do
        if is_tbl(m.textures) and is_tbl(m.rules) then
            index.by_sig[signature(m.params, m.textures)] = m
            local tex_key = signature("", m.textures)
            index.by_tex[tex_key] = index.by_tex[tex_key] == nil and m or false   -- 只按贴图槽认时,撞了就不认
        end
    end
    return index
end

-- nparams = getMaterialVariableNum,textures = read_textures 的结果。先按完整签名找,再只按贴图槽名找
function Palette.find_master(index, nparams, textures)
    if not index then return nil end
    local names = {}
    for n in pairs(textures or {}) do names[#names + 1] = n end
    if #names == 0 then return nil end
    return index.by_sig[signature(nparams, names)] or index.by_tex[signature("", names)] or nil
end

-- 返回 { [参数名] = { comps = "xyz", why = { { texture = 槽名, null = 路径 }, ... } } };没有失效项时返回 nil
function Palette.ineffective(index, master, textures)
    if not (index and master and textures) then return nil end
    local out, any = {}, false
    for _, r in ipairs(master.rules) do
        local param, comps, slot, nulls = r[1], r[2], r[3], r[4]
        local path = textures[slot]
        local id = path and index.nulls[path]
        local hit = false
        if id then
            if nulls == "*" then hit = true
            else for _, k in ipairs(nulls) do if k == id then hit = true; break end end end
        end
        if hit then
            local e = out[param] or { comps = "", why = {} }
            for ch in comps:gmatch("[xyzw]") do if not e.comps:find(ch, 1, true) then e.comps = e.comps .. ch end end
            local seen = false
            for _, w in ipairs(e.why) do if w.texture == slot then seen = true; break end end
            if not seen then e.why[#e.why + 1] = { texture = slot, null = path } end
            out[param], any = e, true
        end
    end
    if not any then return nil end
    for _, e in pairs(out) do
        local sorted = {}
        for _, ch in ipairs(Palette.COMPONENTS) do if e.comps:find(ch, 1, true) then sorted[#sorted + 1] = ch end end
        e.comps = table.concat(sorted)
    end
    return out
end

-- ============================================================ 导出参数清单
-- 选中一个材质,列出全部参数名、类型、当前值,写成映射草稿(含义留给作者填)
function Palette.draft(mesh, j)
    local vars = Palette.read_vars(mesh, j)
    local names = {}
    for n in pairs(vars) do names[#names + 1] = n end
    table.sort(names, function(a, b) return vars[a].k < vars[b].k end)
    local params = {}
    for _, n in ipairs(names) do
        local var = vars[n]
        local v = Palette.read_value(mesh, j, var)
        if var.t == Palette.TYPE_FLOAT then
            params[#params + 1] = { param = n, kind = "float", label = { zh = n, en = n }, current = v }
        else
            params[#params + 1] = { param = n, kind = n:match("Color$") and "color" or "vec", channels = n:match("Color$") and "rgb" or nil,
                label = { zh = n, en = n }, current = v }
        end
    end
    local material = try(function() return mesh:call("getMaterialName", j) end) or "material"
    return {
        format = Palette.FORMAT, id = "draft_" .. material, label = { zh = material, en = material }, priority = 50,
        match = { all = {} }, groups = { { id = "all", tier = "basic", label = { zh = "全部参数", en = "All parameters" }, params = params } },
    }
end

return Palette
