package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local prefix = "ArmorVariantManager_Core.UI.Reff."
local Controller = require(prefix .. "Controller")
local Parts = require(prefix .. "Parts")
local bridge_path = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/UI/Reff/Bridge.lua"
local height_path = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Wilds/HeightSettings.lua"
local failures, passed = {}, 0

local function test(name, run)
    local ok, reason = pcall(run)
    if ok then passed=passed+1 else failures[#failures+1]=name .. ": " .. tostring(reason) end
end

local function rejects(run, reason)
    local ok, error_message = pcall(run)
    assert(not ok and tostring(error_message):find(reason, 1, true), tostring(error_message))
end

-- 检查 JSON 的值、键和数组形状，并排除不会携带字段的空引擎对象。
local function serializable(value, forbidden, seen, path)
    path = path or "snapshot"
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return end
    if kind == "number" then
        assert(value == value and math.abs(value) < math.huge, path .. ": non-finite number")
        return
    end
    assert(kind == "table", path .. ": " .. kind)
    assert(not forbidden[value], path .. ": engine/context object leaked")
    assert(getmetatable(value) == nil, path .. ": metatable leaked")
    seen = seen or {}
    assert(not seen[value], path .. ": cycle")
    seen[value] = true
    local strings, numbers, last = 0, 0, 0
    for key, item in pairs(value) do
        if type(key) == "string" then strings=strings+1 else
            assert(type(key) == "number" and key >= 1 and key % 1 == 0, path .. ": invalid key")
            numbers=numbers+1; last=math.max(last,key)
        end
        serializable(item, forbidden, seen, path .. "." .. tostring(key))
    end
    assert(strings == 0 or numbers == 0, path .. ": mixed object/array")
    assert(numbers == last, path .. ": sparse array")
    seen[value] = nil
end

local function controller_fixture(game)
    local context = {id="armor", weapon=false, suspended=false, group="", selected="Base", selecting=false,
        group_names={"Local","Global"}, preset_names={"Base","Other"},
        config={default_preset="Base",groups={Local={is_global=false,default_preset="LocalBase"},
            Global={is_global=true}}}, pending={[7]={cloth=true,metal=false}}, character={}, player={},
        baseline={}, internal=function() end}
    local state = {context=context,theme="custom",operations={},parts_calls=0,theme_writes=0,mode_writes=0}
    local deps = {game=game,version="test",context=function() return state.context end,
        theme=function() return state.theme end,language=function() return "en" end,
        main_label=function() return "Main" end,
        set_theme=function(value) state.theme=value;state.theme_writes=state.theme_writes+1;return true end,
        set_mode=function(value) state.context.weapon=value;state.mode_writes=state.mode_writes+1 end,
        parts=function(received)
            assert(received == state.context and received.id)
            state.parts_calls=state.parts_calls+1
            return {{index=7,label="Part",available=true,enabled=true,materials={}}}
        end,operations=state.operations}
    state.controller=Controller.new(deps)
    state.deps=deps
    state.forbidden={[context]=true,[context.character]=true,[context.player]=true,[context.baseline]=true,
        [context.config]=true,[context.pending]=true,[context.pending[7]]=true}
    return state
end

for _, game in ipairs({"Wilds","Rise"}) do
    test(game .. " serializable detached snapshot", function()
        local f=controller_fixture(game)
        local snapshot=f.controller.snapshot()
        serializable(snapshot,f.forbidden)
        assert(snapshot.game == game and snapshot.bodyId == "armor" and snapshot.selectedPreset == "Base")
        S.equal(snapshot.groups,{{name="",label="Main",global=false},{name="Global",label="Global",global=true},
            {name="Local",label="Local",global=false}})
        S.equal(snapshot.presets,{{name="Base",default=true,active=true},{name="Other",default=false,active=false}})
        S.equal(snapshot.pending,{["7"]={cloth=true,metal=false}})
        snapshot.pending["7"].cloth=false
        assert(f.context.pending[7].cloth == true,"snapshot edits changed pending selections")
        f.context.pending[7].metal=true
        assert(snapshot.pending["7"].metal == false,"pending selections changed an old snapshot")
        f.context.group="Local";f.context.selected="LocalBase";f.context.preset_names={"LocalBase"}
        local grouped=f.controller.snapshot()
        assert(grouped.group == "Local" and grouped.presets[1].default and grouped.presets[1].active)
    end)

    test(game .. " empty scene and non-equipment actions", function()
        local f=controller_fixture(game)
        f.context.id=nil;f.context.config=nil;f.context.pending=nil
        f.deps.parts=function() error("empty scene queried parts") end
        setmetatable(f.operations,{__index=function() error("non-equipment action queried operations") end})
        local empty=f.controller.snapshot()
        serializable(empty,f.forbidden)
        assert(empty.bodyId == "" and #empty.groups == 0 and #empty.presets == 0 and #empty.parts == 0)
        S.equal(empty.pending,{})
        assert(f.controller.action({kind="theme",value="reff"}).theme == "reff")
        assert(f.controller.action({kind="mode",weapon=true}).weapon == true)
        assert(f.theme_writes == 1 and f.mode_writes == 1 and f.parts_calls == 0)
        rejects(function() f.controller.action({kind="theme",value="unknown"}) end,"主题选项无效")
        rejects(function() f.controller.action({kind="mode",weapon="true"}) end,"装备模式无效")
    end)

    test(game .. " manual import capability defaults to unavailable without scanning", function()
        local f=controller_fixture(game)
        assert(f.controller.snapshot().canImport == false)
        f.deps.parts=function() error("import list queried equipment parts") end
        setmetatable(f.operations,{__index=function() error("import list queried equipment operations") end})
        local unavailable=f.controller.imports()
        serializable(unavailable,f.forbidden)
        S.equal(unavailable,{bodyId="armor",files={}})
        f.context.id=nil
        assert(f.controller.snapshot().canImport == false)
        S.equal(f.controller.imports(),{bodyId="",files={}})
    end)

    test(game .. " manual import list is on demand, detached and follows the current context", function()
        local f=controller_fixture(game)
        local armor_files={{path="ArmorVariantManager/other.json",name="Other",config=f.context.config},
            {path="ArmorVariantManager/backup/other.json",name="[备份] Other",object=f.context.character}}
        local weapon_files={{path="ArmorVariantManager/weapon.json",name="Weapon"}}
        local requested={}
        f.deps.imports=function(context)
            assert(context == f.context)
            requested[#requested+1]={id=context.id,weapon=context.weapon}
            return context.weapon and weapon_files or armor_files
        end
        assert(f.controller.snapshot().canImport == true and #requested == 0,"snapshot scanned preset files eagerly")
        f.deps.parts=function() error("import list queried equipment parts") end
        for _, files in ipairs({armor_files,weapon_files}) do
            f.forbidden[files]=true
            for _, file in ipairs(files) do f.forbidden[file]=true end
        end
        local list=f.controller.imports()
        serializable(list,f.forbidden)
        S.equal(list,{bodyId="armor",files={{path="ArmorVariantManager/other.json",name="Other"},
            {path="ArmorVariantManager/backup/other.json",name="[备份] Other"}}})
        list.files[1].name="Edited in web UI"
        assert(armor_files[1].name == "Other","returned import row aliases a scanner row")
        armor_files[2].name="Changed on disk"
        assert(list.files[2].name == "[备份] Other","scanner changed an already returned import row")
        list.files[3]={path="web-only.json",name="Web only"}
        assert(#armor_files == 2,"returned import array aliases the scanner array")
        f.context={id="weapon",weapon=true,suspended=false}
        f.forbidden[f.context]=true
        local weapons=f.controller.imports()
        serializable(weapons,f.forbidden)
        S.equal(weapons,{bodyId="weapon",files={{path="ArmorVariantManager/weapon.json",name="Weapon"}}})
        S.equal(requested,{{id="armor",weapon=false},{id="weapon",weapon=true}})
    end)

    test(game .. " empty and suspended actors never scan manual import files", function()
        local f=controller_fixture(game)
        f.deps.imports=function() error("unavailable actor scanned import files") end
        f.context.id=nil
        assert(f.controller.snapshot().canImport == true,"actor availability changed the capability flag")
        S.equal(f.controller.imports(),{bodyId="",files={}})
        f.context.id="armor";f.context.suspended=true
        assert(f.controller.snapshot().canImport == true)
        S.equal(f.controller.imports(),{bodyId="armor",files={}})
    end)

    test(game .. " manual import scan and operation errors retain their causes", function()
        local f=controller_fixture(game)
        f.deps.imports=function(context)
            assert(context == f.context)
            error("预设扫描失败: access denied")
        end
        rejects(function() f.controller.imports() end,"预设扫描失败: access denied")
        local request={kind="import-preset",bodyId="armor",path="ArmorVariantManager/other.json"}
        f.operations["import-preset"]=function(received,context)
            assert(received == request and context == f.context)
            return false,"预设导入失败: disk full"
        end
        rejects(function() f.controller.action(request) end,"预设导入失败: disk full")
        f.operations["import-preset"]=function() error("预设读取失败: invalid JSON") end
        rejects(function() f.controller.action(request) end,"预设读取失败: invalid JSON")
        f.operations["import-preset"]=function(received,context)
            assert(received == request and context == f.context)
            return true
        end
        assert(f.controller.action(request).bodyId == "armor")
    end)

    test(game .. " backup notice follows the current equipment and defaults to false", function()
        local f=controller_fixture(game)
        assert(f.controller.snapshot().backupPending == false,"missing backup dependency must default to false")
        local pending={armor=true,["other-armor"]=false,weapon=true}
        local requested={}
        f.deps.backup_pending=function(id)
            assert(id == f.context.id)
            requested[#requested+1]=id
            return pending[id]
        end
        local initial=f.controller.snapshot()
        assert(initial.bodyId == "armor" and initial.backupPending == true)
        f.context.id="other-armor"
        local other=f.controller.snapshot()
        assert(other.bodyId == "other-armor" and other.backupPending == false)
        f.context.id="weapon";f.context.weapon=true
        local weapon=f.controller.snapshot()
        assert(weapon.bodyId == "weapon" and weapon.backupPending == true)
        S.equal(requested,{"armor","other-armor","weapon"})
        f.context.id=nil
        f.deps.backup_pending=function() error("empty scene queried equipment backup") end
        local empty=f.controller.snapshot()
        assert(empty.bodyId == "" and empty.backupPending == false)
        assert(initial.backupPending == true and other.backupPending == false)
    end)

    test(game .. " backup dismissal is guarded and affects only the requested equipment", function()
        local f=controller_fixture(game)
        local pending={armor=true,["other-armor"]=true}
        local dismissed={}
        f.deps.backup_pending=function(id) return pending[id] end
        f.operations["dismiss-backup"]=function(request,context)
            assert(request.bodyId == context.id and context == f.context)
            dismissed[#dismissed+1]=context.id
            pending[context.id]=false
            return true
        end
        rejects(function() f.controller.action({kind="dismiss-backup",bodyId="other-armor"}) end,"装备已变化")
        f.context.suspended=true
        rejects(function() f.controller.action({kind="dismiss-backup",bodyId="armor"}) end,"角色不可用或正在切换装备")
        f.context.suspended=false;f.context.id=nil
        rejects(function() f.controller.action({kind="dismiss-backup",bodyId="armor"}) end,"角色不可用或正在切换装备")
        assert(#dismissed == 0 and pending.armor and pending["other-armor"])
        f.context.id="armor"
        local result=f.controller.action({kind="dismiss-backup",bodyId="armor"})
        assert(result.backupPending == false and pending["other-armor"])
        f.context.id="other-armor"
        rejects(function() f.controller.action({kind="dismiss-backup",bodyId="armor"}) end,"装备已变化")
        assert(f.controller.snapshot().backupPending == true)
        S.equal(dismissed,{"armor"})
    end)

    test(game .. " documentation is requested on demand without an actor and uses the current language", function()
        local f=controller_fixture(game)
        f.context.id=nil;f.context.suspended=true;f.context.config=nil;f.context.pending=nil
        local language,reads="zh",0
        f.deps.language=function() return language end
        f.deps.documentation=function()
            reads=reads+1
            return {sections={{title=language,content={"help:" .. language}}}}
        end
        setmetatable(f.operations,{__index=function() error("documentation queried equipment operations") end})
        local snapshot=f.controller.snapshot()
        assert(reads == 0 and snapshot.documentation == nil,"snapshot loaded documentation eagerly")
        local chinese=f.controller.documentation()
        serializable(chinese,f.forbidden)
        S.equal(chinese,{sections={{title="zh",content={"help:zh"}}}})
        language="en"
        S.equal(f.controller.documentation(),{sections={{title="en",content={"help:en"}}}})
        assert(reads == 2 and chinese.sections[1].title == "zh" and f.parts_calls == 0)
    end)

    test(game .. " settings remain visible without an actor and preserve theme/mode actions", function()
        local f=controller_fixture(game)
        f.context.id=nil;f.context.config=nil;f.context.pending=nil
        local settings={sections={{id="general",scope="global",fields={{id="language",value="en"}}}}}
        local reads=0
        f.deps.settings={snapshot=function(context)
            assert(context == f.context)
            reads=reads+1
            return settings
        end,action=function() error("theme/mode dispatched a setting action") end}
        setmetatable(f.operations,{__index=function() error("settings queried equipment operations") end})
        local empty=f.controller.snapshot()
        serializable(empty,f.forbidden)
        S.equal(empty.settings,settings)
        assert(empty.bodyId == "" and #empty.parts == 0 and reads == 1)
        assert(f.controller.action({kind="theme",value="reff"}).theme == "reff")
        assert(f.controller.action({kind="mode",weapon=true}).weapon == true)
        assert(f.theme_writes == 1 and f.mode_writes == 1 and reads == 3 and f.parts_calls == 0)
    end)

    test(game .. " settings dispatch independently and preserve failure reasons", function()
        local f=controller_fixture(game)
        f.context.id=nil;f.context.suspended=true
        local request={kind="setting",id="language",value="zh",bodyId="old-armor"}
        local dispatched=0
        f.deps.settings={snapshot=function(context) assert(context == f.context);return {sections={}} end,
            action=function(received,context)
                assert(received == request and context == f.context)
                dispatched=dispatched+1
                return true
            end}
        setmetatable(f.operations,{__index=function() error("setting queried equipment operations") end})
        S.equal(f.controller.action(request).settings,{sections={}})
        assert(dispatched == 1)
        f.deps.settings.action=function() return false,"设置写入失败: access denied" end
        rejects(function() f.controller.action(request) end,"设置写入失败: access denied")
        f.deps.settings.action=function() error("设置应用失败: native unavailable") end
        rejects(function() f.controller.action(request) end,"设置应用失败: native unavailable")
        f.deps.settings.action=function() return false end
        rejects(function() f.controller.action(request) end,"设置未保存，请重试")
        f.deps.settings=nil
        rejects(function() f.controller.action(request) end,"设置不可用")
    end)

    test(game .. " stale equipment and hover are rejected before dispatch", function()
        local f=controller_fixture(game)
        local dispatched=0
        for _, kind in ipairs({"select","hover","import-preset"}) do
            f.operations[kind]=function() dispatched=dispatched+1;return true end
            rejects(function() f.controller.action({kind=kind,bodyId="old-armor"}) end,"装备已变化")
            f.context.suspended=true
            rejects(function() f.controller.action({kind=kind,bodyId="armor"}) end,"角色不可用或正在切换装备")
            f.context.suspended=false;f.context.id=nil
            rejects(function() f.controller.action({kind=kind,bodyId="armor"}) end,"角色不可用或正在切换装备")
            f.context.id="armor"
        end
        assert(dispatched == 0)
        f.controller.action({kind="select",bodyId="armor"})
        assert(dispatched == 1)
    end)

    test(game .. " operation failure reasons reach the caller", function()
        local f=controller_fixture(game)
        local request={kind="save",bodyId="armor",name="Captured"}
        f.operations.save=function(received,context)
            assert(received == request and context == f.context)
            return false,"磁盘写入失败: access denied"
        end
        rejects(function() f.controller.action(request) end,"磁盘写入失败: access denied")
        f.operations.save=function() error("网格已失效") end
        rejects(function() f.controller.action(request) end,"网格已失效")
        f.operations.save=function() return false end
        rejects(function() f.controller.action(request) end,"操作未保存，请重试")
        f.deps.set_theme=function() return false end
        rejects(function() f.controller.action({kind="theme",value="reff"}) end,"主题保存失败")
    end)
end

local function height_fixture()
    local f={value={enabled=true,height_cm=-2.5},reads=0,status_reads=0,writes={},persisted=0,set_ok=true}
    local function persist()
        f.persisted=f.persisted+1
        error("height draft persisted global settings")
    end
    local env=setmetatable({json={dump_file=persist}}, {__index=_G})
    env._G=env
    local HeightSettings=assert(loadfile(height_path,"t",env))()
    f.model=HeightSettings.new({translate=function(key) return "tr:" .. key end,
        get=function()
            f.reads=f.reads+1
            if f.get_error then error(f.get_error) end
            return f.value
        end,
        status=function()
            f.status_reads=f.status_reads+1
            if f.status_error then error(f.status_error) end
            return f.status
        end,
        set=function(patch,body_id)
            f.writes[#f.writes+1]={patch=S.copy(patch),bodyId=body_id}
            if f.set_error then error(f.set_error) end
            if f.set_ok then for key,value in pairs(patch) do f.value[key]=value end end
            return f.set_ok,f.set_reason
        end,
        save=persist,global_session={save=persist}})
    return f
end

test("Wilds height draft exposes equipment-scoped controls and live status", function()
    local f=height_fixture()
    local context={id="armor",weapon=false,suspended=false}
    assert(f.model.handles("ground_clipping_enabled") and f.model.handles("ground_clipping_height_cm"))
    assert(not f.model.handles("language") and not f.model.handles(nil))
    local section=f.model.snapshot(context)
    serializable(section,{[context]=true,[f.value]=true})
    assert(section.id == "ground_clipping" and section.scope == "equipment")
    assert(section.label == "tr:heel_title" and section.description == "tr:heel_description")
    S.equal(section.fields,{{id="ground_clipping_enabled",label="tr:heel_enable",type="boolean",value=true,disabled=false},
        {id="ground_clipping_height_cm",label="tr:heel_height",type="number",value=-2.5,
            min=-10,max=50,step=0.1,disabled=false},
        {id="ground_clipping_reset",label="tr:heel_reset_short",type="action",disabled=false}})
    f.value={enabled=false,height_cm=0}
    f.status={key="heel_error",error="target transform unavailable"}
    local updated=f.model.snapshot(context)
    assert(updated.fields[1].value == false and updated.fields[2].value == 0)
    assert(updated.description == "tr:heel_error: target transform unavailable\ntr:heel_description")
    assert(section.fields[1].value == true and section.fields[2].value == -2.5)
    assert(f.reads == 2 and f.status_reads == 2 and #f.writes == 0 and f.persisted == 0)
end)

test("Wilds height reset enables a zero draft in one call and retains failure guards", function()
    local f=height_fixture()
    assert(f.model.handles("ground_clipping_reset"))
    local context={id="armor",weapon=false,suspended=false}
    f.value={enabled=false,height_cm=15}
    assert(f.model.action({id="ground_clipping_reset",bodyId="armor"},context))
    S.equal(f.writes,{{patch={enabled=true,height_cm=0},bodyId="armor"}})
    S.equal(f.value,{enabled=true,height_cm=0})
    assert(f.persisted == 0)
    f.set_ok=false; f.set_reason="height target unavailable"
    local ok,reason=f.model.action({id="ground_clipping_reset",bodyId="armor"},context)
    assert(ok == false and reason == f.set_reason)
    local count=#f.writes
    for _, invalid in ipairs({{weapon=false,suspended=false},{id="armor",weapon=true,suspended=false},
        {id="armor",weapon=false,suspended=true},{id="other",weapon=false,suspended=false}}) do
        assert(f.model.action({id="ground_clipping_reset",bodyId="armor"},invalid) == false)
    end
    assert(#f.writes == count and f.persisted == 0)
end)

test("Wilds height availability follows actor, equipment mode and suspension", function()
    for _, context in ipairs({{id="armor",weapon=false,suspended=false},
        {weapon=false,suspended=false},{id="weapon",weapon=true,suspended=false},
        {id="armor",weapon=false,suspended=true}}) do
        local f=height_fixture()
        local available=context.id ~= nil and not context.weapon and not context.suspended
        local section=f.model.snapshot(context)
        for _, field in ipairs(section.fields) do
            assert(field.disabled == not available)
            assert(field.reason == (not available and "tr:heel_armor_only" or nil))
        end
        assert(f.reads == (available and 1 or 0))
        if not available then
            assert(section.fields[1].value == false and section.fields[2].value == 10)
            local ok,reason=f.model.action({id="ground_clipping_enabled",value=true,bodyId=context.id},context)
            assert(ok == false and reason == "tr:heel_armor_only" and #f.writes == 0)
        end
        assert(f.persisted == 0)
    end
end)

test("Wilds height rejects stale equipment and invalid values before setting a draft", function()
    local f=height_fixture()
    local context={id="armor",weapon=false,suspended=false}
    local cases={
        {{id="ground_clipping_enabled",value=true,bodyId="old-armor"},"装备已变化，请重新操作"},
        {{id="ground_clipping_enabled",value="true",bodyId="armor"},"高度开关无效"},
        {{id="ground_clipping_enabled",value=0,bodyId="armor"},"高度开关无效"},
        {{id="ground_clipping_enabled",bodyId="armor"},"高度开关无效"},
        {{id="ground_clipping_height_cm",value="0",bodyId="armor"},"高度数值无效"},
        {{id="ground_clipping_height_cm",value=false,bodyId="armor"},"高度数值无效"},
        {{id="ground_clipping_height_cm",bodyId="armor"},"高度数值无效"},
        {{id="ground_clipping_height_cm",value=0/0,bodyId="armor"},"高度数值无效"},
        {{id="ground_clipping_height_cm",value=math.huge,bodyId="armor"},"高度数值无效"},
        {{id="ground_clipping_height_cm",value=-math.huge,bodyId="armor"},"高度数值无效"},
        {{id="language",value=true,bodyId="armor"},"设置项不存在"},
    }
    for _, case in ipairs(cases) do
        local ok,reason=f.model.action(case[1],context)
        assert(ok == false and reason == case[2],tostring(reason))
        assert(#f.writes == 0 and f.persisted == 0)
    end
end)

test("Wilds height forwards booleans, zero and negative values without global persistence", function()
    local f=height_fixture()
    local context={id="armor",weapon=false,suspended=false}
    for _, case in ipairs({{"ground_clipping_enabled","enabled",true},{"ground_clipping_enabled","enabled",false},
        {"ground_clipping_height_cm","height_cm",0},{"ground_clipping_height_cm","height_cm",-2.5}}) do
        local ok,reason=f.model.action({id=case[1],value=case[3],bodyId="armor"},context)
        assert(ok == true and reason == nil)
        S.equal(f.writes[#f.writes],{patch={[case[2]]=case[3]},bodyId="armor"})
        assert(f.value[case[2]] == case[3] and f.persisted == 0)
    end
    assert(#f.writes == 4 and f.reads == 0)
end)

test("Wilds height preserves actual get, status and set failure reasons", function()
    local f=height_fixture()
    local context={id="armor",weapon=false,suspended=false}
    f.get_error="draft read failed: config unavailable"
    rejects(function() f.model.snapshot(context) end,f.get_error)
    f.get_error=nil;f.status_error="status read failed: native unavailable"
    rejects(function() f.model.snapshot(context) end,f.status_error)
    f.status_error=nil;f.set_ok=false;f.set_reason="draft rejected: equipment changed"
    local request={id="ground_clipping_height_cm",value=0,bodyId="armor"}
    local ok,reason=f.model.action(request,context)
    assert(ok == false and reason == f.set_reason)
    f.set_error="draft apply failed: native target missing"
    rejects(function() f.model.action(request,context) end,f.set_error)
    assert(f.persisted == 0)
end)

local function parts_fixture(game, weapon)
    local mesh={enabled=false,names={"cloth","cloth","global","outside"},values={true,false,false,true}}
    local valid={mesh=mesh};local missing={};local invalid={invalid=true,mesh=mesh}
    local rows={{index="7",label="Sparse weapon",object=valid},
        {index=0,label="Rebuilding",object=missing},{index=2,label="Departed",object=invalid},
        {text="Not equipped"}}
    local context={character={},player={},weapon=weapon,baseline={},selecting=false}
    local translate=function(key) return key end
    local access={weapon_mesh_locked=game == "Rise",valid=function(object) return not object.invalid end,
        mesh=function(object) assert(not object.invalid);return object.mesh end,
        call=function(object,method,index)
            assert(object == mesh,"unexpected component")
            if method == "get_Enabled" then return object.enabled end
            if method == "get_MaterialNum" then return #object.names end
            if method == "getMaterialName" then return object.names[index+1] end
            if method == "getMaterialsEnable" then return object.values[index+1] end
            error("unexpected mesh operation: " .. method)
        end}
    local parts=Parts.new({access=access,translate=translate,
        collect=function(character,player,is_weapon,baseline,tr)
            assert(character == context.character and player == context.player and is_weapon == context.weapon
                and baseline == context.baseline and tr == translate)
            return rows
        end,
        contains=function(index,name) assert(index == 7);return name ~= "outside" end,
        hidden=function(index,name) assert(index == 7);return name == "global" end,
        global_names=function(index,name) assert(index == 7);return name == "global" and {"Hide"} or {} end})
    local forbidden={[mesh]=true,[valid]=true,[missing]=true,[invalid]=true,[context.character]=true,
        [context.player]=true,[context.baseline]=true,[rows]=true}
    return {parts=parts,context=context,rows=rows,mesh=mesh,valid=valid,forbidden=forbidden}
end

for _, game in ipairs({"Wilds","Rise"}) do
    for _, weapon in ipairs({false,true}) do
        local name=game .. (weapon and " weapon" or " armor")
        test(name .. " materials are filtered, deduplicated and value-only", function()
            local f=parts_fixture(game,weapon)
            local snapshot=f.parts.snapshot(f.context)
            serializable(snapshot,f.forbidden)
            assert(snapshot[1].index == 7 and snapshot[1].available)
            assert(snapshot[1].meshLocked == (game == "Rise" and weapon))
            assert(snapshot[1].enabled == (game == "Rise" and weapon))
            S.equal(snapshot[1].materials,{{name="cloth",enabled=true,hidden=false,groups={}},
                {name="global",enabled=false,hidden=true,groups={"Hide"}}})
            f.context.selecting=true
            local selection=f.parts.snapshot(f.context)
            assert(#selection[1].materials == 3 and selection[1].materials[3].name == "outside")
        end)

        test(name .. " manual material intent takes priority over rendered visibility", function()
            local f=parts_fixture(game,weapon)
            f.context.selecting=true
            f.context.baseline["7"]={materials={cloth=false,global=true}}
            local snapshot=f.parts.snapshot(f.context)
            S.equal(snapshot[1].materials,{{name="cloth",enabled=false,hidden=false,groups={}},
                {name="global",enabled=true,hidden=true,groups={"Hide"}},
                {name="outside",enabled=true,hidden=false,groups={}}})
            f.context.baseline["7"].materials.global=nil
            local fallback=f.parts.snapshot(f.context)
            assert(fallback[1].materials[1].enabled == false,"manual false fell back to rendered true")
            assert(fallback[1].materials[2].enabled == false and fallback[1].materials[2].hidden,
                "missing intent did not fall back to rendered false")
            assert(fallback[1].materials[3].enabled == true,"missing intent did not fall back to rendered true")
        end)

        test(name .. " missing components stay unavailable and sparse find stays fresh", function()
            local f=parts_fixture(game,weapon)
            local snapshot=f.parts.snapshot(f.context)
            assert(#snapshot == 4 and snapshot[2].index == 0 and snapshot[3].index == 2 and snapshot[4].index == -4)
            for index=2,4 do
                assert(snapshot[index].available == false,"missing/invalid mesh reported available at row " .. index)
                assert(snapshot[index].enabled == false and #snapshot[index].materials == 0)
            end
            local mesh,row=f.parts.find(f.context,7)
            assert(mesh == f.mesh and row == f.rows[1])
            assert(f.parts.find(f.context,0) == nil and f.parts.find(f.context,2) == nil and f.parts.find(f.context,6) == nil)
            local replacement={}
            f.valid.mesh=replacement
            assert(f.parts.find(f.context,7) == replacement,"find retained an obsolete mesh")
        end)
    end
end

local function bridge_fixture(native, sdk_loader)
    local resets,errors={},{}
    local env=setmetatable({reff_native=native,require=sdk_loader,
        log={error=function(message) errors[#errors+1]=message end},
        re={on_script_reset=function(callback) resets[#resets+1]=callback end}}, {__index=_G})
    env._G=env
    return assert(loadfile(bridge_path,"t",env))(),resets,errors
end

test("missing REFF native never loads SDK or registers hooks", function()
    local bridge,resets,errors=bridge_fixture(nil,function() error("SDK must not be loaded") end)
    assert(bridge.register({}) == nil and #resets == 0 and #errors == 0)
end)

test("missing REFF SDK reports its cause without blocking native UI", function()
    local bridge,resets,errors=bridge_fixture({},function(name)
        assert(name == "reff.sdk");error("module 'reff.sdk' not found")
    end)
    assert(bridge.register({}) == nil and #resets == 0 and #errors == 1)
    assert(errors[1]:find("module 'reff.sdk' not found",1,true))
end)

test("failed SDK registration reports its cause without blocking native UI", function()
    local bridge,resets,errors=bridge_fixture({},function(name)
        assert(name == "reff.sdk")
        return {register=function() error("REFF plugin registration rejected") end}
    end)
    assert(bridge.register({}) == nil and #resets == 0 and #errors == 1)
    assert(errors[1]:find("REFF plugin registration rejected",1,true))
end)

test("isolated SDK registers controller methods and unregisters on reset", function()
    local f=controller_fixture("Rise")
    local documentation_reads,import_reads=0,0
    f.deps.documentation=function()
        documentation_reads=documentation_reads+1
        return {sections={{title="Help",content={"Current-language instructions"}}}}
    end
    f.deps.imports=function(context)
        assert(context == f.context)
        import_reads=import_reads+1
        return {{path="ArmorVariantManager/other.json",name="Other"}}
    end
    local registered,unregistered=0,0
    local handle={unregister=function() unregistered=unregistered+1 end}
    local bridge,resets,errors=bridge_fixture({},function(name)
        assert(name == "reff.sdk")
        return {register=function(id,definition)
            assert(id == "monkeysama.avm")
            S.equal(definition.events,{})
            local methods=definition.methods
            assert(methods["monkeysama.avm.snapshot"] == f.controller.snapshot)
            assert(methods["monkeysama.avm.action"] == f.controller.action)
            assert(methods["monkeysama.avm.documentation"] == f.controller.documentation,"documentation method was not forwarded")
            assert(methods["monkeysama.avm.imports"] == f.controller.imports,"manual import list method was not forwarded")
            local count=0;for _ in pairs(methods) do count=count+1 end;assert(count == 4,"expected four registered methods")
            serializable(methods["monkeysama.avm.snapshot"](),f.forbidden)
            assert(methods["monkeysama.avm.action"]({kind="theme",value="reff"}).theme == "reff")
            assert(documentation_reads == 0 and import_reads == 0)
            local imports=methods["monkeysama.avm.imports"]()
            serializable(imports,f.forbidden)
            S.equal(imports,{bodyId="armor",files={{path="ArmorVariantManager/other.json",name="Other"}}})
            assert(import_reads == 1)
            f.context.id=nil
            S.equal(methods["monkeysama.avm.imports"](),{bodyId="",files={}})
            assert(import_reads == 1,"bridge import list scanned without an actor")
            S.equal(methods["monkeysama.avm.documentation"](),
                {sections={{title="Help",content={"Current-language instructions"}}}})
            assert(documentation_reads == 1)
            registered=registered+1
            return handle
        end}
    end)
    assert(bridge.register(f.controller) == handle and registered == 1 and #errors == 0 and #resets == 1,
        table.concat(errors,"\n"))
    resets[1]()
    assert(unregistered == 1)
end)

assert(#failures == 0, table.concat(failures,"\n"))
print("PASS: REFF controller, part snapshots and isolated SDK lifecycle (" .. passed .. " checks)")
