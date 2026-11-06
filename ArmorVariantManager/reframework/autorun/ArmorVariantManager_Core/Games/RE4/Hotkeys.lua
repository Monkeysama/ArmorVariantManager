-- 整套造型的快捷键:Alt + 数字切换(手动选择),按住 Alt 时不让游戏读到这些数字键(数字键在游戏里是换武器)。
--
-- 实测(2026-11-06,reframework 探针):换武器的数字键只经过 share.hid.Device.isDown(via.hid.KeyboardKey);
-- 原生 via.hid.KeyboardDevice 那层对数字键从来不返回按下,isTrigger / isRepeat 也没人问数字键。
-- 按住 Alt 时把 isDown(数字) 改成返回 false,换武器就不会发生。via.hid.KeyboardKey 的数字键值同 VK:'1' = 49。
--
-- 规则:
--   * 先按住 Alt、再按数字(按下那一刻 Alt 在按着)= 快捷键,这个数字键一直屏蔽到松开(哪怕中途先松了 Alt,
--     否则游戏会看到它「按下」又去换武器)。
--   * 先按着数字、再按 Alt = 照常换武器,不触发、不屏蔽。
--   * 只处理绑了整套造型的数字;没绑的数字按住 Alt 也照常交给游戏。一个都没绑时完全不碰键盘。
local Hotkeys = {}

Hotkeys.ALT_VK = 0x12
function Hotkeys.vk(digit) return 0x30 + digit end   -- 数字 0~9 的 VK,也是 via.hid.KeyboardKey 的值

-- 判断逻辑(不碰游戏,测试直接用):
--   key_down(vk) / alt_down():物理按键状态
--   bound():{ [数字] = true },当前角色绑了哪些数字
--   fire(digit):触发快捷键
function Hotkeys.new(deps)
    local self = { held = {}, plain = {}, was = {} }
    -- 每帧调用一次:找出这一帧新按下的数字
    function self.tick()
        local bound = deps.bound() or {}
        local alt = deps.alt_down()
        for d = 0, 9 do
            local down = deps.key_down(Hotkeys.vk(d))
            if down and not self.was[d] then
                if alt and bound[d] and not self.plain[d] then
                    self.held[d] = true
                    deps.fire(d)
                else
                    self.plain[d] = true
                end
            elseif not down then
                self.held[d], self.plain[d] = nil, nil
            end
            self.was[d] = down
        end
    end
    -- 游戏问「这个数字键按着没有」时,要不要回答没按。hook 在 tick 之前也可能先问到(按下的第一帧),
    -- 所以这里也按「Alt 按着、绑了、不是先按的数字」判断一次
    function self.should_block(d)
        if self.held[d] then return true end
        if self.plain[d] or self.was[d] then return false end
        local bound = deps.bound() or {}
        return bound[d] == true and deps.alt_down()
    end
    return self
end

-- 挂到游戏上:share.hid.Device.isDown(via.hid.KeyboardKey) 对要屏蔽的数字返回 false。
-- 装不上(类型 / 方法变了)只记日志,快捷键本身照样能用,只是会顺带换武器
function Hotkeys.install(logic, active, warn)
    local t = sdk.find_type_definition("share.hid.Device")
    local m = t and t:get_method("isDown(via.hid.KeyboardKey)")
    if not m then
        if warn then warn("[AVM] Hotkeys: share.hid.Device.isDown(KeyboardKey) not found; number keys not blocked") end
        return false
    end
    local ok, err = pcall(function()
        sdk.hook(m, function(args)
            local storage = thread.get_hook_storage()
            storage.key = nil
            if not active() then return end
            local k = sdk.to_int64(args[3]) & 0xFFFFFFFF
            if k >= 0x30 and k <= 0x39 then storage.key = k - 0x30 end
        end, function(retval)
            local storage = thread.get_hook_storage()
            local d = storage and storage.key
            if d and (sdk.to_int64(retval) & 1) ~= 0 and logic.should_block(d) then return sdk.to_ptr(0) end
            return retval
        end)
    end)
    if not ok and warn then warn("[AVM] Hotkeys: hook failed: " .. tostring(err)) end
    return ok
end

-- 屏幕提示:切换后在左上角显示几秒(面板关着也能看到切到了哪套、是否正被条件接管)
local toast = nil   -- { lines = { 文字, ... }, until_ = 时间 }
function Hotkeys.toast(lines, seconds)
    toast = { lines = lines, until_ = os.clock() + (seconds or 2.5) }
end
function Hotkeys.draw_toast()
    if not toast then return end
    if os.clock() > toast.until_ then toast = nil; return end
    if type(imgui) ~= "table" or not imgui.get_background_draw_list then return end
    local ok, dl = pcall(imgui.get_background_draw_list)
    if not ok or not dl then return end
    local x, y, pad, line_h = 24, 24, 10, 22
    local w = 0
    for _, s in ipairs(toast.lines) do
        local okm, size = pcall(imgui.calc_text_size, s)
        if okm and size and size.x > w then w = size.x end
    end
    local h = #toast.lines * line_h
    -- ImGui 颜色是 ABGR
    pcall(dl.add_rect_filled, dl, { x - pad, y - pad }, { x + w + pad, y + h + pad - 6 }, 0xD0201814, 6.0, 0)
    for i, s in ipairs(toast.lines) do
        pcall(dl.add_text, dl, { x, y + (i - 1) * line_h }, i == 1 and 0xFFFFFFFF or 0xFFB0C8D8, s)
    end
end

return Hotkeys
