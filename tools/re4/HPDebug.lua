-- HP 调试 (RE4) —— 独立脚本,和差分管理器没有任何依赖关系,单独删掉也不影响它。
--
-- 由来:原本是「条件判断」面板里的一个改血输入框,用来回答"血量等级(getHitPointVital)
-- 在百分之几翻档""只剩 1 点血时是哪一档"。那个面板已经移除(见 tools/re4/README.md),
-- 但扫阈值这件事随时还会再做,所以单独拆成一个工具。
--
-- 三条设计约束:
--   * **只用局部变量**。REFramework 的所有 autorun 脚本共享同一个 Lua 状态,
--     写全局就等于往别人家里放东西,重名了很难查。
--   * **绝不做滑条**。拖动过程中会连续写 HP,一路扫过濒死/死亡阈值,
--     把要观察的现象自己搅掉。要扫就用 ±1 / ±10 一格一格走。
--   * **imgui 的 tree 栈要收平**。tree 栈是整个进程共享的,绘制中途抛错会把
--     其他 mod 的界面一起搞乱,而用户只会觉得"装了这个之后菜单全乱了"。

local version = "0.1.0"

-- ---------- 文案 ----------

local lang = "en"
local L = {
    zh = {
        title = "HP 调试 (RE4)",
        no_character = "未找到当前控制角色",
        no_hitpoint = "读不到 HitPoint",
        cur = "当前 HP",
        max = "上限 HP",
        ratio = "百分比",
        vital = "血量等级",
        declared = "引擎声明的全部档位",
        set_to = "写入 HP",
        apply = "写入",
        full = "满血",
        one = "只剩 1 点",
        zero = "归零(会死)",
        zero_confirm = "确认归零?",
        cancel = "取消",
        hint = "扫阈值用 +/-1 / +/-10 一格一格走 —— 刻意不做滑条,连续写血会把要观察的档位跳变冲掉。",
        draw_error = "界面绘制出错(已保护,不影响其他 mod):",
    },
    en = {
        title = "HP debug (RE4)",
        no_character = "No controlled character found",
        no_hitpoint = "HitPoint not readable",
        cur = "Current HP",
        max = "Max HP",
        ratio = "Percent",
        vital = "Vital tier",
        declared = "All tiers declared by the engine",
        set_to = "Set HP",
        apply = "Apply",
        full = "Full",
        one = "Down to 1",
        zero = "Zero (kills you)",
        zero_confirm = "Confirm zero?",
        cancel = "Cancel",
        hint = "Scan thresholds with +/-1 and +/-10. No slider on purpose: dragging writes HP every frame and blows past the tier changes you are trying to see.",
        draw_error = "UI draw error (contained, other mods unaffected):",
    },
}
local function T(key)
    return (L[lang] or L.en)[key] or key
end

-- ---------- 引擎访问 ----------

local function player_context()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return nil end
    local ok, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
    if ok and ctx and sdk.is_managed_object(ctx) then return ctx end
    return nil
end

local function hitpoint(ctx)
    if not ctx then return nil end
    local ok, hp = pcall(function() return ctx:call("get_HitPoint") end)
    if ok and hp and sdk.is_managed_object(hp) then return hp end
    return nil
end

