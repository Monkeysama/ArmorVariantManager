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
local current=Equipment.new()
local function frame(delta)
    now, epoch = now + (delta or .03), epoch + 1
    current.begin_frame(epoch)
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
local expected={
    [0]={{prefix="G_Swd",name="Blade"}}, {{prefix="S_Axe",name="Axe"}},
    {{prefix="LS_Saya",name="Sheath"},{prefix="LS_Swd",name="Blade"}},
    {{prefix="L_Bg",name="Bowgun"}}, {{prefix="H_Bg",name="Bowgun"}}, {{prefix="Ham",name="Hammer"}},
    {{prefix="GL_Sld",name="Shield"},{prefix="GL_Lan",name="Lance"}},
    {{prefix="L_Sld",name="Shield"},{prefix="L_Lan",name="Lance"}},
    {{prefix="SS_Sld",name="Shield"},{prefix="SS_Swd",name="Sword"}},
    {{prefix="DB_L",name="Left"},{prefix="DB_R",name="Right"}}, {{prefix="Hrn",name="Horn"}},
    {{prefix="CA_Sld",name="Shield"},{prefix="CA_Swd",name="Sword"}},
    {{prefix="IG_Ins",name="Insect"},{prefix="IG_Gla",name="Glaive"}},
    {{prefix="B_Bow",name="Bow"},{prefix="B_Ydt",name="Quiver"}},
}
local main={[2]=2,[6]=2,[7]=2,[8]=2,[11]=2,[12]=2}
S.equal(modules.Weapons.WEAPON_PARTS_MAP,expected)
for kind=0,13 do
    local children={}
    for _,part in ipairs(expected[kind]) do children[#children+1]=node(part.prefix.."_custom") end
    local go=node("player03",{node("weapons",children),node("custom_body")})
    local handle=player(go,kind)
    master=player(node("player00"),0)
    frame()
    local parts=current.weapons(go,handle)
    local direct=modules.Weapons.get_current_weapon_parts(handle)
    for index,part in ipairs(expected[kind]) do
        assert(parts[index]==children[index] and direct[index]==children[index])
        assert(modules.Weapons.part_name(kind,index-1)==part.name)
    end
    assert(current.weapon_id(go,handle)==expected[kind][main[kind] or 1].prefix.."_custom")
end
assert(modules.Weapons.part_name(99, 3) == "Part 3")

-- 完整防具优先 MOD、递归查找；模型标识仍采用直接子物体，保留旧路径含义。
local body = node("mod_body", nil, {})
local native = node("ch00_body")
local parts = {node("mod_helm"), body, node("mod_arm"), node("mod_wst"), node("mod_leg")}
local character = node("player01", {native, node("nested", parts)})
player(character, 0)
frame()
current.body_id(character)
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
current.body_id(character)
assert(current.parts(character)[1] == new_body)

-- 不完整模型短暂重试，身体生成后更新 ID；同帧保持已取得的值。
local incomplete = node("female_preview")
frame()
current.body_id(incomplete)
incomplete:set_children({node("preview_body")})
assert(current.body_id(incomplete) == "female_preview")
frame(.01)
current.body_id(incomplete)
assert(current.body_id(incomplete) == "female_preview")
frame(.02)
current.body_id(incomplete)
assert(current.body_id(incomplete) == "preview_body")
incomplete.children[1].name = "renamed_body"
frame()
current.body_id(incomplete)
assert(current.body_id(incomplete) == "renamed_body")

-- 网格只查自身和直接子物体，缓存 TTL 与失效绑定都影响下一次读取。
local mesh1, mesh2 = {}, {}
local mesh_node = node("part", {node("child", nil, mesh1)})
assert(current.mesh(mesh_node) == mesh1)
mesh_node.children[1].mesh = mesh2
frame(.1)
assert(current.mesh(mesh_node) == mesh1)
mesh1.dead = true
assert(current.mesh(mesh_node) == mesh2)
local mesh3 = {}
mesh_node.children[1].mesh = mesh3
frame(2.1)
assert(current.mesh(mesh_node) == mesh3)
assert(current.mesh(node("deep", {node("middle", {node("bottom", nil, {})})})) == nil)

-- 同名装备不同角色不能共享部件；换武器与旧对象销毁触发重查。
local a = node("player01", {node("LS_Saya_a"), node("LS_Swd_a")})
local b = node("player02", {node("LS_Saya_b"), node("LS_Swd_b")})
local pa, pb = player(a, 2), player(b, 2)
frame()

assert(current.weapon_id(a, pa) == "LS_Swd_a" and current.weapon_id(b, pb) == "LS_Swd_b")
a.children[2].dead = true
a:set_children({a.children[1], node("LS_Swd_new")})
frame()
current.weapons(a,pa)
assert(current.weapon_id(a, pa) == "LS_Swd_new")
pa.weapon_type = 5
a:set_children({node("Ham_new")})
frame()
current.weapons(a,pa)
assert(current.weapon_id(a, pa) == "Ham_new")

-- 武器未生成时的 20ms 重试与缺少首部件的稀疏数组。
local pending = node("player00")
local pp = player(pending, 2)
frame()
current.weapons(pending,pp)
pending:set_children({node("LS_Swd_only")})
frame(.01)
current.weapons(pending,pp)
assert(current.weapons(pending, pp) == nil)
frame(.02)
current.weapons(pending,pp)
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
print("PASS: Rise equipment and weapon discovery preserve IDs, slot mappings, TTLs and lifecycle isolation")
