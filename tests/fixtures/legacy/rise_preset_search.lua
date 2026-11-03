-- ============================================================================
--  PresetAutoFinder.lua —— 「自动查找预设」统一匹配内核
-- ============================================================================

local M = {}

-- 统一路径分隔符，便于做字符串判断
local function to_posix(path)
    return (string.gsub(path or "", "\\", "/"))
end

-- 文件名（去掉扩展名）
local function base_name(path)
    local name = string.match(to_posix(path), "([^/]+)$") or to_posix(path)
    return (string.gsub(name, "%.json$", ""))
end

local function is_backup_path(path)
    local p = to_posix(path)
    return string.find(p, "/backup/") ~= nil
end

-- ============================================================================
--  1. 扫描磁盘上的候选预设文件
-- ============================================================================
-- 返回：candidates（数组，按主目录优先 + 文件名排序）, diag（诊断信息）
function M.scan(game)
    local fs_lib = game.fs
    local diag = { patterns = 0, raw_files = 0, loaded = 0, skipped = {} }
    if not fs_lib or not fs_lib.glob then
        return {}, diag
    end

    -- REFramework 在不同版本/工作目录下 glob 的写法不完全一样，这里把
    -- 正反斜杠两种写法都试一遍（与旧版手动查找保持一致）。
    local search_patterns = {
        "reframework/data/ArmorVariantManager/.*\\.json",
        "reframework\\data\\ArmorVariantManager\\.*\\.json",
        "ArmorVariantManager/.*\\.json",
        "ArmorVariantManager\\\\.*\\.json",
        "data/ArmorVariantManager/.*\\.json",
        -- backup 目录单独列出来：兜底用，避免主目录文件被改名/移动后彻底找不到
        "reframework/data/ArmorVariantManager/backup/.*\\.json",
        "reframework\\data\\ArmorVariantManager\\backup\\.*\\.json"
    }
    diag.patterns = #search_patterns

    local raw_files = {}
    local seen_raw = {}
    for _, pattern in ipairs(search_patterns) do
        local ok, found = pcall(fs_lib.glob, pattern)
        if ok and type(found) == "table" then
            for _, f in ipairs(found) do
                if type(f) == "string" and not seen_raw[f] then
                    seen_raw[f] = true
                    table.insert(raw_files, f)
                end
            end
        end
    end
    diag.raw_files = #raw_files

    -- 系统文件 / 运行时文件不参与匹配
    local skip_exact = {
        GlobalSettings = true,
        Profile = true,
        D2DInputState = true
    }

    -- 归一化路径：统一成 "ArmorVariantManager/xxx.json" 形式，
    -- 并生成 json.load_file 可能需要的几种路径写法。
    local candidates = {}
    local seen_key = {}
    for _, raw in ipairs(raw_files) do
        local posix = to_posix(raw)
        local base = base_name(raw)

        -- 过滤系统文件
        local lower = string.lower(posix)
        local skip = skip_exact[base] == true
            or string.find(lower, "/runtime/") ~= nil
            or string.match(lower, "%.json%.bak$") ~= nil
        if not skip then
            -- 去掉 reframework/data/ 等前缀，得到 ArmorVariantManager/xxx.json
            local rel = posix
            rel = string.gsub(rel, "^[Rr]eframework[/]?[Dd]ata[/]", "")
            rel = string.gsub(rel, "^[Dd]ata[/]", "")
            rel = string.gsub(rel, "^[/]+", "")
            if not string.match(rel, "^[Aa]rmor[Vv]ariant[Mm]anager[/]") then
                rel = "ArmorVariantManager/" .. rel
            end

            -- 去重键：相对路径（小写，避免同一文件因大小写不同重复读）
            local key = string.lower(rel)
            if not seen_key[key] then
                seen_key[key] = true
                table.insert(candidates, {
                    raw = raw,
                    rel = rel,
                    base = base,
                    is_backup = is_backup_path(posix),
                    paths = { raw, rel, "reframework/data/" .. rel }
                })
            end
        else
            table.insert(diag.skipped, raw)
        end
    end

    -- 先按路径排序，保证遍历顺序稳定（结果可复现，便于排查）
    table.sort(candidates, function(a, b)
        if a.is_backup ~= b.is_backup then
            return not a.is_backup
        end
        return string.lower(a.rel) < string.lower(b.rel)
    end)

    -- 读取每个候选文件并做结构分析
    local list = {}
    for _, cand in ipairs(candidates) do
        local data = nil
        for _, p in ipairs(cand.paths) do
            local ok, loaded = pcall(game.load_json, p)
            if ok and type(loaded) == "table" and (loaded.presets or loaded.groups) then
                data = loaded
                break
            end
        end
        if data then
            local analyzed = game.analyze(data)
            analyzed.path = cand.rel
            analyzed.base = cand.base
            analyzed.is_backup = cand.is_backup
            analyzed.source = cand.rel
            diag.loaded = diag.loaded + 1
            table.insert(list, analyzed)
        end
    end

    return list, diag
end

