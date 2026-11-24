package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix = "ArmorVariantManager_Core."
local Normalize = require(prefix.."Config.Normalize")

-- 检查配置与保存边界，不把控件排列或某个旧版本当作业务契约。
local function run(game, input, action, unavailable, weapon)
    local config, saves, values = S.copy(input), {}, {}
    local refreshes, fail_save = 0, action and action.fail_save
    local editable = {button=true,checkbox=true,combo=true,input_text=true}
    local ui = setmetatable({}, {__index=function(_, method)
        return function(label, value)
            values[label or method]=value
            if method=="tree_node" then return true end
            if not editable[method] then return end
            local changed=action and action.label==label
            local result=value
            if changed then result=action.value; action=nil end
            if method=="button" then return changed end
            return changed,result
        end
    end})
    local noop=function() end
    local rules=setmetatable({
        has_configured_condition=function() return true end,
        get_configured_state=function(_,kind) return kind=="hp" and 75 or 1 end,
        get_current_state_display=function() return "state" end,
        get_current_raw_state=function() return 75 end,
        clear_cache=noop,
    },{__index=function(_,key)
        assert(key:match("^has_") or key=="is_hp_module_initialized",key)
        return function() return not unavailable end
    end})
    local actor={get_address=function() return 123 end}
    imgui=ui
    local panel=require(prefix.."Games."..game..".ImGuiConditions").new({
        translate=function(key) return key end, rules=rules,
        save=function(id, preserve)
            assert(id=="id")
            if fail_save then assert(preserve); return false, "disk unavailable" end
            saves[#saves+1]=S.copy(config)
            return true
        end,
        draw_targets=noop, can_transform=function() return unavailable~="actor" end,
        game_object=function() return actor end,
        set_enabled=function(id,data,enabled)
            assert(id=="id" and data==config); data.enable_transform=enabled
        end,
        refresh=function(id,data,character)
            assert(id=="id" and data==config and character==actor); refreshes=refreshes+1
        end,
    })
    panel(config,"id",actor,weapon)
    assert(not action,"control was not reached")
    panel(config,"id",actor,weapon)
    assert(config.unknown.keep and (not saves[1] or saves[1].unknown.keep))
    return {config=config,saves=saves,values=values,refreshes=refreshes}
end

for _,game in ipairs({"Wilds","Rise"}) do
    local kind=game=="Wilds" and "hp" or "monster_hp"
    local base=Normalize.apply({presets={Base={}},default_preset="Base",unknown={keep=true},
        enable_transform=true,transform_type=kind,transform_rules={{threshold=50,targets={}}},
        monster_hp_transform_rules={{threshold=50,targets={}}}},require(prefix.."Games."..game..".Config"))
    local mode=run(game,base,{label="switch_to_parallel"})
    assert(mode.config.is_parallel and #mode.saves==1)
    local priority=run(game,mode.config,{label="priority##weapon",value="27"})
    assert(priority.config.parallel_settings.weapon.priority==27 and #priority.saves==1)
    local threshold=game=="Wilds" and "hp_percent##1" or "monster_hp_threshold##1"
    local rules=game=="Wilds" and "transform_rules" or "monster_hp_transform_rules"
    local valid=run(game,base,{label=threshold,value="27"})
    assert(valid.config[rules][1].threshold==27 and #valid.saves==1)
    local invalid=run(game,base,{label=threshold,value="not a number"})
    assert(invalid.config[rules][1].threshold==50 and #invalid.saves==0)
    local target=run(game,base,{label="+ add_condition##"..kind.."_add_1"})
    S.equal(target.config[rules][1].targets,{{group="",preset=game=="Rise" and "Base" or ""}})
    assert(#target.saves==1 and target.refreshes==(game=="Rise" and 1 or 0))
    local removed=run(game,base,{label="delete_node##1"})
    assert(#removed.config[rules]==0 and #removed.saves==1)
    if game=="Wilds" then
        local state=run(game,base,{label="##test_hp_input",value="27"})
        assert(state.values["##test_hp_input"]=="27" and #state.saves==0)
        local enabled = run(game,base,{label="rule_dissolve_enabled##dissolve_enabled",value=true})
        local rule = enabled.config.transform_rules[1]
        assert(rule.dissolve_enabled and #enabled.saves==1 and enabled.refreshes==0)
        assert(rule.dissolve_hide_time==nil and rule.dissolve_show_time==nil)
        local enter = "rule_dissolve_enter_time##dissolve_hide_time"
        local exit = "rule_dissolve_exit_time##dissolve_show_time"
        assert(enabled.values[enter]=="0.5" and enabled.values[exit]=="0.5")
        local updated = run(game,enabled.config,{label=enter,value="1.25"})
        assert(updated.config.transform_rules[1].dissolve_hide_time==1.25 and #updated.saves==1)
        local failed = run(game,updated.config,{label=exit,value="0",fail_save=true})
        assert(failed.config.transform_rules[1].dissolve_show_time==nil and #failed.saves==0)
        assert(failed.values["disk unavailable"]~=nil and failed.refreshes==0)
        local weapon = run(game,enabled.config,nil,nil,true)
        assert(weapon.values[enter]==nil and weapon.values[exit]==nil)
        local damage=S.copy(base); damage.transform_type="damage"
        damage.damage_transform_rules={{mode=1,duration=5,targets={},chain_nodes={}}}
        local changed=run(game,damage,{label="action_mode##dmg",value=2})
        assert(changed.config.damage_transform_rules[1].mode==2 and #changed.saves==1)
        damage.damage_transform_rules[1].mode = 3
        local chain=run(game,damage,{label="rule_dissolve_enabled##dissolve_enabled",value=true})
        assert(chain.config.damage_transform_rules[1].dissolve_enabled)
        local unavailable=run(game,base,nil,"actor")
        assert(#unavailable.saves==0 and next(unavailable.values)==nil)
    else
        local disabled=run(game,base,{label="enable_transform",value=false})
        assert(not disabled.config.enable_transform and #disabled.saves==1)
    end
end
print("PASS: native condition modes, priority, rule editing, target refresh, numeric input and actor eligibility")
