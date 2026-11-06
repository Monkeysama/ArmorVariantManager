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

-- ============================================================ 绑定:清洗、迁移、互斥、轮换、改名删除
local function snap(slot, mats) return {[slot] = {materials = mats}} end
local function cfg_with(hotkeys, legacy)
    return M3.normalize({version = 3,
        base = {presets = {A = snap("body", {a = true}), B = snap("body", {a = false}), C = {}}, order = {"A", "B", "C"}, active = "A",
            hotkeys = legacy},
        groups = {{name = "Face", scope = {}, options = {Clean = {}, Hurt = {}}, order = {"Clean", "Hurt"}, active = ""}},
        palettes = {Warm = {}, Night = {}}, palette_order = {"Warm", "Night"},
        hotkeys = hotkeys})
end
do
    -- 迁移旧的 base.hotkeys;非法 / 指不到的去掉;同一设定只留数字小的;轮换压过同结构的单项
    local cfg = cfg_with({
        ["1"] = {kind = "base"},
        ["2"] = {kind = "base", option = "B"},            -- 结构有轮换 → 单项作废
        ["3"] = {kind = "group", group = "Face", option = "Hurt"},
        ["4"] = {kind = "group", group = "Face", option = "Hurt"},   -- 重复 → 只留 3
        ["5"] = {kind = "palette", scheme = "Nope"},       -- 指不到
        ["6"] = {kind = "group", group = "Gone"},
        ["7"] = {kind = "palette", skip = {"", "Bad", "Night"}},
        ["x"] = {kind = "base"},
    }, {C = 8, A = 9})
    assert(cfg.base.hotkeys == nil, "legacy field removed")
    S.equal(cfg.hotkeys["1"], {kind = "base"})
    assert(cfg.hotkeys["2"] == nil and cfg.hotkeys["4"] == nil and cfg.hotkeys["5"] == nil and cfg.hotkeys["6"] == nil)
    S.equal(cfg.hotkeys["3"], {kind = "group", group = "Face", option = "Hurt"})
    S.equal(cfg.hotkeys["7"], {kind = "palette", skip = {"", "Night"}}, "skip keeps existing items only")
    assert(cfg.hotkeys["8"] == nil and cfg.hotkeys["9"] == nil, "migrated base items lose to the base cycle key")
    local plain = cfg_with(nil, {C = 8, A = 1})
    S.equal(plain.hotkeys, {["1"] = {kind = "base", option = "A"}, ["8"] = {kind = "base", option = "C"}}, "legacy migration")
