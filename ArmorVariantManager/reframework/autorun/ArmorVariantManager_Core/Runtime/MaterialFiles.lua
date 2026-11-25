local Mdf2 = require("ArmorVariantManager_Core.Runtime.Mdf2")
local Writer = require("ArmorVariantManager_Core.Runtime.Palette")
local Files = {}

-- 网格所用 mdf2 文件的导出与写入，只用引擎组件方法和原生插件的文件接口，不依赖具体游戏。
--
-- 导出：把网格上一个材质按 RE Mesh Editor 的材质预设格式写到 reframework/data/ArmorVariantManager/mdf2_presets/<游戏>/<名字>.json，
--   参数取当前值（调色覆盖后的）。材质头、Flags、贴图、MMTRS / GPBF 取自 MOD 的 mdf2；读不到时只用运行时数据，并返回原因。
-- 写入：把一个部位的调色覆盖值原地写进 MOD 的 mdf2（原生插件第一次覆盖前留 <文件>.avm_bak），再让本局立即生效：
--   1. 同一路径的资源引擎会缓存，文件改了也不会重读，所以另写一份重载副本 <名字>_avmr<n>.mdf2.<版本> 并加载它
--   2. 资源异步加载，等 RELOAD_DELAY 帧再 set_Material；材质数没对上就再等一轮，最多 MAX_TRIES 次
--   3. 换上的同一帧调用 opts.swapped，由调用方清掉写入器状态和已写进文件的覆盖值
--   下次启动时引擎直接读改好的原文件，副本只在本局用。
-- 副本的清理：本局内不删。引用放掉后引擎可能卸载资源，再按副本路径加载（例如复制角色、预览模型照当前材质路径加载）
--   时文件不在会报 missing file，整个模型不显示。副本路径记在 reframework/data 的清单里，下次启动游戏时删除；
--   脚本重置不算新的启动（原生插件给出进程标识），不删。
--
-- deps：
--   version          mdf2 格式版本（扩展名里的数字，如《荒野》为 45）
--   bridge()         原生插件的 Lua 表（read_game_file 等），没有时返回 nil
--   json             { load(path), dump(path, value) }，路径相对 reframework/data
--   load_holder(resource_path)  加载材质资源并返回 MeshMaterialResourceHolder，失败时报错（可替换，测试用）
--   log(msg)         可选
local RELOAD_DELAY = 10      -- 帧
local MAX_TRIES = 3
local MANIFEST = "ArmorVariantManager/mdf2_reload_copies.json"
local MAX_KEPT = 16          -- 留住引用的资源 / holder 个数

local function try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function default_holder(resource_path)
    local resource = sdk.create_resource("via.render.MeshMaterialResource", resource_path)
    if not resource then error("create_resource failed: " .. resource_path) end
    resource = resource:add_ref()
    local holder = resource:create_holder("via.render.MeshMaterialResourceHolder")
    if not holder then error("create_holder failed: " .. resource_path) end
    return holder:add_ref(), resource
end