-- ============================================================================
--  2. 结构分析：把一份预设文件「认得出来」的材质全部收集到一张表里
-- ----------------------------------------------------------------------------
--  返回 {
--    has_groups  = 是否含分组,
--    material_set= { [材质名] = true },   -- 用于快速求交集
--    flat_list   = { { preset=名字, parts={ {part=部件键, mats={材质名=true}} } } },
--    group_list  = { { group=分组名, is_global=bool, mats={材质名=true} } }
--  }
-- ============================================================================
function M.analyze_config(data)
    local result = {
        has_groups = false,
        material_set = {},
        flat_list = {},
        group_list = {}
    }
    if type(data) ~= "table" then return result end

    -- ---------- 2.1 顶层（无分组）预设 ----------
    if type(data.presets) == "table" then
        local order = data.preset_order
        local names = {}
        local seen = {}
        if type(order) == "table" then
            for _, n in ipairs(order) do
                if type(n) == "string" and data.presets[n] and not seen[n] then
                    seen[n] = true
                    table.insert(names, n)
                end
            end
        end
        for n, _ in pairs(data.presets) do
            if type(n) == "string" and not seen[n] then
                seen[n] = true
                table.insert(names, n)
            end
        end
        -- pairs 遍历顺序随机，排序保证结果稳定
        if type(order) ~= "table" or #order == 0 then
            table.sort(names)
        end

        for _, pname in ipairs(names) do
            local preset = data.presets[pname]
            if type(preset) == "table" then
                local parts = {}
                for part_key, part_data in pairs(preset) do
                    if type(part_data) == "table" and type(part_data.materials) == "table" then
                        local mats = {}
                        for mat_name, _ in pairs(part_data.materials) do
                            if type(mat_name) == "string" then
                                mats[mat_name] = true
                                result.material_set[mat_name] = true
                            end
                        end
                        if next(mats) then
                            table.insert(parts, { part = tostring(part_key), mats = mats })
                        end
                    end
                end
                if #parts > 0 then
                    table.insert(result.flat_list, { preset = pname, parts = parts })
                end
            end
        end
    end

    -- ---------- 2.2 分组预设 ----------
    -- 关键点：分组里「显示/隐藏」两个预设用的是同一批材质，差别只在 true/false。
    -- 所以能不能认出这份预设，取决于「分组拥有的材质(mask)」是否出现在当前装备上，
    -- 而不是某个具体预设的开关值。这里统一取 mask（缺失时回退到预设条目里的键名）。
    if type(data.groups) == "table" then
        local g_order = data.group_order
        local gnames = {}
        local gseen = {}
        if type(g_order) == "table" then
            for _, n in ipairs(g_order) do
                if type(n) == "string" and data.groups[n] and not gseen[n] then
                    gseen[n] = true
                    table.insert(gnames, n)
                end
            end
        end
        for n, _ in pairs(data.groups) do
            if type(n) == "string" and not gseen[n] then
                gseen[n] = true
                table.insert(gnames, n)
            end
        end

        for _, gname in ipairs(gnames) do
            local g_data = data.groups[gname]
            if type(g_data) == "table" then
                local mats = {}
                local function add_mat(name)
                    if type(name) == "string" then
                        mats[name] = true
                        result.material_set[name] = true
                    end
                end

                if type(g_data.mask) == "table" then
                    for _, part_mats in pairs(g_data.mask) do
                        if type(part_mats) == "table" then
                            for mat_name, _ in pairs(part_mats) do add_mat(mat_name) end
                        end
                    end
                end
                if not next(mats) and type(g_data.presets) == "table" then
                    for _, preset in pairs(g_data.presets) do
                        if type(preset) == "table" then
                            for _, part_data in pairs(preset) do
                                if type(part_data) == "table" and type(part_data.materials) == "table" then
                                    for mat_name, _ in pairs(part_data.materials) do add_mat(mat_name) end
                                end
                            end
                        end
                    end
                end

                if next(mats) then
                    result.has_groups = true
                    table.insert(result.group_list, {
                        group = gname,
                        is_global = g_data.is_global == true,
                        mats = mats
                    })
                end
            end
        end
    end

    return result
end

