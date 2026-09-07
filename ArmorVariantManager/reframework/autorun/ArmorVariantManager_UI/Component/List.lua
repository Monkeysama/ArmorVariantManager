local Runtime = require("ArmorVariantManager_UI.Component.Runtime")

local List = {}

-- 创建按固定行高排列的列表组件，适用于分组、预设等列表。
function List.new(button, d2d_api, colors)
    local component = {
        drag_key = nil,
        drag_index = nil,
        drag_items = nil,
        drag_target_index = nil,
        scroll_offsets = {},
        scroll_drag_key = nil,
        scroll_drag_offset = 0
    }

    local function copy_items(items)
        local copied = {}
        for index, item in ipairs(items or {}) do copied[index] = item end
        return copied
    end

    -- 按列表规则移动项目；reorderable_only 模式会保留固定项目的原位置。
    local function reorder_items(items, from_index, target_index, options)
        if not target_index or target_index == from_index then return items end
        local reordered = copy_items(items)
        if options.reorderable_only then
            local movable_indices = {}
            for index, item in ipairs(reordered) do
                if options.draggable(item, index) == true then
                    table.insert(movable_indices, index)
                end
            end
            local from_position, target_position
            for position, index in ipairs(movable_indices) do
                if index == from_index then from_position = position end
                if index == target_index then target_position = position end
            end
            if not from_position or not target_position then return reordered end
            local movable_items = {}
            for _, index in ipairs(movable_indices) do
                table.insert(movable_items, reordered[index])
            end
            local moved = table.remove(movable_items, from_position)
            table.insert(movable_items, target_position, moved)
            for position, index in ipairs(movable_indices) do
                reordered[index] = movable_items[position]
            end
            return reordered
        end
        local moved = table.remove(reordered, from_index)
        table.insert(reordered, target_index, moved)
        return reordered
    end

    -- 计算鼠标当前对应的列表行，并跳过不可拖动的默认/全局分组。
    local function get_drop_index(items, list_y, mouse_y, h, options, scroll_offset, max_items)
        local row_height = options.row_height or 28
        local row_gap = options.row_gap or 6
        local top_padding = options.top_padding or 0
        local bottom_padding = options.bottom_padding or 0
        max_items = max_items or math.floor((h - top_padding - bottom_padding + row_gap) / (row_height + row_gap))
        max_items = math.max(0, math.min(#items, max_items))
        if max_items == 0 or mouse_y < list_y + top_padding
            or mouse_y > list_y + top_padding + max_items * (row_height + row_gap) then
            return nil
        end
        local relative = mouse_y - (list_y + top_padding)
        local index = math.floor(relative / (row_height + row_gap)) + 1 + (scroll_offset or 0)
        local first_index = (scroll_offset or 0) + 1
        local last_index = math.min(#items, (scroll_offset or 0) + max_items)
        index = math.max(first_index, math.min(last_index, index))
        local function can_drag(item, item_index)
            return not options.draggable or options.draggable(item, item_index) == true
        end
        if can_drag(items[index], index) then return index end
        for distance = 1, max_items do
            local before, after = index - distance, index + distance
            if before >= first_index and can_drag(items[before], before) then return before end
            if after <= last_index and can_drag(items[after], after) then return after end
        end
        return nil
    end

    function component:draw(items, x, y, w, h, options)
        options = options or {}
        local row_height = options.row_height or 28
        local row_gap = options.row_gap or 6
        local top_padding = options.top_padding or 0
        local bottom_padding = options.bottom_padding or 0
        local max_items = math.floor((h - top_padding - bottom_padding + row_gap) / (row_height + row_gap))
        max_items = math.max(0, math.min(#(items or {}), max_items))
        local list_key = options.key or tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(w)
        local mouse_x, mouse_y = Runtime.mouse_position()
        local item_count = #(items or {})
        local max_offset = math.max(0, item_count - max_items)
        local scroll_offset = math.max(0, math.min(max_offset,
            tonumber(self.scroll_offsets[list_key]) or 0))
        local scroll_bar_width = 8
        local scroll_bar_gap = 4
        local content_w = math.max(1, w - scroll_bar_width - scroll_bar_gap)
        local track_x = x + w - scroll_bar_width
        local track_y = y + top_padding
        local track_h = math.max(1, h - top_padding - bottom_padding)
        local scrollable = max_offset > 0 and max_items > 0
        local track_hovered = scrollable and Runtime.point_in_rect(mouse_x, mouse_y,
            track_x - scroll_bar_gap, track_y, scroll_bar_width + scroll_bar_gap, track_h)

        -- 列表滚动状态独立保存；鼠标滚轮只作用于当前列表的可视区域。
        if scrollable and Runtime.point_in_rect(mouse_x, mouse_y,
            x, track_y, w, track_h) and self.scroll_drag_key ~= list_key then
            local wheel = tonumber(options.wheel) or 0
            if wheel ~= 0 then
                local wheel_step = options.wheel_step or 3
                scroll_offset = math.max(0, math.min(max_offset,
                    scroll_offset - math.floor(wheel * wheel_step)))
            end
        end

        local thumb_h = scrollable and math.max(24, track_h * max_items / item_count) or track_h
        local thumb_range = math.max(0, track_h - thumb_h)
        local thumb_y = track_y
        if scrollable and max_offset > 0 then
            thumb_y = track_y + thumb_range * scroll_offset / max_offset
        end
        local thumb_hovered = scrollable and Runtime.point_in_rect(mouse_x, mouse_y,
            track_x - scroll_bar_gap, thumb_y, scroll_bar_width + scroll_bar_gap, thumb_h)
        if scrollable and Runtime.is_mouse_clicked() and track_hovered then
            self.scroll_drag_key = list_key
            self.scroll_drag_offset = thumb_hovered and mouse_y - thumb_y or thumb_h / 2
        end
        if self.scroll_drag_key == list_key and Runtime.is_mouse_down() and thumb_range > 0 then
            local next_thumb_y = math.max(track_y, math.min(track_y + thumb_range,
                mouse_y - self.scroll_drag_offset))
            scroll_offset = math.floor((next_thumb_y - track_y) / thumb_range * max_offset + 0.5)
        elseif self.scroll_drag_key == list_key and not Runtime.is_mouse_down() then
            self.scroll_drag_key = nil
            self.scroll_drag_offset = 0
        end
        scroll_offset = math.max(0, math.min(max_offset, scroll_offset))
        self.scroll_offsets[list_key] = scroll_offset
        local row_y = y + top_padding
        local start_index = scroll_offset + 1
        local end_index = math.min(item_count, scroll_offset + max_items)

        local display_items = items or {}
        if self.drag_key == list_key and self.drag_items then
            display_items = self.drag_items
            local target_index = get_drop_index(display_items, y, mouse_y, h, options,
                scroll_offset, max_items)
            self.drag_target_index = target_index
            if target_index and target_index ~= self.drag_index then
                self.drag_items = reorder_items(display_items, self.drag_index, target_index, options)
                self.drag_index = target_index
                display_items = self.drag_items
            end
        end

        -- 鼠标释放时提交顺序，只在拖动源列表的绘制阶段执行一次。
        if self.drag_key == list_key and self.drag_index and not Runtime.is_mouse_down() then
            local from_index = self.drag_index
            local reordered = self.drag_items or display_items
            if options.on_reorder and reordered then
                options.on_reorder(reordered, from_index, self.drag_index)
            end
            self.drag_key = nil
            self.drag_index = nil
            self.drag_items = nil
            self.drag_target_index = nil
        end

        for i = start_index, end_index do
            local item = display_items[i]
            local label = options.label and options.label(item, i) or tostring(item)
            local selected = options.selected and options.selected(item, i) or false
            local draggable = options.draggable and options.draggable(item, i) == true
            local handle_x = x + content_w - 28
            local handle_hovered = draggable and Runtime.point_in_rect(mouse_x, mouse_y,
                handle_x, row_y, 28, row_height)
            local is_dragged = self.drag_key == list_key and self.drag_index == i
            local clicked = button:draw(label, x, row_y, content_w, row_height, selected,
                is_dragged and "dragging" or nil)
            if draggable and d2d_api and colors then
                -- 悬停或按住拖动时使用与按钮边框一致的强调色。
                local handle_dragging = self.drag_key == list_key and self.drag_index == i
                local handle_color = (handle_hovered or handle_dragging)
                    and colors.accent or colors.muted
                for line = 0, 2 do
                    local line_y = row_y + 9 + line * 5
                    d2d_api.line(handle_x + 9, line_y, handle_x + 19, line_y, 2, handle_color)
                end
            end
            if options.draw_after then
                options.draw_after(item, i, x, row_y, content_w, row_height, handle_x - 4)
            end
            if clicked and not handle_hovered and not self.drag_key then
                if options.on_click then options.on_click(item, i) end
            end
            if draggable and clicked and handle_hovered and not self.drag_key then
                self.drag_key = list_key
                self.drag_index = i
                self.drag_items = copy_items(display_items)
                self.drag_target_index = i
            end
            row_y = row_y + row_height + row_gap
        end
        if self.drag_key == list_key and self.drag_target_index then
            local target_y = y + top_padding + (self.drag_target_index - scroll_offset - 1)
                * (row_height + row_gap)
            d2d_api.line(x, target_y - 2, x + content_w, target_y - 2, 2,
                colors and colors.accent or 0xFF55B8C8)
        end

        -- 滚动条仅在内容超出可视区域时显示，样式与材质列表保持一致。
        if scrollable and d2d_api then
            d2d_api.fill_rounded_rect(track_x, track_y, scroll_bar_width, track_h,
                3, 3, colors and colors.panel_alt or 0xFF252E3A)
            d2d_api.fill_rounded_rect(track_x, thumb_y, scroll_bar_width, thumb_h,
                3, 3, (thumb_hovered or self.scroll_drag_key == list_key)
                    and (colors and colors.accent or 0xFF55B8C8)
                    or (colors and colors.border or 0xFF3D4A5C))
        end
        return max_items
    end

    return component
end

return List


