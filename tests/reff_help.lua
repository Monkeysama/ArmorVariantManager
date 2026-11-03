package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local Documentation = require("ArmorVariantManager_Core.Documentation")
local Localization = require("ArmorVariantManager_Core.Localization")
local Help = require("ArmorVariantManager_Core.UI.Reff.Help")
local failures, passed = {}, 0

local function test(name, run)
    local ok, reason = pcall(run)
    if ok then passed = passed + 1 else failures[#failures + 1] = name .. ": " .. tostring(reason) end
end

local function all_text(section)
    local text = {}
    for _, entry in ipairs(section.entries) do
        text[#text + 1] = entry.title
        for _, paragraph in ipairs(entry.paragraphs) do text[#text + 1] = paragraph end
    end
    return table.concat(text, "\n")
end

local function source_tables(value, result)
    result = result or {}
    if type(value) == "table" then
        result[value] = true
        for _, item in pairs(value) do source_tables(item, result) end
    end
    return result
end

local function plain_detached(value, forbidden)
    if type(value) == "string" then return end
    assert(type(value) == "table", "non-document value leaked")
    assert(getmetatable(value) == nil, "metatable leaked")
    assert(not forbidden[value], "source table leaked")
    local strings, numbers = 0, 0
    for key, item in pairs(value) do
        if type(key) == "string" then strings = strings + 1 else
            assert(type(key) == "number" and key >= 1 and key % 1 == 0 and key <= #value, "sparse array")
            numbers = numbers + 1
        end
        plain_detached(item, forbidden)
    end
    assert(strings == 0 or numbers == 0, "mixed object/array")
    assert(numbers == #value, "array has a hole")
end

local versions = { "V4.3.4", "V4.3.3", "V4.3.2", "V4.3.1", "V4.3.0", "V4.2.2", "V4.2.1", "V4.2.0",
    "V4.1.2", "V4.1.1", "V4.1.0", "V4.0.0", "V3.3.0", "V3.2.0", "V3.1.0", "V3.0.0", "V2.1.1",
    "V2.0.0", "V1.2.1", "V1.2.0", "V1.1.0", "V1.0.0" }
local paragraph_counts = { 3, 2, 3, 3, 3, 1, 3, 3, 1, 1, 1, 4, 1, 3, 1, 1, 1, 3, 1, 1, 1, 1 }
local section_ids = { "configure", "usage", "changelog" }

for _, language in ipairs({ "zh", "en" }) do
    for _, game in ipairs({ "Wilds", "Rise" }) do
        test(game .. " " .. language .. " complete localized plain documentation without an actor", function()
            local snapshot = Help.snapshot(language, game)
            plain_detached(snapshot, source_tables(Documentation))
            assert(#snapshot.sections == 3)
            for index, section in ipairs(snapshot.sections) do
                local source = language == "en" and Documentation[index].en or Documentation[index]
                local title = source.title
                if index == 3 then
                    title = title .. (language == "zh" and "（原《荒野》版本历史）" or " (Original Wilds Version History)")
                end
                assert(section.id == section_ids[index] and section.title == title)
                assert(section.en == nil and section.game == nil)
                local expected = {}
                for _, entry in ipairs(source.entries) do
                    if not entry.game or entry.game == game then
                        expected[#expected + 1] = { title = entry.title, paragraphs = S.copy(entry.paragraphs) }
                    end
                end
                S.equal(section.entries, expected)
            end
            assert(#snapshot.sections[1].entries == (game == "Wilds" and 8 or 7))
            assert(#snapshot.sections[2].entries == 4)
            local history = snapshot.sections[3]
            assert(#history.entries == #versions)
            for index, entry in ipairs(history.entries) do
                assert(entry.title == versions[index])
                assert(#entry.paragraphs == paragraph_counts[index])
            end
            assert(history.title:find(language == "zh" and "荒野" or "Wilds", 1, true))
        end)

        test(game .. " " .. language .. " current saving and performance guidance", function()
            local snapshot = Help.snapshot(language, game)
            local usage = all_text(snapshot.sections[2])
            local files = table.concat(snapshot.sections[1].entries[7].paragraphs, "\n")
            assert(files:find("reframework\\data\\ArmorVariantManager", 1, true))
            assert(files:find(language == "zh" and "当前界面" or "current UI", 1, true))
            assert(usage:find(language == "zh" and "自动将选中预设设为默认" or "Automatically set selected preset as default", 1, true))
            assert(usage:find(language == "zh" and "覆盖预设" or "Overwrite Preset", 1, true))
            assert(not usage:find("不再需要手动保存", 1, true) and not usage:find("manual saving is not required", 1, true))
            assert(not usage:find("2 FPS", 1, true))
            assert(usage:find(language == "zh" and "扫描间隔" or "Scan Interval", 1, true))
            assert(usage:find(language == "zh" and "刷新间隔" or "Refresh Interval", 1, true))
            assert(usage:find(language == "zh" and "分帧扫描步频" or "Scanner Batch Size", 1, true))
            local performance = snapshot.sections[2].entries[4].paragraphs
            assert(performance[1]:find(language == "zh" and "荒野" or "In Wilds", 1, true))
            assert(performance[2]:find(language == "zh" and "崛起" or "In Rise", 1, true))
            assert(performance[2]:find(language == "zh" and "为其他玩家应用差分" or "Apply variants to other players", 1, true))
            local configure = all_text(snapshot.sections[1])
            if game == "Wilds" then
                local route = (language == "zh" and "设置 → " or "Settings > ") .. Localization[language].heel_title
                assert(configure:find(route, 1, true))
                assert(configure:find(language == "zh" and "当前防具分组的预设草稿" or "current armor group's preset draft", 1, true))
                assert(not configure:find(language == "zh" and "设置 → 装备草稿" or "Settings > Equipment Draft", 1, true))
                assert(not configure:find(language == "zh" and "防具部件面板底部" or "bottom of the armor parts panel", 1, true))
            else
                assert(not configure:find(language == "zh" and "陷地修" or "Ground Clipping Fix", 1, true))
                assert(not configure:find(language == "zh" and "鹭鹰龙" or "Seikret", 1, true))
            end
        end)
    end
end

test("historical literals and numbers are unchanged", function()
    local zh = Help.snapshot("zh", "Rise").sections[3].entries
    local en = Help.snapshot("en", "Rise").sections[3].entries
    assert(zh[1].paragraphs[2] == "2. 支持在勾选的 +10 cm 与 0 cm 预设之间切换；归零按钮会勾选并设为 0 cm。")
    assert(en[1].paragraphs[2] == "2. Switch between checked +10 cm and 0 cm presets to raise or reset height. Reset now checks the option and sets 0 cm.")
    assert(zh[12].paragraphs[1] == "1. 新增独立 UI 面板，默认使用 Home 键打开。")
    assert(en[12].paragraphs[1] == "1. Added an independent UI panel, opened with the Home key by default.")
    assert(zh[12].paragraphs[3] == "3. 新增自动保存预设功能，默认启用。")
    assert(en[12].paragraphs[3] == "3. Added automatic preset saving, enabled by default.")
    assert(zh[22].paragraphs[1] == "发布。" and en[22].paragraphs[1] == "Initial release.")
end)

test("snapshots cannot modify the source or later reads", function()
    local snapshot = Help.snapshot("en", "Wilds")
    local expected = S.copy(snapshot)
    snapshot.sections[1].title = "changed"
    snapshot.sections[1].entries[1].title = "changed"
    snapshot.sections[1].entries[1].paragraphs[1] = "changed"
    table.remove(snapshot.sections[3].entries)
    S.equal(Help.snapshot("en", "Wilds"), expected)
    assert(Documentation[1].en.entries[1].paragraphs[1] == expected.sections[1].entries[1].paragraphs[1])
end)

test("legacy numeric array and language fallback remain available", function()
    assert(#Documentation == 3 and Documentation.sections == nil)
    assert(Documentation[1].title == "如何配置" and Documentation[1].en.title == "How to Configure")
    assert(Documentation[3].title == "更新日志" and Documentation[3].en.title == "Changelog")
    assert(#Documentation[1].entries == 8 and #Documentation[1].en.entries == 8)
    S.equal(Help.snapshot(nil, "Wilds"), Help.snapshot("zh", "Wilds"))
    local english = Documentation[2].en
    Documentation[2].en = nil
    local ok, snapshot = pcall(Help.snapshot, "en", "Wilds")
    Documentation[2].en = english
    assert(ok, snapshot)
    assert(snapshot.sections[2].title == Documentation[2].title)
    S.equal(snapshot.sections[2].entries, Documentation[2].entries)
end)

test("empty lists remain plain tables for bridge normalization", function()
    local source = Documentation[1]
    Documentation[1] = { title = "Empty", entries = { { title = "No paragraphs", paragraphs = {} } },
        en = { title = "Empty section", entries = {} } }
    local zh_ok, zh = pcall(Help.snapshot, "zh", "Rise")
    local en_ok, en = pcall(Help.snapshot, "en", "Rise")
    Documentation[1] = source
    assert(zh_ok, zh)
    assert(en_ok, en)
    S.equal(zh.sections[1].entries[1].paragraphs, {})
    S.equal(en.sections[1].entries, {})
    plain_detached(zh, source_tables(Documentation))
    plain_detached(en, source_tables(Documentation))
end)

if #failures > 0 then error(table.concat(failures, "\n")) end
print("reff help: " .. passed .. " passed")
