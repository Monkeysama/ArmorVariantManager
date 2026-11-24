package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Fixture = dofile("tests/app_fixture.lua")
local ShapeKeys = require("ArmorVariantManager_Core.Presets.ShapeKeys")
local ShapeKeyLink = require("ArmorVariantManager_Core.Runtime.ShapeKeyLink")
local ReffShapeKeys = require("ArmorVariantManager_Core.UI.Reff.ShapeKeys")
local Controller = require("ArmorVariantManager_Core.UI.Reff.Controller")
local State = require("ArmorVariantManager_Core.Runtime.State")

-- 字段读取只接受名字与 0；写入清空后删除字段，旧格式预设保持不变。
S.equal(ShapeKeys.read({sks={Hair="Long", Coat=0, Bad=1, [""]="x", Empty=""}}), {Hair="Long", Coat=0})
S.equal(ShapeKeys.read({sks="broken"}), {})
S.equal(ShapeKeys.read(nil), {})
local preset = {["0"]={materials={}}}
assert(ShapeKeys.set(preset, "Hair", nil) and preset.sks == nil)
assert(ShapeKeys.set(preset, "Hair", "Long"))
assert(ShapeKeys.set(preset, "Coat", 0))
S.equal(preset.sks, {Hair="Long", Coat=0})
assert(not ShapeKeys.set(preset, "", "Long"))
assert(not ShapeKeys.set(preset, "Hair", 2))
assert(not ShapeKeys.set(preset, "Hair", ""))
assert(ShapeKeys.set(preset, "Hair", nil) and ShapeKeys.set(preset, "Coat", nil))
assert(preset.sks == nil)

-- 覆盖保存沿用旧预设的联动；新数据自带字段时不覆盖。
local previous = {sks={Hair="Long"}}
local captured = ShapeKeys.carry(previous, {["0"]={}})
S.equal(captured.sks, {Hair="Long"})
assert(captured.sks ~= previous.sks)
S.equal(ShapeKeys.carry(previous, {sks={Hair="Short"}}).sks, {Hair="Short"})
assert(ShapeKeys.carry(nil, {}).sks == nil)

-- 解算顺序与材质合成一致：主列表、普通组（界面排序）、规则目标、全局组。
local function with(values) return {sks=values} end
local config = {
    default_preset="Base", presets={Base=with({Hair="Base", Coat="Base"}), Alt=with({Hair="Alt"}), Plain={}},
    group_order={"Second", "First"},
    groups={
        First={default_preset="On", presets={On=with({Coat="First", Boots="First"}), Off=with({Coat=0})}},
        Second={default_preset="On", presets={On=with({Coat="Second"})}},
        Zeta={presets={On=with({Boots="Zeta"})}},
        Lock={is_global=true, default_preset="Hide", presets={Hide=with({Hair="Lock"}), Show={}}},
    },
}
S.equal(ShapeKeys.resolve(config, {}), {Hair="Lock", Coat="First", Boots="First"})
S.equal(ShapeKeys.resolve(config, {[""]="Alt", First="Off", Zeta="On", Lock="Show"}),
    {Hair="Alt", Coat=0, Boots="Zeta"})
S.equal(ShapeKeys.resolve(config, {[""]="Missing", First="Missing", Lock=""}),
    {Hair="Lock", Coat="First", Boots="First"}, "missing names fall back to defaults")
S.equal(ShapeKeys.resolve(config, {Lock="Show"}, {[""]="Alt", First="Off", Second="Missing", Lock="Hide"}),
    {Hair="Alt", Coat=0, Boots="First"}, "rule targets override normal groups but not globals")
S.equal(ShapeKeys.resolve({presets={}}, {}), {})
S.equal(ShapeKeys.resolve(nil, {}), {})

