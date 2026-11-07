-- HP 滑条 (RE4) —— 测试随血量变化的效果用(随血量溶解、随血量变色)。独立脚本,和差分管理器没有依赖,删掉不影响它。
-- 用时拷到游戏的 reframework/autorun/。
--
-- 和 HPDebug.lua 的分工:HPDebug 刻意不做滑条(扫血量等级阈值时,连续写血会冲掉要看的跳变);
-- 这个专门做滑条,拖动时连续写血,看渐变效果。最低限制在 1 点,拖到底也不会死。
-- 只用局部变量(所有 autorun 脚本共享一个 Lua 状态);tree 栈出错也收平。

local percent = nil      -- 滑条上的百分比;nil = 还没从游戏读过
local last_written = nil -- 上次写入的 HP,用来判断游戏自己改了血(回血、挨打)时跟着刷新滑条
local lock = false       -- 锁定:每帧把血量按住在滑条的值(避免回血 / 挨打把它带走)

local function hitpoint()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local ctx = cm and cm:call("getPlayerContextRef")
    local hp = ctx and ctx:call("get_HitPoint")
    if hp and sdk.is_managed_object(hp) then return hp end
    return nil
end

local function read(hp)
    local ok_c, cur = pcall(function() return hp:call("get_CurrentHitPoint") end)
    local ok_m, max = pcall(function() return hp:call("get_DefaultHitPoint") end)
    if ok_c and ok_m and type(cur) == "number" and type(max) == "number" and max > 0 then return cur, max end
    return nil
end

local function write(hp, max, p)
    local v = math.max(1, math.min(max, math.floor(max * p / 100 + 0.5)))
    pcall(function() hp:call("set_CurrentHitPoint", v) end)
    last_written = v
end

re.on_frame(function()
    if not lock or not percent then return end
    local ok, hp = pcall(hitpoint)
    if not ok or not hp then return end
    local cur, max = read(hp)
    if cur and last_written and cur ~= last_written then write(hp, max, percent) end
end)

re.on_draw_ui(function()
    local opened = false
    local ok_draw, err = pcall(function()
        opened = imgui.tree_node("HP 滑条 (RE4)")
        if not opened then return end
        local hp = hitpoint()
        if not hp then imgui.text("未找到当前控制角色"); return end
        local cur, max = read(hp)
        if not cur then imgui.text("读不到 HP"); return end
        -- 游戏自己改了血(回血、挨打):滑条跟着显示实际值
        if percent == nil or (last_written ~= cur and not lock) then
            percent = math.floor(cur / max * 100 + 0.5)
            last_written = cur
        end
        imgui.text(string.format("当前 HP: %d / %d  (%.1f%%)", cur, max, cur / max * 100))
        local changed, v = imgui.slider_int("血量 %###avm_hp_slider", percent, 1, 100)
        if changed then
            percent = v
            write(hp, max, v)
        end
        for _, p in ipairs({ 100, 75, 50, 25, 10, 1 }) do
            if imgui.button(p .. "%###avm_hp_btn" .. p) then percent = p; write(hp, max, p) end
            imgui.same_line()
        end
        imgui.new_line()
        local ch, want = imgui.checkbox("锁定在滑条的值(回血 / 挨打后自动拉回)###avm_hp_lock", lock)
        if ch then lock = want end
    end)
    if opened then pcall(imgui.tree_pop) end
    if not ok_draw then pcall(imgui.text, "HP 滑条出错: " .. tostring(err)) end
end)
