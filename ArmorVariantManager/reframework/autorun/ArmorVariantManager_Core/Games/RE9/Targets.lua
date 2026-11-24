local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
local Visibility = require("ArmorVariantManager_Core.Games.RE4.Viscon")
local Targets = {}
local labels = { cp_A000 = "Leon", cp_A100 = "Grace", cp_A110 = "Grace" }
local slot_ids = { ["10"] = "head", ["20"] = "hair", ["40"] = "body" }
local mesh_type
local last_context, last_result, next_scan
local scan_interval = 30
local current_frame = scan_interval

local function player()
    local manager = sdk.get_managed_singleton("app.CharacterManager")
    if not manager then return end
    local context = manager:call("getPlayerContextRefFast")
    if not context or context:call("get_IsActivePlayer") ~= true then return end
    local root = context:call("get_GameObject")
    if not root or not root:call("get_Valid") then return end
    local kind = root:call("get_Name")
    if labels[kind] then return context, root, kind end
end

local function scan(root)
    local source, by_slot, shadow_by_parent, seen = {}, {}, {}, {}
    local visits = 0
    mesh_type = mesh_type or sdk.typeof("via.render.Mesh")
    local function visit(transform, parent, depth)
        if not transform or depth > 12 or visits >= 1800 then return end
        visits = visits + 1
        local go = transform:call("get_GameObject")
        if not go or not go:call("get_Valid") then return end
        local mesh = go:call("getComponent(System.Type)", mesh_type)
        if mesh and mesh:call("get_MeshReady") and mesh:call("get_MaterialNum") > 0 then
            local path = Utils.get_mesh_resource_path(mesh)
            local id = path and path:lower():match("[/\\](ch%d%d%d%d_%d%d_[%d_]+)%.mesh")
            if id and path:lower():match("^character[/\\]ch[/\\]") then
                local map_id = id:match("^ch%d+_(%d%d)_")
                local slot = slot_ids[map_id] or ("mesh_" .. map_id)
                local name = go:call("get_Name")
                local data = { mesh = mesh, path = path, id = id, go = go, drawn = go:call("get_DrawSelf") }
                if name == "Shadow" and parent then
                    shadow_by_parent[parent] = data
                elseif not by_slot[slot] or (data.drawn and not by_slot[slot].drawn) then
                    by_slot[slot] = data
                end
            end
        end
        local child = transform:call("get_Child")
        while child and visits < 1800 and depth < 12 do
            visit(child, go:get_address(), depth + 1)
            child = child:call("get_Next")
        end
    end
    visit(root:call("get_Transform"), nil, 0)
    if not by_slot.body then
        Visibility.refresh(seen)
        return nil
    end
    for _, data in pairs(by_slot) do
        local shadow = shadow_by_parent[data.go:get_address()]
        if shadow and shadow.path ~= data.path then shadow = nil end
        if shadow then seen[shadow.mesh:get_address()] = shadow.path end
        seen[data.mesh:get_address()] = data.path
    end
    Visibility.refresh(seen)
    for slot, data in pairs(by_slot) do
        local shadow = shadow_by_parent[data.go:get_address()]
        local same_shadow = shadow and shadow.path == data.path
        if same_shadow then Visibility.add(shadow.mesh, data.path) end
        source[slot] = Visibility.add(data.mesh, data.path, same_shadow and {shadow.mesh} or nil)
    end
    local paths = {}
    for slot, data in pairs(by_slot) do
        paths[#paths + 1] = slot .. ":" .. data.path
    end
    table.sort(paths)
    source.resource_identity = table.concat(paths, "|")
    return source, by_slot.body.id
end

function Targets.set_borrow_resolver() end

function Targets.collect()
    local context, root, kind = player()
    if not context then
        if last_context then Visibility.reset() end
        last_context, last_result = nil, nil
        return {}
    end
    local address = context:get_address()
    if last_context ~= address or current_frame >= next_scan then
        if last_context ~= address then Visibility.reset() end
        local source, body = scan(root)
        last_context, next_scan = address, current_frame + scan_interval
        local name = labels[kind]
        local config_key = source and name .. "_" .. body
        last_result = source and {{
            id = "player:" .. config_key,
            kind_id = body,
            config_key = config_key,
            source = source,
            context = context,
            label = name,
            ident = { character = name },
        }} or {}
    end
    return last_result
end

function Targets.tick()
    current_frame = current_frame + 1
end
return Targets
