local Runtime = require("ArmorVariantManager_UI.Component.Runtime")
local List = {}
function List.new(button, d2d_api, colors)
    local component = { views = {} }
    local function copy(items)
        local result = {}
        for i,item in ipairs(items) do result[i]=item end
        return result
    end
    local function cancel(self)
        self.drag_key,self.drag_index,self.drag_items,self.drag_ids,self.drag_target_index,self.changed=nil,nil,nil,nil,nil,nil
    end
    local function reorder(items,from,target,options)
        local result=copy(items)
        if options.reorderable_only then
            local indices,movable={},{}
            local a,b
            for i,item in ipairs(items) do
                if options.draggable(item,i) then
                    indices[#indices+1]=i; movable[#movable+1]=item
                    if i==from then a=#movable end
                    if i==target then b=#movable end
                end
            end
            if not a or not b then return result end
            table.insert(movable,b,table.remove(movable,a))
            for i,index in ipairs(indices) do result[index]=movable[i] end
        else table.insert(result,target,table.remove(result,from)) end
        return result
    end
    function component:draw(items,x,y,w,h,options)
        items,options=items or {},options or {}
        local row_h,gap=options.row_height or 28,options.row_gap or 6
        local stride=row_h+gap
        local top,bottom=y+(options.top_padding or 0),y+h-(options.bottom_padding or 0)
        local room=math.max(0,bottom-top)
        local capacity=math.max(0,math.floor((room+gap)/stride))
        local overflow=#items>capacity
        if overflow then capacity=math.max(0,math.floor((room-26+gap)/stride)) end
        local key=options.key or tostring(x)..":"..tostring(y)..":"..tostring(w)
        local scope=options.scope or ""
        local view=self.views[key]
        if not view or view.scope~=scope then
            view={scope=scope,offset=0}; self.views[key]=view
            if self.drag_key==key then cancel(self) end
        end
        local function id(item,index) return options.item_key and options.item_key(item,index) or item end
        -- A live edit or equipment switch must not commit stale drag contents.
        if self.drag_key==key then
            local same=self.drag_ids and #items==#self.drag_ids
            if same then
                for i,item in ipairs(items) do if id(item,i)~=self.drag_ids[i] then same=false; break end end
            end
            if not same then cancel(self) end
        end
        local limit=math.max(0,#items-capacity)
        local function clamp(n) return math.max(0,math.min(limit,n)) end
        local selected,selected_id
        for i,item in ipairs(items) do
            if options.selected and options.selected(item,i) then selected,selected_id=i,id(item,i); break end
        end
        if selected and (view.selected~=selected_id or view.capacity~=capacity) then
            if selected<=view.offset then view.offset=selected-1
            elseif selected>view.offset+capacity then view.offset=selected-capacity end
        end
        view.selected,view.capacity=selected_id,capacity
        view.offset=clamp(view.offset)
        local mx,my=Runtime.mouse_position()
        if overflow and Runtime.point_in_rect(mx,my,x,top,w,room) then
            view.offset=clamp(view.offset-math.floor((options.wheel or 0)*3))
        end
        -- Navigation stays inside the list viewport, above the action area.
        if overflow and room>=26 then
            local nav_y,nav_w=bottom-24,math.min(32,w/3)
            if button:draw("^",x,nav_y,nav_w,22,false,nil,options.font,view.offset==0) then
                view.offset=clamp(view.offset-math.max(1,capacity))
            end
            if button:draw("v",x+w-nav_w,nav_y,nav_w,22,false,nil,options.font,view.offset==limit) then
                view.offset=clamp(view.offset+math.max(1,capacity))
            end
            if options.font then
                local label=string.format("%d-%d / %d",math.min(#items,view.offset+1),math.min(#items,view.offset+capacity),#items)
                local tx,ty=Runtime.center_text(options.font,label,x+nav_w,nav_y,w-nav_w*2,22)
                Runtime.text(d2d_api,options.font,label,tx,ty,colors.muted)
            end
        end
        local display=self.drag_key==key and self.drag_items or items
        local first,last=view.offset+1,math.min(#display,view.offset+capacity)
        if self.drag_key==key then
            local target
            if capacity>0 and Runtime.point_in_rect(mx,my,x,top,w,capacity*stride) then
                local candidate=math.min(last,first+math.floor((my-top)/stride))
                for distance=0,capacity do
                    for _,index in ipairs({candidate-distance,candidate+distance}) do
                        if index>=first and index<=last and (not options.draggable or options.draggable(display[index],index)) then target=index; break end
                    end
                    if target then break end
                end
            end
            self.drag_target_index=target
            if target and target~=self.drag_index then
                self.drag_items=reorder(display,self.drag_index,target,options)
                self.drag_index,self.changed=target,true; display=self.drag_items
            end
            if not Runtime.is_mouse_down() then
                if self.changed and options.on_reorder then options.on_reorder(display) end
                cancel(self)
            end
        end
        for i=first,last do
            local item=display[i]
            local row_y=top+(i-first)*stride
            local handle_x=x+w-28
            local draggable=options.draggable and options.draggable(item,i)==true
            local handle_hovered=draggable and Runtime.point_in_rect(mx,my,handle_x,row_y,28,row_h)
            local dragged=self.drag_key==key and self.drag_index==i
            local label=options.label and options.label(item,i) or tostring(item)
            local clicked=button:draw(label,x,row_y,w,row_h,options.selected and options.selected(item,i) or false,dragged and "dragging" or nil)
            if draggable and d2d_api and colors then
                for line=0,2 do
                    local ly=row_y+9+line*5
                    d2d_api.line(handle_x+9,ly,handle_x+19,ly,2,(handle_hovered or dragged) and colors.accent or colors.muted)
                end
            end
            if options.draw_after then options.draw_after(item,i,x,row_y,w,row_h,handle_x-4) end
            if clicked and not self.drag_key then
                if handle_hovered then
                    self.drag_key,self.drag_index,self.drag_items=key,i,copy(display)
                    self.drag_ids={}
                    for index,entry in ipairs(items) do self.drag_ids[index]=id(entry,index) end
                elseif options.on_click then options.on_click(item,i) end
            end
        end
        if self.drag_key==key and self.drag_target_index then
            local target_y=top+(self.drag_target_index-first)*stride
            d2d_api.line(x,target_y-2,x+w,target_y-2,2,colors and colors.accent or 0xFF55B8C8)
        end
        return capacity
    end
    return component
end
return List
