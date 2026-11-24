package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Core = require("ArmorVariantManager_Core.Runtime.Dissolve")
local WildsDissolve = require("ArmorVariantManager_Core.Games.Wilds.Dissolve")

local function near(a, b) return math.abs(a - b) < 1e-6 end
local function vec(v) return {v.x, v.y, v.z, v.w} end
local function assert_vec(actual, expected, message)
    for i = 1, 4 do assert(near(actual[i], expected[i]), (message or "vector") .. ": " .. table.concat(actual, ",")) end
end

-- 假网格：材质带 Dissolve_Rate / Dissolve_Flag 时视为溶解模板。
local function mesh(materials, enabled)
    local m = {enabled = enabled ~= false, materials = {}}
    for i, item in ipairs(materials) do
        local vars, values = {}, {}
        if item.template then
            vars = {"BaseColor", "Dissolve_Rate", "Dissolve_Flag"}
            values = {[0] = {x=1, y=1, z=1, w=1}, [1] = {x=0, y=0, z=0, w=0}, [2] = {x=1, y=item.morphed or 0, z=0.5, w=0}}
            if item.no_flag then vars, values[2] = {"BaseColor", "Dissolve_Rate"}, nil end
        end
        m.materials[i - 1] = {name = item.name, enabled = item.enabled ~= false, vars = vars, values = values}
    end
    function m:call(method, ...)
        local a, b, c = ...
        if method == "get_MaterialNum" then local n = 0; for _ in pairs(self.materials) do n = n + 1 end; return n
        elseif method == "getMaterialName" then return self.materials[a] and self.materials[a].name
        elseif method == "getMaterialsEnable" then return self.materials[a].enabled
        elseif method == "setMaterialsEnable" then self.materials[a].enabled = b; self.writes = (self.writes or 0) + 1
        elseif method == "get_Enabled" then return self.enabled
        elseif method == "set_Enabled" then self.enabled = a
        elseif method == "getMaterialVariableNum" then return #self.materials[a].vars
        elseif method == "getMaterialVariableName" then return self.materials[a].vars[b + 1]
        elseif method == "getMaterialFloat4" then return self.materials[a].values[b]
        elseif method == "setMaterialFloat4" then self.materials[a].values[b] = c
        end
    end
    return m
end
local function rate(m, j) return vec(m.materials[j].values[1]) end
local function flag(m, j) return vec(m.materials[j].values[2]) end

local now = 0
local function new_core(report)
    return Core.new({clock=function() return now end, report=report,
        vector=function(x, y, z, w) return {x=x, y=y, z=z, w=w} end})
end
local function tick(core, seconds) now = now + seconds; core:update() end

-- 非溶解模板瞬间切换；没有选定过渡或时长为 0 时也瞬间切换。
local core = new_core()
local m = mesh({{name="plain"}, {name="cloth", template=true}})
core:use(Core.settings(1, true))
core:set_material(m, 0, false, true)
assert(m.materials[0].enabled == false and not core:is_animating(m, 0))
core:use(nil)
core:set_material(m, 1, false, true)
assert(m.materials[1].enabled == false and not core:is_animating(m, 1))
core:use(Core.settings(0, true))
core:set_material(m, 1, true, false)
assert(m.materials[1].enabled == true and not core:is_animating(m, 1))