local function num(obj, method)
    if not obj then return nil end
    local ok, v = pcall(function() return obj:call(method) end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- 血量等级的名字。运行时 sdk 给的是裸整数,名字得反射枚举的静态字段查回来;
-- 枚举类型名从**方法的返回类型**上问,不硬编码 —— 硬编码猜过一次,查出来是空表。
local vital_map, vital_listed = nil, nil
local function build_vital_map(ctx)
    if vital_map then return end
    vital_map, vital_listed = {}, {}
    local td = nil
    local ok, t = pcall(function() return ctx:get_type_definition() end)
    if ok then td = t end
    local m = nil
    while td and not m do
        local ok_m, found = pcall(function() return td:get_method("getHitPointVital") end)
        if ok_m and found then m = found; break end
        local ok_p, parent = pcall(function() return td:get_parent_type() end)
        if not ok_p then break end
        td = parent
    end
    if not m then return end
    local ok_rt, rt = pcall(function() return m:get_return_type() end)
    if not ok_rt or not rt then return end
    local ok_n, name = pcall(function() return rt:get_full_name() end)
    if not ok_n or not name then return end
    local etd = sdk.find_type_definition(name)
    if not etd then return end
    local ok_f, fields = pcall(function() return etd:get_fields() end)
    if not ok_f or not fields then return end
    for _, f in ipairs(fields) do
        local ok_s, is_static = pcall(function() return f:is_static() end)
        if ok_s and is_static then
            local ok_v, v = pcall(function() return f:get_data(nil) end)
            if ok_v and type(v) == "number" then
                vital_map[v] = f:get_name()
                table.insert(vital_listed, { value = v, name = f:get_name() })
            end
        end
    end
    table.sort(vital_listed, function(a, b) return a.value < b.value end)
end

local function vital_text(ctx)
    local v = num(ctx, "getHitPointVital")
    if not v then return nil end
    build_vital_map(ctx)
    local n = vital_map and vital_map[v]
    return n and (n .. " (" .. v .. ")") or tostring(v)
end

local function declared_text(ctx)
    build_vital_map(ctx)
    if not vital_listed or #vital_listed == 0 then return nil end
    local parts = {}
    for _, e in ipairs(vital_listed) do
        table.insert(parts, e.name .. "=" .. e.value)
    end
    return table.concat(parts, "  ")
end

local function write_hp(hp, value, max)
    if not hp then return end
    local v = math.floor(value)
    if v < 0 then v = 0 end
    if max and v > max then v = max end
    pcall(function() hp:call("set_CurrentHitPoint", v) end)
end

-- ---------- 界面 ----------

local input_buf = "1"
local pending_zero = false
local last_error = nil
local tree_open = false

local function tree_pop()
    if tree_open then
        tree_open = false
        pcall(imgui.tree_pop)
    end
end

local function draw()
    local ok_tree, open = pcall(imgui.tree_node, T("title") .. " v" .. version)
    if not ok_tree or not open then return end
    tree_open = true

    local ch_lang, want_zh = imgui.checkbox("中文###hpdbg_lang", lang == "zh")
    if ch_lang then lang = want_zh and "zh" or "en" end

    if last_error then imgui.text(T("draw_error") .. " " .. last_error) end

    local ctx = player_context()
    if not ctx then
        imgui.text(T("no_character"))
        tree_pop()
        return
    end
    local hp = hitpoint(ctx)
    if not hp then
        imgui.text(T("no_hitpoint"))
        tree_pop()
        return
    end

    local cur = num(hp, "get_CurrentHitPoint")
    local max = num(hp, "get_DefaultHitPoint")
    local ratio = num(hp, "get_HitPointRatio")

    imgui.text(string.format("%s: %s / %s   (%s: %s)",
        T("cur"), tostring(cur or "?"), tostring(max or "?"),
        T("ratio"), ratio and string.format("%.1f%%", ratio * 100) or "?"))
    imgui.text(string.format("%s: %s", T("vital"), vital_text(ctx) or "?"))
    local declared = declared_text(ctx)
    if declared then
        imgui.text(string.format("%s: %s", T("declared"), declared))
    end

    imgui.separator()

    -- 一格一格走。数值按钮排一行,标签短到能并排放下
    local steps = { -10, -1, 1, 10 }
    for i, d in ipairs(steps) do
        if i > 1 then imgui.same_line() end
        local label = (d > 0) and ("+" .. d) or tostring(d)
        if imgui.button(label .. "###hpdbg_step" .. i) and cur then
            write_hp(hp, cur + d, max)
        end
    end

    if imgui.button(T("full") .. "###hpdbg_full") and max then write_hp(hp, max, max) end
    imgui.same_line()
    if imgui.button(T("one") .. "###hpdbg_one") then write_hp(hp, 1, max) end
    imgui.same_line()
    -- 归零要二次确认:它紧挨着其他按钮,而误点的代价是直接死一次
    if pending_zero then
        if imgui.button(T("zero_confirm") .. "###hpdbg_zero_ok") then
            write_hp(hp, 0, max)
            pending_zero = false
        end
        imgui.same_line()
        if imgui.button(T("cancel") .. "###hpdbg_zero_no") then pending_zero = false end
    else
        if imgui.button(T("zero") .. "###hpdbg_zero") then pending_zero = true end
    end

    local ch_in, nv = imgui.input_text(T("set_to") .. "###hpdbg_input", input_buf)
    if ch_in then input_buf = nv end
    imgui.same_line()
    if imgui.button(T("apply") .. "###hpdbg_apply") then
        local n = tonumber(input_buf)
        if n then write_hp(hp, n, max) end
    end

    imgui.text(T("hint"))
    tree_pop()
end

re.on_draw_ui(function()
    -- 绘制必须包 pcall,出错时把欠的那一层 tree_pop 补回去 —— 否则会把**其他 mod**
    -- 的界面一起搞乱(tree 栈是整个进程共享的)。只在自己确实开着的时候 pop:
    -- 没开也 pop 是反方向的同一个 bug。
    local ok, err = pcall(draw)
    if ok then
        last_error = nil
    else
        local msg = tostring(err)
        if last_error ~= msg then
            pcall(function() log.error("[HPDebug] " .. msg) end)
        end
        last_error = msg
    end
    tree_pop()
end)
