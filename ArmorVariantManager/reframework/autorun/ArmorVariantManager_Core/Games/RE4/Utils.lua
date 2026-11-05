local Utils = {}

local type_character_manager = nil
local function get_character_manager()
    if not type_character_manager then
        type_character_manager = sdk.find_type_definition("chainsaw.CharacterManager")
    end
    return sdk.get_managed_singleton("chainsaw.CharacterManager")
end
Utils.get_character_manager = get_character_manager

-- 目前只对里昂(ch0_a0z0)实测过。其它 PlayerKind(艾什莉可控段/Ada)未验证
-- get_BodyUpdater() 返回的具体类是否也继承 chainsaw.PlayerBodyUpdater。
function Utils.get_local_player_context()
    local cm = get_character_manager()
    if not cm then return nil end
    local ok, ctx = pcall(function() return cm:call("getPlayerContextRef") end)
    if ok and ctx and sdk.is_managed_object(ctx) then return ctx end
    return nil
end

-- get_KindID() 在真实 Lua 里返回的是裸整数(枚举底层值),不是 MCP 检查器显示用的
-- "ch0_a0z0 (100000)" 那种格式化字符串——那格式是检查工具自己拼的,sdk 运行时不会给。
-- 所以要反查 chainsaw.CharacterKindID 的静态字段名。
local kind_id_name_by_value = nil
local function build_kind_id_map()
    kind_id_name_by_value = {}
    local type_def = sdk.find_type_definition("chainsaw.CharacterKindID")
    if not type_def then return end
    for _, field in ipairs(type_def:get_fields()) do
        if field:is_static() then
            local ok, value = pcall(function() return field:get_data(nil) end)
            if ok and type(value) == "number" then
                kind_id_name_by_value[value] = field:get_name()
            end
        end
    end
end

-- 裸枚举值 → 名字。CG 傀儡走的是 TimelineEventPuppetChara.get_CharacterKindID(),
-- 不是 CharacterContext.get_KindID(),但两者返回的是同一个枚举,所以反查表共用。
function Utils.kind_id_name(kind)
    if kind == nil then return nil end
    if not kind_id_name_by_value then build_kind_id_map() end
    local value = type(kind) == "number" and kind or nil
    if value and kind_id_name_by_value[value] then return kind_id_name_by_value[value] end
    return tostring(kind)
end

function Utils.get_kind_id_string(context)
    if not context then return nil end
    local ok, kind = pcall(function() return context:call("get_KindID") end)
    if not ok or kind == nil then return nil end
    return Utils.kind_id_name(kind)
end

function Utils.get_body_updater(context)
    if not context then return nil end
    local ok, bu = pcall(function() return context:call("get_BodyUpdater") end)
    if ok and bu and sdk.is_managed_object(bu) then return bu end
    return nil
end

-- 固定槛位,来自 chainsaw.PlayerBodyUpdater 的公共 getter(实测里昂验证过)。
Utils.MESH_SLOTS = { "body", "head", "hair", "armor" }
local SLOT_GETTER = {
    body = "get_BodyMesh",
    head = "get_HeadMesh",
    hair = "get_HairMesh",
    armor = "get_ArmorMesh",
}

-- 「mesh 来源」有两种,下面所有取 mesh 的地方都只认这个抽象:
--   * BodyUpdater(REManagedObject)—— 玩家/搭档,四个槛位各有 getter;
--   * 纯 Lua 表 { [slot] = mesh } —— CG 傀儡。傀儡**没有 BodyUpdater**
--     (它是 TimelineEventPuppetChara 直接挂 mesh),所以只能预先解好塞进表里。
-- 区分靠 `type()`:REManagedObject 在 Lua 里是 userdata,不会和表混淆。
function Utils.get_mesh(source, slot)
    if not source then return nil end
    if type(source) == "table" then
        local mesh = source[slot]
        if mesh and sdk.is_managed_object(mesh) then return mesh end
        return nil
    end
    local getter = SLOT_GETTER[slot]
    if not getter then return nil end
    local ok, mesh = pcall(function() return source:call(getter) end)
    if ok and mesh and sdk.is_managed_object(mesh) then return mesh end
    return nil
end

function Utils.has_armor_mesh(source)
    if not source then return false end
    if type(source) == "table" then return Utils.get_mesh(source, "armor") ~= nil end
    local ok, has = pcall(function() return source:call("get_HasArmorMesh") end)
    return ok and has == true
end

