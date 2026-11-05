local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
local CharacterId = require("ArmorVariantManager_Core.Games.RE4.CharacterId")

local Targets = {}

-- ============================================================
-- 「目标」= 一具能被写材质开关的模型。
--
-- 一开始只有一种目标(本地玩家),所以整份代码到处直接传 BodyUpdater。
-- 但**过场动画里的角色不是玩家那具模型** —— 引擎另外生成一批 GameObject
-- (`ch0a0z0_puppet` / `ch2a200_00_puppet` / `ch2a600_puppet` …),
-- 挂 `chainsaw.TimelineEventPuppetChara`,**没有 CharacterContext,也没有 BodyUpdater**,
-- mesh 直接躺在组件字段上。所以只盯玩家的话,一进 CG 差分就全没了。
--
-- 实测(RE4 1.x,CG EventID=50400):
--   ch0a0z0_puppet     get_CharacterKindID() = 100000 = ch0_a0z0   (和剧情里昂同一个 kind)
--   ch2a200_00_puppet  get_CharacterKindID() = 200031 = ch2_a200   (**不是** ch3_a8z0)
--   ch2a600_puppet     get_CharacterKindID() = 200034 = ch2_a600
--
-- 注意第二条:傀儡自带的 kind 是"这个角色在剧情里的那个 NPC kind",不一定等于
-- 用户心里那个可操作角色的 kind。这里**不做任何硬编码映射** —— 照旧按自带 kind 登记,
-- 让既有的材质指纹认亲(find_kin)去建立别名,认错了在面板上改。
-- 理由:硬编码表要逐个角色维护,而认亲机制本来就是为"同一个人的多个 kind"造的。
-- ============================================================

-- 傀儡的四个槛位怎么找:
--   body/head/hair —— 组件上就有字段(`_BodyMesh` / `_HeadMesh` / `_HairMesh`),
--                     实测这三个指针和子物体上的 via.render.Mesh 组件是同一个对象。
--   armor          —— **组件上没有对应字段**。里昂傀儡的护甲是第四个子物体
--                     (实测叫 `body_armor`,mesh 是 cha001_00),Ada 傀儡则没有。
--                     所以只能走子物体:把不是上面那三个的 via.render.Mesh 当 armor。
--
-- 为什么不按子物体名字认槛位:名字根本不统一 —— 里昂傀儡是
-- `body` / `head` / `hair` / `body_armor`,Ada 傀儡却是 `cha200_00` / `cha200_10` / `cha200_20`
-- (直接拿 mesh 文件名当名字)。指针比对没有这个问题。
local PUPPET_SLOT_FIELD = {
    body = "_BodyMesh",
    head = "_HeadMesh",
    hair = "_HairMesh",
}

-- sdk.typeof 拿的是 System.Type 实例(getComponent/findComponents 要的就是它),
-- 和 sdk.find_type_definition 的 RETypeDefinition **不是一个东西**,别混用。
local mesh_system_type = nil
local function get_mesh_type()
    if mesh_system_type == nil then mesh_system_type = sdk.typeof("via.render.Mesh") or false end
    return mesh_system_type or nil
end

local function build_puppet_source(comp)
    local source = {}
    local known = {}
    for slot, field in pairs(PUPPET_SLOT_FIELD) do
        local ok, mesh = pcall(function() return comp:get_field(field) end)
        if ok and mesh and sdk.is_managed_object(mesh) then
            source[slot] = mesh
            known[mesh:get_address()] = true
        end
    end

    -- 找 armor:遍历子物体,取第一个"没在上面三个字段里出现过"的 Mesh 组件。
    local mesh_t = get_mesh_type()
    if mesh_t then
        pcall(function()
            local go = comp:call("get_GameObject")
            if not go then return end
            local tf = go:call("get_Transform")
            if not tf then return end
            local child = tf:call("get_Child")
            while child do
                local cgo = child:call("get_GameObject")
                if cgo then
                    local m = cgo:call("getComponent(System.Type)", mesh_t)
                    if m and sdk.is_managed_object(m) and not known[m:get_address()] then
                        source.armor = m
                        return
                    end
                end
                child = child:call("get_Next")
            end
        end)
    end

    return source
end

-- findComponents 要扫全场景,**不能每帧跑**。傀儡的生灭以过场事件为单位(秒级),
-- 隔一秒重扫一次完全跟得上,中间沿用上次的结果。
local RESCAN_INTERVAL = 60      -- 帧

