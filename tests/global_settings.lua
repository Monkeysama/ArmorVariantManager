package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Global = require("ArmorVariantManager_Core.Config.Global")
local path = "ArmorVariantManager/GlobalSettings.json"
local cases = {
    {},
    {language="en", scan_interval=1.2, body_id_ttl=2, scanner_batch_size=400, new_ui_key=0x23},
    {new_ui_enabled=false, auto_set_selected_preset_as_default=false},
    {new_ui_enabled=true, auto_set_selected_preset_as_default=true},
    {enable_image_quality=true, image_quality_rate=1.5, new_ui_mute_game_input=false,
     new_ui_debug_force_visible=true, new_ui_debug_manual_picker=true, debug_profile=true,
     enable_multiplayer=false, multiplayer_players_per_tick=0, scene_scan_batch=4},
    {enable_image_quality=false, image_quality_rate=0.8, new_ui_mute_game_input=true,
     new_ui_debug_force_visible=false, new_ui_debug_manual_picker=false, debug_profile=false,
     enable_multiplayer=true, multiplayer_players_per_tick=8, scene_scan_batch=128},
    {multiplayer_players_per_tick=-1, multiplayer_weapon_scan_interval=0.1, scene_scan_batch=1},
    {multiplayer_players_per_tick=12, multiplayer_weapon_scan_interval=50, scene_scan_batch=200},
    {multiplayer_players_per_tick="2.8", multiplayer_weapon_scan_interval="1.25", scene_scan_batch="32.5"},
    {new_ui_backend="native"}, {new_ui_backend="imgui"}, {new_ui_backend="auto"},
}
for _, game in ipairs({"Wilds", "Rise"}) do
    local schema = require("ArmorVariantManager_Core.Games." .. game .. ".Settings")
    local factory = dofile("tests/fixtures/legacy/" .. game:lower() .. "_settings.lua")
    local function legacy(input)
        local env = {global_config_path=path, safe_json_load=function() return input end,
            json={load_file=function() return input end}}
        local old = factory(setmetatable(env, {__index=_G}))
        old.load()
        return old.value
    end
    for index=0,#cases do
        local input = index > 0 and S.copy(cases[index]) or nil
        local original = S.copy(input)
        local saved, reads, writes, success = nil, 0, 0, true
        local session = Global.new(schema, {
            load=function(p) S.equal(p,path); reads=reads+1; return input end,
            save=function(p,v) S.equal(p,path); writes=writes+1; saved=S.copy(v); return success end,
        })
        S.equal(session.value, legacy(nil), game .. " defaults")
        local identity = session.value
        session.load()
        assert(session.value == identity and reads == 1 and writes == 0)
        local expected = legacy(input)
        -- 崛起原加载器丢弃不认识的字段；共享读写需按兼容约定保留它们。
        if input then
            local known=schema.new()
            for k,v in pairs(input) do if known[k]==nil then expected[k]=v end end
        end
        S.equal(session.value, expected, game .. " case " .. index)
        S.equal(input, original, "input unchanged")
        assert(session.save()); S.equal(saved,expected)
        local roundtrip = Global.new(schema,{load=function() return saved end})
        roundtrip.load(); S.equal(roundtrip.value,expected,game .. " roundtrip")
        success=false; assert(session.save()==false and writes==2, "return write failure")
    end
    local input = {portrait_camera={distance=2.15,refresh_fps=0,extension="keep"},
        custom_extension={retained=false, nested={7,8}}}
    local saved
    local session = Global.new(schema,{load=function() return input end,
        save=function(_,v) saved=S.copy(v); return true end})
    session.load(); session.save()
    S.equal(saved.portrait_camera,input.portrait_camera)
    S.equal(saved.custom_extension,input.custom_extension)
    input={language="en"}; session.load(); session.save()
    assert(saved.custom_extension.nested[2]==8 and saved.portrait_camera.refresh_fps==0)
    local fresh=Global.new(schema); assert(fresh.value.custom_extension==nil)
    fresh.value.language="en"; assert(schema.new().language=="zh")
end

-- 执行正式入口的构造和包装，检查存储、加载顺序及配置引用没有旁路。
local source=S.read("ArmorVariantManager/reframework/autorun/ArmorVariantManager.lua")
local saved, calls=nil,{}
local Store=require("ArmorVariantManager_Core.Config.Store")
local old_load,old_save=Store.load,Store.save
Store.load=function(p) S.equal(p,path); calls[#calls+1]="load"; return {new_ui_enabled=false,language="en"} end
Store.save=function(p,v) S.equal(p,path); calls[#calls+1]="save"; saved=v; return false end
local construct=S.section(source,"local global_settings =", "-- 本地化字典")
local wrappers=S.section(source,"local function load_global_settings()", "-- =============================================================================")
local config,save=assert(load(construct..wrappers.."\nreturn global_config,save_global_settings"))()
S.equal(calls,{"load"}); assert(config.new_ui_enabled==false and config.language=="en")
assert(save()==false and saved==config); S.equal(calls,{"load","save"})
Store.load,Store.save=old_load,old_save
print("PASS: dual-game global defaults, legacy load, unknown fields, roundtrip and entry wiring")
