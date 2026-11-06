-- RE4 调色渐变:方案来源、渐变时长(渐入 / 渐出 / 手动)、插值写入(起点 = 当前显示的值、枚举过半才切、
-- 中途换终点接着走、结束后 apply_mesh 还原不再覆盖的参数)。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
_G.Vector4f = {new = function(x, y, z, w) return {x = x, y = y, z = z, w = w} end}
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local Palette = require("ArmorVariantManager_Core.Games.RE4.Palette")
Registry.eval_condition = function(c, ctx) return ctx[c.type] == true end
M3.clock = function() return 0 end

local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ============================================================ 来源与时长
do
    local cfg = M3.normalize({version = 3,
        base = {presets = {A = {}}, order = {"A"}, active = "A", palettes = {A = "Warm"}},
        palettes = {Warm = {}, Night = {}, Pick = {}}, palette_active = "Pick",
        conditions = {states = {
            {name = "night", conditions = {{type = "night"}}, targets = {}, palette = "Night", fade_in = 2, fade_out = 3},
            {name = "battle", conditions = {{type = "battle"}}, targets = {}, base = "A", fade_in = 0.5, fade_out = 0.25},
        }}})
    local r0 = M3.resolve(cfg, {})
    local names, src = M3.palette_sources(cfg, r0)
    S.equal(names, {"Pick", "Warm"}); S.equal(src, {false, false}, "manual pick and manually picked base")
    local r1 = M3.resolve(cfg, {night = true})
    local n1, s1 = M3.palette_sources(cfg, r1)
    S.equal(n1, {"Pick", "Warm", "Night"}); assert(s1[3] == 1)
    local states = cfg.conditions.states
    local prev = {names = names, src = src, states = states}
    local cur = {names = n1, src = s1, states = states}
    assert(M3.palette_fade_time(prev, cur, 1) == 2, "entering: the state's fade-in")
    assert(M3.palette_fade_time(cur, prev, 1) == 3, "leaving: the state's fade-out")
    assert(M3.palette_fade_time(prev, prev, 1) == 0, "no change")
    assert(M3.palette_fade_time(nil, cur, 1) == 0, "first frame is instant")
    -- 条件状态认领了整套造型:它引用的方案按这个状态的时间
    local r2 = M3.resolve(cfg, {battle = true})
    local n2, s2 = M3.palette_sources(cfg, r2)
    S.equal(n2, {"Pick", "Warm"}); assert(s2[2] == 2, "base claimed by state 2")
    -- 手动换选中的方案:界面溶解时间
    cfg.palette_active = "Night"
    local n3, s3 = M3.palette_sources(cfg, r0)
    assert(M3.palette_fade_time(prev, {names = n3, src = s3, states = states}, 1.5) == 1.5)
    assert(M3.palette_fade_time(prev, {names = n3, src = s3, states = states}, 0) == 0, "UI dissolve off = instant")
end

-- ============================================================ 插值写入
local function fake_mesh()
    local vals = {[0] = 0.0, [1] = {x = 1, y = 1, z = 1, w = 1}, [2] = 0}
    local names = {[0] = "Rough", [1] = "Base", [2] = "Mode"}
    local mesh = {vals = vals}
    mesh.call = function(_, m, j, k, v)
        if m == "get_MaterialNum" then return 1
        elseif m == "getMaterialName" then return "Skin"
        elseif m == "getMaterialVariableNum" then return 3
        elseif m == "getMaterialVariableName" then return names[k]
        elseif m == "getMaterialVariableType" then return k == 1 and Palette.TYPE_FLOAT4 or Palette.TYPE_FLOAT
        elseif m == "getMaterialFloat" then return vals[k]
        elseif m == "getMaterialFloat4" then local t = vals[k]; return {x = t.x, y = t.y, z = t.z, w = t.w}
        elseif m == "setMaterialFloat" then vals[k] = v
        elseif m == "setMaterialFloat4" then vals[k] = {x = v.x, y = v.y, z = v.z, w = v.w} end
    end
    return mesh
