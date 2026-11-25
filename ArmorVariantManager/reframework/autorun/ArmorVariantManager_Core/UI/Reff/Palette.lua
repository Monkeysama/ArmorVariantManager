local Palette = require("ArmorVariantManager_Core.Presets.Palette")
local ReffPalette = {}

-- 调色的界面数据与操作；参数分组、含义和控件布局由网页决定。
-- deps.set(preset, part, material, param, value, component, body_id)、deps.params(part, material)。
-- mdf2 文件（可选，游戏不支持时省略）：deps.file(part, material)、deps.export(part, material, name)、
-- deps.write(preset, part, material, body_id)、deps.files（busy / result）。
function ReffPalette.new(deps)
    local self = {}

    -- snapshot.palette：
    --   editable  当前可编辑（有装备、未在切换）
    --   presets   当前分组中带调色覆盖的预设 { [预设名] = { [部位] = { [材质] = { [参数] = 数值 | { x..w } } } } }
    --   file      mdf2 文件：{ busy, result = 最近一次写入 { path, values, ok, error },
    --             export = 最近一次导出 { path（相对 reframework/data）, exact, reason } }；游戏不支持时没有这个字段
    local last_export
    function self.snapshot(context)
        local result = { editable = context.id ~= nil and not context.suspended, presets = {} }
        local owner = result.editable and context.config and (context.group == "" and context.config
            or context.config.groups and context.config.groups[context.group])
        for name, preset in pairs(owner and owner.presets or {}) do
            local values = Palette.read(preset)
            if next(values) then result.presets[name] = values end
        end
        if deps.files then result.file = { busy = deps.files.busy(), result = deps.files.result(), export = last_export } end
        return result
    end

    local function part_valid(part) return type(part) == "number" or type(part) == "string" end

    -- request = { preset, group, part, material, param, value, component }；
    -- value 为数值、{ x..w } 中要改的分量，或省略 / null 表示取消。
    function self.action(request, context)
        if request.group ~= context.group then return false, "分组已变化，请重新操作" end
        if type(request.preset) ~= "string" or request.preset == "" then return false, "预设名称无效" end
        if not part_valid(request.part) then return false, "部位无效" end
        return deps.set(request.preset, tostring(request.part), request.material, request.param, request.value,
            request.component, context.id)
    end

    -- request = { part, material, name }：导出 RE Mesh Editor 材质预设到
    -- reframework/data/ArmorVariantManager/mdf2_presets/<游戏>/<name>.json。
    function self.export(request, context)
        if not deps.export then return false, "此游戏暂不支持" end
        if not context.id or context.suspended then return false, "没有当前装备" end
        if not part_valid(request.part) or type(request.material) ~= "string" then return false, "材质无效" end
        local result, reason = deps.export(tostring(request.part), request.material, request.name)
        if not result then return false, reason end
        last_export = result
        return true
    end

    -- request = { preset, group, part, material }：把该预设在这个部位的覆盖写进 material 所在的 mdf2；结果见快照 file.result。
    function self.write(request, context)
        if not deps.write then return false, "此游戏暂不支持" end
        if request.group ~= context.group then return false, "分组已变化，请重新操作" end
        if type(request.preset) ~= "string" or request.preset == "" then return false, "预设名称无效" end
        if not part_valid(request.part) or type(request.material) ~= "string" then return false, "材质无效" end
        local result, reason = deps.write(request.preset, tostring(request.part), request.material, context.id)
        if not result then return false, reason end
        return true
    end

    -- 按需读取一个材质的参数，不随每秒快照传输。file 为材质所在 mdf2 的 { path, status }（游戏支持时）。
    function self.params(request, context)
        local result = { bodyId = context.id or "", part = request.part, material = request.material, params = {} }
        if not context.id or context.suspended or type(request.material) ~= "string" then return result end
        local params, reason = deps.params(tostring(request.part), request.material)
        result.params, result.reason = params or {}, reason
        if deps.file then result.file = deps.file(tostring(request.part), request.material) end
        return result
    end

    return self
end

return ReffPalette