local puppet_system_type = nil
local figure_system_type = nil
local scene_type_def = nil
local cached_puppets = {}
local cached_figures = {}
-- 诊断用:**所有**扫到的雕像,包括借用解析失败的。
-- 分成两份是因为 cached_figures 是「参与应用」的列表(匹配不上就不该动它的模型),
-- 而面板要看的是「扫到了什么、判成了谁」—— 后者必须包含失败项,否则诊断面板就挂在了
-- 旧闸门的下游,**恰好失败的那些永远看不见**(踩过:Figure10_010 指纹 0.292 被拒,
-- 于是压根不产生目标,面板上一行都没有,看起来像"识别不出来")。
local cached_figures_all = {}
local frames_since_scan = RESCAN_INTERVAL   -- 首帧就扫一次

-- 重扫**失败**(拿不到场景 / findComponents 报错或返回 nil)和"扫到 0 个"是两回事。
-- 实测模型鉴赏页挂机时,每隔几秒就有一次重扫失败;以前失败也当成"0 个"把缓存清空,
-- 雕像就整整丢一个重扫周期(约 1 秒),表现为"反复丢失角色追踪"。
-- 现在失败时沿用上次结果,连续失败超过这么多次才清空(真离开了场景也不会一直挂着旧目标)。
local SCAN_FAIL_LIMIT = 3
local scan_fails = { puppets = 0, figures = 0 }

local function current_scene()
    if not scene_type_def then scene_type_def = sdk.find_type_definition("via.SceneManager") end
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not scene_type_def then return nil end
    return sdk.call_native_func(sm, scene_type_def, "get_CurrentScene")
end

local function rescan_puppets()
    local out = {}
    if puppet_system_type == nil then
        puppet_system_type = sdk.typeof("chainsaw.TimelineEventPuppetChara") or false
    end
    if not puppet_system_type then return out end

    local scene = current_scene()
    if not scene then return nil end

    -- findComponents 返回 SystemArray,**必须先 get_elements() 转成 Lua 表**。
    -- 直接 ipairs 一个 SystemArray 会跳过第 0 个元素、还会越界读一格
    -- (REFramework 文档明写的坑)—— 表现就是"场上第一具傀儡永远不生效"。
    local ok, comps = pcall(function()
        local arr = scene:call("findComponents(System.Type)", puppet_system_type)
        return arr and arr:get_elements() or nil
    end)
    if not ok or not comps then return nil end

    for _, comp in ipairs(comps) do
        if comp and sdk.is_managed_object(comp) then
            local ok_k, kind = pcall(function() return comp:call("get_CharacterKindID") end)
            local kind_id = ok_k and Utils.kind_id_name(kind) or nil
            if kind_id then
                local source = build_puppet_source(comp)
                -- 一个 mesh 都解不出来的先不算目标:傀儡刚生成、服装还没加载完时
                -- 会是这个样子,这时候登记它只会拿一份空模型去抓 default 预设。
                if source.body or source.head or source.hair then
                    local name = "?"
                    pcall(function()
                        local go = comp:call("get_GameObject")
                        if go then name = go:call("get_Name") or "?" end
                    end)
                    table.insert(out, {
                        id = "puppet:" .. tostring(comp:get_address()),
                        kind_id = kind_id,
                        source = source,
                        label = name,
                        is_puppet = true,
                        -- 只读身份判定(见 CharacterId.lua)。**目前只显示,不参与任何行为。**
                        -- 在重扫时算一次而不是每帧算 —— mesh 换实例才可能变身份,
                        -- 而重扫周期本来就是跟着傀儡生灭走的。
                        ident = CharacterId.identify(source),
                    })
                end
            end
        end
    end

    -- 顺序要稳:findComponents 的返回顺序不保证,而 UI 上的目标下拉是按下标选的,
    -- 每次重扫顺序一变,用户选中的目标就会自己跳。
    table.sort(out, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return a.id < b.id
    end)
    return out
end

