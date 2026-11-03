game = {wilds=true, prefix="ArmorVariantManager_Core.Games.Wilds."}
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix = "ArmorVariantManager_Core."
local Defaults = require(prefix .. "Presets.Defaults")
local Height = require(prefix .. "GroundClippingFix")
local legacy = dofile("tests/fixtures/legacy/defaults.lua")
local function preset(value) return {["0"] = {materials = {cloth = value}}} end

-- 默认初始化比较完整结果及选择表；保留缺省、空字符串和无效名称的旧区别。
for _, game in ipairs({"Wilds", "Rise"}) do
    local policy = require(prefix .. "Games." .. game .. ".Presets")
    for _, default in ipairs({false, "", "missing", "Hide"}) do
        for _, order in ipairs({{}, {"missing"}, {"Show", "Hide"}}) do
            local config = {default_preset="Base", presets={Base=preset(true)}, groups={
                Normal={default_preset="Chosen", presets={Chosen={["1"]={mesh_enabled=false}}}},
                Global={is_global=true, default_preset=default or nil, preset_order=order,
                    presets={Hide=preset(false), Show=preset(true)}}}}
            local expected, selected, normal, base_selected = {}, {old="kept"}
            local env = setmetatable({active_overrides={id=expected}, active_group_presets={id=selected},
                load_config_data=function() return config end,
                bump_overrides_version=function() end,
                Applied={invalidate_body=function() end},
                ground_clipping_presets={reset=function() end},
                GroundClippingFix=Height,
            }, {__index=_G})
            env.merge_preset_into_overrides=function(id, value) policy.merge_into(env.active_overrides[id], value) end
            env.merge_global_preset_into_overrides=function(id, value) policy.merge_global_into(env.active_overrides[id], value) end
            env.TransformManager={
                set_model_base=function(_, value, names)
                    normal, base_selected = S.copy(value), S.copy(names)
                    return S.copy(value)
                end,
                update_base_preset=function(_, _, group, name) base_selected[group]=name end,
            }
            legacy[game](env)("id")
            local actual = game == "Wilds" and {ground_clipping_fix=Height.default_settings(config)} or {}
            local names = game == "Wilds" and {old="kept"} or {}
            Defaults.normal(config, policy, actual, names)
            if game == "Rise" then S.equal(actual, normal, "normal baseline before global lock") end
            Defaults.globals(config, policy, actual, names, policy.default_global)
            if game == "Wilds" then
                local app = require(prefix .. "Games.Wilds.Appearance").new({load=function() return config end})
                app.groups.id = {old="kept"}
                app.defaults("id")
                S.equal(app.overrides.id, actual, "Wilds appearance default composition")
                S.equal(app.groups.id, names, "Wilds appearance default selections")
            end
            S.equal(actual, env.active_overrides.id, game .. " defaults")
            S.equal(names, env.active_group_presets.id, game .. " selections")
            if game == "Rise" then S.equal(names, base_selected, "rule baseline selections") end
        end
    end
end
print("PASS: both legacy default initializers, global fallback and selections")

-- 运行正式入口的会话装配，确认别名、过滤与场景清理连接到同一状态所有者。
do
    local configured, eligible, addresses, evaluations, resets = false, false, 0, 0, 0
    local cfg = {presets={Base=preset(true)}, default_preset="Base", groups={}}
    local character = {}
    local env = setmetatable({
        runtime={equipment={},materials={}},
        config_session={load=function() return cfg end},
        actors={can_transform=function() return eligible end},
        safe_get_game_object=function(value) addresses=addresses+1; return value end,
        TransformManager={
            has_configured_rules=function() return configured end,
            apply_transform_rules=function(_, _, _, base)
                evaluations=evaluations+1
                return base, false, nil, nil
            end,
            clear_last_state_cache=function() resets=resets+1 end,
        },
    }, {__index=_G})
    local main = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
    local body = S.section(main, "-- 只接受本轮 PlayerManager 提供的真实玩家。", "-- 当前 Body 的配置数据结构")
    local app, overrides, groups, state, height, transform, weapon = assert(load(body .. [[
return appearance, active_overrides, active_group_presets, actor_runtime, ground_clipping_presets,
    apply_transform_rules_for_character, is_weapon_id
]], "actual-appearance-wiring", "t", env))()
    assert(app.overrides == overrides and app.groups == groups and app.state == state and app.height == height)
    assert(weapon("wp03_custom") and weapon("it1234_custom") and not weapon("armor"))
    app.defaults("armor")
    local baseline = overrides.armor
    transform(cfg, character, baseline, function() error("Unexpected merge") end)
    configured=true
    transform(cfg, character, baseline, function() error("Unexpected merge") end)
    assert(addresses == 0 and evaluations == 0, "Empty conditions and preview actors must not read combat objects")
    eligible=true
    local result, changed = app.resolve("armor", cfg, character, "armor")
    assert(result ~= baseline and changed and addresses == 1 and evaluations == 1)
    assert(state:peek(tostring(character), "armor", "armor", cfg).overrides == result)
    local selected = groups.armor
    app.reset()
    assert(resets == 1 and state:peek(tostring(character), "armor", "armor", cfg) == nil)
    assert(overrides.armor == baseline and groups.armor == selected, "Scene reset preserves manual intent")