function Files.new(deps)
    local self = {}
    local version = deps.version
    local game = Mdf2.GAME_NAMES[version] or tostring(version)
    local load_holder = deps.load_holder or default_holder
    local log = deps.log or function() end
    local job, last, keep, counter = nil, nil, {}, 0

    local function bridge()
        local b = deps.bridge()
        return type(b) == "table" and b or nil
    end

    -- 原生插件是否提供文件接口：返回 true，或 false + "plugin"
    function self.available()
        local b = bridge()
        if b and b.read_game_file and b.game_file_exists and b.write_game_file and b.write_reload_copy
            and b.remove_reload_copies and b.game_session then return true end
        return false, "plugin"
    end

    -- 网格当前 mdf2 的原文件相对路径（换上重载副本后仍指回原文件）
    function self.file_of(mesh)
        local path = try(function()
            local holder = mesh:call("get_Material")
            return holder and holder:call("get_ResourcePath")
        end)
        return Mdf2.original_rel(Mdf2.file_path(path, version))
    end

    -- 网格的 mdf2 能否读写：{ path, status }，status 为 "ok" / "packed"（不是松散文件）/ "plugin"（原生插件太旧）/ "none"（没有材质路径）
    function self.status(mesh)
        local rel = self.file_of(mesh)
        if not rel then return { status = "none" } end
        if not self.available() then return { path = rel, status = "plugin" } end
        local exists = try(bridge().game_file_exists, rel)
        return { path = rel, status = exists and "ok" or "packed" }
    end

    local function read(rel)
        if not self.available() then return nil, "native plugin too old" end
        local data, err = bridge().read_game_file(rel)
        if not data then return nil, rel .. ": " .. tostring(err) end
        return data
    end

    local function material_index(mesh, material)
        for j = 0, (try(mesh.call, mesh, "get_MaterialNum") or 0) - 1 do
            if try(mesh.call, mesh, "getMaterialName", j) == material then return j end
        end
        return nil
    end

    -- 导出一个材质。返回 { path = data 下的相对路径, exact = 是否来自 mdf2, reason = 退回运行时数据的原因 }，失败时报错
    function self.export(mesh, material, name)
        if not Mdf2.valid_name(name) then error("invalid preset name") end
        local j = material_index(mesh, material)
        if not j then error("material not found: " .. tostring(material)) end
        local vars = Writer.variables(mesh, j)
        local live = function(param)
            local var = vars[param]
            return var and Writer.read(mesh, j, var) or nil
        end
        local ok, preset = pcall(function()
            local rel = self.file_of(mesh)
            if not rel then error("no mdf2 resource path") end
            local data, err = read(rel)
            if not data then error(err) end
            local mat = Mdf2.find(Mdf2.parse(data, version), material)
            if not mat then error(rel .. ": material " .. tostring(material) .. " not in file") end
            return Mdf2.preset_from_mdf(version, mat, live)
        end)
        local reason
        if not ok then
            reason = tostring(preset):gsub("^.-%.lua:%d+: ", "")
            local list = {}
            for param, var in pairs(vars) do list[#list + 1] = { name = param, var = var } end
            table.sort(list, function(a, b) return a.var.index < b.var.index end)
            local props = {}
            for _, e in ipairs(list) do
                local v = Writer.read(mesh, j, e.var)
                local is4 = e.var.type ~= Writer.FLOAT
                props[#props + 1] = { name = e.name, count = is4 and 4 or 1, values = is4 and (v or {}) or { v or 0 } }
            end
            local textures = {}
            for t = 0, (try(mesh.call, mesh, "getMaterialTextureNum", j) or 0) - 1 do
                local tname = try(mesh.call, mesh, "getMaterialTextureName", j, t)
                local holder = try(mesh.call, mesh, "getMaterialTexture", j, t)
                local path = holder and try(holder.call, holder, "get_ResourcePath") or ""
                if type(tname) == "string" then
                    textures[#textures + 1] = { type = tname, path = (tostring(path):gsub("\\", "/")) }
                end
            end
            preset = Mdf2.preset_from_runtime(version, material, props, textures)
        end
        local path = "ArmorVariantManager/mdf2_presets/" .. game .. "/" .. name .. ".json"
        if not deps.json.dump(path, preset) then error("cannot write " .. path) end
        return { path = path, exact = reason == nil, reason = reason }
    end

    -- 清单：{ session = 进程标识, files = { 原文件相对路径... } }
    local function manifest()
        local value = try(deps.json.load, MANIFEST)
        if type(value) ~= "table" then value = {} end
        if type(value.files) ~= "table" then value.files = {} end
        return value
    end

    -- 启动时调用一次：上一次启动留下的重载副本全部删除；脚本重置（同一进程）时不动
    function self.cleanup()
        if not self.available() then return 0 end
        local session = try(bridge().game_session)
        if type(session) ~= "string" then return 0 end
        local list = manifest()
        if list.session == session then return 0 end
        local removed = 0
        for _, rel in ipairs(list.files) do
            if type(rel) == "string" then removed = removed + (try(bridge().remove_reload_copies, rel) or 0) end
        end
        deps.json.dump(MANIFEST, { session = session, files = {} })
        if removed > 0 then log("removed " .. removed .. " mdf2 reload copies from the previous launch") end
        return removed
    end

    local function remember(rel)
        local list = manifest()
        list.session = try(bridge().game_session)
        for _, existing in ipairs(list.files) do
            if existing == rel then return deps.json.dump(MANIFEST, list) end
        end
        list.files[#list.files + 1] = rel
        return deps.json.dump(MANIFEST, list)
    end

    function self.busy() return job ~= nil end
    -- 最近一次写入的结果：{ path, values, ok, error }，写入进行中为 nil
    function self.result() return last end

    -- 开始写入。opts：
    --   mesh          用来定位 mdf2 的网格
    --   overrides     { [材质名] = { [参数] = 值 } }（预设 palette 字段里的一个部位）
    --   meshes()      当前可能使用这个 mdf2 的所有网格（换上时逐个检查路径）
    --   swapped(meshes, written)  换上的同一帧调用；written = { [材质名] = { [参数] = true } }，即写进文件的参数
    -- 返回 { path, values }；不能开始时报错（文字直接给界面看）
    function self.start(opts)
        if job then error("busy") end
        local status = self.status(opts.mesh)
        if status.status ~= "ok" then error("not writable: " .. status.status) end
        local rel = status.path
        local data, err = read(rel)
        if not data then error(err) end
        local patched, count, parsed, written = Mdf2.patch(data, version, opts.overrides)
        if count == 0 then error("nothing to write") end
        if not remember(rel) then error("cannot record reload copy") end
        local ok, werr = bridge().write_game_file(rel, patched)
        if not ok then error(rel .. ": " .. tostring(werr)) end
        counter = counter + 1
        local copy = Mdf2.reload_rel(rel, os.time() % 100000 * 10 + counter % 10)
        ok, werr = bridge().write_reload_copy(copy, patched)
        if not ok then error(copy .. ": " .. tostring(werr)) end
        local holder, resource = load_holder(Mdf2.resource_path(copy))
        last = nil
        job = { rel = rel, copy = copy, holder = holder, resource = resource, written = written,
            expect = #parsed.materials, wait = RELOAD_DELAY, tries = 0, opts = opts, values = count }
        return { path = rel, values = count }
    end

    local function finish(ok, message)
        keep[#keep + 1] = { job.holder, job.resource }
        if #keep > MAX_KEPT then table.remove(keep, 1) end
        -- 本局之前的副本：已经没有网格在用的不删也无妨，下次启动统一清理
        last = { path = job.rel, values = job.values, ok = ok, error = message }
        log("mdf2 written: " .. job.rel .. " (reload copy " .. job.copy .. ")" .. (message and (": " .. message) or ""))
        job = nil
    end

    -- 每帧调用
    function self.tick()
        if not job then return end
        job.wait = job.wait - 1
        if job.wait > 0 then return end
        local swapped, ready = {}, true
        for _, mesh in ipairs(job.opts.meshes() or {}) do
            if self.file_of(mesh) == job.rel then
                if pcall(mesh.call, mesh, "set_Material", job.holder) then
                    swapped[#swapped + 1] = mesh
                    if try(mesh.call, mesh, "get_MaterialNum") ~= job.expect then ready = false end
                end
            end
        end
        job.tries = job.tries + 1
        if not ready and job.tries < MAX_TRIES then
            job.wait = RELOAD_DELAY
            return
        end
        local ok, err = pcall(job.opts.swapped, swapped, job.written)
        if not ok then finish(false, tostring(err)); return end
        if ready then finish(true) else finish(false, "material count mismatch after reload") end
    end

    -- 切场景、脚本重置时放弃进行中的替换（文件已经写好，下次启动生效）
    function self.reset()
        if job then finish(false, "interrupted") end
    end

    return self
end

return Files