end
do
    local mesh, state = fake_mesh(), {}
    local v = mesh.vals
    local discrete = Palette.discrete_params({{groups = {{params = {{param = "Mode", kind = "enum"}, {param = "Base", kind = "color"}}}}}})
    assert(discrete.Mode and not discrete.Base)
    -- 先瞬间写一份:Rough = 1,Base.x = 0
    Palette.apply_mesh(mesh, {Skin = {Rough = 1, Base = {x = 0}}}, state)
    assert(v[0] == 1 and v[1].x == 0)
    -- 渐变到:Rough 不再覆盖(回到原值 0)、Base.y = 0、Mode = 3
    local plan = Palette.fade_begin(mesh, {Skin = {Base = {y = 0}, Mode = 3}}, state, discrete)
    assert(plan and #plan == 3)
    Palette.fade_step(mesh, plan, 0.25)
    assert(near(v[0], 0.75), "Rough 1 -> original 0")
    assert(near(v[1].x, 0.25) and near(v[1].y, 0.75), "Base.x back to 1, Base.y to 0")
    assert(v[1].z == 1 and v[1].w == 1, "untouched components keep the current value")
    assert(v[2] == 0, "enum does not move before halfway")
    Palette.fade_step(mesh, plan, 0.6)
    assert(v[2] == 3, "enum switches past halfway")
    -- 中途换终点:从当前显示的值接着走
    local plan2 = Palette.fade_begin(mesh, {Skin = {Rough = 0.5}}, state, discrete)
    Palette.fade_step(mesh, plan2, 0)
    assert(near(v[0], 0.4) and near(v[1].x, 0.6), "starts from what is on screen")
    Palette.fade_step(mesh, plan2, 0.5)
    assert(near(v[0], 0.45) and near(v[1].x, 0.8) and near(v[1].y, 0.7))
    assert(v[2] == 0, "Mode heads back to its original")
    -- 结束:写一次终点,不再覆盖的参数还原
    Palette.apply_mesh(mesh, {Skin = {Rough = 0.5}}, state)
    assert(v[0] == 0.5 and v[1].x == 1 and v[1].y == 1 and v[2] == 0)
    Palette.apply_mesh(mesh, nil, state)
    assert(v[0] == 0, "fully restored")
    assert(Palette.fade_begin(mesh, nil, state, discrete) == nil, "nothing to fade")
end

-- 混合模式要变的层:强度先降到 0、中点切模式和颜色、再升到目标(不跨模式插值,否则旧模式下会整片变色)
do
    local vals = {[0] = {x = 0.2, y = 0.2, z = 0.2, w = 0.28}, [1] = {x = 2, y = 1, z = 0, w = 0}}
    local names = {[0] = "L2Color", [1] = "L2Param"}
    local mesh = {call = function(_, m, j, k, v)
        if m == "get_MaterialNum" then return 1
        elseif m == "getMaterialName" then return "Hair"
        elseif m == "getMaterialVariableNum" then return 2
        elseif m == "getMaterialVariableName" then return names[k]
        elseif m == "getMaterialVariableType" then return Palette.TYPE_FLOAT4
        elseif m == "getMaterialFloat4" then local t = vals[k]; return {x = t.x, y = t.y, z = t.z, w = t.w}
        elseif m == "setMaterialFloat4" then vals[k] = {x = v.x, y = v.y, z = v.z, w = v.w} end
    end}
    local discrete = Palette.discrete_params({{groups = {{params = {
        {param = "L2Color", kind = "color"}, {param = "L2Color", component = "w", kind = "float"},
        {param = "L2Param", component = "x", kind = "enum"}, {param = "L2Param", component = "y", kind = "float"}}}}}})
    assert(discrete.couples["L2Param|x"] == "L2Color", "blend mode paired with the layer colour")
    local state = {}
    local plan = Palette.fade_begin(mesh, {Hair = {L2Color = {x = 1, y = 0, z = 0, w = 1}, L2Param = {x = 0}}}, state, discrete)
    Palette.fade_step(mesh, plan, 0.25)
    assert(near(vals[0].w, 0.14), "strength heads to 0 first")
    assert(vals[0].x == 0.2 and vals[1].x == 2, "old colour and mode kept in the first half")
    Palette.fade_step(mesh, plan, 0.5)
    assert(vals[0].w == 0 and vals[1].x == 0 and vals[0].x == 1, "switch at the midpoint while the layer is off")
    Palette.fade_step(mesh, plan, 0.75)
    assert(near(vals[0].w, 0.5), "then up to the target strength")
    -- 模式不变:照常线性插值
    local plan2 = Palette.fade_begin(mesh, {Hair = {L2Color = {x = 0, y = 0, z = 0, w = 0.5}, L2Param = {x = 0}}}, state, discrete)
    Palette.fade_step(mesh, plan2, 0.5)
    assert(near(vals[0].w, 0.5 * (0.5 + 0.5)) or near(vals[0].w, 0.5), "no dip when the mode stays")
    -- 只换模式、颜色没写:强度也要降下去再升回来
    vals = {[0] = {x = 0.2, y = 0.2, z = 0.2, w = 0.6}, [1] = {x = 3, y = 1, z = 0, w = 0}}
    local state3 = {}
    local plan3 = Palette.fade_begin(mesh, {Hair = {L2Param = {x = 0}}}, state3, discrete)
    Palette.fade_step(mesh, plan3, 0.5)
    assert(vals[0].w == 0 and vals[1].x == 0)
    Palette.fade_step(mesh, plan3, 1)
    assert(near(vals[0].w, 0.6), "back to its own strength")
end

print("PASS: RE4 palette fades: sources, fade-in / fade-out / manual durations, interpolation from what is on screen, enums switch at halfway, retargeting mid-fade, restore at the end")