-- 假 SKS：记录调用，返回值与公开接口一致。
local function fake_sks(options)
    options = options or {}
    local sks = {calls={}, listeners={}, picks={}, missing=options.missing or {}}
    function sks.select_group_option(owner, group, option)
        assert(owner == "ArmorVariantManager")
        sks.calls[#sks.calls + 1] = {"select", group, option}
        if sks.missing[group] then return false, "E_NOT_FOUND", "missing" end
        sks.picks[group] = option
        return true, nil, nil, {applied=true}
    end
    if not options.no_clear then
        function sks.clear_selection(owner)
            sks.calls[#sks.calls + 1] = {"clear"}
            sks.picks = {}
            return true
        end
    end
    function sks.on(event, fn) sks.listeners[event] = fn; return 1 end
    function sks.key_groups()
        return {{name="Hair", value=2, options={"Short", "Long"}}, {name="Coat", value=0, options={"Open"}}, {name=""}}
    end
    function sks.selection() return {owner="ArmorVariantManager", skipped={"Gone"}} end
    return sks
end
local function calls(sks)
    local result = sks.calls
    sks.calls = {}
    return result
end

local current
local link = ShapeKeyLink.new({api=function() return current end})
link.push({Hair="Long"})
assert(not link.available(), "without SKS nothing happens")
S.equal(link.view(), {available=false, groups={}, sent={}, errors={}})

current = fake_sks()
link.push(nil)
S.equal(calls(current), {}, "nil keeps SKS untouched")
link.push({Hair="Long", Coat=0})
local first = calls(current)
assert(#first == 2)
link.push({Hair="Long", Coat=0})
S.equal(calls(current), {}, "unchanged groups are not resent")
link.push({Hair="Short", Coat=0})
S.equal(calls(current), {{"select", "Hair", "Short"}})
link.push({Hair="Short"})
local released = calls(current)
S.equal(released, {{"clear"}, {"select", "Hair", "Short"}}, "released groups go back to the sculpt config")
link.push({})
S.equal(calls(current), {{"clear"}})
link.push({})
S.equal(calls(current), {})

-- 没有 clear_selection 的旧版 SKS 发 0；失败的键组不发还原。
current = fake_sks({no_clear=true, missing={Gone=true}})
link.push({Hair="Long", Gone="X"})
calls(current)
local view = link.view()
assert(view.available and view.errors.Gone == "E_NOT_FOUND" and view.sent.Hair == "Long")
S.equal(view.groups, {{name="Hair", options={"Short", "Long"}, value="Long"}, {name="Coat", options={"Open"}, value=0}})
link.push({Gone="X"})
S.equal(calls(current), {{"select", "Hair", 0}})
link.push({Gone="X"})
S.equal(calls(current), {}, "failed groups wait for the next SKS scan")
current.missing.Gone = nil
current.listeners.scan()
link.push({Gone="X"})
S.equal(calls(current), {{"select", "Gone", "X"}})
assert(link.view().errors.Gone == "E_NOT_FOUND", "groups SKS skipped are reported")

-- SKS 重置换了接口表：全部重发。
local replaced = fake_sks()
current = replaced
link.push({Gone="X"})
S.equal(calls(replaced), {{"select", "Gone", "X"}})
current = fake_sks()
current.select_group_option = function() error("boom") end
link.push({Hair="Long"})
assert(link.view().errors.Hair == "E_CALL")

-- 业务接口：设置写盘失败恢复原值，覆盖保存带上联动，本地猎人的解算结果。
for _, game in ipairs({"Wilds", "Rise"}) do
    local normalized = require("ArmorVariantManager_Core.Config.Normalize").apply(S.copy(config),
        require("ArmorVariantManager_Core.Games." .. game .. ".Config"))
    S.equal(normalized.presets.Base.sks, config.presets.Base.sks, game .. " normalize keeps the field")

    local cfg, saves, fail, suspended = S.copy(config), 0, false, false
    local player, body = {}, "armor"
    local state = State.new()
    local backend = {
        runtime={actors={local_player=function() return player end}, equipment={body_id=function() return body end},
            scene_object={}, meshes={}, guard={}, is_suspended=function() return suspended end},
        appearance={overrides={}, groups={}, state=state},
        save=function() saves = saves + 1; return not fail end,
        capture=function() return {["0"]={materials={cloth=true}}} end,
    }
    local session = {cache={armor=cfg}, load=function(id) return id == "armor" and cfg or nil end}
    local app = Fixture.new(game, {backend=backend, session=session})
    app.workspace.config = cfg
    app.workspace.state.group = ""

    assert(app.set_preset_shape_key("Plain", "Hair", "Short", "armor"))
    S.equal(cfg.presets.Plain.sks, {Hair="Short"})
    fail = true
    local ok, reason = app.set_preset_shape_key("Plain", "Hair", "Long", "armor")
    assert(not ok and cfg.presets.Plain.sks.Hair == "Short", game .. " failed save restores the field")
    assert(not app.set_preset_shape_key("Plain", "Coat", "Open", "armor") and cfg.presets.Plain.sks.Coat == nil)
    fail = false
    assert(not app.set_preset_shape_key("Missing", "Hair", "Long", "armor"))
    assert(app.set_preset_shape_key("Plain", "Hair", nil, "armor") and cfg.presets.Plain.sks == nil)
    app.workspace.state.weapon = true
    assert(not app.set_preset_shape_key("Plain", "Hair", "Long", "armor"))
    app.workspace.state.weapon = false

    assert(app.save_preset("Base", "armor"))
    S.equal(cfg.presets.Base.sks, {Hair="Base", Coat="Base"}, game .. " overwrite keeps the link")
    assert(cfg.presets.Base["0"].materials.cloth == true)
    assert(app.save_preset("Fresh", "armor") and cfg.presets.Fresh.sks == nil)

    assert(app.shape_key_selection() == nil, "not resolved yet")
    local context = state:get(tostring(player), "armor", "armor", cfg)
    context.groups, context.targets = {First="Off"}, {Second="On"}
    S.equal(app.shape_key_selection(), {Hair="Lock", Coat="Second"})
    suspended = true
    assert(app.shape_key_selection() == nil)
    suspended = false
    body = "other"
    S.equal(app.shape_key_selection(), {}, "equipment without config releases every group")
    body = nil
    assert(app.shape_key_selection() == nil)
    body = "armor"
    player = nil
    assert(app.shape_key_selection() == nil)
    player = {}

    local pushes, pushed = 0, false
    app.shape_keys = {push=function(want) pushes, pushed = pushes + 1, want end}
    app.update_shape_keys()
    assert(pushes == 1 and pushed == nil, "new player object is not resolved yet")
    app.shape_keys.push = function() error("broken") end
    app.update_shape_keys()
    assert(app.shape_keys.failure and app.shape_keys.failure:find("broken"))
    app.shape_keys.push = function() error("must stay stopped") end
    app.update_shape_keys()
end

-- REFF：快照只读，操作走控制器的装备校验。
local link_view = {available=true, groups={{name="Hair", options={"Long"}, value=0}}, sent={Hair="Long"}, errors={}}
local writes = {}
local reff = ReffShapeKeys.new({
    view=function() return link_view end,
    set=function(name, group, option, id) writes[#writes + 1] = {name, group, option, id}; return true end,
})
local reff_config = {presets={A=with({Hair="Long"}), B={}}, groups={G={presets={C=with({Coat=0})}}}}
local context = {id="armor", config=reff_config, group="", weapon=false, suspended=false}
local snap = reff.snapshot(context)
assert(snap.available and snap.editable and snap.reason == nil)
S.equal(snap.presets, {A={Hair="Long"}})
context.group = "G"
S.equal(reff.snapshot(context).presets, {C={Coat=0}})
context.weapon = true
snap = reff.snapshot(context)
assert(not snap.editable and snap.reason == "armor_only")
S.equal(snap.presets, {})
context.weapon = false
link_view.available = false
assert(reff.snapshot(context).reason == "sks_missing")
link_view.available = true

assert(reff.action({preset="C", group="G", keyGroup="Coat", option="Open"}, context))
assert(reff.action({preset="C", group="G", keyGroup="Coat", option=0}, context))
assert(reff.action({preset="C", group="G", keyGroup="Coat"}, context))
S.equal(writes, {{"C", "Coat", "Open", "armor"}, {"C", "Coat", 0, "armor"}, {"C", "Coat", nil, "armor"}})
assert(not reff.action({preset="C", group="", keyGroup="Coat"}, context))
assert(not reff.action({preset="", group="G", keyGroup="Coat"}, context))
assert(not reff.action({preset="C", group="G", keyGroup="Coat", option=3}, context))
context.weapon = true
assert(not reff.action({preset="C", group="G", keyGroup="Coat"}, context))
context.weapon = false

local controller = Controller.new({
    game="Wilds", version="test", context=function() return {
        id="armor", config=reff_config, group="G", group_names={"G"}, preset_names={"C"}, selected="C", pending={},
    } end,
    shape_keys=reff, parts=function() return {} end, main_label=function() return "main" end,
    language=function() return "zh-CN" end, theme=function() return "classic_white" end, operations={},
})
assert(controller.snapshot().shapeKeys.presets.C.Coat == 0)
writes = {}
controller.action({kind="shape-key", bodyId="armor", preset="C", group="G", keyGroup="Coat", option="Open"})
assert(#writes == 1)
assert(not pcall(controller.action, {kind="shape-key", bodyId="other", preset="C", group="G", keyGroup="Coat"}))
assert(#writes == 1, "stale equipment requests are rejected")

print("PASS shape_keys")
