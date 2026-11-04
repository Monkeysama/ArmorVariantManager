package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Selection = require("ArmorVariantManager_Core.Presets.Selection")
local Height = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingFix")
local legacy = dofile("tests/fixtures/legacy/preset_selection.lua")
local Fixture=dofile("tests/app_fixture.lua")
local function preset(materials) return {["0"]={materials=materials}} end
local config = {default_preset="Base", presets={Base=preset({cloth=true, ribbon=true}), Alt=preset({cloth=false})},
    groups={
        Normal={default_preset="Default", presets={Default=preset({boots=true}), Other=preset({boots=false})}},
        Lock={is_global=true, default_preset="Hide", presets={Hide=preset({cloth=false}), Show=preset({cloth=true})}},
        Extra={is_global=true, default_preset="Hide", presets={Hide=preset({ribbon=false}), Show=preset({ribbon=true})}},
    }, unknown={keep=true}}
config.groups.Normal.presets.Other["0"].mesh_enabled=false

local function environment(game, selected)
    local policy = require("ArmorVariantManager_Core.Games." .. game .. ".Presets")
    local env = setmetatable({current_config=S.copy(config), current_group_name="",
        active_overrides={id=preset({cloth=true, ribbon=true, boots=true, untouched=false})},
        active_group_presets={id=S.copy(selected)}, temp_applied_presets={},
        PresetSelection=Selection, GamePresets=policy, GroundClippingFix=Height,
        ground_clipping_presets={reset=function() end},
        get_body_id=function() return "id" end, get_primary_body_id=function() return "id" end,
        get_local_player_character=function() end, get_primary_player=function() end,
        get_all_characters=function() return {} end, is_weapon_id=function() return false end,
        bump_overrides_version=function() end, Applied={invalidate_body=function() end},
        TransformManager={update_base_preset=function() end},
    }, {__index=_G})
    if game == "Wilds" then
        env.active_overrides.id.ground_clipping_fix={enabled=true, height_cm=9}
        env.appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance").new({is_weapon_id=env.is_weapon_id})
        env.appearance.overrides, env.appearance.groups = env.active_overrides, env.active_group_presets
        env.appearance.height = env.ground_clipping_presets
        env.application = require("ArmorVariantManager_Core.Games.Wilds.Application").new({
            actors={all=env.get_all_characters, local_player=env.get_local_player_character},
            equipment={}, materials={},
        }, env.appearance, {}, {}, env.is_weapon_id)
    end
    env.get_current_preset_data=function(name)
        local owner=env.current_group_name == "" and env.current_config or env.current_config.groups[env.current_group_name]
        return owner and owner.presets[name]
    end
    env.merge_preset_into_overrides=function(id, data) policy.merge_into(env.active_overrides[id], data) end
    env.merge_global_preset_into_overrides=function(id, data) policy.merge_global_into(env.active_overrides[id], data) end
    env.merge_overrides=policy.merge
    return env
end

for _, game in ipairs({"Wilds", "Rise"}) do
    for _, selected in ipairs({{}, {[""]="Alt", Normal="Other"},
        {[""]="missing", Normal="missing", Extra="missing"}, {[""]="", Normal="", Extra=""}}) do
        local before, after = environment(game, selected), environment(game, selected)
        local old = legacy[game](before)
        local new
        if game == "Wilds" then
            local app=Fixture.new(game, {backend=after.application})
            app.workspace.config=after.current_config
            app.workspace.applied=after.temp_applied_presets
            app.workspace.get_body_id=after.get_body_id
            new=function(name)
                app.workspace.state.group=after.current_group_name
                return app.apply_preset(name)
            end
        else
            new = function(name)
                local result=Selection.apply(after.current_config, after.active_group_presets.id,
                    after.active_overrides.id, after.current_group_name, name, after.GamePresets)
                if result then after.active_overrides.id=result end
            end
        end
        for _, choice in ipairs({{"Lock","Show"}, {"Normal","Other"}, {"","Alt"},
            {"Lock","Hide"}, {"Extra","Show"}, {"Lock","Show"}, {"","Base"}, {"Lock","missing"}}) do
            before.current_group_name, after.current_group_name = choice[1], choice[1]
            old(choice[2]); new(choice[2])
            S.equal(after.active_overrides, before.active_overrides, game .. " result " .. choice[1] .. "/" .. choice[2])
            S.equal(after.active_group_presets, before.active_group_presets, game .. " selections")
            S.equal(after.current_config, config, "Selecting must not change defaults or stored presets")
            S.equal(after.temp_applied_presets, before.temp_applied_presets, "Temporary selection")
        end
    end
end
local names, result = {}, {keep=true}
assert(Selection.apply(config, names, result, "deleted", "Base", {}) == nil)
assert(next(names) == nil and result.keep, "Missing group must not mutate either state")
print("PASS: both legacy manual selection paths, global rebuild, incremental merge, fallback and original Wilds entry")