-- mesh / mdf2 的**原版逻辑路径**。mod 替换的是这个路径上的文件内容,路径本身不变 ——
-- 所以它是比材质名稳得多的身份依据(见 CharacterId.lua 开头)。
-- 实测两个 getter 加起来约 2.9 µs,比枚举一遍材质名(~9.7 µs/槛位)便宜三倍多。
function Utils.get_mesh_resource_path(mesh)
    if not mesh then return nil end
    local ok, holder = pcall(function() return mesh:call("getMesh") end)
    if not ok or not holder or not sdk.is_managed_object(holder) then return nil end
    local ok2, path = pcall(function() return holder:call("get_ResourcePath") end)
    if ok2 and type(path) == "string" then return path end
    return nil
end

function Utils.get_material_resource_path(mesh)
    if not mesh then return nil end
    local ok, holder = pcall(function() return mesh:call("get_Material") end)
    if not ok or not holder or not sdk.is_managed_object(holder) then return nil end
    local ok2, path = pcall(function() return holder:call("get_ResourcePath") end)
    if ok2 and type(path) == "string" then return path end
    return nil
end

function Utils.get_material_names(mesh)
    if not mesh then return {} end
    local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
    if not ok or not count or count <= 0 then return {} end
    local names = {}
    for i = 0, count - 1 do
        local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
        if ok_n and name then table.insert(names, name) end
    end
    return names
end

-- 材质名 -> 当前是否显示。读不到的材质不写(调用方按"显示"处理);同名材质以后出现的为准。
-- 注意不能写成 `ok and cur or true`:cur=false 时会算成 true(同 capture_current_as_preset 的坑)。
function Utils.current_material_states(mesh)
    local out = {}
    if not mesh then return out end
    local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
    if not ok or not count or count <= 0 then return out end
    for i = 0, count - 1 do
        local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
        local ok_e, enabled = pcall(function() return mesh:call("getMaterialsEnable", i) end)
        if ok_n and name and ok_e and type(enabled) == "boolean" then out[name] = enabled end
    end
    return out
end

-- 把当前实际显示状态整份抓下来当一个新预设。
-- 这是刻意换掉"从空表开始手动勾"的创建方式:空表是稀疏 diff,只记录被点过的材质,
-- 两个预设之间来回切时,谁都没提到的材质会保留切换前的状态("切一次有效,再切没反应"
-- 就是这个稀疏 diff 的直接后果)。整份抓一次快照,每个预设都对每个材质有明确的
-- true/false,来回切换才是确定性的。
function Utils.capture_current_as_preset(source)
    local preset = {}
    for _, slot in ipairs(Utils.MESH_SLOTS) do
        preset[slot] = { materials = {} }
        local mesh = Utils.get_mesh(source, slot)
        if mesh then
            local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
            if ok and count and count > 0 then
                for i = 0, count - 1 do
                    local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
                    if ok_n and name then
                        local ok_e, enabled = pcall(function() return mesh:call("getMaterialsEnable", i) end)
                        -- 别写成 `cond and enabled or true`:enabled 为 false 时
                        -- `false or true` 会算成 true,于是**隐藏的材质永远抓不进来**。
                        -- 这条 bug 让"用当前外观覆写"等于什么都没存。
                        local v = true
                        if ok_e and type(enabled) == "boolean" then v = enabled end
                        preset[slot].materials[name] = v
                    end
                end
            end
        end
    end
    return preset
end

-- 「用当前外观覆写」用的抓法:**只覆写对得上的槛位,对不上的保持原值**。
--
-- 需要它是因为面板改成按角色选之后,代表目标可能是鉴赏雕像 —— 而雕像的某些槛位
-- 用的是没被 mod 替换的皮肤 mesh(实测 Figure10_010 的 body 是 cha004_00_TU1,
-- 17 个原版材质名)。整份覆写会把角色配置里那 24 个 mod 材质名替掉,
-- 而那份配置在真正的角色身上是对的。
--
-- 判据和逐槛位闸门用同一个(usable 由调用方算好传进来),这样用户只需要理解一套规则:
-- **对不上的槛位就是不动它** —— 不管是应用还是抓取。
function Utils.capture_preserving_unmatched(source, old_preset, usable)
    local fresh = Utils.capture_current_as_preset(source)
    if type(old_preset) ~= "table" then return fresh end
    for _, slot in ipairs(Utils.MESH_SLOTS) do
        local had = old_preset[slot]
        local has_stored = type(had) == "table" and next(had.materials or {}) ~= nil
        -- 原来这个槛位有内容、但当前模型上对不上 ⇒ 保留原值,别用当前模型的覆盖它
        if has_stored and not (usable and usable[slot]) then
            fresh[slot] = had
        end
    end
    return fresh
