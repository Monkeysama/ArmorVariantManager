-- RE4 整套造型快捷键:Alt + 数字的判断(什么时候触发、什么时候屏蔽数字键)、绑定的清洗与增删改。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
local Hotkeys = require("ArmorVariantManager_Core.Games.RE4.Hotkeys")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")

-- ============================================================ 判断逻辑
do
    local keys, fired, bound = {}, {}, {[1] = true, [2] = true}
    local h = Hotkeys.new({
        key_down = function(vk) return keys[vk] == true end,
        alt_down = function() return keys[Hotkeys.ALT_VK] == true end,
        bound = function() return bound end,
        fire = function(d) fired[#fired + 1] = d end,
    })
    local function press(...) for _, k in ipairs({...}) do keys[k] = true end end
    local function release(...) for _, k in ipairs({...}) do keys[k] = nil end end
    local ALT, K1, K2, K3 = Hotkeys.ALT_VK, Hotkeys.vk(1), Hotkeys.vk(2), Hotkeys.vk(3)
    assert(Hotkeys.vk(0) == 48 and K1 == 49, "VK / KeyboardKey value of digits")

    -- 单按数字:不触发、不屏蔽
    press(K1); assert(not h.should_block(1)); h.tick(); assert(#fired == 0 and not h.should_block(1))
    release(K1); h.tick()

    -- 先 Alt 后数字:按下那一帧(tick 之前游戏就会问)就屏蔽,tick 时触发一次,按住期间一直屏蔽
    press(ALT); h.tick()
    press(K1); assert(h.should_block(1), "first frame blocked before tick")
    h.tick(); S.equal(fired, {1}); assert(h.should_block(1))
    h.tick(); S.equal(fired, {1}, "held key fires once")
    -- 中途先松 Alt:数字还按着,继续屏蔽到松开
    release(ALT); h.tick(); assert(h.should_block(1), "still blocked after Alt is released")
    release(K1); h.tick(); assert(not h.should_block(1))

    -- 先按数字再按 Alt:照常换武器
    press(K2); h.tick(); press(ALT); h.tick()
    assert(#fired == 1 and not h.should_block(2), "digit before Alt = weapon switch")
    release(K2); h.tick()
    -- Alt 按着时再按一次 2:触发
    press(K2); h.tick(); S.equal(fired, {1, 2})
    release(K2, ALT); h.tick()

    -- 没绑的数字按住 Alt 也照常交给游戏
    press(ALT); h.tick(); press(K3)
    assert(not h.should_block(3)); h.tick(); S.equal(fired, {1, 2}); assert(not h.should_block(3))
    release(K3, ALT); h.tick()

    -- 一个都没绑:什么都不做
    bound = nil
    press(ALT); h.tick(); press(K1); assert(not h.should_block(1)); h.tick(); S.equal(fired, {1, 2})
end

-- ============================================================ 绑定:清洗与增删改
local function snap(slot, mats) return {[slot] = {materials = mats}} end
do
    local cfg = M3.normalize({version = 3, base = {
        presets = {A = snap("body", {a = true}), B = snap("body", {a = false}), C = snap("body", {a = true})},
        order = {"A", "B", "C"}, hotkeys = {A = 1, B = 1, C = 12, Gone = 3}}})
    S.equal(cfg.base.hotkeys, {A = 1}, "duplicate digit: the earlier preset keeps it; out of range / missing dropped")
    assert(M3.normalize({version = 3}).base.hotkeys == nil)

    assert(OpsV3.set_base_hotkey(cfg, "B", 2))
    assert(not OpsV3.set_base_hotkey(cfg, "B", 2), "no change")
    assert(OpsV3.set_base_hotkey(cfg, "C", 1))
    S.equal(cfg.base.hotkeys, {B = 2, C = 1}, "taking a digit moves it")
    assert(not OpsV3.set_base_hotkey(cfg, "C", 10) and not OpsV3.set_base_hotkey(cfg, "Nope", 3))
    assert(OpsV3.set_base_hotkey(cfg, "C", 0) and cfg.base.hotkeys.C == 0, "0 is a digit")

    local _, _, dup = Ops.duplicate_preset(cfg.base, "C")
    assert(cfg.base.hotkeys[dup] == nil, "a copy does not take the digit")
    assert(OpsV3.rename_base(cfg, "C", "Main") and cfg.base.hotkeys.Main == 0 and cfg.base.hotkeys.C == nil)
    assert(OpsV3.delete_base(cfg, "Main") and cfg.base.hotkeys.Main == nil)
    assert(OpsV3.set_base_hotkey(cfg, "B", nil))
    assert(cfg.base.hotkeys == nil, "last binding removed -> nil")
end

print("PASS: RE4 hotkeys: Alt + digit fires once and blocks the digit until released, digit-before-Alt and unbound digits pass through, bindings clean / move / follow rename / drop on delete")
