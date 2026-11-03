local MaterialView = {}

-- 荒野原生面板直接查询组件，批量显示操作遵守全局隐藏。
function MaterialView.new()
    local type_mesh
    local access = {
        valid = function(object) return sdk.is_managed_object(object) end,
        call = function(object, method, ...) return object:call(method, ...) end,
        weapon_mesh_locked = false, bulk_lock = true,
    }
    function access.mesh(object)
        if not type_mesh then type_mesh = sdk.find_type_definition("via.render.Mesh") end
        if not type_mesh then return nil, "loading" end
        return access.call(object, "getComponent(System.Type)", type_mesh:get_runtime_type())
    end
    return access
end

return MaterialView
