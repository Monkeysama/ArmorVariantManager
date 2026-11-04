-- 网格探针 (RE4) —— 独立诊断脚本,和差分管理器没有依赖关系,查完可以直接删。
--
-- 要回答的问题:里昂穿上防护衣之后,armor 槽位是**追加**上来的,还是把 body **整个换掉**?
-- 这决定差分管理器要怎么改:
--   * 追加  → 预设的材质匹配度只是被稀释(22/32 ≈ 0.69,仍高于 0.5 阈值),整套造型还能用,
--             要做的是让用户能给护甲单独配差分。
--   * 替换  → 匹配度会掉到 0.2 左右,**穿上防护衣的瞬间所有整套造型都会被判"材质不匹配"**,
--             那是个真 bug,得改匹配算法(按"两边都有的槽位"算,而不是四个槽位一起算)。
--
-- 两种用法:
--   1. 面板上实时看(REFramework → Script Generated UI → Mesh probe (RE4))
--   2. **自动记日志**:每帧比对一次"四个槽位的形状",一有变化就往 reframework 的 log 里写一行。
--      穿衣服那一瞬间不用盯着菜单也能抓到,事后翻 reframework.log 即可。
--
-- 和 HPDebug 一样的三条约束:只用局部变量(所有 autorun 共享同一个 Lua 状态)、
-- 绘制包 pcall、tree 栈自己收平(别把其他 mod 的界面带歪)。

local version = "0.1.0"

local SLOTS = { "body", "head", "hair", "armor" }
local GETTER = {
    body = "get_BodyMesh",
    head = "get_HeadMesh",
    hair = "get_HairMesh",
    armor = "get_ArmorMesh",
}

-- ---------- 引擎访问 ----------

local function player_context()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return nil end
    local ok, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
    if ok and ctx and sdk.is_managed_object(ctx) then return ctx end
    return nil
end

local function body_updater(ctx)
    if not ctx then return nil end
    local ok, bu = pcall(function() return ctx:call("get_BodyUpdater") end)
    if ok and bu and sdk.is_managed_object(bu) then return bu end
    return nil
end

local function call(obj, method, ...)
    if not obj then return nil end
    local args = { ... }
    local ok, v = pcall(function() return obj:call(method, table.unpack(args)) end)
    if ok then return v end
    return nil
end

-- 试一串可能的方法名,返回第一个读到布尔的。**不硬编码猜一个就完** ——
-- 组件的"开没开"在 RE 引擎里有好几个叫法,这里把实际存在的那个报出来比猜准。
local ENABLED_GETTERS = { "get_Enabled", "get_DrawEnable", "get_Visible", "get_Draw" }
local function enabled_of(mesh)
    for _, m in ipairs(ENABLED_GETTERS) do
        local v = call(mesh, m)
        if type(v) == "boolean" then return v, m end
    end
    return nil, nil
end

local function material_names(mesh)
    local out = {}
    local n = call(mesh, "get_MaterialNum")
    if type(n) ~= "number" or n <= 0 then return out end
    for i = 0, n - 1 do
        local name = call(mesh, "getMaterialName", i)
        local on = call(mesh, "getMaterialsEnable", i)
        table.insert(out, {
            index = i,
            name = (type(name) == "string") and name or ("<" .. tostring(name) .. ">"),
            enabled = on,
        })
    end
    return out
end

-- 一份"当前四个槽位长什么样"的快照
local function snapshot()
    local ctx = player_context()
    local bu = body_updater(ctx)
    if not bu then return nil end
    local snap = {
        has_armor = call(bu, "get_HasArmorMesh"),
        bu_type = nil,
        slots = {},
    }
    local ok, td = pcall(function() return bu:get_type_definition() end)
    if ok and td then
        local ok_n, n = pcall(function() return td:get_full_name() end)
        if ok_n then snap.bu_type = n end
    end
    for _, slot in ipairs(SLOTS) do
        local mesh = call(bu, GETTER[slot])
        if mesh and sdk.is_managed_object(mesh) then
            local en, en_method = enabled_of(mesh)
            local mats = material_names(mesh)
            snap.slots[slot] = {
                ptr = tostring(mesh),
                count = #mats,
                mats = mats,
                enabled = en,
                enabled_method = en_method,
            }
        else
            snap.slots[slot] = nil          -- 槽位不存在(读不到 mesh)
        end
    end
    return snap
