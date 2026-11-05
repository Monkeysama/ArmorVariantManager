-- RE4 走独立接入：真实入口识别 re4 后只转交 Games.RE4.Main，共享应用与 REFF 不加载；
-- 旧 v2 配置（base 整套造型 + axes 状态组）按原语义写到 BodyUpdater 的固定槛位。
-- 可传入已解压发布包的 autorun 目录，默认验证开发源码。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local main = autorun .. "/ArmorVariantManager.lua"
local S = dofile("tests/support.lua")

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
local function imgui_stub(clicks, texts)
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
    return setmetatable({}, {__index = function(_, name) return returns[name] or function() end end})
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

    local meshes = {
        body = mesh("_Chainsaw/Character/ch/cha0/cha000/00/cha000_00.mesh", {"Skin", "Jacket"}),
        head = mesh("_Chainsaw/Character/ch/cha0/cha000/10/cha000_10.mesh", {"Face"}),
        hair = mesh("_Chainsaw/Character/ch/cha0/cha000/20/cha000_20.mesh", {"Hair", "Clip"}),
    }
    local body_updater = managed({
        get_BodyMesh = meshes.body, get_HeadMesh = meshes.head, get_HairMesh = meshes.hair,
        get_HasArmorMesh = false,
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
        on_draw_ui = function(f) draws[#draws + 1] = f end, on_script_reset = function() end}
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
    _G.imgui = imgui_stub(scenario.clicks, texts)

    local native_require = require
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
    _G.require = native_require
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
    assert(joined:find("REFF", 1, true), "v3 panel explains where full editing lives")
    assert(joined:find("Hide Hair", 1, true), "state groups are listed for manual switching")
    S.equal(meshes.hair.state(), {Hair = false, Clip = true}, "look unchanged after migrating from the menu")
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
assert(snap.notice.kind == "migrated" and snap.notice.overlaps == 0 and snap.notice.presets == 1)
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
S.equal(snap.groups[1].scope, {"hair/Hair"})
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

-- 状态组:新建、作用域(不重叠)、选项、材质三态、改名牵动引用、删除
snap = act({kind = "group-new", character = "Leon", name = "Face"})
snap = act({kind = "scope-add", character = "Leon", group = "Face", slot = "head", material = "Face"})
S.equal(snap.groups[2].scope, {"head/Face"})
assert(not pcall(act, {kind = "scope-add", character = "Leon", group = "Face", slot = "hair", material = "Hair"}),
    "a material belongs to one group only")
snap = act({kind = "option-new", character = "Leon", group = "Face"})
assert(snap.groups[2].active == "1")
snap = act({kind = "option-material", character = "Leon", group = "Face", option = "1", slot = "head", material = "Face", value = "off"})
run_frames()
assert(meshes.head.state().Face == false)
assert(not pcall(act, {kind = "option-material", character = "Leon", group = "Face", option = "1", slot = "body", material = "Skin", value = "off"}),
    "outside the scope")
snap = act({kind = "state-target", character = "Leon", index = 1, group = "Face", option = "1"})
snap = act({kind = "group-rename", character = "Leon", group = "Face", name = "Expression"})
assert(snap.groups[2].name == "Expression" and snap.states[1].targets[2].group == "Expression")
snap = act({kind = "option-rename", character = "Leon", group = "Expression", option = "1", name = "Pale"})
assert(snap.states[1].targets[2].option == "Pale")
snap = act({kind = "state-target-remove", character = "Leon", index = 1, target = 2})
assert(#snap.states[1].targets == 1)
snap = act({kind = "scope-remove", character = "Leon", group = "Expression", slot = "head", material = "Face"})
assert(#snap.groups[2].scope == 0)
snap = act({kind = "group-delete", character = "Leon", group = "Expression"})
assert(#snap.groups == 1)

-- 护甲镜像、备注、定位(不写配置)
snap = act({kind = "armor-mirror", character = "Leon", enabled = true})
assert(snap.armorMirror == true)
snap = act({kind = "note", character = "Leon", slot = "body", material = "Skin", text = "Skin base"})
assert(snap.slots[1].materials[1].note == "Skin base")
local before_locate = S.copy(files[CONFIG_PATH])
snap = act({kind = "locate", character = "Leon", slot = "hair", material = "Clip"})
assert(snap.locating.slot == "hair" and snap.locating.material == "Clip")
S.equal(files[CONFIG_PATH], before_locate, "locating never writes the config")

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
print("PASS: RE4 REFF v2 -> v3 migration (restore point, old saves become presets), v3 snapshot, manual / condition states / full outfit / state groups / scope / notes / locate, preset library with auto-saves, rejections")