end
-- 整套造型预设(整份快照)的材质键集 vs 当前模型实际材质集的 **Jaccard 相似度**(交集/并集)。
--
-- 为什么要这个:预设存的是材质**名字**。换了个 mod 之后,少数通用名(Body / S_Hair /
-- Metal1 这类到处都有)会碰巧撞上,于是"逐材质尽力匹配"会套出一个半残的样子 ——
-- 这比什么都不做更糟。所以要先整体判一次"这还是同一个模型吗"。
--
-- 用交集/并集而不是"交集占谁的比例":它**两头都惩罚**(少了的和多出来的都算),
-- 所以"modder 改了两个名字"(≈0.8)和"换了整个模型"(≈0.1)分得很开。
--
-- 但**只在两边都有材质的槛位上算** —— 一边有一边没有的槛位(armor 就是这样,
-- 穿上防护衣才出现)反映的是配置差异,不是"换了模型",算进去会造成误判。详见下面。
--
-- 只对整套造型有意义 —— 状态组是稀疏的,它的键集只是自己声明拥有的那一小撮,
-- 推不出模型全貌;它的材质不存在时本来就会被忽略,天然降级。
function Utils.preset_match_ratio(source, preset)
    if not preset then return 0 end
    local inter, union = 0, 0
    local seen = {}
    local compared = 0

    for _, slot in ipairs(Utils.MESH_SLOTS) do
        local mesh = Utils.get_mesh(source, slot)
        local live, live_n = {}, 0
        if mesh then
            for _, name in ipairs(Utils.get_material_names(mesh)) do
                if not live[name] then live[name] = true; live_n = live_n + 1 end
            end
        end
        local stored, stored_n = {}, 0
        local sd = preset[slot]
        if type(sd) == "table" and type(sd.materials) == "table" then
            for name, _ in pairs(sd.materials) do
                if not stored[name] then stored[name] = true; stored_n = stored_n + 1 end
            end
        end

        -- **一边有、另一边没有的槛位整个跳过。**
        --
        -- 这种槛位说明的是"配置变了",不是"这是另一个模型" —— 最典型的就是 armor:
        -- 里昂穿上防护衣之后 armor 槛位才出现,而用户的预设是没穿的时候抓的。
        -- 把它算进去的话:多出来的护甲材质只进并集不进交集,相似度被稀释;
        -- 如果护甲还**替换**掉了 body(body 读不到),预设里那十几个身体材质也全变成
        -- 只进并集 —— 相似度直接从 1.0 掉到 0.2 上下,**穿衣服的瞬间所有整套造型
        -- 都会被判「材质不匹配,已跳过」**。那不是"预设不属于这个模型",纯属误判。
        --
        -- 只比"两边都有东西"的槛位,穿脱护甲就不再影响判断。
        if live_n > 0 and stored_n > 0 then
            compared = compared + 1
            -- 用「槛位/材质名」做键,避免不同部位的同名材质混算
            for name, _ in pairs(live) do
                local k = slot .. "/" .. name
                if not seen[k] then seen[k] = true; union = union + 1
                    if stored[name] then inter = inter + 1 end
                end
            end
            for name, _ in pairs(stored) do
                local k = slot .. "/" .. name
                if not seen[k] then seen[k] = true; union = union + 1 end
            end
        end
    end

    -- 一个槛位都没法比 = 没有任何证据说它属于这个模型,当不匹配处理
    -- (比如空预设、或者预设记的槛位在这个模型上全都不存在)
    if compared == 0 or union == 0 then return 0 end
    return inter / union
end

