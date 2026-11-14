local Documentation = require("ArmorVariantManager_Core.Documentation")
local Help = {}
local section_ids = { "configure", "usage", "changelog" }

-- 按需复制说明内容；不依赖角色，也不把文档原表交给网页。
function Help.snapshot(language, game)
    local result = { sections = {} }
    for index, source in ipairs(Documentation) do
        local section = language == "en" and source.en or source
        local row = { id = section_ids[index], title = section.title, heading = section.heading, entries = {} }
        for _, entry in ipairs(section.entries or {}) do
            if not entry.game or entry.game == game then
                local item = { title = entry.title, groupTitle = entry.groupTitle, paragraphs = {} }
                for _, paragraph in ipairs(entry.paragraphs or {}) do
                    item.paragraphs[#item.paragraphs + 1] = paragraph
                end
                row.entries[#row.entries + 1] = item
            end
        end
        result.sections[#result.sections + 1] = row
    end
    return result
end

return Help
