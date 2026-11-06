-- 调色页的「替换 mdf」:把调色覆盖值写进 mod 的 mdf2(原地改参数字节),当场换上,并清空涉及的调色配置。
--
-- 流程(2026-11-05 在游戏里实测过运行时替换,见 tests/re4_mdf2.lua 的说明):
--   1. 读原文件(natives/STM/<路径>.32,原生插件读),把选中的调色方案里这个槽位、这个 mdf2 的材质的覆盖值写进去
--   2. 覆盖原文件(原生插件第一次会先留 <文件>.avm_bak);再写一份重载副本 <名字>_avmr<n>.mdf2.32 ——
--      同一路径的资源引擎会缓存,文件改了也不会重新读,只有新路径才从磁盘读
--   3. create_resource(副本) 后等 RELOAD_DELAY 帧再 set_Material:资源是异步加载的,立刻换上会是黄白格子(缺材质)
--   4. 换上的同一帧:清掉这些网格的调色状态(否则调色模块会把记下的原值写回去)、清空配置里这个 mdf2 的材质的覆盖值、存盘、重新应用
--   5. 核对材质数;没对上就再等一轮重试。最后删掉旧的重载副本
-- 下次进游戏时引擎直接读改好的原文件,副本只在本次运行中用。
local Mdf2 = require("ArmorVariantManager_Core.Games.RE4.Mdf2")

local Replace = {}

local RELOAD_DELAY = 10      -- 帧
local MAX_TRIES = 3

local job = nil              -- 正在进行的替换
local keep = {}              -- 换上的资源 / holder 留住引用
local counter = 0

local function bridge()
    local b = rawget(_G, "avm_portrait")
    return type(b) == "table" and b or nil
end

local function material_rel(mesh)
    local ok, rel = pcall(function()
        local holder = mesh:call("get_Material")
        return Mdf2.file_path(holder and holder:call("get_ResourcePath"))
    end)
    return ok and rel and Mdf2.original_rel(rel) or nil
end

-- 这个网格的 mdf2 能不能替换:"ok" / "packed"(不是松散文件,原版在 pak 里)/ "plugin"(原生插件太旧)/ nil(读不到)
function Replace.check(mesh)
    local b = bridge()
    if not (b and b.game_file_exists and b.write_game_file and b.write_reload_copy) then return "plugin" end
    local rel = mesh and material_rel(mesh)
    if not rel then return nil end
    local ok, exists = pcall(b.game_file_exists, rel)
    return (ok and exists) and "ok" or "packed"
end

function Replace.busy() return job ~= nil end

-- opts:
--   mesh          要替换的网格(调色页选中材质所在槽位的网格)
--   overrides     选中方案的覆盖表[槽位]
--   meshes()      当前所有目标的所有槽位网格(找同一个 mdf2 的,一起换)
--   forget(mesh)  清掉调色模块里这个网格的状态(不还原)
--   clear(names)  清空配置里这些材质的调色覆盖值并存盘(names = { [材质名] = true })
--   reapply()     重新应用材质开关
--   log(msg)
-- 失败时报错(错误文字直接给界面看)
function Replace.start(opts)
    if job then error("busy") end
    local b = bridge()
    if Replace.check(opts.mesh) ~= "ok" then error("not replaceable") end
    local rel = material_rel(opts.mesh)
    local data, err = b.read_game_file(rel)
    if not data then error(rel .. ": " .. tostring(err)) end
    local patched, count, parsed = Mdf2.patch(data, opts.overrides)
    if count == 0 then error("nothing to write") end
    local ok, werr = b.write_game_file(rel, patched)
    if not ok then error(rel .. ": " .. tostring(werr)) end
    counter = counter + 1
    local copy = Mdf2.reload_rel(rel, os.time() % 100000 * 10 + counter % 10)
    ok, werr = b.write_reload_copy(copy, patched)
    if not ok then error(copy .. ": " .. tostring(werr)) end
    local res = sdk.create_resource("via.render.MeshMaterialResource", Mdf2.resource_path(copy))
    if not res then error("create_resource failed: " .. copy) end
    res = res:add_ref()
    local holder = res:create_holder("via.render.MeshMaterialResourceHolder"):add_ref()
    local names = {}
    for _, m in ipairs(parsed.materials) do names[m.name] = true end
    job = { rel = rel, copy = copy, res = res, holder = holder, names = names, expect = #parsed.materials,
        wait = RELOAD_DELAY, tries = 0, opts = opts }
    return { path = rel, values = count }
end

local function finish(log)
    keep[#keep + 1] = job.res
    keep[#keep + 1] = job.holder
    if #keep > 16 then table.remove(keep, 1); table.remove(keep, 1) end
    local b = bridge()
    if b and b.remove_reload_copies then pcall(b.remove_reload_copies, job.rel, job.copy) end
    if log then log("mdf2 replaced: " .. job.rel .. " (reload copy " .. job.copy .. ")") end
    job = nil
end

-- 每帧调用(Main 的 re.on_frame)
function Replace.tick()
    if not job then return end
    job.wait = job.wait - 1
    if job.wait > 0 then return end
    local o = job.opts
    local swapped, ready = {}, true
    for _, mesh in ipairs(o.meshes()) do
        if material_rel(mesh) == job.rel then
            local ok = pcall(function() mesh:call("set_Material", job.holder) end)
            if ok then
                swapped[#swapped + 1] = mesh
                local n = mesh:call("get_MaterialNum")
                if n ~= job.expect then ready = false end
            end
        end
    end
    job.tries = job.tries + 1
    if not ready and job.tries < MAX_TRIES then
        job.wait = RELOAD_DELAY   -- 还没加载完(材质数不对):再等一轮重新换
        return
    end
    -- 同一帧清状态和配置:换上的新材质里已经是写好的值,不能让调色模块再写旧值回去
    for _, mesh in ipairs(swapped) do pcall(o.forget, mesh) end
    pcall(o.clear, job.names)
    pcall(o.reapply)
    finish(o.log)
end

return Replace
