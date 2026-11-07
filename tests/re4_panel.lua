-- RE4 独立面板(没有 REFF 时的兜底界面,Games/RE4/Panel):用假的 ImGui 和一份覆盖各种情况的快照,
-- 逐页把每个可点的地方都点一遍(点开折叠、进入确认、再确认……),检查:
--   * 绘制不报错(页面错误会被面板吞掉并记日志,这里把日志当失败)
--   * 发出去的操作都是 Reff 控制器认识的 kind,且带着当前角色
--   * 关键流程:切页进出调色页会开 / 关调色数据,换角色、语言切换、窗口拖动后保存位置
-- 另外用真实的 Reff 控制器跑一遍(tests/re4_entrypoint.lua 的 REFF 场景已覆盖控制器本身)。
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path

local warnings = {}
_G.log = { warn = function(m) warnings[#warnings + 1] = m end, info = function() end }

-- ---------------------------------------------------------------- 假 ImGui
local mouse = { x = -1, y = -1, down = false }
local draw_calls = 0
local dl = setmetatable({}, { __index = function() return function() draw_calls = draw_calls + 1 end end })
local inputs = {}
_G.Vector2f = { new = function(x, y) return { x = x, y = y } end }
_G.Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
_G.imgui = {
    get_background_draw_list = function() return dl end,
    calc_text_size = function(s) return { x = utf8.len(s) * 7, y = 14 } end,
    get_display_size = function() return { x = 1920, y = 1080 } end,
    get_mouse = function() return { x = mouse.x, y = mouse.y } end,
    is_mouse_down = function() return mouse.down end,
    is_window_hovered = function() return false end,
    push_font_size = function() end, pop_font_size = function() end,
    push_style_var = function() end, pop_style_var = function() end,
    push_style_color = function() end, pop_style_color = function() end,
    set_next_window_pos = function() end, set_next_window_size = function() end,
    begin_window = function() return true end, end_window = function() end,
    push_item_width = function() end, pop_item_width = function() end,
    input_text = function(id, text) inputs[id] = text; return false, text end,
    is_item_active = function() return false end,
}
_G.sdk = { get_native_singleton = function() return nil end, find_type_definition = function() return nil end }
local keys = {}
-- 点遍测试里鼠标是瞬移的,系统光标不在中心、没有被钉住,直接用它;虚拟光标另有专门的用例
_G.reframework = { is_drawing_ui = function() return true end, is_key_down = function(_, vk) return keys[vk] == true end }

-- ---------------------------------------------------------------- 快照夹具
local function fixture(character, version)
    local snap = {
        game = "RE4", version = "test", language = "zh", character = character or "leon",
        settings = { weaponHideStorage = false, uiDissolveEnabled = true, uiDissolveTime = 1, blockGameMouse = true, heightEnabled = false },
        characters = {
            { id = "leon", label = "里昂", configured = true, targets = { "玩家", "过场" } },
            { id = "ada", label = "艾达", configured = false, targets = {} },
        },
        configVersion = version or 3,
    }
    if character == "" then snap.characters = {}; snap.configVersion = nil; return snap end
    if snap.configVersion ~= 3 then return snap end
    snap.status = { hp = 25.5, flags = { "战斗中", "瞄准" } }
    snap.conditions = {
        { id = "hp_ratio", kind = "number", label = "HP %", category = "hp", ops = { "<=", "<", ">=", ">", "==" }, value = 25.5 },
        { id = "hp_vital", kind = "enum", label = "血量等级", category = "hp", ops = { "==", "~=" },
            options = { { value = 0, label = "良好" }, { value = 1, label = "危险" } }, value = 1 },
        { id = "is_battle", kind = "bool", label = "战斗中", category = "combat", value = true },
        { id = "is_crouch", kind = "bool", label = "蹲下", category = "move", value = false },
    }
    snap.auto = true
    snap.armorMirror = true
    snap.slots = {
        { id = "body", label = "身体 (body / 00)", mirrored = false, materials = { { name = "Skin" }, { name = "Jacket", note = "夹克" }, { name = "Belt" } } },
        { id = "hair", label = "头发 (hair / 20)", mirrored = false, materials = { { name = "Hair" } } },
        { id = "armor", label = "护甲", mirrored = true, materials = { { name = "Vest" } } },
    }
    snap.look = { { slot = "body", material = "Skin", on = true }, { slot = "body", material = "Jacket", on = false },
        { slot = "hair", material = "Hair", on = true } }
    snap.locating = { slot = "body", material = "Belt" }
    snap.base = { active = "日常", effective = "战斗", fromState = 2, presets = {
        { name = "日常", values = { ["body/Skin"] = true, ["body/Jacket"] = true }, match = { status = "ok", skipped = {} }, height = 3 },
        { name = "战斗", values = { ["body/Skin"] = true }, match = { status = "partial", skipped = { "头发" } } },
        { name = "旧的", values = {}, match = { status = "mismatch", skipped = {} } },
    } }
    snap.groups = {
        { name = "外套", active = "穿", options = {
            { name = "穿", values = { ["body/Jacket"] = true } }, { name = "脱", values = { ["body/Jacket"] = false }, height = -2 } } },
        { name = "破损", active = "", effective = "破", fromState = 1, options = {
            { name = "破", values = { ["body/Jacket"] = false } } } },
        { name = "空组", active = "", options = {} },
    }
    snap.states = {
        { name = "低血量", enabled = true, exclusive = true, logic = "AND", hold = 0, fadeIn = 0.5, fadeOut = 1, kind = "active", holding = true,
            hp = { upper = 60, lower = 10, invert = false }, targets = { { group = "破损", option = "破", result = { kind = "win" } } }, conditions = {} },
        { name = "战斗", enabled = true, exclusive = false, logic = "OR", hold = 2, fadeIn = 0, fadeOut = 0, kind = "outranked", by = 1, holding = false,
            base = "战斗", baseResult = { kind = "win" },
            targets = { { group = "外套", option = "脱", result = { kind = "lose", by = 1 } }, { group = "已删", option = "x", result = { kind = "broken" } } },
            conditions = {
                { type = "is_battle", value = true, label = "战斗中", known = true, met = true },
                { type = "hp_ratio", op = "<=", value = 50, label = "HP %", known = true, met = true },
                { type = "hp_vital", op = "~=", value = 0, label = "血量等级", known = true, valueLabel = "良好" },
                { type = "gone", value = true, label = "gone", known = false },
            } },
        { name = "停用的", enabled = false, exclusive = false, logic = "AND", hold = 0, fadeIn = 0, fadeOut = 0, kind = "off", holding = false,
            base = "不存在", baseResult = { kind = "broken" }, targets = {}, conditions = {} },
    }
    snap.height, snap.heightSource = 3, { layer = "外套", option = "脱" }
    snap.heightOverride = { enabled = false, cm = 0 }
    snap.presets = { current = "partial", source = { id = "p1", name = "我的", own = true }, dismissed = false,
        list = { { id = "p1", name = "我的", source = "user", match = "partial" }, { id = "p2", name = "模组", source = "mod", match = "full" },
            { id = "p3", name = "别人", source = "user", match = "none" } },
        better = { { id = "p2", name = "模组" } }, autosaves = { { name = "自动 1", time = 1700000000 } } }
    snap.backups = { hasBackup = true, hasOnload = false }
    return snap
end

local function palette()
    return {
        materials = {
            { key = "body/Skin", slot = "body", material = "Skin", main = "lil", addons = { "extra" }, missing = { "Gone" }, overridden = 2, replace = "ok",
                ineffective = { Emission = { comps = "xyz", why = { { texture = "EmissionMap", null = "sys/null_black.tex" } } } } },
            { key = "body/Jacket", slot = "body", material = "Jacket", note = "夹克", addons = {}, missing = {}, generic = { "BaseColor" }, overridden = 0 },
            { key = "hair/Hair", slot = "hair", material = "Hair", main = "lil", addons = {}, missing = {}, overridden = 0, replace = "packed" },
        },
        profiles = {
            lil = { id = "lil", label = { zh = "lilToon" }, addon = false, enums = { blend = { { value = 0, label = { zh = "正常" } }, { value = 1, label = { zh = "相加" } } } },
                sections = { { id = "color", label = { zh = "颜色层" } } },
                groups = {
                    { id = "main", tier = "basic", section = "color", label = { zh = "主色" }, note = { zh = "说明" }, params = {
                        { param = "BaseColor", kind = "color", channels = "rgb", label = { zh = "主色" }, note = { zh = "颜色" } },
                        { param = "Emission", kind = "color", channels = "rgba", label = { zh = "自发光" } },
                        { param = "Alpha", kind = "float", min = 0, max = 1, label = { zh = "透明度" }, tier = "more" },
                    } },
                    { id = "misc", tier = "more", label = { zh = "杂项" }, params = {
                        { param = "Blend", kind = "enum", enum = "blend", label = { zh = "混合" } },
                        { param = "Flag", kind = "bool", component = "y", label = { zh = "开关" } },
                        { param = "Gone", kind = "float", label = { zh = "缺失" } },
                        { param = "Vec", kind = "vec", labels = { zh = { "甲", "乙", "丙", "丁" } } },
                    } },
                    { id = "guess", tier = "other", label = { zh = "推断" }, params = { { param = "Rim", kind = "float", min = 0, max = 50 } } },
                } },
            extra = { id = "extra", label = { zh = "附加" }, addon = true, enums = {}, sections = {}, groups = {} },
        },
        values = {
            ["body/Skin"] = { BaseColor = { 0.5, 0.4, 1.3, 1 }, Emission = { 0, 0, 0, 1 }, Alpha = 0.8, Blend = 1, Flag = { 0, 1, 0, 0 },
                Vec = { 1, 2, 3, 4 }, Rim = 3 },
            ["body/Jacket"] = { BaseColor = { 0.1, 0.1, 0.1, 1 } },
            ["hair/Hair"] = { BaseColor = { 0.5, 0.4, 1.3, 1 }, Emission = { 0, 0, 0, 1 }, Alpha = 0.5, Blend = 0, Flag = { 0, 0, 0, 0 },
                Vec = { 1, 2, 3, 4 }, Rim = 3 },
        },
        overrides = { ["body/Skin"] = { BaseColor = { x = 0.5 }, Alpha = 0.8 }, ["body/Jacket"] = false, ["hair/Hair"] = false },
        selected = { "body/Skin", "hair/Hair" }, errors = { "bad.json" },
    }
end

-- 控制器认识的操作(Reff.lua 的 actions 表 + character / setting / migrate)
local KNOWN = {}
for _, k in ipairs({ "character", "setting", "migrate", "manual", "auto", "armor-mirror", "note", "locate", "base-new", "base-duplicate",
    "base-rename", "base-move", "base-delete", "base-recapture", "palette-view", "palette-set", "palette-reset", "palette-reload",
    "palette-export", "palette-replace", "base-height", "option-height", "height-override", "base-material", "group-new", "group-rename", "group-move",
    "group-delete", "option-new", "option-duplicate", "option-rename", "option-move",
    "option-delete", "option-material", "state-new", "state-delete", "state-move", "state-rename", "state-field", "state-hp",
    "state-base", "state-target", "state-target-group", "state-target-remove", "condition-add", "condition-set", "condition-delete",
    "preset-apply", "preset-save", "preset-update", "preset-blank", "preset-rename", "preset-delete", "preset-dismiss", "autosave-restore",
    "autosave-promote", "restore" }) do KNOWN[k] = true end

local function fake_controller(start)
    local c = { actions = {}, character = start or "leon", palette_open = false, version = 3 }
    function c.snapshot()
        local s = fixture(c.character, c.version)
        if c.palette_open and s.configVersion == 3 then s.palette = palette() end
        return s
    end
    function c.action(a)
        assert(KNOWN[a.kind], "unknown action kind " .. tostring(a.kind))
        if a.kind ~= "character" and a.kind ~= "setting" then
            assert(a.character == c.character, "action without the current character: " .. a.kind)
        end
        c.actions[#c.actions + 1] = a
        if a.kind == "character" then c.character = a.id end
        if a.kind == "palette-view" then c.palette_open = a.open == true end
        if a.kind == "rejected" then error("nope") end
        return c.snapshot()
    end
    function c.documentation()
        return { sections = { { id = "a", title = "概念", entries = { { title = "整套造型", paragraphs = { string.rep("很长的一段说明。", 40), "short" } } } } } }
    end
    return c
end

local Panel = require("ArmorVariantManager_Core.Games.RE4.Panel.Panel")
local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")

-- 记录每帧所有点击判定的矩形(控件都通过 I.click 判点击)
local rects
local real_click = I.click
I.click = function(x, y, w, h)
    if rects and w > 0 and h > 0 then rects[#rects + 1] = { x + w / 2, y + h / 2, x, y, w, h } end
    return real_click(x, y, w, h)
end

local saved = 0
local global = { language = "zh" }
local function new_panel(ctrl)
    return Panel.new({ controller = ctrl, global_config = global, save_global_settings = function() saved = saved + 1 end,
        version = "test", set_language = function(lang) global.language = lang end })
end

local function frame(p)
    p.frame()
    p.draw()
    p.draw_inputs()
end

-- 一次点击:按下的那一帧排队,下一帧松开
local function click(p, x, y)
    mouse.x, mouse.y, mouse.down = x, y, true
    frame(p)
    mouse.down = false
    frame(p)
    frame(p)   -- 下拉框的选择在下一次绘制才返回
end

local function assert_clean(where)
    assert(#warnings == 0, where .. ": " .. tostring(warnings[1]))
end

-- ---------------------------------------------------------------- 逐页点遍
local ctrl = fake_controller()
local p = new_panel(ctrl)
assert(p.available(), "draw list stub makes the panel available")
p.set_open(true)
assert(p.is_open())
frame(p)
assert_clean("first frame")
assert(draw_calls > 0, "the panel draws onto the background draw list")

local PAGES = { "quick", "base", "groups", "states", "palette", "presets", "misc" }
local total = 0
for _, page in ipairs(PAGES) do
    p._ctx.goto_page(page)
    frame(p)
    assert_clean("open " .. page)
    -- 点遍:每次点之前重新布局一次取最新的矩形;一个位置只点一次(展开后会冒出新的位置)
    -- 正序点一遍,再倒序点一遍(正序时「完成」这类按钮会先把刚展开的区域收起来)
    local n = 0
    for pass = 1, 2 do
    local done = {}
    local guard = 0
    while guard < 400 do
        guard = guard + 1
        rects = {}
        frame(p)
        local list = rects
        rects = nil
        if pass == 2 then
            local rev = {}
            for i = #list, 1, -1 do rev[#rev + 1] = list[i] end
            list = rev
        end
        local target
        for _, r in ipairs(list) do
            local key = math.floor(r[3]) .. ":" .. math.floor(r[4]) .. ":" .. math.floor(r[5])
            -- 不点关闭按钮和左边的页签(会离开这一页)
            local rail = r[3] < 120 + 132 and r[4] > 120 + 40
            local title = r[4] < 120 + 40
            if not done[key] and not rail and not title then target = r; done[key] = true; break end
        end
        if not target then break end
        click(p, target[1], target[2])
        assert_clean(page .. " click #" .. n .. " at " .. math.floor(target[1]) .. "," .. math.floor(target[2]))
        n = n + 1
    end
    end
    total = total + n
    print(string.format("  %-8s %3d clicks", page, n))
end
assert(total > 150, "clicked across the pages: " .. total)

-- 操作覆盖:点遍以后,主要的编辑操作都应该发出去过
local seen = {}
for _, a in ipairs(ctrl.actions) do seen[a.kind] = true end
for _, k in ipairs({ "manual", "auto", "state-field", "base-new", "base-material", "option-material", "group-move", "group-delete",
    "option-delete", "base-recapture", "option-new", "state-move", "state-delete", "state-hp", "condition-add",
    "condition-delete", "state-target-remove", "preset-apply", "preset-blank", "preset-delete", "preset-dismiss", "autosave-restore", "restore",
    "palette-view", "palette-reload", "palette-reset", "setting", "armor-mirror", "migrate" }) do
    if k ~= "migrate" then assert(seen[k], "never sent " .. k) end
end
print("PASS: RE4 panel draws every page and every clickable control sends a known action for the current character")

-- 调色页:进入时打开调色数据,离开时关掉
ctrl.actions = {}
p._ctx.goto_page("quick")
p._ctx.goto_page("palette")
frame(p)
assert(ctrl.palette_open, "entering the palette page opens the palette view")
p._ctx.goto_page("misc")
assert(not ctrl.palette_open, "leaving the palette page closes the palette view")
p._ctx.goto_page("palette")
frame(p)
p.set_open(false)
assert(not ctrl.palette_open, "closing the panel on the palette page closes the palette view")
print("PASS: RE4 panel opens the palette data only while the palette page is shown")

-- 拖动标题栏移动窗口,松手后存位置
p.set_open(true)
p._ctx.goto_page("quick")
frame(p)
local before = saved
mouse.x, mouse.y, mouse.down = 300, 130, true
frame(p)
mouse.x, mouse.y = 500, 230
frame(p)
mouse.down = false
frame(p)
assert(saved > before and global.panel_window and global.panel_window.x == 320 and global.panel_window.y == 220,
    "dragging the title bar moves the window and saves it")
print("PASS: RE4 panel window drags by its title bar and remembers its place")

-- 换角色 / 语言 / v2 配置 / 没有角色
local ctrl2 = fake_controller()
local p2 = new_panel(ctrl2)
p2.set_open(true)
frame(p2)
p2._ctx.act({ kind = "character", id = "ada" })
frame(p2)
assert(ctrl2.character == "ada" and p2._snapshot().character == "ada")
ctrl2.version = 2
frame(p2); frame(p2); frame(p2); frame(p2); frame(p2); frame(p2); frame(p2)
assert_clean("v2 config")
assert(p2._snapshot().configVersion == 2)
local p3 = new_panel(fake_controller(""))
p3.set_open(true)
frame(p3)
assert_clean("no character")
-- 控制器拒绝时只提示,不报错
local ctrl4 = fake_controller()
ctrl4.action = function() error("Games/RE4/Reff.lua:12: 角色已变化") end
local p4 = new_panel(ctrl4)
p4.set_open(true)
frame(p4)
assert(p4._ctx.act({ kind = "auto", enabled = false }) == false)
assert(p4._ui.toasts[1] and p4._ui.toasts[1].text:find("角色已变化", 1, true) and not p4._ui.toasts[1].text:find("Reff.lua", 1, true),
    "a rejected action shows the reason without the source location")
frame(p4)
assert_clean("rejected action")
print("PASS: RE4 panel follows character switches, shows the migration banner for v2, copes with no character and rejections")

-- SKS 打开自己的面板时让位
local p5 = new_panel(fake_controller())
p5.set_open(true)
frame(p5)
rawset(_G, "__AVM_UI_INPUT_BLOCKER_STATES", { ShapeKeySystem = true })
frame(p5)
assert(not p5.is_open(), "the panel closes when ShapeKeySystem opens its own")
rawset(_G, "__AVM_UI_INPUT_BLOCKER_STATES", nil)
print("PASS: RE4 panel gives way when ShapeKeySystem opens its panel")

-- 调色页的 HSV 滑条:切到 HSV 后拖一下色相,写出去的仍然是 R / G / B 三个分量,并且是那个颜色转了色相的结果
do
    local hctrl = fake_controller()
    local hg = { language = "zh", palette_sliders = "hsv" }
    local hp = Panel.new({ controller = hctrl, global_config = hg, save_global_settings = function() end, version = "test",
        set_language = function() end })
    hp.set_open(true)
    hp._ctx.goto_page("palette")
    frame(hp)
    hp._ui.page_state.palette.groups_open["lil:main"] = true   -- 组默认收起
    frame(hp)
    -- 找到第一行颜色(Skin 的 BaseColor = 0.5, 0.4, 1.3)的色相滑条:颜色行里第一个滑条
    rects = {}
    frame(hp)
    local list = rects
    rects = nil
    -- 滑条的点击区比轨道左右各宽 6、高 22;「整体调色」的滑条在颜色行上面,取第 4 个(颜色行的第一个)
    local sliders = {}
    for _, r in ipairs(list) do if r[5] > 200 and r[6] == 22 then sliders[#sliders + 1] = r end end
    table.sort(sliders, function(a, b) return a[4] < b[4] end)
    local best = sliders[4]
    assert(best, "found a colour slider")
    hctrl.actions = {}
    local x0, y0, w0 = best[3] + 6, best[4] + 11, best[5] - 12
    mouse.x, mouse.y, mouse.down = x0 + w0 * 0.5, y0, true   -- 色相拖到 180°
    frame(hp)
    mouse.x = x0 + w0 * 0.5
    frame(hp)
    mouse.down = false
    frame(hp); frame(hp)
    local last
    for _, a in ipairs(hctrl.actions) do if a.kind == "palette-set" then last = a end end
    assert(last and last.live == nil, "releasing the slider sends a final (saved) write")
    local got = {}
    for _, wr in ipairs(last.writes) do
        if wr.param == "BaseColor" and wr.slot == "body" then got[wr.component] = wr.value end
    end
    -- 0.5, 0.4, 1.3 的色相 ≈ 247.5°,饱和度 ≈ 0.692,明度 1.3;拖到 180° 后应是青色:r 最小,g = b = 1.3
    assert(got.x and got.y and got.z, "writes R, G and B")
    assert(math.abs(got.y - 1.3) < 1e-6 and math.abs(got.z - 1.3) < 1e-6 and math.abs(got.x - 0.4) < 1e-3,
        string.format("hue 180 keeps saturation and value: %.3f %.3f %.3f", got.x, got.y, got.z))
    assert(#warnings == 0, tostring(warnings[1]))
end
print("PASS: RE4 panel palette HSV sliders write R / G / B from hue / saturation / value (linear values above 1 kept)")

-- 后备的虚拟光标(照 SKS):系统光标在中心 ±2 像素算钉住(粘滞 30 帧),钉住时按 UpdateMotionFrame 之前
-- 采到的设备位移移动;系统光标自由后同步过去。正常情况下 InputGuard 让游戏自己放开光标,用不到它
do
    local delta = { x = 0, y = 0 }
    local dev = { call = function(_, m)
        if m == "get_DeltaPosition()" then return { x = delta.x, y = delta.y } end
        return 0
    end }
    local real_sdk = _G.sdk
    _G.sdk = { find_type_definition = function(name) return name == "via.hid.Mouse" and {} or nil end, get_native_singleton = function() return {} end,
        call_native_func = function(_, _, name) if name == "get_Device()" then return dev end end,
        get_native_field = function() return nil end }
    global.panel_window = nil   -- 默认位置 120,120
    local vp = new_panel(fake_controller())
    _G.reframework.is_drawing_ui = function() return false end
    -- 一个游戏帧:UpdateMotionFrame 之前采样,之后 on_frame(面板的 frame / draw)
    local function game_frame() I.sample(); frame(vp) end
    mouse.x, mouse.y = 960, 540   -- 系统光标钉在中心;面板从这里开始
    vp.set_open(true)
    game_frame()
    assert(I.pinned, "a cursor sitting on the screen centre counts as pinned")
    -- 往左上移到标题栏的标题文字上(窗口在 120,120;标题栏高 40):(960,540) → (200,135)
    for _ = 1, 10 do delta.x, delta.y = -76, -40.5; game_frame() end
    delta.x, delta.y = 0, 0
    assert(math.abs(I.mx - 200) < 1 and math.abs(I.my - 135) < 1, string.format("virtual cursor follows the deltas: %.1f %.1f", I.mx, I.my))
    -- 位移只在 UpdateMotionFrame 之前采:on_frame 里不再读(读到的是 0,会让光标粘住)
    delta.x, delta.y = 50, 50
    frame(vp)
    assert(math.abs(I.mx - 200) < 1, "deltas are not read from on_frame")
    delta.x, delta.y = 0, 0
    -- 按住拖动窗口:位移继续驱动
    mouse.down = true
    game_frame()
    for _ = 1, 5 do delta.x, delta.y = 20, 10; game_frame() end
    delta.x, delta.y = 0, 0
    mouse.down = false
    game_frame()
    assert(vp._ui.win.x == 220 and vp._ui.win.y == 170, string.format("dragging with the virtual cursor moves the window: %s %s", vp._ui.win.x, vp._ui.win.y))
    -- 刚离开中心(粘滞期内)仍按钉住处理
    mouse.x, mouse.y = 700, 300
    game_frame()
    assert(I.pinned and math.abs(I.mx - 300) < 1, "still pinned right after leaving the centre")
    -- 系统光标持续自由(超过 30 帧):直接用它
    for _ = 1, 31 do game_frame() end
    assert(not I.pinned and I.mx == 700 and I.my == 300, "a free cursor is used directly")
    vp.set_open(false)
    _G.sdk = real_sdk
    _G.reframework.is_drawing_ui = function() return true end
    mouse.x, mouse.y = -1, -1
    assert(#warnings == 0, tostring(warnings[1]))
end
print("PASS: RE4 panel follows a virtual cursor while the game pins the OS cursor to the centre")

-- 替换 mdf:点按钮只弹确认框;弹窗挡住下面的点击;取消不发操作,确定才发
do
    local W = require("ArmorVariantManager_Core.Games.RE4.Panel.Widgets")
    local labels
    local real_button = W.button
    W.button = function(label, x, y, w, h, opt)
        local clicked, bw = real_button(label, x, y, w, h, opt)
        if labels then labels[label] = { x + bw / 2, y + (h or 28) / 2 } end
        return clicked, bw
    end
    local function where(label)
        labels = {}
        frame(rp_global)
        local at = labels[label]
        labels = nil
        return at
    end
    local rctrl = fake_controller()
    rp_global = new_panel(rctrl)
    local rp = rp_global
    rp.set_open(true)
    rp._ctx.goto_page("palette")
    frame(rp)
    rp._ui.page_state.palette.sel = { "body/Skin" }
    frame(rp); frame(rp)
    rctrl.actions = {}
    local at = assert(where("替换mdf"), "replace button shown for a loose material")
    click(rp, at[1], at[2])
    assert(rp._ui.modal and rp._ui.modal.text:find("原始mdf2文件", 1, true), "the replace button opens the confirm dialog")
    for _, a in ipairs(rctrl.actions) do assert(a.kind ~= "palette-replace", "nothing is sent before confirming") end
    -- 弹窗下面的东西点不到(弹窗盖住整个窗口)
    local under = assert(where("重新读取映射"))
    local before = #rctrl.actions
    click(rp, under[1], under[2])
    assert(#rctrl.actions == before and rp._ui.modal, "the dialog blocks the page underneath")
    -- 取消
    local c = assert(where("取消"))
    click(rp, c[1], c[2])
    assert(not rp._ui.modal, "cancel closes the dialog")
    for _, a in ipairs(rctrl.actions) do assert(a.kind ~= "palette-replace") end
    -- 再开一次,点确定
    at = where("替换mdf")
    click(rp, at[1], at[2])
    local ok_at = assert(where("确定"))
    click(rp, ok_at[1], ok_at[2])
    local sent
    for _, a in ipairs(rctrl.actions) do if a.kind == "palette-replace" then sent = a end end
    assert(sent and sent.slot == "body" and not rp._ui.modal, "confirm sends palette-replace for the material's slot")
    -- 不是松散文件:按钮灰掉
    rp._ui.page_state.palette.sel = { "hair/Hair" }
    frame(rp); frame(rp)
    rctrl.actions = {}
    at = where("替换mdf")
    click(rp, at[1], at[2])
    assert(not rp._ui.modal, "disabled for a packed material")
    W.button = real_button
    assert(#warnings == 0, tostring(warnings[1]))
end
print("PASS: RE4 panel replace mdf asks in a separate dialog that blocks the page; only confirm sends the action")

-- 快捷键:默认 F8 按一次开、再按一次关;改成 Ctrl+F7 后只认组合;输入框在打字时不响应;入口关掉时不响应
local TextInput = require("ArmorVariantManager_Core.Games.RE4.Panel.TextInput")
local hk_global = { language = "zh" }
local entry = true
local p6 = Panel.new({ controller = fake_controller(), global_config = hk_global, save_global_settings = function() end,
    version = "test", set_language = function() end, entry_enabled = function() return entry end })
local function press(vk)
    keys[vk] = true; p6.frame()
    keys[vk] = nil; p6.frame()
end
local F7, F8, CTRL = 0x76, 0x77, 0x11
assert(p6.hotkey_text() == "F8")
press(F8)
assert(p6.is_open(), "F8 opens the panel")
p6.frame()
assert(p6.is_open(), "holding nothing keeps it open")
keys[F8] = true; p6.frame(); p6.frame(); keys[F8] = nil; p6.frame()
assert(not p6.is_open(), "a held key toggles once")
hk_global.panel_hotkey, hk_global.panel_hotkey_mod = "F7", "Ctrl"
assert(p6.hotkey_text() == "Ctrl+F7")
press(F8); press(F7)
assert(not p6.is_open(), "the old key and the key without its modifier do nothing")
keys[CTRL] = true; press(F7); keys[CTRL] = nil
assert(p6.is_open(), "Ctrl+F7 opens the panel")
TextInput.active = "typing"
keys[CTRL] = true; press(F7); keys[CTRL] = nil
assert(p6.is_open(), "the hotkey is ignored while typing")
TextInput.active = nil
p6.set_open(false)
entry = false
keys[CTRL] = true; press(F7); keys[CTRL] = nil
assert(not p6.is_open(), "no hotkey while the entry is off (REFF installed)")
print("PASS: RE4 panel hotkey (default F8, configurable key + modifier, ignored while typing or when the entry is off)")

-- 文案:中英 key 对齐
local Text = require("ArmorVariantManager_Core.Games.RE4.Panel.Text")
for k in pairs(Text.zh) do assert(Text.en[k], "missing en text " .. k) end
for k in pairs(Text.en) do assert(Text.zh[k], "missing zh text " .. k) end
assert(Text.translator("zh")("coveredBy", "甲") == "被「甲」覆盖")
print("PASS: RE4 panel texts have matching zh / en keys")