-- ============================================================
-- 模型鉴赏(Model Viewer)的雕像
--
-- 第三种形状,和前两种都不一样:
--
--   FigureWindow_RootObject → …_OperationRoot → …_RootOperationMove → …_RootOperationRotate
--     └ FigureModel_Figure00_010     chainsaw.FigureModelController
--       └ Figure00_010_Body          Transform + Motion + DummySkeleton,**自己没有 mesh**
--         ├ Body    cha002_00  24 材质
--         ├ Hair    cha000_20  12 材质
--         ├ Head    cha000_10  10 材质
--         ├ Jacket  cha002_01   2 材质
--         └ Figure02_010_Body  wp4000_00   ← 武器道具,不是身体部件
--
-- **雕像没有 CharacterKindID。** `FigureModelController` 只知道一个 `chainsaw.FigureId`
-- (184 个值),`FigureModelSetting` 里只有镜头/布料/姿态参数。所以傀儡那套
-- "按自带 kind 登记 + 认亲"在这里根本没有东西可挂。
--
-- 归属策略:**只借用。** 每个雕像按材质指纹在已知角色里找最像的一个,直接套它的配置,
-- 不进 known、不建 alias、不自动抓 default。理由:雕像是"里昂的**像**",不是"一个里昂" ——
-- 想要的是"把里昂的差分套到雕像上",不是"给雕像单独配一套"。
-- (识别机制以后要改,所以整个匹配动作收在 borrow_resolver 这一个注入点里。)
--
-- 实测 Figure00_010 对 ch3_a8z0 配置的 Jaccard ≈ 0.87(body 24/24 + hair 12/12 +
-- head 5/11),稳过 KINSHIP_THRESHOLD。
-- ============================================================

-- **这里按子物体名字认槛位 —— 和傀儡那边刻意相反。**
-- 傀儡的子物体名不统一(`body` / `cha200_00` 混着),只能靠指针比对;
-- 雕像这边名字是固定的 `Body` / `Head` / `Hair`,而且**必须**靠名字白名单:
-- 子物体里还混着武器道具(`Figure02_010_Body` → wp4000_00),
-- "取剩下那个 Mesh 当 armor"在这里会把枪当成护甲。
--
-- **`Jacket` 刻意不收(踩过,是这一版最早的写法)。**
-- 一开始把 Jacket(cha002_01)映射成 armor,结果 Figure00_010 死活匹配不上。实测:
--
--   Jacket→armor:  最高 0.581  → 低于 KINSHIP_THRESHOLD(0.6),整个雕像不受管
--   不收 Jacket:   最高 0.896  → 匹配到 ch0_a0z0(里昂),正确
--
-- 原因:本插件的 `armor` 指的是"**把 body 的材质名整套重导出**的护甲 mesh"
-- (`armor_mirrors_body` 整个机制就建立在这上面),存下来的 armor 材质集是
-- Band / BeltRibon / Body / Cable … 这 23 个身体名;而 Jacket 只有
-- `Jacket_Mat` / `JacketFur_Mat` 两个毫不相干的名字。
-- 于是 `preset_match_ratio` 在 armor 这一槛上拿到**两边都非空、却完全不相交**的集合 ——
-- 那条"一边空就整槛跳过"的保护**不会触发**,交集 0、并集 +25,纯扣分。
--
-- 而且收了它也**什么都换不了**:armor 镜像 body 时写下去的是 body 的材质名,
-- 那两个名字在 jacket mesh 上根本不存在,`apply_preset_to_slot` 一个都写不进去。
-- 零收益 + 砸掉匹配 ⇒ 不收。
-- (真想管雕像的外套,得老老实实加第五个槛位,不能挤在 armor 上。)
--
-- 只实测过 Figure00_010。别的雕像若用了别的子物体名,这里会解不出槛位 ⇒
-- 那个雕像不产生目标(静默跳过),不会误套到别的部位上。
local FIGURE_SLOT_BY_CHILD_NAME = {
    body = "body",
    head = "head",
    hair = "hair",
}

local FIGURE_MAX_DEPTH = 6

local function collect_figure_meshes(tf, depth, source)
    if not tf or depth > FIGURE_MAX_DEPTH then return end
    local mesh_t = get_mesh_type()
    if not mesh_t then return end
    local child = tf:call("get_Child")
    while child do
        local cgo = child:call("get_GameObject")
        if cgo then
            local cname = cgo:call("get_Name")
            local slot = cname and FIGURE_SLOT_BY_CHILD_NAME[string.lower(cname)] or nil
            if slot and not source[slot] then
                local m = cgo:call("getComponent(System.Type)", mesh_t)
                if m and sdk.is_managed_object(m) then source[slot] = m end
            end
        end
        collect_figure_meshes(child, depth + 1, source)
        child = child:call("get_Next")
    end
end

-- 注入点:给一份 mesh 来源,返回"该借哪个 kind 的配置"(或 nil = 没有够像的)。
-- 放在主脚本里实现 —— 已知角色登记表和别名解析都在那边,而且这块以后要换。
local borrow_resolver = nil
function Targets.set_borrow_resolver(fn) borrow_resolver = fn end

