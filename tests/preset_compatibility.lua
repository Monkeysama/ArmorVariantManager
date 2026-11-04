game = {wilds=true, prefix="ArmorVariantManager_Core.Games.Wilds."}
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Groups = require("ArmorVariantManager_Core.Presets.Groups")

local config = { presets = { Base = { ["1"] = { mesh_enabled = true, materials = { Cape = true, Skin = true, Boots = false } } } },
    groups = { Shoes = { mask = { ["1"] = { Boots = true } }, presets = {} } }, group_order = { "Shoes" }, unknown = { keep = true } }
local preset = { ["1"] = { mesh_enabled = false, materials = { Cape = false, Skin = true, Extra = true } },
    ["2"] = { materials = { Hair = true } } }
local base = { ["1"] = { mesh_enabled = true, materials = { Cape = true, Skin = false }, extension = "keep" } }
for _,game in ipairs({"Wilds","Rise"}) do
    local Presets=require("ArmorVariantManager_Core.Games."..game..".Presets")
    local added=S.copy(preset)
    if game=="Wilds" then added.ground_clipping_fix={enabled=true,height_cm=0} end
    local before=S.copy(added)
    local expected={
        ["1"]={mesh_enabled=false,materials={Cape=false,Skin=true,Extra=true},extension="keep"},
        ["2"]={materials={Hair=true}},
    }
    if game=="Wilds" then expected.ground_clipping_fix={enabled=true,height_cm=0} end
    S.equal(Presets.merge(base,added),expected)
    S.equal(Presets.merge(base,nil),base)
    local target=S.copy(base)
    local manual_expected=S.copy(expected); manual_expected.ground_clipping_fix=nil
    Presets.merge_into(target,added); S.equal(target,manual_expected)
    target["1"].materials.Skin=false
    assert(base["1"].materials.Skin==false and added["1"].materials.Skin==true)
    target=S.copy(base)
    Presets.merge_global_into(target,added)
    assert(target["1"].mesh_enabled and not target["1"].materials.Cape and not target["1"].materials.Skin)
    assert(target["1"].materials.Extra==(game=="Wilds" and true or nil))
    assert(target["2"] and target["2"].materials.Hair==(game=="Wilds" and true or nil))
    S.equal(added,before,"stored preset unchanged")
    if game=="Wilds" then
        local height={ground_clipping_fix={enabled=true,height_cm=20}}
        for _,enabled in ipairs({true,false}) do
            local merged=Presets.merge(height,{ground_clipping_fix={enabled=enabled,height_cm=0}})
            assert(merged.ground_clipping_fix.height_cm==(enabled and 0 or 20))
        end
    end

    -- 两款游戏的 false mask 存储语义不同；删除组只释放归属，不复原主预设。
    for _,mask in ipairs({{}, {["1"]={}}, {["1"]={Cape=false}}, {["1"]={Cape=true,Skin=false}}}) do
        for _,global in ipairs({false,true}) do
            local current=S.copy(config)
            local has_entry=mask["1"] and next(mask["1"])~=nil
            local accepted=has_entry and (game=="Rise" or mask["1"].Cape==true) or false
            assert(Groups.create(current,"Overlay",mask,global,game=="Wilds")==accepted)
            if accepted then
                local expected_mask=game=="Wilds" and {["1"]={Cape=true}} or mask
                S.equal(current.groups.Overlay.mask,expected_mask)
                S.equal(current.group_order,{"Shoes","Overlay"})
                assert(current.groups.Overlay.is_global==global)
                assert(Groups.owner(current,1,"Boots")=="Shoes")
                local owner=not global and expected_mask["1"].Cape==true and "Overlay" or nil
                assert(Groups.owner(current,1,"Cape")==owner)
                assert(Groups.contains(current,"",1,"Cape")==(owner==nil))
                assert((not not Groups.contains(current,"Overlay",1,"Cape"))==
                    (global and expected_mask["1"].Cape==true or owner=="Overlay"))
                for material in pairs(expected_mask["1"]) do
                    assert(current.presets.Base["1"].materials[material]==(global and config.presets.Base["1"].materials[material] or nil))
                end
                assert(Groups.delete(current,"Overlay") and current.groups.Overlay==nil)
                S.equal(current.group_order,{"Shoes"})
                assert(not Groups.delete(current,"Overlay"))
            else S.equal(current,config,"rejected group unchanged") end
            S.equal(current.unknown,config.unknown)
        end
    end
end

-- 应用层只在保存成功后清选择状态；失败原地恢复配置。
local app=dofile("tests/app_fixture.lua").new("Wilds")
local ws,calls=app.workspace,{}
local fail=false
ws.config=S.copy(config)
ws.state.pending={["1"]={Cape=true}}
ws.state.selecting=true
ws.state.group_index=2
ws.update_group_names_list=function() calls[#calls+1]="groups" end
ws.update_preset_names_list=function() calls[#calls+1]="presets" end
app.backend.save=function(id) assert(id=="armor"); calls[#calls+1]="save"; return not fail end
assert(not app.create_new_group("","armor") and not app.create_new_group("Overlay",false))
S.equal(calls,{})
local identity=ws.config
fail=true
assert(not app.create_new_group("Overlay","armor"))
assert(ws.config==identity and ws.state.selecting and ws.state.pending["1"].Cape)
S.equal(ws.config,config)
fail=false; calls={}
assert(app.create_new_group("Overlay","armor"))
assert(not ws.state.selecting and next(ws.state.pending)==nil)
S.equal(calls,{"save","groups"})
assert(not app.create_new_group("Overlay","armor"))
ws.state.group="Overlay"
calls={}; fail=true
assert(not app.delete_group("Overlay","armor") and ws.config.groups.Overlay and ws.state.group=="Overlay")
calls={}; fail=false
assert(app.delete_group("Overlay","armor"))
S.equal(calls,{"save","presets","groups"})
assert(ws.state.group=="" and ws.state.group_index==1 and ws.config.groups.Overlay==nil)
assert(ws.config.presets.Base["1"].materials.Cape==nil)
S.equal(Groups.global_names({groups={Z={is_global=true,mask={["1"]={Cape=true}}},
    A={is_global=true,mask={["1"]={Cape=true}}}}},1,"Cape"),{"A","Z"})
print("PASS: dual-game composition, global/height precedence, group masks and transactional rollback")