end
print("PASS: Wilds entry appearance wiring, actor eligibility and reset ownership")

-- 执行真实崛起规则、共享处理器和角色状态；只替换引擎信号读取。
local loaded, samples = {}, 0
local signals = {sample_condition=function(_, handler, actor, player) return handler.get_state(actor, player) end}
local env = setmetatable({}, {__index=_G})
env.require = function(name)
    if name == prefix .. "Games.Rise.ConditionRegistry" then
        return {weapon={get_state=function(_, player) samples=samples+1; return player.drawn end}}
    end
    if name == prefix .. "Games.Rise.Signals" then
        return signals
    end
    if loaded[name] then return loaded[name] end
    loaded[name] = assert(loadfile("ArmorVariantManager/reframework/autorun/" .. name:gsub("%.", "/") .. ".lua", "t", env))()
    return loaded[name]
end
local config = {enable_transform=true, transform_type="weapon", default_preset="Base",
    presets={Base=preset(true), Hide=preset(false)}, groups={},
    weapon_transform_rules={{state="drawn", targets={{group="", preset="Hide"}}}}}
local configs, reads = {armor=config, weapon=S.copy(config)}, {}
local app = env.require(prefix .. "Games.Rise.Appearance").new(function(id)
    reads[id]=(reads[id] or 0)+1
    return configs[id]
end)
local a, b, menu = {id="armor", weapon="weapon"}, {id="armor"}, {id="armor"}
local pa, pb = {drawn=true}, {drawn=false}
local outputs, versions = {}, {}
local runtime = {equipment={
    body_id=function(object) return object.id end,
    weapon_id=function(object) return object.weapon end,
    weapons=function(object) return object.weapon and {[2]={}} end,
}, materials={}}
for _, slot in ipairs({"armor", "weapon"}) do
    local function apply(object, value, options)
        outputs[object]=outputs[object] or {}; outputs[object][slot]=S.copy(value)
        versions[object]=versions[object] or {}; versions[object][slot]=options.version
        assert(options.body_id == (slot == "armor" and object.id or object.weapon))
    end
    if slot == "armor" then runtime.materials.armor=apply
    else runtime.materials.weapon=function(object, parts, value, options)
        assert(parts[1] == nil and parts[2], "Sparse weapon parts must reach materials")
        apply(object, value, options)
    end end
end
local function tick(object, player, is_local, is_event)
    app.process({obj=object, player=player, is_local=is_local}, is_event, runtime)