-- 指纹匹配要把每个已知角色的 json 都读一遍,**很贵**,所以匹配上了就按雕像名缓存整个会话。
--
-- 但**没匹配上不能也永久缓存**:雕像刚加载时 mesh 在、材质却可能还没就绪
-- (`get_MaterialNum` 返回 0),这时候算出来必然是 0 分。一次就把它钉死成"不受管",
-- 那么"Reset Scripts 那一刻正显示着的那个雕像"会永远匹配不上,而之后翻到的都正常 ——
-- 这种只差在时序上的毛病最难查。所以失败只重试有限几次(每次隔一个重扫周期),
-- 既能等到材质就绪,又不会对真的匹配不上的雕像每 60 帧重读一遍全部 json。
local BORROW_RETRY_LIMIT = 3
local borrow_cache = {}     -- label -> kind_id(只存匹配成功的)
local borrow_misses = {}    -- label -> 已经失败几次

local function rescan_figures()
    local out = {}
    if not borrow_resolver then return out end
    if figure_system_type == nil then
        figure_system_type = sdk.typeof("chainsaw.FigureModelController") or false
    end
    if not figure_system_type then return out end

    local scene = current_scene()
    if not scene then return nil end

    local ok, comps = pcall(function()
        local arr = scene:call("findComponents(System.Type)", figure_system_type)
        return arr and arr:get_elements() or nil
    end)
    if not ok or not comps then return nil end

    local all = {}
    for _, comp in ipairs(comps) do
        if comp and sdk.is_managed_object(comp) then
            local source, label = {}, nil
            pcall(function()
                local go = comp:call("get_GameObject")
                if not go then return end
                label = go:call("get_Name")
                local tf = go:call("get_Transform")
                if tf then collect_figure_meshes(tf, 0, source) end
            end)

            if label and (source.body or source.head or source.hair) then
                local ident = CharacterId.identify(source)

                -- **认出角色就不用指纹了。** 指纹只在身份未知时兜底 ——
                -- 一是它在角色之间没有分辨力(这套 mod 下跨角色 1.000),
                -- 二是它要把每个已知角色的 json 都读一遍,很贵。
                local kind_id = nil
                if not (ident and ident.character) then
                    kind_id = borrow_cache[label]
                    if not kind_id and (borrow_misses[label] or 0) < BORROW_RETRY_LIMIT then
                        local ok_r, kind = pcall(borrow_resolver, source)
                        if ok_r and kind then
                            borrow_cache[label] = kind
                            kind_id = kind
                        else
                            borrow_misses[label] = (borrow_misses[label] or 0) + 1
                        end
                    end
                end
                do
                    local entry = {
                        id = "figure:" .. label,
                        -- 只有"身份未知、靠指纹借到"时才有值;认出角色的走角色名,
                        -- 由主脚本的 resolve_config_key 决定键。
                        kind_id = kind_id,
                        source = source,
                        label = label,
                        is_figure = true,
                        -- 借用的目标:不登记、不建配置
                        borrowed = true,
                        ident = ident,
                    }
                    table.insert(all, entry)
                    -- **认出角色的雕像即使还没有配置也要进 out** ——
                    -- 键由主脚本解析,拿不到配置时 apply_target 自己会跳过。
                    -- 之前这里用"借到配置没有"做闸门,导致指纹拒掉的雕像连目标都不是,
                    -- 面板上一行都没有(踩过:Figure10_010)。
                    if kind_id or (ident and ident.character) then table.insert(out, entry) end
                end
            end
        end
    end

    local by_label = function(a, b) return a.label < b.label end
    table.sort(out, by_label)
    table.sort(all, by_label)
    return out, all
end

-- 上一次扫描看到的**全部**雕像,含借用解析失败的。不参与应用。
--
-- 目前**没有调用方** —— 只读诊断面板已经撤掉了。刻意留着:下一步要把身份判定从
-- 材质指纹换成 head mesh 编号,而那件事需要的正是「不管指纹匹不匹配,先把场上的
-- 雕像全枚举出来」,也就是 cached_figures_all 这份列表本身。删了下一步得原样加回来。
function Targets.scanned_figures() return cached_figures_all end

