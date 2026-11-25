package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Application = require("ArmorVariantManager_Core.Games.Wilds.Application")
local schema = require("ArmorVariantManager_Core.Games.Wilds.Config")
local Appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance")
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

assert(app.runtime==runtime and app.appearance==appearance and app.load==session.load)

-- mdf2 文件：按材质找本地猎人的网格；写入时把所有角色的网格（含武器对象）交给文件服务，
-- 换上后忘掉写入器状态、回调业务层并刷新外观
local function fake_mesh(...)
    local names = {...}
    return {call=function(_, method, j)
        if method == "get_MaterialNum" then return #names end
        if method == "getMaterialName" then return names[j + 1] end
    end}
end
local cloth_mesh, skin_mesh, remote_mesh, blade = fake_mesh("cloth"), fake_mesh("skin"), fake_mesh("cloth"), fake_mesh("blade")
runtime.meshes = {
    part_meshes=function(actor, index) return actor == primary and index == 1 and {skin_mesh, cloth_mesh} or {} end,
    all=function(actor) return actor == primary and {skin_mesh, cloth_mesh} or actor == remote and {remote_mesh} or {} end,
    first=function(object) return object == primary and blade or nil end,
}
local started, cleaned = nil, 0
runtime.material_files = {
    cleanup=function() cleaned = cleaned + 1 end,
    status=function(mesh) return {path=mesh == cloth_mesh and "cloth.mdf2.45" or "x", status=mesh == cloth_mesh and "ok" or "packed"} end,
    export=function(mesh, material, name)
        if name == "bad" then error("invalid preset name") end
        return {path=material .. name, mesh=mesh}
    end,
    start=function(opts) started = opts; return {path="cloth.mdf2.45", values=1} end,
    reset=function() end,
}
roster = {primary, remote}
local files_app = Application.new(runtime, appearance, session, rules, weapon)
assert(cleaned == 1, "reload copies from the previous launch are cleaned at startup")
S.equal(files_app.material_file("1", "cloth"), {path="cloth.mdf2.45", status="ok"})
assert(files_app.material_file("1", "missing").status == "none")
assert(files_app.export_material("1", "cloth", "Red").mesh == cloth_mesh)
local ok, reason = files_app.export_material("1", "cloth", "bad")
assert(not ok and reason == "invalid preset name")
local written
S.equal(files_app.write_material_file("1", {cloth={Rough=1}}, "cloth", false, function(value) written = value end),
    {path="cloth.mdf2.45", values=1})
assert(started.mesh == cloth_mesh)
S.equal(started.overrides, {cloth={Rough=1}})
local all = started.meshes()
assert(#all == 4 and all[3] == blade and all[4] == remote_mesh, "every actor's armor and weapon meshes are candidates")
local forgotten = {}
files_app.palette.writer.forget = function(mesh) forgotten[#forgotten + 1] = mesh end
writes = {}
started.swapped({cloth_mesh, remote_mesh}, {cloth={Rough=true}})
assert(#forgotten == 2 and written.cloth.Rough and #writes == 2, "swapped meshes are forgotten and appearance refreshed")
started = nil
assert(files_app.write_material_file("1", {cloth={Rough=1}}, nil, false) and started.mesh == cloth_mesh,
    "without a material the first writable mesh of the part is used")
ok, reason = files_app.write_material_file("1", {cloth={Rough=1}}, "missing", false)
assert(not ok and reason == "material not found")
runtime.material_files = nil
print("PASS: Wilds mdf2 file lookup, export, write candidates, swap callback and launch cleanup")
print("PASS: Wilds application immediate actor/slot refresh, primary inclusion, invalid selection, save failure/preserve/reset")
