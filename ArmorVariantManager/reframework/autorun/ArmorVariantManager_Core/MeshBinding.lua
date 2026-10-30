-- Cache structural information by mesh lifetime, not by frame count. No cached
-- native liveness result is used: every native call retains SceneObject checks.
local SceneObject=require('ArmorVariantManager_Core.SceneObject')
local Binding={}
local meshes=setmetatable({}, {__mode='k'})
function Binding.reset() meshes=setmetatable({}, {__mode='k'}) end
function Binding.get(mesh)
    if mesh==nil then return nil end
    if not SceneObject.is_alive(mesh) then meshes[mesh]=nil;return nil end
    local count=SceneObject.call(mesh,'get_MaterialNum')
    if type(count)~='number' then return nil end
    local entry=meshes[mesh]
    if entry and entry.count==count then return entry end
    entry={count=count,materials={},indices={}}
    for index=0,count-1 do
        local name=SceneObject.call(mesh,'getMaterialName',index)
        if name then
            entry.materials[#entry.materials+1]={name=name,index=index}
            local list=entry.indices[name] or {};entry.indices[name]=list;list[#list+1]=index
        end
    end
    meshes[mesh]=entry
    return entry
end
function Binding.apply(mesh, data, operable, visibility)
    local entry=Binding.get(mesh)
    if not entry then return false end
    if data.mesh_enabled~=nil then
        local current=SceneObject.call(mesh,'get_Enabled')
        if current~=data.mesh_enabled then SceneObject.call(mesh,'set_Enabled',data.mesh_enabled) end
    end
    for name,enabled in pairs(data.materials or {}) do
        if not operable or operable(name) then
            local want=enabled
            if visibility then want=visibility(name,enabled) end
            for _,index in ipairs(entry.indices[name] or {}) do
                if SceneObject.call(mesh,'getMaterialsEnable',index)~=want then
                    SceneObject.call(mesh,'setMaterialsEnable',index,want)
                end
            end
        end
    end
    return true
end
return Binding
