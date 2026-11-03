-- 仅接管材质显隐，不启用整个 Mesh 或 GameObject。
local Module = {}
local Store = require("ArmorVariantManager_Core.Config.Store")
local SETTINGS_PATH = 'ArmorVariantManager/DissolveTransitions.json'

-- 每个会话独立持有动画；完成或重置时恢复原参数。
function Module.new(deps)
    deps = deps or {}
    local clock = deps.clock or os.clock
    local valid = deps.valid or sdk.is_managed_object
    local vector = deps.vector or function(x,y,z,w) return Vector4f.new(x,y,z,w) end
    local store, settings = deps.store or Store, {}
    local st = {active={}, enabled=true, duration=0.355, completed=0, errors=0}
    local function key(mesh,index) return tostring(mesh)..':'..index end
    local function values(v) return {v.x,v.y,v.z,v.w} end
    local function write(s,name,v)
        s.mesh:call('setMaterialFloat4',s.index,s.vars[name],vector(v[1],v[2],v[3],v[4]))
    end
    local function alive(s)
        return valid(s.mesh) and s.mesh:call('getMaterialName',s.index)==s.name
            and s.mesh:call('get_MaterialNum')==s.count
    end
    local function position(s,now)
        local t=math.max(0,math.min(1,(now-s.start)/s.seconds))
        return s.from+(s.to-s.from)*t,t>=1
    end
    local function restore(s)
        write(s,'Dissolve_Flag',s.flags)
        write(s,'Dissolve_Rate',s.rate)
    end
    local function write_rate(s,p)
        s.mesh:call('setMaterialFloat4',s.index,s.vars.Dissolve_Rate,vector(p,p,p,0))
    end
    local function finish(s)
        s.mesh:call('setMaterialsEnable',s.index,s.target)
        restore(s)
    end
    local function make_state(mesh,index)
        local vars={}
        -- Moon appends its dissolve parameters near the end of the layout.
        for v=(mesh:call('getMaterialVariableNum',index) or 0)-1,0,-1 do
            local name=mesh:call('getMaterialVariableName',index,v)
            if name=='Dissolve_Flag' or name=='Dissolve_Rate' then
                vars[name]=v
                if vars.Dissolve_Flag and vars.Dissolve_Rate then break end
            end
        end
        if vars.Dissolve_Flag==nil or vars.Dissolve_Rate==nil then return nil end
        return {mesh=mesh,index=index,name=mesh:call('getMaterialName',index),
                count=mesh:call('get_MaterialNum'),vars=vars,
                flags=values(mesh:call('getMaterialFloat4',index,vars.Dissolve_Flag)),
                rate=values(mesh:call('getMaterialFloat4',index,vars.Dissolve_Rate))}
    end

    -- 动画期间返回目标显隐，避免绑定层将暂时可见误认为应用失败。
    function st:get_material_enabled(mesh,index)
        local s=self.active[key(mesh,index)]
        if s then
            local ok,same=pcall(alive,s)
            if ok and same then return s.target end
            self.active[key(mesh,index)]=nil
        end
        return mesh:call('getMaterialsEnable',index)
    end

    -- 反向切换从当前位置继续，不重新开始完整时长。
    function st:set_material_enabled(mesh,index,enabled)
        enabled=enabled==true
        local k=key(mesh,index)
        local s=self.active[k]
        if s then
            local ok,same=pcall(alive,s)
            if not ok or not same then self.active[k]=nil;s=nil end
        end
        if s and s.target==enabled then return end
        if not self.enabled then
            if s then pcall(restore,s);self.active[k]=nil end
            mesh:call('setMaterialsEnable',index,enabled)
            return
        end
        local now
        local p
        if s then now=clock();p=position(s,now)
        else
            local current=mesh:call('getMaterialsEnable',index)~=false
            if current==enabled then return end
            -- Unsupported materials retain AVM's immediate visibility behavior.
            local ok,result=pcall(make_state,mesh,index)
            if not ok or not result then
                mesh:call('setMaterialsEnable',index,enabled)
                return
            end
            s=result;p=current and 0 or 1;now=clock()
        end
        s.target=enabled;s.from=p;s.to=enabled and 0 or 1;s.start=now
        s.seconds=math.max(0.001,self.duration*math.abs(s.to-p))
        local ok=pcall(function()
            -- Set the hidden start before enabling incoming geometry.
            write_rate(s,p)
            write(s,'Dissolve_Flag',{1,0,0,0})
            s.mesh:call('setMaterialsEnable',s.index,true)
        end)
        if ok then self.active[k]=s
        else
            self.errors=self.errors+1;self.active[k]=nil
            pcall(restore,s)
            mesh:call('setMaterialsEnable',index,enabled)
        end
    end

    -- 每帧推进并检查对象身份，原生隐藏时结束而非重新显示。
    function st:tick()
        if next(self.active)==nil then return end
        if not self.enabled then self:finish_all();return end
        local now=clock()
        for k,s in pairs(self.active) do
            local ok=pcall(function()
                if not alive(s) then self.active[k]=nil;return end
                -- Respect engine/AVM whole-mesh hiding; never resurrect it.
                if s.mesh:call('get_Enabled')==false then
                    finish(s);self.active[k]=nil;return
                end
                local p,done=position(s,now)
                if done or not self.enabled then
                    finish(s);self.active[k]=nil;self.completed=self.completed+1
                else write_rate(s,p) end
            end)
            if not ok then
                self.errors=self.errors+1;self.active[k]=nil
                pcall(function() if alive(s) then finish(s) end end)
            end
        end
    end

    -- On a scene boundary discard references without touching stale objects.
    function st:abandon() self.active={} end
    function st:finish_all()
        local reason
        for k,s in pairs(self.active) do
            local ok,err=pcall(function() if alive(s) then finish(s) end end)
            if ok then self.active[k]=nil
            else
                self.errors=self.errors+1
                reason=reason or tostring(err)
            end
        end
        return reason==nil,reason
    end
    function st:save_settings()
        local previous_enabled, previous_duration = settings.enabled, settings.duration
        settings.enabled, settings.duration = self.enabled, self.duration
        local ok, saved, reason = pcall(store.save, SETTINGS_PATH, settings)
        if not ok or saved ~= true then
            settings.enabled, settings.duration = previous_enabled, previous_duration
            return false, ok and reason or saved
        end
        self.settings_error = nil
        return true
    end
    -- Draw inline in AVM settings; the transition has no standalone panel.
    function st:draw_ui(translate)
        local previous_enabled, previous_duration = self.enabled, self.duration
        local changed,value=imgui.checkbox(translate('enable_dissolve')..'##avm_dissolve',self.enabled)
        if changed then self.enabled=value end
        local changed_duration=false
        if self.enabled then
            local duration
            changed_duration,duration=imgui.slider_float(translate('dissolve_duration')..'##avm_dissolve',self.duration,0.1,2.0)
            if changed_duration then self.duration=duration end
        end
        if changed or changed_duration then
            local saved, reason = self:save_settings()
            if saved then
                self.settings_error = nil
                if not self.enabled then
                    local applied, apply_reason = self:finish_all()
                    if not applied then self.settings_error = apply_reason end
                end
            else
                self.enabled, self.duration = previous_enabled, previous_duration
                self.settings_error = reason or 'Dissolve settings save failed'
            end
        end
        if self.settings_error then imgui.text_colored(tostring(self.settings_error), 0xFF8080FF) end
    end
    if not deps.clock or deps.store then
        local ok,cfg=pcall(store.load, SETTINGS_PATH)
        if ok and type(cfg)=='table' then
            settings=cfg
            if type(cfg.enabled)=='boolean' then st.enabled=cfg.enabled end
            if type(cfg.duration)=='number' and cfg.duration==cfg.duration then
                st.duration=math.max(0.1,math.min(2,cfg.duration))
            end
        end
    end
    return st
end

return Module
