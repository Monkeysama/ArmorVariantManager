package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Fixture = dofile("tests/app_fixture.lua")
local Palette = require("ArmorVariantManager_Core.Presets.Palette")
local Writer = require("ArmorVariantManager_Core.Runtime.Palette")
local WildsPalette = require("ArmorVariantManager_Core.Games.Wilds.Palette")
local ReffPalette = require("ArmorVariantManager_Core.UI.Reff.Palette")
local Controller = require("ArmorVariantManager_Core.UI.Reff.Controller")

-- 字段读取只保留有限数值与 x..w 分量，溶解参数不接受覆盖。
S.equal(Palette.read({palette={["0"]={cloth={Tint={x=0.5, q=1, y=0/0}, Rough=0.3, Bad="x", Dissolve_Rate=1},
    empty={}, [""]={A=1}}, bad="x"}}), {["0"]={cloth={Tint={x=0.5}, Rough=0.3}}})
S.equal(Palette.read({palette="broken"}), {})

-- 设置：float、单个分量、多个分量；取消逐层清空，最后删除字段。
local preset = {["0"]={materials={cloth=true}}}
assert(Palette.set(preset, "0", "cloth", "Rough", 0.123456789))
assert(preset.palette["0"].cloth.Rough == 0.12346, "values are rounded to 1e-5")
assert(not Palette.set(preset, "0", "cloth", "Rough", 0.123456789), "same value is not a change")
assert(Palette.set(preset, "0", "cloth", "Tint", 0.2, "x"))
assert(Palette.set(preset, "0", "cloth", "Tint", {y=0.4, w=1}))
S.equal(preset.palette["0"].cloth.Tint, {x=0.2, y=0.4, w=1})
local ok, reason = Palette.set(preset, "0", "cloth", "Dissolve_Flag", 1)
assert(not ok and reason)
assert(not Palette.set(preset, "0", "cloth", "Tint", 0.2, "v"))
assert(not Palette.set(preset, "0", "cloth", "Tint", {v=1}))
assert(not Palette.set(preset, "0", "cloth", "Rough", 0/0))
assert(Palette.set(preset, "0", "cloth", "Tint", nil, "y"))
S.equal(preset.palette["0"].cloth.Tint, {x=0.2, w=1})
assert(not Palette.set(preset, "0", "cloth", "Missing", nil))
assert(Palette.set(preset, "0", "cloth", "Tint", nil))
assert(Palette.set(preset, "0", "cloth", "Rough", nil))
assert(preset.palette == nil and preset["0"].materials.cloth)

-- 覆盖保存沿用旧预设的调色，复制而不共享。
local previous = {palette={["0"]={cloth={Rough=0.5}}}}
local captured = Palette.carry(previous, {["0"]={}})
S.equal(captured.palette, previous.palette)
assert(captured.palette["0"] ~= previous.palette["0"])
assert(Palette.carry(previous, {palette={}}).palette.cloth == nil)

-- 合并顺序与材质合成一致：主列表、普通组（界面排序）、规则目标、全局组；float4 按分量合并。
local function with(values) return {palette={["0"]={cloth=values}}} end
local config = {
    default_preset="Base", presets={Base=with({Rough=0.1, Tint={x=1, y=1}}), Alt=with({Rough=0.2})},
    group_order={"Second", "First"},
    groups={
        First={default_preset="On", presets={On=with({Tint={y=0.5}}), Off=with({Rough=0.9})}},
        Second={default_preset="On", presets={On=with({Tint={x=0.3}, Metal=0.4})}},
        Lock={is_global=true, default_preset="Dark", presets={Dark=with({Tint={z=0}}), Plain={}}},
    },
}
S.equal(Palette.resolve(config, {}), {["0"]={cloth={Rough=0.1, Tint={x=0.3, y=0.5, z=0}, Metal=0.4}}})
S.equal(Palette.resolve(config, {[""]="Alt", Lock="Plain"}, {First="Off", Second="Missing"}),
    {["0"]={cloth={Rough=0.9, Tint={x=0.3, y=0.5}, Metal=0.4}}}, "rule targets override normal groups")
S.equal(Palette.resolve(nil, {}), {})

-- 假网格：Tint 为 float4，Rough / Metal 为 float，Dissolve_Rate 存在但不可覆盖。
local function mesh(materials)
    local m = {materials={}, writes=0}
    for i, item in ipairs(materials) do
        m.materials[i - 1] = {name=item, vars={"Tint", "Rough", "Metal", "Dissolve_Rate", "Texture"},
            types={4, 1, 1, 4, 7}, values={{x=1, y=1, z=1, w=1}, 0.5, 0.0, {x=0, y=0, z=0, w=0}, 0}}
    end
    function m:call(method, a, b, c)
        local mat = self.materials[a]
        if method == "get_MaterialNum" then local n = 0; for _ in pairs(self.materials) do n = n + 1 end; return n
        elseif method == "getMaterialName" then return mat and mat.name
        elseif method == "getMaterialVariableNum" then return #mat.vars
        elseif method == "getMaterialVariableName" then return mat.vars[b + 1]
        elseif method == "getMaterialVariableType" then return mat.types[b + 1]
        elseif method == "getMaterialFloat" then return mat.values[b + 1]
        elseif method == "getMaterialFloat4" then return mat.values[b + 1]
        elseif method == "setMaterialFloat" or method == "setMaterialFloat4" then mat.values[b + 1] = c; self.writes = self.writes + 1
        end
    end
    return m