-- 原地互换（前进）：消失方 y = 0、出现方 y = 1，比例都从 0 走到 1；结束后关闭消失方并还原变量。
core = new_core()
local hide, show = mesh({{name="a", template=true}}), mesh({{name="b", template=true, enabled=false}})
core:use(Core.settings(1, true))
core:set_material(hide, 0, false, true)
core:set_material(show, 0, true, false)
core:use(nil)
assert(hide.materials[0].enabled and show.materials[0].enabled, "both sides stay on during the swap")
assert(core:material_target(hide, 0) == false and core:material_target(show, 0) == true)
assert_vec(rate(hide, 0), {0, 0, 0, 0}); assert_vec(flag(hide, 0), {1, 0, 0.5, 0})
assert_vec(rate(show, 0), {0, 0, 0, 0}); assert_vec(flag(show, 0), {1, 1, 0.5, 0})
tick(core, 0.05); tick(core, 0.05); tick(core, 0.05); tick(core, 0.05); tick(core, 0.05)
assert_vec(rate(hide, 0), {0.25, 0.25, 0.25, 0}, "progress follows the clock")
assert_vec(rate(show, 0), {0.25, 0.25, 0.25, 0})
for _ = 1, 20 do tick(core, 0.05) end
assert(hide.materials[0].enabled == false and show.materials[0].enabled == true)
assert_vec(rate(hide, 0), {0, 0, 0, 0}); assert_vec(flag(hide, 0), {1, 0, 0.5, 0}, "flag back to mdf")
assert_vec(flag(show, 0), {1, 0, 0.5, 0})
assert(core:material_target(hide, 0) == nil and not core:is_animating(show, 0))

-- 原地互换（后退）：比例从 1 走到 0，Reversing = 1，消失方 y = 1、出现方 y = 0。
core = new_core()
hide, show = mesh({{name="a", template=true}}), mesh({{name="b", template=true, enabled=false}})
core:use(Core.settings(1, false))
core:set_material(hide, 0, false, true)
core:set_material(show, 0, true, false)
assert_vec(rate(hide, 0), {1, 1, 1, 1}); assert(flag(hide, 0)[2] == 1)
assert_vec(rate(show, 0), {1, 1, 1, 1}); assert(flag(show, 0)[2] == 0)
tick(core, 0.05)
assert_vec(rate(hide, 0), {0.95, 0.95, 0.95, 1})

-- 倒放：出现 = 消失倒放，比例 1 -> 0，IsMorphed 与 Reversing 都为 0，不区分方向。
core = new_core()
hide, show = mesh({{name="a", template=true}}), mesh({{name="b", template=true, enabled=false}})
core:use(Core.settings(1, false, Core.REVERSE))
core:set_material(hide, 0, false, true)
core:set_material(show, 0, true, false)
assert_vec(rate(hide, 0), {0, 0, 0, 0}); assert(flag(hide, 0)[2] == 0)
assert_vec(rate(show, 0), {1, 1, 1, 0}); assert(flag(show, 0)[2] == 0)
tick(core, 0.05)
assert_vec(rate(show, 0), {0.95, 0.95, 0.95, 0})

-- 没有 Dissolve_Flag 的模板只写比例。
core = new_core()
m = mesh({{name="a", template=true, no_flag=true}})
core:use(Core.settings(1, true))
core:set_material(m, 0, false, true)
assert(core:is_animating(m, 0) and m.materials[0].values[2] == nil)

-- 仅有 Rate 的材质使用倒放出现，起点完全溶解。
local rate_only = mesh({{name="rate-only", template=true, no_flag=true, enabled=false}})
core:set_material(rate_only, 0, true, false)
assert_vec(rate(rate_only, 0), {1, 1, 1, 0})
tick(core, 0.05)
assert_vec(rate(rate_only, 0), {0.95, 0.95, 0.95, 0})

-- 中途反向：从旧动画离开的位置接着走；同方向重复写入不重启动画。
core = new_core()
m = mesh({{name="a", template=true}})
core:use(Core.settings(1, true))
core:set_material(m, 0, false, true)
for _ = 1, 6 do tick(core, 0.05) end
core:set_material(m, 0, false, true)
assert_vec(rate(m, 0), {0.3, 0.3, 0.3, 0}, "same phase keeps running")
core:set_material(m, 0, true, true)
assert_vec(rate(m, 0), {0.3, 0.3, 0.3, 0}, "reversal preserves the current mask")
assert(flag(m, 0)[2] == 0 and core:material_target(m, 0) == true)
for _ = 1, 5 do tick(core, 0.05) end
assert(core:is_animating(m, 0) and m.materials[0].enabled, "the reversed run only has the remaining 0.3 s")
for _ = 1, 2 do tick(core, 0.05) end
assert(not core:is_animating(m, 0) and m.materials[0].enabled)
assert_vec(rate(m, 0), {0, 0, 0, 0})

