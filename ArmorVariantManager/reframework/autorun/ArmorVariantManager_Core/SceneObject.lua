-- A Lua reference keeps the managed wrapper alive, not its native scene object.
-- get_Valid is safe to query after native GameObject/Component destruction.
local SceneObject = { invalid_count = 0 }
local validity_methods = {}

function SceneObject.is_alive(obj)
    if obj == nil then return false end
    local ok, alive = pcall(function()
        if not sdk.is_managed_object(obj) then return false end
        local td = obj:get_type_definition()
        if not td then return false end
        local getter = validity_methods[td]
        if getter == nil then
            getter = td:get_method("get_Valid") or false
            validity_methods[td] = getter
        end
        -- Collections and other purely managed types have no native validity flag.
        if getter == false then return true end
        return getter:call(obj) == true
    end)
    if ok and alive == true then return true end
    SceneObject.invalid_count = SceneObject.invalid_count + 1
    return false
end

function SceneObject.call(obj, method, ...)
    if not SceneObject.is_alive(obj) then return nil end
    local ok, value = pcall(obj.call, obj, method, ...)
    if ok then return value end
    -- Only a destruction race is expected. Preserve unrelated errors for diagnosis.
    if not SceneObject.is_alive(obj) then return nil end
    error(value, 0)
end

return SceneObject
