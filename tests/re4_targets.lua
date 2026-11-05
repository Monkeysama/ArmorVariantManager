-- RE4 目标收集:重扫失败(拿不到场景 / findComponents 报错)沿用上次的雕像,不能当成"0 个"清空;
-- 连续失败超过上限才清空;真扫到 0 个立即清空。(模型鉴赏页挂机时"反复丢失角色追踪"的回归)
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path

package.loaded["ArmorVariantManager_Core.Games.RE4.Utils"] = {
    get_local_player_context = function() return nil end,
    get_character_manager = function() return nil end,
    get_mesh = function(source, slot) return type(source) == "table" and source[slot] or nil end,
}
package.loaded["ArmorVariantManager_Core.Games.RE4.CharacterId"] = {
    identify = function(source) return source.head and { head_mesh = "cha000_10", character = "Leon" } or nil end,
}

local function obj(t) t.get_address = t.get_address or function() return tostring(t) end; return t end
local function mesh() return obj({ call = function(_, m) if m == "get_MaterialNum" then return 9 end end }) end
local function child(name, next_tf)
    local go = obj({})
    local m = mesh()
    function go:call(method) if method == "get_Name" then return name elseif method == "getComponent(System.Type)" then return m end end
    local tf = obj({})
    function tf:call(method)
        if method == "get_GameObject" then return go elseif method == "get_Next" then return next_tf end
        return nil
    end
    return tf
end
local body_tf = obj({})
local first = child("Hair", nil); first = child("Head", first); first = child("Body", first)
function body_tf:call(method) if method == "get_Child" then return first end end
local fig_go = obj({})
function fig_go:call(method) if method == "get_Name" then return "FigureModel_Figure00_010" elseif method == "get_Transform" then return body_tf end end
local comp = obj({ call = function(_, method) if method == "get_GameObject" then return fig_go end end })

local mode = "ok"   -- ok | error | nil | empty | noscene
local scene = obj({})
function scene:call(method, t)
    if t == "figure" then
        if mode == "error" then error("findComponents failed") end
        if mode == "nil" then return nil end
        local list = mode == "empty" and {} or { comp }
        return { get_elements = function() return list end }
    end
    return { get_elements = function() return {} end }
end
_G.sdk = {
    typeof = function(name) return name == "chainsaw.FigureModelController" and "figure" or "other" end,
    find_type_definition = function() return {} end,
    get_native_singleton = function() return {} end,
    call_native_func = function() return mode ~= "noscene" and scene or nil end,
    is_managed_object = function(v) return type(v) == "table" end,
}

local Targets = require("ArmorVariantManager_Core.Games.RE4.Targets")
Targets.set_borrow_resolver(function() return nil end)
local function frames(n) local out; for _ = 1, n do out = Targets.collect() end; return out end
local function has_figure(out) return #out == 1 and out[1].id == "figure:FigureModel_Figure00_010" end

assert(has_figure(frames(1)), "figure found on first scan")
for _, failure in ipairs({ "error", "nil", "noscene" }) do
    mode = failure
    local out = frames(60)
    assert(has_figure(out), "a failed rescan (" .. failure .. ") must keep the figure")
    mode = "ok"; assert(has_figure(frames(60)))
end

-- 连续失败超过上限才清空
mode = "error"
assert(has_figure(frames(60 * 3)), "up to the limit the figure stays")
assert(#frames(60) == 0, "after too many consecutive failures the cache is cleared")
mode = "ok"; assert(has_figure(frames(60)), "recovers on the next good scan")

-- 真扫到 0 个:立即清空
mode = "empty"
assert(#frames(60) == 0, "a successful empty scan clears immediately")

print("PASS: RE4 targets keep figures across failed rescans (error / nil / no scene), clear after the failure limit and on a real empty scan")
