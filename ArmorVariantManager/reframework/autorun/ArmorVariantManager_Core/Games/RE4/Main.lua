-- RE4(chainsaw.*)适配:入口识别到 re4 后调用 Main.start,其余游戏的共享应用不参与。
-- RE4 的配置模型(base 整套造型 + axes 状态组)与 MH 的 groups 不同,这里沿用自己的规则、
-- 存储和 ImGui 面板,只复用入口的游戏识别与版本号。设计约束见同目录 AGENTS.md。
local Main = {}
-- REFramework 只在加载脚本时解析 autorun 模块:绘制回调里再 require 会报 module not found,所以在这里先载入
local ImGuiV3 = require("ArmorVariantManager_Core.Games.RE4.ImGuiV3")
local MdfReplace = require("ArmorVariantManager_Core.Games.RE4.MdfReplace")

function Main.start(ctx)
    local mod_name = "ArmorVariantManager"
    local version = ctx.version
    -- 移植自 MHRise/MHWorld 差分管理器(v2.4.5 崛起版 / v3.3.0),按 RE4(chainsaw.*)的
    -- PlayerBodyUpdater 固定槛位模型重写。架构与已知未决见 AGENTS.md。

    local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")
    local TransformManager = require("ArmorVariantManager_Core.Games.RE4.TransformManager")
    local Registry = require("ArmorVariantManager_Core.Games.RE4.Conditions.Registry")
    local Targets = require("ArmorVariantManager_Core.Games.RE4.Targets")
    local CharacterId = require("ArmorVariantManager_Core.Games.RE4.CharacterId")
    local Localization = require("ArmorVariantManager_Core.Games.RE4.Localization")
    local Dissolve = require("ArmorVariantManager_Core.Games.RE4.Dissolve")
    local DissolveStyles = require("ArmorVariantManager_Core.Games.RE4.DissolveStyles")
    local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
    local OpsDissolve = require("ArmorVariantManager_Core.Games.RE4.OpsV3")   -- 溶解预设改名时改各角色配置里的引用
    local ModelV3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
    local Presets = require("ArmorVariantManager_Core.Games.RE4.Presets")
    local Hotkeys = require("ArmorVariantManager_Core.Games.RE4.Hotkeys")

    local global_config_path = "ArmorVariantManager/GlobalSettings.json"
    -- 默认英文(面板顶部有「中文」勾选框,勾了才切中文)。语言是全局的,不跟角色配置走。
    -- ui_dissolve_*:在面板上手动切状态 / 预设时的溶解过渡(只作用于溶解模板的材质)
    -- block_game_mouse:REFF 面板显示时不让游戏读到鼠标按键(见 InputGuard.lua)
    -- height_enabled:模型高度总开关(高度本身按预设 / 选项存在角色配置里,见 HeightFix.lua)
    -- dissolve_presets:溶解预设库(全局,「溶解」页;DissolveStyles.clean_presets)
    local global_config = { language = "en", ui_dissolve_enabled = true, ui_dissolve_time = 1.0, block_game_mouse = true,
        height_enabled = true, dissolve_presets = DissolveStyles.clean_presets(nil, nil) }
    local function load_global_settings()
        local loaded = json.load_file(global_config_path)
        if not loaded then return end
        if loaded.language then global_config.language = loaded.language end
        -- 已知角色登记表也必须读回来,否则重载一次就全忘了(只读 language 是早期的漏)
        if type(loaded.known) == "table" then global_config.known = loaded.known end
        if type(loaded.aliases) == "table" then global_config.aliases = loaded.aliases end
        if type(loaded.weapon_hide_storage) == "boolean" then
            global_config.weapon_hide_storage = loaded.weapon_hide_storage
        end
        if type(loaded.ui_dissolve_enabled) == "boolean" then global_config.ui_dissolve_enabled = loaded.ui_dissolve_enabled end
        if type(loaded.block_game_mouse) == "boolean" then global_config.block_game_mouse = loaded.block_game_mouse end
        if type(loaded.height_enabled) == "boolean" then global_config.height_enabled = loaded.height_enabled end
        if tonumber(loaded.ui_dissolve_time) then global_config.ui_dissolve_time = tonumber(loaded.ui_dissolve_time) end
        -- 溶解预设库;旧版只有一套全局设置(内置样式的形状存在 DissolveEffects.json,光边在 dissolve_edge),
        -- 第一次读到时迁移成一个「默认」预设,外观不变
        local legacy = nil
        if loaded.dissolve_presets == nil then
            local effects = json.load_file("ArmorVariantManager/DissolveEffects.json")
            legacy = { shape = type(effects) == "table" and effects[DissolveStyles.PROVIDER_ID] or nil, edge = loaded.dissolve_edge }
        end
        global_config.dissolve_presets = DissolveStyles.clean_presets(loaded.dissolve_presets, legacy)
        global_config.dissolve_edge = nil
        -- 全身预览(REFF 页面里显示)
        if type(loaded.portrait_enabled) == "boolean" then global_config.portrait_enabled = loaded.portrait_enabled end
        if tonumber(loaded.portrait_distance) then global_config.portrait_distance = tonumber(loaded.portrait_distance) end
        if tonumber(loaded.portrait_height) then global_config.portrait_height = tonumber(loaded.portrait_height) end
        -- 独立面板(没有 REFF 时的兜底界面)的窗口位置与大小
        if type(loaded.panel_window) == "table" then global_config.panel_window = loaded.panel_window end
        if type(loaded.panel_hotkey) == "string" then global_config.panel_hotkey = loaded.panel_hotkey end
        if type(loaded.panel_hotkey_mod) == "string" then global_config.panel_hotkey_mod = loaded.panel_hotkey_mod end
        -- 独立面板调色页的颜色滑条:"rgb"(默认)/ "hsv"
        if loaded.palette_sliders == "hsv" or loaded.palette_sliders == "rgb" then global_config.palette_sliders = loaded.palette_sliders end
    end
    local function save_global_settings()
        json.dump_file(global_config_path, global_config)
    end
    load_global_settings()

    -- 术语(**别再弄反**):
    --   * 一个层(代码里的 axis)= 用户看到的「状态组」,例如「条件切换-面部」
    --   * 层里的一个 preset  = 用户看到的「状态」,例如 正常 / 低血量 / 受伤
    --   * 整套造型层里的 preset 仍然叫「预设」—— 它是一整套外观,不是某个部位的开关组合
    -- 所以同一个数据结构在两种层里有两个名字,共用一个词会让人以为状态组里存的也是"一整套"。
    --
    -- 实现方式是**同一个 key 加 `_g` 后缀**取另一份文案,而不是到处写 if:
    -- 漏改一处就会出现"新建状态组 / 还没有预设"这种半截子术语(那比统一叫预设更糟)。
    -- 校验脚本会检查每个 `_g` key 都有对应的基础 key,反之亦然。
    local function T(key)
        local lang = global_config.language or "en"
        if not Localization[lang] then lang = "en" end
        return Localization[lang][key] or tostring(key)
    end

    local function TP(key, is_base)
        if is_base then return T(key) end
        return T(key .. "_g")
    end

    -- ============================================================
    -- ImGui 栈保护
    --
    -- ImGui 的 tree 栈是**整个进程共享**的。如果绘制中途抛错,留下没配对的 tree_node,
    -- 失衡会连带把 REFramework 里**其他 mod 的界面**也搞乱 —— 用户只会觉得
    -- "装了这个插件之后菜单全乱了",而且很难归因到这里。
    --
    -- 所以:自己记 tree 深度,绘制包在 pcall 里,出错时把欠的 tree_pop 补齐。
    -- ============================================================

    local tree_depth = 0
    local function ui_tree(label)
        local ok, open = pcall(imgui.tree_node, label)
        if not ok then return false end
        if open then tree_depth = tree_depth + 1 end
        return open
    end
    -- 控件宽度。ImGui 里 combo/input_text 默认吃满可用宽度,而**标签渲染在控件右边** ——
    -- 控件一宽,标签就被推到面板外面(截图里 "Hide Inner Clothes | 隐藏内层衣服" 就被切掉了)。
    -- 收窄到一个固定值,把右边让给标签。
    --
    -- 用 set_next_item_width 而不是 push/pop_item_width:后者又是一对要配平的栈,
    -- 出错时会漏,和刚做的栈保护相抵。set_next_item_width 只影响下一个控件,无状态。
    local ITEM_WIDTH = 260
    local function ui_w() imgui.set_next_item_width(ITEM_WIDTH) end

    local function ui_tree_pop()
        if tree_depth > 0 then
            tree_depth = tree_depth - 1
            imgui.tree_pop()
        end
    end

    -- 只在错误信息变化时写一次日志,否则每帧一条会把日志刷爆
    local last_draw_error = nil
    local logged_error = nil
    local function note_error(where, err)
        local msg = where .. ": " .. tostring(err)
        if logged_error ~= msg then
            logged_error = msg
            pcall(function() log.error("[ArmorVariantManager] " .. msg) end)
        end
        return msg
    end

    local loaded_configs = {}

    -- ============================================================
    -- 配置归属:默认共用,显式独立
    --
    -- 同一个"视觉上的角色"可以有多个 CharacterKindID:剧情里昂 `ch0_a0z0`、
    -- 佣兵里昂 `ch6_i0z0`。配置按 kind_id 分文件,所以默认互不相干。
    --
    -- 规则:**自己没有配置时,按材质指纹找同族并建立共用(别名);想分开就显式点「创建独立预设」。**
    --
    -- 为什么默认共用而不是"写时复制"(先借用、一改动就自动分家):
    -- 写时复制的默认值放反了。对"同一个里昂的两个 object"来说,一改动就分家等于**把一个里昂
    -- 当成两个** —— 而这正是最常见的场景。反过来"里昂和 Ada 用了同一个 mod"这种要分开的情形,
    -- 用户一眼就知道,点一下独立即可。默认值该照着常见情形放。
    --
    -- 代价(明确写在 UI 横幅上):**共用期间的改动会同时影响来源角色。**
    --
    -- 「初始化预设」只在**独立状态**下出现。共用时直接初始化会把来源角色的配置一起清空,
    -- 靠用户记得"先独立再初始化"太脆 —— 让它不可能发生比提醒更可靠。
    --
    -- 走不通的路:`CharacterManager.calcPlayerKind(kindID)` —— 剧情里昂、佣兵里昂、剧情 Ada
    -- 三个全都返回 `PlA0`,它是"玩家槽位"不是角色身份。也不能靠 `Ch6CommonBodyUpdater`
    -- 判断"这是佣兵模式" —— 剧情 Ada 也走这个基类。
    -- ============================================================

    -- 解析别名。所有跟配置有关的路径与内存缓存都必须走它,否则会出现"配置共用了但备份没共用"
    -- 这种半共用状态。
    local function cfg_key(kind_id)
        local aliases = global_config.aliases
        if not aliases then return kind_id end
        local k, seen = kind_id, {}
        for _ = 1, 4 do                      -- 上限防 A→B→A 兜圈子
            local a = aliases[k]
            if not a or a == "" or seen[a] then break end
            seen[k] = true
            k = a
        end
        return k
    end

    local function get_config_path(kind_id) return "ArmorVariantManager/" .. cfg_key(kind_id) .. ".json" end

    -- 解析结果要缓存:每次都 json.load_file 探一遍文件存不存在太贵(每帧、每目标)。
    -- 只在写配置/迁移之后失效 —— 那时候文件集合才可能变。
    local resolved_key_cache = {}
    local function invalidate_key_cache() resolved_key_cache = {} end


    -- 见过哪些角色。json API 没有目录枚举,所以"有哪些配置存在"必须自己记。
    local function register_kind(kind_id)
        global_config.known = global_config.known or {}
        for _, k in ipairs(global_config.known) do
            if k == kind_id then return end
        end
        table.insert(global_config.known, kind_id)
        table.sort(global_config.known)
        save_global_settings()
    end

    -- 配置格式 v2:主层 + 轴,两者同构({presets, active, rules})。
    -- order = 状态(预设)的优先级顺序,靠前的优先。见 TransformManager.pick_active_preset
    local new_layer = Ops.new_layer

    -- armor_mirrors_body:护甲槛位是否直接照抄 body 的最终结果(按材质名对应)。
    -- **默认开启** —— 护甲和身体用同一套材质导出是常见做法,开着比关着更常对。
    -- 见 TransformManager.resolve 里的实际逻辑;这里只是配置层的默认值/归一化。
    local function default_config()
        return { version = 2, base = new_layer(), axes = {}, material_notes = {},
                 armor_mirrors_body = true }
    end

    -- v0.1 的规则是 { threshold = N, preset = P }(只能是 HP 阈值);
    -- 之后统一成 { conditions = {{type,op,value},...}, logic, preset }。
    --
    -- **条件被删掉时也要在这里迁移**,不只是结构变化:引用已删除 id 的规则会恒不命中
    -- (`eval_condition` 找不到 def 就返回 false),对用户表现为"我的配置突然不生效了"。
    -- 迁移完之后,任何一次改动触发的 save_config 都会把新格式写回盘(读进来就升级,存回去就落地)。
    local function migrate_rules(rules)
        for _, rule in ipairs(rules) do
            if rule.threshold ~= nil and rule.conditions == nil then
                rule.conditions = { { type = "hp_ratio", op = "<=", value = rule.threshold } }
                rule.logic = "AND"
                rule.threshold = nil
            end
            -- hp_drop_elapsed(上次掉血距今 N 秒)已被 hp_decreased + hold 取代。
            -- `<= N` / `< N` 等价于"掉血 → 保持 N 秒",能一一对应地换掉。
            -- 反向的 `> N`(已经 N 秒没被打了)布尔表达不了,**故意不动它** ——
            -- 留在那里会在规则列表里显示成原始 id,看得见、删得掉,比悄悄改掉语义好。
            for _, c in ipairs(rule.conditions or {}) do
                if c.type == "hp_drop_elapsed" and (c.op == "<=" or c.op == "<") then
                    local secs = tonumber(c.value) or 0
                    c.type = "hp_decreased"
                    c.value = true
                    c.op = nil
                    local cur = tonumber(rule.hold) or 0
                    if secs > cur then rule.hold = secs end
                end
            end
            if type(rule.conditions) ~= "table" then rule.conditions = {} end
            if not rule.logic then rule.logic = "AND" end
            -- hold(命中后保持多少秒)只接受正数;0 / 负数 / 垃圾值一律当"不保持"(nil)
            local h = tonumber(rule.hold)
            rule.hold = (h and h > 0) and h or nil
        end
    end

    -- order 和 presets 对齐:老配置没有 order(按名字排),新增/删除/改名也可能让两边不一致。
    -- **每次 normalize 都跑一遍**,而不是只在迁移时跑 —— 手改 json、或者以后哪个代码路径
    -- 忘了维护 order,都在这里被兜住。补进来的新名字排在**末尾**(优先级最低),
    -- 不是插在开头:新建的状态突然压过所有已有状态会很意外。
    local function reconcile_order(layer)
        if type(layer.order) ~= "table" then layer.order = {} end
        local seen, out = {}, {}
        for _, n in ipairs(layer.order) do
            if type(n) == "string" and layer.presets[n] and not seen[n] then
                seen[n] = true
                table.insert(out, n)
            end
        end
        local rest = {}
        for n, _ in pairs(layer.presets) do
            if not seen[n] then table.insert(rest, n) end
        end
        table.sort(rest)
        for _, n in ipairs(rest) do table.insert(out, n) end
        layer.order = out
    end

    -- reframework 的 json 库把空 Lua 表存成 null,读回来是 nil 不是 {},直接索引就崩。
    -- 所有可能为空的表都要在这里补回去。
    local function normalize_layer(layer, force_all_slots)
        if type(layer.presets) ~= "table" then layer.presets = {} end
        if type(layer.active) ~= "string" then layer.active = "" end
        if type(layer.rules) ~= "table" then layer.rules = {} end
        -- auto:只有显式 false 才是关。老配置没这个字段、或者被写坏成别的类型,都当开。
        if layer.auto ~= false then layer.auto = true end
        migrate_rules(layer.rules)
        reconcile_order(layer)
        for _, preset in pairs(layer.presets) do
            if force_all_slots then
                -- 主层是整份快照:每个槛位都得在
                for _, slot in ipairs(Utils.MESH_SLOTS) do
                    if type(preset[slot]) ~= "table" then preset[slot] = { materials = {} } end
                    if type(preset[slot].materials) ~= "table" then preset[slot].materials = {} end
                end
            else
                -- 轴是稀疏的:**不要**补齐槛位,补了就等于宣称拥有全部材质,叠加会互相踩
                for slot, data in pairs(preset) do
                    if type(data) == "table" and type(data.materials) ~= "table" then
                        data.materials = {}
                    end
                end
            end
        end
    end

    -- v1(presets/default_preset/transform_rules/groups)→ v2(base/axes)
    local function migrate_v1_to_v2(data)
        local base = new_layer()
        base.presets = (type(data.presets) == "table") and data.presets or {}
        base.active = (type(data.default_preset) == "string") and data.default_preset or ""
        base.rules = (type(data.transform_rules) == "table") and data.transform_rules or {}

        local axes = {}
        for name, g in pairs((type(data.groups) == "table") and data.groups or {}) do
            -- 旧 groups 的预设是整份快照,当轴用会互相覆盖(那是 v0.2 的设计错误)。
            -- 这里不猜、不丢数据,原样搬过来,由作用域冲突检测报出来让用户自己收拾。
            axes[name] = {
                presets = (type(g.presets) == "table") and g.presets or {},
                active = (type(g.active_preset) == "string") and g.active_preset or "",
                rules = {},
            }
        end

        data.version = 2
        data.base = base
        data.axes = axes
        data.presets, data.default_preset, data.transform_rules, data.groups = nil, nil, nil, nil
        data.group_order, data.preset_order = nil, nil
        return data
    end

    -- axis_order 和 axes 对齐。和 reconcile_order 同一个思路:补进来的新轴排在**末尾**
    -- (优先级最低)—— 新建的状态组突然压过所有已有的会很意外。
    -- 这个字段可以完全不存在:那时候 get_axis_names 退回字母序,而用户的 `0 - ` / `1 - `
    -- 数字前缀本身就是排好的顺序,所以旧配置不填也是对的。
    local function reconcile_axis_order(cfg)
        local axes = cfg.axes or {}
        if type(cfg.axis_order) ~= "table" then
            if next(axes) == nil then cfg.axis_order = nil end
            return
        end
        local seen, out = {}, {}
        for _, n in ipairs(cfg.axis_order) do
            if type(n) == "string" and axes[n] and not seen[n] then
                seen[n] = true; table.insert(out, n)
            end
        end
        local rest = {}
        for n, _ in pairs(axes) do if not seen[n] then table.insert(rest, n) end end
        table.sort(rest)
        for _, n in ipairs(rest) do table.insert(out, n) end
        cfg.axis_order = out
    end
    local function normalize_config(data)
        -- v3(状态组平铺 + 条件状态)由 ModelV3 负责;这里只补 v2 同样保证的那两件事:
        -- 整套造型是整份快照(每个槛位都在),备注按槛位分表
        if data.version == ModelV3.VERSION then
            ModelV3.normalize(data)
            for _, preset in pairs(data.base.presets) do
                for _, slot in ipairs(Utils.MESH_SLOTS) do
                    if type(preset[slot]) ~= "table" then preset[slot] = { materials = {} } end
                end
            end
            for _, slot in ipairs(Utils.MESH_SLOTS) do
                if type(data.material_notes[slot]) ~= "table" then data.material_notes[slot] = {} end
            end
            return data
        end
        if data.version ~= 2 then migrate_v1_to_v2(data) end
        if type(data.base) ~= "table" then data.base = new_layer() end
        if type(data.axes) ~= "table" then data.axes = {} end
        if type(data.material_notes) ~= "table" then data.material_notes = {} end
        -- 默认开启:只有显式 false 才算关,老配置没这个字段、或者被写坏成别的类型,都当开
        -- (和 layer.auto 同一套写法)
        if data.armor_mirrors_body ~= false then data.armor_mirrors_body = true end
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            if type(data.material_notes[slot]) ~= "table" then data.material_notes[slot] = {} end
        end
        normalize_layer(data.base, true)
        for _, axis in pairs(data.axes) do normalize_layer(axis, false) end
        reconcile_axis_order(data)
        return data
    end

    -- ============================================================
    -- 备份:两个还原点,各管一类事故
    --
    --   destructive —— 删除预设 / 覆写预设**之前**。这两个是唯一会显式丢数据的操作。
    --   onload      —— 本次载入配置**时**的原样。管的是"渐进搞坏"和文件损坏:
    --
    -- 为什么需要 onload:load_config 里 json.load_file 对**文件损坏**和**文件不存在**
    -- 都返回 nil,于是坏文件会被静默当成空配置,接着任何一次 save_config
    -- (材质勾选是点一下就存盘)就把那个也许还能手工修的坏文件覆盖成空的了。
    -- 这条路径没有任何显式的破坏性操作,destructive 那份救不了它。
    --
    -- **两份都不跟着 save_config 走。** 日常编辑存盘极频繁,备份若跟着保存走会被立刻冲掉 ——
    -- 等发现删错时,备份里也已经是删掉之后的样子,等于没有备份。
    --
    -- 不做多档备份/浏览器:配置本身就是纯 JSON 文件,想留几份、想用 git 管都行,
    -- 比在 ImGui 里搭一套列表+时间戳+预览+部分恢复划算得多。
    -- ============================================================

    local function get_backup_path(kind_id) return "ArmorVariantManager/backup/" .. cfg_key(kind_id) .. ".json" end
    local function get_onload_backup_path(kind_id) return "ArmorVariantManager/backup/" .. cfg_key(kind_id) .. ".onload.json" end

    local backup_exists = {}          -- 缓存,免得每帧读文件探测
    local onload_backup_exists = {}
    local onload_backup_done = {}     -- 每个角色每次会话只留一次

    local function has_backup_file(path, cache, kind_id)
        if cache[kind_id] == nil then
            cache[kind_id] = (json.load_file(path) ~= nil)
        end
        return cache[kind_id]
    end
    local function has_backup(kind_id)
        return has_backup_file(get_backup_path(kind_id), backup_exists, cfg_key(kind_id))
    end
    local function has_onload_backup(kind_id)
        return has_backup_file(get_onload_backup_path(kind_id), onload_backup_exists, cfg_key(kind_id))
    end

    local function deep_copy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, val in pairs(v) do t[k] = deep_copy(val) end
        return t
    end

    -- ============================================================
    -- 材质指纹:找"同一个角色的另一个 kind_id"
    --
    -- 阈值为什么不能接近 1:**只能通过对方存下来的预设看它的材质集**,而那些预设会随 mod
    -- 更新变旧。实测同一角色(里昂剧情 vs 佣兵)、对方配置略旧时是 **0.72–0.75**;
    -- 真的不同角色(里昂 vs Ada)是 **0.000**。分离度极大,所以取 0.6:
    -- 离"同角色"的下界有余量,离"不同角色"更是天远。
    --
    -- 一开始按"必须完全一致"取了 0.95,那是建立在"能看到对方当前材质集"的错假设上,
    -- 实际永远匹配不上。
    --
    -- 和 TransformManager.SLOT_MATCH_THRESHOLD(0.25)**别合并**,两者问的问题不同:
    -- 一个是"这个槛位上这份预设还能用吗",一个是"这俩是不是同一个角色"。
    -- 而且分母不同 —— 一个按单槛位算,一个跨槛位聚合,数值不可比。
    -- ============================================================

    local KINSHIP_THRESHOLD = 0.6

    local function find_kin(kind_id, source)
        local best_name, best_ratio = nil, 0
        for _, other in ipairs(global_config.known or {}) do
            if other ~= kind_id and other ~= cfg_key(kind_id) then
                local d = json.load_file("ArmorVariantManager/" .. other .. ".json")
                if d then
                    -- 旧格式(v1)预设在顶层,新格式在 base 下 —— 读的是生文件,两种都得认
                    local presets = (type(d.base) == "table" and d.base.presets) or d.presets
                    -- **必须遍历全部预设、取最高分**:预设可能是空的或很旧,
                    -- 只看 pairs() 撞见的第一个会随哈希顺序随机失败(踩过)。
                    for _, preset in pairs(presets or {}) do
                        local r = Utils.preset_match_ratio(source, preset)
                        if r > best_ratio then best_ratio, best_name = r, other end
                    end
                end
            end
        end
        if best_ratio >= KINSHIP_THRESHOLD then return best_name end
        return nil
    end

    -- 「借用」用的匹配:给一份 mesh 来源(模型鉴赏的雕像),问"该套哪个已知角色的配置"。
    --
    -- 和 find_kin 三点不同,所以**没有合并成一个函数**:
    --   1. 没有"自己"要排除 —— 雕像不是一个 kind,它压根不在 known 里;
    --   2. 走 `cfg_key(other)` 解析别名后再读文件。共用中的 kind 自己那份文件是被旁路掉的
    --      (读原名会拿到 nil),不解析的话这些角色永远匹配不上;
    --   3. 结果只用来读,不写 alias、不写 known。
    --
    -- 同一个文件可能被多个 kind 指向,所以要去重,否则同一份预设会被算好几遍(只是白费,
    -- 但读盘不便宜)。
    local function find_borrowable_kind(source)
        local best_name, best_ratio = nil, 0
        local seen_files = {}
        for _, other in ipairs(global_config.known or {}) do
            local key = cfg_key(other)
            if not seen_files[key] then
                seen_files[key] = true
                local d = json.load_file("ArmorVariantManager/" .. key .. ".json")
                if d then
                    local presets = (type(d.base) == "table" and d.base.presets) or d.presets
                    for _, preset in pairs(presets or {}) do
                        local r = Utils.preset_match_ratio(source, preset)
                        if r > best_ratio then best_ratio, best_name = r, key end
                    end
                end
            end
        end
        if best_ratio >= KINSHIP_THRESHOLD then return best_name end
        return nil
    end
    Targets.set_borrow_resolver(find_borrowable_kind)

    -- 「尝试匹配同角色配置」只在配置**没什么可丢**时才该出现:建立共用会让本角色自己那份
    -- 配置文件被旁路掉(别名指向别处),里面的预设就成了孤儿。
    -- 判据:没有状态组,且整套造型预设最多只有一个自动生成的 default。
    local function config_is_trivial(cfg)
        for _ in pairs((cfg or {}).axes or {}) do return false end
        local n = 0
        for name, _ in pairs(((cfg or {}).base or {}).presets or {}) do
            if name ~= "default" then return false end
            n = n + 1
            if n > 1 then return false end
        end
        return true
    end

    local function save_config(kind_id)
        local key = cfg_key(kind_id)
        if not loaded_configs[key] then return end
        json.dump_file(get_config_path(kind_id), loaded_configs[key])
        -- 新建了文件的话,键解析的结果可能变(比如 Leon.json 从"不存在"变"存在")
        invalidate_key_cache()
    end

    -- 溶解预设改名(全局库):登记过的每份角色配置里的引用跟着改,有改动的存盘。共用同一份配置的只处理一次
    local function rename_dissolve_everywhere(old, new)
        local done = {}
        for _, kind in ipairs(global_config.known or {}) do
            local key = cfg_key(kind)
            if not done[key] then
                done[key] = true
                local cfg = loaded_configs[key]
                if not cfg then
                    local raw = json.load_file(get_config_path(kind))
                    if raw then
                        cfg = normalize_config(raw)
                        loaded_configs[key] = cfg
                    end
                end
                if cfg and OpsDissolve.rename_dissolve_refs(cfg, old, new) then save_config(kind) end
            end
        end
    end

    -- 建立共用(把 kind_id 指到 target 的配置上)。两处会用:第一次遇到这个角色时自动建立,
    -- 以及用户点「尝试匹配同族配置」时手动建立。
    local function establish_share(kind_id, target)
        global_config.aliases = global_config.aliases or {}
        global_config.aliases[kind_id] = target
        save_global_settings()
        loaded_configs[kind_id] = nil          -- 原来那张(自己的)表作废
        local nk = cfg_key(kind_id)
        if not loaded_configs[nk] then
            local src = json.load_file(get_config_path(kind_id))   -- 已解析到 target 的文件
            loaded_configs[nk] = src and normalize_config(src) or normalize_config(default_config())
        end
        ui_state = {}
        return loaded_configs[nk]
    end

    local function try_match_kin(kind_id, source)
        if not source then return false end
        if cfg_key(kind_id) ~= kind_id then return false end   -- 已经在共用了
        local kin = find_kin(kind_id, source)
        if not kin then return false end
        establish_share(kind_id, kin)
        return true
    end

    -- ============================================================
    -- 配置键的解析:角色识别为主,旧 kind 键为辅,指纹兜底
    --
    -- 为什么要换:kind_id 是"角色槽位"不是"人"。`ch0_a0z0`(剧情里昂)和 `ch6_i0z0`
    -- (佣兵里昂)是同一个人,`ch2_a200` 和 `ch3_a8z0` 也是同一个 Ada;而模型鉴赏的
    -- 雕像**根本没有 kind**。之前靠材质指纹补这一层,但实测这套 mod 下里昂和 Ada 的
    -- 材质名 Jaccard = **1.000**(一个模型换给了多个角色),指纹在角色之间是精确的零分辨力。
    -- head mesh 编号不受 mod 影响,所以身份改由它决定(见 CharacterId.lua)。
    --
    -- 解析顺序(第一个命中即止):
    --   1. <角色名>.json                     新键
    --   2. cfg_key(kind_id).json             旧键,命中后顺带迁移成 1
    --   3. 角色已识别但两者都没有             → 键就是角色名(新建时用),**不跨角色借用**
    --   4. 角色识别不出来                     → 旧行为(kind 键 + 指纹认亲)
    --
    -- 第 3 条是刻意的:已经确定这是 Leon 了,再让指纹去匹配只会匹配到别人
    -- (材质名 1.000 必然误中),那比"暂时不受管"更糟 —— 后者至少不会把 Ada 的差分
    -- 套到 Leon 身上。**弱信号不能覆盖强信号。**
    -- ============================================================

    -- 把某个角色的旧配置迁成 <角色名>.json。**不动旧文件** —— 迁移出错时
    -- 直接删掉新文件就回到原状,不需要恢复备份。
    local migrated = {}
    local function migrate_to_character(char, fallback_kind)
        if migrated[char] then return end
        migrated[char] = true
        local target_path = "ArmorVariantManager/" .. char .. ".json"
        if json.load_file(target_path) then return end          -- 已经有了

        -- 正身优先。没写正身的角色(Leon/Wesker…)就用当前这个目标自己的旧键。
        local candidates = {}
        local pk = CharacterId.primary_kind(char)
        if pk then table.insert(candidates, pk) end
        if fallback_kind then table.insert(candidates, fallback_kind) end

        for _, k in ipairs(candidates) do
            local raw = json.load_file("ArmorVariantManager/" .. cfg_key(k) .. ".json")
            if raw then
                json.dump_file(target_path, raw)
                invalidate_key_cache()
                pcall(function()
                    log.info("[ArmorVariantManager] migrated " .. cfg_key(k)
                        .. ".json -> " .. char .. ".json (旧文件保留)")
                end)
                return
            end
        end
    end

    -- 返回这个目标该用哪个配置键;nil = 没有可用配置(不受管)。
    -- 第二个返回值说明是怎么定下来的,给面板显示用。
    local function resolve_config_key(target)
        local char = target.ident and target.ident.character
        local kid = target.kind_id
        local ck = (char or "?") .. "/" .. tostring(kid)
        local hit = resolved_key_cache[ck]
        if hit then return hit[1], hit[2] end

        local key, how
        if char then
            if json.load_file("ArmorVariantManager/" .. char .. ".json") then
                key, how = char, "character"
            elseif kid and json.load_file(get_config_path(kid)) then
                -- 旧配置还在:迁移一份成角色名,之后就走上面那条
                migrate_to_character(char, kid)
                key, how = char, "migrated"
            else
                -- 角色认出来了但这个角色还没有任何配置。
                -- 玩家/傀儡可以就地建一份(在自己身上抓,安全);雕像不许建。
                key = char
                how = target.borrowed and "none" or "character"
                if target.borrowed then key = nil end
            end
        else
            key = kid and cfg_key(kid) or nil
            how = key and "legacy" or "none"
        end

        resolved_key_cache[ck] = { key, how }
        return key, how
    end
    -- allow_kin:允许在盘上没有配置时用材质指纹去"认亲"(借别人的配置)。
    -- **身份已经由 mesh 确定时必须传 false** —— 那时候认亲只会认到别人身上
    -- (这套 mod 下跨角色材质名 1.000,必然误中),弱信号覆盖强信号。
    local function load_config(kind_id, source, allow_kin)
        local key = cfg_key(kind_id)
        if loaded_configs[key] then return loaded_configs[key] end

        local raw = json.load_file(get_config_path(kind_id))

        -- 只有真从盘上读出东西才留 onload 备份。
        -- 文件损坏/不存在时 raw 是 nil,这时写备份只会把上一次的好备份覆盖成空配置 ——
        -- 那正好是最需要备份的时刻,绝不能自己把它毁掉。
        -- 存的是 normalize 之前的原样(连 v1 旧格式也照原样留着)。
        if raw and not onload_backup_done[key] then
            json.dump_file(get_onload_backup_path(kind_id), raw)
            onload_backup_done[key] = true
            onload_backup_exists[key] = true
        end

        if raw then
            loaded_configs[key] = normalize_config(raw)
            return loaded_configs[key]
        end

        -- **第一次遇到这个角色**(盘上没有它的配置)。只在这一刻自动处理:
        -- 先按材质指纹找同族建立共用,找不到就自动初始化一个 default 基线。
        --
        -- 刻意**不**做成"只要配置为空就自动处理"(试过,是错的):
        --   1. 两条分支同一个触发条件,而自动初始化总会成功 ⇒ "找同族"那条实际不可达;
        --   2. 用户删掉最后一个预设后会被立刻重建 ⇒ default 永远删不掉。
        -- 想事后建立共用,走显式的「尝试匹配同族配置」按钮 —— 那条路没有循环,
        -- 所以也不再需要"配置永不为空"那个不变量。
        if source then
            if allow_kin then
                local kin = find_kin(kind_id, source)
                if kin then return establish_share(kind_id, kin) end
            end

            -- 自己身上抓一份 default 基线。这一步**永远是安全的** ——
            -- 抓的是这个角色自己的外观,不涉及跨角色。
            local fresh = normalize_config(default_config())
            fresh.base.presets["default"] = Utils.capture_current_as_preset(source)
            fresh.base.order = { "default" }
            fresh.base.active = "default"
            loaded_configs[key] = fresh
            save_config(kind_id)
            return fresh
        end

        loaded_configs[key] = normalize_config(default_config())
        return loaded_configs[key]
    end


    local function snapshot_before_destructive(kind_id)
        local cfg = loaded_configs[cfg_key(kind_id)]
        if not cfg then return end
        json.dump_file(get_backup_path(kind_id), cfg)
        backup_exists[cfg_key(kind_id)] = true
    end

    -- ============================================================
    -- 命名存档(预设存取)
    --
    -- 全部存档放在**同一个文件**的一个字典里,而不是一档一个文件 ——
    -- 因为 json API 没有目录枚举,一档一文件就必须再维护一份索引文件,
    -- 而索引和实际文件迟早会不同步。放一个字典里,"有哪些档"就是它的键,不会漂。
    -- ============================================================

    local function get_slots_path(kind_id) return "ArmorVariantManager/backup/" .. cfg_key(kind_id) .. ".slots.json" end

    local slots_cache = {}


    -- 按**存档文件的 key**(= cfg_key 之后的角色 id)取,而不是按当前角色取 ——
    -- 跨角色读档要能碰到别的角色那份文件。读不到就缓存成空表,所以每个 key 一个会话只读盘一次。
    local function get_slots_by_key(key)
        if slots_cache[key] == nil then
            local d = json.load_file("ArmorVariantManager/backup/" .. key .. ".slots.json")
            slots_cache[key] = (type(d) == "table" and type(d.slots) == "table") and d.slots or {}
        end
        return slots_cache[key]
    end

    local function get_slots(kind_id)
        return get_slots_by_key(cfg_key(kind_id))
    end

    local function save_slots_file(kind_id)
        json.dump_file(get_slots_path(kind_id), { slots = slots_cache[cfg_key(kind_id)] or {} })
    end

    -- 全部存档,**跨角色**。返回 { { key=, name=, own=, label= }, ... },自己的排前面。
    --
    -- 为什么能跨:存档本来就是"一整份配置的快照",里面没有任何"我属于哪个角色"的绑定 ——
    -- 按角色分文件只是存储上的选择(和配置本身按 kind_id 分文件同一个原因),不是能力限制。
    -- 真正的限制在**材质名**上:读进来之后对不上的整套造型会被判"材质不匹配"跳过、
    -- 状态里引用不到的材质被忽略。所以跨角色读档对"同一个模型装在不同角色上"是完全可用的,
    -- 对不同模型则相当于"把结构(状态组/条件/规则)搬过来,材质部分自己再抓一遍"。
    --
    -- 枚举靠 global_config.known(已知角色登记表),不需要目录遍历 API。
    local function all_slot_entries(kind_id)
        local own_key = cfg_key(kind_id)
        local keys, seen = { own_key }, { [own_key] = true }
        for _, k in ipairs(global_config.known or {}) do
            local ck = cfg_key(k)
            if not seen[ck] then seen[ck] = true; table.insert(keys, ck) end
        end

        local entries = {}
        for i, key in ipairs(keys) do
            local names = {}
            for n, _ in pairs(get_slots_by_key(key)) do table.insert(names, n) end
            table.sort(names)
            for _, n in ipairs(names) do
                table.insert(entries, {
                    key = key,
                    name = n,
                    own = (key == own_key),
                    -- 别人的存档带上角色前缀,一眼看得出这是从哪搬来的
                    label = (key == own_key) and n or (key .. " / " .. n),
                    sort_key = string.format("%03d|%s", i, n),
                })
            end
        end
        table.sort(entries, function(a, b) return a.sort_key < b.sort_key end)
        return entries
    end

    local function auto_slot_name()
        local ok, s = pcall(function() return os.date("%m%d-%H%M") end)
        if ok and type(s) == "string" and s ~= "" then return s end
        return tostring(math.floor(os.clock() * 1000))
    end

    -- 存进去的必须是深拷贝:直接放引用的话它就是活配置本身,之后每次编辑都会跟着变
    local function save_slot(kind_id, name)
        local cfg = loaded_configs[cfg_key(kind_id)]
        if not cfg then return end
        get_slots(kind_id)[name] = deep_copy(cfg)
        save_slots_file(kind_id)
    end

    -- ============================================================
    -- 应用
    -- ============================================================

    -- 「定位」预览:临时只显示某一个材质,用来认清它是哪块(给材质起备注名时用)。
    -- 纯预览,**不写进任何预设**;到时间自动恢复,所以不会留下脏状态。
    -- mats = { [槛位] = { [材质] = true } } 要显示的材质;hold = 「仅显示选中部位」开着(不过期,until_clock = nil)
    local preview = nil            -- { mats=, slot=, mat=, until_clock=, hold=, target_id=, saved = { [槛位] = { id=, states= } } }
    local PREVIEW_SECONDS = 3
    local preview_restoring = false -- 预览刚过期的那一帧:恢复时不用溶解过渡
    local preview_ending = nil      -- 刚结束的预览(那一帧用它的 saved 把定位前的开关放回去)

    -- 面板当前编辑的目标(Targets.collect 给的 id)。nil = 还没选过,取第一个(本地玩家)。
    local selected_target_id = nil

    -- 一个槛位的材质开关,经过溶解(Dissolve.lua):带 Dissolve_Rate 的材质按过渡溶解,其余照旧瞬间开关。
    --   owner_of(slot, mat) -> 决定这个材质的层键;trans[层键] = 这一层当前的过渡设置(nil = 瞬间)
    --   drive[mat] = { on = 终点外观里的开关, p = 进度 }:血量驱动中、两种外观里开关不同的材质
    -- 只处理传进来的材质名,没提到的材质保持原状(同 Utils.apply_preset_to_slot)。
    local function apply_slot(mesh, slot, slot_data, owner_of, trans, drive)
        local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
        if not ok or not count or count <= 0 then return end
        for i = 0, count - 1 do
            local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
            if ok_n and name then
                local d = drive and drive[name]
                local want = slot_data.materials[name]
                if d or want ~= nil then
                    local ok_c, cur = pcall(function() return mesh:call("getMaterialsEnable", i) end)
                    if ok_c then
                        if d then
                            pcall(Dissolve.drive_material, mesh, i, d.on, d.p, cur)
                        elseif cur ~= want or Dissolve.is_animating(mesh, i) then
                            local key = owner_of and owner_of(slot, name)
                            Dissolve.use(trans and key and trans[key] or nil)
                            pcall(Dissolve.set_material, mesh, i, want, cur)
                        end
                    end
                end
            end
        end
        Dissolve.use(nil)
    end

    -- 一个 mesh 当前每个材质的开关(按下标),定位开始前存一份,结束时照原样放回
    local function material_states(mesh)
        local states = {}
        local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
        if not ok or not count then return states end
        for i = 0, count - 1 do
            local ok_c, cur = pcall(function() return mesh:call("getMaterialsEnable", i) end)
            if ok_c then states[i] = cur end
        end
        return states
    end

    -- 定位结束:先把定位前存下的开关原样放回(mesh 已换实例的跳过),再由正常应用接管。
    -- 不能只靠正常应用恢复 —— 它只写配置里点名过的材质,没点名的(或整个没配置的槛位)
    -- 会一直停在定位时被关掉的状态。
    local function restore_preview_snapshot(source, saved)
        for slot, s in pairs(saved or {}) do
            local mesh = Utils.get_mesh(source, slot)
            if mesh and tostring(mesh) == s.id then
                for i, on in pairs(s.states) do
                    pcall(function() mesh:call("setMaterialsEnable", i, on) end)
                end
            end
        end
    end

    -- 定位显示的槛位:被定位的那个;开着「armor 照抄 body」时 body / armor 互相带上
    -- (穿着护甲时游戏把 body 换成 armor,只隔离 body 看不到任何东西)
    local function preview_shows(active_preview, slot, name, mirror)
        local mats = active_preview.mats
        if mats[slot] and mats[slot][name] then return true end
        if not mirror then return false end
        local other = (slot == "armor" and "body") or (slot == "body" and "armor") or nil
        return other ~= nil and mats[other] ~= nil and mats[other][name] == true
    end

    local function apply_resolved(source, resolved, active_preview, owner_of, trans, drive_map, mirror)
        if not resolved then return end
        if not active_preview then
            -- 溶解效果提供者按这个角色开事务(见 EffectProviders.lua 的 scope)
            Dissolve.effect_scope(source)
            for _, slot in ipairs(Utils.MESH_SLOTS) do
                local slot_data = resolved[slot]
                if slot_data then
                    local mesh = Utils.get_mesh(source, slot)
                    if mesh then apply_slot(mesh, slot, slot_data, owner_of, trans, drive_map and drive_map[slot]) end
                end
            end
            Dissolve.effect_scope(nil)
            return
        end
        -- 定位中:所有槛位都不走正常应用(正常应用会给被定位关掉 / 打开的材质起溶解过渡,
        -- 和定位每帧互相拉扯,定位就失效了)。被定位的槛位只显示这一个材质,
        -- 其余槛位(头、头发……)整个隐藏,瞬间切换不用溶解(进行中的溶解先复位成 mdf2 的值)
        local saved = active_preview.saved
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            local mesh = Utils.get_mesh(source, slot)
            if mesh then
                local id = tostring(mesh)
                if saved and (not saved[slot] or saved[slot].id ~= id) then
                    saved[slot] = { id = id, states = material_states(mesh) }
                end
                Dissolve.reset_mesh(mesh)
                local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
                for i = 0, ((ok and count) or 0) - 1 do
                    local ok_n, name = pcall(function() return mesh:call("getMaterialName", i) end)
                    if ok_n and name then
                        local want = preview_shows(active_preview, slot, name, mirror)
                        local ok_c, cur = pcall(function() return mesh:call("getMaterialsEnable", i) end)
                        if ok_c and cur ~= want then pcall(function() mesh:call("setMaterialsEnable", i, want) end) end
                    end
                end
            end
        end
    end

    -- 差分被冲掉的两种情形,分别对应下面两道检查。
    --
    -- 本来打算挂 CharacterContext.OnChangedBodyGameObject 那个 Action 委托,改成了自己比对,
    -- 理由:(1) REFramework Lua 侧往托管 Action 字段上追加回调并不好办;
    -- (2) 更重要的是,"mesh 实例变了"这个判据覆盖面**更宽** —— 换装、模型重载、重生、
    --     场景切换全都会让 mesh 换实例,而那个回调只在它自己那几个时机触发。
    -- 直接盯我们真正在意的不变量(我写过的那个 mesh 还是不是当前这个),比盯"谁通知我"更稳。
    local last_mesh_identity = {}
    local frame_counter = 0
    local DRIFT_CHECK_INTERVAL = 30

    -- UI 改了配置之后置上,下一帧强制重写一次(比如把某个材质从轴里摘掉,要退回基线值)
    local force_reapply = false

    -- 结束定位:下一帧瞬间恢复(先放回定位前的开关,再强制正常应用一次)
    local function end_preview()
        if not preview then return end
        preview_ending = preview
        preview = nil
        force_reapply = true
        preview_restoring = true
    end

    -- 模型高度:应用循环每帧按解算结果收集 { source, cm },循环结束交给 HeightFix(下面安装)
    local height_fix = nil
    local frame_heights = {}

    -- 调色盘(Palette.lua)。映射 = 内置(PaletteProfiles.lua)+ data/ArmorVariantManager/material_profiles/*.json,
    -- 同 id 的外部文件覆盖内置;按需读一次,网页上「重新读取映射」时重读。
    -- palette_state[target.id] = Palette.apply_mesh 的状态(各 mesh 的原值与写过的参数)
    local Palette = require("ArmorVariantManager_Core.Games.RE4.Palette")
    local Mdf2 = require("ArmorVariantManager_Core.Games.RE4.Mdf2")
    -- 必须在脚本加载时 require:REFramework 只在加载 autorun 期间把 autorun 目录放进 package.path,
    -- 之后(网页请求、每帧回调里)再 require 会找不到模块
    local PaletteProfiles = require("ArmorVariantManager_Core.Games.RE4.PaletteProfiles")
    local PALETTE_DIR = "ArmorVariantManager/material_profiles/"
    local palette_profiles, palette_by_id, palette_profile_errors = nil, nil, {}
    local palette_state = {}
    -- 调色方案:palette_sig[target.id] = 上次写入时生效的方案组合(名字串);组合变了就重写调色
    local palette_sig = {}
    -- 整套造型快捷键(Hotkeys.lua):这一帧主控角色的配置和解算结果,没有主控 / 不是 v3 时为 nil
    local hotkey_ctx = nil
    local hotkey_logic = nil
    -- 武器显示:这一帧主控角色胜出的条件状态要求的模式("stowed" / "all" / nil)
    local frame_weapons = nil
    local function load_palette_profiles(reload)
        if palette_profiles and not reload then return palette_profiles, palette_by_id end
        local extras, errors = {}, {}
        -- glob 会遍历整个 data 目录,遇到转不成系统代码页的文件名会抛错(见 Presets.lua),必须包 pcall
        local ok, found = false, nil
        if fs and fs.glob then ok, found = pcall(fs.glob, "ArmorVariantManager[/\\\\]material_profiles[/\\\\][^/\\\\]*\\.json") end
        if ok and type(found) == "table" then
            table.sort(found)
            for _, raw in ipairs(found) do
                local file = tostring(raw):match("([^/\\]+%.json)$")
                local ok_l, data = pcall(json.load_file, PALETTE_DIR .. file)
                if ok_l and type(data) == "table" and Palette.clean_profile(data) then extras[#extras + 1] = data
                else errors[#errors + 1] = file end
            end
        end
        palette_profiles, palette_by_id = Palette.load_profiles(PaletteProfiles, extras)
        palette_profile_errors = errors
        return palette_profiles, palette_by_id
    end
    -- 写调色时同步溶解的 Dissolve_Flag 底值
    -- 内置溶解样式(DissolveStyles.lua):注册成效果提供者;噪声图在第一帧预加载
    -- 自己加载的 resource 和 holder 都存进 style_textures 一直持有(实测不持有会闪退)
    local style_textures = {}
    local dissolve_styles = DissolveStyles.new({
        load_texture = function(path)
            local res = sdk.create_resource("via.render.TextureResource", path)
            if not res then return nil end
            res = res:add_ref()
            local h = res:create_holder("via.render.TextureResourceHolder"):add_ref()
            style_textures[#style_textures + 1] = res
            style_textures[#style_textures + 1] = h
            return h
        end,
        presets = function() return global_config.dissolve_presets end,
        vec4 = function(x, y, z, w) return Vector4f.new(x, y, z, w) end,
    })
    local ok_styles, err_styles = pcall(Dissolve.register_effect_provider, dissolve_styles.provider)
    if not ok_styles and log and log.error then log.error("[AVM] dissolve styles: " .. tostring(err_styles)) end
    local styles_preloaded = false

    local function on_palette_write(m, j, param, value)
        if param == "Dissolve_Flag" then Dissolve.set_flag_base(m, j, value) end
        dissolve_styles.on_param_write(m, j, param, value)
    end
    -- pal:叠好的覆盖表(v3 = 生效的方案,v2 = config.palette)。还原的目标优先取 mdf2 文件里的原值
    -- (mdf2_cache:{ [相对路径] = 解析结果 | false },换 mdf / 重读映射时清空)
    local mdf2_cache = {}
    local function file_original(mesh, _, material, param) return Mdf2.file_value(mesh, material, param, mdf2_cache) end
    local function apply_palette(target, source, pal)
        local state = palette_state[target.id]
        if pal and next(pal) == nil then pal = nil end
        if not pal and not state then return end
        state = state or {}
        palette_state[target.id] = state
        local live = {}
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            local mesh = Utils.get_mesh(source, slot)
            if mesh then
                live[tostring(mesh)] = true
                Palette.apply_mesh(mesh, pal and pal[slot], state, on_palette_write, file_original)
            end
        end
        Palette.prune(state, live)
    end
    -- 调色渐变:palette_fade[target.id] = { plans = { [mesh 键] = { mesh, plan } }, pal = 终点, dur, elapsed, last };
    -- palette_prev[target.id] = 上一帧的方案组合 { names, src, states }(算渐变时长用)
    local palette_fade, palette_prev = {}, {}
    -- 血量驱动的调色方案:palette_wsig[target.id] = 上次的权重签名;palette_drive_keys[target.id] = 用着的平滑键
    local palette_wsig, palette_drive_keys = {}, {}
    local palette_discrete, palette_discrete_for = nil, nil
    local function discrete_params()
        local profiles = load_palette_profiles()
        if palette_discrete_for ~= profiles then
            palette_discrete, palette_discrete_for = Palette.discrete_params(profiles), profiles
        end
        return palette_discrete
    end
    local function begin_palette_fade(target, source, pal, dur)
        local state = palette_state[target.id] or {}
        palette_state[target.id] = state
        local fade = { plans = {}, pal = pal, dur = dur, elapsed = 0, last = os.clock() }
        local discrete = discrete_params()
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            local mesh = Utils.get_mesh(source, slot)
            if mesh then
                local plan = Palette.fade_begin(mesh, pal and pal[slot], state, discrete, file_original)
                if plan then fade.plans[tostring(mesh)] = { mesh = mesh, plan = plan } end
            end
        end
        return next(fade.plans) and fade or nil
    end
    -- 推进一帧;走完了返回 true(调用方再写一次终点)。卡顿时一帧最多算 0.1 秒,同溶解
    local function step_palette_fade(fade)
        local now = os.clock()
        fade.elapsed = fade.elapsed + math.min(math.max(now - fade.last, 0), 0.1)
        fade.last = now
        local p = fade.dur > 0 and fade.elapsed / fade.dur or 1
        if p >= 1 then return true end
        for _, e in pairs(fade.plans) do Palette.fade_step(e.mesh, e.plan, p, on_palette_write) end
        return false
    end
    local function request_reapply() force_reapply = true end

    -- Ops 的返回值 → 存盘 / 重写。ImGui 和 REFF 改配置都走这里。
    local function commit(kind_id, changed, reapply)
        if changed then save_config(kind_id) end
        if changed and reapply then request_reapply() end
        return changed
    end

    -- ============================================================
    -- 预设库(v3),见 Presets.lua。当前配置是唯一生效的那份,预设只是套用的来源;
    -- 套用 = 当前配置先进自动保存,再整份换成预设的内容。从不自动切换。
    -- ============================================================
    local preset_lib = Presets.library({
        load = function(path) return json.load_file(path) end,
        dump = function(path, t) return json.dump_file(path, t) end,
        glob = (fs and fs.glob) and function(pattern) return fs.glob(pattern) end or nil,
        now = os.time,
    })
    -- "不用了"按模型记:[配置键] = 当时的材质签名;模型再变就重新提醒
    local preset_dismissed = {}

    local function live_sets_of(source) return Presets.live_sets(Utils.all_enabled_preset(source)) end
    local function live_signature(sets)
        local parts = {}
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            local names = {}
            for m in pairs(sets[slot] or {}) do names[#names + 1] = m end
            table.sort(names)
            parts[#parts + 1] = slot .. ":" .. table.concat(names, ",")
        end
        return table.concat(parts, "|")
    end

    -- 原地换内容:其他地方(解算缓存、面板)拿着的是同一个表
    local function replace_config(cfg, new)
        for k in pairs(cfg) do cfg[k] = nil end
        for k, v in pairs(normalize_config(new)) do cfg[k] = v end
        TransformManager.clear_last_state_cache()
    end

    -- v2 的优先级 = 应用顺序倒过来(后写的优先)
    local function v2_priority(cfg)
        local apply, out = TransformManager.axis_apply_order(cfg), {}
        for i = #apply, 1, -1 do out[#out + 1] = apply[i] end
        return out
    end

    local function preset_view(kind_id, source)
        local key = cfg_key(kind_id)
        local cfg = loaded_configs[key]
        local live = live_sets_of(source)
        local ranked = Presets.ranked(preset_lib, live)
        local current = (cfg and ModelV3.is_v3(cfg)) and Presets.match(cfg, live) or nil
        local better = {}
        if current and current ~= "full" then
            for _, r in ipairs(ranked) do if r.match == "full" then better[#better + 1] = r.entry end end
        end
        return {
            current = current,
            source = cfg and cfg.source_preset and preset_lib.get(cfg.source_preset) or nil,
            presets = ranked, better = better,
            dismissed = preset_dismissed[key] == live_signature(live),
            autosaves = preset_lib.autosaves(key),
        }
    end

    local function dismiss_preset_hint(kind_id, source)
        preset_dismissed[cfg_key(kind_id)] = live_signature(live_sets_of(source))
        return true
    end

    local function apply_preset(kind_id, id)
        local key = cfg_key(kind_id)
        local cfg, e = loaded_configs[key], preset_lib.get(id)
        if not cfg or not e or not ModelV3.is_v3(cfg) then return false end
        preset_lib.autosave_push(key, string.format(T("autosave_before_apply"), e.name), cfg)
        local new = deep_copy(e.config)
        new.version = ModelV3.VERSION
        replace_config(cfg, new)
        cfg.source_preset = id
        commit(kind_id, true, true)
        return true
    end

    -- 新建空白配置:整套造型、状态组、条件状态、调色方案、快捷键全部清空,
    -- 材质备注、护甲同步、高度覆盖这几项设定保留(它们不是"造型内容")。
    -- 给常用场景用:换了整个 mod,旧配置和预设库都对不上,想从头配。
    -- capture = true 时先抓取当前外观,作为整套造型「1」并选中 —— 在清空**之前**抓取,
    -- 抓到的是用户此刻眼前的样子。清空前的配置进自动保存,和套用预设一样可以恢复。
    local function new_blank_config(kind_id, source, capture)
        local key = cfg_key(kind_id)
        local cfg = loaded_configs[key]
        if not cfg or not ModelV3.is_v3(cfg) then return false end
        local look = (capture and source) and Utils.capture_current_as_preset(source) or nil
        preset_lib.autosave_push(key, T("autosave_before_blank"), cfg)
        local new = ModelV3.new_config()
        new.material_notes = deep_copy(cfg.material_notes)
        new.armor_mirrors_body = cfg.armor_mirrors_body
        new.height_override = deep_copy(cfg.height_override)
        if look then Ops.new_preset(new.base, look) end
        replace_config(cfg, new)
        commit(kind_id, true, true)
        return true
    end

    local function save_current_as_preset(kind_id, name)
        local key = cfg_key(kind_id)
        local cfg = loaded_configs[key]
        if not cfg or not ModelV3.is_v3(cfg) then return nil end
        local id = preset_lib.save_new(name, cfg, key)
        if id then cfg.source_preset = id; commit(kind_id, true, false) end
        return id
    end

    local function update_source_preset(kind_id)
        local cfg = loaded_configs[cfg_key(kind_id)]
        if not cfg or not cfg.source_preset then return false end
        return preset_lib.update(cfg.source_preset, cfg)
    end

    local function restore_autosave(kind_id, k)
        local key = cfg_key(kind_id)
        local cfg = loaded_configs[key]
        if not cfg or not ModelV3.is_v3(cfg) then return false end
        local a = preset_lib.autosave_take(key, k)
        if not a then return false end
        preset_lib.autosave_push(key, T("autosave_before_restore"), cfg)
        local new = deep_copy(a.config)
        new.version = ModelV3.VERSION
        replace_config(cfg, new)
        commit(kind_id, true, true)
        return true
    end

    local function promote_autosave(kind_id, k, name)
        local key = cfg_key(kind_id)
        local a = preset_lib.autosaves(key)[tonumber(k) or -1]
        if not a then return nil end
        local id = preset_lib.save_new(name, a.config, key)
        if id then preset_lib.autosave_take(key, k) end
        return id
    end

    -- v2 → v3(状态组平铺 + 条件状态)。由用户在杂项页 / 面板上点"迁移旧配置"触发,不自动迁移。
    -- 迁移前写一份还原点("恢复到上次删除 / 覆写之前"能退回 v2)。
    -- 旧的命名存档(backup/<角色>.slots.json)逐条转成预设,原文件保留不删。
    -- 返回 ModelV3 的 report + presets(转换出来的预设编号);
    -- 已经是 v3 / 没有配置时返回 nil。
    local function migrate_to_v3(kind_id)
        local key = cfg_key(kind_id)
        local cfg = loaded_configs[key]
        if not cfg or ModelV3.is_v3(cfg) then return nil end
        snapshot_before_destructive(kind_id)
        local v3, report = ModelV3.migrate_from_v2(cfg, v2_priority(cfg), T("base_layer"))
        replace_config(cfg, v3)
        commit(kind_id, true, true)

        report.presets = {}
        local slots = get_slots_by_key(key)
        local names = {}
        for n in pairs(slots) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            local old = normalize_config(deep_copy(slots[n]))
            if not ModelV3.is_v3(old) then old = (ModelV3.migrate_from_v2(old, v2_priority(old), T("base_layer"))) end
            local id = preset_lib.save_new(key .. " · " .. n, old, key)
            if id then report.presets[#report.presets + 1] = id end
        end
        return report
    end

    -- 玩家的装备组件。调用链(2026-08 用 reframework MCP 实测确认过):
    --   context -> get_HeadUpdater() -> get_Equipment()
    -- 这条链只对**真玩家**有意义,不走 Targets 那套傀儡/雕像分支。
    local function get_equipment(context)
        if not context then return nil end
        local ok, equip = pcall(function()
            local head = context:call("get_HeadUpdater")
            return head and head:call("get_Equipment")
        end)
        if ok and equip and sdk.is_managed_object(equip) then return equip end
        return nil
    end

    -- 当前手持武器的 mesh:Equipment.getEquipWeapon() -> get_Mesh()。
    -- 赤手、换武器插值过程中等任一环节都可能是 nil —— 一律当"这一帧没有武器可处理",
    -- 不报错、不重试。
    local function get_weapon_mesh(context)
        local equip = get_equipment(context)
        if not equip then return nil end
        local ok, mesh = pcall(function()
            local arms = equip:call("getEquipWeapon")
            return arms and arms:call("get_Mesh")
        end)
        if ok and mesh and sdk.is_managed_object(mesh) then return mesh end
        return nil
    end

    -- 枚举的底层数值都存在 `value__` 字段里 —— `get_MountWeaponIDs()` 返回的是
    -- **值类型枚举数组**,遍历出来的每个元素是装箱后的对象,不能直接拿去当
    -- getWeapon(WeaponID) 的参数用(会静默失败,返回 nil),得先转成裸数字。
    local function weapon_id_value(wid)
        if type(wid) == "number" then return wid end
        local ok, v = pcall(function() return wid:get_field("value__") end)
        if ok and type(v) == "number" then return v end
        return nil
    end

    -- 隐藏「收纳武器」(挂在背后/腰间、当前没拿在手上的那些)。
    --
    -- `context:get_MountWeaponIDs()` 就是挂在身上但不在手里的那批武器 ID;对每个
    -- ID 用 `Equipment.getWeapon(id)` 拿到它自己的 Arms,`get_Mesh()` 和手持武器
    -- 是同一种 via.render.Mesh,直接 set_Enabled 整只开关。
    --
    -- **不管开关开没开都要跑一遍**:开关关掉之后,之前被这段代码隐藏过的收纳武器
    -- 得靠这里主动写回 true 才能显示回来,不然会一直隐身下去。
    --
    -- **拿出来的武器也要救回来**:一把武器从"收纳"变成"拿在手上"之后就不在
    -- mount 列表里了,上面那段循环压根碰不到它——如果它之前被藏起来过,这里不
    -- 主动写回 Enabled=true 的话,它会一直卡在隐藏状态,永远显示不出来(实测踩过)。
    --
    -- mode 来自玩家配置里胜出的条件状态(ModelV3.resolve 的 weapons):
    --   "stowed" = 隐藏收纳武器;"all" = 收纳武器和手上那把都隐藏;nil = 没有状态管,按全局开关。
    -- 实测 MountWeaponIDs 里包括小刀(wp5000,chainsaw.Melee)和身上的雷,手上的雷也有自己的 Mesh。
    local function apply_weapon_hide_storage(context, mode)
        local hide = (mode == "stowed" or mode == "all") or (mode == nil and global_config.weapon_hide_storage == true)
        local hide_held = mode == "all"
        local equip = get_equipment(context)
        if not equip then return end

        local ok, ids = pcall(function() return context:call("get_MountWeaponIDs") end)
        if ok and ids then
            local ok2, elems = pcall(function() return ids:get_elements() end)
            if ok2 and elems then
                for _, wid in ipairs(elems) do
                    local wid_int = weapon_id_value(wid)
                    if wid_int then
                        local ok3, mesh = pcall(function()
                            local arms = equip:call("getWeapon", wid_int)
                            return arms and arms:call("get_Mesh")
                        end)
                        if ok3 and mesh and sdk.is_managed_object(mesh) then
                            pcall(function() mesh:call("set_Enabled", not hide) end)
                        end
                    end
                end
            end
        end

        local held_mesh = get_weapon_mesh(context)
        if held_mesh then
            pcall(function() held_mesh:call("set_Enabled", not hide_held) end)
        end
    end

    -- ============================================================
    -- 溶解过渡(Dissolve.lua)
    --
    -- 每个目标记住各层上一帧的选择。某一层的选择变了,就按"引起变化的那条规则"定这一层的过渡,
    -- 这一层写出的材质都用它,直到下一次变化:
    --   * 进入一条规则的状态:用这条规则的渐入时间。新状态的优先级比原来的高(在状态列表里更靠上,
    --     或原来是手动选的)= 正向(中心向外);否则反向(外向中心)
    --   * 规则不再成立、回到手动选择:用这条规则的渐出时间,反向
    --   * 两边都不是规则(在面板上手动切换):用全局的「界面切换溶解」设置,正向
    -- 首次应用、mesh 换了实例时一律瞬间,不播过渡。
    --
    -- 血量驱动:层里勾了「按血量驱动」的规则组成一条链(见 TransformManager 的 hp_chain)。
    -- 进度按目标 + 层平滑;这一段起点与终点两种外观里开关不同的材质交给 Dissolve.drive_material,
    -- 其余材质照常。驱动期间每帧都重写。
    -- ============================================================
    local dissolve_state = {}   -- target.id -> { picks = { [层键] = { name, rule } }, trans = {}, owner = {}, drives = {} }
    local trans_seq = 0         -- 过渡的先后序号(Dissolve.transition_layer 用它挑最近换过选项的层)

    local function layer_of(config, key)
        if key == "base" then return config.base end
        if key:sub(1, 6) == "group:" then return (ModelV3.find_group(config, key:sub(7))) end
        return (config.axes or {})[key:sub(6)]
    end

    -- 状态在层里的优先级位置(越小越优先);手动选择 / 无 = 最低
    local function layer_pos(layer, name)
        if not layer or not name then return math.huge end
        local order = layer.order
        if type(order) ~= "table" or #order == 0 then
            order = {}
            for n, _ in pairs(layer.presets or {}) do table.insert(order, n) end
            table.sort(order)
        end
        for i, n in ipairs(order) do if n == name then return i end end
        return math.huge
    end

    -- 溶解预设(全局库,DissolveStyles):按引起这次切换的来源选,
    --   条件状态引用的 → 切到的整套造型预设 / 状态组选项引用的 → 都没有就是 nil(用库里的默认)
    local function dissolve_ref(layer, name)
        local refs = layer and layer.dissolves
        return type(refs) == "table" and name and refs[name] or nil
    end

    -- 面板上手动操作的过渡:界面溶解设置(开关、时长),溶解预设看这一层当前选项引用的
    local function manual_transition(layer, name)
        return { enabled = global_config.ui_dissolve_enabled ~= false,
                 dur = math.max(0, math.min(30, tonumber(global_config.ui_dissolve_time) or 1.0)), forward = true,
                 preset = dissolve_ref(layer, name) }
    end

    local function choose_transition(layer, old, new)
        if new.rule then
            if new.rule.dissolve_enabled ~= true then return nil end
            -- v3 的优先级是条件状态的顺序(prio),v2 是层内状态的顺序
            local forward = (not old.rule) or ((new.prio and old.prio) and new.prio < old.prio)
                or (not (new.prio and old.prio) and layer_pos(layer, new.name) < layer_pos(layer, old.name))
            return { enabled = true, dur = tonumber(new.rule.dissolve_hide_time) or 0.5, forward = forward,
                     preset = new.rule.dissolve_preset or dissolve_ref(layer, new.name) }
        elseif old.rule then
            if old.rule.dissolve_enabled ~= true then return nil end
            return { enabled = true, dur = tonumber(old.rule.dissolve_show_time) or 0.5, forward = false,
                     preset = old.rule.dissolve_preset or dissolve_ref(layer, new.name) }
        end
        return manual_transition(layer, new.name)
    end

    local function copy_picks(t)
        local o = {}
        for k, v in pairs(t) do o[k] = v end
        return o
    end

    -- 一个目标一帧的活。玩家和 CG 傀儡走的是**同一条**路径 —— 区别只在 target.source
    -- 是 BodyUpdater 还是一张 mesh 表,而那个区别整个封在 Utils.get_mesh 里。
    local function apply_target(target, preview_active)
        local source = target.source
        local kind_id, how = resolve_config_key(target)

        -- 没有可用配置就**什么都不做**。最典型的是"雕像认出是 Leon,但 Leon 还没有配置" ——
        -- 这时候硬跑一遍会把全启用底层写到雕像身上,是没必要的写入。
        if not kind_id then return end

        local config
        if target.borrowed then
            -- **借用的目标(模型鉴赏雕像)绝不能产生配置。**
            -- 不 register_kind:雕像不是一个角色,进了 known 会污染认亲候选表。
            -- source 传 nil 是刻意的:这样"第一次遇到"那条分支里的
            -- capture_current_as_preset / save_config 走不到,雕像**在任何情况下都无法**
            -- 写盘、也无法用自己的材质集去种一份 default。
            config = load_config(kind_id, nil, false)
        else
            -- 登记也放在这里,不能只放 UI 里:认亲要靠这份登记表找候选,而"玩过这个角色"
            -- 比"打开过面板"更可靠 —— 否则没开过面板的角色永远不会成为认亲的候选。
            register_kind(kind_id)
            -- 只有身份认不出来(走旧 kind 键)时才允许认亲
            config = load_config(kind_id, source, how == "legacy")
        end
        -- resolve 的第一个参数只是变化检测的缓存键,必须**按目标**唯一:
        -- 同一个 kind 的两具傀儡同时在场时,用 kind_id 当键会让它俩互相顶掉签名,
        -- 表现成 changed 乱跳。
        local resolved, changed, info = TransformManager.resolve(target.id, config, target.context, source)
        if info.v3 and not target.borrowed and type(target.id) == "string" and target.id:sub(1, 7) == "player:" then
            hotkey_ctx = { kind_id = kind_id, config = config, v3 = info.v3, layers = info.layers }
            frame_weapons = info.v3.weapons
        end

        -- 模型高度:整套造型 → 状态组按叠加顺序,最后设过的那一层说了算
        if global_config.height_enabled ~= false and info.v3 then
            local cm = ModelV3.height_of(config, info.v3.picks)
            if cm and cm ~= 0 then frame_heights[#frame_heights + 1] = { source = source, cm = cm } end
        end

        -- 一:mesh 实例被换掉 —— 之前写的开关必然全丢,无条件重新应用。每帧四次指针比较,很便宜。
        local identity = Utils.get_mesh_identity(source)
        local mesh_swapped = (last_mesh_identity[target.id] ~= identity)
        last_mesh_identity[target.id] = identity

        -- 溶解:各层选择的变化 → 这一层的过渡;首次 / mesh 换实例时清空(瞬间应用)
        local ds = dissolve_state[target.id]
        local fresh = mesh_swapped or not ds
        if fresh then
            for dkey, _ in pairs(ds and ds.drives or {}) do Dissolve.drive_end(dkey) end
            ds = { picks = {}, trans = {}, owner = {}, drives = {} }
            dissolve_state[target.id] = ds
        end
        local switched = {}
        for key, cur in pairs(info.layers) do
            local old = ds.picks[key]
            if not fresh and old and old.name ~= cur.name then
                local tr = choose_transition(layer_of(config, key), old, cur) or { enabled = false }
                trans_seq = trans_seq + 1
                tr.seq = trans_seq
                ds.trans[key] = tr
                switched[key] = true
            end
            ds.picks[key] = cur
        end

        -- 血量驱动:起点外观(各驱动层取本段起点)照常应用,和本段终点不同的材质按进度溶解
        local drive_map, drive_stopped = nil, false
        local now_drives = {}
        if next(info.drives) then
            local from_picks, segments = copy_picks(info.picks), {}
            for key, d in pairs(info.drives) do
                local dkey = target.id .. "|" .. key
                now_drives[dkey] = true
                local chain = Dissolve.drive_progress(dkey, d.chain)
                local k = math.max(1, math.min(#d.names, math.ceil(chain)))
                from_picks[key] = (k > 1) and d.names[k - 1] or d.base_name
                segments[key] = { to = d.names[k], p = math.max(0, math.min(1, chain - (k - 1))) }
            end
            local from_owner
            resolved, from_owner = info.build(from_picks)
            info.owner = from_owner
            drive_map = {}
            for key, seg in pairs(segments) do
                local to_picks = copy_picks(from_picks)
                to_picks[key] = seg.to
                for slot, data in pairs((info.build(to_picks))) do
                    for m, v in pairs(data.materials) do
                        local f = resolved[slot] and resolved[slot].materials[m]
                        if f ~= nil and f ~= v then
                            drive_map[slot] = drive_map[slot] or {}
                            drive_map[slot][m] = { on = v, p = seg.p }
                        end
                    end
                end
            end
        end
        for dkey, _ in pairs(ds.drives) do
            if not now_drives[dkey] then Dissolve.drive_end(dkey); drive_stopped = true end
        end
        ds.drives = now_drives
        -- 材质归属 → 用哪一层的过渡:见 Dissolve.transition_layer(放手的层也要带过渡)
        local owner, prev_owner = info.owner, ds.owner
        -- 预览刚结束的那一次恢复也是瞬间的:被预览关掉的材质不该一个个溶解着"出现"
        local trans = (not fresh) and (not preview_restoring) and ds.trans or nil
        -- 面板改了某层当前选项里的材质(选项没换,例如勾掉整套造型里的一个材质):这一帧用界面溶解设置。
        -- 以前这种改动沿用这一层上一次换选项时留下的过渡:这一层从没换过选项(只有一个预设、
        -- 或模型鉴赏里新出现的人偶)就没有过渡,材质直接开关;换过的话用的是那次的时长和方向。
        -- 只放在这一帧的副本里,不写回 ds.trans,不影响之后"放手"时按 seq 选层。
        if trans and force_reapply then
            local edit = nil
            for key, cur in pairs(info.layers) do
                if not switched[key] then
                    edit = edit or copy_picks(trans)
                    local tr = manual_transition(layer_of(config, key), cur.name)
                    tr.seq = 0   -- 同一帧真换了选项的层优先
                    edit[key] = tr
                end
            end
            trans = edit or trans
        end
        local function owner_of(slot, mat)
            return Dissolve.transition_layer(owner[slot] and owner[slot][mat],
                prev_owner[slot] and prev_owner[slot][mat], trans)
        end

        -- 二:mesh 没换但开关被游戏重置了 —— 每帧全量核对太浪费,隔几十帧抽一次。
        -- 预览期间要跳过:那时 mesh 上的状态是故意和 resolved 不一致的,不是漂移。
        local drifted = false
        if (not changed) and (not mesh_swapped) and (not force_reapply) and (not preview_active)
            and (frame_counter % DRIFT_CHECK_INTERVAL == 0) then
            for _, slot in ipairs(Utils.MESH_SLOTS) do
                local slot_data = resolved and resolved[slot]
                if slot_data then
                    local mesh = Utils.get_mesh(source, slot)
                    if Utils.slot_state_drifted(mesh, slot_data) then drifted = true; break end
                end
            end
        end

        -- 预览期间每帧都重写:否则任何一次 resolve 输出或游戏自己的重置都会把它盖掉。
        -- 预览只作用在面板当前选中的那个目标上,不能糊到同 kind 的其它目标身上。
        local use_preview = preview_active and (preview.target_id == target.id) and preview or nil
        if preview_restoring and preview_ending and preview_ending.target_id == target.id then
            restore_preview_snapshot(source, preview_ending.saved)
        end
        if changed or mesh_swapped or drifted or force_reapply or use_preview or drive_map or drive_stopped then
            apply_resolved(source, resolved, use_preview, owner_of, trans, drive_map, config.armor_mirrors_body == true)
            -- 记住这次谁写了哪个材质;没写到的沿用旧的,好让"放手"那一帧还找得到是哪一层
            for slot, mats in pairs(owner) do
                prev_owner[slot] = prev_owner[slot] or {}
                for m, k in pairs(mats) do prev_owner[slot][m] = k end
            end
        end
        -- 调色盘:和材质开关同一套时机(换实例 / 配置变了 / 被重置 / 强制重写);预览和血量驱动的
        -- 每帧重写不带它,调色值不会被那些路径改掉。v3 另外看生效的调色方案组合变了没有
        -- (条件状态只带调色方案时,材质开关的 changed 不会变)
        -- 组合变了就渐变:进来的方案用带来它的条件状态的渐入时间,离开的用渐出,手动选择用界面溶解时间。
        -- 渐变中途再变就从当前显示的值接着走;首次 / 换实例 / 组合没变时的重写(调色页里直接改值)都是瞬间的
        local names, src, hpw = nil, nil, nil
        if info.v3 then names, src, hpw = ModelV3.palette_sources(config, info.v3) end
        -- 血量状态带来的方案:按血量进度加权叠加,权重平滑追向目标(同血量溶解,掉血时颜色渐变过去)。
        -- 这些方案不参与「组合变了就按时间渐变」:签名和渐变时长只看完全生效的方案;权重一变就直接重写
        local fixed, fixed_src, weights, wsig = names, src, nil, ""
        if names and next(hpw) then
            fixed, fixed_src, weights = {}, {}, {}
            local keys, parts = {}, {}
            for k, n in ipairs(names) do
                if hpw[k] ~= nil then
                    local dkey = target.id .. "|pal|" .. tostring(src[k]) .. "|" .. n
                    keys[dkey] = true
                    local w = Dissolve.drive_progress(dkey, hpw[k])
                    weights[k] = w
                    parts[#parts + 1] = string.format("%s=%.3f", n, w)
                else
                    weights[k] = 1
                    fixed[#fixed + 1] = n; fixed_src[#fixed_src + 1] = src[k]
                end
            end
            for dkey in pairs(palette_drive_keys[target.id] or {}) do if not keys[dkey] then Dissolve.drive_end(dkey) end end
            palette_drive_keys[target.id] = keys
            wsig = table.concat(parts, ",")
        elseif palette_drive_keys[target.id] then
            for dkey in pairs(palette_drive_keys[target.id]) do Dissolve.drive_end(dkey) end
            palette_drive_keys[target.id] = nil
        end
        local weights_changed = palette_wsig[target.id] ~= wsig
        palette_wsig[target.id] = wsig
        local sig = fixed and table.concat(fixed, "\0") or ""
        local scheme_changed = palette_sig[target.id] ~= sig
        palette_sig[target.id] = sig
        local cur = fixed and { names = fixed, src = fixed_src, states = config.conditions.states } or nil
        local prev = palette_prev[target.id]
        palette_prev[target.id] = cur
        local fade = palette_fade[target.id]
        if mesh_swapped or force_reapply or scheme_changed or (not fade and (changed or drifted or weights_changed)) then
            local pal
            if weights then
                -- 权重不到 1 的方案:没被下面的方案改过的参数从原值(mdf2 文件里的值)插值过去
                local index = {}
                local function original(slot, mat, param)
                    local mesh = Utils.get_mesh(source, slot)
                    if not mesh then return nil end
                    local mk = tostring(mesh)
                    if not index[mk] then
                        index[mk] = {}
                        local ok, count = pcall(function() return mesh:call("get_MaterialNum") end)
                        for j = 0, (ok and count or 0) - 1 do
                            local ok_n, n = pcall(function() return mesh:call("getMaterialName", j) end)
                            if ok_n and n and index[mk][n] == nil then index[mk][n] = j end
                        end
                    end
                    local j = index[mk][mat]
                    if j == nil then return nil end
                    local o = file_original(mesh, j, mat, param)
                    if o == nil then o = Palette.original(palette_state[target.id], mesh, j, param) end
                    return o
                end
                pal = ModelV3.palette_blend_of(config, names, weights, original, discrete_params())
            else
                pal = names and ModelV3.palette_of(config, names) or config.palette
            end
            pal = ModelV3.mirror_palette(pal, config.armor_mirrors_body == true)
            local manual = (global_config.ui_dissolve_enabled ~= false)
                and math.max(0, math.min(30, tonumber(global_config.ui_dissolve_time) or 1.0)) or 0
            -- 手动选方案 / 切整套造型这类操作提交时也会要求重写(force_reapply),所以只看组合变没变:
            -- 变了就按规则渐变;没变(调色页里直接改值)才瞬间写
            local dur = (scheme_changed and not mesh_swapped)
                and ModelV3.palette_fade_time(prev, cur, manual) or 0
            palette_fade[target.id] = dur > 0 and begin_palette_fade(target, source, pal, dur) or nil
            if not palette_fade[target.id] then apply_palette(target, source, pal) end
        elseif fade and step_palette_fade(fade) then
            palette_fade[target.id] = nil
            apply_palette(target, source, fade.pal)
            -- 渐变的终点是开始时按当时权重叠的;渐变期间血量变了的话,下一帧按现在的权重重写
            if weights then palette_wsig[target.id] = nil end
        end
    end

    local function frame_logic()
        if not styles_preloaded then
            styles_preloaded = true
            local ok, err = pcall(dissolve_styles.preload)
            if not ok then note_error("dissolve styles preload", err) end
        end
        -- 推进正在跑的溶解过渡(和有没有目标无关:目标消失时动画自己会清掉)
        Dissolve.update()
        frame_heights = {}
        hotkey_ctx = nil
        frame_weapons = nil
        local targets = Targets.collect()
        if #targets == 0 then
            if height_fix then height_fix.set_targets(frame_heights) end
            return
        end

        -- 有状态的条件(掉血计时之类)每帧维护一次,必须在 resolve 之前、且**只调一次** ——
        -- 所以放在目标循环**外面**。放进循环的话,场上有几个目标它就 tick 几次,
        -- "上次掉血距今多久"这类量会按目标数成倍走快。
        local context = targets[1].context
        if context then Registry.tick(context) end

        -- 定位预览:过期就清掉并强制恢复一次
        local preview_active = false
        if preview then
            if preview.hold or os.clock() < preview.until_clock then
                preview_active = true
            else
                end_preview()
            end
        end

        frame_counter = frame_counter + 1

        for _, target in ipairs(targets) do
            local ok, err = pcall(apply_target, target, preview_active)
            Dissolve.effect_scope(nil)   -- apply_target 中途抛错时 apply_resolved 来不及清
            -- 一个目标炸掉(傀儡正好这一帧被销毁之类)不该让其它目标也停掉
            if not ok then note_error("apply_target " .. tostring(target.label), err) end
        end
        if height_fix then height_fix.set_targets(frame_heights) end

        -- 武器显示放在目标循环之后:要用玩家配置这一帧解出来的 weapons(apply_target 里记下)
        local ok_ws, err_ws = pcall(apply_weapon_hide_storage, context, frame_weapons)
        if not ok_ws then note_error("weapon_hide_storage", err_ws) end

        force_reapply = false
        preview_restoring = false
        preview_ending = nil
    end

    re.on_frame(function()
        local ok, err = pcall(frame_logic)
        if not ok then note_error("on_frame", err) end
        -- 整套造型快捷键:看这一帧新按下的 Alt + 数字;切换提示画在左上角
        if hotkey_logic then
            local ok_h, err_h = pcall(hotkey_logic.tick)
            if not ok_h then note_error("hotkeys", err_h) end
            pcall(Hotkeys.draw_toast)
        end
        -- 调色页「替换 mdf」:等新 mdf2 加载完再换上(见 MdfReplace.lua)
        local ok_r, err_r = pcall(MdfReplace.tick)
        if not ok_r then note_error("mdf_replace", err_r) end
        -- 独立面板(没有 REFF 时的兜底界面):采样输入 → 布局并绘制 → 原位输入框。各自保护,出错不影响应用
        local panel = Main.panel
        if panel then
            local ok_f, err_f = pcall(panel.frame)
            if not ok_f then note_error("panel_frame", err_f) end
            panel.draw()
            panel.draw_inputs()
        end
    end)

    -- ============================================================
    -- UI
    -- ============================================================

    local new_axis_name = ""
    local pending_restore = nil     -- nil / "destructive" / "onload" / "slot":恢复的二次确认
    local pending_ownership = nil   -- nil / "independent" / "reset":归属操作的二次确认
    local slot_name_buf = ""        -- 命名存档的名字输入
    local slot_sel_idx = 1

    -- 每个层各自的 UI 状态,按 id_prefix 隔开,互不干扰
    local ui_state = {}
    local function get_ui_state(id_prefix)
        if not ui_state[id_prefix] then
            ui_state[id_prefix] = {
                name_buf = "",        -- 「当前预设名」输入框的缓冲
                name_buf_for = nil,   -- 这个缓冲属于哪个预设(切换选中时用来重同步)
                editing = nil,
                slot_filter = 1,        -- 1 = 全部
                pending_delete = nil,   -- 等待二次确认的预设名
                pending_recapture = false,
                rule = {                -- 「加条件」表单的状态(**不是**暂存的规则)
                    adding = false,     -- 表单展开着没
                    hold_buf = "0",     -- 「命中后保持」的输入缓冲
                    hold_buf_for = nil, -- 这个缓冲属于哪个目标状态(换目标时重同步)
                    logic_idx = 1,      -- 表单里选的"和已有条件的关系";打开表单时从规则同步
                    preset_idx = 1,
                    cond_type_idx = 1,
                    cond_op_idx = 1,
                    cond_num_value = "50",
                    cond_bool_idx = 1,
                    cond_enum_idx = 1,
                },
            }
        end
        return ui_state[id_prefix]
    end

    local function restore_from(path, kind_id)
        local data = json.load_file(path)
        if not data then return false end
        normalize_config(data)
        loaded_configs[cfg_key(kind_id)] = data
        save_config(kind_id)
        -- 恢复后 editing / pending 指向的预设可能已经不存在了,整份清掉重来
        ui_state = {}
        return true
    end
    local function restore_backup(kind_id) return restore_from(get_backup_path(kind_id), kind_id) end
    local function restore_onload_backup(kind_id) return restore_from(get_onload_backup_path(kind_id), kind_id) end





    -- from_key = 从哪个角色的存档文件里读(nil = 自己的)。读进来之后**存成当前角色的配置**,
    -- 不动来源那份 —— 跨角色读档是"复制过来",不是"共用"。
    local function load_slot(kind_id, name, from_key)
        local snap = get_slots_by_key(from_key or cfg_key(kind_id))[name]
        if not snap then return false end
        local data = deep_copy(snap)   -- 别把存档本身交出去,否则之后的编辑会改到存档
        normalize_config(data)
        loaded_configs[cfg_key(kind_id)] = data
        save_config(kind_id)
        ui_state = {}
        return true
    end

    -- 只能删自己的存档:在这个角色的面板上删掉另一个角色的存档太意外了
    local function delete_slot(kind_id, name)
        local slots = get_slots(kind_id)
        if not slots[name] then return false end
        slots[name] = nil
        save_slots_file(kind_id)
        return true
    end

    -- 共用 → 独立:从当前(共用的)内容拷一份成为自己的,什么都不丢。
    local function make_independent(kind_id)
        local shared_src = cfg_key(kind_id)
        if shared_src == kind_id then return false end
        local cur = loaded_configs[shared_src]
        local copy = normalize_config(deep_copy(cur or default_config()))
        if global_config.aliases then global_config.aliases[kind_id] = nil end
        save_global_settings()
        loaded_configs[kind_id] = copy
        save_config(kind_id)
        ui_state = {}
        request_reapply()
        return true
    end

    -- 初始化(只在独立时允许:共用时初始化会把来源角色一起清空)。先留备份。
    -- **不能产出完全空的配置**:空配置会立刻触发同族匹配、把共用又建回来,
    -- 于是初始化看起来毫无效果(初始化 ↔ 匹配 的死循环)。
    -- 带一个按当前显示状态抓的 default 整套预设,既撑成非空,也给了个可用基线。
    local function reset_config(kind_id, source)
        if cfg_key(kind_id) ~= kind_id then return false end
        snapshot_before_destructive(kind_id)
        local fresh = normalize_config(default_config())
        fresh.base.presets["default"] = Utils.capture_current_as_preset(source)
        fresh.base.order = { "default" }
        fresh.base.active = "default"
        loaded_configs[kind_id] = fresh
        save_config(kind_id)
        ui_state = {}
        request_reapply()
        return true
    end

    -- 「定位」:临时只显示这一个材质 PREVIEW_SECONDS 秒,只作用在指定目标上。
    -- 定位中再点别的材质:同一目标沿用最初存下的开关(这时 mesh 上已经是定位后的样子,不能重存);
    -- 换了目标就先让旧目标按自己的存档恢复
    local function begin_preview(target_id, mats, slot, mat, hold)
        local saved = {}
        if preview and preview.target_id == target_id then saved = preview.saved
        elseif preview then end_preview() end
        preview = { mats = mats, slot = slot, mat = mat, target_id = target_id, hold = hold or nil,
            until_clock = (not hold) and (os.clock() + PREVIEW_SECONDS) or nil, saved = saved }
    end
    local function start_preview(target_id, slot, mat)
        begin_preview(target_id, { [slot] = { [mat] = true } }, slot, mat, false)
        request_reapply()
    end
    -- 「仅显示选中部位」(调色页的开关):keys = { "槛位/材质", ... },一直生效到关掉 / 离开调色页 / 换角色。
    -- 空 / nil = 关掉;只关常驻的这种,不打断整套造型页的定位
    local function set_solo(target_id, keys)
        local mats, slot0, mat0 = {}, nil, nil
        for _, k in ipairs(type(keys) == "table" and keys or {}) do
            local slot, mat = tostring(k):match("^([^/]+)/(.+)$")
            if slot then
                mats[slot] = mats[slot] or {}
                mats[slot][mat] = true
                slot0, mat0 = slot0 or slot, mat0 or mat
            end
        end
        if not (target_id and slot0) then
            if preview and preview.hold then end_preview() end
            return
        end
        begin_preview(target_id, mats, slot0, mat0, true)
    end

    local function cond_to_string(c)
        local def = Registry.get(c.type)
        local label = def and T(def.label_key) or tostring(c.type)
        if def and def.kind == "bool" then
            return label .. " = " .. ((c.value == true) and T("yes") or T("no"))
        end
        if def and def.kind == "enum" then
            -- 裸数字("血量等级 == 2")没人看得懂,必须翻回档位名
            local vl = def.value_label and def.value_label(c.value, global_config.language) or tostring(c.value)
            return label .. " " .. tostring(c.op or "==") .. " " .. vl
        end
        return label .. " " .. tostring(c.op or "<=") .. " " .. tostring(c.value)
    end

    local function rule_to_string(rule)
        if rule.dissolve_hp_driven == true then
            -- 血量驱动的规则不看条件,概览里写它的血量范围
            return string.format(T("hp_drive_rule"), tonumber(rule.dissolve_hp_upper) or 100,
                tonumber(rule.dissolve_hp_lower) or 0) .. "  ->  " .. tostring(rule.preset or "")
        end
        local parts = {}
        for _, c in ipairs(rule.conditions or {}) do table.insert(parts, cond_to_string(c)) end
        if #parts == 0 then return T("cond_none") end
        local joiner = " " .. (((rule.logic or "AND") == "AND") and T("logic_and") or T("logic_or")) .. " "
        return table.concat(parts, joiner) .. "  ->  " .. tostring(rule.preset or "")
    end

    -- 状态/预设的显示顺序 = 优先级顺序。**所有列出它们的地方都用这个**(列表、快速切换的
    -- 下拉框、规则的目标选择),否则同一批东西在不同地方顺序不一样,优先级就没法看懂了。
    -- 返回副本:调用方拿去 table.insert 之类的时候不会改到配置。
    local function ordered_preset_names(layer)
        reconcile_order(layer)
        local out = {}
        for _, n in ipairs(layer.order) do table.insert(out, n) end
        return out
    end

    -- 槛位显示名:两套命名都给出。代码里的槛位名来自引擎 getter(get_BodyMesh),
    -- 而在 Blender / RE Mesh Editor 里看到的是 00/10/20 —— 只显示一套就得靠脑内换算。
    -- 走 T() 而不是写死,否则切到英文时这几个标题不会跟着变。
    -- 角色的显示名(本地化)。
    --
    -- **canonical 名字同时是配置键**(`Leon.json`),所以它绝对不能跟着语言变 ——
    -- 切一次语言配置文件就找不到了。只有显示这一层翻译,查不到译名就退回 canonical,
    -- 不要把 "char_leon" 这种键名露给用户。和 slot_label 一个套路。
    local function char_display(char)
        if not char then return nil end
        local key = "char_" .. string.lower(char)
        local v = T(key)
        return (v ~= key) and v or char
    end
    -- 目标的显示名:「Leon (ch0_a0z0)」。
    --
    -- 括号里是**引擎给的 kind**,不是配置键 —— 配置键现在就是角色名,写出来是
    -- 「Leon (Leon)」那种废话。两个信息不同:角色名是身份(按 head mesh 判的),
    -- kind 是引擎的角色槽位,同一个人可以有好几个(剧情里昂 / 佣兵里昂)。
    --
    -- 雕像没有 kind,所以只显示角色名。身份认不出来时只剩 kind。
    local function target_display_name(t)
        local who = char_display(t.ident and t.ident.character)
        local kid = t.kind_id and tostring(t.kind_id) or nil
        if who and kid then return who .. " (" .. kid .. ")" end
        return who or kid or "?"
    end
    local function slot_label(slot)
        local key = "slot_" .. slot
        local v = T(key)
        return (v ~= key) and v or slot
    end

    -- 这个角色实际存在的槛位。armor **不是**里昂身上恒定不存在的槛位 ——
    -- 它跟当前穿的皮肤绑定,默认皮肤下 HasArmorMesh=true,切到别的皮肤会变回 false
    -- (2026-08-24 用户反馈 + MeshProbe.lua 实测确认)。这里每次都实时查,
    -- 不缓存结果,换皮肤后这个函数自然会给出新答案。
    -- hide_mirrored_armor:镜像开着时,armor 在工作台/轴编辑器里编辑毫无意义
    -- (resolve 会整份覆盖掉),继续显示就是一堆点了没用的死控件。材质备注那边不传这个参数 ——
    -- 备注只是给材质起个人能看懂的名字,跟镜像与否无关,armor 的材质名照样值得备注。
    local function visible_slots(source, hide_mirrored_armor)
        local out = {}
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            if slot ~= "armor" or Utils.has_armor_mesh(source) then
                if not (slot == "armor" and hide_mirrored_armor) then
                    if Utils.get_mesh(source, slot) then table.insert(out, slot) end
                end
            end
        end
        return out
    end

    -- 材质备注名。`Metal1`–`Metal4` 这种名字对人类没有意义,靠试才知道是哪块。
    -- 备注是**角色级**的(存在 config.material_notes 里),不属于任何预设 —— 认清一次,处处受益。
    -- 没备注就 fallback 到原始材质名。
    local function display_mat_name(config, slot, mat_name)
        local notes = config.material_notes and config.material_notes[slot]
        local note = notes and notes[mat_name]
        if note and note ~= "" then return note .. " (" .. mat_name .. ")" end
        return mat_name
    end

    -- 主层预设的材质编辑:二值(整份快照,每个材质都有值)
    local function render_base_material(config, preset_data, slot, mesh, mat_index, mat_name, id_prefix, kind_id)
        if type(preset_data[slot]) ~= "table" then preset_data[slot] = { materials = {} } end
        local cur = preset_data[slot].materials[mat_name]
        local checked = cur ~= false
        -- 材质名在同一个 mesh 里可能重复(同名不同下标),光靠"名字##槛位"当 ImGui ID 会撞车,
        -- 点击没反应就是这个原因,所以额外把下标塞进 ID 里(不影响存档用的 mat_name 这个 key)。
        local widget_id = display_mat_name(config, slot, mat_name)
            .. "###" .. id_prefix .. slot .. tostring(mat_index)
        local ch, nv = imgui.checkbox(widget_id, checked)
        if ch then
            local changed, reapply = Ops.set_material(preset_data, slot, mat_name, nv, true)
            -- 先写一次模型让点击当帧就有反馈,下一帧的重算会给出最终结果
            pcall(function() mesh:call("setMaterialsEnable", mat_index - 1, nv) end)
            commit(kind_id, changed, reapply)
        end
    end

    -- 轴预设的材质编辑:三态。
    -- 「—」= 这个轴不管这个材质(稀疏的关键:不管 = 不写进表 = 不参与叠加)
    --
    -- 循环顺序刻意是 — → 关 → 开,**把「关」放在第一跳**:状态最常见的用法是
    -- "隐藏某个部件"(隐藏耳朵/马尾之类),让最常用的目标一次点到,而不是点两次。
    local TRI_KEY = { [0] = "tri_none", [1] = "tri_off", [2] = "tri_on" }
    local function render_axis_material(config, preset_data, slot, mesh, mat_index, mat_name, id_prefix, kind_id)
        if type(preset_data[slot]) ~= "table" then preset_data[slot] = { materials = {} } end
        local cur = preset_data[slot].materials[mat_name]
        local state = (cur == nil) and 0 or ((cur == false) and 1 or 2)
        local widget_id = T(TRI_KEY[state]) .. "###" .. id_prefix .. slot .. tostring(mat_index)
        if imgui.button(widget_id) then
            state = (state + 1) % 3
            local changed, reapply = Ops.set_material(preset_data, slot, mat_name,
                ({ [0] = "none", [1] = "off", [2] = "on" })[state], false)
            if state ~= 0 then
                pcall(function() mesh:call("setMaterialsEnable", mat_index - 1, state == 2) end)
            end
            commit(kind_id, changed, reapply)   -- 改成「—」时要退回基线值,交给下一帧重算
        end
        imgui.same_line()
        imgui.text(display_mat_name(config, slot, mat_name))
    end

    -- 预设编辑区(主层/轴共用,靠 is_base 切材质控件形态)
    local function render_editor(config, state, layer, id_prefix, kind_id, source, is_base)
        local preset_data = layer.presets[state.editing]
        if not preset_data then return end

        imgui.separator()
        imgui.text(T("editing") .. ": " .. state.editing)

        if is_base then
            -- 覆写会整份丢掉这个预设原有的内容,同样要二次确认
            if state.pending_recapture then
                if imgui.button(T("confirm_overwrite") .. "###crc_" .. id_prefix) then
                    snapshot_before_destructive(kind_id)
                    -- **逐槛位覆写**:对不上的槛位保持原值。代表目标可能是鉴赏雕像,
                    -- 它的某些槛位用的是没被 mod 替换的皮肤 mesh —— 整份覆写会把角色
                    -- 配置里正确的那部分替成原版材质名。判据和应用时的闸门是同一个。
                    local prev = layer.presets[state.editing]
                    local data = is_base
                        and Utils.capture_preserving_unmatched(source, prev,
                                TransformManager.usable_slots(source, prev))
                        or Utils.capture_current_as_preset(source)
                    state.pending_recapture = false
                    commit(kind_id, Ops.replace_preset(layer, state.editing, data))
                    return
                end
                imgui.same_line()
                if imgui.button(T("cancel_btn") .. "###crx_" .. id_prefix) then
                    state.pending_recapture = false
                end
            else
                if imgui.button(TP("recapture_btn", is_base) .. "###recap_" .. id_prefix) then
                    state.pending_recapture = true
                end
            end
        else
            imgui.text(T("axis_editor_hint"))
        end

        -- 部位筛选:body 实测有 16 个材质、hair 只有 4 个,做头发时不该滚过 16 行身体材质。
        -- 镜像开着时 armor 从这个下拉框里消失(base 层和轴编辑器一视同仁 ——
        -- 轴对 armor 的单独配置一样会被 resolve 覆盖掉,留着编辑同样是死控件)。
        if config.armor_mirrors_body then
            imgui.text(T("armor_mirror_editor_hint"))
        end
        local slots = visible_slots(source, config.armor_mirrors_body)
        local filter_items = { T("slot_all") }
        for _, s in ipairs(slots) do table.insert(filter_items, slot_label(s)) end
        if state.slot_filter > #filter_items then state.slot_filter = 1 end
        ui_w()
        local ch_f, f_idx = imgui.combo(T("slot_filter") .. "###sf_" .. id_prefix, state.slot_filter, filter_items)
        if ch_f then state.slot_filter = f_idx end

        for slot_i, slot in ipairs(slots) do
            if state.slot_filter == 1 or state.slot_filter == slot_i + 1 then
                local mesh = Utils.get_mesh(source, slot)
                if mesh then
                    local names = Utils.get_material_names(mesh)

                    -- 折叠时也能看出这个部位有没有被动过
                    local touched = 0
                    local sd = preset_data[slot]
                    if type(sd) == "table" and type(sd.materials) == "table" then
                        for _, v in pairs(sd.materials) do
                            if is_base then
                                if v == false then touched = touched + 1 end
                            else
                                touched = touched + 1
                            end
                        end
                    end
                    local summary = string.format("%s   %d %s / %d %s",
                        slot_label(slot), #names, T("materials_unit"),
                        touched, is_base and T("off_unit") or T("owned_unit"))

                    if ui_tree(summary .. "###slot_" .. id_prefix .. slot) then
                        if is_base then
                            -- 全开 / 全关 / 反选:改完按预设里的新值先写一次模型,让当帧就有反馈
                            for _, op in ipairs({ { "all_on", "###on_" }, { "all_off", "###off_" }, { "invert", "###inv_" } }) do
                                if op[1] ~= "all_on" then imgui.same_line() end
                                if imgui.button(T(op[1]) .. op[2] .. id_prefix .. slot) then
                                    local changed, reapply = Ops.bulk_slot(preset_data, slot, op[1], names, nil, true)
                                    for i, n in ipairs(names) do
                                        local v = preset_data[slot].materials[n]
                                        pcall(function() mesh:call("setMaterialsEnable", i - 1, v) end)
                                    end
                                    commit(kind_id, changed, reapply)
                                end
                            end
                        else
                            -- 「整块纳入」= 让这个状态接管整个部位,于是它就成了"这个部位独立选造型"。
                            -- 这就是"按身体部位用不同造型"的实现方式 —— 不需要额外的架构层,
                            -- 只是把逐个点三态这件事批量化了。
                            if imgui.button(T("claim_all") .. "###clm_" .. id_prefix .. slot) then
                                commit(kind_id, Ops.bulk_slot(preset_data, slot, "claim", names,
                                    Utils.current_material_states(mesh), false))
                            end
                            imgui.same_line()
                            if imgui.button(T("release_all") .. "###rel_" .. id_prefix .. slot) then
                                commit(kind_id, Ops.bulk_slot(preset_data, slot, "release", names, nil, false))
                            end
                        end

                        for mat_index, mat_name in ipairs(names) do
                            if is_base then
                                render_base_material(config, preset_data, slot, mesh, mat_index, mat_name, id_prefix, kind_id)
                            else
                                render_axis_material(config, preset_data, slot, mesh, mat_index, mat_name, id_prefix, kind_id)
                            end
                        end
                        ui_tree_pop()
                    end
                end
            end
        end

        if imgui.button(T("close_edit_btn") .. "###close_" .. id_prefix) then
            state.editing = nil
        end
    end

    -- 条件规则编辑器(每层各自一套 —— 「条件组」不是独立概念,而是这一层的选择器)
    --
    -- **条件直接挂在目标状态组上编辑,没有暂存区。** 之前是"拼一条规则 → 点添加规则",
    -- 用户反馈那一整块多余:人的心智模型是"这个状态组在什么时候生效",不是"我在构造一条规则"。
    -- 现在的流程:选目标 → 看见它现有的条件 → 加/删。改动立刻落盘,没有"忘了点添加规则"这一说。
    --
    -- 存储格式**没变**(还是 layer.rules 数组,一条 rule = {conditions, logic, preset}),
    -- 只是 UI 把"编辑哪条 rule"绑定到了当前选中的状态组:
    --   * 加第一个条件时才按需创建那条 rule —— 所以不会留下空规则
    --   * 删掉最后一个条件时把整条 rule 一起删掉;空条件的 rule 永远不会命中,
    --     留着只会在上面的规则列表里显示成一条什么都不做的幽灵
    -- 所以不需要迁移,老配置直接能用。
    --
    -- 一个状态组理论上可以有多条 rule(老配置或手改 json 会出现),编辑器只编第一条,
    -- 其余的照样在上面的列表里显示、可删除 —— 不藏东西。
    local function find_rule_index(layer, preset_name)
        for i, r in ipairs(layer.rules or {}) do
            if r.preset == preset_name then return i end
        end
        return nil
    end

    local function render_rules(state, layer, id_prefix, kind_id, context, is_base)
        local preset_names = ordered_preset_names(layer)
        local rb = state.rule

        -- 一、这一层已有的全部规则,**按优先级从上往下列**(和状态列表同一个顺序)。
        -- 保留这个概览是因为按状态组编辑一次只看得见一个状态的条件,看不出全层的优先级关系;
        -- 它也是唯一能看出"多个条件同时成立时到底谁赢"的地方。
        --
        -- 「命中」和「生效」必须分开显示:优先级低的规则条件成立时它确实命中了,
        -- 但被上面的压着,没生效。只标「命中」会让人以为插件坏了(两条都写着命中,画面只有一个)。
        local eff_name = TransformManager.pick_active_preset(layer, context)
        if #layer.rules == 0 then
            imgui.text(T("no_rules"))
        else
            imgui.text(T("rules_by_priority"))
            local rule_to_delete = nil
            local shown = {}
            for pi, pname in ipairs(ordered_preset_names(layer)) do
                for i, rule in ipairs(layer.rules) do
                    if rule.preset == pname then
                        shown[i] = true
                        local line = string.format("  %d. %s", pi, rule_to_string(rule))
                        if rule.hold then
                            line = line .. string.format("  [%s %s]", T("hold_tag"), tostring(rule.hold))
                        end
                        -- 用带闩锁的判定,否则"保持中"的那两秒会显示成没命中,
                        -- 而画面上明明是它在生效 —— 概览和实际打脸比不显示更糟
                        if rule.dissolve_hp_driven ~= true and TransformManager.rule_hits(rule, context) then
                            line = line .. ((eff_name == pname)
                                and ("  (" .. T("rule_effective") .. ")")
                                or  ("  (" .. T("rule_shadowed") .. ")"))
                        end
                        imgui.text(line)
                        imgui.same_line()
                        if imgui.button(T("delete_btn") .. "###delrule_" .. id_prefix .. i) then
                            rule_to_delete = i
                        end
                    end
                end
            end
            -- 目标状态已经不存在的规则(改名漏了/手改 json)。它永远不会生效,
            -- 但**必须显示出来**,否则用户看不见也删不掉,只能去改 json
            for i, rule in ipairs(layer.rules) do
                if not shown[i] then
                    imgui.text("  - " .. rule_to_string(rule) .. "  (" .. T("rule_orphan") .. ")")
                    imgui.same_line()
                    if imgui.button(T("delete_btn") .. "###delorph_" .. id_prefix .. i) then
                        rule_to_delete = i
                    end
                end
            end
            if rule_to_delete then
                commit(kind_id, Ops.delete_rule(layer, rule_to_delete))
                return
            end
        end

        if #preset_names == 0 then
            imgui.text(T("rule_need_preset"))
            return
        end

        -- 二、选目标。它和下面的条件编辑之间要有明确分隔 —— 目标是"改哪一组的条件",
        -- 不是这条条件的一个字段(挤在一起被误读过)。
        imgui.separator()
        if rb.preset_idx > #preset_names then rb.preset_idx = 1 end
        ui_w()
        local ch_p, p = imgui.combo(TP("rule_target", is_base) .. "###rp_" .. id_prefix, rb.preset_idx, preset_names)
        if ch_p then
            rb.preset_idx = p
            rb.adding = false   -- 换目标就把表单收起来:避免"给 A 填的值加到了 B 上"
        end
        local target = preset_names[rb.preset_idx]
        local rule_idx = find_rule_index(layer, target)
        local rule = rule_idx and layer.rules[rule_idx] or nil

        imgui.separator()

        -- 三、这个状态组当前的条件。行与行之间把「且/或」显示出来 ——
        -- 它是**整组共用一个**连接词,不是每对条件各自一个,写在行间才看得出这一点。
        imgui.text(string.format(T("cond_of_target"), target))
        local conds = rule and rule.conditions or {}
        if #conds == 0 then
            imgui.text("  " .. T("cond_group_none"))
        else
            local joiner = ((rule.logic or "AND") == "AND") and T("logic_and") or T("logic_or")
            local to_delete = nil
            for i, c in ipairs(conds) do
                if i > 1 then imgui.text("    " .. joiner) end
                imgui.text("  " .. cond_to_string(c))
                imgui.same_line()
                if imgui.button(T("delete_btn") .. "###delcond_" .. id_prefix .. i) then to_delete = i end
            end
            if to_delete then
                -- 删光条件会连规则一起删(血量驱动的规则除外),见 Ops.delete_condition
                commit(kind_id, Ops.delete_condition(layer, target, to_delete))
                return
            end
        end

        -- 四、命中后保持多少秒。**只在这个状态已经有规则时出现** —— 没有规则就没有
        -- "命中"这件事,保持无处挂载。不做逐键提交(那样每敲一个字存一次盘),给个按钮。
        if rule then
            if rb.hold_buf_for ~= target then
                rb.hold_buf = tostring(rule.hold or 0)
                rb.hold_buf_for = target
            end
            ui_w()
            local ch_h, hv = imgui.input_text(T("hold_label") .. "###hold_" .. id_prefix, rb.hold_buf)
            if ch_h then rb.hold_buf = hv end
            imgui.same_line()
            if imgui.button(T("hold_apply") .. "###holdok_" .. id_prefix) then
                commit(kind_id, Ops.set_hold(layer, target, rb.hold_buf))
                rb.hold_buf = tostring(rule.hold or 0)
            end
            imgui.text("  " .. T("hold_hint"))
        end

        -- 溶解(Dissolve.lua),只作用于溶解模板的材质。
        --   溶解过渡:进入 / 离开这个状态时按时长溶解,而不是瞬间开关
        --   按血量驱动:不看条件,溶解进度直接跟血量走;没有规则时也给勾选框,勾上就建一条空条件的规则
        imgui.separator()
        if rule then
            local ch_de, de = imgui.checkbox(T("dissolve_transition") .. "###dis_" .. id_prefix, rule.dissolve_enabled == true)
            if ch_de then commit(kind_id, Ops.set_dissolve(layer, target, de)) end
            if rule.dissolve_enabled == true and rule.dissolve_hp_driven ~= true then
                for _, field in ipairs({ "dissolve_hide_time", "dissolve_show_time" }) do
                    ui_w()
                    local ch_t, tv = imgui.slider_float(T(field) .. "###" .. field .. "_" .. id_prefix,
                        tonumber(rule[field]) or 0.5, 0.0, 10.0)
                    if ch_t then commit(kind_id, Ops.set_dissolve_time(layer, target, field, tv)) end
                end
            end
        end
        local driven = rule ~= nil and rule.dissolve_hp_driven == true
        local ch_hd, hd = imgui.checkbox(T("dissolve_hp_driven") .. "###hpd_" .. id_prefix, driven)
        if ch_hd then
            -- 没有规则时建一条空条件的规则来挂;取消时只为它建的空规则一并删掉,见 Ops.set_hp_driven
            commit(kind_id, Ops.set_hp_driven(layer, target, hd))
            return
        end
        if driven then
            for _, field in ipairs({ "dissolve_hp_upper", "dissolve_hp_lower" }) do
                ui_w()
                local ch_v, v = imgui.slider_float(T(field) .. "###" .. field .. "_" .. id_prefix,
                    tonumber(rule[field]) or (field == "dissolve_hp_upper" and 100 or 0), 0.0, 100.0)
                if ch_v then commit(kind_id, Ops.set_hp_bound(layer, target, field, v)) end
            end
            ui_w()
            local ch_dir, dir = imgui.combo(T("dissolve_hp_dir") .. "###hpdir_" .. id_prefix,
                rule.dissolve_hp_invert == true and 2 or 1, { T("dissolve_hp_dir_low"), T("dissolve_hp_dir_high") })
            if ch_dir then commit(kind_id, Ops.set_hp_invert(layer, target, dir == 2)) end
            imgui.text("  " .. T("dissolve_hp_hint"))
        end

        -- 五、加条件。表单默认收起:大部分时间是来看/删的,不是来加的。
        if not rb.adding then
            if imgui.button(T("cond_add_new") .. "###addnew_" .. id_prefix) then
                rb.adding = true
                -- 打开表单时把"关系"同步成这条规则现在的值,否则表单会显示一个和实际不符的选项
                rb.logic_idx = (rule and (rule.logic or "AND") == "OR") and 2 or 1
            end
            return
        end

        -- 已经有条件了才需要问"和它们什么关系" —— 第一条条件没有可关联的对象
        if #conds > 0 then
            ui_w()
            local ch_lg, lg = imgui.combo(T("logic_join") .. "###lg_" .. id_prefix, rb.logic_idx,
                { T("logic_all"), T("logic_any") })
            if ch_lg then rb.logic_idx = lg end
        end

        local cond_defs = Registry.visible()
        local cond_labels = {}
        for _, def in ipairs(cond_defs) do table.insert(cond_labels, T(def.label_key)) end
        if #cond_labels == 0 then return end

        ui_w()
        local ch_ct, ct_idx = imgui.combo(T("cond_type") .. "###ct_" .. id_prefix, rb.cond_type_idx, cond_labels)
        if ch_ct then rb.cond_type_idx = ct_idx end
        local sel_def = cond_defs[rb.cond_type_idx]
        if not sel_def then return end

        if sel_def.kind == "bool" then
            ui_w()
            local ch_bv, bv = imgui.combo(T("cond_value") .. "###cb_" .. id_prefix, rb.cond_bool_idx,
                { T("yes"), T("no") })
            if ch_bv then rb.cond_bool_idx = bv end
        elseif sel_def.kind == "enum" then
            -- 档位是下拉框而不是填数字:存进配置的是枚举值,但没人应该去背"残血 = 2"
            local opts = sel_def.options and sel_def.options(context, global_config.language) or {}
            local names = {}
            for _, o in ipairs(opts) do table.insert(names, o.label) end
            if rb.cond_enum_idx > #names then rb.cond_enum_idx = 1 end
            ui_w()
            local ch_eo, eo = imgui.combo(T("cond_op") .. "###ceo_" .. id_prefix, rb.cond_op_idx, Registry.ENUM_OPS)
            if ch_eo then rb.cond_op_idx = eo end
            if #names > 0 then
                ui_w()
                local ch_ev, ev = imgui.combo(T("cond_value") .. "###ce_" .. id_prefix, rb.cond_enum_idx, names)
                if ch_ev then rb.cond_enum_idx = ev end
            end
        else
            ui_w()
            local ch_op, op = imgui.combo(T("cond_op") .. "###co_" .. id_prefix, rb.cond_op_idx, Registry.NUM_OPS)
            if ch_op then rb.cond_op_idx = op end
            ui_w()
            local ch_nv, nv = imgui.input_text(T("cond_value") .. "###cn_" .. id_prefix, rb.cond_num_value)
            if ch_nv then rb.cond_num_value = nv end
        end

        if imgui.button(T("cond_add") .. "###ca_" .. id_prefix) then
            local op, value
            if sel_def.kind == "bool" then
                value = (rb.cond_bool_idx == 1)
            elseif sel_def.kind == "enum" then
                local opts = sel_def.options and sel_def.options(context, global_config.language) or {}
                local chosen = opts[rb.cond_enum_idx]
                -- 算子索引和数值类共用 cond_op_idx,所以这里必须按 ENUM_OPS 取,
                -- 不能按 NUM_OPS —— 否则切换条件类型后会取到 "<=" 这种枚举用不了的算子
                op, value = Registry.ENUM_OPS[rb.cond_op_idx] or "==", chosen and chosen.value
            else
                op, value = Registry.NUM_OPS[rb.cond_op_idx], rb.cond_num_value
            end
            local cond = Ops.make_condition(sel_def, op, value, context, global_config.language)
            if cond then
                -- 「关系」是整条规则共用的,加条件时是**改**它、不是只影响新条件 ——
                -- 行间显示的那个连接词就是它,用户看得见自己改了什么
                local logic = (rb.logic_idx == 1) and "AND" or "OR"
                rb.adding = false
                commit(kind_id, Ops.add_condition(layer, target, cond, logic))
            end
        end
        imgui.same_line()
        if imgui.button(T("cancel_btn") .. "###cacx_" .. id_prefix) then rb.adding = false end
    end

    -- 一个完整的层:预设库(新建/浏览编辑/改名/复制/删除)+ 编辑区 + 条件规则
    local function render_layer(config, id_prefix, layer, kind_id, source, context, is_base)
        local state = get_ui_state(id_prefix)
        local names = ordered_preset_names(layer)

        -- 护甲镜像开关。只在整套造型层出现一次 —— 这是角色级的设置(取决于这具模型的
        -- armor 是不是 body 的完整重导出),不是"这份预设"或"这条轴"的属性。
        -- 不按 armor 当前在不在(has_armor_mesh)来决定要不要显示这个开关:皮肤切换会让
        -- armor 随时冒出来,提前开好镜像、等 armor 出现时直接生效,比现开现关更顺手。
        if is_base then
            local ch_am, want_mirror = imgui.checkbox(
                T("armor_mirror_label") .. "###armormirror_" .. id_prefix, config.armor_mirrors_body)
            if ch_am then commit(kind_id, Ops.set_armor_mirror(config, want_mirror)) end
            imgui.text("  " .. T("armor_mirror_hint"))
            imgui.separator()
        end

        -- 新建:自动取名(1、2、3…),建完立刻选中。名字随后在「当前预设名」里改 ——
        -- "先取名再创建"对用户是多一道门槛,常规工具都是先建后改名。
        if imgui.button(TP("new_preset_btn", is_base) .. "###nb_" .. id_prefix) then
            -- 整套造型抓当前显示状态(一整套的语义);状态组必须从空开始,
            -- 一上来就整份快照 = 宣称拥有全部材质 = 叠加时互相踩。新建的排最后,想提上去用「上移」
            local changed, reapply, newn = Ops.new_preset(layer, is_base and Utils.capture_current_as_preset(source) or {})
            state.editing = newn
            state.name_buf = newn
            state.name_buf_for = newn
            commit(kind_id, changed, reapply)
        end

        -- 当前预设名:就地改名(不是"新建用的名字")
        if state.editing and layer.presets[state.editing] then
            if state.name_buf_for ~= state.editing then
                state.name_buf = state.editing
                state.name_buf_for = state.editing
            end
            ui_w()
            local ch_n, nv = imgui.input_text(TP("current_preset_name", is_base) .. "###ni_" .. id_prefix, state.name_buf)
            if ch_n then state.name_buf = nv end
            imgui.same_line()
            -- 不做逐键改名:那样每敲一个字就要挪一次表 + 存一次盘,中途还可能撞上已有名字
            if imgui.button(T("rename_btn") .. "###rn_" .. id_prefix) then
                -- 连带改掉 order / 手动选择 / 规则目标里的旧名字,见 Ops.rename_preset
                if commit(kind_id, Ops.rename_preset(layer, state.editing, state.name_buf)) then
                    state.editing = state.name_buf
                    state.name_buf_for = state.name_buf
                end
            end
        end

        imgui.spacing()

        -- 列表。「浏览并编辑」是一个动作:选中 = 立刻生效 = 展开编辑。
        -- 拆成"调用"和"编辑"两个按钮是错的 —— 编辑非生效预设时,改动会被
        -- resolve() 按 active 那个预设重算后盖掉,屏幕上根本看不到自己在改什么。
        if #names == 0 then
            imgui.text(TP("no_presets", is_base))
        end
        -- 顺序 = 优先级,所以列表本身就是优先级表。只有 2 个以上、且这一层真有规则时才提示 ——
        -- 一个状态时没有优先级可言,没有规则时顺序也不影响任何东西,提示会变成噪音。
        if #names >= 2 and #layer.rules > 0 then
            imgui.text(T("priority_hint"))
        end
        local move = nil     -- { from = i, to = j },循环外再改,避免遍历途中挪表
        for pi, pname in ipairs(names) do
            local is_active = (layer.active == pname)
            local prefix = is_active and "[*] " or "[ ] "
            -- 整套造型:标出"这个预设是给另一套材质做的" —— 否则用户只会觉得"点了没反应"。
            -- 闸门改成逐槛位之后这里有**三态**,不再是能用/不能用:
            --   全部槛位都对不上 → 和以前一样,整份跳过
            --   部分槛位对不上   → 新增:把跳过的槛位名列出来。这一态以前会被误报成
            --                      "整份不匹配"(实测 Figure10_010 只有 body 对不上,
            --                      却整份被判掉),用户看到的是"点了没反应"而无从下手
            --   全部对得上       → 无标记
            local suffix = ""
            if is_base then
                local preset = layer.presets[pname]
                local usable = TransformManager.usable_slots(source, preset)
                local skipped = {}
                for _, slot in ipairs(Utils.MESH_SLOTS) do
                    -- 只报"这个模型上真有、预设里也写了、但对不上"的槛位。
                    -- 模型上不存在的槛位(比如没穿护甲时的 armor)不是问题,别当噪音报出来。
                    local sd = preset and preset[slot]
                    local has_stored = type(sd) == "table" and next(sd.materials or {}) ~= nil
                    if has_stored and Utils.get_mesh(source, slot) and not usable[slot] then
                        table.insert(skipped, slot_label(slot))
                    end
                end
                if next(usable) == nil then
                    suffix = "   [" .. T("preset_mismatch") .. "]"
                elseif #skipped > 0 then
                    suffix = "   [" .. T("preset_partial") .. ": " .. table.concat(skipped, " ") .. "]"
                end
            end
            if imgui.button(prefix .. pname .. suffix .. "###sel_" .. id_prefix .. pname) then
                if state.editing == pname then
                    state.editing = nil          -- 再点一次收起编辑区(但保持生效)
                else
                    state.editing = pname
                    commit(kind_id, Ops.set_active(layer, pname))
                end
            end
            -- 上移/下移。只在有得移的时候出现(第一行没有上移、最后一行没有下移),
            -- 而不是画一个点了没反应的灰按钮 —— 后者会让人以为"卡住了"。
            if #names >= 2 then
                if pi > 1 then
                    imgui.same_line()
                    if imgui.button(T("move_up") .. "###mu_" .. id_prefix .. pname) then
                        move = { name = pname, offset = -1 }
                    end
                end
                if pi < #names then
                    imgui.same_line()
                    if imgui.button(T("move_down") .. "###md_" .. id_prefix .. pname) then
                        move = { name = pname, offset = 1 }
                    end
                end
            end
            imgui.same_line()
            if imgui.button(T("duplicate_btn") .. "###du_" .. id_prefix .. pname) then
                -- 后缀 _1 / _2 …,插在源的紧后面,复制完直接切过去(跟新建一致:建完就在手上)
                local changed, reapply, newn = Ops.duplicate_preset(layer, pname)
                if changed then
                    state.editing = newn
                    state.name_buf = newn
                    state.name_buf_for = newn
                end
                commit(kind_id, changed, reapply)
            end
            imgui.same_line()
            -- 删除要二次确认:它紧挨着复制和预设名按钮,误点概率最高,而且不可逆
            if state.pending_delete == pname then
                if imgui.button(T("confirm_delete") .. "###cd_" .. id_prefix .. pname) then
                    snapshot_before_destructive(kind_id)
                    if state.editing == pname then state.editing = nil end
                    state.pending_delete = nil
                    commit(kind_id, Ops.delete_preset(layer, pname))
                end
                imgui.same_line()
                if imgui.button(T("cancel_btn") .. "###cx_" .. id_prefix .. pname) then
                    state.pending_delete = nil
                end
            else
                if imgui.button(T("delete_btn") .. "###de_" .. id_prefix .. pname) then
                    state.pending_delete = pname
                end
            end
        end

        -- 优先级改动:改 order 就够了(presets 是 map,不受顺序影响),存盘 + 重算一次 ——
        -- 顺序变了可能立刻换成另一个状态,不重算的话要等下一次条件变化才生效
        if move then commit(kind_id, Ops.move_preset(layer, move.name, move.offset)) end


        if state.editing and layer.presets[state.editing] then
            render_editor(config, state, layer, id_prefix, kind_id, source, is_base)
        end

        imgui.separator()
        if ui_tree(T("rules") .. "###rules_" .. id_prefix) then
            render_rules(state, layer, id_prefix, kind_id, context, is_base)
            ui_tree_pop()
        end
    end

    -- 快速切换里的一行。控件形态按"这一层实际是什么"来给:
    --
    --   整套造型            → 永远是下拉框(即使挂了规则)。它是最主要的手动控制,
    --                        规则对它只是例外(比如章节换装);规则接管时旁边标出来。
    --   状态,1 份预设       → 勾选框(「隐藏耳朵」这类本来就是开关)
    --   状态,多份预设       → 下拉框(多档维度,状态内互斥)
    --   有规则的层(基础/高级都算)→ 前面多一个「自动」勾选框;关掉后才出现手动控件
    --
    -- 快速切换区分成「基础状态组」(无条件)和「高级状态组」(条件驱动)两块。
    -- **这一条是改过的**:早期刻意不按手动/被动分块,理由是"一给状态加规则它就会跳到
    -- 另一个板块去"。现在分了,因为加了「自动」开关之后被动组变成**可操作**的了 ——
    -- 而它跟"点一下就换装"的基础组混在一起反而更难读(一个是拨开关,一个是设定规则后不用管)。
    -- 位置会跳这件事仍然存在,只是用「基础/高级」这两个名字把它解释掉了:加了条件就升级成高级。
    -- 「自动」勾选框。只给**有规则**的层 —— 没规则时没有任何东西可自动,画出来是纯噪音。
    -- 返回这一层现在是不是自动状态。
    local function render_auto_toggle(layer, id_prefix, kind_id)
        if #(layer.rules or {}) == 0 then return true end
        local on = layer.auto ~= false
        local ch, v = imgui.checkbox(T("auto_label") .. "###auto_" .. id_prefix, on)
        if ch then commit(kind_id, Ops.set_auto(layer, v)) end
        -- imgui.checkbox 的第二个返回值就是点完之后的值,无论这一帧有没有被点
        return v
    end

    local function render_quick_row(label, layer, id_prefix, kind_id, context, is_base)
        local eff_name, from_cond = TransformManager.pick_active_preset(layer, context)
        local names = ordered_preset_names(layer)

        if #names == 0 then
            imgui.text(string.format("  %s: %s", label, TP("no_presets", is_base)))
            return
        end

        -- 整套造型**永远给下拉框**,即使它挂了规则 —— 它是最主要的手动控制,而规则对它是
        -- 例外(比如只在某章节命中)。规则正在接管时在旁边标出来,让人知道当前不是手动值。
        -- (状态组则相反:规则是主要驱动方式,挂了规则的根本不会走到这里 —— 调用处已过滤。)
        if is_base then
            local items = { T("none_option") }
            for _, n in ipairs(names) do table.insert(items, n) end
            local cur_idx = 1
            for i, n in ipairs(names) do
                if n == layer.active then cur_idx = i + 1 end
            end
            ui_w()
            local ch, idx = imgui.combo(label .. "###q_" .. id_prefix, cur_idx, items)
            if ch then commit(kind_id, Ops.set_active(layer, (idx == 1) and "" or items[idx])) end
            if #(layer.rules or {}) > 0 then
                imgui.same_line()
                render_auto_toggle(layer, id_prefix, kind_id)
            end
            if from_cond then
                imgui.same_line()
                imgui.text("-> " .. T("overridden_by_rule") .. ": " .. tostring(eff_name))
            end
            return
        end

        -- 高级组(有规则):先显示组名,再「自动」开关。
        -- 自动开着时**不给**手动控件 —— 规则永远压过手动值,那个控件点了没反应
        -- (这正是早期"被动组根本不进快速切换"的理由);关掉自动它才出现、才真的管用。
        if #(layer.rules or {}) > 0 then
            imgui.text("  " .. label)
            imgui.same_line()
            local auto_on = render_auto_toggle(layer, id_prefix, kind_id)
            imgui.same_line()
            if auto_on then
                imgui.text("-> " .. (from_cond and T("overridden_by_rule") or T("now_label"))
                    .. ": " .. tostring(eff_name or T("none_option")))
            else
                local items = { T("none_option") }
                for _, n in ipairs(names) do table.insert(items, n) end
                local cur_idx = 1
                for i, n in ipairs(names) do
                    if n == layer.active then cur_idx = i + 1 end
                end
                ui_w()
                local ch, idx = imgui.combo("###q_" .. id_prefix, cur_idx, items)
                if ch then commit(kind_id, Ops.set_active(layer, (idx == 1) and "" or items[idx])) end
            end
            return
        end

        -- 只有一份预设的状态**就是个开关**(「隐藏耳朵」这类),给勾选框而不是只有两项的下拉框。
        -- 不勾 = (无) = 这个状态不发言,听整套造型的。
        if #names == 1 then
            local only = names[1]
            local ch, v = imgui.checkbox(label .. "###q_" .. id_prefix, layer.active == only)
            if ch then commit(kind_id, Ops.set_active(layer, v and only or "")) end
            return
        end

        -- 多份预设 = 多档维度(比如面部的 正常/受伤/低血量),仍然用下拉框。
        -- 保留多预设是因为**状态内预设互斥**正是多档维度的确定性来源:
        -- 拆成多个单预设状态的话,它们会抢同一批材质,结果变成状态名排序依赖。
        local items = { T("none_option") }
        for _, n in ipairs(names) do table.insert(items, n) end
        local cur_idx = 1
        for i, n in ipairs(names) do
            if n == layer.active then cur_idx = i + 1 end
        end
        ui_w()
        local ch, idx = imgui.combo(label .. "###q_" .. id_prefix, cur_idx, items)
        if ch then commit(kind_id, Ops.set_active(layer, (idx == 1) and "" or items[idx])) end
    end

    -- 场上目标按**角色**分组:同一角色的玩家 / CG 傀儡 / 鉴赏雕像共用同一份配置(配置键就是角色名)。
    -- ImGui 面板和 REFF 网页都用这一份分组,保证两边选中的是同一个东西。
    local function collect_character_groups(all_targets)
        local groups, group_order = {}, {}
        for _, t in ipairs(all_targets) do
            -- 键可能是 nil(认出角色但那个角色还没有配置)。这种也要成组显示,
            -- 否则用户看不到"认出来了、只是还没配"这个状态。
            local key = resolve_config_key(t)
            local gid = key or (t.ident and t.ident.character)
            if gid then
                local g = groups[gid]
                if not g then
                    g = { gid = gid, key = key, char = t.ident and t.ident.character,
                          targets = {}, rank = 99 }
                    groups[gid] = g
                    table.insert(group_order, gid)
                end
                table.insert(g.targets, t)
                -- 代表目标 = 材质开关列表和抓快照的来源。优先级:玩家 > 伙伴 > 傀儡 > 雕像。
                -- 玩家优先有两个理由:它有 context(条件求值要),而且它的材质集是
                -- 这个角色"正统"的那一份(雕像可能用的是没被 mod 替换的皮肤 mesh)。
                local rank = t.is_figure and 4 or (t.is_puppet and 3 or (t.is_partner and 2 or 1))
                if rank < g.rank then g.rep, g.rank = t, rank end
            end
        end
        return groups, group_order
    end

    -- 默认选主控那一组(rank 1 = 玩家)。记的是组 id 而不是下标 ——
    -- 傀儡/雕像随场景生灭,下标会指到别人身上去。
    local function pick_character_group(groups, group_order, wanted)
        if groups[wanted] then return groups[wanted] end
        for _, gid in ipairs(group_order) do
            if groups[gid].rank == 1 then return groups[gid] end
        end
        return groups[group_order[1]]
    end

    local function draw_panel()
        if not ui_tree(T("title") .. " v" .. version) then return end

        -- 语言开关放在最顶上、且在所有提前 return 之前:否则"未找到角色"那类提示会卡在
        -- 用户看不懂的语言里,而他又没地方切。标签固定写「中文」,英文界面下也能认出来。
        local ch_lang, want_zh = imgui.checkbox("中文###langtoggle", global_config.language == "zh")
        if ch_lang and Ops.set_global(global_config, "language", want_zh and "zh" or "en") then
            save_global_settings()
        end

        -- 最上面给独立面板的入口(另有快捷键,默认 F8)。装了 REFF 也给:REFF.dll 加载了不等于网页
        -- 打得开(缺 WebView2 Runtime、宿主被杀软拦掉等),只留 Home 的话用户会两头都打不开
        local panel = Main.panel
        if panel and panel.available() then
            local label = (panel.is_open() and T("panel_close") or T("panel_open")) .. " (" .. panel.hotkey_text() .. ")"
            if imgui.button(label .. "###avm_panel_toggle") then panel.toggle() end
        end

        -- 上一帧绘制出错时把它显示出来。不显示的话 pcall 会把错误吞掉,
        -- 表现成"面板缺了一半"却没人知道为什么(日志里也有,但没人会去翻)。
        if last_draw_error then
            imgui.text(T("draw_error") .. " " .. last_draw_error)
        end

        -- 面板一次只编辑一个目标。目标 = 本地玩家 + 当前在场的 CG 傀儡。
        --
        -- 为什么必须让傀儡也能选中,而不是只在后台给它们应用配置:傀儡是按**自己带的**
        -- CharacterKindID 登记的(实测 ch2a200_00_puppet 是 ch2_a200,不是 ch3_a8z0),
        -- 首次出现时会自动去认亲。认亲认错了得有地方改 —— 而「独立/共用」那两个按钮
        -- 操作的永远是"面板当前显示的这个角色"。选不中傀儡,它认错的别名就永远改不回来。
        local all_targets = Targets.collect()

        -- 隐藏收纳武器是全局功能,不属于任何一个角色分组,画在分组逻辑之外,就一个勾选框。
        imgui.separator()
        local ch_st, st = imgui.checkbox(T("weapon_hide_storage_enabled") .. "###wh_storage",
            global_config.weapon_hide_storage == true)
        if ch_st and Ops.set_global(global_config, "weapon_hide_storage", st) then
            save_global_settings()
        end
        -- 界面切换溶解:在面板上手动切状态 / 预设时播放溶解(只作用于溶解模板的材质)
        local ch_ud, ud = imgui.checkbox(T("ui_dissolve_enabled") .. "###ui_dissolve",
            global_config.ui_dissolve_enabled ~= false)
        if ch_ud and Ops.set_global(global_config, "ui_dissolve_enabled", ud) then
            save_global_settings()
        end
        if global_config.ui_dissolve_enabled ~= false then
            ui_w()
            local ch_ut, ut = imgui.slider_float(T("ui_dissolve_time") .. "###ui_dissolve_time",
                tonumber(global_config.ui_dissolve_time) or 1.0, 0.0, 30.0)
            if ch_ut and Ops.set_global(global_config, "ui_dissolve_time", ut) then
                save_global_settings()
            end
        end

        -- ============================================================
        -- 面板一次编辑一个**角色**,不是一个目标。
        --
        -- 同一个角色在场的所有目标(玩家 / CG 傀儡 / 鉴赏雕像)共用同一份配置 ——
        -- 配置键就是角色名,所以"分开选"从数据上就没有意义:改哪个都是改同一份文件。
        -- 之前按目标选是 kind 键时代的遗留(那时候一个傀儡可能有自己的配置)。
        --
        -- 顺带把"雕像不可选中"那条限制去掉了 —— 它当初是为了防止「从当前模型抓快照」
        -- 把雕像的材质集写进角色配置。按角色分组之后,抓快照有明确的**代表目标**
        -- (优先玩家),雕像不再是快照来源,那条限制的前提就不存在了。
        -- ============================================================
        local groups, group_order = collect_character_groups(all_targets)

        if #group_order == 0 then
            imgui.text(T("no_character"))
            ui_tree_pop()
            return
        end

        local group = pick_character_group(groups, group_order, selected_target_id)
        selected_target_id = group.gid

        if #group_order > 1 then
            local labels, cur = {}, 1
            for i, gid in ipairs(group_order) do
                local g = groups[gid]
                local nm = char_display(g.char) or gid
                if not g.key then nm = nm .. "  " .. T("char_no_config") end
                if #g.targets > 1 then nm = nm .. "  x" .. #g.targets end
                labels[i] = nm
                if gid == group.gid then cur = i end
            end
            local ch, ni = imgui.combo(T("target_sel") .. "###tgtsel", cur, labels)
            if ch and group_order[ni] then
                selected_target_id = group_order[ni]
                group = groups[selected_target_id]
                end_preview()       -- 预览绑在具体目标上,换组就作废
                ui_state = {}
            end
        end

        local target = group.rep

        local context = target.context
        local source = target.source
        -- 面板往下所有地方用的 `kind_id` 其实是**配置键**:角色名(Leon),或者身份认不出来时
        -- 的旧 kind 代号(ch1_c0z1)。下游只把它当不透明字符串用(文件路径、内存缓存、
        -- 命名存档、备份),所以那一大片代码不用逐处改。
        local _, key_how = resolve_config_key(target)
        local kind_id = group.key or group.gid

        -- 这一组覆盖场上哪些目标。改成按角色选之后,这一行是唯一能看出
        -- "改这份配置会影响谁"的地方 —— 否则用户不知道 CG 傀儡和雕像也在里面。
        if #group.targets > 1 then
            local parts = {}
            for _, t in ipairs(group.targets) do table.insert(parts, t.label) end
            imgui.text(T("group_covers") .. " " .. table.concat(parts, ", "))
        end

        register_kind(kind_id)
        -- 同 apply_target:只有身份认不出来时才允许跨角色认亲
        local config = load_config(kind_id, source, key_how == "legacy")

        -- 状态条:一行说完"我是谁、什么状态"。
        -- context 可能为 nil(只剩傀儡、玩家还没就位),这时候整条状态就只剩 kind_id ——
        -- 条件求值本来就是拿玩家的值来算的,没有玩家就没有值可显示。
        local hp = context and TransformManager.get_character_hp_percent(context)
        local status = target_display_name(target)
        if hp then status = status .. string.format("  |  HP %.1f%%", hp) end
        for _, def in ipairs(Registry.visible()) do
            if context and def.kind == "bool" and def.get(context) == true then
                status = status .. "  |  " .. T(def.label_key)
            elseif context and def.merged then
                local v = def.get(context)
                if type(v) == "number" and v ~= 0 then
                    status = status .. "  |  " .. T(def.label_key) .. ": " .. def.value_label(v, global_config.language)
                end
            end
        end
        imgui.text(status)

        -- v2 配置:给"迁移旧配置"(两步确认)。迁移在原表上换内容,同一帧就会走到下面的 v3 面板
        if not ModelV3.is_v3(config) then
            if ui_state.migrate_pending then
                imgui.text(T("migrate_confirm"))
                if imgui.button(T("migrate_btn") .. "###mig_yes") then
                    ui_state.migrate_pending = nil
                    ui_state.migrate_report = migrate_to_v3(kind_id)
                end
                imgui.same_line()
                if imgui.button(T("cancel_btn") .. "###mig_no") then ui_state.migrate_pending = nil end
            elseif imgui.button(T("migrate_btn") .. "###mig") then
                ui_state.migrate_pending = true
            end
        end

        -- v3 配置:REF 菜单里只做日常使用(手动选择、条件状态开关、预设),完整编辑在 REFF 页面
        if ModelV3.is_v3(config) then
            local report = ui_state.migrate_report
            if report then
                imgui.text(string.format(T("migrate_done"), #(report.presets or {})))
                imgui.same_line()
                if imgui.button(T("cancel_btn") .. "###mig_ok") then ui_state.migrate_report = nil end
            end
            ui_state.v3 = ui_state.v3 or {}
            ImGuiV3.draw({
                T = T, config = config, kind_id = kind_id, target = target, context = context, source = source,
                TM = TransformManager, ui = ui_state.v3,
                commit = function(changed, reapply) return commit(kind_id, changed, reapply) end,
                ui_tree = ui_tree, ui_tree_pop = ui_tree_pop, ui_w = ui_w,
                preset_view = preset_view, apply_preset = apply_preset, save_current_as_preset = save_current_as_preset,
                dismiss_preset_hint = dismiss_preset_hint, restore_autosave = restore_autosave,
                -- 提示里只列真的有的编辑入口:独立面板画得出来才给它的快捷键,REFF 加载了才提 Home
                panel_key = Main.panel and Main.panel.available() and Main.panel.hotkey_text() or nil,
                reff = rawget(_G, "reff_native") ~= nil,
            })
            ui_tree_pop()
            return
        end

        -- 共用/独立。两个出口都二次确认;初始化额外先备份。
        -- **「初始化预设」只在独立状态下出现** —— 共用时初始化会把来源角色一起清空,
        -- 让它不可能发生比提醒用户"先独立再初始化"更可靠。
        local shared_src = cfg_key(kind_id)
        if shared_src ~= kind_id then
            imgui.text(T("shared_with") .. " " .. shared_src)
            imgui.text(T("shared_hint"))
            if pending_ownership == "independent" then
                if imgui.button(T("confirm_independent") .. "###ci_own") then
                    make_independent(kind_id)
                    pending_ownership = nil
                end
                imgui.same_line()
                if imgui.button(T("cancel_btn") .. "###cx_own") then pending_ownership = nil end
            else
                if imgui.button(T("make_independent_btn") .. "###mkind") then
                    pending_ownership = "independent"
                end
            end
        else
            if pending_ownership == "reset" then
                if imgui.button(T("confirm_reset_config") .. "###cr_reset") then
                    reset_config(kind_id, source)      -- 先留备份,再按当前外观建一份 default
                    pending_ownership = nil
                end
                imgui.same_line()
                if imgui.button(T("cancel_btn") .. "###cx_reset") then pending_ownership = nil end
            else
                if imgui.button(T("reset_config_btn") .. "###rstcfg") then
                    pending_ownership = "reset"
                end
                -- 事后建立共用的唯一入口。只在配置没什么可丢时出现 —— 已经有真实预设的角色
                -- 建立共用会把自己那份配置旁路成孤儿。
                if config_is_trivial(config) then
                    imgui.same_line()
                    if imgui.button(T("match_kin_btn") .. "###matchkin") then
                        if try_match_kin(kind_id, source) then request_reapply() end
                    end
                end
            end
        end
        imgui.separator()

        -- 快速切换:高频操作放最上面,默认展开。这里不出现任何"材质/槛位"字样。
        imgui.text(T("quick_switch"))
        render_quick_row(T("base_layer"), config.base, "base", kind_id, context, true)

        -- 状态组区分成两块:**基础**(没有条件规则,手动拨)和**高级**(条件驱动)。
        --
        -- 分块之前是"挂了规则的状态组根本不出现在这里",理由是规则永远压过手动值、那一行不可
        -- 操作。加了「自动」开关之后这个理由不成立了:关掉自动它就能手动拨,所以它该出现。
        -- 但**不能和基础组混在一列**:一个是"点一下就换",一个是"设好条件就别管了",
        -- 混排读起来像同一类东西。分成基础/高级之后,"加了条件的组会从上面那块跳到下面那块"
        -- 也有了能说清的解释:它升级成高级了。
        --
        -- 两块各自的摘要**只统计自己那块**。摘要行就是折叠标题,标题提到的东西展开必须看得见
        -- (试过"摘要含被动、列表只放可操作的",读起来像坏了)。
        local axis_names = TransformManager.get_axis_names(config)
        local basic, basic_active = {}, {}
        local adv, adv_active, adv_manual = {}, {}, {}
        for _, name in ipairs(axis_names) do
            local axis = config.axes[name]
            local on = TransformManager.pick_active_preset(axis, context) ~= nil
            -- 用和 axis_apply_order 同一个判据 —— 否则"面板把它放在哪一栏"和
            -- "它的优先级归哪一档"可能不一致,那种错最难看出来
            if not TransformManager.axis_is_advanced(axis) then
                table.insert(basic, name)
                if on then table.insert(basic_active, name) end
            else
                table.insert(adv, name)
                if on then table.insert(adv_active, name) end
                if axis.auto == false then table.insert(adv_manual, name) end
            end
        end

        local function axes_block(header_key, names, active_names, node_id)
            if #names == 0 then return end
            local summary = "  " .. T(header_key) .. ": "
                .. ((#active_names > 0) and table.concat(active_names, ", ") or T("none_active"))
            if ui_tree(summary .. "###" .. node_id) then
                for _, name in ipairs(names) do
                    render_quick_row(name, config.axes[name], "ax_" .. name, kind_id, context)
                end
                ui_tree_pop()
            end
        end
        axes_block("quick_axes_header", basic, basic_active, "quickaxes")
        axes_block("quick_axes_adv_header", adv, adv_active, "quickaxesadv")

        -- 自动被关掉的组要在**折叠区外面**点名:关掉之后过两天很容易忘,
        -- 然后以为"规则坏了"。整套造型层也算进来(它同样有这个开关)。
        local paused = {}
        if config.base and config.base.auto == false and #(config.base.rules or {}) > 0 then
            table.insert(paused, T("base_layer"))
        end
        for _, name in ipairs(adv_manual) do table.insert(paused, name) end
        if #paused > 0 then
            imgui.text("  " .. T("auto_paused") .. ": " .. table.concat(paused, ", "))
        end

        imgui.separator()

        -- 主层工作台
        if ui_tree(T("base_workbench")) then
            render_layer(config, "base", config.base, kind_id, source, context, true)
            ui_tree_pop()
        end

        -- 轴
        if ui_tree(T("axes")) then
            imgui.text(T("axes_hint"))
            ui_w()
            local ch_an, anv = imgui.input_text(T("new_axis") .. "###newaxis", new_axis_name)
            if ch_an then new_axis_name = anv end
            if imgui.button(T("new_axis_btn")) and new_axis_name ~= "" then
                -- 顺手带一份预设并选中(见 Ops.new_axis);编辑区直接打开它
                local changed, reapply = Ops.new_axis(config, new_axis_name)
                if changed then
                    local st = get_ui_state("ax_" .. new_axis_name)
                    st.editing = "1"
                    st.name_buf = "1"
                    st.name_buf_for = "1"
                    new_axis_name = ""
                end
                commit(kind_id, changed, reapply)
            end

            -- 只报**真会打架的**:都写同一个值的算兼容,不报(见 find_scope_conflicts 的注释)。
            -- 报的时候把各状态写什么值一起列出来,否则用户看不出该改哪个。
            local conflicts = TransformManager.find_scope_conflicts(config)
            if #conflicts > 0 then
                imgui.text(T("scope_conflict"))
                for _, c in ipairs(conflicts) do
                    local segs = {}
                    for _, p in ipairs(c.parts) do
                        local vals = {}
                        if p.on then table.insert(vals, T("state_on")) end
                        if p.off then table.insert(vals, T("state_off")) end
                        table.insert(segs, p.axis .. "(" .. table.concat(vals, "/") .. ")")
                    end
                    imgui.text("  " .. c.key .. " : " .. table.concat(segs, ", "))
                end
            end

            -- 删除/改名都推迟到循环外:避免在遍历途中改动集合
            local axis_to_delete, axis_to_rename = nil, nil
            for _, name in ipairs(TransformManager.get_axis_names(config)) do
                if ui_tree(name .. "###axisnode_" .. name) then
                    render_layer(config, "ax_" .. name, config.axes[name], kind_id, source, context, false)
                    imgui.separator()

                    -- 状态改名。缓冲挂在这个状态自己的 ui_state 上,切换状态时自动重同步。
                    local st = get_ui_state("ax_" .. name)
                    if st.axis_name_buf_for ~= name then
                        st.axis_name_buf = name
                        st.axis_name_buf_for = name
                    end
                    ui_w()
                    local ch_r, rv = imgui.input_text(T("new_state_name_input") .. "###axname_" .. name, st.axis_name_buf)
                    if ch_r then st.axis_name_buf = rv end
                    imgui.same_line()
                    if imgui.button(T("rename_state_btn") .. "###axren_" .. name) then
                        local nn = st.axis_name_buf
                        if nn ~= "" and nn ~= name and not config.axes[nn] then
                            axis_to_rename = { old = name, new = nn }
                        end
                    end

                    if imgui.button(T("delete_axis_btn") .. "###delaxis_" .. name) then
                        axis_to_delete = name
                    end
                    ui_tree_pop()
                end
            end
            if axis_to_rename then
                local o, n = axis_to_rename.old, axis_to_rename.new
                -- 状态组名没有跨引用(规则在组内部),挪 key(Ops)+ 挪 UI 状态就够了
                if commit(kind_id, Ops.rename_axis(config, o, n)) then
                    ui_state["ax_" .. n] = ui_state["ax_" .. o]
                    ui_state["ax_" .. o] = nil
                    local st = ui_state["ax_" .. n]
                    if st then st.axis_name_buf = n; st.axis_name_buf_for = n end
                end
            end
            if axis_to_delete then
                ui_state["ax_" .. axis_to_delete] = nil
                commit(kind_id, Ops.delete_axis(config, axis_to_delete))
            end
            ui_tree_pop()
        end

        -- 材质备注:角色级,不属于任何预设 —— 认清一次,所有预设/状态的编辑器里都跟着显示。
        if ui_tree(T("material_notes")) then
            imgui.text(T("material_notes_hint"))
            if preview then
                imgui.text("-> " .. T("locating") .. ": " .. preview.slot .. " / " .. preview.mat)
            end
            for _, slot in ipairs(visible_slots(source)) do
                if ui_tree(slot_label(slot) .. "###note_" .. slot) then
                    local mesh = Utils.get_mesh(source, slot)
                    local names = mesh and Utils.get_material_names(mesh) or {}
                    for mat_index, mat_name in ipairs(names) do
                        if imgui.button(T("locate_btn") .. "###loc_" .. slot .. mat_index) then
                            start_preview(target.id, slot, mat_name)
                        end
                        imgui.same_line()
                        local cur = config.material_notes[slot][mat_name] or ""
                        ui_w()
                        local ch, nv = imgui.input_text(mat_name .. "###noteinput_" .. slot .. mat_index, cur)
                        if ch then commit(kind_id, Ops.set_note(config, slot, mat_name, nv)) end
                    end
                    ui_tree_pop()
                end
            end
            ui_tree_pop()
        end

        if ui_tree(T("slots_section")) then
            -- 命名存档:手动存/读,像存档位一样用
            ui_w()
            local ch_sn, snv = imgui.input_text(T("slot_name_input") .. "###slotname", slot_name_buf)
            if ch_sn then slot_name_buf = snv end
            if imgui.button(T("slot_save_btn") .. "###slotsave") then
                -- 留空自动命名;重名直接覆盖(和"存档位"的直觉一致)
                local nm = (slot_name_buf ~= "") and slot_name_buf or auto_slot_name()
                save_slot(kind_id, nm)
                slot_name_buf = ""
            end

            -- 列表是**跨角色**的:自己的在前,别人的带「角色 / 」前缀。
            -- 保存永远写进自己那份文件(不给"存到别人名下"这种操作,那只会让人搞混谁是谁的)。
            local entries = all_slot_entries(kind_id)
            if #entries == 0 then
                imgui.text(T("slot_none"))
            else
                if slot_sel_idx > #entries then slot_sel_idx = 1 end
                local labels = {}
                for _, e in ipairs(entries) do table.insert(labels, e.label) end
                ui_w()
                local ch_ss, ssi = imgui.combo("###slotsel", slot_sel_idx, labels)
                if ch_ss then
                    slot_sel_idx = ssi
                    pending_restore = nil      -- 换了选择就撤销确认态,免得确认按钮作用在新目标上
                end
                local sel = entries[slot_sel_idx]
                imgui.same_line()
                if pending_restore == "slot" then
                    if imgui.button(T("confirm_restore") .. "###cr_s") then
                        load_slot(kind_id, sel.name, sel.key); pending_restore = nil; request_reapply()
                    end
                    imgui.same_line()
                    if imgui.button(T("cancel_btn") .. "###cx_s") then pending_restore = nil end
                else
                    if imgui.button(T("slot_load_btn") .. "###slotload") then pending_restore = "slot" end
                end
                -- **只能删自己的**:在这个角色的面板上删掉另一个角色的存档太意外了
                if sel.own then
                    imgui.same_line()
                    if imgui.button(T("slot_delete_btn") .. "###slotdel") then
                        delete_slot(kind_id, sel.name)
                        slot_sel_idx = 1
                    end
                end
                if not sel.own then
                    imgui.text("  " .. T("slot_foreign_hint"))
                end
            end

            imgui.separator()
            imgui.text(T("auto_restore_header"))

            -- 一:最近一次删除/覆写之前
            if has_backup(kind_id) then
                if pending_restore == "destructive" then
                    if imgui.button(T("confirm_restore") .. "###cr_d") then
                        restore_backup(kind_id); pending_restore = nil; request_reapply()
                    end
                    imgui.same_line()
                    if imgui.button(T("cancel_btn") .. "###cx_d") then pending_restore = nil end
                else
                    if imgui.button(T("restore_backup") .. "###rb_d") then pending_restore = "destructive" end
                end
            else
                imgui.text(T("backup_none"))
            end

            -- 二:本次载入配置时的原样(管渐进搞坏 / 文件损坏)
            if has_onload_backup(kind_id) then
                if pending_restore == "onload" then
                    if imgui.button(T("confirm_restore") .. "###cr_o") then
                        restore_onload_backup(kind_id); pending_restore = nil; request_reapply()
                    end
                    imgui.same_line()
                    if imgui.button(T("cancel_btn") .. "###cx_o") then pending_restore = nil end
                else
                    if imgui.button(T("restore_onload") .. "###rb_o") then pending_restore = "onload" end
                end
            else
                imgui.text(T("backup_onload_none"))
            end
            ui_tree_pop()
        end

        ui_tree_pop()
    end

    re.on_draw_ui(function()
        tree_depth = 0
        local ok, err = pcall(draw_panel)
        -- 无论成功失败都把栈收平:失败时这就是保护其他 mod 的关键一步
        while tree_depth > 0 do
            tree_depth = tree_depth - 1
            pcall(imgui.tree_pop)
        end
        if ok then
            last_draw_error = nil
        else
            last_draw_error = note_error("on_draw_ui", err)
        end
    end)

    -- REFF 面板显示时屏蔽游戏的鼠标并接管光标模式(键盘不拦)。装不上(类型变了)只记日志,不影响其他功能。
    pcall(function()
        local InputGuard = require("ArmorVariantManager_Core.Games.RE4.InputGuard")
        InputGuard.install(function()
            return global_config.block_game_mouse ~= false
                and (InputGuard.reff_visible() or (Main.panel ~= nil and Main.panel.is_open()))
        end,
            function(msg) log.warn(msg) end)
    end)

    -- 整套造型快捷键:Alt + 数字切到绑定的整套造型(手动选择),按住 Alt 时不让游戏读到绑定的数字键(换武器)。
    -- 只作用于主控角色;一个都没绑时不碰键盘
    pcall(function()
        local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
        local function key_down(vk)
            local ok, v = pcall(function() return reframework:is_key_down(vk) end)
            return ok and v == true
        end
        local function bound()
            local keys = hotkey_ctx and hotkey_ctx.config.hotkeys
            if type(keys) ~= "table" or next(keys) == nil then return nil end
            local out = {}
            for k in pairs(keys) do
                local d = math.tointeger(tonumber(k))
                if d then out[d] = true end
            end
            return out
        end
        local zh = function() return global_config.language == "zh" end
        hotkey_logic = Hotkeys.new({
            key_down = key_down,
            alt_down = function() return key_down(Hotkeys.ALT_VK) end,
            bound = bound,
            -- 绑定见 ModelV3 的 hotkeys:单项 = 切到那一项;轮换 = 切到当前手动选择的下一项(跳过关掉的)
            fire = function(digit)
                local ctx = hotkey_ctx
                local cfg = ctx and ctx.config
                local b = cfg and type(cfg.hotkeys) == "table" and cfg.hotkeys[tostring(digit)]
                if not b then return end
                local target
                if ModelV3.hotkey_is_cycle(b) then target = ModelV3.hotkey_next(cfg, b)
                elseif b.kind == "palette" then target = b.scheme
                else target = b.option end
                local where = b.kind == "base" and (zh() and "整套造型" or "Full outfit")
                    or b.kind == "group" and ((zh() and "状态组「" or "State group \"") .. b.group .. (zh() and "」" or "\""))
                    or (zh() and "调色" or "Colours")
                local suffix = "  (Alt+" .. digit .. ")"
                if target == nil then
                    Hotkeys.toast({ where .. (zh() and "：没有可轮换的项" or ": nothing to cycle through") .. suffix })
                    return
                end
                local layer_key
                if b.kind == "base" then
                    commit(ctx.kind_id, OpsV3.set_manual(cfg, "base", target)); layer_key = "base"
                elseif b.kind == "group" then
                    commit(ctx.kind_id, OpsV3.set_manual(cfg, b.group, target)); layer_key = ModelV3.layer_key(b.group)
                else
                    commit(ctx.kind_id, OpsV3.set_palette_active(cfg, target))
                end
                local label = target
                if target == "" then
                    label = b.kind == "palette" and (zh() and "初始" or "Original") or (zh() and "（无）" or "(none)")
                end
                local lines = { where .. (zh() and "：" or ": ") .. label .. suffix }
                -- 条件状态正接管这一层时,手动选择要等它结束才生效(调色不会被接管:引用的方案是叠在上面的)
                local by = layer_key and ctx.layers and ctx.layers[layer_key] and ctx.layers[layer_key].prio
                local st = by and cfg.conditions.states[by]
                if st then
                    lines[2] = zh() and ("条件「" .. st.name .. "」接管中，结束后生效")
                        or ("Condition \"" .. st.name .. "\" is in control; applies when it ends")
                end
                Hotkeys.toast(lines)
            end,
        })
        Hotkeys.install(hotkey_logic, function() return bound() ~= nil end, function(msg) log.warn(msg) end)
    end)

    -- 模型高度。装不上只记日志,不影响其他功能
    local ok_hf, err_hf = pcall(function()
        height_fix = require("ArmorVariantManager_Core.Games.RE4.HeightFix").new({
            skeleton_of = Utils.get_skeleton_transform,
            on_error = function(msg) note_error("height_fix", msg) end,
        })
    end)
    if not ok_hf then note_error("height_fix", err_hf) end

    -- 全身预览的拍摄对象:{ root = 角色根变换, meshes = 四个槛位的网格 }。
    --   玩家 / 伙伴:BodyUpdater 挂在身体对象上,它的变换就是角色根(2026-11-05 实测伙伴 ch2a1z0_body 无父节点)
    --   过场傀儡 / 模型鉴赏人偶:source 是网格表,从身体网格所在对象往上找到顶层变换
    local function portrait_subject(target)
        local source = target.source
        local meshes = {}
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            local mesh = Utils.get_mesh(source, slot)
            if mesh then meshes[#meshes + 1] = mesh end
        end
        if #meshes == 0 then return nil end
        local root
        if type(source) ~= "table" then
            local go = source:call("get_GameObject")
            root = go and go:call("get_Valid") and go:call("get_Transform") or nil
        end
        if not root then
            local body = Utils.get_mesh(source, "body") or meshes[1]
            local go = body:call("get_GameObject")
            local tr = go and go:call("get_Valid") and go:call("get_Transform") or nil
            for _ = 1, 16 do
                local parent = tr and tr:call("get_Parent")
                if not parent then break end
                tr = parent
            end
            root = tr
        end
        return root and { root = root, meshes = meshes } or nil
    end

    -- REFF 网页界面(可选)。未安装 REFF 时不注册,REF 原生面板照常可用。
    -- 网页与面板共用分组、配置读写和 Ops,只是各自记着自己选中的角色。
    local reff_ok, reff_err = pcall(function()
        -- 全身预览:相机与 GPU 交接在 Portrait.lua,网页只发心跳。拿不到玩家时不画。
        local portrait, portrait_web = require("ArmorVariantManager_Core.Games.RE4.Portrait").connect({
            settings = function()
                return { enabled = global_config.portrait_enabled == true,
                    distance = global_config.portrait_distance, height = global_config.portrait_height }
            end,
            -- 拍网页上选中的角色(玩家 / 伙伴 / 过场傀儡 / 模型鉴赏人偶);拿不到时退回主控
            player = function()
                local ok, subject = pcall(function()
                    local target = Main.reff and Main.reff.preview_target and Main.reff.preview_target()
                    return target and portrait_subject(target)
                end)
                if ok and subject then return subject end
                local manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
                local context = manager and manager:call("getPlayerContextRef")
                local body = context and context:call("get_BodyGameObject")
                if not body or not body:call("get_Valid") then return nil end
                local updater = context:call("get_BodyUpdater")
                local meshes = {}
                for _, slot in ipairs(Utils.MESH_SLOTS) do
                    local mesh = updater and Utils.get_mesh(updater, slot)
                    if mesh then meshes[#meshes + 1] = mesh end
                end
                return { root = body:call("get_Transform"), meshes = meshes }
            end,
            log = function(message) if log and log.info then log.info("[AVM Portrait] " .. message) end end,
        })
        if not portrait.register() then portrait_web = nil end
        Main.portrait = portrait
        Main.reff = require("ArmorVariantManager_Core.Games.RE4.Reff").connect({
            version = version, global_config = global_config, save_global_settings = save_global_settings, T = T,
            rename_dissolve = rename_dissolve_everywhere,
            targets = Targets.collect, groups = collect_character_groups, pick_group = pick_character_group,
            resolve_key = resolve_config_key, cfg_key = cfg_key, register_kind = register_kind,
            load_config = load_config, commit = commit, reset_ui_state = function() ui_state = {} end,
            ordered_presets = ordered_preset_names, char_display = char_display, target_label = target_display_name,
            TransformManager = TransformManager, Registry = Registry, Utils = Utils,
            -- 第二阶段:编辑、归属、备注与定位、存档 —— 和面板调用的是同一批函数
            slot_label = slot_label, visible_slots = visible_slots, request_reapply = request_reapply,
            snapshot_before_destructive = snapshot_before_destructive, config_is_trivial = config_is_trivial,
            make_independent = make_independent, reset_config = reset_config, try_match_kin = try_match_kin,
            save_slot = save_slot, load_slot = load_slot, delete_slot = delete_slot, all_slot_entries = all_slot_entries,
            auto_slot_name = auto_slot_name, has_backup = has_backup, has_onload_backup = has_onload_backup,
            restore_backup = restore_backup, restore_onload_backup = restore_onload_backup,
            start_preview = start_preview, set_solo = set_solo, get_preview = function() return preview end,
            documentation = require("ArmorVariantManager_Core.Games.RE4.Documentation"),
            -- v3:迁移与预设库
            migrate_to_v3 = migrate_to_v3, preset_view = preset_view, dismiss_preset_hint = dismiss_preset_hint,
            apply_preset = apply_preset, save_current_as_preset = save_current_as_preset,
            update_source_preset = update_source_preset, restore_autosave = restore_autosave,
            promote_autosave = promote_autosave, preset_lib = preset_lib, new_blank_config = new_blank_config,
            preview = portrait_web,
            -- 调色盘:映射(reload = true 重读 data 目录)、读不了的映射文件名、草稿写盘
            palette_profiles = load_palette_profiles, palette_profile_errors = function() return palette_profile_errors end,
            palette_dump = function(path, data) return pcall(json.dump_file, path, data) end, palette_dir = PALETTE_DIR,
            -- 替换 mdf:所有目标的所有槽位网格;清掉某个网格的调色状态(不还原,新 mdf2 里已经是写好的值)
            all_meshes = function()
                local out = {}
                for _, target in ipairs(Targets.collect()) do
                    for _, slot in ipairs(Utils.MESH_SLOTS) do
                        local mesh = Utils.get_mesh(target.source, slot)
                        if mesh then out[#out + 1] = mesh end
                    end
                end
                return out
            end,
            forget_palette = function(mesh)
                local key = tostring(mesh)
                for _, state in pairs(palette_state) do state[key] = nil end
                mdf2_cache = {}
            end,
            forget_mdf2 = function() mdf2_cache = {} end,
        })
    end)
    if not reff_ok then note_error("reff", reff_err) end

    -- 独立面板:不依赖 REFF 的图形界面(外观照 SKS)。数据走同一个 Reff 控制器,和网页语义一致。
    -- 装没装 REFF 都给入口;画不了(REFramework 太旧)时 available() 为 false,入口不显示
    if Main.reff then
        local ok_p, err_p = pcall(function()
            Main.panel = require("ArmorVariantManager_Core.Games.RE4.Panel.Panel").new({
                controller = Main.reff, global_config = global_config, save_global_settings = save_global_settings,
                version = version, hotkeys = Ops.PANEL_KEYS,
                set_language = function(lang)
                    if Ops.set_global(global_config, "language", lang) then save_global_settings() end
                end,
            })
        end)
        if not ok_p then note_error("panel", err_p) end
    end
end

return Main