-- ============================================================================
--  3. 给单个候选打分
-- ============================================================================
local function score_candidate(cand, current_mats, body_id)
    local m = {
        path = cand.path,
        base = cand.base,
        is_backup = cand.is_backup,
        has_groups = cand.has_groups,
        file_mats = 0,
        intersect_mats = 0,     -- 命中的材质数
        intersect_parts = 0,    -- 命中的部件数
        flat_score = 0,         -- 顶层预设里最多命中的材质数
        group_score = 0,        -- 分组 mask 命中的材质数
        coverage = 0,
        filename_match = false
    }

    -- 文件名是否与当前 body_id 相同（这是很强的信号：管理器就是按 body_id 存盘的）
    local want = string.lower(tostring(body_id or ""))
    want = string.gsub(want, "%.json$", "")
    if want ~= "" then
        local have = string.lower(cand.base or "")
        if have == want or string.find(have, want, 1, true) then
            m.filename_match = true
        end
    end

    -- 统计该文件「认得出来」的材质总数
    for _ in pairs(cand.material_set or {}) do
        m.file_mats = m.file_mats + 1
    end

    -- ---------- 3.1 顶层（无分组）预设：遍历所有预设 × 所有部件 ----------
    local touched = {}
    for _, entry in ipairs(cand.flat_list or {}) do
        local preset_hits = 0
        for _, part in ipairs(entry.parts) do
            local part_hit = false
            for mat_name, _ in pairs(part.mats) do
                if current_mats[mat_name] then
                    preset_hits = preset_hits + 1
                    part_hit = true
                    m.intersect_mats = m.intersect_mats + 1
                end
            end
            if part_hit then touched[part.part] = true end
        end
        if preset_hits > m.flat_score then
            m.flat_score = preset_hits
        end
    end
    for _ in pairs(touched) do
        m.intersect_parts = m.intersect_parts + 1
    end

    -- ---------- 3.2 分组预设：用分组 mask ∩ 当前材质 ----------
    local g_touched = {}
    for _, g in ipairs(cand.group_list or {}) do
        for mat_name, _ in pairs(g.mats) do
            if current_mats[mat_name] then
                m.group_score = m.group_score + 1
                g_touched[g.group] = true
            end
        end
    end
    if cand.has_groups then
        -- 分组结构下，命中材质按分组口径统计；部件数用「分组命中数」近似，
        -- 因为 mask 里的部件键才是真正被这个分组控制的部位。
        m.intersect_mats = m.group_score
        m.intersect_parts = 0
        for _ in pairs(g_touched) do
            m.intersect_parts = m.intersect_parts + 1
        end
    end

    if m.file_mats > 0 then
        m.coverage = m.intersect_mats / m.file_mats
    end

    -- 说明：这里不再对命中数做任何「加分」。
    -- 能认出这份预设，唯一可靠的依据就是「材质对上了多少」；
    -- 文件名是否相同只在排序的最后阶段作为次要参考（见 find_best 的 better()）。
    return m
end

-- ============================================================================
--  4. 从所有候选中选出最佳匹配
-- ============================================================================
function M.find_best(candidates, current_mats, body_id)
    current_mats = current_mats or {}

    local scored = {}
    local diag = {
        total = #candidates,
        with_mats = 0,          -- 有材质可读的候选数
        material_ok = false,    -- 是否完成了材质匹配
        best = nil,
        top = {},               -- 前几名，用于诊断输出
        reason = ""
    }

    for _, cand in ipairs(candidates) do
        local m = score_candidate(cand, current_mats, body_id)
        table.insert(scored, m)
        if m.intersect_mats > 0 then
            diag.with_mats = diag.with_mats + 1
        end
    end

    -- 排序规则（越靠前优先级越高）：
    --   1. 命中的材质数量   —— 唯一真正说明「这份预设是不是当前这身装备」的指标
    --   2. 文件名是否与 body_id 相同
    --      （279/280 这种同模型换编号的情况：命中数完全一样，此时就该选
    --        「本来就属于这个编号」的那份，而不是字典序靠前的那份）
    --   3. 命中的部件/分组数
    --   4. 覆盖率（命中材质 / 文件材质总数）
    --   5. 非备份优先
    --   6. 路径字典序（保证结果稳定可复现）
    local function better(a, b)
        if a.intersect_mats ~= b.intersect_mats then return a.intersect_mats > b.intersect_mats end
        if a.filename_match ~= b.filename_match then return a.filename_match end
        if a.intersect_parts ~= b.intersect_parts then return a.intersect_parts > b.intersect_parts end
        if math.abs(a.coverage - b.coverage) > 1e-9 then return a.coverage > b.coverage end
        if a.is_backup ~= b.is_backup then return not a.is_backup end
        return a.path < b.path
    end
    table.sort(scored, better)

    for i = 1, math.min(3, #scored) do
        table.insert(diag.top, scored[i])
    end

    -- ---------- 4.1 第 1 级：材质匹配 ----------
    -- 阈值：至少命中 1 个材质（材质名基本都带 mod 前缀，误命中概率很低），
    -- 并且要求命中数不低于文件自身材质数的 3%（防止只有 1 个全局材质刚好撞上）。
    local best = nil
    for _, m in ipairs(scored) do
        if m.intersect_mats >= 1 and m.coverage >= 0.03 then
            best = m
            break
        end
    end
    if best then
        diag.material_ok = true
        diag.best = best
        diag.reason = string.format("材质匹配 %d 个（覆盖率 %.0f%%）",
            best.intersect_mats, best.coverage * 100)
        return best, diag
    end

    -- ---------- 4.2 第 2 级：材质读不到时，按文件名兜底 ----------
    local by_name = nil
    for _, m in ipairs(scored) do
        if m.filename_match then
            by_name = m
            break
        end
    end
    if by_name then
        diag.best = by_name
        diag.reason = "运行时未读到材质，按文件名匹配"
        return by_name, diag
    end

    diag.reason = (#candidates == 0) and "未找到任何预设文件" or "没有匹配的预设"
    return nil, diag
end

return M
