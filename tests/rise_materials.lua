package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local root = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Rise/"
local function mesh()
    local m = {names={[0]="cloth", "cloth", "metal"}, values={[0]=true,true,true},
        enabled=true, reads=0, writes={}}
    function m:call(method, index, value)
        self.reads = self.reads + 1
        if method == "get_MaterialNum" then return 3 end
        if method == "getMaterialName" then return self.names[index] end
        if method == "get_Enabled" then return self.enabled end
        if method == "getMaterialsEnable" then return self.values[index] end
        if method == "set_Enabled" then self.enabled=index; self.writes[#self.writes+1]={method,index}; return end
        if method == "setMaterialsEnable" then
            self.values[index]=value; self.writes[#self.writes+1]={method,index,value}; return
        end
        error(method)
    end
    return m
end
local scene={is_alive=function(obj) return obj~=nil and not obj.dead end}
function scene.call(obj,method,...)
    if scene.is_alive(obj) then return obj:call(method,...) end
end
local env=setmetatable({require=function(name)
    assert(name=="ArmorVariantManager_Core.Games.Rise.SceneObject"); return scene
end},{__index=_G})
local binding=assert(loadfile(root.."MeshBinding.lua","t",env))()
env.require=function(name)
    if name:match("SceneObject$") then return scene end
    if name:match("MeshBinding$") then return binding end
    error(name)
end
local equipment={parts=function(c) return c.parts end,mesh=function(p) return p.mesh end,
    invalidate_body_id=function(c) c.invalidated=(c.invalidated or 0)+1 end,clear_meshes=function() end}
local captures={}
local api=assert(loadfile(root.."Materials.lua","t",env))().new(equipment,function(id,part,m)
    captures[#captures+1]={id=id,part=part,values=S.copy(m.values),enabled=m.enabled}
end)
local function actor() return {parts={sig="initial",[0]={mesh=mesh()},[1]={mesh=mesh()}}} end
local a,a2=actor(),actor()
local preset={['0']={mesh_enabled=false,materials={cloth=false,metal=false}},
    ['1']={materials={cloth=true,metal=false}}}
local options={body_id="shared_body",version=1}
api.armor(a,preset,options)
assert(a.parts[0].mesh.values[0]==false and a.parts[0].mesh.values[1]==false)
assert(captures[1].values[0]==true, "sample baseline before changing either duplicate")
local before=a.parts[0].mesh.reads
api.armor(a,preset,options)
assert(a.parts[0].mesh.reads==before, "unchanged complete binding should skip native reads")

-- 同模型另一个角色独立应用，结果换表同版本也不能跳过。
local other={['0']={mesh_enabled=true,materials={cloth=true,metal=false}}}
api.armor(a2,other,options)
assert(a2.parts[0].mesh.values[0] and not a.parts[0].mesh.values[0])
api.armor(a,other,options)
local edit={body_id="shared_body",version=2,
    operable=function(_,name) return name=="cloth" end,
    hidden=function(_,name) return name=="cloth" end}
api.armor(a,other,edit)
assert(a.parts[0].mesh.values[0]==false)

-- 过场和零版本保留逐次应用；换装需等待下一拍的新标识。
local cg={body_id="shared_body",version=2,special_cg=true}
api.armor(a,other,cg)
local no_version={body_id="shared_body",version=0}
api.armor(a,other,no_version)
a.parts={sig="replaced",[0]={mesh=mesh()}}
api.armor(a,preset,options)
assert(#a.parts[0].mesh.writes==0 and a.invalidated==1)
api.armor(a,preset,options)
assert(#a.parts[0].mesh.writes>0)

-- 同一部件上的网格失效需要重新绑定；首次缺网格不能记作已完整应用。
a.parts[0].mesh.dead=true
a.parts[0].mesh=mesh()
api.armor(a,preset,options)
local missing={['1']={materials={metal=false}}}
a2.parts[1].mesh=nil
api.armor(a2,missing,options)
a2.parts[1].mesh=mesh()
api.armor(a2,missing,options)
assert(not a2.parts[1].mesh.values[2])

-- 武器使用零起始配置键；旧接口的主角回退留在运行层。
local wa={{mesh=mesh()},{mesh=mesh()}}
local wp={["0"]={materials={cloth=false}},["1"]={materials={metal=false}}}
local wo={body_id="weapon",version=1}
api.weapon(a,wa,wp,wo)
assert(not wa[1].mesh.values[0] and not wa[1].mesh.values[1] and not wa[2].mesh.values[2])
local reads=wa[1].mesh.reads
api.weapon(a,wa,wp,wo)
assert(wa[1].mesh.reads==reads,"complete weapon binding skips repeated native reads")
local sparse={[2]={mesh=mesh()}}
api.weapon(a2,sparse,wp,wo)
assert(sparse[2].mesh.values[2]==false,"second weapon part is applied without first slot")
api.invalidate("shared_body"); options.version=2
api.armor(a,preset,options)
api.clear()
api.armor(a,preset,options)
assert(not a.parts[0].mesh.values[0] and not a.parts[0].mesh.values[1] and not a.parts[0].mesh.values[2])
print("PASS: Rise material intent, duplicate bindings, cache invalidation, actor isolation and sparse weapons")