end

-- 只含"形状"的指纹:槽位在不在、材质数、mesh 实例。用来判断有没有发生变化,
-- **不含材质的开关状态** —— 那个每帧都可能被差分管理器改,会把指纹刷成每帧都变。
local function fingerprint(snap)
    if not snap then return "no-character" end
    local parts = { "armor=" .. tostring(snap.has_armor) }
    for _, slot in ipairs(SLOTS) do
        local s = snap.slots[slot]
        table.insert(parts, slot .. "=" .. (s and (s.count .. "@" .. s.ptr) or "nil"))
    end
    return table.concat(parts, " ")
end

-- ---------- 自动记日志 ----------

local last_fp = nil
local log_lines = {}          -- 面板上也显示一份,免得非要去翻文件

local function note(line)
    pcall(function() log.info("[MeshProbe] " .. line) end)
    table.insert(log_lines, line)
    if #log_lines > 12 then table.remove(log_lines, 1) end
end

re.on_frame(function()
    local ok, snap = pcall(snapshot)
    if not ok then return end
    local fp = fingerprint(snap)
    if fp == last_fp then return end
    last_fp = fp
    note("CHANGED  " .. fp)
    -- 变化的那一刻把材质名也记下来:护甲的材质名就是这么拿到的
    if snap then
        for _, slot in ipairs(SLOTS) do
            local s = snap.slots[slot]
            if s and s.count > 0 then
                local names = {}
                for _, m in ipairs(s.mats) do table.insert(names, m.name) end
                note("  " .. slot .. " (" .. s.count .. "): " .. table.concat(names, ", "))
            end
        end
    end
end)

-- ---------- 界面 ----------

local last_error = nil
local tree_open = false

local function tree_pop()
    if tree_open then
        tree_open = false
        pcall(imgui.tree_pop)
    end
end

local function draw()
    local ok_tree, open = pcall(imgui.tree_node, "Mesh probe (RE4) v" .. version)
    if not ok_tree or not open then return end
    tree_open = true

    if last_error then imgui.text("draw error: " .. last_error) end

    local snap = snapshot()
    if not snap then
        imgui.text("No character / BodyUpdater")
        tree_pop()
        return
    end

    imgui.text("BodyUpdater: " .. tostring(snap.bu_type))
    imgui.text("get_HasArmorMesh(): " .. tostring(snap.has_armor))
    imgui.separator()

    for _, slot in ipairs(SLOTS) do
        local s = snap.slots[slot]
        if not s then
            imgui.text(string.format("%-6s  <no mesh>", slot))
        else
            imgui.text(string.format("%-6s  %d materials   enabled=%s (%s)   %s",
                slot, s.count, tostring(s.enabled), tostring(s.enabled_method), s.ptr))
            if imgui.tree_node("materials###mp_" .. slot) then
                for _, m in ipairs(s.mats) do
                    imgui.text(string.format("   [%d] %-24s on=%s", m.index, m.name, tostring(m.enabled)))
                end
                imgui.tree_pop()
            end
        end
    end

    imgui.separator()
    imgui.text("Change log (also in reframework.log):")
    if #log_lines == 0 then
        imgui.text("  (nothing yet - it logs when the mesh layout changes)")
    else
        for _, l in ipairs(log_lines) do imgui.text("  " .. l) end
    end

    tree_pop()
end

re.on_draw_ui(function()
    local ok, err = pcall(draw)
    if ok then
        last_error = nil
    else
        local msg = tostring(err)
        if last_error ~= msg then pcall(function() log.error("[MeshProbe] " .. msg) end) end
        last_error = msg
    end
    tree_pop()
end)
