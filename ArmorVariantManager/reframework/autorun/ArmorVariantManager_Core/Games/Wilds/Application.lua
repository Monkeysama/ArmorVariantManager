local Processor = require("ArmorVariantManager_Core.Runtime.Processor")
local Application = {}

-- 连接配置会话、外观与运行服务，界面只负责选择和显示。
function Application.new(runtime, appearance, session, rules, is_weapon_id)
    local app = {runtime=runtime, appearance=appearance, load=session.load}
    local equipment, materials = runtime.equipment, runtime.materials
    app.is_weapon_id, app.weapon_id = is_weapon_id, equipment.weapon_id
    function app.player_handle() return nil end

    local type_mesh
    function app.capture(config, group_name, id, weapon, contains, selected)
        local character = runtime.actors.local_player()
        if not character then return nil end
        type_mesh = type_mesh or sdk.find_type_definition("via.render.Mesh")
        if not type_mesh then return nil end
        local data = runtime.capture(character, config, group_name, appearance.overrides[id], is_weapon_id(id), contains)
        if not is_weapon_id(id) then
            local group = group_name == "" and config or config.groups[group_name]
            data.ground_clipping_fix = appearance.height.get_editor(config, id, group_name,
                selected[group_name] or group and group.default_preset)
        end
        return data
    end
    app.process = Processor.new({
        identify = function(character, slot)
            if slot == "armor" then return equipment.body_id(character) end
            return equipment.weapon_id(character)
        end,
        load = app.load,
        initialize = function(id)
            if not appearance.overrides[id] then appearance.defaults(id) end
        end,
        resolve = appearance.resolve,
        apply = function(character, slot, objects, result)
            if slot == "armor" then materials.armor(character, result)
            else materials.weapon(character, objects, result) end
        end,
    })

    -- 即时切换覆盖同装备角色，并补入扫描尚未发现的本地菜单演员。
    function app.refresh(id)
        local characters = runtime.actors.all()
        local primary = runtime.actors.local_player()
        if primary and sdk.is_managed_object(primary) then
            local found = false
            for _, character in ipairs(characters) do
                if character == primary then found = true; break end
            end
            if not found then characters[#characters + 1] = primary end
        end
        local weapon = is_weapon_id(id)
        for _, character in ipairs(characters) do
            local current, objects
            if weapon then current, objects = equipment.weapon_id(character)
            else current = equipment.body_id(character) end
            if current and current == id then
                local result = appearance.resolve(id, app.load(id), character, weapon and "weapon" or "armor")
                if weapon then materials.weapon(character, objects, result)
                else materials.armor(character, result) end
            end
        end
    end

    function app.select(id, config, group, preset)
        if not id or not appearance.select(id, config, group, preset) then return false end
        app.refresh(id)
        return true
    end

    -- 保存失败保留手动外观；仅持久化时不重建默认值或清除规则状态。
    function app.save(id, config, preserve)
        if not id then return end
        if not preserve then rules.refresh_config_rules(config) end
        local saved, reason = session.save(id, config)
        if not saved then return false, reason end
        if preserve then return true end
        appearance.end_material_preview(id)
        appearance.overrides[id], appearance.groups[id] = nil, nil
        if rules.clear_last_state_cache then rules.clear_last_state_cache() end
        return true
    end

    function app.restore(id)
        local restored, reason = session.restore(id)
        if not restored then return false, reason end
        appearance.overrides[id], appearance.groups[id] = nil, nil
        local config = app.load(id)
        if config then appearance.defaults(id, config) end
        if rules.clear_last_state_cache then rules.clear_last_state_cache() end
        return true
    end

    -- mdf2 文件服务（格式版本 45）：原生插件和 json 在调用时取，离线测试可经 runtime.material_files 替换。
    -- 启动时删除上一次启动留下的重载副本。
    app.files = runtime.material_files or require("ArmorVariantManager_Core.Runtime.MaterialFiles").new({
        version=45,
        bridge=function() return rawget(_G, "avm_portrait") end,
        json={load=function(path) return json.load_file(path) end, dump=function(path, value) return json.dump_file(path, value) end},
        log=function(message) if log and log.info then log.info("[AVM] " .. message) end end,
    })
    pcall(app.files.cleanup)

    -- 调色在材质开关写入之后应用：按处理器本帧处理过的槽位，读取同一份角色上下文。
    app.palette = require("ArmorVariantManager_Core.Games.Wilds.Palette").new({meshes=runtime.meshes, files=app.files})
    local function slot_context(character, slot)
        local id, objects
        if slot == "armor" then id = equipment.body_id(character)
        else id, objects = equipment.weapon_id(character) end
        local config = id and app.load(id)
        local context = config and appearance.state:peek(tostring(character), slot, id, config)
        return context, config, objects
    end
    local process = app.process
    app.process = function(character)
        local seen = process(character)
        for slot in pairs(seen) do
            local context, config, objects = slot_context(character, slot)
            if context then app.palette.apply(character, slot, objects, context, config) end
        end
        return seen
    end

    -- 界面读取本地猎人当前装备某个部位、某个材质的参数。
    function app.material_params(part, material, weapon)
        local character = runtime.actors.local_player()
        if not character then return {} end
        local slot = weapon and "weapon" or "armor"
        local context, _, objects = slot_context(character, slot)
        local part_data = context and context.overrides and context.overrides[part]
        return app.palette.inspect(character, slot, objects, part, material, part_data)
    end

    -- 本地猎人某个部位里含有该材质的网格；没有时返回 nil 与原因。
    local function local_mesh(part, material, weapon)
        local character = runtime.actors.local_player()
        if not character then return nil, "no player" end
        local slot = weapon and "weapon" or "armor"
        local context, _, objects = slot_context(character, slot)
        local part_data = context and context.overrides and context.overrides[part]
        local mesh = app.palette.mesh_with(character, slot, objects, part, material, part_data)
        if not mesh then return nil, "material not found" end
        return mesh
    end

    -- 材质所在 mdf2 能否读写：{ path, status }，见 Runtime/MaterialFiles.lua 的 status。
    function app.material_file(part, material, weapon)
        local mesh, reason = local_mesh(part, material, weapon)
        if not mesh then return { status = "none", reason = reason } end
        return app.files.status(mesh)
    end

    -- 把本地猎人某个材质导出成 RE Mesh Editor 材质预设，参数取当前值。
    function app.export_material(part, material, name, weapon)
        local mesh, reason = local_mesh(part, material, weapon)
        if not mesh then return nil, reason end
        local ok, result = pcall(app.files.export, mesh, material, name)
        if not ok then return nil, (tostring(result):gsub("^.-%.lua:%d+: ", "")) end
        return result
    end

    -- 把一个部位的覆盖值写进该部位网格所用的 mdf2，并在本局换上。overrides 只含这个部位。
    -- 同一部位可能有多个网格、多个 mdf2：只写含有 material 的那个网格的文件（material 省略时取第一个可写的）。
    -- 换上后清掉写入器里这些网格的状态，并调用 done(written)，由调用方清掉已写进文件的覆盖值；最后刷新外观。
    function app.write_material_file(part, overrides, material, weapon, done)
        local character = runtime.actors.local_player()
        if not character then return nil, "no player" end
        local slot = weapon and "weapon" or "armor"
        local context, _, objects = slot_context(character, slot)
        local part_data = context and context.overrides and context.overrides[part]
        local target
        if material then
            target = app.palette.mesh_with(character, slot, objects, part, material, part_data)
        else
            for _, mesh in ipairs(app.palette.meshes_of(character, slot, objects, part, part_data)) do
                if app.files.status(mesh).status == "ok" then target = mesh; break end
            end
        end
        if not target then return nil, "material not found" end
        local id = slot == "armor" and equipment.body_id(character) or equipment.weapon_id(character)
        local ok, result = pcall(app.files.start, {
            mesh=target, overrides=overrides,
            meshes=function()
                local list = {}
                for _, actor in ipairs(runtime.actors.all()) do
                    for _, mesh in ipairs(runtime.meshes.all(actor)) do list[#list + 1] = mesh end
                    local _, weapon_objects = equipment.weapon_id(actor)
                    for _, object in ipairs(weapon_objects or {}) do
                        local mesh = runtime.meshes.first(object)
                        if mesh then list[#list + 1] = mesh end
                    end
                end
                return list
            end,
            swapped=function(meshes, written)
                for _, mesh in ipairs(meshes) do app.palette.writer.forget(mesh) end
                if done then done(written) end
                if id then app.refresh(id) end
            end,
        })
        if not ok then return nil, (tostring(result):gsub("^.-%.lua:%d+: ", "")) end
        return result
    end

    return app
end

return Application
