-- RE4 文案：zh/en 键集合一致，面板用到的静态键、TP 的 base/_g 两份、以及拼出来的动态键
-- （cond_<条件>、slot_<槛位>、char_<角色>、tri_<三态>）都有定义。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
package.path = autorun .. "/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local root = autorun .. "/ArmorVariantManager_Core/Games/RE4/"

_G.sdk = {find_type_definition = function() return nil end, is_managed_object = function() return false end}
local L = require("ArmorVariantManager_Core.Games.RE4.Localization")
local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
local CharacterId = require("ArmorVariantManager_Core.Games.RE4.CharacterId")

local problems = {}
local function need(key, why)
    for _, lang in ipairs({"zh", "en"}) do
        if L[lang][key] == nil then problems[#problems + 1] = lang .. " missing " .. key .. " (" .. why .. ")" end
    end
end

for _, pair in ipairs({{"zh", "en"}, {"en", "zh"}}) do
    for key in pairs(L[pair[1]]) do
        if L[pair[2]][key] == nil then problems[#problems + 1] = pair[1] .. "-only key " .. key end
    end
end
for key in pairs(L.en) do
    local base = key:match("^(.+)_g$")
    if base and L.en[base] == nil then problems[#problems + 1] = "orphan _g key " .. key end
end

local main = S.read(root .. "Main.lua")
for key in main:gmatch('[^%w_]T%("([%w_]+)"%)') do need(key, "T") end
for key in main:gmatch('TP%("([%w_]+)"') do need(key, "TP base"); need(key .. "_g", "TP _g") end

for _, def in ipairs(Registry.all()) do
    assert(Registry.get(def.id) == def)
    need(def.label_key, "condition " .. def.id)
end
for _, slot in ipairs(Utils.MESH_SLOTS) do need("slot_" .. slot, "slot label") end
for _, character in pairs(CharacterId.HEAD_GROUP_TO_CHARACTER) do need("char_" .. character:lower(), "character label") end
for _, key in ipairs({"tri_none", "tri_off", "tri_on"}) do need(key, "tri-state") end

assert(#problems == 0, table.concat(problems, "\n"))
assert(#Registry.all() > 0, "conditions registered")
print("PASS: RE4 zh/en parity, static T/TP keys, condition/slot/character/tri-state labels")