-- 动画中改为瞬间写入：收回动画、还原变量后直接切换。
core:use(Core.settings(1, true))
core:set_material(m, 0, false, true)
tick(core, 0.05)
core:use(nil)
core:set_material(m, 0, true, true)
assert(not core:is_animating(m, 0) and m.materials[0].enabled)
assert_vec(rate(m, 0), {0, 0, 0, 0}); assert_vec(flag(m, 0), {1, 0, 0.5, 0})

-- 瞬切的目标与旧动画相同也要收尾，并恢复启动前的参数。
core = new_core()
m = mesh({{name="a", template=true, morphed=0.25}})
m.materials[0].values[1] = {x=0.1, y=0.2, z=0.3, w=0.4}
core:use(Core.settings(1, true))
core:set_material(m, 0, false, true)
core:use(Core.settings(0, true))
core:set_material(m, 0, false, true)
assert(not m.materials[0].enabled and not core:is_animating(m, 0))
assert_vec(rate(m, 0), {0.1, 0.2, 0.3, 0.4})
assert_vec(flag(m, 0), {1, 0.25, 0.5, 0})
m.materials[0].enabled = true
core:use(Core.settings(1, true))
core:set_mesh(m, false, true)
assert(core:is_animating(m))
core:use(nil)
core:set_mesh(m, false, true)
assert(not m.enabled and not core:is_animating(m))

