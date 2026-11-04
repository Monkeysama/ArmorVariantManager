package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Normalize = require("ArmorVariantManager_Core.Config.Normalize")
local editable = {button=true, checkbox=true, combo=true, input_text=true}
local noop = function() end
local comparisons = 0

-- 记录完整控件顺序，每轮只操作一个控件，比较旧面板的配置和保存时机。
local function run(game, candidate, input, action, unavailable)
    local config = S.copy(input)
    local trace, controls, saves, hp_writes = {}, {}, {}, {}
    local index, refreshes = 0, 0
    local translations = require(game == "Wilds" and "ArmorVariantManager_Core.Localization"
        or "ArmorVariantManager_Core.Games.Rise.Localization").en
    local ui = setmetatable({}, {__index=function(_, name)
        return function(...)
            local args = table.pack(...)
            trace[#trace+1] = {name=name, args=S.copy(args)}
            if editable[name] then
                index = index + 1
                controls[#controls+1] = {name=name, index=index}
                local changed = action == index
                if name == "button" then return changed end
                if name == "checkbox" then
                    if changed then return true, not args[2] end
                    return false, args[2]
                end
                if name == "combo" then return changed, changed and (args[2] % #args[3] + 1) or args[2] end
                return changed, changed and "27" or args[2]
            end
            if name == "tree_node" then return true end
        end
    end})
    local rules = setmetatable({
        has_configured_condition=function() return true end,
        get_configured_state=function(_, kind) return kind == "hp" and 75 or 1 end,
        get_current_state_display=function() return "state" end,
        get_current_raw_state=function() return 75 end,
        get_character_hp=function() return 100 end,
        set_character_hp=function(_, value) hp_writes[#hp_writes+1] = {"hp", value} end,
        set_character_hp_percent=function(_, value) hp_writes[#hp_writes+1] = {"percent", value} end,
        clear_cache=noop,
        apply_transform_rules=function() refreshes=refreshes+1; return {}, false, {}, {} end,
    }, {__index=function(_, key)
        assert(key:match("^has_") or key == "is_hp_module_initialized", key)
        return function() return not unavailable end
    end})
    local character = {get_address=function() return 123 end}
    local function translate(key) return translations[key] or key end
    local function save(id) saves[#saves+1] = {id, S.copy(config)} end
    local function targets(list, kind, i)
        trace[#trace+1] = {name="targets", args={S.copy(list),kind,i}}
    end
    local env = setmetatable({imgui=ui, T=translate, current_config=config, body_id="id",
        character=character, primary=character, test_hp_input="100", TransformManager=rules,
        save_current_config_to_file=save, draw_targets_ui=targets,
        can_use_transform=function() return unavailable ~= "actor" end, safe_get_game_object=function() return character end,
        active_overrides={}, active_group_presets={}, is_weapon_mode=false,
        bump_overrides_version=noop, apply_preset_to_character=noop, apply_all_defaults=noop,
    }, {__index=_G})
    local draw
    if candidate then
        local path="ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/"..game.."/ImGuiConditions.lua"
        local module = assert(loadfile(path, "t", env))()
        draw = module.new({translate=translate, rules=rules, save=save, draw_targets=targets,
            can_transform=env.can_use_transform, game_object=env.safe_get_game_object,
            set_enabled=function(id, data, enabled)
                assert(id == "id" and data == config)
                data.enable_transform=enabled
                if enabled then refreshes=refreshes+1 end
            end,
            refresh=function(id, data, actor)
                assert(id == "id" and data == config and actor == character)
                refreshes=refreshes+1
            end,
        })
    else
        draw = dofile("tests/fixtures/legacy/"..game:lower().."_condition_ui.lua")(env)
    end
    draw(config, "id", character)
    -- 第二帧同时检查 HP 输入等面板私有状态是否保留。
    action=nil
    draw(config, "id", character)
    return {config=config, trace=trace, saves=saves, hp=hp_writes, refreshes=refreshes}, controls
end

for _, game in ipairs({"Wilds", "Rise"}) do
    local schema = require("ArmorVariantManager_Core.Games."..game..".Config")
    local config = Normalize.apply({presets={Base={}}, default_preset="Base", unknown={keep=true}}, schema)
    config.enable_transform=true
    config.transform_rules={{threshold=50, targets={}}}
    config.monster_hp_transform_rules={{threshold=50, targets={}}}
    local types = game == "Wilds" and {"hp","damage","weapon","spirit","dual_blades","switch_axe",
        "insect_glaive","charge_blade","greatsword_type","greatsword_level","bow_level","hammer_level"}
        or {"weapon","scroll","monster_hp","longsword","dual_blades","switch_axe","charge_axe",
        "greatsword_level","hammer","bow"}
    local cases = {}
    for _, kind in ipairs(types) do
        local item=S.copy(config); item.transform_type=kind; item.is_parallel=false
        cases[#cases+1]=item
    end
    local parallel=S.copy(config); parallel.is_parallel=true
    for _, setting in pairs(parallel.parallel_settings) do setting.enabled=true end
    cases[#cases+1]=parallel
    if game == "Wilds" then
        for mode=2,3 do
            local item=S.copy(config); item.transform_type="damage"; item.is_parallel=false
            item.damage_transform_rules={{mode=mode, duration=5, targets={}, chain_nodes={{duration=3,targets={}}}}}
            cases[#cases+1]=item
        end
    else
        local item=S.copy(config); item.enable_transform=false; cases[#cases+1]=item
    end
    for _, item in ipairs(cases) do
        local baseline, controls=run(game,false,item)
        local actual=run(game,true,item)
        S.equal(actual,baseline,game.." idle "..item.transform_type)
        -- controls 含两帧；首帧控件编号在每次运行中相同。
        local first_frame_count=#controls/2
        for i=1,first_frame_count do
            local old=run(game,false,item,i)
            local new=run(game,true,item,i)
            S.equal(new,old,game.." control "..i.." "..item.transform_type)
            comparisons=comparisons+1
        end
    end
    if game == "Wilds" then
        S.equal(run(game,true,parallel,nil,true),run(game,false,parallel,nil,true),"Unavailable signals")
        S.equal(run(game,true,parallel,nil,"actor"),run(game,false,parallel,nil,"actor"),"Preview actor has no combat panel")
    end
end

-- 完整菜单接线由 entrypoint.lua 的双游戏入口场景覆盖。
print("PASS: native condition panels, "..comparisons.." individual control edits and second-frame state")