end
local function tint(m, j) local v = m.materials[j or 0].values[1]; return {v.x, v.y, v.z, v.w} end
local vector = function(x, y, z, w) return {x=x, y=y, z=z, w=w} end

local writer = Writer.new({vector=vector})
local m = mesh({"cloth", "metal"})
assert(not writer.active("hunter"))
writer.apply("hunter", m, {cloth={Rough=0.8, Tint={x=0.2}, Dissolve_Rate={x=1}}})
assert(m.materials[0].values[2] == 0.8)
S.equal(tint(m), {0.2, 1, 1, 1})
S.equal(m.materials[0].values[4], {x=0, y=0, z=0, w=0}, "dissolve variables are never written")
assert(m.writes == 2 and writer.active("hunter"))
writer.apply("hunter", m, {cloth={Rough=0.8, Tint={x=0.2}}})
assert(m.writes == 2, "unchanged targets are not rewritten")
m.materials[0].values[2] = 0.1
m.materials[0].values[1] = {x=0.9, y=1, z=0.25, w=1}
writer.apply("hunter", m, {cloth={Rough=0.8, Tint={x=0.2}}})
assert(m.materials[0].values[2] == 0.8, "another plugin's write to a covered parameter is undone")
S.equal(tint(m), {0.2, 1, 0.25, 1}, "uncovered components keep their current value")
writer.apply("hunter", m, {cloth={Tint={y=0.3}}})
assert(m.materials[0].values[2] == 0.5, "a released float goes back to the original")
S.equal(tint(m), {1, 0.3, 0.25, 1}, "a released component goes back; the new one is written")
writer.apply("hunter", m, nil)
S.equal(tint(m), {1, 1, 0.25, 1})
local writes = m.writes
writer.apply("hunter", m, nil)
assert(m.writes == writes, "nothing left to restore")

-- 界面读取：列出 float / float4，不含溶解参数与其他类型，被覆盖时带原值。
writer.apply("hunter", m, {metal={Metal=0.7}})
local params = writer.inspect("hunter", m, "metal")
S.equal(params, {{name="Metal", type="float", value=0.7, original=0.0}, {name="Rough", type="float", value=0.5},
    {name="Tint", type="float4", value={1, 1, 1, 1}}})
S.equal(writer.inspect("hunter", m, "missing"), {})

-- 换装：本帧没出现的网格被丢弃；新网格实例重新记录原值。
writer.begin("hunter")
local fresh = mesh({"metal"})
fresh.materials[0].values[3] = 0.25
writer.apply("hunter", fresh, {metal={Metal=0.6}})
writer.finish("hunter")
assert(writer.inspect("hunter", m, "metal")[1].original == nil, "the old mesh was dropped")
assert(writer.inspect("hunter", fresh, "metal")[1].original == 0.25)
writer.begin("hunter"); writer.finish("hunter")
assert(not writer.active("hunter"))
writer.apply("hunter", fresh, {metal={Metal=0.1}})
writer.reset()
assert(not writer.active("hunter"))

-- 荒野接入：按上下文解算；没有覆盖也没有写过的参数时不查网格。
local lookups = 0
local armor_mesh, weapon_mesh = mesh({"cloth"}), mesh({"blade"})
local adapter = WildsPalette.new({meshes={
    part_meshes=function(_, index) lookups = lookups + 1; return index == 0 and {armor_mesh} or {} end,
    first=function(object) return object.mesh end,
}})
local character = {}
local armor_config = {default_preset="Base", presets={Base={palette={["0"]={cloth={Rough=0.9}}}}}}
adapter.apply(character, "armor", nil, {groups={}, overrides={}}, {presets={Plain={}}, default_preset="Plain"})
assert(lookups == 0, "characters without palette entries are skipped")
adapter.apply(character, "armor", nil, {groups={}, overrides={["0"]={materials={}}}}, armor_config)
assert(lookups == 6 and armor_mesh.materials[0].values[2] == 0.9)
local weapon_config = {default_preset="W", presets={W={palette={["1"]={blade={Metal=0.3}}}}}}
adapter.apply(character, "weapon", {{mesh=mesh({"grip"})}, {mesh=weapon_mesh}}, {groups={}}, weapon_config)
assert(weapon_mesh.materials[0].values[3] == 0.3, "weapon parts are object indices")
S.equal(adapter.inspect(character, "armor", nil, "0", "cloth")[2], {name="Rough", type="float", value=0.9, original=0.5})
adapter.apply(character, "armor", nil, {groups={}, overrides={}}, {presets={}})
assert(armor_mesh.materials[0].values[2] == 0.5, "removing the preset restores the original")
adapter.reset()

