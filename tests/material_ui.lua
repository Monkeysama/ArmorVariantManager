package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix = "ArmorVariantManager_Core."
local Panel = require(prefix .. "UI.ImGui.Materials")
local SceneObject = require(prefix .. "Games.Rise.SceneObject")
local Visibility = require(prefix .. "Presets.Visibility")
local legacy = {Wilds = dofile("tests/fixtures/legacy/visibility.lua"),
    Rise = dofile("tests/fixtures/legacy/rise_material_ui.lua")}

local function fixture(game, modern, options)
    local trace, edits = {}, {}
    local part = options.weapon and "7" or 0
    local key = tostring(part)
    local mesh = {enabled=false, names={"cloth", "locked", "owned"}, values={true, false, true}}
    local td = {get_method=function() return nil end, get_runtime_type=function() return "Mesh" end}
    function mesh:get_type_definition() return td end
    function mesh:call(method, index, value)
        trace[#trace+1] = {method, index, value}
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
            trace[#trace+1]={method, kind}
            assert(method == "getComponent(System.Type)")
            if not options.missing then return mesh end
        end}
    local context = {filters={[part]=options.filter or ""}, pending={},
        selecting=options.selecting, new_global=options.global, weapon=options.weapon,
        overrides={armor={[key]={materials={cloth=false}}}}, group=options.group or "",
        config={groups={Hide={default_preset="Hidden", presets={Hidden={[key]={materials={locked=false}}}},
            Show={default_preset="Visible", presets={Visible={[key]={materials={locked=true}}}}}}}}}
    local env = setmetatable({active_overrides=context.overrides, active_group_presets={armor={}},
        mat_filter_text=context.filters, pending_material_selections=context.pending,
        is_selection_mode=context.selecting, new_group_is_global=context.new_global,
        is_weapon_mode=context.weapon, current_config=context.config, current_group_name=context.group,
        get_body_id=function() return "armor" end, get_primary_body_id=function() return "armor" end,
        get_effective_group_presets=function() return {} end,
        T=function(key) return key end,
        get_material_group_owner=function(_, name) return name == "owned" and "Owner" or nil end,
        get_material_global_groups=function(_, name) return name == "locked" and {"Hide","Show"} or {} end,
        is_material_in_current_context=function(_, name) return name ~= "owned" end,
        is_globally_hidden=function(_, name) return name == "locked" end,
        safe_object_alive=SceneObject.is_alive, SceneObject=SceneObject,
        TransformManager={edit_base_field=function(id, index, name, value)
            edits[#edits+1]={id,index,name,value}
        end}, bump_overrides_version=function() end,
    }, {__index=_G})
    env.sdk={is_managed_object=function(obj) return obj ~= false end,
        find_type_definition=function() if not options.loading then return td end end}
    env.get_type=env.sdk.find_type_definition
    env.imgui=setmetatable({}, {__index=function(_, method)
        return function(label, value)
            trace[#trace+1]={"ui",method,label,value}
            if method == "tree_node" then return not options.closed end
            if method == "checkbox" then
                if options.action == label then return true, not value end
                return false, value
            end
            if method == "button" then return options.action == label end
            if method == "input_text" then return options.action == "filter", options.action == "filter" and "LOCK" or value end
        end
    end})
    local draw
    if modern then
        draw=Panel.new({access=require(prefix .. "Games." .. game .. ".MaterialView").new(),
            context=function() return context end, translate=env.T,
            edit=function(id, index, name, value)
                Visibility.set(context.overrides[id],index,name,value)
                if game == "Rise" then env.TransformManager.edit_base_field(id,tostring(index),name,value) end
            end,
            owner=env.get_material_group_owner, global_groups=env.get_material_global_groups,
            in_context=env.is_material_in_current_context, hidden=env.is_globally_hidden,
            body_id=env.get_body_id, selected=env.get_effective_group_presets})
    else draw=legacy[game](env) end
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

local count=0
for _, game in ipairs({"Wilds", "Rise"}) do
    for _, weapon in ipairs({false,true}) do
        local key=weapon and "7" or "0"
        for _, mode in ipairs({{}, {selecting=true}, {selecting=true,global=true}, {group="Group"}}) do
            for _, action in ipairs({"", "enable_mesh", "select_all##sa_"..key, "invert_select##inv_"..key,
                "[0] cloth", "[1] locked", "[2] owned", "filter", "x##fltclr_"..key}) do
                local options=S.copy(mode); options.weapon=weapon; options.action=action
                if action == "x##fltclr_"..key then options.filter="cloth" end
                local old,new=fixture(game,false,options),fixture(game,true,options)
                old.draw();new.draw()
                S.equal(new.trace,old.trace,game.." trace "..action)
                S.equal(new.context,old.context,game.." state "..action)
                S.equal(new.edits,old.edits,game.." rule edit "..action)
                count=count+1
            end
        end
    end
    for _, condition in ipairs({"empty","missing","loading","closed","invalid"}) do
        local options={[condition]=true}
        local old,new=fixture(game,false,options),fixture(game,true,options)
        old.draw();new.draw();S.equal(new.trace,old.trace,game.." "..condition)
    end
end
-- 渐隐期间读目标显隐而非暂时保持可见的原生材质，编辑也经过同一桥接。
for _, action in ipairs({"[0] cloth", "invert_select##inv_0"}) do
    local old,new=fixture("Rise",false,{fade=true,action=action}),fixture("Rise",true,{fade=true,action=action})
    old.draw();new.draw();S.equal(new.trace,old.trace,"Rise dissolve bridge")
    S.equal(new.context,old.context,"Rise dissolve draft")
end
SceneObject.material_transition=nil
print("PASS: shared native material UI matches both games for "..count.." interactions and unavailable states")
