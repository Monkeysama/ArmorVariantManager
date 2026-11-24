local ShapeKeys = require("ArmorVariantManager_Core.Presets.ShapeKeys")
local ReffShapeKeys = {}

-- SKS 键组联动的界面数据与操作；只序列化名字和选项，界面布局由网页决定。
-- deps.view() 返回 ShapeKeyLink.view()，deps.set(preset, group, option, body_id) 写入当前分组的预设。
function ReffShapeKeys.new(deps)
    local self = {}

    -- snapshot.shapeKeys：
    --   available  SKS 已加载；editable 当前可编辑（防具、未切换装备、SKS 可用）
    --   reason     不可编辑的原因键：sks_missing / armor_only / unavailable
    --   groups     SKS 当前捏脸配置的键组 { name, options, value }
    --   presets    当前分组中带联动设置的预设 { [预设名] = { [键组] = 选项名 | 0 } }
    --   sent / errors / failure  见 ShapeKeyLink.view
    function self.snapshot(context)
        local view = deps.view()
        local armor = context.id ~= nil and not context.weapon and not context.suspended
        local result = { available = view.available, editable = view.available and armor, groups = view.groups,
            presets = {}, sent = view.sent, errors = view.errors, failure = view.failure }
        if not view.available then result.reason = "sks_missing"
        elseif not armor then result.reason = context.weapon and "armor_only" or "unavailable" end
        local owner = armor and context.config and (context.group == "" and context.config
            or context.config.groups and context.config.groups[context.group])
        for name, preset in pairs(owner and owner.presets or {}) do
            local values = ShapeKeys.read(preset)
            if next(values) then result.presets[name] = values end
        end
        return result
    end

    -- request = { preset, group, keyGroup, option }；option 为选项名或 0，省略或 null 表示取消该键组。
    function self.action(request, context)
        if context.weapon then return false, "键组联动只用于防具" end
        if request.group ~= context.group then return false, "分组已变化，请重新操作" end
        if type(request.preset) ~= "string" or request.preset == "" then return false, "预设名称无效" end
        if not ShapeKeys.valid_group(request.keyGroup) then return false, "键组名称无效" end
        local option = request.option
        if option ~= nil and not ShapeKeys.valid_option(option) then return false, "键组选项无效" end
        return deps.set(request.preset, request.keyGroup, option, context.id)
    end

    return self
end

return ReffShapeKeys
