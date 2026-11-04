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
    local files = {[GLOBAL_PATH] = {language = "zh", extra = {keep = true}}}
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
        on_draw_ui = function(f) draws[#draws + 1] = f end}
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
        return native_require(name)
    end
    local ok, err = pcall(dofile, main)
    _G.require = native_require
    assert(ok, err)

    assert(#frames == 1 and #draws == 1, "RE4 registers exactly one frame and one draw callback")
    for name in pairs(imports) do
        assert(not name:match("^ArmorVariantManager_Core%.App$") and not name:match("^ArmorVariantManager_Core%.UI%.")
            and not name:match("^ArmorVariantManager_Core%.Config%.") and not name:match("^ArmorVariantManager_Core%.Games%.Wilds")
            and not name:match("^ArmorVariantManager_Core%.Games%.Rise") and name ~= "reff.sdk",
            "RE4 must not load shared application module " .. name)
    end
    assert(imports["ArmorVariantManager_Core.Games.RE4.Main"])

    for _ = 1, 40 do frames[1]() end
    for _ = 1, 3 do draws[1]() end
    assert(#errors == 0, "unexpected error: " .. tostring(errors[1]))
    return files, meshes
end

-- 有玩家、有旧配置：整套造型铺底，状态组只覆盖它点名的材质，没点名的保持整套造型的值。
local files, meshes = run({player = true, config = leon})
S.equal(meshes.body.state(), {Skin = true, Jacket = false})
S.equal(meshes.head.state(), {Face = true})
S.equal(meshes.hair.state(), {Hair = false, Clip = true})
assert(files[CONFIG_PATH].extra.keep == true, "unknown config fields survive")
assert(files[CONFIG_PATH].axes["Hide Hair"].presets.On.hair.materials.Hair == false)
assert(files[GLOBAL_PATH].language == "zh", "global language is preserved")
print("PASS: RE4 standalone entry, no shared app/REFF modules, v2 base + sparse axis applied, unknown fields kept")

-- 没有玩家（标题画面、读盘中）：回调照常运行，不报错、不碰配置。
files = run({player = false, config = leon})
S.equal(files[CONFIG_PATH], leon)
print("PASS: RE4 without player context keeps callbacks quiet and config untouched")
