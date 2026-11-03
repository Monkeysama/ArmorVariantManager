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
local function harness(legacy)
    local scene = {is_alive=function(obj) return obj ~= nil and not obj.dead end}
    function scene.call(obj, method, ...)
        if scene.is_alive(obj) then return obj:call(method, ...) end
    end
    local env = setmetatable({require=function(name)
        assert(name == "ArmorVariantManager_Core.Games.Rise.SceneObject"); return scene
    end}, {__index=_G})
    local binding = assert(loadfile(root .. "MeshBinding.lua", "t", env))()
    local equipment = {parts=function(c) return c.parts end,
        mesh=function(p) return p.mesh end,
        invalidate_body_id=function(c) c.invalidated=(c.invalidated or 0)+1 end,
        clear_meshes=function() end}
    local h = {actors={}, captures={}, opts={}, baseline={}, versions={}}
    local function capture(id, part, m)
        h.captures[#h.captures+1]={id=id,part=part,values=S.copy(m.values),enabled=m.enabled}
    end
    if legacy then
        local mesh_cache = {by_obj={}}
        env.PlayerDir={parts=equipment.parts,body_id_of=function() return "body" end,
            invalidate_body_id=equipment.invalidate_body_id,mesh=mesh_cache}
        env.Binding=binding
        env.safe_object_alive=scene.is_alive
        env.SceneObject=scene
        env.Profiler={count=function() end,begin=function() end,finish=function() end}
        env.get_type=function() return {} end
        env.get_mesh_component_recursive=equipment.mesh
        env.TransformManager={capture_mesh=capture}
        env.active_overrides=h.baseline
        env.overrides_version=h.versions
        env.bump_overrides_version=function(id) h.versions[id]=(h.versions[id] or 0)+1 end
        env.get_primary_player=function() return h.actors[1] end
        env.is_material_in_current_context=function(i,n) return not h.opts.operable or h.opts.operable(i,n) end
        env.is_globally_hidden=function(i,n) return h.opts.hidden and h.opts.hidden(i,n) end
        h.old=dofile("tests/fixtures/legacy/rise_materials.lua")(env)
    else
        env.require=function(name)
            if name:match("SceneObject$") then return scene end
            if name:match("MeshBinding$") then return binding end
            error(name)
        end
        h.api=assert(loadfile(root .. "Materials.lua", "t", env))().new(equipment,capture)
    end
    function h.add()
        local actor={parts={sig="initial", [0]={mesh=mesh()}, [1]={mesh=mesh()}}}
        h.actors[#h.actors+1]=actor
        return actor
    end
    function h.armor(actor, preset, opts)
        h.opts=opts; h.baseline[opts.body_id]={}; h.versions[opts.body_id]=opts.version
        env.g_is_special_cg=opts.special_cg
        if h.old then
            local st=h.old.state.get(actor)
            st.desired_armor=not opts.hidden and preset or nil
            h.old.armor(actor,preset,not opts.operable,opts.body_id)
        else h.api.armor(actor,preset,opts) end
    end
    function h.weapon(actor, parts, preset, opts)
        h.opts=opts; h.baseline[opts.body_id]={}; h.versions[opts.body_id]=opts.version
        env.g_is_special_cg=opts.special_cg
        if h.old then h.old.weapon(parts,preset,not opts.operable,opts.body_id,actor)
        else h.api.weapon(actor,parts,preset,opts) end
    end
    function h.invalidate(id)
        if h.old then h.old.state.invalidate_body(id) else h.api.invalidate(id) end
    end
    function h.clear()
        if h.old then h.old.state.clear() else h.api.clear() end
    end
    return h
end
local new, old = harness(false), harness(true)
local a,b=new.add(),old.add()
local a2,b2=new.add(),old.add()
local function compare()
    for i, actor in ipairs(new.actors) do
        local prior=old.actors[i]
        for index, part in pairs(actor.parts) do
            if type(index)=="number" and part.mesh then
                local x,y=part.mesh,prior.parts[index].mesh
                S.equal(x.values,y.values); S.equal(x.writes,y.writes)
                assert(x.enabled==y.enabled)
            end
        end
        assert(actor.invalidated==prior.invalidated)
    end
    S.equal(new.captures,old.captures)
end
local preset={['0']={mesh_enabled=false,materials={cloth=false,metal=false}},
    ['1']={materials={cloth=true,metal=false}}}
local options={body_id="shared_body",version=1}
new.armor(a,preset,options); old.armor(b,preset,options); compare()
assert(a.parts[0].mesh.values[0]==false and a.parts[0].mesh.values[1]==false)
assert(new.captures[1].values[0]==true, "sample baseline before changing either duplicate")
local before=a.parts[0].mesh.reads
new.armor(a,preset,options); old.armor(b,preset,options); compare()
assert(a.parts[0].mesh.reads==before, "unchanged complete binding should skip native reads")

-- 同模型另一个角色独立应用，结果换表同版本也不能跳过。
local other={['0']={mesh_enabled=true,materials={cloth=true,metal=false}}}
new.armor(a2,other,options); old.armor(b2,other,options); compare()
assert(a2.parts[0].mesh.values[0] and not a.parts[0].mesh.values[0])
new.armor(a,other,options); old.armor(b,other,options); compare()
local edit={body_id="shared_body",version=2,
    operable=function(_,name) return name=="cloth" end,
    hidden=function(_,name) return name=="cloth" end}
new.armor(a,other,edit); old.armor(b,other,edit); compare()
assert(a.parts[0].mesh.values[0]==false)

-- 过场和零版本保留逐次应用；换装需等待下一拍的新标识。
local cg={body_id="shared_body",version=2,special_cg=true}
new.armor(a,other,cg); old.armor(b,other,cg); compare()
local no_version={body_id="shared_body",version=0}
new.armor(a,other,no_version); old.armor(b,other,no_version); compare()
a.parts={sig="replaced",[0]={mesh=mesh()}}
b.parts={sig="replaced",[0]={mesh=mesh()}}
new.armor(a,preset,options); old.armor(b,preset,options); compare()
assert(#a.parts[0].mesh.writes==0 and a.invalidated==1)
new.armor(a,preset,options); old.armor(b,preset,options); compare()
assert(#a.parts[0].mesh.writes>0)

-- 同一部件上的网格失效需要重新绑定；首次缺网格不能记作已完整应用。
a.parts[0].mesh.dead=true; b.parts[0].mesh.dead=true
a.parts[0].mesh=mesh(); b.parts[0].mesh=mesh()
new.armor(a,preset,options); old.armor(b,preset,options); compare()
local missing={['1']={materials={metal=false}}}
a2.parts[1].mesh=nil; b2.parts[1].mesh=nil
new.armor(a2,missing,options); old.armor(b2,missing,options); compare()
a2.parts[1].mesh=mesh(); b2.parts[1].mesh=mesh()
new.armor(a2,missing,options); old.armor(b2,missing,options); compare()
assert(not a2.parts[1].mesh.values[2])

-- 武器使用零起始配置键；旧接口的主角回退留在运行层。
local wa,wb={{mesh=mesh()},{mesh=mesh()}},{{mesh=mesh()},{mesh=mesh()}}
local wp={['0']={materials={cloth=false}},['1']={materials={metal=false}}}
local wo={body_id="weapon",version=1}
new.weapon(a,wa,wp,wo); old.weapon(b,wb,wp,wo)
new.weapon(a,wa,wp,wo); old.weapon(b,wb,wp,wo)
for i=1,2 do S.equal(wa[i].mesh.writes,wb[i].mesh.writes) end
S.equal(new.captures,old.captures)

-- 支持缺盾牌的配置：旧应用的 ipairs 会漏掉第二部件，新实现必须应用。
local sparse={[2]={mesh=mesh()}}
local legacy_sparse={[2]={mesh=mesh()}}
old.weapon(b2,legacy_sparse,wp,wo)
assert(legacy_sparse[2].mesh.values[2]==true, "legacy ipairs skips the supported second weapon part")
new.weapon(a2,sparse,wp,wo)
assert(sparse[2].mesh.values[2]==false)

new.invalidate("shared_body"); old.invalidate("shared_body")
options.version=old.versions.shared_body
new.armor(a,preset,options); old.armor(b,preset,options)
new.clear(); old.clear()
new.armor(a,preset,options); old.armor(b,preset,options)
S.equal(a.parts[0].mesh.writes,b.parts[0].mesh.writes)
print("PASS: Rise material application matches legacy caches, captures and writes; sparse weapons applied")