end
tick(a, pa, true); tick(b, pb, false)
assert(reads.armor == 2 and reads.weapon == 1, "Load once per processed slot")
assert(not outputs[a].armor["0"].materials.cloth and outputs[b].armor["0"].materials.cloth)
assert(not outputs[a].weapon["0"].materials.cloth)
assert(app.overrides.armor["0"].materials.cloth and app.groups.armor[""] == "Base")
local state_a = app.state:peek(tostring(a), "armor", "armor", config)
local state_b = app.state:peek(tostring(b), "armor", "armor", config)
assert(state_a.groups[""] == "Hide" and state_b.groups[""] == "Base")
local version = versions[a].armor
tick(a, pa, true)
assert(versions[a].armor == version, "Unchanged rule output keeps material fast path")
pa.drawn=false; pb.drawn=true
tick(a, pa, true); tick(b, pb, false)
assert(outputs[a].armor["0"].materials.cloth and not outputs[b].armor["0"].materials.cloth)
assert(versions[a].armor > version, "Changed result advances only this actor slot")
local before = samples
tick(menu, nil, true); tick(b, pb, false, true)
assert(samples == before, "Menu and event actors do not sample combat signals")
assert(outputs[menu].armor["0"].materials.cloth and outputs[b].armor["0"].materials.cloth)
assert(app.state:peek(tostring(a), "armor", "armor", config) == state_a, "Budget-skipped actors survive")
a.weapon=nil; tick(a, pa, true)
assert(app.state:peek(tostring(a), "weapon", "weapon", configs.weapon) == nil)
app.forget_actor(a)
assert(app.state:peek(tostring(a), "armor", "armor", config) == nil)
assert(app.state:peek(tostring(b), "armor", "armor", config) == state_b)
app.reset()
assert(app.state:peek(tostring(b), "armor", "armor", config) == nil and app.overrides.armor)
local empty = {presets={}, groups={}}
configs.empty=empty; b.id="empty"; before=samples; local old=outputs[b].armor
tick(b, pb, false)
assert(outputs[b].armor == old and samples == before and app.overrides.empty == nil)
b.id="missing"; tick(b, pb, true)
assert(app.state:peek(tostring(b), "armor", "armor", config) == nil)
print("PASS: Rise shared pipeline, actor/slot isolation, menu gate, versioning and lifecycle")

-- 调度器直接消费应用回调；配置和手动基线在场景重置后仍能重建角色结果。
local rise = prefix .. "Games.Rise."
local entry_a = {obj=a, player=pa, is_local=true}
local entry_b = {obj=b, player=pb, is_local=false}
local directory = {local_entry=entry_a, entries={entry_a, entry_b}, others={entry_b}}
local events = {}
loaded[rise .. "Actors"] = {new=function() return {
    get=function() return directory end, events=function() return events end,
    tick=function() end, reset=function() end,
} end}
runtime.equipment.begin_frame = function() end
runtime.equipment.clear = function() end
runtime.materials.clear = function() end
loaded[rise .. "Equipment"] = {new=function() return runtime.equipment end}
loaded[rise .. "Materials"] = {new=function() return runtime.materials end}
loaded[rise .. "SceneObject"] = {is_alive=function(object) return object ~= nil end}
loaded[rise .. "DissolveTransition"] = {new=function() return {
    tick=function() end, abandon=function() end, finish_all=function() end,
} end}
signals.begin_frame = function() end
signals.clear = function() end
signals.bind_actor = function() end
signals.forget_actor = function() end
local now = 0
env.os = {clock=function() return now end}
local session = env.require(rise .. "Runtime").new({}, app)
b.id="armor"; pa.drawn=true; pb.drawn=false
local function advance(frames)
    for _ = 1, frames do now=now+1/60; session.tick() end
end
advance(20)
assert(not outputs[a].armor["0"].materials.cloth and outputs[b].armor["0"].materials.cloth)
local intent = app.overrides.armor
session.request_reset(); advance(1)
assert(app.state:peek(tostring(a), "armor", "armor", config) == nil)
assert(app.overrides.armor == intent)
advance(20)
assert(not outputs[a].armor["0"].materials.cloth and outputs[b].armor["0"].materials.cloth)
events={menu}; before=samples; advance(10)
local event_samples=samples
advance(10)
assert(event_samples == samples and outputs[menu].armor["0"].materials.cloth)
events={}; advance(20)
assert(not outputs[a].armor["0"].materials.cloth)
session.stop()
assert(app.state:peek(tostring(a), "armor", "armor", config) == nil)
print("PASS: actual Rise Runtime consumes Appearance callbacks across scene/event/reset")

-- 手动切换必须改变规则回滚基础，并触发同装备各角色的材质版本更新。
config.presets.Manual=preset(true)
config.presets.Manual["0"].materials.ribbon=false
local unchanged=S.copy(config)
assert(app.select("armor", config, "", "Manual"))
pa.drawn=true; pb.drawn=false
tick(a, pa, true); tick(b, pb, false)
assert(not outputs[a].armor["0"].materials.cloth and outputs[b].armor["0"].materials.cloth)
assert(not outputs[a].armor["0"].materials.ribbon and not outputs[b].armor["0"].materials.ribbon)
assert(app.groups.armor[""] == "Manual" and app.groups.weapon[""] == "Base")
pa.drawn=false; tick(a, pa, true)
assert(outputs[a].armor["0"].materials.cloth and not outputs[a].armor["0"].materials.ribbon,
    "Ending a rule returns to the new manual baseline")