-- 首次或逐帧写入失败时回退到直接显隐，并恢复部分写入。
for _, fail_on in ipairs({1, 2}) do
    local messages = {}
    local fault = new_core(function(reason) messages[#messages + 1] = reason end)
    local model = mesh({{name="cloth", template=true}})
    local call, writes = model.call, 0
    function model:call(method, ...)
        local _, index = ...
        if method == "setMaterialFloat4" and index == 2 then
            writes = writes + 1
            if writes == fail_on then error("Flag write failed") end
        end
        return call(self, method, ...)
    end
    fault:use(Core.settings(1, true))
    fault:set_material(model, 0, false, true)
    tick(fault, 0.05)
    assert(#messages == 1 and messages[1]:find("Flag write failed", 1, true))
    assert(not model.materials[0].enabled and not fault:is_animating(model, 0))
    assert_vec(rate(model, 0), {0, 0, 0, 0})
    assert_vec(flag(model, 0), {1, 0, 0.5, 0})
end

-- 材质被换掉（名字变了）时丢弃动画，不再写入。
m = mesh({{name="a", template=true}})
core:use(Core.settings(1, true))
core:set_material(m, 0, false, true)
assert(core:is_animating(m, 0))
m.materials[0].name = "replaced"
tick(core, 0.05)
assert(not core:is_animating(m, 0) and m.materials[0].enabled)

-- 整个部件：溶解全部模板材质后关闭部件；原生不允许时不打开。
core = new_core()
m = mesh({{name="a", template=true}, {name="plain"}, {name="b", template=true}})
core:use(Core.settings(0.5, true))
core:set_mesh(m, false, true)
assert(m.enabled and core:mesh_target(m) == false)
for _ = 1, 12 do tick(core, 0.05) end
assert(m.enabled == false and core:mesh_target(m) == nil)
assert_vec(rate(m, 2), {0, 0, 0, 0})
core:set_mesh(m, true, false, false)
assert(m.enabled == false, "native hiding blocks showing")
core:set_mesh(m, true, false)
assert(m.enabled and flag(m, 0)[2] == 1)
core:use(nil)
local plain = mesh({{name="plain"}})
core:set_mesh(plain, false, true)
assert(plain.enabled == false, "parts without a template switch at once")

-- 脚本重置播完全部动画；切场景只丢弃引用。
core:use(Core.settings(1, true))
m = mesh({{name="a", template=true}})
core:set_material(m, 0, false, true)
core:finish_all()
assert(m.materials[0].enabled == false and not core:is_animating(m, 0))
core:set_material(m, 0, true, false)
core:abandon()
assert(not core:is_animating(m, 0) and m.materials[0].enabled)

-- 荒野接入：按规则选过渡。
local wilds_core = new_core()
local dissolve = WildsDissolve.new({core=wilds_core, config={}})
local r1 = {threshold=70, dissolve_enabled=true, dissolve_hide_time=2, dissolve_show_time=3}
local r2 = {threshold=40, dissolve_enabled=true}
local r3 = {state="drawn"}
local config = {transform_rules={r1, r2}, weapon_transform_rules={r3}}
dissolve.reset_character("hunter", {})
assert(dissolve.character("hunter") == nil, "first application never dissolves")
dissolve.rules_changed("hunter", {r1}, config)
S.equal(dissolve.character("hunter"), {duration=2, forward=true, appear="morph"})
dissolve.rules_changed("hunter", {r2}, config)
S.equal(dissolve.character("hunter"), {duration=0.5, forward=true, appear="morph"}, "missing times use 0.5 s")
dissolve.rules_changed("hunter", {r1}, config)
assert(dissolve.character("hunter").forward == false, "replacing a later rule of the same list runs backward")
dissolve.rules_changed("hunter", {}, config)
S.equal(dissolve.character("hunter"), {duration=3, forward=false, appear="morph"}, "an ended rule fades out")
dissolve.rules_changed("hunter", {r3}, config)
assert(dissolve.character("hunter") == nil, "rules without dissolve switch at once")
dissolve.rules_changed("hunter", {r1}, config)
local kept = dissolve.character("hunter")
dissolve.rules_changed("hunter", {r1}, config)
assert(dissolve.character("hunter") == kept, "same rule set keeps the transition")
dissolve.retain({hunter={armor=true}})
assert(dissolve.character("hunter") == kept)
dissolve.retain({})
assert(dissolve.character("hunter") == nil)

-- 界面设置：默认开启 1 秒，可关闭，时长限制在 0..30。
local settings = {}
local weapon = false
dissolve = WildsDissolve.new({core=wilds_core, config=settings, weapon_mode=function() return weapon end})
S.equal(dissolve.ui_settings(), {duration=1, forward=true, appear="morph"})
settings.ui_dissolve_time = 99
assert(dissolve.ui_settings().duration == 30)
settings.ui_dissolve_enabled = false
assert(dissolve.ui_settings() == nil)
settings.ui_dissolve_enabled, settings.ui_dissolve_time = true, 1

-- 读写入口：动画期间读到目标值；界面写入防具溶解、编辑武器时瞬间切换。
m = mesh({{name="a", template=true}, {name="b", template=true}, {name="c", template=true}})
dissolve.ui_call(m, "setMaterialsEnable", 0, false)
assert(m.materials[0].enabled and dissolve.call(m, "getMaterialsEnable", 0) == false)
assert(dissolve.ui_call(m, "getMaterialsEnable", 0) == false)
assert(dissolve.call(m, "getMaterialsEnable", 1) == true)
weapon = true
dissolve.ui_call(m, "setMaterialsEnable", 1, false)
assert(m.materials[1].enabled == false, "weapon editing switches at once")
weapon = false
dissolve.ui_call(m, "set_Enabled", false)
assert(m.enabled and dissolve.call(m, "get_Enabled") == false)
dissolve.with(nil, dissolve.call, m, "set_Enabled", true)
assert(m.enabled and dissolve.call(m, "get_Enabled") == true)
assert(not pcall(dissolve.with, dissolve.ui_settings(), function() error("boom") end))
local after = mesh({{name="a", template=true}})
dissolve.call(after, "setMaterialsEnable", 0, false)
assert(after.materials[0].enabled == false, "a failed write does not leave a transition selected")
dissolve.reset()
assert(dissolve.call(m, "getMaterialsEnable", 0) == true)

-- REF 和 REFF 共用的设置事务：落盘失败继续过渡，成功关闭时仅收尾界面过渡。
core = new_core()
local global = {ui_dissolve_enabled=true, ui_dissolve_time=1}
local owner = "hunter"
dissolve = WildsDissolve.new({core=core, config=global, actor_key=function() return owner end})
local one, two, rule_mesh = mesh({{name="cloth", template=true}}), mesh({{name="cloth", template=true}}),
    mesh({{name="cloth", template=true}})
dissolve.ui_call(one, "setMaterialsEnable", 0, false)
owner = "teammate"
dissolve.ui_call(two, "setMaterialsEnable", 0, false)
core:use(Core.settings(1, true))
core:set_material(rule_mesh, 0, false, true)
dissolve.retain({hunter={armor=true}, teammate={weapon=true}})
assert(core:is_animating(one, 0) and not core:is_animating(two, 0) and not two.materials[0].enabled)
dissolve.reset_character("hunter", {})
assert(not core:is_animating(one, 0) and not one.materials[0].enabled, "equipment change finishes the old owner's animation")
owner = "hunter"
dissolve.ui_call(one, "setMaterialsEnable", 0, true)
local saved = false
local session = {value=global, save=function() return saved, "disk full" end}
local model = require("ArmorVariantManager_Core.Games.Wilds.SettingsModel").new({config=global, transition=dissolve})
local controls = require("ArmorVariantManager_Core.Config.Settings").new({
    model=model, global_session=session, translate=function(key) return key end})
assert(not controls.action({id="ui_dissolve_enabled", value=false}))
assert(global.ui_dissolve_enabled and core:is_animating(one, 0))
saved = true
assert(controls.action({id="ui_dissolve_enabled", value=false}))
assert(not core:is_animating(one, 0) and one.materials[0].enabled and core:is_animating(rule_mesh, 0))
assert(controls.action({id="ui_dissolve_enabled", value=true}))
dissolve.ui_call(one, "setMaterialsEnable", 0, false)
assert(core:is_animating(one, 0) and controls.action({id="ui_dissolve_time", value=0}))
assert(not core:is_animating(one, 0) and not one.materials[0].enabled and core:is_animating(rule_mesh, 0))

-- 换装后的同名材质使用新布局及参数，旧部件动画不写入新材质。
core = new_core()
m = mesh({{name="cloth", template=true}})
core:use(Core.settings(1, true))
core:set_mesh(m, false, true)
m.materials[0].vars = {"BaseColor", "Roughness", "Dissolve_Rate"}
m.materials[0].values[1] = {x=0.8, y=0.7, z=0.6, w=0.5}
m.materials[0].values[2] = {x=0.2, y=0.2, z=0.2, w=0}
tick(core, 0.05)
assert(m.enabled and not core:is_animating(m))
assert_vec(vec(m.materials[0].values[1]), {0.8, 0.7, 0.6, 0.5})
core:set_material(m, 0, false, true)
core:finish_all()
assert_vec(vec(m.materials[0].values[2]), {0.2, 0.2, 0.2, 0})

-- 防具写入：动画期间按目标值判断，消失中改回显示时会反向，而不是被当成已显示跳过。
_G.sdk = {is_managed_object=function(object) return object ~= nil end}
local armor_mesh = mesh({{name="cloth", template=true}})
local Materials = require("ArmorVariantManager_Core.Games.Wilds.Materials")
dissolve = WildsDissolve.new({core=new_core(), config={}})
local materials = Materials.new({part_meshes=function(_, index) return index == 0 and {armor_mesh} or {} end},
    function() return true end, dissolve.call)
local character = {}
dissolve.with(Core.settings(1, true), materials.armor, character, {["0"]={materials={cloth=false}}})
assert(armor_mesh.materials[0].enabled and dissolve.call(armor_mesh, "getMaterialsEnable", 0) == false)
local writes = armor_mesh.writes or 0
dissolve.with(Core.settings(1, true), materials.armor, character, {["0"]={materials={cloth=false}}})
assert((armor_mesh.writes or 0) == writes, "the running hide is not restarted")
dissolve.with(Core.settings(1, true), materials.armor, character, {["0"]={materials={cloth=true}}})
assert(dissolve.call(armor_mesh, "getMaterialsEnable", 0) == true, "showing again reverses the running hide")
local plain_materials = Materials.new({part_meshes=function() return {armor_mesh} end}, function() return true end)
plain_materials.armor(character, {["0"]={materials={cloth=false}}})
assert(armor_mesh.materials[0].enabled == false, "without a call the write is direct")

-- 预设同时打开部件和关闭材质：应隐藏的材质全程保持关闭。
local combined = mesh({{name="cloth", template=true}, {name="trim", template=true}}, false)
core = new_core()
dissolve = WildsDissolve.new({core=core, config={}})
materials = Materials.new({part_meshes=function(_, index) return index == 0 and {combined} or {} end},
    function() return true end, dissolve.call)
local menu_actor = {get_type_definition=function() return {get_full_name=function() return "app.MenuModel" end} end}
dissolve.with(Core.settings(1, true), materials.armor, menu_actor,
    {["0"]={mesh_enabled=true, materials={cloth=false, trim=true}}})
assert(combined.enabled and not combined.materials[0].enabled)
assert(core:mesh_target(combined) == true and core:material_target(combined, 0) == nil)
tick(core, 0.05)
assert(not combined.materials[0].enabled)
assert_vec(rate(combined, 0), {0, 0, 0, 0}, "a part fade leaves the disabled material untouched")
assert_vec(rate(combined, 1), {0.05, 0.05, 0.05, 0})

-- 部件出现中单独关闭材质：接手同一遮罩，下一帧只有材质动画推进。
dissolve.ui_call(combined, "setMaterialsEnable", 1, false)
assert_vec(rate(combined, 1), {0.05, 0.05, 0.05, 0})
assert(flag(combined, 1)[2] == 1)
tick(core, 0.075)
assert_vec(rate(combined, 1), {0, 0, 0, 0})
assert(combined.enabled and not combined.materials[1].enabled)

-- 外观解算：防具首次应用只记录规则，规则状态变化时交给溶解；武器槽不参与。
local calls, rule_result = {}, {changed=false, rules={}}
local appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance").new({
    is_weapon_id=function() return false end, can_transform=function() return true end,
    game_object=function(object) return object end,
    rules={has_configured_rules=function() return true end, clear_last_state_cache=function() end,
        apply_transform_rules=function(_, _, _, overrides)
            return overrides, rule_result.changed, nil, nil, rule_result.rules
        end},
    dissolve={reset_character=function(key, rules) calls[#calls + 1] = {"reset", key, rules} end,
        rules_changed=function(key, rules, cfg) calls[#calls + 1] = {"changed", key, rules, cfg} end,
        reset=function() calls[#calls + 1] = {"clear"} end},
})
appearance.height = {set_runtime=function() end, reset=function() end}
local cfg = {presets={Base={["0"]={materials={cloth=true}}}}, default_preset="Base"}
appearance.overrides.armor = {["0"]={materials={cloth=true}}}
appearance.groups.armor = {}
local hunter = {}
appearance.resolve("armor", cfg, hunter, "armor")
assert(#calls == 1 and calls[1][1] == "reset" and calls[1][2] == tostring(hunter))
appearance.resolve("armor", cfg, hunter, "armor")
assert(#calls == 1, "unchanged rule state does not pick a transition")
rule_result.changed, rule_result.rules = true, {r1}
appearance.resolve("armor", cfg, hunter, "armor")
assert(#calls == 2 and calls[2][1] == "changed" and calls[2][3][1] == r1 and calls[2][4] == cfg)
appearance.resolve("weapon", cfg, hunter, "weapon")
assert(#calls == 2, "weapons switch at once")
appearance.reset()
assert(calls[3][1] == "clear")

-- 设置：旧 GlobalSettings.json 没有新字段时取默认值。
local Settings = require("ArmorVariantManager_Core.Games.Wilds.Settings")
local defaults = Settings.new()
assert(defaults.ui_dissolve_enabled == true and defaults.ui_dissolve_time == 1)
Settings.apply(defaults, {language="en"})
assert(defaults.ui_dissolve_enabled == true and defaults.ui_dissolve_time == 1)
Settings.apply(defaults, {ui_dissolve_enabled=false, ui_dissolve_time="2.5"})
assert(defaults.ui_dissolve_enabled == false and defaults.ui_dissolve_time == 2.5)

print("PASS dissolve")
