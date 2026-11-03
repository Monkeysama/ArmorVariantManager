local SceneObject = require("ArmorVariantManager_Core.Games.Wilds.SceneObject")
local Actors = require("ArmorVariantManager_Core.Games.Wilds.Actors")
local Equipment = require("ArmorVariantManager_Core.Games.Wilds.Equipment")
local Meshes = require("ArmorVariantManager_Core.Games.Wilds.Meshes")
local Materials = require("ArmorVariantManager_Core.Games.Wilds.Materials")
local Capture = require("ArmorVariantManager_Core.Games.Wilds.Capture")
local Runtime = {}

-- 运行会话持有引擎服务；场景清理由角色目录通知应用层丢弃计算结果。
function Runtime.new(config, callbacks)
    local runtime = { scene_object = SceneObject.new() }
    local game_object = runtime.scene_object.game_object
    runtime.equipment = Equipment.new(game_object, config, Actors.preview_names)
    runtime.meshes = Meshes.new(game_object, function(name) return sdk.find_type_definition(name) end)
    runtime.materials = Materials.new(runtime.meshes, game_object)
    runtime.capture = Capture.new(runtime.meshes, runtime.equipment)
    runtime.actors = Actors.new(config, runtime.scene_object, runtime.equipment, runtime.meshes, callbacks.reset)
    runtime.guard = runtime.actors.guard

    function runtime.install_hooks() runtime.guard:install_hooks() end

    -- 先检查场景和扫描，再更新界面选择，最后将各角色结果应用到对应对象。
    function runtime.tick(frame)
        local suspended = runtime.guard:update()
        frame.suspended(suspended)
        if suspended then return end
        if not runtime.actors.tick() then frame.suspended(true); return end
        frame.update()

        local characters = runtime.actors.all()
        local primary = runtime.actors.local_player()
        -- 模型重建或菜单场景可能尚未被扫描覆盖，本地玩家仍需每帧应用。
        if primary and sdk.is_managed_object(primary) then
            local found = false
            for _, character in ipairs(characters) do
                if character == primary then found = true; break end
            end
            if not found then characters[#characters + 1] = primary end
        end
        local seen = {}
        for _, character in ipairs(characters) do
            if character and sdk.is_managed_object(character) then
                seen[tostring(character)] = frame.process(character)
            end
        end
        frame.retain(seen)
    end

    return runtime
end

return Runtime
