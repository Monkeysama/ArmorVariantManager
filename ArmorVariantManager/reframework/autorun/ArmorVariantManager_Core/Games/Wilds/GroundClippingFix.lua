-- 陷地修复：独立偏移玩家与展示模型的根骨骼，不修改物理坐标与碰撞。
local GroundClippingFix = {}
local OWNER_KEY = "ArmorVariantManagerGroundClippingFix"

-- 旧 JSON 不需要迁移；缺失配置默认关闭，高度默认 10 cm。
function GroundClippingFix.bounded_height(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return 10 end
    return math.max(-10, math.min(50, value))
end

function GroundClippingFix.read_settings(value)
    value = type(value) == "table" and value or {}
    return { enabled = value.enabled == true, height_cm = GroundClippingFix.bounded_height(value.height_cm) }
end

-- 兼容开发过渡版保存过的字段；新修改只写入陷地修复自己的配置，不迁移旧预设结构。
function GroundClippingFix.config_settings(config)
    if type(config) ~= "table" then return nil end
    if config.ground_clipping_fix ~= nil then return config.ground_clipping_fix end
    return config.high_heel_height
end

-- 新预设自带启用状态和高度；旧预设继续读取过渡版的装备级配置。
function GroundClippingFix.preset_settings(preset, config)
    return GroundClippingFix.read_settings(type(preset) == "table" and preset.ground_clipping_fix
        or GroundClippingFix.config_settings(config))
end

-- 只有勾选的预设参与高度控制；勾选且为 0 cm 时仍是有效的归零指令。
function GroundClippingFix.participating_settings(preset, config)
    local settings = GroundClippingFix.preset_settings(preset, config)
    if settings.enabled then return settings end
    return nil
end

-- 多组同时加载时按默认分组、普通分组、全局分组顺序取最后一个勾选预设的高度。
-- 分组内使用 UI 排序，旧 JSON 缺少排序的部分按名称排序，避免 pairs 导致高度随机变化。
function GroundClippingFix.default_settings(config)
    config = config or {}
    local settings = GroundClippingFix.preset_settings(config.presets and config.presets[config.default_preset], config)
    local ordered, seen, missing = {}, {}, {}
    for _, name in ipairs(config.group_order or {}) do
        if config.groups and config.groups[name] and not seen[name] then
            ordered[#ordered + 1], seen[name] = name, true
        end
    end
    for name in pairs(config.groups or {}) do
        if not seen[name] then missing[#missing + 1] = name end
    end
    table.sort(missing)
    for _, name in ipairs(missing) do ordered[#ordered + 1] = name end
    for _, global in ipairs({ false, true }) do
        for _, name in ipairs(ordered) do
            local group = config.groups[name]
            local preset = group.presets and group.presets[group.default_preset]
            if (group.is_global == true) == global and preset then
                settings = GroundClippingFix.participating_settings(preset, config) or settings
            end
        end
    end
    return settings
end

-- 草稿不写 JSON；新建或覆盖预设时才捕获。运行值按角色隔离，不受打开武器 UI 影响。
function GroundClippingFix.new_preset_state()
    local drafts, runtime = {}, setmetatable({}, { __mode = "k" })
    local state = {}
    function state.get_editor(config, body_id, group_name, preset_name)
        local body = drafts[body_id]
        local draft = body and body.config == config and body.groups[group_name]
        if draft and draft.preset_name == preset_name then return GroundClippingFix.read_settings(draft.settings) end
        local group = group_name == "" and config or config.groups and config.groups[group_name]
        return GroundClippingFix.preset_settings(group and group.presets and group.presets[preset_name], config)
    end
    function state.edit(config, body_id, group_name, preset_name, changes)
        local settings = state.get_editor(config, body_id, group_name, preset_name)
        if changes.enabled ~= nil then settings.enabled = changes.enabled == true end
        if changes.height_cm ~= nil then settings.height_cm = GroundClippingFix.bounded_height(changes.height_cm) end
        if not drafts[body_id] or drafts[body_id].config ~= config then drafts[body_id] = { config = config, groups = {} } end
        drafts[body_id].groups[group_name] = { preset_name = preset_name, settings = settings }
        return settings
    end
    function state.reset(body_id, group_name)
        if group_name == nil then drafts[body_id] = nil
        elseif drafts[body_id] then drafts[body_id].groups[group_name] = nil end
    end
    function state.set_runtime(character, config, settings)
        if not character or not config then return end
        -- SDK 可能为同一角色返回不同 Lua 包装对象；与主脚本角色缓存一样按稳定字符串标识索引。
        local entry = runtime[config]
        if not entry then entry = {}; runtime[config] = entry end
        entry[tostring(character)] = settings
    end
    function state.get_runtime(character, config, base)
        local entry = runtime[config]
        local settings = entry and entry[tostring(character)]
        if settings then return settings end
        return base or GroundClippingFix.default_settings(config)
    end
    return state
end

-- 每次主脚本加载创建独立实例，并撤销独立原型或上一实例，防止重复叠加。
function GroundClippingFix.new(deps)
    local previous = rawget(_G, OWNER_KEY)
    if previous and type(previous.shutdown) == "function" then previous.shutdown() end
    local standalone = rawget(_G, "HighHeelHeight")
    if standalone and standalone ~= previous and type(standalone.shutdown) == "function" then
        standalone.shutdown()
    end

    local api = {}
    local alive, failed = true, false
    local entries, hunters, actors, weapons = {}, {}, {}, {}
    local status = { key = "heel_disabled", height_cm = 10 }
    local methods = {}

    -- 原生方法按类型和名称缓存；不在每帧重复反射，也不持有旧场景的骨骼对象。
    local function call(object, type_name, method_name, ...)
        local key = type_name .. ":" .. method_name
        local method = methods[key]
        if not method then
            local definition = sdk.find_type_definition(type_name)
            method = definition and definition:get_method(method_name)
            assert(method, "Missing method: " .. key)
            methods[key] = method
        end
        return method:call(object, ...)
    end

    -- 始终从 MasterPlayer 取实际本机猎人，不复用 UI 中的变更造型预览角色。
    local function get_hunter()
        local manager = sdk.get_managed_singleton("app.PlayerManager")
        local player = manager and manager:call("getMasterPlayer")
        local hunter = player and player:call("get_Character")
        if not hunter or not hunter:call("get_IsSetUp") then return nil end
        local object = player:call("get_Object")
        local transform = object and object:call("get_Transform")
        return hunter, transform
    end

    local function copy_position(position)
        return Vector3f.new(position.x, position.y, position.z)
    end

    local function same_position(a, b)
        return math.abs(a.x - b.x) < 0.00001
            and math.abs(a.y - b.y) < 0.00001
            and math.abs(a.z - b.z) < 0.00001
    end

    -- 每个骨架独立核验来源、角色和根骨骼；其他动画或 MOD 已写入时绝不覆盖。
    local function resolve(entry)
        local character, transform, object = entry.target.resolve()
        if not character or character:get_address() ~= entry.character
            or not transform or transform:get_address() ~= entry.transform then return nil end
        return character, transform, object
    end

    local function restore(entry)
        local applied = entry.applied
        entry.applied = nil
        if not applied then return end
        local _, transform = resolve(entry)
        if not transform then return end
        local root = call(transform, "via.Transform", "getJointByName", "root")
        if not root or root:get_address() ~= applied.joint then return end
        if applied.written and same_position(call(root, "via.Joint", "get_LocalPosition"), applied.written) then
            call(root, "via.Joint", "set_LocalPosition", applied.base)
        end
    end

    -- 猎人在 IK 后、武器更新前抬升；预览和时间轴模型另有回调与渲染前兜底。
    local function apply(entry)
        restore(entry)
        if failed or entry.failed then return end
        local current = entry.status
        if deps.is_suspended and deps.is_suspended() then
            current.key = "heel_suspended"
            return
        end
        local character, transform, object = resolve(entry)
        if not character then current.key = "heel_waiting"; return end
        if entry.target.is_ready and not entry.target.is_ready() then current.key = "heel_waiting"; return end
        if object and object:call("get_Draw") == false then current.key = "heel_waiting"; return end
        local settings, body_id = deps.get_settings(entry.target.hunter or character)
        settings = type(settings) == "table" and settings or nil
        local height = GroundClippingFix.bounded_height(settings and settings.height_cm)
        current.height_cm, current.body_id = height, body_id
        if not settings or settings.enabled ~= true or math.abs(height) < 0.001 then
            current.key = "heel_disabled"
            return
        end
        if entry.target.hunter and entry.target.hunter:call("get_IsPorterRiding") then
            current.key = "heel_riding"
            return
        end
        local root = call(transform, "via.Transform", "getJointByName", "root")
        if not root then current.key = "heel_no_root"; return end
        local base = copy_position(call(root, "via.Joint", "get_LocalPosition"))
        local position = copy_position(call(root, "via.Joint", "get_Position"))
        position.y = position.y + height / 100.0
        call(root, "via.Joint", "set_Position", position)
        entry.applied = { joint = root:get_address(), base = base,
            written = copy_position(call(root, "via.Joint", "get_LocalPosition")) }
        current.key = "heel_applied"
    end

    -- 一个骨架的异常只暂停它自己；缺少公共入口才禁用整个实例，不修改 JSON。
    local function guarded(fn, entry)
        if not alive then return end
        local ok, err = pcall(fn, entry)
        if not ok then
            local current = entry and entry.status or status
            if entry then entry.failed = true; pcall(restore, entry) else failed = true end
            current.key, current.error = "heel_error", tostring(err)
            if log and log.error then log.error("[AVM GroundClippingFix] " .. tostring(err)) end
        end
    end

    -- 动画前还原全部旧偏移，再发布本帧地址白名单；重建、离线和隐藏对象不会串写。
    local function prepare_hunter()
        hunters, actors, weapons = {}, {}, {}
        local targets = {}
        if not (deps.is_suspended and deps.is_suspended()) then
            if deps.get_targets then targets = deps.get_targets()
            else
                local hunter, transform = get_hunter()
                if hunter and transform then targets = {{ character = hunter, hunter = hunter,
                    id = transform:get_address(), kind = "local", resolve = get_hunter }} end
            end
        end
        for _, entry in pairs(entries) do guarded(restore, entry) end
        if failed then return end
        if deps.is_suspended and deps.is_suspended() then status.key = "heel_suspended"; return end
        local previous = entries
        entries = {}
        status = { key = "heel_waiting", height_cm = 10 }
        local priority = -1
        for _, target in ipairs(targets) do
            pcall(function()
                local character, transform = target.resolve()
                if not character or not transform then return end
                local id, address = transform:get_address(), character:get_address()
                local entry = previous[id]
                if not entry or entry.character ~= address then
                    entry = { character = address, transform = id,
                        status = { key = "heel_waiting", height_cm = 10 } }
                end
                entry.target = target
                entries[id] = entry
                if target.hunter then hunters[target.hunter:get_address()] = entry end
                if target.actor then actors[target.actor:get_address()] = entry end
                for _, binding in ipairs(target.weapons or {}) do
                    weapons[binding.id] = { entry = entry, valid = binding.valid }
                end
                local rank = target.kind == "local" and 3 or target.kind == "preview" and 2 or 1
                if rank > priority then priority, status = rank, entry.status end
            end)
        end
    end

    -- UI 编辑只恢复重试资格；骨骼写入留在动画回调内，不在 D2D 绘制中改姿态。
    function api.settings_changed()
        failed, status.error = false, nil
        for _, entry in pairs(entries) do entry.failed, entry.status.error = false, nil end
    end

    function api.get_status()
        if deps.get_status_target then
            local ok, id = pcall(deps.get_status_target)
            if ok and entries[id] and not (deps.is_suspended and deps.is_suspended()) then return entries[id].status end
        end
        return status
    end
    function api.is_alive() return alive end
    function api.shutdown()
        alive = false
        hunters, actors, weapons = {}, {}, {}, {}
        for _, entry in pairs(entries) do pcall(restore, entry) end
        entries = {}
        if rawget(_G, OWNER_KEY) == api then rawset(_G, OWNER_KEY, nil) end
        if rawget(_G, "HighHeelHeight") == api then rawset(_G, "HighHeelHeight", nil) end
    end

    rawset(_G, OWNER_KEY, api)
    rawset(_G, "HighHeelHeight", api)
    -- 不依赖全局 LateUpdateBehavior 与角色更新的相对顺序，直接在白名单猎人末段写骨骼。
    -- 钩子无法随 Lua 实例移除，旧实例通过 alive 失效；找不到入口时保持禁用并报告错误。
    guarded(function()
        local definition = sdk.find_type_definition("app.HunterCharacter")
        local method = definition and definition:get_method("doLateUpdateEnd")
        assert(method, "Missing method: app.HunterCharacter:doLateUpdateEnd")
        sdk.hook(method, function(args)
            if not alive then return end
            local entry = hunters[sdk.to_int64(args[2])]
            if entry then guarded(apply, entry) end
        end, nil)
    end)
    if deps.get_targets then
        -- 展示武器会在 lateUpdate 中重算挂点；提前抬升所属人偶，让原生更新自然带动主副武器。
        -- 仅查本帧白名单，不从未知裸地址构造对象，也不重复调用武器或碰撞逻辑。
        local weapon_type = sdk.find_type_definition("app.Weapon")
        local weapon_method = weapon_type and weapon_type:get_method("lateUpdate")
        if weapon_method then
            local ok, err = pcall(sdk.hook, weapon_method, function(args)
                if not alive then return end
                local binding = weapons[sdk.to_int64(args[2])]
                if binding then
                    guarded(function()
                        if binding.valid() then apply(binding.entry) end
                    end, binding.entry)
                end
            end, nil)
            if not ok and log and log.error then log.error("[AVM GroundClippingFix preview weapon] " .. tostring(err)) end
        end
        -- 只保存白名单项到线程局部钩子栈，递归调用和多线程更新不会把演员串到一起。
        local definition = sdk.find_type_definition("app.CharacterTimelineEventActorPlayer")
        local method = definition and definition:get_method("updateAfterTimeline")
        if method then
            local ok, err = pcall(sdk.hook, method, function(args)
                if alive then thread.get_hook_storage().avm_ground_target = actors[sdk.to_int64(args[2])] end
            end, function(retval)
                local entry = thread.get_hook_storage().avm_ground_target
                if alive and entry and entries[entry.transform] == entry then guarded(apply, entry) end
                return retval
            end)
            if not ok and log and log.error then log.error("[AVM GroundClippingFix timeline] " .. tostring(err)) end
        end
        re.on_application_entry("LateUpdateBehavior", function()
            if not alive then return end
            for _, entry in pairs(entries) do
                if entry.target.kind == "preview" then guarded(apply, entry) end
            end
        end)
        -- 菜单可不执行猎人末段，CG 也可能在全局末段之后改姿态；仅补齐展示类骨架。
        re.on_pre_application_entry("PrepareRendering", function()
            if not alive then return end
            for _, entry in pairs(entries) do
                if entry.target.kind == "preview" or entry.target.kind == "cutscene" then guarded(apply, entry) end
            end
        end)
    end
    re.on_pre_application_entry("UpdateMotion", function()
        guarded(prepare_hunter)
    end)
    re.on_script_reset(api.shutdown)
    return api
end

return GroundClippingFix
