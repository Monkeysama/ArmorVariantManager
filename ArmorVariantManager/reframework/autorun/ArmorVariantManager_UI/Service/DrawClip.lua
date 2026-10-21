-- CPU clipping for the official draw API and standard d2d (neither requires an ImGui window).
local DrawClip = {}
function DrawClip.new(px, py, get_scale)
    local current, stack
    local clip = {}
    function clip.reset() current,stack=nil,{} end
    clip.reset()
    function clip.push(x,y,w,h)
        stack[#stack+1] = current or false
        local next_clip={px(x),py(y),px(x+w),py(y+h)}
        if current then
            next_clip={math.max(current[1],next_clip[1]),math.max(current[2],next_clip[2]),
                math.min(current[3],next_clip[3]),math.min(current[4],next_clip[4])}
        end
        current=next_clip
    end
    function clip.pop() current=table.remove(stack) or nil end
    function clip.rect(x,y,w,h)
        x,y,w,h=px(x),py(y),w*get_scale(),h*get_scale()
        if current then
            local right,bottom=math.min(x+w,current[3]),math.min(y+h,current[4])
            x,y=math.max(x,current[1]),math.max(y,current[2])
            w,h=right-x,bottom-y
        end
        if w<=0 or h<=0 then return nil end
        return x,y,w,h
    end
    function clip.line(x1,y1,x2,y2)
        x1,y1,x2,y2=px(x1),py(y1),px(x2),py(y2)
        if not current then return x1,y1,x2,y2 end
        local dx,dy=x2-x1,y2-y1
        local lower,upper=0,1
        local p={-dx,dx,-dy,dy}
        local q={x1-current[1],current[3]-x1,y1-current[2],current[4]-y1}
        for i=1,4 do
            if p[i]==0 then if q[i]<0 then return nil end
            else
                local t=q[i]/p[i]
                if p[i]<0 then lower=math.max(lower,t) else upper=math.min(upper,t) end
            end
        end
        if lower>upper then return nil end
        return x1+lower*dx,y1+lower*dy,x1+upper*dx,y1+upper*dy
    end
    function clip.text(font,text,x,y)
        if not current then return true end
        local w,h=font:measure(text)
        x,y,w,h=px(x),py(y),w*get_scale(),h*get_scale()
        return x>=current[1] and y>=current[2] and x+w<=current[3] and y+h<=current[4]
    end
    return clip
end
return DrawClip
