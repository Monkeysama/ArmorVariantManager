-- RE4 溶解效果提供者(EffectProviders.lua)及其在 Dissolve.lua 里的接入:
-- 注册校验、选择存盘 / 回滚、随机、按角色合并事务、同一材质只绑定一次(血量驱动不每帧重绑)、
-- 溶解结束后收尾、定位复位、没有提供者时什么都不做。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

_G.Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
local now = 0
os.clock = function() return now end
local saved_file = nil
_G.json = {
    load_file = function() return { ["test.fx"] = "square", ["gone"] = "x" } end,
    dump_file = function(_, v) saved_file = v; return true end,
}

local EffectProviders = require("ArmorVariantManager_Core.Games.RE4.EffectProviders")
local Dissolve = require("ArmorVariantManager_Core.Games.RE4.Dissolve")

local function tick(n) for _ = 1, n do now = now + 0.1; Dissolve.update() end end
local function fake(id)
    local m = { id = id, enabled = {}, values = { [0] = { x = 0, y = 0, z = 0, w = 0 }, [1] = { x = 1, y = 0, z = 0, w = 0 } } }
    local names = { [0] = "Dissolve_Rate", [1] = "Dissolve_Flag" }
    function m:call(method, j, a, b)
        if method == "getMaterialName" then return "mat" .. j
        elseif method == "get_MaterialNum" then return 2
        elseif method == "getMaterialVariableNum" then return 2
        elseif method == "getMaterialVariableName" then return names[a]
        elseif method == "getMaterialFloat4" then return self.values[a]
        elseif method == "setMaterialFloat4" then self.values[a] = b
        elseif method == "setMaterialsEnable" then self.enabled[j] = a
        end
    end
    return setmetatable(m, { __tostring = function() return "mesh:" .. id end })
end

local function provider(id, effects)
    local log = { begin = {}, bind = {}, finish = {}, reset = {}, reset_mesh = {} }
    local p = {
        api_version = 1, id = id, effects = effects,
        name = { ["zh-CN"] = "测试", ["en-US"] = "Test", bad = 3 },
        labels = { square = "方块", hex = { ["zh-CN"] = "六边形" } },
        supports = function() return true end,
        begin_transaction = function(info) log.begin[#log.begin + 1] = info; return true end,
        bind_material = function(tx, mesh, j) log.bind[#log.bind + 1] = { tx, tostring(mesh), j }; return true end,
        end_transaction = function(tx) log.finish[#log.finish + 1] = tx; return true end,
        reset = function(reason) log.reset[#log.reset + 1] = reason end,
        reset_mesh = function(mesh) log.reset_mesh[#log.reset_mesh + 1] = tostring(mesh) end,
    }
    return p, log
end

-- 没有提供者:接入点什么都不做,也不抛错
local m0 = fake("none")
Dissolve.use({ enabled = true, dur = 1, forward = true }); Dissolve.set_material(m0, 0, false, true); Dissolve.use(nil)
tick(20)
assert(#Dissolve.get_effect_providers() == 0)

-- 注册校验
local ok_bad = pcall(Dissolve.register_effect_provider, { api_version = 1, id = "x", effects = { "random" },
    supports = print, begin_transaction = print, bind_material = print, end_transaction = print, reset = print })
assert(not ok_bad, "'random' is reserved")
assert(not pcall(Dissolve.register_effect_provider, { api_version = 2, id = "x" }), "api_version checked")

local p, log = provider("test.fx", { "square", "hex", "plain" })
local unregister = Dissolve.register_effect_provider(p)
assert(not pcall(Dissolve.register_effect_provider, p), "duplicate id rejected")
local list = Dissolve.get_effect_providers()
assert(#list == 1 and list[1].mode == "square", "saved selection restored")
assert(list[1].name["zh-CN"] == "测试" and list[1].name.bad == nil, "name cleaned")
assert(list[1].labels.square == "方块" and list[1].labels.hex["zh-CN"] == "六边形" and list[1].labels.plain == nil)

-- 选择:未知效果拒绝;存盘
assert(not Dissolve.set_effect_selection("test.fx", "nope"))
assert(not Dissolve.set_effect_selection("other", "square"))
assert(Dissolve.set_effect_selection("test.fx", "hex") and saved_file["test.fx"] == "hex")

-- 定时过渡:同一角色两个材质 → 一个事务、各绑一次;反向切换不重绑;都结束后收尾
local src = { name = "leon" }
local a, b = fake("a"), fake("b")
Dissolve.effect_scope(src)
Dissolve.use({ enabled = true, dur = 1, forward = true })
Dissolve.set_material(a, 0, false, true)
Dissolve.set_material(b, 0, false, true)
Dissolve.set_material(a, 0, true, true)    -- 中途反向
Dissolve.use(nil)
Dissolve.effect_scope(nil)
assert(#log.begin == 1 and log.begin[1].effect_id == "hex" and log.begin[1].source == src, "one transaction per character")
assert(log.begin[1].source_key == tostring(src))
assert(#log.bind == 2, "each material bound once, reversal does not rebind: " .. #log.bind)
tick(5)
assert(#log.finish == 0, "still animating")
tick(6)
assert(#log.finish == 1 and log.finish[1] == log.begin[1].id, "transaction closed after all rows finish")

-- 血量驱动:每帧都会调 drive_material,只在进入中间段时绑定一次;离开后收尾
local d = fake("d")
Dissolve.effect_scope(src)
for i = 1, 10 do Dissolve.drive_material(d, 0, true, 0.1 * i * 0.9, true) end
Dissolve.effect_scope(nil)
assert(#log.begin == 2 and #log.bind == 3, "HP drive binds once, not every frame: " .. #log.bind)
tick(1)
assert(#log.finish == 1, "drive still in progress")
Dissolve.drive_material(d, 0, true, 1, true)
tick(1)
assert(#log.finish == 2, "drive end closes the transaction")

-- 随机:按注入的 random 抽
local E = EffectProviders.new({ random = function(n) return n end })
local p2, log2 = provider("r", { "one", "two", "three" })
E.register(p2)
assert(E.list()[1].mode == "random", "unknown saved selection falls back to random")
E.bind(fake("x"), 0)
assert(log2.begin[1].effect_id == "three")

-- 存盘失败回滚
local E2 = EffectProviders.new({ save = function() return false end })
E2.register((provider("s", { "one", "two" })))
assert(not E2.select("s", "two") and E2.list()[1].mode == "random", "failed save rolls back")

-- 定位复位:通知提供者、移出事务并收尾
local r = fake("r")
Dissolve.use({ enabled = true, dur = 1, forward = true }); Dissolve.set_material(r, 0, false, true); Dissolve.use(nil)
local finished = #log.finish
Dissolve.reset_mesh(r)
assert(log.reset_mesh[#log.reset_mesh] == "mesh:r" and #log.finish == finished + 1, "preview reset closes the transaction")

-- 事务上限 16
local E3 = EffectProviders.new({})
local p3, log3 = provider("cap", { "one" })
E3.register(p3)
for i = 1, 20 do E3.bind(fake("cap" .. i), 0) end
assert(#log3.begin == 16, "at most 16 transactions")

-- 注销:reset("unregister"),列表清空
unregister()
assert(log.reset[#log.reset] == "unregister" and #Dissolve.get_effect_providers() == 0)

print("PASS: RE4 dissolve effect providers (validation, saved selection, random, per-character transactions, bind once incl. HP drive, close on finish, preview reset, cap, unregister)")
