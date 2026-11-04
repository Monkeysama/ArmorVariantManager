package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix = "ArmorVariantManager_Core."
local Panel = require(prefix .. "UI.ImGui.Materials")
local SceneObject = require(prefix .. "Games.Rise.SceneObject")
local Visibility = require(prefix .. "Presets.Visibility")

local function fixture(game, options)
    local trace, edits = {}, {}
    local part = options.weapon and "7" or 0
    local key = tostring(part)
    local mesh = {enabled=false, names={"cloth", "locked", "owned"}, values={true, false, true}}
    local td = {get_method=function() return nil end, get_runtime_type=function() return "Mesh" end}
    function mesh:get_type_definition() return td end
    function mesh:call(method, index, value)
        if method == "get_Enabled" then return self.enabled end
        if method == "set_Enabled" then self.enabled=index; return end
        if method == "get_MaterialNum" then return options.empty and 0 or #self.names end
        if method == "getMaterialName" then return self.names[index+1] end
        if method == "getMaterialsEnable" then return self.values[index+1] end
        if method == "setMaterialsEnable" then self.values[index+1]=value; return end
        error(method)
    end
    local object = {get_type_definition=function() return td end,
        call=function(_, method, kind)
            assert(method == "getComponent(System.Type)")
            if not options.missing then return mesh end
        end}
    local context = {filters={[part]=options.filter or ""}, pending={},
        selecting=options.selecting, new_global=options.global, weapon=options.weapon,
        overrides={armor={[key]={materials={cloth=false}}}}, group=options.group or "",
        config={groups={Hide={default_preset="Hidden", presets={Hidden={[key]={materials={locked=false}}}},
            Show={default_preset="Visible", presets={Visible={[key]={materials={locked=true}}}}}}}}}
    local env = {T=function(key) return key end,
        get_material_group_owner=function(_, name) return name == "owned" and "Owner" or nil end,
        get_material_global_groups=function(_, name) return name == "locked" and {"Hide","Show"} or {} end,
        is_material_in_current_context=function(_, name) return name ~= "owned" end,
        is_globally_hidden=function(_, name) return name == "locked" end,
        get_body_id=function() return "armor" end, get_effective_group_presets=function() return {} end}
    env.sdk={is_managed_object=function(obj) return obj ~= false end,
        find_type_definition=function() if not options.loading then return td end end}
    env.imgui=setmetatable({}, {__index=function(_, method)
        return function(label, value)
            if method == "tree_node" then return not options.closed end
            if method == "checkbox" then
                if options.action == label then return true, not value end
                return false, value
            end
            if method == "button" then return options.action == label end
            if method == "input_text" then return options.action == "filter", options.action == "filter" and "LOCK" or value end
        end
    end})
    local draw=Panel.new({access=require(prefix .. "Games." .. game .. ".MaterialView").new(),
        context=function() return context end, translate=env.T,
        edit=function(id, index, name, value)
            Visibility.set(context.overrides[id],index,name,value)
            edits[#edits+1]={id,tostring(index),name,value}
        end,
        owner=env.get_material_group_owner, global_groups=env.get_material_global_groups,
        in_context=env.is_material_in_current_context, hidden=env.is_globally_hidden,
        body_id=env.get_body_id, selected=env.get_effective_group_presets})
    return {trace=trace, context=context, edits=edits, mesh=mesh, env=env,
        draw=function()
            _G.sdk, _G.imgui = env.sdk, env.imgui
            local target=object
            if options.invalid then target=false end
            if options.fade then
                SceneObject.material_transition = {enabled=true, active={[mesh]=true},
                    get_material_enabled=function(_, target, index)
                        trace[#trace+1]={"fade_read",index};return false
                    end,
                    set_material_enabled=function(_, target, index, value)
                        trace[#trace+1]={"fade_write",index,value}
                    end}
            else SceneObject.material_transition=nil end
            draw(target, "Body", "armor", part)
        end}
end

-- 原生菜单是默认入口：只断言可见编辑、分组约束与渐隐桥接，不锁定控件顺序。
for _, game in ipairs({"Wilds", "Rise"}) do
    for _, weapon in ipairs({false,true}) do
        local key=weapon and "7" or "0"
        local locked=fixture(game,{weapon=weapon,action="[1] locked"}); locked.draw()
        assert(locked.context.overrides.armor[key].materials.locked==true)
        assert(locked.mesh.values[2]==false, "global hide wins over the visible checkbox intent")
        local owned=fixture(game,{weapon=weapon,action="[2] owned"}); owned.draw()
        assert(owned.context.overrides.armor[key].materials.owned==nil)
        local normal=fixture(game,{weapon=weapon,selecting=true,action="[2] owned"}); normal.draw()
        assert(normal.context.pending[key]==nil, "normal groups cannot select an owned material")
        local global=fixture(game,{weapon=weapon,selecting=true,global=true,action="[2] owned"}); global.draw()
        assert(global.context.pending[key].owned==true and global.mesh.values[3]==true)
        local bulk=fixture(game,{weapon=weapon,action="select_all##sa_"..key}); bulk.draw()
        S.equal(bulk.context.overrides.armor[key].materials,{cloth=true,locked=true})
        assert(bulk.mesh.values[2]==(game=="Rise"), "game-specific bulk visibility policy")
    end
    local mesh=fixture(game,{weapon=true,action="enable_mesh"}); mesh.draw()
    assert(mesh.mesh.enabled==(game=="Wilds"), "Rise weapon mesh is not directly editable")
    local filtered=fixture(game,{action="filter"}); filtered.draw()
    assert(filtered.context.filters[0]=="LOCK")
    for _, condition in ipairs({"empty","missing","loading","closed","invalid"}) do
        local panel=fixture(game,{[condition]=true,action="[0] cloth"}); panel.draw()
        assert(#panel.edits==0)
    end
end
local fade=fixture("Rise",{fade=true,action="[0] cloth"}); fade.draw()
assert(fade.context.overrides.armor["0"].materials.cloth==true)
local bridged=false
for _, row in ipairs(fade.trace) do
    if row[1]=="fade_write" and row[2]==0 and row[3]==true then bridged=true end
end
assert(bridged and fade.mesh.values[1]==true, "dissolve edits use target intent, not native visibility")
SceneObject.material_transition=nil
print("PASS: native material intent, ownership/global masks, bulk policy, unavailable parts and dissolve edits")
