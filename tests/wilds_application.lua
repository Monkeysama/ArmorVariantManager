package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Application = require("ArmorVariantManager_Core.Games.Wilds.Application")
local schema = require("ArmorVariantManager_Core.Games.Wilds.Config")
local Appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance")
local main = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local config = {default_preset="Base", presets={
    Base={["0"]={materials={cloth=true}}}, Hide={["0"]={materials={cloth=false}}},
}}
schema.normalize(config)
local saved, fail, refreshed, cleared = 0, false, 0, 0
local session = {
    load=function() return config end,
    save=function(id, data) assert(id == "armor" and data == config); saved=saved+1; return not fail end,
}
local rules = {
    has_configured_rules=function() return false end,
    refresh_config_rules=function(data) assert(data == config); refreshed=refreshed+1 end,
    clear_last_state_cache=function() cleared=cleared+1 end,
}
local function weapon(id) return id == "wp01" end
local appearance = Appearance.new({load=session.load, rules=rules, is_weapon_id=weapon})
local primary, remote, other = {body="armor", weapon="wp01"}, {body="armor"}, {body="other"}
local roster, writes = {remote,other}, {}
sdk = {is_managed_object=function(value) return not value.dead end}
local runtime = {
    actors={all=function() return {table.unpack(roster)} end, local_player=function() return primary end},
    equipment={body_id=function(actor) return actor.body end,
        weapon_id=function(actor) return actor.weapon, actor.weapon and {actor} end},
    materials={armor=function(actor, value) writes[#writes+1]={actor,"armor",S.copy(value)} end,
        weapon=function(actor, objects, value) assert(objects[1]==actor); writes[#writes+1]={actor,"weapon",S.copy(value)} end},
}
local app = Application.new(runtime, appearance, session, rules, weapon)
appearance.defaults("armor")
assert(app.select("armor",config,"","Hide"))
assert(#writes==2 and writes[1][1]==remote and writes[2][1]==primary)
assert(writes[1][3]["0"].materials.cloth==false and writes[2][3]["0"].materials.cloth==false)
assert(appearance.state:peek(tostring(primary),"armor","armor",config))
assert(appearance.state:peek(tostring(remote),"armor","armor",config))
writes={}; roster={primary,remote,other}
app.refresh("armor"); assert(#writes==2, "Listed primary must not be applied twice")
writes={}; assert(not app.select("armor",config,"","missing") and #writes==0)
assert(not app.select(nil,config,"","Hide"))
appearance.defaults("wp01"); app.refresh("wp01")
assert(#writes==1 and writes[1][1]==primary and writes[1][2]=="weapon")
writes={}; roster={remote}; primary.dead=true
app.refresh("armor"); assert(#writes==1 and writes[1][1]==remote)
primary.dead=nil

local draft, groups = appearance.overrides.armor, appearance.groups.armor
fail=true
assert(not app.save("armor",config,false))
assert(appearance.overrides.armor==draft and appearance.groups.armor==groups and cleared==0)
fail=false
assert(app.save("armor",config,true))
assert(appearance.overrides.armor==draft and appearance.groups.armor==groups and refreshed==1)
assert(app.save("armor",config,false))
assert(not appearance.overrides.armor and not appearance.groups.armor and cleared==1)
assert(app.save(nil,config)==nil and saved==3)
writes={}; app.process(primary)
assert(appearance.overrides.armor["0"].materials.cloth==true)
assert(#writes==2 and writes[1][2]=="armor" and writes[2][2]=="weapon")

-- 正式入口绑定真实服务，而不是测试专用的另一套协调路径。
local env = setmetatable({runtime=runtime,appearance=appearance,config_session=session,
    TransformManager=rules,is_weapon_id=weapon}, {__index=_G})
local constructor=S.section(main,'local application = require(', 'local active_overrides, active_group_presets')
local bound=assert(load(constructor.."\nreturn application", "main-application", "t", env))()
assert(bound.runtime==runtime and bound.appearance==appearance and bound.load==session.load)
print("PASS: Wilds application immediate actor/slot refresh, primary inclusion, invalid selection, save failure/preserve/reset and main wiring")
