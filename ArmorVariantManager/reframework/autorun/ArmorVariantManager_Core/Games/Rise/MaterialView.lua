local SceneObject = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local MaterialView = {}

-- 原生面板保持直接组件查询；崛起读写经过渐隐意图桥接。
function MaterialView.new()
    local type_mesh
    local access = {
        valid = SceneObject.is_alive, call = SceneObject.call,
        weapon_mesh_locked = true, bulk_lock = false,
    }
    function access.mesh(object)
        if not type_mesh then type_mesh = sdk.find_type_definition("via.render.Mesh") end
        if not type_mesh then return nil, "loading" end
        return access.call(object, "getComponent(System.Type)", type_mesh:get_runtime_type())
    end
    return access
end

return MaterialView
