package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local S = dofile("tests/support.lua")
local root = "ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/Rise/"
local now, epoch = 0, 0
local scene = {}
function scene.is_alive(obj) return obj ~= nil and not obj.dead end
function scene.call(obj, method, ...)
    if not scene.is_alive(obj) then return nil end
    return obj:call(method, ...)
end
local master
local signals = {}
function signals.resolve_player(handle)
    if not handle then handle = master end
    if not scene.is_alive(handle) then return nil end
    if handle.go then return handle, handle.go end
    return handle.player, handle
end
function signals.get_current_weapon_type(handle)
    local player = signals.resolve_player(handle) or master
    return player and player.weapon_type
end
local mesh_type = {get_runtime_type=function() return "mesh" end}
local modules = {SceneObject=scene, Signals=signals}
local env = setmetatable({os={clock=function() return now end},
    sdk={find_type_definition=function(name) assert(name == "via.render.Mesh"); return mesh_type end},
    require=function(name) return assert(modules[name:match("([^.]+)$")], name) end,
}, {__index=_G})
modules.Weapons = assert(loadfile(root .. "Weapons.lua", "t", env))()
local Equipment = assert(loadfile(root .. "Equipment.lua", "t", env))()
local function old_equipment()
    local legacy_env = setmetatable({SceneObject=scene, os=env.os,
        resolve_player=signals.resolve_player, get_current_weapon_type=signals.get_current_weapon_type,
        safe_object_alive=scene.is_alive,
        safe_object_name=function(obj) return scene.call(obj, "get_Name") end,
        get_type=env.sdk.find_type_definition, Profiler={count=function() end},
    }, {__index=_G})
    legacy_env.Utils = dofile("tests/fixtures/legacy/rise_weapons.lua")(legacy_env)
    return dofile("tests/fixtures/legacy/rise_equipment.lua")(legacy_env), legacy_env.Utils
end
local current = Equipment.new()
local old, old_weapons = old_equipment()
local function frame(delta)
    now, epoch = now + (delta or .03), epoch + 1
    current.begin_frame(epoch)
    old.state.epoch = epoch
end
local function node(name, children, mesh)
    local obj = {name=name, children=children or {}, mesh=mesh, reads={}}
    obj.transform = {owner=obj}
    function obj.transform:call(method)
        if method == "get_Child" then return obj.children[1] and obj.children[1].transform end
        if method == "get_Next" then return self.next end
        if method == "get_GameObject" then return obj end
        error(method)
    end
    function obj:call(method)
        self.reads[method] = (self.reads[method] or 0) + 1
        if method == "get_Name" then return self.name end
        if method == "get_Transform" then return self.transform end
        if method == "getComponent(System.Type)" then return self.mesh end
        error(method)
    end
    function obj:set_children(items)
        self.children = items
        for i, child in ipairs(items) do child.transform.next = items[i+1] and items[i+1].transform end
    end
    obj:set_children(obj.children)
    return obj
end
local function player(go, kind)
    local value = {go=go, weapon_type=kind}
    go.player = value
    return value
end
local function refs_equal(a, b, first, last)
    assert((a == nil) == (b == nil))
    if a then for i=first,last do assert(a[i] == b[i], "different part " .. i) end end
end
local function compare(character, handle)
    assert(current.body_id(character) == old.body_id(character))
    local parts, legacy = current.parts(character), old.parts(character)
    refs_equal(parts, legacy, 0, 4)
    if parts then assert(parts.sig == legacy.sig and parts.changed == legacy.changed) end
    refs_equal(current.weapons(character, handle), old.weapons(character, handle), 1, 2)
    assert(current.weapon_id(character, handle) == old.weapon_id(character, handle))
end

