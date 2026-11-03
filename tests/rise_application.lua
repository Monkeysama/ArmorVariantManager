package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix, rise = "ArmorVariantManager_Core.", "ArmorVariantManager_Core.Games.Rise."
local loaded, samples, tracking, now, outputs, writes = {}, 0, false, 0, {}, 0
local a, b, menu = {id="armor"}, {id="armor"}, {id="armor"}
local pa, pb = {drawn=true}, {drawn=false}
local directory = {local_entry={obj=a, player=pa, is_local=true}, others={{obj=b, player=pb}}}
directory.entries = {directory.local_entry, directory.others[1]}
local events, invalidations, hooks = {}, {}, {}
local actors = {
    get=function() return directory end, local_player=function() return a end,
    events=function() return events end, reset=function() end, tick=function() end,
}
local equipment = {
    body_id=function(obj) return obj.id end, weapon_id=function() end,
    begin_frame=function() end, clear=function() end,
}
local materials = {
    armor=function(obj, result, options)
        outputs[obj] = {result=result, version=options.version, event=options.special_cg}
        writes=writes+1
    end,
    invalidate=function(id) invalidations[#invalidations+1]=id end,
    clear=function() end,
}
loaded[rise .. "Actors"] = {new=function() return actors end}
loaded[rise .. "Equipment"] = {new=function() return equipment end}
loaded[rise .. "Materials"] = {new=function() return materials end}
loaded[rise .. "SceneObject"] = {is_alive=function(obj) return obj and not obj.dead end}
loaded[rise .. "DissolveTransition"] = {new=function() return {
    tick=function() end, abandon=function() end, finish_all=function() end,
} end}
loaded[rise .. "ConditionRegistry"] = {
    weapon={get_state=function(_, player) samples=samples+1; return player.drawn end},
    monster_hp={set_tracking=function(value) tracking=value end},
}
loaded[rise .. "Signals"] = {
    begin_frame=function() end, clear=function() end, bind_actor=function() end, forget_actor=function() end,
    sample_condition=function(_, handler, actor, player) return handler.get_state(actor, player) end,
}
local env = setmetatable({os={clock=function() return now end},
    sdk={find_type_definition=function() return {get_method=function() return {} end} end,
        hook=function(_, before) hooks.scene=before end},
    re={on_script_reset=function(callback) hooks.reset=callback end},
}, {__index=_G})
env.require=function(name)
    if loaded[name] then return loaded[name] end
    loaded[name]=assert(loadfile("ArmorVariantManager/reframework/autorun/" .. name:gsub("%.", "/") .. ".lua", "t", env))()
    return loaded[name]
end
local function preset(value) return {["0"]={materials={cloth=value}}} end
local original={default_preset="Base",presets={Base=preset(true),Hide=preset(false)},groups={},
    enable_transform=true,transform_type="weapon", custom={retained=7},
    weapon_transform_rules={{state="drawn",targets={{group="",preset="Hide"}}}}}
local files={armor=S.copy(original),backup_armor=S.copy(original)}
local fail=false
local store={config_path=function(id) return id end, backup_path=function(id) return "backup_"..id end,
    load=function(path) return S.copy(files[path]) end,
    save=function(path,value) if fail then return false end; files[path]=S.copy(value); return true end}
local session=env.require(prefix .. "Config.Session").new(env.require(rise .. "Config"),nil,store)
local app=env.require(rise .. "Application").new({language="en"},session)
app.runtime.install_hooks()
assert(hooks.scene and hooks.reset and _G.__AVM_LANGUAGE=="en" and not tracking)
local function frame(count)
    for _=1,count or 1 do now=now+1/60; app.runtime.tick() end
end
local function cloth(obj) return outputs[obj].result["0"].materials.cloth end
frame(20)
local config=app.load("armor")
assert(not cloth(a) and cloth(b))
assert(app.appearance.overrides.armor["0"].materials.cloth)
assert(app.set_enabled("armor",config,false) and cloth(a))
frame(10); assert(cloth(a) and cloth(b))
assert(app.set_enabled("armor",config,true) and not cloth(a))
-- 修改目标时武器信号不变，也必须立即重编译，而不是复用旧隐藏结果。
config.weapon_transform_rules[1].targets[1].preset="Base"
assert(app.refresh("armor",config,a) and cloth(a))
config.weapon_transform_rules[1].targets[1].preset="Hide"
assert(app.refresh("armor",config,a) and not cloth(a))
app.set_enabled("armor",config,false)
assert(app.select("armor",config,"","Hide") and not cloth(a))
assert(app.edit("armor",0,"cloth",true) and cloth(a))
local draft=app.appearance.overrides.armor
fail=true
assert(not app.save("armor",config,false) and app.appearance.overrides.armor==draft)
assert(not app.restore("armor") and app.appearance.overrides.armor==draft)
fail=false
assert(app.save("armor",config,true) and app.appearance.overrides.armor==draft)
assert(files.armor.custom.retained==7)
config.default_preset="Hide"
assert(app.save("armor",config,false))
frame(); assert(not cloth(a))
files.backup_armor=S.copy(original)
assert(app.restore("armor") and not cloth(a)) -- restored configuration enables drawn rule
local restored=app.load("armor")
assert(restored~=config and restored.default_preset=="Base" and restored.custom.retained==7)
app.set_enabled("armor",restored,false); assert(cloth(a))
-- 本地、队友、预览都经过同一执行入口；未知对象不能靠刷新绕过角色发现。
local before=writes
assert(not app.runtime.refresh({id="armor"}) and writes==before)
pa.dead=true; assert(not app.runtime.refresh(a) and writes==before); pa.dead=nil
hooks.scene(); assert(not app.refresh("armor",restored,a) and writes==before)
frame(); assert(writes==before and app.appearance.state:peek(tostring(a),"armor","armor",restored)==nil)
frame(); assert(cloth(a))
-- 过场只接受当前演员；不得把正常猎人或他的信号带入预览。
events={menu}; frame(5)
before=samples
assert(app.refresh("armor",restored,menu) and cloth(menu) and outputs[menu].event)
assert(samples==before and not app.runtime.refresh(a))
events={}; frame(5)
-- 怪物血量钩子仅在任一已加载配置真正使用该条件时开启。
local hp=env.require(rise .. "Config").new()
hp.enable_transform=true; hp.transform_type="monster_hp"; hp.monster_hp_transform_rules={{threshold=50,targets={}}}
assert(app.save("other",hp,true) and tracking)
hp.enable_transform=false; assert(app.save("other",hp,true) and not tracking)
hp.enable_transform=true; hp.transform_type="weapon"; hp.is_parallel=true
hp.parallel_settings.monster_hp.enabled=true
assert(app.save("other",hp,true) and tracking)
session.cache.missing="LOAD_FAILED"
hp.monster_hp_transform_rules={}; assert(app.save("other",hp,true) and not tracking)
-- 原生条件面板直接消费应用操作，而不是重新实现运行逻辑。
restored.enable_transform=true
local panel=env.require(rise .. "ImGuiConditions").new({translate=function(k) return k end,
    rules=env.require(rise .. "Rules"),set_enabled=app.set_enabled,refresh=app.refresh,
    save=function(id) return app.save(id,restored) end,draw_targets=function() error("disabled") end})
env.imgui={checkbox=function() return true,false end,separator=function() end}
panel(restored,"armor",a)
assert(not restored.enable_transform and not files.armor.enable_transform and cloth(a))
hooks.reset()
assert(app.appearance.state:peek(tostring(a),"armor","armor",restored)==nil)
print("PASS: Rise application, real config/rules/runtime, edits, restore, scene/event refresh and condition callbacks")
