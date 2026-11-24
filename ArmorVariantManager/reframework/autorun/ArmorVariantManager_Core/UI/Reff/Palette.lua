local Palette = require("ArmorVariantManager_Core.Presets.Palette")
local ReffPalette = {}

-- 调色的界面数据与操作；参数分组、含义和控件布局由网页决定。
-- deps.set(preset, part, material, param, value, component, body_id)、deps.params(part, material)。
function ReffPalette.new(deps)
    local self = {}

    -- snapshot.palette：
    --   editable  当前可编辑（有装备、未在切换）
    --   presets   当前分组中带调色覆盖的预设 { [预设名] = { [部位] = { [材质] = { [参数] = 数值 | { x..w } } } } }
    function self.snapshot(context)
        local result = { editable = context.id ~= nil and not context.suspended, presets = {} }
        local owner = result.editable and context.config and (context.group == "" and context.config
            or context.config.groups and context.config.groups[context.group])
        for name, preset in pairs(owner and owner.presets or {}) do
            local values = Palette.read(preset)
            if next(values) then result.presets[name] = values end
        end
        return result
    end

    -- request = { preset, group, part, material, param, value, component }；
    -- value 为数值、{ x..w } 中要改的分量，或省略 / null 表示取消。
    function self.action(request, context)
        if request.group ~= context.group then return false, "分组已变化，请重新操作" end
        if type(request.preset) ~= "string" or request.preset == "" then return false, "预设名称无效" end
        if type(request.part) ~= "number" and type(request.part) ~= "string" then return false, "部位无效" end
        return deps.set(request.preset, tostring(request.part), request.material, request.param, request.value,
            request.component, context.id)
    end

    -- 按需读取一个材质的参数，不随每秒快照传输。
    function self.params(request, context)
        local result = { bodyId = context.id or "", part = request.part, material = request.material, params = {} }
        if not context.id or context.suspended or type(request.material) ~= "string" then return result end
        local params, reason = deps.params(tostring(request.part), request.material)
        result.params, result.reason = params or {}, reason
        return result
    end

    return self
end

return ReffPalette
