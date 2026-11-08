-- RE4 走独立接入：真实入口识别 re4 后只转交 Games.RE4.Main，共享应用与 REFF 不加载；
-- 旧 v2 配置（base 整套造型 + axes 状态组）按原语义写到 BodyUpdater 的固定槛位。
-- 可传入已解压发布包的 autorun 目录，默认验证开发源码。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local main = autorun .. "/ArmorVariantManager.lua"
local S = dofile("tests/support.lua")
ORIGINAL_REQUIRE = require

local Game = require("ArmorVariantManager_Core.Game")
local re4 = assert(Game.detect("RE4"))
assert(re4.name == "RE4" and re4.standalone and not re4.wilds)
assert(not Game.detect("mhwilds").standalone and not Game.detect("mhrise").standalone)

local KIND_LEON = 100000
local CONFIG_PATH = "ArmorVariantManager/Leon.json"
local GLOBAL_PATH = "ArmorVariantManager/GlobalSettings.json"

local function layer(presets, active, order)
    return {presets = presets, active = active, rules = {}, order = order, auto = true}
end

-- 一份最小的 v2 配置：base 关掉 Jacket；状态组只记它动过的 Hair（稀疏）。
local leon = {
    version = 2, armor_mirrors_body = false, material_notes = {}, extra = {keep = true},
    base = layer({Default = {
        body = {materials = {Skin = true, Jacket = false}},
        head = {materials = {Face = true}},
        hair = {materials = {Hair = true, Clip = true}},
    }}, "Default", {"Default"}),
    axes = {["Hide Hair"] = layer({On = {hair = {materials = {Hair = false}}}}, "On", {"On"})},
}

-- RE4 代码用 type() 区分托管对象（userdata）和 CG 傀儡的槛位表（table），
-- 所以托管对象必须是真 userdata：借用临时文件句柄，逐个换成自己的元表（只影响这个句柄）。
local objects = setmetatable({}, {__mode = "k"})
local object_meta = {__index = function(handle, key) return objects[handle][key] end}

local next_address = 0
local function managed(methods)
    local handle = assert(io.tmpfile())
    handle:close()
    debug.setmetatable(handle, object_meta)
    next_address = next_address + 1
    local address = next_address
    local object = {}
    function object.call(_, name, ...)
        local value = methods[name]
        if type(value) == "function" then return value(...) end
        return value
    end
    function object.get_address() return address end
    function object.get_type_definition() return {get_method = function() return nil end} end
    objects[handle] = object
    return handle, object
end
local function is_managed(value) return objects[value] ~= nil end

local function mesh(path, materials)
    local names, enabled = {}, {}
    for index, name in ipairs(materials) do names[index - 1], enabled[index - 1] = name, true end
    local holder = managed({get_ResourcePath = path})
    local result, object = managed({
        get_MaterialNum = #materials,
        getMaterialName = function(index) return names[index] end,
        getMaterialsEnable = function(index) return enabled[index] end,
        setMaterialsEnable = function(index, value) enabled[index] = value end,
        getMesh = holder,
        get_Material = managed({get_ResourcePath = path:gsub("%.mesh$", ".mdf2")}),
    })
    object.state = function()
        local state = {}
        for index, name in pairs(names) do state[name] = enabled[index] end
        return state
    end
    return result
end

