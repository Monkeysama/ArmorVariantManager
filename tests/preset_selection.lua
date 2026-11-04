package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Selection = require("ArmorVariantManager_Core.Presets.Selection")
local Fixture=dofile("tests/app_fixture.lua")
local function preset(materials) return {["0"]={materials=materials}} end
local config = {default_preset="Base", presets={Base=preset({cloth=true, ribbon=true}), Alt=preset({cloth=false})},
    groups={
        Normal={default_preset="Default", presets={Default=preset({boots=true}), Other=preset({boots=false})}},
        Lock={is_global=true, default_preset="Hide", presets={Hide=preset({cloth=false}), Show=preset({cloth=true})}},
        Extra={is_global=true, default_preset="Hide", presets={Hide=preset({ribbon=false}), Show=preset({ribbon=true})}},
    }, unknown={keep=true}}
config.groups.Normal.presets.Other["0"].mesh_enabled=false

for _,game in ipairs({"Wilds","Rise"}) do
    local policy=require("ArmorVariantManager_Core.Games."..game..".Presets")
    for _,initial in ipairs({{}, {[""]="Alt",Normal="Other"},
        {[""]="missing",Normal="missing",Extra="missing"}, {[""]="",Normal="",Extra=""}}) do
        local cfg,names=S.copy(config),S.copy(initial)
        local result=preset({cloth=true,ribbon=true,boots=true,untouched=false})
        local app
        if game=="Wilds" then
            local appearance=require("ArmorVariantManager_Core.Games.Wilds.Appearance").new({is_weapon_id=function() return false end})
            appearance.overrides,appearance.groups={id=result},{id=names}
            appearance.height={reset=function() end}
            result.ground_clipping_fix={enabled=true,height_cm=9}
            local backend=require("ArmorVariantManager_Core.Games.Wilds.Application").new({
                actors={all=function() return {} end,local_player=function() end},equipment={},materials={}
            },appearance,{}, {},function() return false end)
            app=Fixture.new(game,{backend=backend})
            app.workspace.config=cfg
            app.workspace.get_body_id=function() return "id" end
        end
        local expected_names=S.copy(initial)
        local function select(group,name,cloth,ribbon,boots)
            expected_names[group]=name
            if app then
                app.workspace.state.group=group
                app.apply_preset(name)
                result=app.appearance.overrides.id
                assert(app.workspace.applied.id==name)
                assert(result.ground_clipping_fix.height_cm==9)
            else result=assert(Selection.apply(cfg,names,result,group,name,policy)) end
            local materials=result["0"].materials
            assert(materials.cloth==cloth and materials.ribbon==ribbon and materials.boots==boots)
            assert(materials.untouched==nil,"global recomposition discards stale materials")
            S.equal(names,expected_names)
            S.equal(cfg,config,"selection does not edit defaults or stored presets")
        end
        select("Lock","Show",initial[""]~="Alt",initial.Extra=="missing" and true or false,initial.Normal~="Other")
        select("Normal","Other",initial[""]~="Alt",initial.Extra=="missing" and true or false,false)
        assert(result["0"].mesh_enabled==false)
        select("","Alt",false,initial.Extra=="missing" and true or false,false)
        local hidden_ribbon
        if initial.Extra~="missing" then hidden_ribbon=false end
        select("Lock","Hide",false,hidden_ribbon,false)
        select("Extra","Show",false,game=="Wilds" and true or nil,false)
        select("Lock","Show",false,game=="Wilds" and true or nil,false)
        select("","Base",true,true,false)
        local before=S.copy(result)
        assert(Selection.apply(cfg,names,result,"Lock","missing",policy)==nil)
        S.equal(result,before); S.equal(names,expected_names)
    end
end
local names,result={}, {keep=true}
assert(Selection.apply(config,names,result,"deleted","Base",{})==nil)
assert(next(names)==nil and result.keep)
print("PASS: manual selection, global rebuild, incremental merge, fallback and live Wilds application")
