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

local function imgui_stub()
    local returns = {
        tree_node = function() return true end,
        combo = function(_, current) return false, current end,
        checkbox = function(_, value) return false, value end,
        input_text = function(_, value) return false, value end,
        button = function() return false end,
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
    _G.imgui = imgui_stub()

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
    return files, meshes, handlers, frames[1]
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

-- 装了 REFF：快照只含可序列化的值；操作走共用 Ops，存盘并重写到模型；角色变了就拒绝。
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
local handlers
local tick
files, meshes, handlers, tick = run({player = true, config = leon, reff = true})
assert(handlers["monkeysama.avm.snapshot"] and handlers["monkeysama.avm.action"] and handlers["monkeysama.avm.documentation"])
assert(handlers["monkeysama.avm.imports"] == nil and handlers["monkeysama.avm.preview"] == nil, "RE4 registers only what it serves")
local snap = handlers["monkeysama.avm.snapshot"]()
plain(snap, "snapshot")
assert(snap.game == "RE4" and snap.character == "Leon" and #snap.characters == 1)
assert(snap.characters[1].configured == true and snap.status.hp == 100)
assert(snap.base.base == true and snap.base.active == "Default" and snap.base.presets[1] == "Default")
assert(#snap.axes == 1 and snap.axes[1].name == "Hide Hair" and snap.axes[1].active == "On" and snap.axes[1].advanced == false)
assert(snap.settings.uiDissolveEnabled == false and snap.settings.uiDissolveTime == 2.5)
local hp_def
for _, def in ipairs(snap.conditions) do if def.id == "hp_ratio" then hp_def = def end end
assert(hp_def and hp_def.kind == "number" and hp_def.value == 100 and #hp_def.ops > 0)

local act = handlers["monkeysama.avm.action"]
-- 关掉状态组:材质回到整套造型的值
snap = act({kind = "active", character = "Leon", axis = "Hide Hair", preset = ""})
assert(snap.axes[1].active == "" and files[CONFIG_PATH].axes["Hide Hair"].active == "")
-- 加一条血量规则:状态组升级成高级组,条件与关系按 Ops 存
snap = act({kind = "condition-add", character = "Leon", axis = "Hide Hair", preset = "On",
    condition = {type = "hp_ratio", op = "<=", value = 30}, logic = "AND"})
local axis = snap.axes[1]
assert(axis.advanced == true and #axis.rules == 1 and axis.rules[1].preset == "On" and axis.rules[1].hits == false)
assert(axis.rules[1].conditions[1].type == "hp_ratio" and axis.rules[1].conditions[1].value == 30)
S.equal(files[CONFIG_PATH].axes["Hide Hair"].rules, {{conditions = {{type = "hp_ratio", op = "<=", value = 30}}, logic = "AND", preset = "On"}})
snap = act({kind = "hold", character = "Leon", axis = "Hide Hair", preset = "On", value = "1.5"})
assert(snap.axes[1].rules[1].hold == 1.5)
-- 整套造型(axis 为 nil)与全局设置
snap = act({kind = "active", character = "Leon", preset = ""})
assert(snap.base.active == "" and files[CONFIG_PATH].base.active == "")
snap = act({kind = "setting", id = "ui_dissolve_time", value = 3.26})
assert(snap.settings.uiDissolveTime == 3.3 and files[GLOBAL_PATH].ui_dissolve_time == 3.3)
-- 拒绝:角色已变化、目标不存在、未知操作 —— 都不改配置
local before = S.copy(files[CONFIG_PATH])
for _, bad in ipairs({
    {kind = "active", character = "Ada", preset = ""},
    {kind = "active", character = "Leon", axis = "Missing", preset = ""},
    {kind = "active", character = "Leon", preset = "Missing"},
    {kind = "condition-add", character = "Leon", axis = "Hide Hair", preset = "On", condition = {type = "hp_ratio", op = "<=", value = "x"}},
    {kind = "unknown", character = "Leon"},
}) do
    assert(not pcall(act, bad), "rejected: " .. tostring(bad.kind))
end
S.equal(files[CONFIG_PATH], before)
local docs = handlers["monkeysama.avm.documentation"]()
plain(docs, "documentation")
assert(#docs.sections == 3 and docs.sections[1].entries[1].title == "角色", "help follows the zh language setting")
print("PASS: RE4 REFF snapshot is plain data; actions go through shared ops, persist, and reject stale or invalid targets")

-- 第二阶段：编辑 / 归属 / 备注与定位 / 存档。快照给出当前模型的材质与各预设的值；
-- 操作和面板走同一批函数（Ops + Main 的共用函数），删除前留备份，定位只影响画面。
snap = handlers["monkeysama.avm.snapshot"]()
plain(snap, "phase-2 snapshot")
local slot_ids = {}
for _, slot in ipairs(snap.editor.slots) do slot_ids[#slot_ids + 1] = slot.id end
S.equal(slot_ids, {"body", "head", "hair"})
assert(snap.editor.slots[1].materials[2].name == "Jacket" and snap.editor.armorMirror == false)
assert(snap.base.values.Default.body.Jacket == false and snap.base.match.Default.status == "ok")
assert(snap.axes[1].values.On.hair.Hair == false and snap.axes[1].match == nil)
assert(snap.ownership.shared == false and snap.ownership.canReset == true and snap.ownership.canMatchKin == false)
assert(#snap.saves.slots == 0 and snap.saves.hasBackup == false)

local function run_frames(n) for _ = 1, n or 2 do tick() end end
-- 整套造型的材质（二值），重算后写到模型上
act({kind = "active", character = "Leon", preset = "Default"})
act({kind = "material", character = "Leon", preset = "Default", slot = "body", material = "Jacket", value = true})
run_frames()
assert(files[CONFIG_PATH].base.presets.Default.body.materials.Jacket == true and meshes.body.state().Jacket == true)
-- 状态组的三态 + 整块纳入 / 释放
act({kind = "material", character = "Leon", axis = "Hide Hair", preset = "On", slot = "hair", material = "Clip", value = "off"})
assert(files[CONFIG_PATH].axes["Hide Hair"].presets.On.hair.materials.Clip == false)
act({kind = "slot-bulk", character = "Leon", axis = "Hide Hair", preset = "On", slot = "hair", op = "release"})
assert(next(files[CONFIG_PATH].axes["Hide Hair"].presets.On.hair.materials) == nil)
assert(not pcall(act, {kind = "slot-bulk", character = "Leon", axis = "Hide Hair", preset = "On", slot = "hair", op = "all_on"}),
    "full-outfit bulk ops are rejected on state groups")
-- 新建 / 复制 / 改名 / 移动 / 删除（删除前留备份）
snap = act({kind = "preset-new", character = "Leon"})
assert(snap.base.active == "1" and snap.base.values["1"].body ~= nil, "a new full outfit captures the current look")
snap = act({kind = "preset-duplicate", character = "Leon", preset = "1"})
assert(snap.base.active == "1_1")
snap = act({kind = "preset-rename", character = "Leon", preset = "1_1", name = "Battle"})
S.equal(snap.base.presets, {"Default", "1", "Battle"})
snap = act({kind = "preset-move", character = "Leon", preset = "Battle", offset = -2})
S.equal(snap.base.presets, {"Battle", "Default", "1"})
assert(not pcall(act, {kind = "preset-rename", character = "Leon", preset = "Battle", name = "Default"}), "rename collision is rejected")
snap = act({kind = "preset-delete", character = "Leon", preset = "1"})
assert(snap.saves.hasBackup == true and files["ArmorVariantManager/backup/Leon.json"].base.presets["1"] ~= nil,
    "the backup is taken before the delete")
assert(snap.base.values["1"] == nil)
-- 状态组的新建 / 改名 / 删除，护甲镜像，备注
snap = act({kind = "axis-new", character = "Leon", name = "Face"})
assert(files[CONFIG_PATH].axes.Face.active == "1")
snap = act({kind = "axis-rename", character = "Leon", axis = "Face", name = "Expression"})
assert(files[CONFIG_PATH].axes.Face == nil and files[CONFIG_PATH].axes.Expression)
snap = act({kind = "axis-delete", character = "Leon", axis = "Expression"})
assert(files[CONFIG_PATH].axes.Expression == nil)
snap = act({kind = "armor-mirror", character = "Leon", enabled = true})
assert(snap.editor.armorMirror == true)
snap = act({kind = "note", character = "Leon", slot = "body", material = "Skin", text = "Skin base"})
assert(snap.editor.slots[1].materials[1].note == "Skin base" and files[CONFIG_PATH].material_notes.body.Skin == "Skin base")
-- 定位：临时只显示一个材质，不写配置
local before_locate = S.copy(files[CONFIG_PATH])
snap = act({kind = "locate", character = "Leon", slot = "hair", material = "Clip"})
assert(snap.editor.locating.slot == "hair" and snap.editor.locating.material == "Clip")
run_frames()
S.equal(meshes.hair.state(), {Hair = false, Clip = true}, "only the located material is shown on its slot")
S.equal(files[CONFIG_PATH], before_locate, "locating never writes the config")
-- 命名存档：存 / 读 / 删；还原点
snap = act({kind = "slot-save", character = "Leon", name = "Before test"})
assert(#snap.saves.slots == 1 and snap.saves.slots[1].own and snap.saves.slots[1].name == "Before test")
act({kind = "axis-new", character = "Leon", name = "Temp"})
snap = act({kind = "slot-load", character = "Leon", key = "Leon", name = "Before test"})
assert(files[CONFIG_PATH].axes.Temp == nil, "loading a slot replaces the config with the saved copy")
snap = act({kind = "slot-delete", character = "Leon", name = "Before test"})
assert(#snap.saves.slots == 0 and not pcall(act, {kind = "slot-delete", character = "Leon", name = "Before test"}))
snap = act({kind = "restore", character = "Leon", which = "backup"})
assert(files[CONFIG_PATH].base.presets["1"] ~= nil, "restoring the backup brings back the deleted preset")
assert(not pcall(act, {kind = "restore", character = "Leon", which = "nothing"}))
-- 归属：独立时可以初始化（先留备份，按当前外观建 default）；配置不平凡时不给认亲
assert(not pcall(act, {kind = "match-kin", character = "Leon"}), "match-kin is refused while the config has real presets")
snap = act({kind = "reset-config", character = "Leon"})
S.equal(snap.base.presets, {"default"})
assert(#snap.axes == 0 and snap.ownership.canMatchKin == true)
assert(not pcall(act, {kind = "make-independent", character = "Leon"}), "an independent config cannot be made independent")
print("PASS: RE4 REFF editing, state groups, notes, locate, named saves, restore points and ownership use the panel's shared functions")