-- clicks:按顺序要点的按钮(按标签结尾匹配,点到一个才轮到下一个);texts:收集画出来的文字
-- no_draw_list:模拟旧版 REFramework(没有背景绘制列表,独立面板画不了)
local function imgui_stub(clicks, texts, no_draw_list)
    local queue = clicks or {}
    local returns = {
        tree_node = function() return true end,
        combo = function(label, current) texts[#texts + 1] = tostring(label); return false, current end,
        checkbox = function(_, value) return false, value end,
        input_text = function(_, value) return false, value end,
        button = function(label)
            if queue[1] and tostring(label):sub(-#queue[1]) == queue[1] then table.remove(queue, 1); return true end
            return false
        end,
        text = function(t) texts[#texts + 1] = tostring(t) end,
        text_colored = function(t) texts[#texts + 1] = tostring(t) end,
    }
    return setmetatable({}, {__index = function(_, name)
        if no_draw_list and name == "get_background_draw_list" then return nil end
        return returns[name] or function() end
    end})
end

local function run(scenario)
    for name in pairs(package.loaded) do
        if name:match("^ArmorVariantManager") then package.loaded[name] = nil end
    end
    local files = {[GLOBAL_PATH] = {language = "zh", ui_dissolve_enabled = false, ui_dissolve_time = 2.5,
        extra = {keep = true}}}
    if scenario.config then files[CONFIG_PATH] = S.copy(scenario.config) end
    for path, value in pairs(scenario.files or {}) do files[path] = S.copy(value) end
    local frames, draws, errors, imports = {}, {}, {}, {}
    local app_entries = {}

    local meshes = {
        body = mesh("_Chainsaw/Character/ch/cha0/cha000/00/cha000_00.mesh", {"Skin", "Jacket"}),
        head = mesh("_Chainsaw/Character/ch/cha0/cha000/10/cha000_10.mesh", {"Face"}),
        hair = mesh("_Chainsaw/Character/ch/cha0/cha000/20/cha000_20.mesh", {"Hair", "Clip"}),
        armor = scenario.armor and mesh("_Chainsaw/Character/ch/cha0/cha000/30/cha000_30.mesh", {"Skin", "Jacket", "Vest"}) or nil,
    }
    local body_updater = managed({
        get_BodyMesh = meshes.body, get_HeadMesh = meshes.head, get_HairMesh = meshes.hair,
        get_ArmorMesh = meshes.armor, get_HasArmorMesh = meshes.armor ~= nil,
    })
    local hit_point = managed({get_HitPointRatio = 1.0, get_CurrentHitPoint = 100, get_DefaultHitPoint = 100})
    local context = managed({
        get_KindID = KIND_LEON, get_BodyUpdater = body_updater, get_HitPoint = hit_point,
        getHitPointVital = 0,
    })
    local character_manager = managed({getPlayerContextRef = context})
    local kind_field = {
        is_static = function() return true end,
        get_data = function() return KIND_LEON end,
        get_name = function() return "ch0_a0z0" end,
    }

    _G.reframework = {get_game_name = function() return "re4" end}
    _G.re = {on_frame = function(f) frames[#frames + 1] = f end,
        on_draw_ui = function(f) draws[#draws + 1] = f end, on_script_reset = function() end,
        -- 模型高度(HeightFix)按引擎阶段注册;这里只确认能装上,写入时机见 re4_height.lua
        on_pre_application_entry = function(name) app_entries[name] = true end,
        on_application_entry = function(name) app_entries[name] = true end}
    -- 是否装了 REFF:共享 Bridge 只在 reff_native 存在时才去加载 reff.sdk
    _G.reff_native = scenario.reff and {} or nil
    local handlers, registered_id
    _G.log = {info = function() end, error = function(message) errors[#errors + 1] = message end}
    _G.json = {
        load_file = function(path) return S.copy(files[path]) end,
        dump_file = function(path, value) files[path] = S.copy(value); return true end,
    }
    -- 预设库靠 fs.glob 枚举目录(游戏里返回带 reframework\data 前缀、反斜杠的路径)
    _G.fs = {glob = function()
        local out = {}
        for path in pairs(files) do
            if path:find("^ArmorVariantManager/presets/") then out[#out + 1] = "reframework\\data\\" .. path:gsub("/", "\\") end
        end
        return out
    end}
    _G.sdk = {
        find_type_definition = function(name)
            if name == "chainsaw.CharacterKindID" then return {get_fields = function() return {kind_field} end} end
            return {get_fields = function() return {} end, get_method = function() return nil end}
        end,
        get_managed_singleton = function(name)
            if name == "chainsaw.CharacterManager" and scenario.player then return character_manager end
        end,
        get_native_singleton = function() return nil end,
        call_native_func = function() return nil end,
        is_managed_object = is_managed,
        typeof = function(name) return {name = name} end,
    }
    local texts = {}
    _G.imgui = imgui_stub(scenario.clicks, texts, scenario.no_draw_list)

    local native_require = ORIGINAL_REQUIRE
    _G.require = function(name)
        imports[name] = true
        if name == "reff.sdk" then
            return {register = function(id, value)
                registered_id, handlers = id, value.methods
                return {unregister = function() end}
            end}
        end
        return native_require(name)
    end
    local ok, err = pcall(dofile, main)
    -- 和 REFramework 一样:加载完以后再 require 没载入过的模块就找不到(回调里懒加载会在游戏里报错)
    _G.require = function(name)
        local loaded = package.loaded[name]
        if loaded ~= nil then return loaded end
        error("module '" .. tostring(name) .. "' not found (REFramework resolves autorun modules only while loading)")
    end
    assert(ok, err)

    assert(#frames == 1 and #draws == 1, "RE4 registers exactly one frame and one draw callback")
    -- 共享层里只允许 REFF 的注册桥;共享 App、MH 的 UI / 配置会话、荒野与崛起适配都不加载
    for name in pairs(imports) do
        local allowed = name == "ArmorVariantManager_Core.UI.Reff.Bridge" or (scenario.reff and name == "reff.sdk")
        assert(allowed or (not name:match("^ArmorVariantManager_Core%.App$") and not name:match("^ArmorVariantManager_Core%.UI%.")
            and not name:match("^ArmorVariantManager_Core%.Config%.") and not name:match("^ArmorVariantManager_Core%.Games%.Wilds")
            and not name:match("^ArmorVariantManager_Core%.Games%.Rise") and name ~= "reff.sdk"),
            "RE4 must not load shared application module " .. name)
    end
    assert(imports["ArmorVariantManager_Core.Games.RE4.Main"] and imports["ArmorVariantManager_Core.Games.RE4.Dissolve"])
    assert((handlers ~= nil) == (scenario.reff == true), "REFF methods are registered only when REFF is present")
    if handlers then assert(registered_id == "monkeysama.avm") end

    for _ = 1, 40 do frames[1]() end
    for _ = 1, 3 do draws[1]() end
    assert(#errors == 0, "unexpected error: " .. tostring(errors[1]))
    return files, meshes, handlers, frames[1], texts
end

-- 有玩家、有旧配置：整套造型铺底，状态组只覆盖它点名的材质，没点名的保持整套造型的值。
local files, meshes = run({player = true, config = leon})
S.equal(meshes.body.state(), {Skin = true, Jacket = false})
S.equal(meshes.head.state(), {Face = true})
S.equal(meshes.hair.state(), {Hair = false, Clip = true})
assert(files[CONFIG_PATH].extra.keep == true, "unknown config fields survive")
assert(files[CONFIG_PATH].axes["Hide Hair"].presets.On.hair.materials.Hair == false)
assert(files[GLOBAL_PATH].language == "zh", "global language is preserved")
-- 0.4.3 的界面溶解设置要原样留住：全局设置保存时整表写回，漏读的字段会被清掉。
assert(files[GLOBAL_PATH].ui_dissolve_enabled == false and files[GLOBAL_PATH].ui_dissolve_time == 2.5,
    "global dissolve settings are preserved")
print("PASS: RE4 standalone entry, no shared app modules (REFF bridge only), v2 base + sparse axis applied, unknown fields and dissolve settings kept")

-- 没有玩家（标题画面、读盘中）：回调照常运行，不报错、不碰配置。
files = run({player = false, config = leon})
S.equal(files[CONFIG_PATH], leon)
print("PASS: RE4 without player context keeps callbacks quiet and config untouched")

-- REF 菜单:v2 配置给"迁移旧配置"(两步确认);迁移后同一个面板画 v3 的日常切换与预设,不出错
do
    local texts
    files, meshes, _, _, texts = run({player = true, config = leon, clicks = {"###mig", "###mig_yes"}})
    assert(files[CONFIG_PATH].version == 3, "migrated from the REF menu")
    assert(files["ArmorVariantManager/backup/Leon.json"].version == 2, "restore point written first")
    local joined = table.concat(texts, "\n")
    -- 提示只列真的有的编辑入口:这里没装 REFF,桩 imgui 能画独立面板 → 只提 F8
    assert(joined:find("请用 imGUI（F8）。", 1, true) and not joined:find("REFF", 1, true),
        "without REFF the hint points to the standalone panel only")
    assert(joined:find("Hide Hair", 1, true), "state groups are listed for manual switching")
    S.equal(meshes.hair.state(), {Hair = false, Clip = true}, "look unchanged after migrating from the menu")
    -- 装了 REFF:F8 照样给(REFF.dll 加载了不等于网页打得开),两个入口都提
    _, _, _, _, texts = run({player = true, config = leon, reff = true, clicks = {"###mig", "###mig_yes"}})
    joined = table.concat(texts, "\n")
    assert(joined:find("imGUI（F8）或 REFF 图形界面（Home）", 1, true),
        "with REFF loaded the hint keeps F8 and adds Home")
    -- 两个都没有(REFramework 太旧、没装 REFF):只说这里能做什么,不提版本
    _, _, _, _, texts = run({player = true, config = leon, no_draw_list = true, clicks = {"###mig", "###mig_yes"}})
    joined = table.concat(texts, "\n")
    assert(joined:find("新版配置:这里只做日常切换和预设。", 1, true) and not joined:find("imGUI", 1, true)
        and not joined:find("REFF", 1, true), "with no editor available the hint names none")
end
print("PASS: RE4 REF menu migrates a v2 config in two steps and draws the v3 daily-use panel")

-- 装了 REFF:v2 配置只能迁移;迁移后快照与操作都按 v3(整套造型 + 状态组 + 条件状态 + 预设库)。
local function plain(value, path)
    local kind = type(value)
    assert(kind == "string" or kind == "number" or kind == "boolean" or kind == "table" or kind == "nil",
        path .. " is not serializable: " .. kind)
    if kind == "table" then
        assert(getmetatable(value) == nil, path .. " carries a metatable")
        for key, item in pairs(value) do
            assert(type(key) == "string" or type(key) == "number", path .. " has a non-plain key")
            plain(item, path .. "." .. tostring(key))
        end
    end
end
local handlers, tick
local SLOTS_PATH = "ArmorVariantManager/backup/Leon.slots.json"
files, meshes, handlers, tick = run({player = true, config = leon, reff = true,
    files = {[SLOTS_PATH] = {slots = {Old = leon}}}})
assert(handlers["monkeysama.avm.snapshot"] and handlers["monkeysama.avm.action"] and handlers["monkeysama.avm.documentation"])
assert(handlers["monkeysama.avm.imports"] == nil, "RE4 registers only what it serves")
-- 全身预览:测试环境里没有原生 DLL,如实报告不可用,不报错
local preview_state = handlers["monkeysama.avm.preview"]({visible = true, width = 330, height = 360})
assert(preview_state.available == false and preview_state.status == "preview_native_missing")
local snap = handlers["monkeysama.avm.snapshot"]()
plain(snap, "v2 snapshot")
assert(snap.game == "RE4" and snap.character == "Leon" and #snap.characters == 1 and snap.configVersion == 2)
assert(snap.base == nil and snap.states == nil, "a v2 config only gets the migration entry")
assert(snap.settings.uiDissolveEnabled == false and snap.settings.uiDissolveTime == 2.5)
local act = handlers["monkeysama.avm.action"]
assert(not pcall(act, {kind = "manual", character = "Leon", layer = "base", option = ""}), "v3 actions wait for migration")

local function run_frames(n) for _ = 1, n or 2 do tick() end end
-- 迁移:先写还原点;旧的命名存档转成预设;外观不变
snap = act({kind = "migrate", character = "Leon"})
plain(snap, "v3 snapshot")
assert(snap.configVersion == 3 and files[CONFIG_PATH].version == 3)
assert(snap.notice.kind == "migrated" and snap.notice.overlaps == nil and snap.notice.presets == 1)
assert(files["ArmorVariantManager/backup/Leon.json"].version == 2, "restore point keeps the v2 config")
assert(files["ArmorVariantManager/presets/p0001.json"].name == "Leon · Old")
assert(files["ArmorVariantManager/presets/p0001.json"].config.version == 3)
assert(files[SLOTS_PATH].slots.Old, "old saves file is kept")
assert(not pcall(act, {kind = "migrate", character = "Leon"}), "already migrated")
run_frames()
S.equal(meshes.hair.state(), {Hair = false, Clip = true}, "migration keeps the look")

local slot_ids = {}
for _, slot in ipairs(snap.slots) do slot_ids[#slot_ids + 1] = slot.id end
S.equal(slot_ids, {"body", "head", "hair"})
assert(snap.base.active == "Default" and snap.base.effective == "Default" and snap.base.presets[1].match.status == "ok")
assert(snap.base.presets[1].values["body/Jacket"] == false)
assert(#snap.groups == 1 and snap.groups[1].name == "Hide Hair" and snap.groups[1].effective == "On")
assert(snap.groups[1].scope == nil, "no scope in the snapshot")
assert(snap.groups[1].options[1].values["hair/Hair"] == false)
assert(snap.auto == true and #snap.states == 0 and snap.status.hp == 100)
assert(snap.presets.current == "full" and #snap.presets.list == 1 and snap.presets.list[1].match == "full")
local hp_def
for _, def in ipairs(snap.conditions) do if def.id == "hp_ratio" then hp_def = def end end
assert(hp_def and hp_def.kind == "number" and hp_def.value == 100 and hp_def.category == "hp")
local function look(slot, mat)
    for _, l in ipairs(snap.look) do if l.slot == slot and l.material == mat then return l.on end end
end
assert(look("hair", "Hair") == false and look("hair", "Clip") == true)

-- 手动选择
snap = act({kind = "manual", character = "Leon", layer = "Hide Hair", option = ""})
assert(snap.groups[1].active == "" and snap.groups[1].effective == nil)
run_frames()
assert(meshes.hair.state().Hair == true, "group set to none falls back to the full outfit")

-- 条件状态:新建、条件、目标、保持;条件成立时接管状态组
snap = act({kind = "state-new", character = "Leon", name = "Healthy"})
assert(#snap.states == 1 and snap.states[1].kind == "idle")
snap = act({kind = "condition-add", character = "Leon", index = 1, condition = {type = "hp_ratio", op = "<=", value = 30}})
assert(snap.states[1].conditions[1].value == 30 and snap.states[1].conditions[1].met == false)
snap = act({kind = "state-target", character = "Leon", index = 1, group = "Hide Hair", option = "On"})
assert(snap.states[1].targets[1].option == "On" and snap.states[1].kind == "idle")
snap = act({kind = "condition-set", character = "Leon", index = 1, condition_index = 1,
    condition = {type = "hp_ratio", op = ">=", value = 50}})
assert(snap.states[1].conditions[1].met == true and snap.states[1].kind == "active")
assert(snap.groups[1].effective == "On" and snap.groups[1].fromState == 1)
run_frames()
assert(meshes.hair.state().Hair == false, "condition state takes over the group")
snap = act({kind = "state-field", character = "Leon", index = 1, field = "hold", value = "1.5"})
assert(snap.states[1].hold == 1.5)
snap = act({kind = "state-field", character = "Leon", index = 1, field = "exclusive", value = true})
assert(snap.states[1].exclusive == true)
snap = act({kind = "state-hp", character = "Leon", index = 1, hp = {upper = 80, lower = 20}})
assert(snap.states[1].hp.upper == 80)
snap = act({kind = "state-hp", character = "Leon", index = 1})
assert(snap.states[1].hp == nil)
snap = act({kind = "state-base", character = "Leon", index = 1, preset = "Default"})
assert(snap.states[1].base == "Default" and snap.states[1].baseResult.kind == "win")
snap = act({kind = "auto", character = "Leon", enabled = false})
assert(snap.auto == false and snap.states[1].kind == "paused")
act({kind = "auto", character = "Leon", enabled = true})

-- 整套造型:新建抓当前外观、改名牵动条件状态、材质、删除前留还原点
snap = act({kind = "base-new", character = "Leon"})
assert(#snap.base.presets == 2 and snap.base.active == "1")
snap = act({kind = "state-base", character = "Leon", index = 1, preset = "1"})
snap = act({kind = "base-rename", character = "Leon", preset = "1", name = "Battle"})
assert(snap.base.presets[2].name == "Battle" and snap.states[1].base == "Battle")
snap = act({kind = "base-material", character = "Leon", preset = "Battle", slot = "body", material = "Jacket", value = false})
assert(files[CONFIG_PATH].base.presets.Battle.body.materials.Jacket == false)
snap = act({kind = "base-move", character = "Leon", preset = "Battle", offset = -1})
assert(snap.base.presets[1].name == "Battle")
snap = act({kind = "base-delete", character = "Leon", preset = "Battle"})
assert(#snap.base.presets == 1 and snap.backups.hasBackup == true)
assert(snap.states[1].baseResult.kind == "broken", "deleted target shows as broken")

-- 状态组:新建、选项、材质三态(任何材质都能写,可以和别的组重叠)、改名牵动引用、删除
snap = act({kind = "group-new", character = "Leon", name = "Face"})
assert(not pcall(act, {kind = "scope-add", character = "Leon", group = "Face", slot = "head", material = "Face"}), "scope actions are gone")
snap = act({kind = "option-new", character = "Leon", group = "Face"})
assert(snap.groups[2].active == "1")
snap = act({kind = "option-material", character = "Leon", group = "Face", option = "1", slot = "head", material = "Face", value = "off"})
run_frames()
assert(meshes.head.state().Face == false)
snap = act({kind = "option-material", character = "Leon", group = "Face", option = "1", slot = "hair", material = "Hair", value = "on"})
assert(snap.groups[2].options[1].values["hair/Hair"] == true, "a material another group writes can be set too")
snap = act({kind = "option-material", character = "Leon", group = "Face", option = "1", slot = "hair", material = "Hair", value = "none"})
assert(snap.groups[2].options[1].values["hair/Hair"] == nil)
snap = act({kind = "state-target", character = "Leon", index = 1, group = "Face", option = "1"})
snap = act({kind = "group-rename", character = "Leon", group = "Face", name = "Expression"})
assert(snap.groups[2].name == "Expression" and snap.states[1].targets[2].group == "Expression")
snap = act({kind = "option-rename", character = "Leon", group = "Expression", option = "1", name = "Pale"})
assert(snap.states[1].targets[2].option == "Pale")
snap = act({kind = "state-target-remove", character = "Leon", index = 1, target = 2})
assert(#snap.states[1].targets == 1)
snap = act({kind = "group-delete", character = "Leon", group = "Expression"})
assert(#snap.groups == 1)

-- 调色方案:在初始(mdf2 原值,只读)上调色 → 自动新建方案并选中 → 复制 → 按方案读写 → 选回初始 → 三处引用 → 改名 / 删除
snap = act({kind = "palette-set", character = "Leon", writes = {{slot = "body", material = "Skin", param = "Base", component = "x", value = 0.5}}})
assert(files[CONFIG_PATH].palette == nil, "the original is read-only")
assert(files[CONFIG_PATH].palette_active == "方案 1" and files[CONFIG_PATH].palettes["方案 1"].body.Skin.Base.x == 0.5,
    "editing on the original creates and selects a scheme")
snap = act({kind = "palette-scheme-new", character = "Leon", name = "Pale", from = "方案 1"})
assert(snap.palettes.list[2].name == "Pale" and snap.palettes.list[2].used == 0 and snap.palettes.list[2].materials == 1)
assert(files[CONFIG_PATH].palettes.Pale.body.Skin.Base.x == 0.5, "copied")
assert(files[CONFIG_PATH].palette_active == "Pale", "a new scheme is selected")
S.equal(snap.palettes.active, {"Pale"}, "selected = in effect, no reference needed")
assert(snap.palettes.selected == "Pale", "the selection is in every snapshot (quick switch), not only on the palette page")
snap = act({kind = "palette-scheme-new", character = "Leon", name = "Blank"})
assert(snap.palettes.list[3].materials == 0, "a blank scheme changes nothing")
snap = act({kind = "palette-scheme-delete", character = "Leon", scheme = "Blank"})
snap = act({kind = "palette-scheme-delete", character = "Leon", scheme = "方案 1"})
snap = act({kind = "palette-scheme-select", character = "Leon", scheme = "Pale"})
snap = act({kind = "palette-view", character = "Leon", open = true, keys = {"body/Skin"}})
assert(snap.palette and snap.palette.scheme == "Pale", "the palette page edits the selected scheme")
snap = act({kind = "palette-set", character = "Leon", scheme = "Pale", writes = {{slot = "body", material = "Skin", param = "Base", component = "y", value = 0.2}}})
assert(files[CONFIG_PATH].palettes.Pale.body.Skin.Base.y == 0.2, "writes go to the selected scheme")
-- 拖动中(live):只回小确认、不存盘;松手那次存盘并返回完整快照
local live = act({kind = "palette-set", character = "Leon", scheme = "Pale", live = true, writes = {{slot = "body", material = "Skin", param = "Base", component = "y", value = 0.3}}})
S.equal(live, {live = true}, "a live drag write is acknowledged without a snapshot")
assert(files[CONFIG_PATH].palettes.Pale.body.Skin.Base.y == 0.2, "live writes are not saved")
snap = act({kind = "palette-set", character = "Leon", scheme = "Pale", writes = {{slot = "body", material = "Skin", param = "Base", component = "y", value = 0.3}}})
assert(snap.game == "RE4" and files[CONFIG_PATH].palettes.Pale.body.Skin.Base.y == 0.3, "the release write saves and returns a snapshot")
snap = act({kind = "palette-reset", character = "Leon", scheme = "Pale", targets = {{slot = "body", material = "Skin"}}, param = "Base", component = "x"})
assert(files[CONFIG_PATH].palettes.Pale.body.Skin.Base.x == nil)
assert(not pcall(act, {kind = "palette-set", character = "Leon", scheme = "Nope", writes = {{slot = "body", material = "Skin", param = "Base", value = 1}}}),
    "writing to a missing scheme is refused")
snap = act({kind = "palette-view", character = "Leon", open = false, keys = {}})
S.equal(snap.palettes.active, {"Pale"}, "closing the palette page keeps the selection in effect")
snap = act({kind = "palette-scheme-select", character = "Leon", scheme = ""})
assert(files[CONFIG_PATH].palette_active == nil)
S.equal(snap.palettes.active, {}, "original only")
assert(not pcall(act, {kind = "palette-scheme-select", character = "Leon", scheme = "Nope"}), "selecting a missing scheme is refused")
snap = act({kind = "palette-view", character = "Leon", open = true, keys = {"body/Skin"}})
assert(snap.palette.scheme == "")
snap = act({kind = "palette-ref", character = "Leon", layer = "base", option = "Default", scheme = "Pale"})
assert(snap.base.presets[1].palette == "Pale")
S.equal(snap.palettes.active, {}, "not picked = not effective")
snap = act({kind = "manual", character = "Leon", layer = "base", option = "Default"})
S.equal(snap.palettes.active, {"Pale"}, "the effective base preset brings its scheme")
snap = act({kind = "palette-ref", character = "Leon", layer = "Hide Hair", option = "On", scheme = "Pale"})
assert(snap.groups[1].options[1].palette == "Pale" or snap.groups[1].options[2].palette == "Pale")
snap = act({kind = "state-palette", character = "Leon", index = 1, scheme = "Pale"})
assert(snap.states[1].palette == "Pale" and snap.palettes.list[1].used == 3)
snap = act({kind = "palette-scheme-select", character = "Leon", scheme = "Pale"})
assert(snap.palettes.active[1] == "Pale" and #snap.palettes.active >= 2, "selected sits under the referenced ones")
snap = act({kind = "palette-scheme-rename", character = "Leon", scheme = "Pale", name = "Sick"})
assert(snap.palette.scheme == "Sick", "selection follows the rename")
assert(snap.base.presets[1].palette == "Sick" and snap.states[1].palette == "Sick")
snap = act({kind = "palette-scheme-new", character = "Leon", name = "Empty"})
assert(snap.palette.scheme == "Empty" and #snap.palettes.list == 2)
snap = act({kind = "palette-scheme-delete", character = "Leon", scheme = "Empty"})
assert(snap.palette.scheme == "", "deleting the selected scheme goes back to the original")
snap = act({kind = "palette-scheme-delete", character = "Leon", scheme = "Sick"})
assert(snap.palettes.list[1] == nil and snap.base.presets[1].palette == "Sick", "refs stay as broken")
assert(snap.states[1].paletteResult.kind == "broken" or snap.states[1].paletteResult == nil)
snap = act({kind = "palette-ref", character = "Leon", layer = "base", option = "Default", scheme = ""})
snap = act({kind = "manual", character = "Leon", layer = "base", option = ""})
snap = act({kind = "palette-view", character = "Leon", open = false, keys = {}})
run_frames()

-- 快捷键:绑定只存配置,不重写。单项 → 轮换(清掉同结构的单项)→ 关掉一项 → 清除
snap = act({kind = "hotkey-set", character = "Leon", digit = 1, target = {kind = "base", option = "Default"}})
assert(snap.hotkeys[1].digit == 1 and snap.hotkeys[1].option == "Default" and not snap.hotkeys[1].cycle)
assert(files[CONFIG_PATH].hotkeys["1"].option == "Default")
assert(not pcall(act, {kind = "hotkey-set", character = "Leon", digit = 12, target = {kind = "base"}}), "digits only")
snap = act({kind = "hotkey-set", character = "Leon", digit = 2, target = {kind = "base"}})
assert(#snap.hotkeys == 1 and snap.hotkeys[1].digit == 2 and snap.hotkeys[1].cycle, "the item key gave way to the cycle key")
snap = act({kind = "hotkey-skip", character = "Leon", structure = {kind = "base"}, item = "Default", included = false})
assert(snap.hotkeys[1].skip[1] == "Default")
snap = act({kind = "hotkey-clear", character = "Leon", digit = 2})
assert(#snap.hotkeys == 0 and files[CONFIG_PATH].hotkeys == nil)

-- 护甲镜像、备注、定位(不写配置)
snap = act({kind = "armor-mirror", character = "Leon", enabled = true})
assert(snap.armorMirror == true)
snap = act({kind = "note", character = "Leon", slot = "body", material = "Skin", text = "Skin base"})
assert(snap.slots[1].materials[1].note == "Skin base")
run_frames()
local before_locate = S.copy(files[CONFIG_PATH])
local looks_before = {body = meshes.body.state(), head = meshes.head.state(), hair = meshes.hair.state()}
snap = act({kind = "locate", character = "Leon", slot = "hair", material = "Clip"})
assert(snap.locating.slot == "hair" and snap.locating.material == "Clip")
S.equal(files[CONFIG_PATH], before_locate, "locating never writes the config")
-- 定位中:被定位的槛位只剩这一个材质,其余槛位(身体、头)整个隐藏
run_frames()
S.equal(meshes.hair.state(), {Hair = false, Clip = true}, "only the located material shows")
S.equal(meshes.body.state(), {Skin = false, Jacket = false}, "other slots are hidden while locating")
S.equal(meshes.head.state(), {Face = false}, "other slots are hidden while locating")
-- 定位中换一个材质:沿用最初存下的开关,过期后瞬间恢复成定位前的样子
act({kind = "locate", character = "Leon", slot = "body", material = "Skin"})
run_frames()
S.equal(meshes.body.state(), {Skin = true, Jacket = false})
S.equal(meshes.hair.state(), {Hair = false, Clip = false})
do
    local real_clock = os.clock
    os.clock = function() return real_clock() + 3600 end
    run_frames()
    os.clock = real_clock
end
S.equal({body = meshes.body.state(), head = meshes.head.state(), hair = meshes.hair.state()}, looks_before,
    "every slot is back to its pre-locate look")

-- 预设库:存为新预设 → 存回 → 改名 → 套用(先进自动保存)→ 恢复自动保存 → 转预设 → 删除
snap = act({kind = "preset-save", character = "Leon", name = "Mine"})
local mine
for _, p in ipairs(snap.presets.list) do if p.name == "Mine" then mine = p end end
assert(mine and mine.match == "full" and snap.presets.source.id == mine.id and snap.presets.source.own)
assert(files[CONFIG_PATH].source_preset == mine.id)
snap = act({kind = "preset-update", character = "Leon"})
snap = act({kind = "preset-rename", character = "Leon", id = mine.id, name = "Mine 2"})
assert(snap.presets.source.name == "Mine 2")
snap = act({kind = "preset-apply", character = "Leon", id = "p0001"})
assert(files[CONFIG_PATH].source_preset == "p0001" and #snap.states == 0, "applying replaces the whole config")
assert(#snap.presets.autosaves == 1)
assert(files["ArmorVariantManager/autosave/Leon.json"].entries[1].config.conditions.states[1].name == "Healthy")
snap = act({kind = "autosave-restore", character = "Leon", index = 1})
assert(#snap.states == 1 and snap.states[1].name == "Healthy", "auto-save brings the config back")
assert(#snap.presets.autosaves == 1, "restoring pushes the replaced config first")
snap = act({kind = "autosave-promote", character = "Leon", index = 1, name = "From autosave"})
assert(#snap.presets.autosaves == 0)
local promoted
for _, p in ipairs(snap.presets.list) do if p.name == "From autosave" then promoted = p end end
assert(promoted)
snap = act({kind = "preset-delete", character = "Leon", id = promoted.id})
assert(files["ArmorVariantManager/presets/" .. promoted.id .. ".json"].deleted == true)
snap = act({kind = "preset-dismiss", character = "Leon"})
assert(snap.presets.dismissed == true)

-- 新建空白配置:整套造型 / 状态组 / 条件状态 / 调色 / 快捷键清空,备注与设定保留,清空前先进自动保存
do
    local before_blank = S.copy(files[CONFIG_PATH])
    assert(next(before_blank.base.presets) and #before_blank.conditions.states > 0, "there is something to clear")
    local n_auto = #snap.presets.autosaves
    snap = act({kind = "preset-blank", character = "Leon", capture = false})
    local c = files[CONFIG_PATH]
    assert(next(c.base.presets) == nil and c.base.active == "" and #c.groups == 0 and #c.conditions.states == 0, "everything is cleared")
    assert(c.palettes == nil and c.palette_active == nil and c.hotkeys == nil and c.source_preset == nil)
    S.equal(c.material_notes, before_blank.material_notes, "material notes are kept")
    assert(c.armor_mirrors_body == before_blank.armor_mirrors_body)
    assert(#snap.base.presets == 0 and #snap.groups == 0 and #snap.states == 0 and snap.presets.source == nil)
    assert(#snap.presets.autosaves == n_auto + 1, "the replaced config goes to the auto-saves")

    snap = act({kind = "preset-blank", character = "Leon", capture = true})
    c = files[CONFIG_PATH]
    assert(c.base.active == "1" and c.base.order[1] == "1" and next(c.base.presets["1"]), "the current look becomes full outfit 1")
    assert(#snap.base.presets == 1 and snap.base.presets[1].match.status == "ok")

    snap = act({kind = "autosave-restore", character = "Leon", index = 2})
    S.equal(files[CONFIG_PATH].conditions, before_blank.conditions, "the auto-save brings the old config back")
    S.equal(files[CONFIG_PATH].base, before_blank.base)
end

-- 还原点与全局设置
snap = act({kind = "restore", character = "Leon", which = "backup"})
assert(not pcall(act, {kind = "restore", character = "Leon", which = "nothing"}))
snap = act({kind = "setting", id = "ui_dissolve_time", value = 3.26})
assert(snap.settings.uiDissolveTime == 3.3 and files[GLOBAL_PATH].ui_dissolve_time == 3.3)

-- 拒绝:角色已变化、目标不存在、坏参数、未知操作 —— 都不改配置
local before = S.copy(files[CONFIG_PATH])
for _, bad in ipairs({
    {kind = "manual", character = "Ada", layer = "base", option = ""},
    {kind = "manual", character = "Leon", layer = "Missing", option = ""},
    {kind = "state-field", character = "Leon", index = 99, field = "hold", value = 1},
    {kind = "condition-add", character = "Leon", index = 1, condition = {type = "hp_ratio", op = "<=", value = "x"}},
    {kind = "preset-apply", character = "Leon", id = "nope"},
    {kind = "unknown", character = "Leon"},
}) do
    assert(not pcall(act, bad), "rejected: " .. tostring(bad.kind))
end
S.equal(files[CONFIG_PATH], before)
local docs = handlers["monkeysama.avm.documentation"]()
plain(docs, "documentation")
assert(#docs.sections >= 1, "help is served")
print("PASS: RE4 REFF v2 -> v3 migration (restore point, old saves become presets), v3 snapshot, manual / condition states / full outfit / state groups / notes / locate, preset library with auto-saves, rejections")

-- 没装 REFF 时的独立面板(Games/RE4/Panel)接在同一个控制器上:换上能画图的 ImGui 桩,
-- 逐页把每个可点的地方点一遍,操作走真实控制器(会改配置;被拒绝的只提示)。页面不能报错。
do
    local Main = package.loaded["ArmorVariantManager_Core.Games.RE4.Main"]
    assert(Main and Main.panel and Main.reff, "Main creates the standalone panel on the REFF controller")
    local warns = {}
    _G.log.warn = function(m) warns[#warns + 1] = m end
    _G.log.error = function(m) warns[#warns + 1] = m end
    local mouse = {x = -1, y = -1, down = false}
    local dl = setmetatable({}, {__index = function() return function() end end})
    local base_imgui = _G.imgui
    _G.Vector2f = _G.Vector2f or {new = function(x, y) return {x = x, y = y} end}
    _G.Vector4f = _G.Vector4f or {new = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end}
    _G.imgui = setmetatable({
        get_background_draw_list = function() return dl end,
        calc_text_size = function(s) return {x = utf8.len(s) * 7, y = 14} end,
        get_display_size = function() return {x = 1920, y = 1080} end,
        get_mouse = function() return {x = mouse.x, y = mouse.y} end,
        is_mouse_down = function() return mouse.down end,
        begin_window = function() return true end,
        input_text = function(_, text) return false, text end,
    }, {__index = function() return function() end end})
    _G.reframework.is_drawing_ui = function() return true end   -- 鼠标瞬移:按 REF 菜单开着算(直接用系统光标)
    local I = require("ArmorVariantManager_Core.Games.RE4.Panel.Input")
    local rects
    local real_click = I.click
    I.click = function(x, y, w, h)
        if rects then rects[#rects + 1] = {x + w / 2, y + h / 2, x, y, w} end
        return real_click(x, y, w, h)
    end
    local panel = Main.panel
    assert(panel.available())
    panel.set_open(true)
    local function frame() tick() end   -- Main 的 on_frame 里依次调用 panel.frame / draw / draw_inputs
    frame()
    local clicks = 0
    for _, page in ipairs({"quick", "base", "groups", "states", "palette", "presets", "misc"}) do
        panel._ctx.goto_page(page)
        frame()
        for pass = 1, 2 do
            local done = {}
            for _ = 1, 150 do
                rects = {}
                frame()
                local list = rects
                rects = nil
                local target
                for k = 1, #list do
                    local r = list[pass == 1 and k or (#list - k + 1)]
                    local key = math.floor(r[3]) .. ":" .. math.floor(r[4]) .. ":" .. math.floor(r[5])
                    -- 不点标题栏(关闭 / 语言)和左边的页签
                    if not done[key] and r[4] > 160 and r[3] > 252 then target = r; done[key] = true; break end
                end
                if not target then break end
                mouse.x, mouse.y, mouse.down = target[1], target[2], true
                frame()
                mouse.down = false
                frame(); frame()
                clicks = clicks + 1
                assert(#warns == 0, page .. ": " .. tostring(warns[1]))
            end
        end
    end
    assert(clicks > 100, "clicked through the standalone panel: " .. clicks)
    panel.set_open(false)
    _G.imgui = base_imgui
    print("PASS: RE4 standalone panel (no REFF) drives the real controller through every page without errors (" .. clicks .. " clicks)")
end

-- 穿着护甲 + armor 照抄 body:定位 body 的材质时 armor 上同名材质一起显示(游戏把 body 换成了 armor);
-- 关掉照抄时 armor 和其它槛位一样整个隐藏
do
    local mirrored = S.copy(leon)
    mirrored.armor_mirrors_body = true
    local h, armor_tick
    files, meshes, h, armor_tick = run({player = true, config = mirrored, reff = true, armor = true})
    local a = h["monkeysama.avm.action"]
    a({kind = "migrate", character = "Leon"})
    for _ = 1, 2 do armor_tick() end
    local armor_before = meshes.armor.state()
    a({kind = "locate", character = "Leon", slot = "body", material = "Jacket"})
    for _ = 1, 2 do armor_tick() end
    S.equal(meshes.body.state(), {Skin = false, Jacket = true})
    S.equal(meshes.armor.state(), {Skin = false, Jacket = true, Vest = false}, "mirrored armor shows the located body material")
    S.equal(meshes.hair.state(), {Hair = false, Clip = false})
    local real_clock = os.clock
    os.clock = function() return real_clock() + 3600 end
    for _ = 1, 2 do armor_tick() end
    os.clock = real_clock
    S.equal(meshes.armor.state(), armor_before, "armor restored, including materials the config never names")
    a({kind = "armor-mirror", character = "Leon", enabled = false})
    for _ = 1, 2 do armor_tick() end
    a({kind = "locate", character = "Leon", slot = "body", material = "Jacket"})
    for _ = 1, 2 do armor_tick() end
    S.equal(meshes.armor.state(), {Skin = false, Jacket = false, Vest = false}, "without mirroring armor is just another hidden slot")
    os.clock = function() return real_clock() + 7200 end
    for _ = 1, 2 do armor_tick() end
    os.clock = real_clock

    -- 调色页「仅显示选中部位」:多选跨部位,跟着选择走,不过期;离开调色页恢复原样
    local looks = function() return {body = meshes.body.state(), head = meshes.head.state(),
        hair = meshes.hair.state(), armor = meshes.armor.state()} end
    local before_solo = looks()
    local snap_solo = a({kind = "palette-view", character = "Leon", open = true, keys = {"body/Jacket", "hair/Clip"}, solo = true})
    assert(snap_solo.solo == true and snap_solo.locating == nil, "solo is reported apart from a timed locate")
    os.clock = function() return real_clock() + 9000 end
    for _ = 1, 2 do armor_tick() end
    os.clock = real_clock
    S.equal(looks(), {body = {Skin = false, Jacket = true}, head = {Face = false}, hair = {Hair = false, Clip = true},
        armor = {Skin = false, Jacket = false, Vest = false}}, "only the selected materials show, and it does not expire")
    a({kind = "palette-view", character = "Leon", open = true, keys = {"body/Skin"}, solo = true})
    for _ = 1, 2 do armor_tick() end
    S.equal(meshes.body.state(), {Skin = true, Jacket = false}, "solo follows the selection")
    S.equal(meshes.hair.state(), {Hair = false, Clip = false})
    a({kind = "palette-view", character = "Leon", open = true, keys = {"body/Skin"}, solo = false})
    for _ = 1, 2 do armor_tick() end
    S.equal(looks(), before_solo, "turning solo off restores the look")
    a({kind = "palette-view", character = "Leon", open = true, keys = {"hair/Hair"}, solo = true})
    for _ = 1, 2 do armor_tick() end
    S.equal(meshes.body.state(), {Skin = false, Jacket = false})
    a({kind = "palette-view", character = "Leon", open = false, keys = {}})
    for _ = 1, 2 do armor_tick() end
    S.equal(looks(), before_solo, "leaving the palette page restores the look")

    -- 快照编码后超过 REFF 单条消息上限:先只留第一个材质的数值并提示,还超就只给提示 —— 总之有回包,不再 TIMEOUT
    local big = false
    _G.json.dump_string = function(v)
        local pal = v.palette
        if not pal then return "{}" end
        if big or not pal.error then return string.rep("x", 300 * 1024) end
        return "{}"
    end
    local s1 = a({kind = "palette-view", character = "Leon", open = true, keys = {"body/Skin", "body/Jacket"}})
    assert(s1.palette and s1.palette.error and s1.palette.error:find("太多", 1, true), "oversized palette is trimmed with a notice")
    big = true
    local s2 = a({kind = "palette-view", character = "Leon", open = true, keys = {"body/Skin", "body/Jacket"}})
    assert(s2.palette.error and next(s2.palette.profiles) == nil and next(s2.palette.values) == nil, "still too large: palette data dropped, notice kept")
    _G.json.dump_string = nil
    a({kind = "palette-view", character = "Leon", open = false, keys = {}})
end
print("PASS: RE4 locate hides every other slot, carries over to mirrored armor, restores the pre-locate look; palette solo shows only the selection until turned off; oversized palette snapshots are trimmed instead of dropped")
