-- 使用真实解析器与骨骼运行时，覆盖没有 MasterPlayer 的菜单、CG、多玩家和生命周期。
package.path = "ArmorVariantManager/reframework/autorun/?.lua;" .. package.path
local Height = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingFix")
local Targets = require("ArmorVariantManager_Core.Games.Wilds.GroundClippingTargets")
local function near(value, expected) assert(math.abs(value - expected) < 0.000001, value .. " ~= " .. expected) end
local function copy(p) return { x = p.x, y = p.y, z = p.z } end
local callbacks, hooks = { motion = {}, late = {}, render = {}, reset = {} }, {}
local stacks = {{}}
thread = { get_hook_storage = function() return stacks[#stacks] end }
re = {
    on_pre_application_entry = function(name, fn)
        local list = assert(callbacks[name == "UpdateMotion" and "motion" or name == "PrepareRendering" and "render"])
        list[#list + 1] = fn
    end,
    on_application_entry = function(name, fn) assert(name == "LateUpdateBehavior"); callbacks.late[#callbacks.late + 1] = fn end,
    on_script_reset = function(fn) callbacks.reset[#callbacks.reset + 1] = fn end
}
local function run(phase) for _, fn in ipairs(callbacks[phase]) do fn() end end
local function invoke(name, address, between)
    stacks[#stacks + 1] = {}
    for _, hook in ipairs(hooks[name] or {}) do if hook.pre then hook.pre({ [2] = address }) end end
    if between then between() end
    for _, hook in ipairs(hooks[name] or {}) do if hook.post then assert(hook.post(17) == 17) end end
    table.remove(stacks)
end
local serial, now, scans, errors = 0, 0, 0, 0
local function object(value)
    serial = serial + 1; value = value or {}; value.id = serial
    function value:get_address() return self.id end
    return value
end
local function model(body, name)
    local root = object({ position = { x = 1, y = 2, z = 3 } })
    local transform = object({ root = root, body = body })
    local go = object({ visible = true, name = name or "arbitrary_custom_pfb_name" })
    function go:call(method, runtime_type)
        if method == "get_Draw" then return self.visible end
        if method == "get_Transform" then return transform end
        if method == "getComponent(System.Type)" then assert(runtime_type == "app.Weapon"); return self.weapon end
        error(method)
    end
    function transform:call(method)
        assert(not self.dead, "dead transform accessed")
        if method == "get_GameObject" then return go end
        if method == "get_Child" then return self.child end
        if method == "get_Next" then return self.next end
        if method == "get_Parent" then return self.parent end
        error(method)
    end
    local character = object({ body = body, go = go, fields = {} })
    function character:call(method)
        assert(not self.dead, "dead component accessed")
        if method == "get_IsSetUp" then return not self.building end
        if method == "get_GameObject" then return self.go end
        if method == "get_IsPorterRiding" then return self.riding end
        if method == "get_WpParent" then return self.wp_parent end
        error(method)
    end
    function character:get_field(name) return self.fields[name] end
    return character, root, transform
end
local local_hunter, lr, lt = model("local")
local remote, rr, rt = model("remote")
local preview, pr, pt = model("preview", "SaveSelect_HunterXX")
local doll, _, doll_transform = model("preview", "Mannequin_Hunter")
doll_transform.root, doll_transform.child, pt.parent = nil, pt, doll_transform
doll.fields = preview.fields
local armor, armor_root, armor_transform = model("preview", "ch03_060_0002")
local weapon, weapon_root, weapon_transform = model("preview", "Wp_Parent")
pt.child, armor_transform.parent, armor_transform.next, weapon_transform.parent = armor_transform, pt, weapon_transform, pt
local preview_weapon, pwr, pwt = model("preview", "custom_weapon")
weapon_transform.child, pwt.parent = pwt, weapon_transform
preview_weapon.wp_parent, preview_weapon.go.weapon = weapon_transform, preview_weapon
local cg, cr, ct = model("cg")
local npc, nr = model("local", "PlNpc000")
local p1, p2 = object({ character = local_hunter }), object({ character = remote })
local function player_call(self, method)
    if method == "get_Character" then return self.character end
    if method == "get_Object" then return self.character and self.character.go end
    error(method)
end
p1.call, p2.call = player_call, player_call
local master, players = p1, { p1, p2 }
local dolls, actors = {}, {}
local scene = object()
function scene:call(method, runtime_type)
    assert(method == "findComponents(System.Type)"); scans = scans + 1
    return { get_elements = function() return runtime_type == "app.HunterDoll" and dolls or actors end }
end
local scene_key, suspended = "scene-a", false
local manager = { call = function(_, method, index)
    if method == "getMasterPlayer" then return master end
    if method == "get_InstancedPlayerNum" then return #players end
    if method == "getInstancedPlayer" then return players[index + 1] end
    error(method)
end }
sdk = {
    is_managed_object = function(value) return value ~= nil and not value.dead end,
    to_int64 = function(value) return value end,
    get_managed_singleton = function(name) assert(name == "app.PlayerManager"); return manager end,
    hook = function(method, pre, post)
        hooks[method.type_name .. ":" .. method.name] = hooks[method.type_name .. ":" .. method.name] or {}
        table.insert(hooks[method.type_name .. ":" .. method.name], { pre = pre, post = post })
    end,
    find_type_definition = function(type_name)
        return {
            get_runtime_type = function() return type_name end,
            get_method = function(_, name)
                return { name = name, type_name = type_name, call = function(_, target, arg)
                    if type_name == "via.Transform" then assert(name == "getJointByName" and (arg == "root" or arg == "COG")); return target.root end
                    assert(type_name == "via.Joint")
                    if name == "get_Position" then assert(not target.fail, "isolated joint failure"); return copy(target.position) end
                    if name == "get_LocalPosition" then return copy(target.position) end
                    if name == "set_Position" or name == "set_LocalPosition" then target.position = copy(arg); return end
                    error(name)
                end }
            end
        }
    end
}
Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
log = { error = function() errors = errors + 1 end }
local old_clock = os.clock; os.clock = function() return now end
local collect = Targets.new({ get_scene = function() return scene, scene_key end })
local settings = { ["local"] = 10, remote = 20, preview = 30, cg = 40 }
local selected = lt.id
local deps = {
    get_targets = collect, is_suspended = function() return suspended end,
    get_status_target = function() return selected end,
    get_settings = function(character) return { enabled = true, height_cm = settings[character.body] }, character.body end
}
local api = Height.new(deps)
local function hunter(character) invoke("app.HunterCharacter:doLateUpdateEnd", character.id) end
local function timeline(character, between) invoke("app.CharacterTimelineEventActorPlayer:updateAfterTimeline", character.id, between) end
local function frame()
    run("motion"); hunter(local_hunter); hunter(remote); hunter(npc)
    timeline(cg); run("late"); run("render")
end
frame(); near(lr.position.y, 2.1); near(rr.position.y, 2.2); near(nr.position.y, 2)
assert(api.get_status().body_id == "local")
for i = 1, 1000 do frame(); run("render"); hunter(remote) end
near(lr.position.y, 2.1); near(rr.position.y, 2.2)
assert(scans == 2, "Do not enumerate models every frame")
-- 无本机玩家的主菜单/存档/捏脸/公会卡/装备预览：通过组件识别，不依赖名字白名单。
master, players, dolls = nil, {}, { doll }
now = 0.6; frame(); near(lr.position.y, 2); near(rr.position.y, 2); near(pr.position.y, 2.3)
selected = pt.id; assert(api.get_status().body_id == "preview")
preview.go.name = "new_menu_custom_pfb"
for i = 1, 1000 do frame(); run("late"); run("render") end
near(pr.position.y, 2.3)
near(armor_root.position.y, 2); near(weapon_root.position.y, 2)
-- 实机顺序：动画先覆盖人偶姿态，武器末段随后读取挂点，最后才到 Lua 全局末段。
local function weapon_late(character, between) invoke("app.Weapon:lateUpdate", character.id, between) end
for _ = 1, 1000 do
    run("motion"); pr.position.y = 2
    weapon_late(preview_weapon, function() pwr.position.y = pr.position.y + 1 end)
    run("late"); run("render")
    near(pr.position.y, 2.3); near(pwr.position.y, 3.3)
end
run("motion"); weapon_late(npc); near(pr.position.y, 2)
-- 已发布白名单之后脱离挂点/改挂其他模型/进入重建，也不能抬升旧人偶。
preview_weapon.wp_parent = rt
weapon_late(preview_weapon); near(pr.position.y, 2)
preview_weapon.wp_parent = weapon_transform
weapon_late(preview_weapon); near(pr.position.y, 2.3)
run("motion"); doll.fields._RequiresWeaponSetup = true
weapon_late(preview_weapon); near(pr.position.y, 2)
doll.fields._RequiresWeaponSetup = false
run("motion"); pwt.parent = nil; weapon_late(preview_weapon); near(pr.position.y, 2)
pwt.parent = weapon_transform; frame(); near(pr.position.y, 2.3)
-- 与实机相同：展示容器无骨架，SaveSelect 子节点有完整骨架，盔甲/武器的独立 root 不重复写入。
-- 同层出现两个完整骨架时保守跳过，但仍还原先前识别的骨架，恢复单一模型后不累计。
local alternate, alternate_root, alternate_transform = model("preview")
alternate_transform.parent, pt.next = doll_transform, alternate_transform
frame(); near(pr.position.y, 2); near(alternate_root.position.y, 2)
pt.next = nil; frame(); near(pr.position.y, 2.3)
run("motion"); doll.fields._RequiresPartsSetup = true; run("late"); run("render"); near(pr.position.y, 2)
doll.fields._RequiresPartsSetup = false; frame(); near(pr.position.y, 2.3)
doll.go.visible = false; frame(); near(pr.position.y, 2)
doll.go.visible = true; frame(); near(pr.position.y, 2.3)
preview.go.visible = false; frame(); near(pr.position.y, 2)
preview.go.visible = true; frame(); near(pr.position.y, 2.3)
preview.fields._RequiresPartsSetup = true; frame(); near(pr.position.y, 2)
preview.fields._RequiresPartsSetup = false; frame(); near(pr.position.y, 2.3)
-- 没有猎人末段更新的 CG；在线程局部栈中识别玩家演员，未知裸地址完全不解引用。
dolls, actors = {}, { cg }; now = 1.2; frame(); near(pr.position.y, 2); near(cr.position.y, 2.4)
selected = ct.id; assert(api.get_status().body_id == "cg")
run("motion")
timeline(cg, function() timeline(npc) end)
near(cr.position.y, 2.4); near(nr.position.y, 2)
-- 时间轴晚于演员回调重写姿态，渲染前重新计算；只恢复仍属于自己的旧偏移。
cr.position.y = 6; run("render"); near(cr.position.y, 6.4)
run("motion"); near(cr.position.y, 6)
-- 同一模型同时是实例玩家和 CG 演员，只抬一次，使用过场时机。
local old_go = cg.go; cg.go = remote.go
master, players, actors = p1, { p1, p2 }, { cg }; now = 1.8
frame(); near(rr.position.y, 2.2)
hunter(remote); near(rr.position.y, 2.2)
run("render"); near(rr.position.y, 2.2)
remote.riding = true; frame(); near(rr.position.y, 2)
remote.riding = false
run("motion"); hunter(remote); near(rr.position.y, 2.2)
run("motion"); near(rr.position.y, 2)
cg.go = old_go; actors = {}; now = 2.4
-- 没有实例玩家登记的 CG 仍使用演员明确持有的猎人配置与骑乘状态。
cg.fields._HunterComp = remote
master, players, actors = nil, {}, { cg }; now = 2.5
frame(); near(cr.position.y, 6.2)
remote.riding = true; frame(); near(cr.position.y, 6)
remote.riding, cg.fields._HunterComp = false, nil
master, players, actors = p1, { p1, p2 }, {}; now = 3.1
-- 一个远端骨架故障不影响本机；退出、重连与包装替换不复用旧故障状态。
rr.fail = true; frame(); assert(errors == 1); near(lr.position.y, 2.1)
frame(); assert(errors == 1); near(lr.position.y, 2.1)
rr.fail = false; api.settings_changed(); frame(); near(rr.position.y, 2.2)
remote.riding = true; frame(); near(rr.position.y, 2); near(lr.position.y, 2.1)
remote.riding = false
local replacement, new_root = model("remote")
run("motion"); p2.character = replacement; hunter(remote); hunter(replacement); near(new_root.position.y, 2)
run("motion"); hunter(replacement); near(new_root.position.y, 2.2)
players = { p1 }; frame(); near(new_root.position.y, 2)
-- 隔离真正场景过渡；旧场景组件的 getter 即使会崩溃，也不能在还原时调用。
master, players, actors = nil, {}, { cg }; now = 3.7; frame(); near(cr.position.y, 6.4)
cg.dead = true; scene_key = "scene-b"; dolls, actors = {}, {}; frame(); assert(errors == 1)
suspended = true; frame(); assert(api.get_status().key == "heel_suspended")
cg.dead = false; actors = { cg }; suspended = false; now = 4.3; cr.position.y = 6
frame(); near(cr.position.y, 6.4)
local previous = api; api = Height.new(deps); assert(not previous.is_alive()); near(cr.position.y, 6)
frame(); near(cr.position.y, 6.4)
api.shutdown(); near(cr.position.y, 6); frame(); near(cr.position.y, 6)
os.clock = old_clock
print("PASS: real target resolver, 1000-frame multi-player/menu isolation, no MasterPlayer, owned preview hierarchy, no duplicate armor/weapon roots, ambiguous models, arbitrary preview names, hidden/rebuilding models, timeline recursion/order, late animation, deduplication, faults, riding, disconnect/replacement, scene transition and reload")