end
do
    local cfg = cfg_with(nil)
    -- 单项
    assert(OpsV3.set_hotkey(cfg, 1, {kind = "base", option = "B"}))
    assert(not OpsV3.set_hotkey(cfg, 1, {kind = "base", option = "B"}), "no change")
    assert(OpsV3.set_hotkey(cfg, 2, {kind = "base", option = "B"}) and cfg.hotkeys["1"] == nil, "a setting moves to the new key")
    assert(not OpsV3.set_hotkey(cfg, 3, {kind = "base", option = ""}), "base has no (none)")
    assert(OpsV3.set_hotkey(cfg, 3, {kind = "group", group = "Face", option = ""}), "group (none) is an item")
    assert(OpsV3.set_hotkey(cfg, 4, {kind = "palette", scheme = "Night"}))
    assert(not OpsV3.set_hotkey(cfg, 10, {kind = "base"}) and not OpsV3.set_hotkey(cfg, 5, {kind = "group", group = "Gone"}))
    -- 同一个键换成别的设定:原来的设定被顶掉
    assert(OpsV3.set_hotkey(cfg, 4, {kind = "palette", scheme = "Warm"}))
    S.equal(cfg.hotkeys["4"], {kind = "palette", scheme = "Warm"})
    -- 轮换:清掉同结构的单项;之后单项不能绑
    assert(OpsV3.set_hotkey(cfg, 5, {kind = "base"}))
    assert(cfg.hotkeys["2"] == nil, "cycle key clears the items of its structure")
    assert(not OpsV3.set_hotkey(cfg, 6, {kind = "base", option = "C"}), "no item keys while the structure cycles")
    -- 轮换顺序与跳过
    assert(M3.hotkey_next(cfg, cfg.hotkeys["5"]) == "B", "A -> B")
    cfg.base.active = "C"; assert(M3.hotkey_next(cfg, cfg.hotkeys["5"]) == "A", "wraps")
    assert(OpsV3.set_hotkey_skip(cfg, {kind = "base"}, "A", false))
    assert(not OpsV3.set_hotkey_skip(cfg, {kind = "base"}, "A", false), "already skipped")
    assert(M3.hotkey_next(cfg, cfg.hotkeys["5"]) == "B", "skips A")
    cfg.base.active = ""; assert(M3.hotkey_next(cfg, cfg.hotkeys["5"]) == "B", "not in the list -> first")
    -- 轮换键换数字:跳过的项保留
    assert(OpsV3.set_hotkey(cfg, 6, {kind = "base"}) and cfg.hotkeys["5"] == nil)
    S.equal(cfg.hotkeys["6"].skip, {"A"})
    assert(OpsV3.set_hotkey_skip(cfg, {kind = "base"}, "A", true) and cfg.hotkeys["6"].skip == nil)
    -- 状态组轮换含「（无）」,调色轮换含「初始」
    assert(OpsV3.set_hotkey(cfg, 7, {kind = "group", group = "Face"}) and cfg.hotkeys["3"] == nil)
    assert(M3.hotkey_next(cfg, cfg.hotkeys["7"]) == "Clean", "(none) -> Clean")
    assert(OpsV3.set_hotkey_skip(cfg, {kind = "group", group = "Face"}, "", false))
    cfg.groups[1].active = "Hurt"; assert(M3.hotkey_next(cfg, cfg.hotkeys["7"]) == "Clean", "skips (none) on wrap")
    assert(OpsV3.set_hotkey(cfg, 8, {kind = "palette"}) and cfg.hotkeys["4"] == nil)
    cfg.palette_active = "Night"; assert(M3.hotkey_next(cfg, cfg.hotkeys["8"]) == "", "Night -> original")
    for _, n in ipairs({"", "Warm", "Night"}) do OpsV3.set_hotkey_skip(cfg, {kind = "palette"}, n, false) end
    assert(M3.hotkey_next(cfg, cfg.hotkeys["8"]) == nil, "everything skipped")
    -- 改名跟着走,删除后作废
    assert(OpsV3.rename_group(cfg, "Face", "Look") and cfg.hotkeys["7"].group == "Look")
    assert(OpsV3.rename_palette(cfg, "Night", "Dark"))
    S.equal(cfg.hotkeys["8"].skip, {"", "Warm", "Dark"})
    assert(OpsV3.set_hotkey(cfg, 9, {kind = "group", group = "Look", option = "Hurt"}) == false, "group cycles")
    assert(OpsV3.set_hotkey(cfg, 7, nil) and cfg.hotkeys["7"] == nil, "clear")
    assert(OpsV3.set_hotkey(cfg, 9, {kind = "group", group = "Look", option = "Hurt"}))
    assert(OpsV3.rename_option(cfg, "Look", "Hurt", "Pain") and cfg.hotkeys["9"].option == "Pain")
    assert(OpsV3.delete_option(cfg, "Look", "Pain") and cfg.hotkeys["9"] == nil)
    assert(OpsV3.rename_base(cfg, "A", "Main"))
    S.equal(cfg.hotkeys["6"].skip or {}, {})
    assert(OpsV3.set_hotkey_skip(cfg, {kind = "base"}, "Main", false))
    assert(OpsV3.delete_base(cfg, "Main"))
    assert(cfg.hotkeys["6"].skip == nil, "deleted item leaves the skip list")
    assert(OpsV3.delete_group(cfg, "Look"))
    assert(OpsV3.delete_palette(cfg, "Dark") and cfg.hotkeys["8"].skip[3] == nil)
end

print("PASS: RE4 hotkeys: Alt + digit fires once and blocks the digit until released, digit-before-Alt and unbound digits pass through; bindings: legacy migration, one key per setting, cycle vs item exclusivity, cycle order / wrap / skip ((none) and original included), follow renames, drop on delete")
