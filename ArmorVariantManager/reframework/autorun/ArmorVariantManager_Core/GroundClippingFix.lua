local GroundClippingFix = {}
local OWNER_KEY = "ArmorVariantManagerGroundClippingFix"
function GroundClippingFix.bounded_height(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return 10 end
    return math.max(-10, math.min(50, value))
end
function GroundClippingFix.read_settings(value)
    value = type(value) == "table" and value or {}
    return { enabled = value.enabled == true, height_cm = GroundClippingFix.bounded_height(value.height_cm) }
end
function GroundClippingFix.config_settings(config)
    if type(config) ~= "table" then return nil end
    if config.ground_clipping_fix ~= nil then return config.ground_clipping_fix end
    return config.high_heel_height
end
function GroundClippingFix.preset_settings(preset, config)
    return GroundClippingFix.read_settings(type(preset) == "table" and preset.ground_clipping_fix
        or GroundClippingFix.config_settings(config))
end
function GroundClippingFix.participating_settings(preset, config)
    local settings = GroundClippingFix.preset_settings(preset, config)
    if settings.enabled then return settings end
    return nil
end
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
