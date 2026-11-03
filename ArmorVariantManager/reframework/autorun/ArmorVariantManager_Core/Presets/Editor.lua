local Editor = {}

-- 主列表与分组共用编辑规则，游戏侧只负责捕获预设内容和保存后的外观刷新。
function Editor.target(config, group_name)
    if group_name == "" then return config end
    return config.groups and config.groups[group_name]
end

local function copy_order(order)
    if not order then return nil end
    local result = {}
    for i, name in ipairs(order) do result[i] = name end
    return result
end

-- 新预设追加排序；覆盖保留位置。写盘失败撤销本次编辑。
function Editor.write(config, group_name, name, data, persist)
    if not name or name == "" then return false end
    local old_groups = config.groups
    local target = Editor.target(config, group_name)
    local created = target == nil
    if created then
        config.groups = config.groups or {}
        target = { presets = {}, mask = {} }
        config.groups[group_name] = target
    end
    local presets, order = target.presets, target.preset_order
    local previous = presets and presets[name]
    target.presets = presets or {}
    if not previous then
        target.preset_order = copy_order(order) or {}
        table.insert(target.preset_order, name)
    end
    target.presets[name] = data
    if persist(false) then return true end
    target.presets[name] = previous
    target.presets, target.preset_order = presets, order
    if created then
        config.groups[group_name] = nil
        config.groups = old_groups
    end
    return false
end

-- 删除仅清理该列表的预设、默认名称和排序；条件目标仍保留原名称。
function Editor.delete(config, group_name, name, persist)
    local target = Editor.target(config, group_name)
    if not target or not target.presets or not target.presets[name] then return false end
    local preset, default, order = target.presets[name], target.default_preset, target.preset_order
    target.presets[name] = nil
    if default == name then target.default_preset = "" end
    if order then
        target.preset_order = copy_order(order)
        for i = #target.preset_order, 1, -1 do
            if target.preset_order[i] == name then table.remove(target.preset_order, i); break end
        end
    end
    if persist(false) then return true end
    target.presets[name], target.default_preset, target.preset_order = preset, default, order
    return false
end

-- 设置默认值只持久化名称，不能重置其他分组的当前外观。
function Editor.set_default(config, group_name, name, persist)
    local target = Editor.target(config, group_name)
    if not target or not target.presets or not target.presets[name] then return false end
    local previous = target.default_preset
    target.default_preset = name
    if persist(true) then return true end
    target.default_preset = previous
    return false
end

local function save_order(target, key, names, persist)
    if not target then return false end
    local previous = target[key]
    target[key] = copy_order(names) or {}
    if persist(false) then return true end
    target[key] = previous
    return false
end

-- 两套 UI 提交名称序列，不把拖拽控件的数据结构写进配置。
function Editor.reorder(config, group_name, names, persist)
    return save_order(Editor.target(config, group_name), "preset_order", names, persist)
end

function Editor.reorder_groups(config, names, persist)
    return save_order(config, "group_order", names, persist)
end

return Editor
