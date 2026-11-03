package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Options = require("ArmorVariantManager_Core.Games.Rise.Options")
local hooks, writes, fps, change, saved = {}, {}, 0, nil, 0
local app, renderer = {}, {}
local config = {enable_image_quality=false,image_quality_rate=1,enable_multiplayer=true}
local container = {call=function(_,name) assert(name=="getFrameRateOption"); return fps end}
sdk = {
    get_native_singleton=function(name) return name=="via.Application" and app or renderer end,
    get_managed_singleton=function(name)
        assert(name=="snow.StmOptionManager")
        return {get_field=function(_,field) assert(field=="_StmOptionDataContainer"); return container end}
    end,
    find_type_definition=function(name)
        return {get_method=function(_,method)
            return {id=name.."."..method,call=function(_,object,value)
                assert(math.type(value)=="float", "native floating-point argument")
                assert(object==(method=="set_MaxFps" and app or renderer))
                writes[#writes+1]={method,value}
            end}
        end}
    end,
    hook=function(method,pre,post) hooks[method.id]={pre=pre,post=post} end,
}
local labels, transitions, closed = {}, 0, false
imgui = {
    tree_node=function() return not closed end,tree_pop=function() end,
    checkbox=function(label,value)
        if change and change.label==label then return true,change.value end
        return false,value
    end,
    slider_float=function(label,value,low,high)
        assert(low==.1 and high==4)
        if change and change.label==label then return true,change.value end
        return false,value
    end,
    text=function(value) labels[#labels+1]=value end,
    text_colored=function(value) labels[#labels+1]=value end,
    separator=function() end,same_line=function() end,
}
local directory={entries={}}
local options = Options.new(config,{
    actors={get=function() return directory end},
    transition={draw_ui=function() transitions=transitions+1 end},
},function(key)
    return ({player_line="%s %s %s",players_summary="%d %s"})[key] or key
end,function() saved=saved+1 end)
S.equal(writes,{{"set_MaxFps",30}},"initial disabled quality")
local option_hook=hooks["snow.StmOptionManager.writeGraphicOptionOnIniFile"]
local event_hook=hooks["snow.eventcut.UniqueEventManager.playEventCommon"]
local quality_hook=hooks["snow.RenderAppManager.setSamplerQuality"]
assert(option_hook and event_hook and quality_hook)
for index,value in ipairs({30,60,90,120,144,165,240,600}) do
    fps=index-1; writes={}; option_hook.post()
    S.equal(writes,{{"set_MaxFps",value}},"FPS option")
end
fps=99; writes={}; event_hook.post()
S.equal(writes,{{"set_MaxFps",60}},"FPS fallback")
writes={}; quality_hook.post(); assert(#writes==0)
change={label="enable_image_quality",value=true}; options.performance()
assert(config.enable_image_quality and saved==1 and transitions==1)
S.equal(writes,{{"set_ImageQualityRate",1}},"quality enabled")
change={label="image_quality_rate",value=1.75}; options.performance()
assert(config.image_quality_rate==1.75 and saved==2)
S.equal(writes[#writes],{"set_ImageQualityRate",1.75},"quality slider")
writes={}; event_hook.post()
S.equal(writes,{{"set_MaxFps",60},{"set_ImageQualityRate",1.75}},"event refresh")
change={label="enable_image_quality",value=false}; writes={}; options.performance()
assert(not config.enable_image_quality and saved==3 and #writes==0)
change={label="enable_multiplayer##mp_enable",value=false}; options.multiplayer()
assert(not config.enable_multiplayer and saved==4)
local seen={}; for _,label in ipairs(labels) do seen[label]=true end
assert(seen.player_none and seen.multiplayer_local_only)
change=nil; directory={entries={{name="A",index=0,is_local=true}},local_entry={name="A"}}
options.multiplayer(); assert(labels[#labels]=="1 A")
closed=true; local count=#labels; options.multiplayer(); assert(#labels==count)
print("PASS: Rise native FPS/quality hooks, float arguments, multiplayer and performance controls")