-- ============================================================
-- 伙伴 NPC(Luis、Ashley 跟随段…)
--
-- PartnerBaseContext 继承 PlayerBaseContext,BodyUpdater 有完整的
-- get_BodyMesh / get_HeadMesh / get_HairMesh / get_ArmorMesh,
-- 和玩家走**同一条**材质操控路径,不需要像傀儡那样手动解 mesh。
--
-- 实测(RE4,Luis 伙伴段):
--   PlayerAndPartnerContextList count=2
--     [0] ch0_a0z0  PlayerBaseContext   (玩家)
--     [1] ch2_a3z0  PartnerBaseContext  (Luis)
--   PartnerBaseContext 继承 PlayerBaseContext -> 30 个 PlayerBools getter 全部可用。
--   BodyUpdater 类型 Ch2a3z0BodyUpdater -> PartnerBodyUpdater -> CharacterBodyUpdater。
--   body=13 材质, head=8, hair=1, armor=null。
--
-- 条件求值暂时**复用玩家的 context** —— 和傀儡/雕像一致:
--   * Registry.tick 只调一次(player context),有状态条件不会因为多个目标而跑快;
--   * 用户预期是"我受伤时 Luis 也跟着变装",不是"Luis 自己受伤才变";
--   * 未来如果要做 per-NPC 条件,只要把 t.context 改成伙伴自己的 ctx 即可。
-- ============================================================

local function collect_partners(player_context)
    local out = {}
    local cm = Utils.get_character_manager()
    if not cm then return out end

    local ok, list = pcall(function() return cm:call("get_PlayerAndPartnerContextList") end)
    if not ok or not list then return out end

    local ok2, count = pcall(function() return list:call("get_Count") end)
    if not ok2 or not count or count == 0 then return out end

    local player_addr = player_context and player_context:get_address() or nil

    for i = 0, count - 1 do
        local ok3, ctx = pcall(function() return list:call("get_Item", i) end)
        if ok3 and ctx and sdk.is_managed_object(ctx) then
            if ctx:get_address() ~= player_addr then
                local body_updater = Utils.get_body_updater(ctx)
                local kind_id = Utils.get_kind_id_string(ctx)
                if body_updater and kind_id then
                    table.insert(out, {
                        id = "partner:" .. kind_id,
                        kind_id = kind_id,
                        source = body_updater,
                        label = kind_id,
                        is_partner = true,
                        ident = CharacterId.identify(body_updater),
                    })
                end
            end
        end
    end
    return out
end

-- 返回当前所有目标。第一个恒为本地玩家(没有玩家时为空表)。
--
-- context:条件求值(HP、是否持枪…)要的东西。傀儡和伙伴自己没有 context
-- (伙伴技术上有,但暂不使用 —— 见上方注释),
-- **统一复用本地玩家的** —— CG 里那些数值仍然是"你现在这个角色"的数值,
-- 而且这样既有条件一条都不用改。
function Targets.collect()
    local out = {}

    local context = Utils.get_local_player_context()
    if context then
        local body_updater = Utils.get_body_updater(context)
        local kind_id = Utils.get_kind_id_string(context)
        if body_updater and kind_id then
            table.insert(out, {
                id = "player:" .. kind_id,
                kind_id = kind_id,
                source = body_updater,
                context = context,
                label = kind_id,
                is_puppet = false,
                -- 玩家这条每次 collect 都重建,所以这里是每帧算一次。
                -- 实测 head 的两个路径 getter 合计 ~2.9 µs = 一帧的 0.017%,可以忽略;
                -- 真要省的话得把它挂到 mesh_identity 的变化边沿上,现阶段没必要。
                ident = CharacterId.identify(body_updater),
            })
        end
    end

    -- 伙伴 NPC:和玩家一样每帧重建(不缓存),因为只是从 List 读几个条目,不扫场景。
    for _, t in ipairs(collect_partners(context)) do
        t.context = context
        table.insert(out, t)
    end

    frames_since_scan = frames_since_scan + 1
    if frames_since_scan >= RESCAN_INTERVAL then
        frames_since_scan = 0
        local puppets = rescan_puppets()
        if puppets then cached_puppets, scan_fails.puppets = puppets, 0
        else
            scan_fails.puppets = scan_fails.puppets + 1
            if scan_fails.puppets > SCAN_FAIL_LIMIT then cached_puppets = {} end
        end
        local figures, figures_all = rescan_figures()
        if figures then cached_figures, cached_figures_all, scan_fails.figures = figures, figures_all or {}, 0
        else
            scan_fails.figures = scan_fails.figures + 1
            if scan_fails.figures > SCAN_FAIL_LIMIT then cached_figures, cached_figures_all = {}, {} end
        end
    end

    for _, list in ipairs({ cached_puppets, cached_figures }) do
        for _, t in ipairs(list) do
            -- 缓存期内目标可能已经被销毁。用一次取值试探,取不到就跳过这一帧
            -- (不从缓存里删 —— 下次重扫自然会没有它)。
            local ok = pcall(function() return t.source.body or t.source.head end)
            if ok then
                t.context = context
                table.insert(out, t)
            end
        end
    end

    return out
end

return Targets
