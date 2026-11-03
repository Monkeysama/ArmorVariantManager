package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Module = require("ArmorVariantManager_Core.Games.Rise.DissolveTransition")
local now=0
local function vector(x,y,z,w) return {x=x,y=y,z=z,w=w} end
local function mesh(supported)
    local m={enabled=true,visible=true,name="cloth",count=1,writes={},
        vectors={[0]=vector(.2,.3,.4,.5),vector(.6,.7,.8,.9)}}
    function m:call(method,index,var,value)
        assert(not self.dead,"native call after destruction")
        if method=="getMaterialName" then return self.name end
        if method=="get_MaterialNum" then return self.count end
        if method=="getMaterialVariableNum" then return supported and 2 or 0 end
        if method=="getMaterialVariableName" then return var==0 and "Dissolve_Flag" or "Dissolve_Rate" end
        if method=="getMaterialFloat4" then return self.vectors[var] end
        if method=="setMaterialFloat4" then
            self.vectors[var]=value; self.writes[#self.writes+1]={method,var,value}; return
        end
        if method=="getMaterialsEnable" then return self.visible end
        if method=="setMaterialsEnable" then self.visible=var; return end
        if method=="get_Enabled" then return self.enabled end
        error(method)
    end
    return m
end
local fade=Module.new({clock=function() return now end,
    valid=function(m) return not m.dead end,vector=vector})
local m=mesh(true)
local originals=S.copy(m.vectors)
fade:set_material_enabled(m,0,false)
assert(m.visible and not fade:get_material_enabled(m,0))
now=.1775; fade:tick()
assert(math.abs(m.vectors[1].x-.5)<1e-10)
fade:set_material_enabled(m,0,true)
assert(fade:get_material_enabled(m,0))
now=.3551; fade:tick()
assert(m.visible and not next(fade.active)); S.equal(m.vectors,originals)

-- 隐藏网格不能被渐隐重新启用；完成时恢复原材质参数。
fade:set_material_enabled(m,0,false)
m.enabled=false; fade:tick()
assert(not m.enabled and not m.visible); S.equal(m.vectors,originals)
m.enabled=true
fade:set_material_enabled(m,0,true)
assert(m.visible and m.vectors[1].x==1, "incoming geometry starts dissolved")
fade:finish_all()
assert(m.visible and not next(fade.active)); S.equal(m.vectors,originals)

-- 不支持参数的材质直接切换；销毁、换材质和场景清理不能写旧对象。
local plain=mesh(false)
fade:set_material_enabled(plain,0,false)
assert(not plain.visible and not next(fade.active))
fade:set_material_enabled(m,0,false)
m.dead=true; fade:tick(); assert(not next(fade.active))
local changed=mesh(true)
fade:set_material_enabled(changed,0,false)
local writes=#changed.writes
changed.name="replacement"; fade:tick()
assert(#changed.writes==writes and not next(fade.active))
local abandoned=mesh(true)
fade:set_material_enabled(abandoned,0,false)
writes=#abandoned.writes; fade:abandon(); fade:tick()
assert(#abandoned.writes==writes)

-- SceneObject 返回目标显隐，不将动画期间的 native=true 当作最终状态。
local scene=assert(loadfile("ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Rise/SceneObject.lua", "t",
    setmetatable({sdk={is_managed_object=function(obj) return not obj.dead end}}, {__index=_G})))()
local live=mesh(true)
function live:get_type_definition() return {get_method=function() return nil end} end
scene.material_transition=fade
scene.call(live,"setMaterialsEnable",0,false)
assert(live.visible and scene.call(live,"getMaterialsEnable",0)==false)
fade.enabled=false; fade:finish_all()
assert(not live.visible)
scene.call(live,"setMaterialsEnable",0,true)
assert(live.visible)
print("PASS: Rise dissolve reversal, restoration, scene cleanup and visibility routing")