local version_before = versions[a].armor
assert(app.select("armor", config, "", "Hide"))
tick(a, pa, true); tick(b, pb, false)
assert(not outputs[a].armor["0"].materials.cloth and not outputs[b].armor["0"].materials.cloth)
assert(versions[a].armor > version_before, "Same combat signal must still observe a manual selection")
S.equal(config, unchanged, "Manual selection leaves stored config unchanged")

config.groups.Lock={is_global=true, default_preset="Hide", presets={Hide=preset(false), Show=preset(true)}}
env.require(prefix .. "Games.Rise.Rules").invalidate_config("armor", config)
assert(app.select("armor", config, "", "Manual"))
tick(a, pa, true)
assert(not outputs[a].armor["0"].materials.cloth, "Global hide remains higher priority than manual show")
assert(app.select("armor", config, "Lock", "Show"))
tick(a, pa, true)
assert(outputs[a].armor["0"].materials.cloth, "Switching global group releases its old hide")
assert(app.groups.armor[""] == "Manual" and app.groups.armor.Lock == "Show")

config.enable_transform=false
tick(a, pa, true); version_before=versions[a].armor
assert(app.select("armor", config, "", "Hide"))
tick(a, pa, true)
assert(not outputs[a].armor["0"].materials.cloth and versions[a].armor > version_before,
    "Without rules, selecting a preset must still invalidate cached material output")
version_before=versions[a].armor
tick(a, pa, true)
assert(versions[a].armor == version_before, "Stable manual state retains the fast path")
local selected_before, result_before = S.copy(app.groups.armor), app.overrides.armor
assert(not app.select("armor", config, "Lock", "deleted"))
assert(not app.select("unloaded", config, "deleted", "Base"))
assert(app.overrides.armor == result_before and app.overrides.unloaded == nil)
S.equal(app.groups.armor, selected_before, "Invalid selection leaves manual intent unchanged")
assert(app.select("fresh", config, "", "Manual"))
assert(app.groups.fresh[""] == "Manual", "Selection can initialize an unprocessed equipment config")
print("PASS: Rise manual selections, rule rollback, global release, actor versions and invalid targets")

-- 显隐草稿与角色结果隔离，关闭条件时也不能绕过全局隐藏。
config.enable_transform=true
assert(app.select("armor", config, "", "Manual"))
assert(app.select("armor", config, "Lock", "Show"))
local stored=S.copy(config)
local old_draft=app.overrides.armor
assert(app.edit("armor",0,"cloth",false))
assert(app.edit("armor",0,nil,false))
assert(old_draft["0"].materials.cloth, "Published old draft remains unchanged")
pa.drawn=true; pb.drawn=false
tick(a,pa,true); tick(b,pb,false)
assert(not outputs[a].armor["0"].materials.cloth and not outputs[b].armor["0"].materials.cloth)
assert(not outputs[b].armor["0"].mesh_enabled)
pa.drawn=false; tick(a,pa,true)
assert(not outputs[a].armor["0"].materials.cloth and not outputs[a].armor["0"].mesh_enabled,
    "Ending rules restores edited material and mesh baseline")
S.equal(config,stored,"Visibility edits do not save presets")
config.enable_transform=false
assert(app.select("armor",config,"Lock","Hide"))
assert(app.edit("armor",0,"cloth",true))
assert(app.overrides.armor["0"].materials.cloth, "Hidden rendering must retain requested show intent")
tick(a,pa,true); tick(b,pb,false)
assert(not outputs[a].armor["0"].materials.cloth and not outputs[b].armor["0"].materials.cloth)
version_before=versions[a].armor
assert(app.edit("armor",0,nil,true))
tick(a,pa,true)
assert(outputs[a].armor["0"].mesh_enabled and versions[a].armor > version_before)
version_before=versions[a].armor
tick(a,pa,true)
assert(versions[a].armor == version_before, "Stable edited output retains material fast path")
assert(app.select("armor",config,"Lock","Show"))
tick(a,pa,true)
assert(outputs[a].armor["0"].materials.cloth, "Selection clears old edited lock output")
assert(not app.edit("missing",0,nil,true) and app.overrides.missing == nil)
configs.fresh=config
app.overrides.fresh=nil
assert(app.edit("fresh",0,"ribbon",true))
assert(app.groups.fresh[""] == "Base" and app.overrides.fresh["0"].materials.ribbon)
print("PASS: Rise visibility edits update rollback, isolated outputs, global locks and stable versions")
