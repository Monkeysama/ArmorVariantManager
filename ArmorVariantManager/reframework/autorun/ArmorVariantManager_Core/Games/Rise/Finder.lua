local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local PresetAutoFinder = require("ArmorVariantManager_Core.Games.Rise.PresetSearch")
local Finder = {}

-- 保留崛起的分组/全身材质评分和文件名回退，武器按玩家及稀疏槽位采样。
function Finder.new(equipment, files)
    local get_mesh_component_recursive = equipment.mesh
    local AUTO_FIND_ARMOR_PART_INDICES = { 0, 1, 2, 3, 4 }

    -- 收集一个 GameObject 上的全部材质名
    local function collect_materials_from_object(obj, out)
        if not obj then return 0 end
        local mesh = get_mesh_component_recursive(obj)
        if not mesh then return 0 end
        local mat_count = SceneObject.call(mesh, "get_MaterialNum")
        if not mat_count or mat_count == 0 then return 0 end
        local added = 0
        for i = 0, mat_count - 1 do
            local name = SceneObject.call(mesh, "getMaterialName", i)
            if name then
                out[name] = true
                added = added + 1
            end
        end
        return added
    end

    -- 读取当前角色（或当前武器）身上的真实材质
    -- 返回：材质集合, 有效部件数, 错误信息
    local function collect_current_materials(primary, player, is_weapon_mode)
        local mats = {}
        local part_hits = 0
        if is_weapon_mode then
            local weapon_parts = equipment.weapons(primary, player)
            if not weapon_parts or not next(weapon_parts) then
                return mats, 0, "未找到武器部件"
            end
            for index = 1, 8 do
                local part = weapon_parts[index]
                if collect_materials_from_object(part, mats) > 0 then
                    part_hits = part_hits + 1
                end
            end
        else
            for _, idx in ipairs(AUTO_FIND_ARMOR_PART_INDICES) do
                local part = (equipment.parts(primary) or {})[idx]
                if collect_materials_from_object(part, mats) > 0 then
                    part_hits = part_hits + 1
                end
            end
        end
        return mats, part_hits, nil
    end

    return function(target_body_id, primary, player, is_weapon_mode)
        if not target_body_id then return nil, "No Body ID" end
        if not primary then return nil, "No Character" end

        local current_mats, part_hits, collect_err = collect_current_materials(primary, player, is_weapon_mode)
        local mat_total = 0
        for _ in pairs(current_mats) do mat_total = mat_total + 1 end

        local candidates, scan_diag = PresetAutoFinder.scan({
            fs = files.fs,
            load_json = files.load,
            analyze = PresetAutoFinder.analyze_config
        })
        local best, diag = PresetAutoFinder.find_best(candidates, current_mats, target_body_id)

        -- 诊断信息：无论成功失败都拼进返回文本，UI 会直接显示，方便排查
        local function build_detail()
            local parts = {
                string.format("扫描%d份", #candidates),
                string.format("身上材质%d个/%d部位", mat_total, part_hits)
            }
            if diag and diag.reason and diag.reason ~= "" then
                table.insert(parts, diag.reason)
            end
            if diag and diag.top and #diag.top > 0 then
                local head = diag.top[1]
                local kind = head.has_groups and "分组" or "顶层"
                table.insert(parts, string.format("最佳:%s[%s]命中%d/%d材质(%.0f%%)%s",
                    head.base, kind, head.intersect_mats, head.file_mats,
                    (head.coverage or 0) * 100,
                    head.filename_match and "·与当前编号同名" or ""))
            end
            return table.concat(parts, "，")
        end

        if not best then
            local msg = "未找到匹配的预设"
            if collect_err then
                msg = collect_err
            elseif scan_diag and scan_diag.loaded == 0 then
                msg = "未读取到任何预设文件"
            end
            return nil, msg .. "｜" .. build_detail()
        end

        -- 加载：依次尝试扫描阶段记录下来的几种路径写法
        local data = nil
        for _, p in ipairs({ best.path, "reframework/data/" .. best.path,
                             string.gsub(best.path, "^ArmorVariantManager[/\\]", "") }) do
            local loaded = files.load(p)
            if type(loaded) == "table" and (loaded.presets or loaded.groups) then
                data = loaded
                break
            end
        end
        if not data then
            return nil, "预设文件读取失败: " .. tostring(best.path)
        end

        return data, string.format("已匹配: %s｜%s", best.base, build_detail())
    end
end

return Finder
