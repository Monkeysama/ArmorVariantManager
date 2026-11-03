local SceneObject = {}

-- 每个运行实例独立记录失效对象；场景清理时解除冷却。
function SceneObject.new()
    local get_game_object_method = sdk.find_type_definition("via.Component"):get_method("get_GameObject")
    -- 已确认销毁的托管包装对象 -> 下次允许再探测的时间。
    -- 目的：REFramework 的 invoke 层在抛异常前一定会写日志，日志无法被 pcall 抑制，
    -- 因此唯一有效的降噪手段是"不重复探测"。确认死掉的对象在 DEAD_OBJECT_RETRY_INTERVAL
    -- 内直接走 nil 分支，把每帧一次的报错降为每个对象每 1 秒最多一次。
    local DEAD_OBJECT_RETRY_INTERVAL = 1.0
    local dead_object_until = {}

    local function mark_dead_object(component)
        if not component then return end
        local ok, key = pcall(tostring, component)
        if ok and key then dead_object_until[key] = os.clock() + DEAD_OBJECT_RETRY_INTERVAL end
    end

    local function is_marked_dead(component)
        if not component then return false end
        local ok, key = pcall(tostring, component)
        if not ok or not key then return false end
        local until_time = dead_object_until[key]
        if not until_time then return false end
        if os.clock() >= until_time then
            dead_object_until[key] = nil
            return false
        end
        return true
    end

    local function clear_dead_object_marks()
        dead_object_until = {}
    end

    -- 性能与日志优化：安全获取组件的 GameObject
    -- 场景切换时游戏会销毁旧场景的原生对象，但 Lua 侧仍持有托管包装对象，
    -- is_managed_object 对这类"已死包装"依然返回 true，直接调用 get_GameObject 会抛出
    -- System.InvalidOperationException；REFramework 会在 invoke 包装层内部先写日志，
    -- 因此 pcall 只能防崩溃、挡不住刷屏。统一改用本函数：
    --   1. 已标记销毁的对象直接返回 nil，不再触发 invoke 与日志；
    --   2. 首次判定失败即登记该对象，1 秒内不重复探测。
    -- origin 参数保留用于调用点自描述（当前不参与逻辑）。
    local function safe_get_game_object(component, origin)
        if not component then return nil end
        if is_marked_dead(component) then return nil end
        local ok, obj
        if get_game_object_method then
            ok, obj = pcall(get_game_object_method.call, get_game_object_method, component)
        else
            ok, obj = pcall(function() return component:call("get_GameObject") end)
        end
        if not ok or not obj then
            mark_dead_object(component)
            return nil
        end
        if not sdk.is_managed_object(obj) then
            mark_dead_object(component)
            return nil
        end
        return obj
    end

    return { game_object = safe_get_game_object, clear = clear_dead_object_marks }
end

return SceneObject
