-- 冻结荒野 d252a44 与崛起 093c61c 的默认初始化，副作用由测试宿主提供。
return {
    Wilds = function(env)
        return assert(load([==[
local function apply_all_defaults(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    -- 彻底重置该 Body 的复合状态
    active_overrides[body_id] = {}
    ground_clipping_presets.reset(body_id)
    active_overrides[body_id].ground_clipping_fix = GroundClippingFix.default_settings(config)
    -- 同步初始化 active_group_presets，使 is_globally_hidden 等函数能找到正确的预设
    if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
    -- 1. 首先合并主列表默认预设
    if config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then
            merge_preset_into_overrides(body_id, def)
            -- 记录主列表当前预设（key 为空字符串）
            if not active_group_presets[body_id][""] or active_group_presets[body_id][""] == "" then
                active_group_presets[body_id][""] = config.default_preset
            end
        end
    end
    -- 2. 合并所有普通分组的默认预设
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if not g_data.is_global then
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then
                        merge_preset_into_overrides(body_id, g_def)
                        if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                            active_group_presets[body_id][g_name] = g_data.default_preset
                        end
                    end
                end
            end
        end
    end
    -- 3. 最后合并所有全局分组的默认预设（只锁隐藏项，强制覆盖）
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if g_data.is_global then
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then
                        merge_global_preset_into_overrides(body_id, g_def)
                        if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                            active_group_presets[body_id][g_name] = g_data.default_preset
                        end
                    end
                end
            end
        end
    end
end


return apply_all_defaults
]==], "legacy-defaults", "t", env))()
    end,
    Rise = function(env)
        return assert(load([==[
local function apply_all_defaults_impl(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    active_overrides[body_id] = {}
    bump_overrides_version(body_id)
    active_group_presets[body_id] = {}
    -- 清除渲染缓存，强制下一帧重新应用（apply_all_defaults 上面已经 bump 过版本号）
    Applied.invalidate_body(body_id)

    -- 1. 主列表默认预设
    if config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then
            merge_preset_into_overrides(body_id, def)
            if not active_group_presets[body_id][""] or active_group_presets[body_id][""] == "" then
                active_group_presets[body_id][""] = config.default_preset
            end
        end
    end

    -- 2. 非全局分组默认预设
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if not g_data.is_global then
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then
                        merge_preset_into_overrides(body_id, g_def)
                        if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                            active_group_presets[body_id][g_name] = g_data.default_preset
                        end
                    end
                end
            end
        end
    end

    active_overrides[body_id] = TransformManager.set_model_base(body_id, active_overrides[body_id], active_group_presets[body_id])

    -- 3. 全局分组默认预设（仅隐藏覆盖），增加 Fallback 机制
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if g_data.is_global then
                local default_preset = g_data.default_preset
                -- 如果 default_preset 无效，自动选取该分组的第一个预设
                if not default_preset or default_preset == "" then
                    if g_data.presets and next(g_data.presets) then
                        -- 优先按 preset_order 排序，取第一个
                        if g_data.preset_order and #g_data.preset_order > 0 then
                            for _, pname in ipairs(g_data.preset_order) do
                                if g_data.presets[pname] then
                                    default_preset = pname
                                    break
                                end
                            end
                        end
                        -- 如果 preset_order 无效，按遍历顺序取第一个
                        if not default_preset then
                            for pname, _ in pairs(g_data.presets) do
                                default_preset = pname
                                break
                            end
                        end
                    end
                end
                -- 应用选定的默认预设
                if default_preset and default_preset ~= "" and g_data.presets and g_data.presets[default_preset] then
                    local g_def = g_data.presets[default_preset]
                    merge_global_preset_into_overrides(body_id, g_def)  -- 内部会递增版本号
                    if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                        active_group_presets[body_id][g_name] = default_preset
                        TransformManager.update_base_preset(body_id, config, g_name, default_preset, function(a) return a end)
                    end
                end
            end
        end
    end
end

return apply_all_defaults_impl
]==], "legacy-defaults", "t", env))()
    end,
}
