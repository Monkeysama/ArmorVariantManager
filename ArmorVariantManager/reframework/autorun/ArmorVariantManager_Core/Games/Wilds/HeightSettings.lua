local HeightSettings = {}
local fields = { ground_clipping_enabled = "enabled", ground_clipping_height_cm = "height_cm" }

-- 高度属于当前防具分组的预设草稿，不写入全局设置。
function HeightSettings.new(deps)
    local T, self = deps.translate, {}
    function self.handles(id) return fields[id] ~= nil or id == "ground_clipping_reset" end
    function self.snapshot(context)
        local available = context.id and not context.weapon and not context.suspended
        local value = available and deps.get() or { enabled = false, height_cm = 10 }
        local section = { id = "ground_clipping", label = T("heel_title"), scope = "equipment",
            description = T("heel_description"), fields = {
                { id = "ground_clipping_enabled", label = T("heel_enable"), type = "boolean", value = value.enabled },
                { id = "ground_clipping_height_cm", label = T("heel_height"), type = "number", value = value.height_cm,
                    min = -10, max = 50, step = 0.1 },
                { id = "ground_clipping_reset", label = T("heel_reset_short"), type = "action" },
            } }
        for _, field in ipairs(section.fields) do
            field.disabled = not available
            if not available then field.reason = T("heel_armor_only") end
        end
        local status = deps.status and deps.status()
        if status then
            section.description = T(status.key) .. (status.error and (": " .. status.error) or "")
                .. "\n" .. section.description
        end
        return section
    end
    function self.action(request, context)
        if not context.id or context.suspended or context.weapon then return false, T("heel_armor_only") end
        if request.bodyId ~= context.id then return false, "装备已变化，请重新操作" end
        if request.id == "ground_clipping_reset" then return deps.set({ enabled = true, height_cm = 0 }, context.id) end
        local key, value = fields[request.id], request.value
        if key == "enabled" then
            if type(value) ~= "boolean" then return false, "高度开关无效" end
        elseif key == "height_cm" then
            if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return false, "高度数值无效" end
        else return false, "设置项不存在" end
        return deps.set({ [key] = value }, context.id)
    end
    return self
end

return HeightSettings
