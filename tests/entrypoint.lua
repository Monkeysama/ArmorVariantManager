-- 可传入已解压发布包的 autorun 目录，默认仍验证开发源码。
local autorun = arg[1] or "ArmorVariantManager/reframework/autorun"
local host_package_path = package.path
package.path = autorun .. "/?.lua;" .. package.path
local startup_package_path = package.path
local main = autorun .. "/ArmorVariantManager.lua"
local Game = require("ArmorVariantManager_Core.Game")
assert(Game.detect("MHWILDS").name == "Wilds")
assert(Game.detect("MHRise").name == "Rise")
assert(not Game.detect("re4"))

local S = dofile("tests/support.lua")
for _, scenario in ipairs({{"mhwilds"}, {"mhrise"}, {"unknown"}, {"mhwilds", true}, {"mhrise", true}}) do
    local game, populated = scenario[1], scenario[2]
    for name in pairs(package.loaded) do
        if name:match("^ArmorVariantManager") then package.loaded[name] = nil end
    end
    local frames, draws, resets, errors, imports = {}, {}, {}, {}, {}
    local expected_errors = 0
    local action, writes, applied, captures = nil, {}, {}, 0
    local native_file_index = 1
    local checkbox_labels = {}
    local weapon_id, applied_weapons = nil, {}
    local handlers, unregistered, write_failed, write_failed_path
    local enabled, visible = true, true
    local td = {get_method=function() return nil end}
    local mesh = {get_type_definition=function() return td end}
    function mesh:call(method, offset, value)
        if method=="get_Enabled" then return enabled end
        if method=="set_Enabled" then enabled=offset end
        if method=="get_MaterialNum" then return 2 end
        if method=="getMaterialName" then return offset==0 and "cloth" or "metal" end
        if method=="getMaterialsEnable" then return visible end
        if method=="setMaterialsEnable" then visible=value end
    end
    local object = {get_type_definition=function() return td end,call=function(_,method)
        if method=="get_Name" then return "actor" end
        if method=="getComponent(System.Type)" then return mesh end
    end}
    local player = {}
    local cfg = {presets={Show={["0"]={materials={cloth=true}}},Hide={["0"]={materials={cloth=false}}}},
        preset_order={"Show","Hide"},default_preset="Show",groups={},extra={keep=true},enable_transform=false}
    local data = {["ArmorVariantManager/armor.json"]=cfg,
        ["ArmorVariantManager/GlobalSettings.json"]={language="en",auto_set_selected_preset_as_default=false,extra={keep=true}}}
    local player_backup = S.copy(cfg)
    player_backup.backup_only = {keep=true}
    data["ArmorVariantManager/backup/armor.json"] = S.copy(player_backup)
    local native_require = require
    _G.require = function(name)
        assert(not name:match("^ArmorVariantManager_UI")
            and name ~= "ArmorVariantManager_Core.UI.VariantManagerUI"
            and name ~= "ArmorVariantManager_Core.UI.Legacy", "retired UI imported: " .. name)
        imports[name] = true
        if name=="reff.sdk" then
            return {register=function(id, value)
                assert(id=="monkeysama.avm")
                handlers=value.methods
                return {unregister=function() unregistered=true end}
            end}
        end
        if populated and name=="ArmorVariantManager_Core.Config.Store" then
            return {config_path=function(id) return "ArmorVariantManager/"..id..".json" end,
                backup_path=function(id) return "ArmorVariantManager/backup/"..id..".json" end,
                load=function(path) return S.copy(data[path]) end,
                save=function(path,value)
                    if write_failed or path==write_failed_path then return false, "disk full" end
                    data[path]=S.copy(value); writes[#writes+1]=path; return true
                end}
        end
        if populated and name:match("Games%.%w+%.Runtime$") then
            return {new=function(_,callbacks)
                local entry={obj=object,player=player,is_local=true,name="Hunter",index=1}
                local runtime={
                    actors={local_player=function() return object end,all=function() return {object} end,
                        get=function() return {entries={entry},local_entry=entry} end,can_transform=function() return false end},
                    equipment={body_id=function() return "armor" end,weapon_id=function() return weapon_id end,
                        weapons=function() return {} end,clear=function() end},
                    meshes={first=function() return mesh end,part_meshes=function() return {mesh} end},
                    scene_object={game_object=function(o) return o end},
                    guard={suspended=false,get_scene=function() end},
                    materials={armor=function(_,result) applied[#applied+1]=S.copy(result) end,
                        weapon=function(_,_,result) applied_weapons[#applied_weapons+1]=S.copy(result) end,invalidate=function() end},
                    transition={draw_ui=function() end},
                    part_view=function() return {{index=0,label="Body",object=object}} end,
                    capture=function(actor,...)
                        assert(actor==object)
                        local args={...}
                        if game=="mhrise" then assert(args[1]==player and args[4]==false)
                        else assert(args[2]=="" and args[4]==false) end
                        captures=captures+1
                        return {["0"]={materials={cloth=false}}}
                    end,
                    is_suspended=function() return false end,
                }
                function runtime.install_hooks() re.on_script_reset(callbacks.reset) end
                function runtime.refresh() callbacks.process(entry,false,runtime); return true end
                function runtime.tick(ui)
                    if ui.suspended then ui.suspended(false) end
                    ui.update()
                    if game=="mhrise" then callbacks.process(entry,false,runtime)
                    else ui.retain({[tostring(object)]=ui.process(object)}) end
                end
                return runtime
            end}
        end
        return native_require(name)
    end
    _G.reff_native = populated and {} or nil
    _G.reframework = {get_game_name=function() return game end}
    _G.sdk = {find_type_definition=function(name)
            if name == "via.Component" or name == "via.GameObject" or name == "via.Scene" or name == "app.HunterCharacter" then return {get_method=function()
                return {call=function(_,object) return object end}
            end} end
            return {get_runtime_type=function() return {} end, get_method=function() return {call=function() end} end,
                get_field=function() return {get_type=function() return {get_method=function() return {} end} end} end}
        end,
        get_managed_singleton=function() return nil end, get_native_singleton=function() return nil end,
        is_managed_object=function(object) return object ~= nil end, typeof=function(name) return name end,
        hook=function() end}
    _G.re = {on_frame=function(fn) frames[#frames+1]=fn end,
        on_draw_ui=function(fn) draws[#draws+1]=fn end,
        on_script_reset=function(fn) resets[#resets+1]=fn end,
        on_application_entry=function() end, on_pre_application_entry=function() end}
    _G.log = {info=function() end, warn=function() end, error=function(message) errors[#errors+1]=message end}
    _G.json = {load_file=function(path) return S.copy(data[path]) end, dump_file=function() return true end}
    _G.fs = {glob=function()
        if populated and game=="mhrise" then
            return {"ArmorVariantManager/manual_source.json","ArmorVariantManager/backup/manual_backup.json"}
        end
        return {}
    end}
    _G.imgui = setmetatable({tree_node=function() return true end, checkbox=function(label,v)
            checkbox_labels[label]=true
            return false,v
        end,
        text_colored=function(message) assert(not tostring(message):find("Error:"),message) end},
        {__index=function() return function() end end})
    if populated then
        imgui.begin_table=function() return true end
        imgui.combo=function(label,value)
            if action=="select" and label=="##preset_selector" then action=nil; return true,2 end
            if action=="manual-select" and label=="##manual_file_selector" then action=nil; return true,native_file_index end
            return false,value
        end
        imgui.input_text=function(label,value)
            if action=="save" and label=="##new_preset_name_input" then return true,"Captured" end
            return false,value
        end
        imgui.button=function(label)
            if action=="save" and label:find("##p_left",1,true) then action=nil; return true end
            if action=="manual-open" and label=="Manual Find Preset" then action=nil; return true end
            if action=="manual-load" and label=="Load Selected" then action=nil; return true end
            return false
        end
        imgui.slider_float=function(_,value) return false,value end
        imgui.slider_int=imgui.slider_float
    end
    assert(loadfile(main))()
    -- 模拟启动后宿主恢复搜索路径，后续 REFF 回调不能依赖 autorun 路径。
    package.path = host_package_path
    for i=1,6 do for _, fn in ipairs(frames) do fn() end end
    for _, fn in ipairs(draws) do fn() end
    if populated then
        assert(applied[#applied]["0"].materials.cloth==true,"default applied from original JSON")
        action="select"; draws[1]()
        assert(action==nil and applied[#applied]["0"].materials.cloth==false,"native selection reaches application")
        action="save"; draws[1]()
        assert(action==nil and captures==1 and #writes>=1,"native save reaches game capture and shared store")
        local saved=data["ArmorVariantManager/armor.json"]
        assert(saved.presets.Captured["0"].materials.cloth==false and saved.extra.keep)
        if game=="mhrise" then assert(saved.longsword_transform_rules and not saved.spirit_transform_rules)
        else assert(saved.spirit_transform_rules and not saved.longsword_transform_rules) end
    end
    if populated then
        assert(handlers,"REFF handler registered for each game")
        local snapshot=handlers["monkeysama.avm.snapshot"]
        local dispatch=handlers["monkeysama.avm.action"]
        local documentation=handlers["monkeysama.avm.documentation"]
        local current=snapshot()
        assert(current.game==(game=="mhrise" and "Rise" or "Wilds") and current.bodyId=="armor")
        assert(current.theme=="custom" and current.parts[1].materials[1].name=="cloth")
        assert(current.parts[1].materials[1].editable and current.parts[1].materials[1].owner==nil)
        local function send(kind,args)
            args=args or {}; args.kind=kind; args.bodyId="armor"
            return dispatch(args)
        end
        assert(current.backupPending and not current.documentation,"backup warning is live; long help is not polled")
        local help=documentation()
        assert(#help.sections==3 and help.sections[1].id=="configure" and help.sections[1].title=="How to Configure")
        assert(#help.sections[3].entries==22,"complete historical help is available on demand")
        local protected_backup=S.copy(data["ArmorVariantManager/backup/armor.json"])
        local restore_writes=#writes
        write_failed=true
        local restored,restore_reason=pcall(send,"restore")
        assert(not restored and restore_reason:find("disk full",1,true),"restore preserves the actual storage error")
        expected_errors=expected_errors+1
        assert(#errors==expected_errors and errors[#errors]:find("还原备份失败",1,true))
        assert(snapshot().backupPending and snapshot().selectedPreset==current.selectedPreset and #writes==restore_writes)
        assert(not pcall(dispatch,{kind="dismiss-backup",bodyId="old"}))
        assert(snapshot().backupPending,"stale dismiss cannot clear another equipment warning")
        current=send("dismiss-backup")
        assert(not current.backupPending and #writes==restore_writes,"dismiss is session-only even when writes fail")
        S.equal(data["ArmorVariantManager/backup/armor.json"],protected_backup)
        write_failed=false
        local function names(items)
            local result={}
            for index,item in ipairs(items) do result[index]=item.name end
            return result
        end
        local function field(id, value)
            for _,section in ipairs((value or snapshot()).settings.sections) do
                for _,item in ipairs(section.fields) do if item.id==id then return item end end
            end
        end
        local function assert_auto_default_label(expected)
            local key="auto_set_selected_preset_as_default"
            assert(field(key).label==expected,"REFF auto-default label must use the current language")
            checkbox_labels={}
            draws[1]()
            assert(checkbox_labels[expected] and not checkbox_labels[key],
                "native auto-default checkbox must use the current language")
        end
        assert(field("language").value=="en")
        assert_auto_default_label("Automatically set selected preset as default")
        if game=="mhwilds" then
            assert(field("scan_interval").value==0.5)
            assert(not field("portrait_enabled").disabled,
                "settings use the application service without the retired UI")
            current=dispatch({kind="setting",id="scan_interval",value=-2,bodyId="old"})
            assert(field("scan_interval",current).value==0.1,"global setting ignores equipment identity")
        else
            assert(not field("scan_interval") and not field("body_id_ttl") and not field("scanner_batch_size"))
            local invalid, reason=pcall(send,"setting",{id="scan_interval",value=2})
            assert(not invalid and reason:find("设置项不存在",1,true))
            current=dispatch({kind="setting",id="enable_multiplayer",value=false,bodyId="old"})
            assert(not field("enable_multiplayer",current).value,"global setting ignores equipment identity")
        end
        assert(data["ArmorVariantManager/GlobalSettings.json"].extra.keep,"global unknown fields retained")
        write_failed=true
        local settings_ok,settings_reason=pcall(send,"setting",{id="language",value="zh"})
        assert(not settings_ok and settings_reason:find("disk full",1,true))
        assert(snapshot().language=="en" and _G.__AVM_LANGUAGE=="en","failed language save has no side effect")
        write_failed=false
        assert(send("setting",{id="language",value="zh"}).language=="zh")
        assert(_G.__AVM_LANGUAGE=="zh")
        assert_auto_default_label("自动将选中预设设为默认")
        assert(documentation().sections[1].title=="如何配置","help reads the current language instead of a startup copy")
        send("setting",{id="language",value="en"})
        assert_auto_default_label("Automatically set selected preset as default")
        local sorting_selected=snapshot().selectedPreset
        local sorting_applied=#applied
        current=send("reorder-preset",{name="Captured",offset=-1})
        S.equal(names(current.presets),{"Show","Captured","Hide"})
        S.equal(data["ArmorVariantManager/armor.json"].preset_order,{"Show","Captured","Hide"})
        assert(current.selectedPreset==sorting_selected and #applied==sorting_applied,"sorting preserves selection and appearance")
        local sorting_writes=#writes
        current=send("reorder-preset",{name="Hide",target="Show",after=false,group="",weapon=false})
        S.equal(names(current.presets),{"Hide","Show","Captured"})
        local sorting_saves=0
        for index=sorting_writes+1,#writes do
            if writes[index]=="ArmorVariantManager/armor.json" then sorting_saves=sorting_saves+1 end
        end
        assert(sorting_saves==1 and current.selectedPreset==sorting_selected,"drag moves multiple positions with one save")
        current=send("reorder-preset",{name="Hide",target="Captured",after=true,group="",weapon=false})
        local before_order=S.copy(data["ArmorVariantManager/armor.json"].preset_order)
        write_failed=true
        local sorted,sort_reason=pcall(send,"reorder-preset",{name="Captured",offset=-1})
        assert(not sorted and sort_reason:find("disk full",1,true))
        S.equal(names(snapshot().presets),before_order)
        S.equal(data["ArmorVariantManager/armor.json"].preset_order,before_order)
        assert(snapshot().selectedPreset==sorting_selected and #applied==sorting_applied,"failed sorting retains selection and appearance")
        write_failed=false
        local before_writes=#writes
        assert(not pcall(send,"reorder-preset",{name="Show",offset=-1}))
        assert(not pcall(send,"reorder-preset",{name="Missing",offset=1}))
        assert(not pcall(send,"reorder-preset",{name="Hide",offset=0}))
        assert(not pcall(dispatch,{kind="reorder-preset",name="Hide",offset=-1,bodyId="old"}))
        assert(not pcall(send,"reorder-preset",{name="Hide",target="Show",after=false,group="Cape",weapon=false}))
        assert(not pcall(send,"reorder-preset",{name="Hide",target="Show",after=false,group="",weapon=true}))
        assert(not pcall(send,"reorder-preset",{name="Hide",target="Missing",after=false,group="",weapon=false}))
        assert(not pcall(dispatch,{kind="reorder-preset",name="Hide",target="Show",after=false,group="",weapon=false,bodyId="old"}))
        assert(#writes==before_writes,"invalid or stale sorting must not write")
        current=send("reorder-preset",{name="Captured",offset=1})
        current=send("material",{part=0,name="cloth",enabled=false})
        assert(not visible and current.parts[1].materials[1].enabled==false)
        assert(not pcall(send,"material",{part=0,name="absent",enabled=true}))
        assert(not pcall(dispatch,{kind="save",name="stale",bodyId="old"}))
        assert(#current.conditions.definitions==(game=="mhrise" and 10 or 12))
        assert(current.conditions.canEnable==(game=="mhrise"))
        assert(current.conditions.canTestHp==(game=="mhwilds"))
        current=send("condition",{op="parallel",value=true})
        assert(current.conditions.parallel and data["ArmorVariantManager/armor.json"].is_parallel)
        assert(current.parts[1].materials[1].enabled==false,"condition editing preserves manual intent")
        current=send("condition",{op="target_add",condition="weapon",rule=1})
        local function weapon_rule(value)
            for _,definition in ipairs(value.conditions.definitions) do
                if definition.id=="weapon" then return definition.rules[1] end
            end
        end
        local target=weapon_rule(current).targets[1]
        local before=target.preset
        write_failed=true
        local applied_before = #applied
        local ok, reason = pcall(send,"condition",{op="target_set",condition="weapon",rule=1,target=1,field="preset",value="Hide"})
        assert(not ok and reason:find("disk full",1,true),"storage error reaches the page")
        assert(#applied==applied_before,"failed save does not refresh appearance")
        assert(weapon_rule(snapshot()).targets[1].preset==before,"failed condition save restores same config")
        write_failed=false
        current=send("condition",{op="target_set",condition="weapon",rule=1,target=1,field="preset",value="Show"})
        local saved_condition=data["ArmorVariantManager/armor.json"]
        assert(saved_condition.weapon_transform_rules[1].targets[1].preset=="Show" and saved_condition.extra.keep)
        assert(not pcall(dispatch,{kind="condition",op="parallel",value=false,bodyId="old"}))
        assert(snapshot().conditions.parallel,"stale request cannot edit current condition")
        if game=="mhrise" then
            current=send("condition",{op="enabled",value=true})
            assert(current.conditions.enabled and data["ArmorVariantManager/armor.json"].enable_transform)
        else
            assert(not pcall(send,"condition",{op="enabled",value=false}),"Wilds has no added total switch")
            assert(not pcall(send,"condition",{op="test_hp",value=50}),"menu actor cannot receive live HP writes")
        end
        current=send("theme",{value="reff"})
        assert(current.theme=="reff" and data["ArmorVariantManager/GlobalSettings.json"].reff_theme=="reff")
        write_failed=true
        assert(not pcall(send,"theme",{value="custom"}) and snapshot().theme=="reff")
        write_failed=false
        send("selection",{enabled=true})
        send("select-material",{part=0,name="cloth",enabled=true})
        write_failed=true
        assert(not pcall(send,"create-group",{name="Cape",global=false}))
        assert(snapshot().selectionMode and #snapshot().groups==1 and snapshot().pending["0"].cloth)
        write_failed=false
        current=send("create-group",{name="Cape",global=false})
        assert(current.group=="Cape" and #current.groups==2 and not current.selectionMode)
        send("selection",{enabled=true})
        send("select-material",{part=0,name="cloth",enabled=true})
        send("create-group",{name="Layer",global=true})
        send("selection",{enabled=true})
        send("select-material",{part=0,name="metal",enabled=true})
        send("create-group",{name="Trim",global=false})
        send("selection",{enabled=true})
        send("select-material",{part=0,name="cloth",enabled=true})
        send("create-group",{name="Overlay",global=true})
        current=send("group",{name=""})
        S.equal(names(current.parts[1].materials),{"cloth","metal"})
        local owned=current.parts[1].materials[1]
        assert(owned.owner=="Cape" and not owned.editable,"main lists group-owned materials without editing them")
        S.equal(owned.groups,{"Layer","Overlay"})
        assert(current.parts[1].materials[2].owner=="Trim" and not current.parts[1].materials[2].editable)
        local material_applied=#applied
        local edited,edit_reason=pcall(send,"material",{part=0,name="cloth",enabled=true})
        assert(not edited and edit_reason:find("材质不属于当前分组",1,true) and #applied==material_applied)
        current=send("group",{name="Layer"})
        assert(#current.parts[1].materials==1 and current.parts[1].materials[1].owner=="Cape"
            and current.parts[1].materials[1].editable,"global mask edits remain available for overlapping owners")
        send("group",{name="Cape"})
        S.equal(names(snapshot().groups),{"","Layer","Overlay","Cape","Trim"})
        current=send("reorder-group",{name="Cape",offset=1})
        S.equal(names(current.groups),{"","Layer","Overlay","Cape","Trim"})
        S.equal(data["ArmorVariantManager/armor.json"].group_order,{"Layer","Cape","Trim","Overlay"})
        current=send("reorder-group",{name="Layer",offset=1})
        S.equal(data["ArmorVariantManager/armor.json"].group_order,{"Cape","Layer","Trim","Overlay"})
        assert(current.group=="Cape","legacy offsets retain global-group sorting and the current selection")
        current=send("reorder-group",{name="Cape",target="Trim",after=true,group="Cape",weapon=false})
        S.equal(names(current.groups),{"","Layer","Overlay","Trim","Cape"})
        assert(current.group=="Cape","sorting retains current group context")
        S.equal(data["ArmorVariantManager/armor.json"].group_order,{"Layer","Overlay","Trim","Cape"})
        local before_group_order=S.copy(data["ArmorVariantManager/armor.json"].group_order)
        write_failed=true
        sorted,sort_reason=pcall(send,"reorder-group",{name="Cape",target="Trim",after=false,group="Cape",weapon=false})
        assert(not sorted and sort_reason:find("disk full",1,true))
        S.equal(names(snapshot().groups),{"","Layer","Overlay","Trim","Cape"})
        S.equal(data["ArmorVariantManager/armor.json"].group_order,before_group_order)
        assert(snapshot().group=="Cape")
        write_failed=false
        current=send("reorder-group",{name="Cape",target="Trim",after=false,group="Cape",weapon=false})
        S.equal(names(current.groups),{"","Layer","Overlay","Cape","Trim"})
        S.equal(data["ArmorVariantManager/armor.json"].group_order,{"Layer","Overlay","Cape","Trim"})
        assert(data["ArmorVariantManager/armor.json"].groups.Layer and data["ArmorVariantManager/armor.json"].groups.Overlay,
            "normal sorting retains every global group")
        before_writes=#writes
        assert(not pcall(send,"reorder-group",{name="",offset=1}))
        assert(not pcall(send,"reorder-group",{name="Layer",offset=-1}))
        assert(not pcall(send,"reorder-group",{name="Cape",target="",after=true,group="Cape",weapon=false}))
        assert(not pcall(send,"reorder-group",{name="Cape",target="Layer",after=true,group="Cape",weapon=false}))
        assert(not pcall(send,"reorder-group",{name="Layer",target="Trim",after=true,group="Cape",weapon=false}))
        assert(#writes==before_writes,"main group, legacy boundaries and fixed-group drops cannot reorder")
        send("delete-group",{name="Layer"})
        send("delete-group",{name="Overlay"})
        send("delete-group",{name="Trim"})
        send("group",{name="Cape"})
        write_failed=true
        assert(not pcall(send,"delete-group",{name="Cape"}))
        assert(snapshot().group=="Cape" and #snapshot().groups==2)
        write_failed=false
        current=send("delete-group",{name="Cape"})
        assert(current.group=="" and #current.groups==1)
        send("preset",{name="Hide"})
        local previous_default=data["ArmorVariantManager/armor.json"].default_preset
        write_failed_path="ArmorVariantManager/armor.json"
        settings_ok,settings_reason=pcall(send,"setting",{id="auto_set_selected_preset_as_default",value=true})
        assert(not settings_ok and settings_reason:find("disk full",1,true))
        assert(data["ArmorVariantManager/GlobalSettings.json"].auto_set_selected_preset_as_default==true)
        assert(field("auto_set_selected_preset_as_default").value==true)
        assert(data["ArmorVariantManager/armor.json"].default_preset==previous_default,"failed equipment save rolls back only its default")
        write_failed_path=nil
        before_writes=#writes
        send("setting",{id="auto_set_selected_preset_as_default",value=true})
        assert(data["ArmorVariantManager/armor.json"].default_preset=="Hide","same-value retry applies current default")
        for index=before_writes+1,#writes do
            assert(writes[index]~="ArmorVariantManager/GlobalSettings.json","same-value retry does not rewrite global JSON")
        end
        do
            assert(field("ground_clipping_height_cm").min==-10)
            before_writes=#writes
            send("setting",{id="ground_clipping_enabled",value=true})
            current=send("setting",{id="ground_clipping_height_cm",value=0})
            assert(field("ground_clipping_enabled",current).value==true and field("ground_clipping_height_cm",current).value==0)
            send("setting",{id="ground_clipping_height_cm",value=12.5})
            send("setting",{id="ground_clipping_enabled",value=false})
            current=send("setting",{id="ground_clipping_reset"})
            assert(field("ground_clipping_enabled",current).value==true and field("ground_clipping_height_cm",current).value==0)
            assert(#writes==before_writes,"height edits remain preset drafts")
            assert(not pcall(dispatch,{kind="setting",id="ground_clipping_height_cm",value=5,bodyId="old"}))
            send("save",{name="HeightZero"})
            local height=data["ArmorVariantManager/armor.json"].presets.HeightZero.ground_clipping_fix
            assert(height.enabled and height.height_cm==0,"preset capture persists checked zero height")
        end
        -- 忽略后保存会更新备份，手动恢复使用此刻的磁盘备份。
        local latest_backup=S.copy(data["ArmorVariantManager/backup/armor.json"])
        current=send("restore")
        assert(not current.backupPending and #current.groups==1)
        S.equal(names(current.presets),latest_backup.preset_order)
        S.equal(data["ArmorVariantManager/armor.json"],latest_backup,"restore writes the current backup and retains unknown fields")
        local file_list=handlers["monkeysama.avm.imports"]()
        assert(current.canImport==(game=="mhrise") and file_list.bodyId=="armor")
        if game=="mhrise" then
            assert(#file_list.files==2,"manual candidates include JSON and backup even with existing presets")
            local imported={presets={Imported={["0"]={materials={cloth=false}}}},preset_order={"Imported"},
                default_preset="Imported",groups={Other={presets={},materials={}}},group_order={"Other"},
                enable_transform=false,foreign={keep="source"}}
            data["ArmorVariantManager/manual_source.json"]=S.copy(imported)
            data["ArmorVariantManager/backup/manual_backup.json"]=S.copy(latest_backup)
            local previous=S.copy(data["ArmorVariantManager/armor.json"])
            send("selection",{enabled=true})
            send("select-material",{part=0,name="cloth",enabled=true})
            local before_import=snapshot()
            local before_applied=S.copy(applied[#applied])
            write_failed_path="ArmorVariantManager/armor.json"
            local imported_ok,import_reason=pcall(send,"import-preset",{path="ArmorVariantManager/manual_source.json"})
            assert(not imported_ok and import_reason:find("disk full",1,true))
            S.equal(snapshot(),before_import,"failed import retains selection, draft and config")
            S.equal(data["ArmorVariantManager/armor.json"],previous)
            frames[1]()
            S.equal(applied[#applied],before_applied,"failed import restores session cache before the next frame")
            write_failed_path=nil
            current=send("import-preset",{path="ArmorVariantManager/manual_source.json"})
            assert(not current.selectionMode and next(current.pending)==nil and current.group=="")
            assert(current.selectedPreset=="Imported" and #current.groups==2)
            assert(data["ArmorVariantManager/armor.json"].foreign.keep=="source")
            assert(data["ArmorVariantManager/armor.json"].longsword_transform_rules)
            assert(applied[#applied]["0"].materials.cloth==false,"import immediately applies its default")
            assert(not pcall(dispatch,{kind="import-preset",bodyId="old",path="ArmorVariantManager/manual_source.json"}))
            data["ArmorVariantManager/invalid.json"]="not a config"
            assert(not pcall(send,"import-preset",{path="ArmorVariantManager/invalid.json"}))
            assert(snapshot().selectedPreset=="Imported","read errors retain imported equipment")
            for index,file in ipairs(file_list.files) do
                if file.path=="ArmorVariantManager/backup/manual_backup.json" then native_file_index=index end
            end
            action="manual-open"; draws[1](); assert(action==nil)
            action="manual-select"; draws[1](); assert(action==nil)
            write_failed_path="ArmorVariantManager/armor.json"
            action="manual-load"; draws[1](); assert(action==nil)
            assert(snapshot().selectedPreset=="Imported","native failed import retains the current config")
            write_failed_path=nil
            action="manual-load"; draws[1](); assert(action==nil)
            current=snapshot()
            S.equal(data["ArmorVariantManager/armor.json"],latest_backup,"native and REFF use the same backup file transaction")
        else assert(#file_list.files==0,"Wilds does not gain Rise-only import") end
        send("mode",{weapon=true})
        assert(snapshot().bodyId=="","mode transition never pairs old config with new equipment")
        assert(not snapshot().backupPending and #documentation().sections==3,"empty equipment can read help without stale warning")
        if game=="mhwilds" then
            current=dispatch({kind="setting",id="body_id_ttl",value=2})
            assert(current.bodyId=="" and field("body_id_ttl",current).value==2,"empty equipment retains global settings")
        else
            current=dispatch({kind="setting",id="enable_multiplayer",value=true})
            assert(current.bodyId=="" and field("enable_multiplayer",current).value,"empty equipment retains global settings")
        end
        if game=="mhwilds" then
            assert(field("ground_clipping_height_cm",current).disabled)
            assert(not pcall(dispatch,{kind="setting",id="ground_clipping_height_cm",value=5,bodyId="armor"}))
        else
            weapon_id="wp_sword"
            data["ArmorVariantManager/wp_sword.json"]=S.copy(cfg)
            frames[1]()
            assert(snapshot().bodyId==weapon_id and snapshot().weapon)
            current=dispatch({kind="import-preset",bodyId=weapon_id,path="ArmorVariantManager/manual_source.json"})
            assert(current.selectedPreset=="Imported" and current.weapon)
            assert(data["ArmorVariantManager/wp_sword.json"].foreign.keep=="source")
            assert(applied_weapons[#applied_weapons]["0"].materials.cloth==false,"manual weapon import applies through its own slot")
            S.equal(data["ArmorVariantManager/armor.json"],latest_backup,"weapon import leaves armor configuration intact")
        end
    else assert(not handlers,"native core still starts without REFF") end
    for _, fn in ipairs(resets) do fn() end
    if game == "unknown" then
        assert(#errors==1 and #frames==0 and #draws==1)
        for name in pairs(imports) do assert(not name:find("Games%.")) end
    else
        assert(#errors==expected_errors,table.concat(errors,"\n"))
        assert(#frames>0 and #draws==1)
        local forbidden = game == "mhrise" and "Wilds" or "Rise"
        for name in pairs(package.loaded) do
            assert(not name:find("Games."..forbidden,1,true),name)
        end
        assert(imports["ArmorVariantManager_Core.Games."..(game=="mhrise" and "Rise" or "Wilds")..".ImGuiConditions"])
        if game=="mhrise" then
            assert(not imports["ArmorVariantManager_Core.UI.VariantManagerUI"])
            assert(not package.loaded["ArmorVariantManager_Core.Games.Wilds.GroundClippingFix"])
        end
    end
    if populated then assert(unregistered,"reset unregisters REFF methods") end
    _G.require = native_require
    package.path = startup_package_path
end
print("PASS: actual dual-game entry, conditions/settings/sorting, backup/help after host search-path reset, manual armor/weapon import and stale/empty-scene/reset guards")
