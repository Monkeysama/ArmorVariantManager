-- Frozen Wilds application operations from a828bc1.
return function(env)
    return assert(load([=[
return {
    reorder_groups = function(items)
        local body_id = get_body_id()
        if not body_id or not current_config then return end
        current_config.group_order = {}
        for _, item in ipairs(items or {}) do
            if item.name and item.name ~= "" then
                table.insert(current_config.group_order, item.name)
            end
        end
        update_group_names_list()
        save_current_config_to_file(body_id)
    end,
    reorder_presets = function(items)
        local body_id = get_body_id()
        if not body_id or not current_config then return end
        local target = current_config
        if current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name] then
            target = current_config.groups[current_group_name]
        end
        target.preset_order = {}
        for _, preset_name in ipairs(items or {}) do
            table.insert(target.preset_order, preset_name)
        end
        update_preset_names_list()
        save_current_config_to_file(body_id)
    end,
    delete_preset = function(preset_name)
        local body_id = get_body_id()
        if not body_id or not preset_name or preset_name == "" or not current_config then return false end
        local target = current_config
        if current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name] then
            target = current_config.groups[current_group_name]
        end
        if not target.presets or not target.presets[preset_name] then return false end
        target.presets[preset_name] = nil
        if target.default_preset == preset_name then target.default_preset = "" end
        if target.preset_order then
            for index = #target.preset_order, 1, -1 do
                if target.preset_order[index] == preset_name then
                    table.remove(target.preset_order, index)
                    break
                end
            end
        end
        update_preset_names_list()
        save_current_config_to_file(body_id)
        return true
    end,

}
]=], "legacy-preset-edits", "t", env))()
end