-- 业务接口：写盘失败恢复原值；不支持调色的后端拒绝；覆盖保存沿用调色。
for _, game in ipairs({"Wilds", "Rise"}) do
    local cfg = S.copy(config)
    local fail, saves = false, 0
    local backend = {save=function() saves = saves + 1; return not fail end,
        capture=function() return {["0"]={materials={cloth=true}}} end}
    if game == "Wilds" then
        backend.palette = {}
        backend.material_params = function(part, material, weapon) return {{name=part .. material .. tostring(weapon)}} end
    end
    local app = Fixture.new(game, {backend=backend})
    app.workspace.config = cfg
    app.workspace.state.group = "First"
    if game == "Rise" then
        assert(not app.set_preset_material_param("On", "0", "cloth", "Rough", 0.5, nil, "armor"))
        assert(app.material_params("0", "cloth") == nil)
    else
        assert(app.set_preset_material_param("On", 0, "cloth", "Rough", 0.5, nil, "armor") and saves == 1)
        S.equal(cfg.groups.First.presets.On.palette["0"].cloth, {Tint={y=0.5}, Rough=0.5})
        assert(app.set_preset_material_param("On", "0", "cloth", "Rough", 0.5, nil, "armor") and saves == 1,
            "an unchanged value is not saved again")
        fail = true
        assert(not app.set_preset_material_param("On", "0", "cloth", "Tint", nil, nil, "armor"))
        S.equal(cfg.groups.First.presets.On.palette["0"].cloth, {Tint={y=0.5}, Rough=0.5}, "failed save restores")
        fail = false
        assert(not app.set_preset_material_param("Missing", "0", "cloth", "Rough", 1, nil, "armor"))
        assert(not app.set_preset_material_param("On", "0", "cloth", "Dissolve_Rate", 1, nil, "armor"))
        S.equal(app.material_params("0", "cloth"), {{name="0clothfalse"}})
        app.workspace.state.weapon = true
        S.equal(app.material_params(1, "blade"), {{name="1bladetrue"}})
        app.workspace.state.weapon = false
        assert(app.save_preset("On", "armor"))
        S.equal(cfg.groups.First.presets.On.palette["0"].cloth, {Tint={y=0.5}, Rough=0.5}, "overwrite keeps palette")
        assert(cfg.groups.First.presets.On["0"].materials.cloth == true)
    end
end

-- REFF：快照列出当前分组带调色的预设；操作与参数读取都校验装备和分组。
local writes_seen = {}
local reff = ReffPalette.new({
    set=function(...) writes_seen[#writes_seen + 1] = {...}; return true end,
    params=function(part, material) return {{name=part .. ":" .. material}} end,
})
local context = {id="armor", config=config, group="First", suspended=false}
S.equal(reff.snapshot(context).presets, {On={["0"]={cloth={Tint={y=0.5}}}}, Off={["0"]={cloth={Rough=0.9}}}})
context.suspended = true
S.equal(reff.snapshot(context), {editable=false, presets={}})
context.suspended = false
assert(reff.action({preset="On", group="First", part=0, material="cloth", param="Rough", value=0.4}, context))
S.equal(writes_seen[1], {"On", "0", "cloth", "Rough", 0.4, nil, "armor"})
assert(not reff.action({preset="On", group="", part=0, material="cloth", param="Rough"}, context))
assert(not reff.action({preset="", group="First", part=0, material="cloth", param="Rough"}, context))
assert(not reff.action({preset="On", group="First", part=true, material="cloth", param="Rough"}, context))
S.equal(reff.params({part=2, material="cloth"}, context).params, {{name="2:cloth"}})

local controller = Controller.new({
    game="Wilds", version="test", context=function() return {
        id="armor", config=config, group="First", group_names={"First"}, preset_names={"On"}, selected="On", pending={},
    } end,
    palette=reff, parts=function() return {} end, main_label=function() return "main" end,
    language=function() return "zh-CN" end, theme=function() return "classic_white" end,
    operations={["material-param"]=reff.action},
})
assert(controller.snapshot().palette.presets.On)
controller.action({kind="material-param", bodyId="armor", preset="On", group="First", part=0, material="cloth",
    param="Metal", value={x=1}})
assert(#writes_seen == 2 and writes_seen[2][4] == "Metal")
assert(not pcall(controller.action, {kind="material-param", bodyId="old", preset="On", group="First", part=0,
    material="cloth", param="Metal"}))
S.equal(controller.material_params({bodyId="armor", part=1, material="cloth"}).params, {{name="1:cloth"}})
S.equal(controller.material_params({bodyId="old", part=1, material="cloth"}).params, {}, "stale equipment reads nothing")

print("PASS palette")
