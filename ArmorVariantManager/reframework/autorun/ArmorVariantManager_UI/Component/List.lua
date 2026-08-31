local Runtime = require("ArmorVariantManager_UI.Component.Runtime")

local List = {}

-- 创建按固定行高排列的列表组件，适用于分组、预设等列表。
function List.new(button, d2d_api, colors)
    local component = {
        drag_key = nil,
        drag_index = nil,
        drag_items = nil,
        drag_target_index = nil
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
    local function get_drop_index(items, list_y, mouse_y, h, options)
        local row_height = options.row_height or 28
        local row_gap = options.row_gap or 6
        local top_padding = options.top_padding or 0
        local bottom_padding = options.bottom_padding or 0
        local max_items = math.floor((h - top_padding - bottom_padding + row_gap) / (row_height + row_gap))
        max_items = math.max(0, math.min(#items, max_items))
        if max_items == 0 or mouse_y < list_y + top_padding
            or mouse_y > list_y + top_padding + max_items * (row_height + row_gap) then
            return nil
        end
        local relative = mouse_y - (list_y + top_padding)
        local index = math.floor(relative / (row_height + row_gap)) + 1
        index = math.max(1, math.min(max_items, index))
        local function can_drag(item, item_index)
            return not options.draggable or options.draggable(item, item_index) == true
        end
        if can_drag(items[index], index) then return index end
        for distance = 1, max_items do
            local before, after = index - distance, index + distance
            if before >= 1 and can_drag(items[before], before) then return before end
            if after <= max_items and can_drag(items[after], after) then return after end
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
        max_items = math.max(0, max_items)
        local row_y = y + top_padding
        local list_key = options.key or tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(w)
        local mouse_x, mouse_y = Runtime.mouse_position()

        local display_items = items or {}
        if self.drag_key == list_key and self.drag_items then
            display_items = self.drag_items
            local target_index = get_drop_index(display_items, y, mouse_y, h, options)
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

        for i, item in ipairs(display_items) do
            if i > max_items then break end
            local label = options.label and options.label(item, i) or tostring(item)
            local selected = options.selected and options.selected(item, i) or false
            local draggable = options.draggable and options.draggable(item, i) == true
            local handle_x = x + w - 28
            local handle_hovered = draggable and Runtime.point_in_rect(mouse_x, mouse_y,
                handle_x, row_y, 28, row_height)
            local is_dragged = self.drag_key == list_key and self.drag_index == i
            local clicked = button:draw(label, x, row_y, w, row_height, selected,
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
                options.draw_after(item, i, x, row_y, w, row_height, handle_x - 4)
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
            local target_y = y + top_padding + (self.drag_target_index - 1) * (row_height + row_gap)
            d2d_api.line(x, target_y - 2, x + w, target_y - 2, 2,
                colors and colors.accent or 0xFF55B8C8)
        end
        return max_items
    end

    return component
end

return List


