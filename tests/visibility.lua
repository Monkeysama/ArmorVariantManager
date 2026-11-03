game = {wilds=true, prefix="ArmorVariantManager_Core.Games.Wilds."}
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix = "ArmorVariantManager_Core."
local legacy = dofile("tests/fixtures/legacy/visibility.lua")
local source = S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")

local function fixture(action, modern, selection)
    local trace = {}
    local mesh = {names={"cloth", "locked", "cloth"}, values={true, false, false}, enabled=true}
    function mesh:call(method, index, value)
        trace[#trace+1]={method, index, value}
        if method == "get_Enabled" then return self.enabled end
        if method == "set_Enabled" then self.enabled=index; return end
        if method == "get_MaterialNum" then return #self.names end
        if method == "getMaterialName" then return self.names[index+1] end
        if method == "getMaterialsEnable" then return self.values[index+1] end
        if method == "setMaterialsEnable" then self.values[index+1]=value; return end
        error(method)
    end
    local app = require(prefix .. "Games.Wilds.Appearance").new({})
    app.overrides.armor = {["0"]={materials={cloth=false}, extension=42}, ground_clipping_fix={height_cm=8}}
    app.groups.armor = {[""]="Saved"}
    local env = setmetatable({appearance=app, active_overrides=app.overrides,
        T=function(key) return key end, mat_filter_text={}, pending_material_selections={},
        current_config={groups={}}, current_group_name="", is_selection_mode=selection,
        is_globally_hidden=function(_, name) return name == "locked" end,
        is_material_in_current_context=function() return true end,
        get_material_group_owner=function() end,
        get_material_global_groups=function() return {} end,
        sdk={is_managed_object=function(object) return object ~= false end},
        type_mesh={get_runtime_type=function() return "Mesh" end},
    }, {__index=_G})
    env.imgui=setmetatable({}, {__index=function(_, method)
        return function(label, value)
            trace[#trace+1]={"ui", method, label, value}
            if method == "tree_node" then return true end
            if method == "checkbox" then
                if action == label then return true, not value end
                return false, value
            end
            if method == "button" then return action == label end
            if method == "input_text" then return false, value end
        end
    end})
    env.sdk.find_type_definition=function() return env.type_mesh end
    _G.sdk, _G.imgui = env.sdk, env.imgui
    local draw, callbacks
    if modern then
        draw=assert(load(S.section(source, "local draw_material_panel =", "local draw_part_list =")
            .. "\nreturn draw_mesh_toggle", "native-visibility", "t", env))()
        callbacks=assert(load(S.section(source, "local visibility_editor =", "variant_manager_ui =")
            .. "\nreturn {" .. S.section(source, "    set_mesh_enabled =", "    is_material_in_context =") .. "}",
            "visibility-wiring", "t", env))()
    else draw, callbacks=legacy(env) end
    local object={call=function(_, method) assert(method == "getComponent(System.Type)"); return mesh end}
    return {app=app, env=env, mesh=mesh, trace=trace, draw=function() draw(object, "Body", "armor", 0) end,
        callbacks=callbacks}
end

for _, selection in ipairs({false, true}) do
    for _, action in ipairs({"", "enable_mesh", "select_all##sa_0", "invert_select##inv_0", "[0] cloth", "[1] locked"}) do
        local old, new=fixture(action, false, selection), fixture(action, true, selection)
        old.draw(); new.draw()
        S.equal(new.trace, old.trace, "native trace " .. action)
        S.equal(new.app.overrides, old.app.overrides, "native intent " .. action)
        S.equal(new.env.pending_material_selections, old.env.pending_material_selections, "selection mask")
        S.equal(new.app.groups.armor, {[""]="Saved"}, "editing leaves group selection intact")
    end
end

for _, enabled in ipairs({false, true}) do
    for _, name in ipairs({"cloth", "locked", "missing"}) do
        local old, new=fixture("",false), fixture("",true)
        for _, f in ipairs({old,new}) do
            -- 包含同名材质的全部索引、多 Mesh 和失效对象。
            f.callbacks.set_mesh_enabled("armor",0,{f.mesh,false},enabled)
            f.callbacks.set_material_enabled("armor",0,{f.mesh,false,f.mesh},name,enabled)
        end
        S.equal(new.trace,old.trace,"custom UI engine calls")
        S.equal(new.app.overrides,old.app.overrides,"custom UI intent")
        S.equal(new.mesh.values,old.mesh.values,"custom UI rendering")
        assert(new.app.overrides.armor["0"].materials[name] == enabled)
        if name == "locked" then assert(new.mesh.values[2] == false) end
    end
end
local f=fixture("",true)
local before=S.copy(f.app.overrides)
assert(not f.callbacks.set_mesh_enabled(nil,0,{f.mesh},true))
assert(#f.trace == 0)
S.equal(f.app.overrides,before,"missing ID leaves draft intact")
print("PASS: native and custom UI visibility matches legacy, global locks, multi-mesh and drafts")
