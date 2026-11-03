-- Local updates are never scheduled here. Only optional actors share this lane.
-- One actor is indivisible: budget controls admission, not unsafe preemption.
local Scheduler = {}
Scheduler.__index = Scheduler
function Scheduler.new()
    return setmetatable({frame=0, dt=1/60, roster={}, records={}, cursor=1,
        calls=0, deferred=0, max_wait=0, last_cost=0}, Scheduler)
end
function Scheduler:begin_frame(now)
    if self.last_at then
        local dt=now-self.last_at
        if dt>0 then self.dt=self.dt*.85+math.min(.25,dt)*.15 end
    end
    self.last_at=now; self.frame=self.frame+1
    self.debt=math.max(0,(self.debt or 0)-.00035)
end
function Scheduler:run(entries, process, foreground_cost, maximum)
    local now=self.last_at or os.clock()
    local next_roster={}
    for _,entry in ipairs(entries or {}) do next_roster[entry.obj]=true end
    for obj in pairs(self.records) do if not next_roster[obj] then self.records[obj]=nil end end
    self.roster=next_roster
    local count=#(entries or {})
    if count==0 or maximum==0 then self.cursor=1;return end
    -- ~60 ms where frame rate permits; 2..6 frames, with round-robin fairness.
    -- At 30/60/144 fps and three teammates: 3/4/6 frames per actor.
    local gap=math.max(count,math.min(6,math.max(2,math.floor(.06/math.max(.001,self.dt)+.5))))
    self.gap=gap
    local admitted=0
    for offset=0,count-1 do
        local index=((self.cursor-1+offset)%count)+1
        local entry=entries[index]
        local record=self.records[entry.obj]
        if not record then record={frame=-math.huge,at=now-.2};self.records[entry.obj]=record end
        local wait=now-record.at
        if self.frame-record.frame>=gap then
            -- Leave headroom for local work on slow CPUs. A soft age deadline
            -- prevents optional actors from starving under sustained load.
            if ((foreground_cost or 0)>.0015 or (self.debt or 0)>0) and wait<.2 then
                self.deferred=self.deferred+1
            else
                local started=os.clock()
                process(entry)
                self.last_cost=os.clock()-started
                self.debt=math.min(.003,(self.debt or 0)+math.max(0,self.last_cost-.00035))
                record.frame,record.at=self.frame,now
                self.calls=self.calls+1; self.max_wait=math.max(self.max_wait,wait)
                self.cursor=index%count+1; admitted=admitted+1
                -- Always at most one optional actor per frame, including CG.
                break
            end
        end
    end
    return admitted
end
return Scheduler
