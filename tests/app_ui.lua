package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Fixture = dofile("tests/app_fixture.lua")
sdk = {is_managed_object=function() return true end}

for _, game in ipairs({"Wilds", "Rise"}) do
    local global_failed, config_failed, global_writes, config_writes = false, false, 0, 0
    local app = Fixture.new(game, {
        session={cache={}, pending=function() return false end},
        global_settings={value={language="en", auto_set_selected_preset_as_default=false}, save=function()
            global_writes=global_writes+1
            return not global_failed, "global disk full"
        end},
    })
    app.backend.save=function()
        config_writes=config_writes+1
        return not config_failed, "config disk full"
    end
    app.height={get=function() return {enabled=false, height_cm=0} end, set=function() return true end}
    local ws=app.workspace
    ws.config={presets={}, groups={Normal={presets={A={}, B={}}, default_preset="A",
        preset_order={"A","B"}, mask={["0"]={cloth=true}}}}}
    ws.state.body_id="armor"
    ws.update_group_names_list()
    ws.select_group("Normal")
    local view={new_preset_name="", new_group_name="", sort_temp_list={}, sort_selected_index=1, auto_find_log=""}
    local button, auto, labels
    imgui=setmetatable({
        begin_table=function() return true end,
        tree_node=function(label) labels[label]=true; return true end,
        text_colored=function(message) assert(not tostring(message):find("Error:"), message) end,
        checkbox=function(label,value)
            if auto ~= nil and label=="auto_set_selected_preset_as_default" then
                local result=auto; auto=nil; return true,result
            end
            return false,value
        end,
        button=function(label) if label==button then button=nil; return true end return false end,
        combo=function(_,value) return false,value end,
        input_text=function(_,value) return false,value end,
        slider_float=function(_,value) return false,value end,
    }, {__index=function() return function() end end})
    local draw=require("ArmorVariantManager_Core.UI.ImGui.Presets").new(app,view)
    local function frame(click)
        button,labels=click,{}
        draw("armor")
        assert(button==nil, tostring(click))
        assert(labels["materials in Normal"], "native group material preview remains available")
    end
    frame("sort##p_sort")
    frame("move_down##sd_1")
    S.equal(view.sort_temp_list,{"B","A"})
    config_failed=true
    frame("sort_confirm##sort_ok")
    assert(view.sort_mode=="preset")
    S.equal(ws.config.groups.Normal.preset_order,{"A","B"})
    config_failed=false
    frame("sort_confirm##sort_ok")
    assert(view.sort_mode==nil)
    S.equal(ws.config.groups.Normal.preset_order,{"B","A"})

    ws.state.preset_index=1
    local before=config_writes
    global_failed=true; auto=true; frame()
    assert(not app.global_config.auto_set_selected_preset_as_default and config_writes==before)
    assert(view.settings_error=="global disk full")
    global_failed=false; config_failed=true; auto=true; frame()
    assert(app.global_config.auto_set_selected_preset_as_default)
    assert(ws.config.groups.Normal.default_preset=="A" and view.settings_error:find("config disk full",1,true))
    config_failed=false
    local written=global_writes
    assert(app.set_setting("auto_set_selected_preset_as_default",true))
    assert(global_writes==written and ws.config.groups.Normal.default_preset=="B")
    if game=="Wilds" then
        assert(app.set_setting("auto_set_selected_preset_as_default",false,"B","armor"))
        global_failed=true
        assert(not app.set_setting("auto_set_selected_preset_as_default",true,"A","armor"))
        assert(not app.global_config.auto_set_selected_preset_as_default and ws.config.groups.Normal.default_preset=="B")
    end
end
print("PASS: actual native group preview/sorting, failed-save retention and shared settings transactions")