-- 逐槛位版本:返回 { [slot] = ratio },**只包含两边都有材质的槛位**。
-- 一边空的槛位不出现在结果里(不是 0)—— 那是「没有依据」而不是「不匹配」,
-- 调用方要能区分这两者。
--
-- 为什么需要它(踩过三次的同一个 bug):聚合成一个标量之后,**一个坏槛位可以否掉
-- 三个好槛位**。实测 Figure10_010 对 ch0_a0z0 的 Human 预设:
--   body 0.000(cha004_00_TU1 没被 mod 替换,材质名还是原版的)
--   head 0.909   hair 0.692
-- 聚合出来 0.292,整份预设被判不可用;而 head/hair 明明完好。
-- 同一个病还表现为 v0.3.7 的「穿上护甲所有造型都被判不匹配」和 Jacket→armor 那次。
function Utils.preset_slot_ratios(source, preset)
    local out = {}
    if not preset then return out end
    for _, slot in ipairs(Utils.MESH_SLOTS) do
        local mesh = Utils.get_mesh(source, slot)
        local live = {}
        local live_n = 0
        if mesh then
            for _, name in ipairs(Utils.get_material_names(mesh)) do
                if not live[name] then live[name] = true; live_n = live_n + 1 end
            end
        end
        local stored, stored_n = {}, 0
        local sd = preset[slot]
        if type(sd) == "table" and type(sd.materials) == "table" then
            for name, _ in pairs(sd.materials) do
                if not stored[name] then stored[name] = true; stored_n = stored_n + 1 end
            end
        end
        -- 和聚合版同一条保护:一边空就整槛跳过(armor 穿脱是最典型的情形)
        if live_n > 0 and stored_n > 0 then
            local inter, union = 0, 0
            for name, _ in pairs(live) do
                union = union + 1
                if stored[name] then inter = inter + 1 end
            end
            for name, _ in pairs(stored) do
                if not live[name] then union = union + 1 end
            end
            if union > 0 then out[slot] = inter / union end
        end
    end
    return out
end

-- "(无)"选项用的兜底:引擎里没找到 VisibleCondition / 材质分组这类概念
-- (via.render.Mesh 上的 MaterialsEnableIndices/PartsEnableIndices 实测是固定 256
-- 容量的位图辅助数组,不是材质分组),所以"不选预设"就无脑全启用,不做分组限定。
function Utils.all_enabled_preset(source)
    local preset = {}
    for _, slot in ipairs(Utils.MESH_SLOTS) do
        preset[slot] = { materials = {} }
        local mesh = Utils.get_mesh(source, slot)
        if mesh then
            for _, name in ipairs(Utils.get_material_names(mesh)) do
                preset[slot].materials[name] = true
            end
        end
    end
    return preset
end

-- 四个槛位当前 mesh 实例的身份串。mesh 被换掉(换装、模型重载、重生、场景切换)时它会变,
-- 而 mesh 一换,我们之前写进去的材质开关就全丢了 —— 这是"差分被冲掉"的主因。
function Utils.get_mesh_identity(source)
    local parts = {}
    for _, slot in ipairs(Utils.MESH_SLOTS) do
        local mesh = Utils.get_mesh(source, slot)
        table.insert(parts, slot .. "=" .. (mesh and tostring(mesh) or "nil"))
    end
    return table.concat(parts, "|")
end

-- mesh 实例没换,但游戏在我们背后把开关重置回去了(过场动画、动作结束时会发生)。
-- 只核对预设里点名过的材质,没点名的本来就该保持原状。
function Utils.slot_state_drifted(mesh, slot_data)
    if not mesh or not slot_data or not slot_data.materials then return false end
    local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
    if not ok or not count or count <= 0 then return false end
    for i = 0, count - 1 do
        local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
        if ok_n and name and slot_data.materials[name] ~= nil then
            local ok_c, cur = pcall(function() return mesh:call("getMaterialsEnable", i) end)
            if ok_c and cur ~= slot_data.materials[name] then return true end
        end
    end
    return false
end

-- 「定位」用:在这个 mesh 里只显示指定材质,同部位其他材质全部临时隐藏。
-- 比"闪烁"明确 —— 闪烁是"看哪块在动"(小部件很难注意到),这个是"还看得见的就是它"。
-- 纯预览,不写进任何预设。
function Utils.isolate_material(mesh, target_name)
    if not mesh then return end
    local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
    if not ok or not count or count <= 0 then return end
    for i = 0, count - 1 do
        local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
        if ok_n and name then
            local want = (name == target_name)
            local ok_c, cur = pcall(function() return mesh:call("getMaterialsEnable", i) end)
            if ok_c and cur ~= want then
                pcall(function() mesh:call("setMaterialsEnable", i, want) end)
            end
        end
    end
end

-- preset_data: { [slot] = { materials = { [mat_name] = true/false } } }
-- 只处理传进来的材质名,没提到的材质保持原状——差分只负责"开/关",不负责枚举全部材质。
function Utils.apply_preset_to_slot(mesh, slot_data)
    if not mesh or not slot_data or not slot_data.materials then return end
    local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
    if not ok or not count or count <= 0 then return end
    for i = 0, count - 1 do
        local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
        if ok_n and name and slot_data.materials[name] ~= nil then
            local want = slot_data.materials[name]
            local ok_c, cur = pcall(function() return mesh:call("getMaterialsEnable", i) end)
            if ok_c and cur ~= want then
                pcall(function() mesh:call("setMaterialsEnable", i, want) end)
            end
        end
    end
end

return Utils