-- 十四种武器保持前缀、主攻击部件、零起始界面编号与原分支一致。
S.equal(modules.Weapons.WEAPON_PARTS_MAP, old_weapons.WEAPON_PARTS_MAP)
for kind=0,13 do
    local children = {}
    for _, part in ipairs(old_weapons.WEAPON_PARTS_MAP[kind]) do
        children[#children+1] = node(part.prefix .. "_custom")
    end
    local go = node("player03", {node("weapons", children), node("custom_body")})
    local handle = player(go, kind)
    master = player(node("player00"), 0)
    frame()
    compare(go, handle)
    refs_equal(modules.Weapons.get_current_weapon_parts(handle), old_weapons.get_current_weapon_parts(handle), 1, 2)
    for i, part in ipairs(old_weapons.WEAPON_PARTS_MAP[kind]) do
        assert(modules.Weapons.part_name(kind, i-1) == part.name)
    end
end
assert(modules.Weapons.part_name(99, 3) == "Part 3")

-- 完整防具优先 MOD、递归查找；模型标识仍采用直接子物体，保留旧路径含义。
local body = node("mod_body", nil, {})
local native = node("ch00_body")
local parts = {node("mod_helm"), body, node("mod_arm"), node("mod_wst"), node("mod_leg")}
local character = node("player01", {native, node("nested", parts)})
player(character, 0)
frame()
compare(character)
assert(current.parts(character)[1] == body)
assert(current.body_id(character) == "ch00_body")
local cached = current.parts(character)
frame(5)
assert(current.parts(character) == cached, "complete model should not rescan on TTL")
body.dead = true
local new_body = node("replacement_body")
parts[2] = new_body
character.children[2]:set_children(parts)
frame()
compare(character)
assert(current.parts(character)[1] == new_body)

-- 不完整模型短暂重试，身体生成后更新 ID；同帧保持已取得的值。
local incomplete = node("female_preview")
frame()
compare(incomplete)
incomplete:set_children({node("preview_body")})
assert(current.body_id(incomplete) == "female_preview")
frame(.01)
compare(incomplete)
assert(current.body_id(incomplete) == "female_preview")
frame(.02)
compare(incomplete)
assert(current.body_id(incomplete) == "preview_body")
incomplete.children[1].name = "renamed_body"
frame()
compare(incomplete)
assert(current.body_id(incomplete) == "renamed_body")

-- 网格只查自身和直接子物体，缓存 TTL 与失效绑定都影响下一次读取。
local mesh1, mesh2 = {}, {}
local mesh_node = node("part", {node("child", nil, mesh1)})
assert(current.mesh(mesh_node) == old.mesh(mesh_node))
mesh_node.children[1].mesh = mesh2
frame(.1)
assert(current.mesh(mesh_node) == mesh1 and old.mesh(mesh_node) == mesh1)
mesh1.dead = true
assert(current.mesh(mesh_node) == mesh2 and old.mesh(mesh_node) == mesh2)
local mesh3 = {}
mesh_node.children[1].mesh = mesh3
frame(2.1)
assert(current.mesh(mesh_node) == mesh3 and old.mesh(mesh_node) == mesh3)
assert(current.mesh(node("deep", {node("middle", {node("bottom", nil, {})})})) == nil)

-- 同名装备不同角色不能共享部件；换武器与旧对象销毁触发重查。
local a = node("player01", {node("LS_Saya_a"), node("LS_Swd_a")})
local b = node("player02", {node("LS_Saya_b"), node("LS_Swd_b")})
local pa, pb = player(a, 2), player(b, 2)
frame()
compare(a, pa); compare(b, pb)
assert(current.weapon_id(a, pa) == "LS_Swd_a" and current.weapon_id(b, pb) == "LS_Swd_b")
a.children[2].dead = true
a:set_children({a.children[1], node("LS_Swd_new")})
frame()
compare(a, pa)
assert(current.weapon_id(a, pa) == "LS_Swd_new")
pa.weapon_type = 5
a:set_children({node("Ham_new")})
frame()
compare(a, pa)
assert(current.weapon_id(a, pa) == "Ham_new")

-- 武器未生成时的 20ms 重试与缺少首部件的稀疏数组。
local pending = node("player00")
local pp = player(pending, 2)
frame()
compare(pending, pp)
pending:set_children({node("LS_Swd_only")})
frame(.01)
compare(pending, pp)
assert(current.weapons(pending, pp) == nil)
frame(.02)
compare(pending, pp)
assert(current.weapon_id(pending, pp) == "LS_Swd_only")

-- 新实例和生命周期清理必须释放旧引用，不能继承其他会话的装备。
local replacement = node("LS_Swd_after_clear")
pending:set_children({replacement})
assert(current.weapon_id(pending, pp) == "LS_Swd_only")
current.clear(pending)
assert(current.weapon_id(pending, pp) == "LS_Swd_after_clear")
pending:set_children({node("LS_Swd_new_scene")})
current.clear()
current.begin_frame(epoch+1)
assert(current.weapon_id(pending, pp) == "LS_Swd_new_scene")
assert(Equipment.new().weapon_id(pending, pp) == "LS_Swd_new_scene")
pending.dead = true
assert(current.body_id(pending) == nil and current.weapons(pending, pp) == nil)
print("PASS: Rise equipment and weapon discovery match legacy behavior")
