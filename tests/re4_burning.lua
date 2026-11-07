-- is_burning:get_IsInBurnDamage 为真,或 BodyUpdater 的 _CurrentBurnEffectID >= 0(普通火焰点燃时前者不置位)
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local defs = require("ArmorVariantManager_Core.Games.RE4.Conditions.PlayerBools")
local burning
for _, d in ipairs(defs) do if d.id == "is_burning" then burning = d end end
assert(burning, "is_burning registered")

local function context(in_burn, effect_id, no_body)
    local body = { get_field = function(_, name) assert(name == "_CurrentBurnEffectID"); return effect_id end }
    return { call = function(_, m)
        if m == "get_IsInBurnDamage" then return in_burn end
        if m == "get_BodyUpdater" then return (not no_body) and body or nil end
    end }
end

assert(burning.get(context(true, -1)) == true, "burn damage flag")
assert(burning.get(context(false, 0)) == true, "ignited by flame attack: effect Start(0)")
assert(burning.get(context(false, 2)) == true, "later burn effect stages")
assert(burning.get(context(false, -1)) == false, "fire out: Invalid(-1)")
assert(burning.get(context(false, nil)) == false, "field unreadable")
assert(burning.get(context(false, 0, true)) == false, "no body updater")
assert(burning.get(nil) == nil, "no context")
print("PASS: RE4 is_burning counts the burn damage flag or an active burn effect")
