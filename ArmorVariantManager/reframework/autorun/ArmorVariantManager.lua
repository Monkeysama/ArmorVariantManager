local mod_name = "ArmorVariantManager"
local version = "3.1.9"
local author = "Moon、MK"

local global_config_path = "ArmorVariantManager/GlobalSettings.json"
local global_config = {
    language = "zh", -- 默认语言: zh (中文), en (英文)
    scan_interval = 0.5, -- 全量扫描间隔 (秒)
    body_id_ttl = 1.0, -- Body ID 缓存有效期 (秒)，默认缩短以加速换装检测
    scanner_batch_size = 100, -- 每帧扫描的对象数量
    enable_image_quality = false,      -- 是否启用自定义渲染比例
    image_quality_rate = 1.0,          -- 渲染比例（1.0 = 100%）
    new_ui_enabled = true,             -- 是否启用新版独立 UI 面板（关闭则使用旧版 ImGui 面板）
    new_ui_key = 0x24,                 -- 新版面板开关按键（默认 Home）
    new_ui_mute_game_input = true,     -- 面板打开时是否屏蔽游戏输入（释放鼠标 / 视角不乱转）
    -- 新版 UI 的绘制后端：
    --   "auto"   = 优先用原生 reframework-d2d 插件，没有则用内置 draw 绘制后端
    --   "imgui"  = 兼容旧配置名，强制使用内置 draw 后端（默认字体，无需原生插件）
    --   "native" = 优先使用原生插件，不可用时自动使用内置绘制
    new_ui_backend = "auto",
    new_ui_debug_force_visible = false, -- 调试用：强制显示新版面板（不需要按 Hotkey）
    new_ui_debug_manual_picker = false, -- 调试用：自动打开「手动查找预设」文件列表
    auto_set_selected_preset_as_default = true, -- 点击预设时是否自动记录为默认预设
    debug_profile = false,             -- 性能诊断：把每帧各环节耗时写入 ArmorVariantManager/Profile.json

    -- ===== 联机（多人）=====
    -- 差分配置是按「模型名（body_id）」保存的，所以同一套模型的玩家天然共用同一份配置。
    -- 打开后：除了本地玩家（主角），场景里的其他玩家也会被应用差分 —— 队友穿着同一套
    -- 模型时就能看到同样的差分效果（与荒野版本行为一致）。
    -- 关闭后：只处理本地玩家，行为与 v3.0.6 完全相同。
    enable_multiplayer = true,
    -- 每轮最多处理几个「其他玩家」（摊到多帧执行，避免多人时掉帧）。
    -- 本地玩家永远每轮都处理，不受这个值影响；其他玩家按轮询依次处理。
    multiplayer_players_per_tick = 1,
    -- 「其他玩家」的武器部件重新查找间隔（秒）。武器部件的递归查找偏贵，
    -- 所以对非本地玩家做限频；本地玩家不受影响。
    multiplayer_weapon_scan_interval = 2.0,
    -- 场景兜底扫描每帧处理多少个 Transform 组件。
    -- - 这个值直接决定「扫描期间每帧多花多少时间」：实测单个组件约 3.6us，
    --   24 个/帧 ≈ 0.086ms/帧（帧时间的 1.4%），野外的 8000 个组件约 2~3 秒扫完。
    --   调大 = 恢复更快但扫描期间更吃帧；调小 = 更省但恢复更慢。
    --   （只在「PlayerManager 完全给不出本地玩家」时才会真正扫描，正常游玩为 0。）
    scene_scan_batch = 24
}

local Localization = require("ArmorVariantManager_Core.Localization")
local Utils = require("ArmorVariantManager_Core.Utils")
local SceneObject = require("ArmorVariantManager_Core.SceneObject")
local TransformManager = require("ArmorVariantManager_Core.TransformManager")
-- 自动查找预设的统一匹配内核（兼容「无分组的老预设」与「使用分组的新预设」）
local PresetAutoFinder = require("ArmorVariantManager_Core.PresetAutoFinder")

-- 新版 UI 模块：先清空 package.loaded，避免 REFramework 复用旧脚本缓存
-- （本文件没有 re.on_script_reset，因此用这种方式替代）
local refd2d_module_names = {
    "ArmorVariantManager_Core.Profiler",
    "ArmorVariantManager_Core.PresetAutoFinder",
    "ArmorVariantManager_Core.UI.VariantManagerUI",
    "ArmorVariantManager_Core.Documentation",
    "ArmorVariantManager_UI",
    "ArmorVariantManager_UI.Component.Runtime",
    "ArmorVariantManager_UI.Component.Button",
    "ArmorVariantManager_UI.Component.Checkbox",
    "ArmorVariantManager_UI.Component.Input",
    "ArmorVariantManager_UI.Component.InputNumber",
    "ArmorVariantManager_UI.Component.List",
    "ArmorVariantManager_UI.Component.Panel",
    "ArmorVariantManager_UI.Component.Select",
    "ArmorVariantManager_UI.Component.Slider",
    "ArmorVariantManager_UI.Component.Tag",
    "ArmorVariantManager_UI.Component.Window",
    "ArmorVariantManager_UI.Service.BridgeRuntime",
    "ArmorVariantManager_UI.Service.ImGuiBackend",
    "ArmorVariantManager_UI.Service.WindowsInput",
    "ArmorVariantManager_UI.Service.EngineMouse",
    "ArmorVariantManager_UI.Service.DrawClip",
    "ArmorVariantManager_UI.Service.NativeD2DBackend",
    "ArmorVariantManager_UI.Service.InputBlocker",
    "ArmorVariantManager_UI.Service.NativeTextInput"
}
if package and package.loaded then
    for _, module_name in ipairs(refd2d_module_names) do
        package.loaded[module_name] = nil
    end
end
local VariantManagerUI = require("ArmorVariantManager_Core.UI.VariantManagerUI")

-- ========== 性能诊断 ==========
-- 默认关闭。关闭时 Profiler.begin() 只做一次布尔判断后返回 nil，
-- 所有测量点变成「判断 + 直接返回」，对帧时间的影响可以忽略。
-- 打开方式：reframework/data/ArmorVariantManager/GlobalSettings.json 里 debug_profile = true
local Profiler = require("ArmorVariantManager_Core.Profiler")
_G.__AVM_PROFILER = Profiler

local function T(key)
    if not key then return "nil" end
    local lang = global_config.language or "en"
    if not Localization[lang] then lang = "en" end
    return Localization[lang][key] or tostring(key)
end

local function load_global_settings()
    local loaded = json.load_file(global_config_path)
    if loaded then
        if loaded.language then global_config.language = loaded.language end
        if loaded.scan_interval then global_config.scan_interval = loaded.scan_interval end
        if loaded.body_id_ttl then global_config.body_id_ttl = loaded.body_id_ttl end
        if loaded.scanner_batch_size then global_config.scanner_batch_size = loaded.scanner_batch_size end
        if loaded.enable_image_quality ~= nil then global_config.enable_image_quality = loaded.enable_image_quality end
        if loaded.image_quality_rate then global_config.image_quality_rate = loaded.image_quality_rate end
        if loaded.new_ui_enabled ~= nil then global_config.new_ui_enabled = loaded.new_ui_enabled == true end
        if loaded.new_ui_key then global_config.new_ui_key = loaded.new_ui_key end
        if loaded.new_ui_mute_game_input ~= nil then
            global_config.new_ui_mute_game_input = loaded.new_ui_mute_game_input == true
        end
        if loaded.new_ui_backend == "native" or loaded.new_ui_backend == "imgui"
            or loaded.new_ui_backend == "auto" then
            global_config.new_ui_backend = loaded.new_ui_backend
        end
        if loaded.new_ui_debug_force_visible ~= nil then
            global_config.new_ui_debug_force_visible = loaded.new_ui_debug_force_visible == true
        end
        if loaded.new_ui_debug_manual_picker ~= nil then
            global_config.new_ui_debug_manual_picker = loaded.new_ui_debug_manual_picker == true
        end
        if loaded.auto_set_selected_preset_as_default ~= nil then
            global_config.auto_set_selected_preset_as_default =
                loaded.auto_set_selected_preset_as_default == true
        end
        if loaded.debug_profile ~= nil then
            global_config.debug_profile = loaded.debug_profile == true
        end
        if loaded.enable_multiplayer ~= nil then
            global_config.enable_multiplayer = loaded.enable_multiplayer == true
        end
        if tonumber(loaded.multiplayer_players_per_tick) then
            local n = math.floor(tonumber(loaded.multiplayer_players_per_tick))
            if n < 0 then n = 0 elseif n > 8 then n = 8 end
            global_config.multiplayer_players_per_tick = n
        end
        if tonumber(loaded.multiplayer_weapon_scan_interval) then
            local v = tonumber(loaded.multiplayer_weapon_scan_interval)
            if v < 0.2 then v = 0.2 elseif v > 30.0 then v = 30.0 end
            global_config.multiplayer_weapon_scan_interval = v
        end
        if tonumber(loaded.scene_scan_batch) then
            local b = math.floor(tonumber(loaded.scene_scan_batch))
            if b < 4 then b = 4 elseif b > 128 then b = 128 end
            global_config.scene_scan_batch = b
        end
    end
end
local function save_global_settings()
    json.dump_file(global_config_path, global_config)
    -- 同步给 TransformManager 用的语言缓存，避免它为了取一个语言名去读盘
    _G.__AVM_LANGUAGE = global_config.language
end
load_global_settings()

-- 语言值同步一次（内存值优先，TransformManager 不再为此读盘）
_G.__AVM_LANGUAGE = global_config.language

-- 性能诊断总开关（必须在 load_global_settings 之后，因为开关值来自配置文件）
Profiler.enabled = global_config.debug_profile == true
Profiler.reset()

-- 禁用 ImGui ID 冲突警告（避免弹窗）
pcall(function()
    local io = imgui.get_io()
    if io then
        io.ConfigDebugHighlightIdConflicts = false
    end
end)


-- 缓存常用类型和方法
local type_mesh = nil
local method_cache = {
    Component_get_GameObject = sdk.find_type_definition("via.Component"):get_method("get_GameObject"),
    GameObject_get_Name = sdk.find_type_definition("via.GameObject"):get_method("get_Name"),
    GameObject_getComponent = sdk.find_type_definition("via.GameObject"):get_method("getComponent(System.Type)"),
    Scene_findComponents = sdk.find_type_definition("via.Scene"):get_method("findComponents(System.Type)")
}
local type_cache = {
    via_transform = sdk.typeof("via.Transform"),
    app_character = sdk.typeof("app.Character"),
    app_hunter_character = sdk.typeof("app.HunterCharacter")
}

-- ========== 预定义 PlayerManager 相关类型和方法 ==========
local playerManagerTypeDef = sdk.find_type_definition("snow.player.PlayerManager")
local playerListField = playerManagerTypeDef and playerManagerTypeDef:get_field("PlayerList")
local playerListGetItem = nil
if playerListField then
    local playerListTypeDef = playerListField:get_type()
    playerListGetItem = playerListTypeDef:get_method("get_Item")
end

-- ========== 模式切换 ==========
local is_weapon_mode = false

-- 状态变量
local loaded_configs = {}
local active_overrides = {}
local merge_overrides
local active_group_presets = {}   -- body_id -> { group_name = preset_name }

-- ============================================================================
--  怪物血量跟踪门控
-- ----------------------------------------------------------------------------
--  实测数据（37,778 帧 / 270 秒）：sdk.hook 在 snow.enemy.EnemyCharacterBase:update
--  上的回调被调用了 **1,627,099 次**（约 43 次/帧），累计 6037ms，
--  是所有环节里最贵的一项（占插件每帧总成本的 ~38%）。
--  而其中只有 1.41% 的调用真正命中了任务目标怪 —— 绝大多数都是小怪/环境生物。
--  如果没有任何配置启用「怪物血量」条件，这个钩子里的托管 API 调用就是纯浪费，
--  所以这里根据「已加载配置里有没有真的用到它」来整体开关跟踪逻辑。
-- ============================================================================
local function config_uses_monster_hp(cfg)
    if not cfg or cfg.enable_transform ~= true then return false end
    local uses = (cfg.transform_type == "monster_hp")
        or (cfg.is_parallel and cfg.parallel_settings
            and cfg.parallel_settings.monster_hp
            and cfg.parallel_settings.monster_hp.enabled == true)
    if not uses then return false end
    local rules = cfg.monster_hp_transform_rules
    return rules ~= nil and next(rules) ~= nil
end

local function refresh_monster_hp_gate()
    local needed = false
    for _, cfg in pairs(loaded_configs) do
        if config_uses_monster_hp(cfg) then
            needed = true
            break
        end
    end
    if TransformManager.set_monster_hp_tracking then
        TransformManager.set_monster_hp_tracking(needed)
    end
    return needed
end
local current_config = {
    default_preset = "",
    presets = {},
    groups = {},
    enable_transform = false,
    transform_type = "weapon",
    is_parallel = false,
    parallel_settings = {
        weapon = { enabled = true, priority = 1 },
        scroll = { enabled = false, priority = 2 },
        monster_hp = { enabled = false, priority = 3 },
        longsword = { enabled = false, priority = 4 },
        dual_blades = { enabled = false, priority = 5 },
        switch_axe = { enabled = false, priority = 6 },
        charge_axe = { enabled = false, priority = 7 },
        greatsword_level = { enabled = false, priority = 8 },
        hammer = { enabled = false, priority = 9 },
        bow = { enabled = false, priority = 10 }
    },
    weapon_transform_rules = {
        { state = "sheathed", targets = {} },
        { state = "drawn", targets = {} }
    },
    scroll_transform_rules = {
        { state = "red", targets = {} },
        { state = "blue", targets = {} }
    },
    longsword_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    dual_blades_transform_rules = {
        { state = 0, targets = {} },
        { state = 1, targets = {} },
        { state = 2, targets = {} }
    },
    switch_axe_transform_rules = {
        { state = 0, targets = {} },
        { state = 1, targets = {} },
        { state = 2, targets = {} }
    },
    charge_axe_transform_rules = {
        { state = 0, targets = {} },
        { state = 1, targets = {} },
        { state = 2, targets = {} },
        { state = 3, targets = {} },
        { state = 4, targets = {} },
        { state = 5, targets = {} }
    },
    greatsword_level_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    hammer_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} }
    },
    bow_transform_rules = {
        { level = 0, targets = {} },
        { level = 1, targets = {} },
        { level = 2, targets = {} },
        { level = 3, targets = {} }
    },
    monster_hp_transform_rules = {}
}
local PART_INDEX_TO_NAME = {
    [0] = "helm",
    [1] = "body",
    [2] = "arm",
    [3] = "waist",
    [4] = "leg"
}

-- UI 状态
local new_preset_name = ""
local selected_preset_index = 1
local preset_names_list = {}
local auto_find_log = ""
local current_group_name = ""
local selected_group_index = 1
local group_names_list = {}
local new_group_name = ""
local new_group_is_global = false
local is_selection_mode = false
local pending_material_selections = {}

-- 材质过滤
local mat_filter_text = {}

-- 手动查找预设状态
local show_manual_selector = false
local manual_files = {}
local manual_file_names = {}
local selected_manual_file_index = 1
local manual_load_error = ""

-- 排序状态
local sort_mode = nil   -- "preset" or "group"
local sort_temp_list = {}
local sort_selected_index = 1

-- 备份恢复状态
local config_restored = {}
local config_restore_handled = {}

-- 特殊内嵌式 CG 标志（用于临时绕过缓存）
local g_is_special_cg = false
-- ============================================================================
--  特殊CG期间的应用节流：**按角色 + 按时间**
-- ----------------------------------------------------------------------------
--  - v3.1.2 修的问题：事件主角初次登场时是「无预设的初始状态」，要过几秒才正常。
--    原因是旧的节流用的是**一个全局调用计数器** special_cg_frame_counter：
--    所有 CG 角色、而且防具与武器**共用**它，只有「第 15 次调用」那一次才真的应用。
--    于是「这次应用落到哪个角色头上」基本是随机的 ——
--    单个角色要等到自己的调用正好排到第 15 次才拿到差分。
--    一场过场里如果有 3~4 个 CG 角色（每人防具+武器各一次调用 = 每轮 6~8 次调用），
--    就要好几秒才能轮到自己，而且先后顺序不可预测。
--
--    现在改成「按角色地址记录上次应用时刻」：节流只限制**同一个角色**的频率，
--    角色之间不再互相拖累。同时也顺手解决了「防具把武器的额度吃光」的问题。
-- ============================================================================
local SPECIAL_CG_APPLY_INTERVAL = 0.08   -- 同一个 CG 角色最快每 0.08 秒应用一次

-- ========== 版本号缓存 ==========
-- overrides_version[body_id]：这份「意图」被改动过几次。
-- - v3.1.0 起，「是否已经把这个版本应用到某个角色」不再记在这里，而是记在
--   char_applied[角色地址]（见 apply_preset_to_character 上方的说明）。
--   原因：同一个 body_id 可能对应多个玩家（联机时穿同一套模型），
--   按 body_id 记「已应用」会让第二个玩家永远被跳过。
local overrides_version = {}        -- body_id -> 版本号（整数）

-- 递增版本号
local function bump_overrides_version(body_id)
    if body_id then
        overrides_version[body_id] = (overrides_version[body_id] or 0) + 1
    end
end

-- 辅助函数
local function deep_copy_table(orig) return Utils.deep_copy_table(orig) end
local function get_type(name) return Utils.get_type(name) end
local function get_player_manager() return sdk.get_managed_singleton("snow.player.PlayerManager") end

-- ========== 多玩家管理 ==========
local player_list = {}

-- - 性能要点：每帧都会用到「只含本地玩家」的列表和「空列表」。
--   原来每帧都新建一张表（players_to_process = { local_player }、
--   event_players = cached_event_players or {}），在 144fps 下就是每秒几百次
--   垃圾分配，会给 Lua GC 增加没必要的负担。这里改成复用固定表。
--   （这两张表只被读取，不会被写入，复用是安全的。）
local single_player_buffer = {}
local EMPTY_PLAYER_LIST = {}

-- 武器部件缓存：key = player_addr, value = weapon_parts 列表
-- - 注意：这份缓存必须**提前**声明。因为 get_weapon_attack_part_name（本文件靠前）
--   会读写它，避免每次逻辑都做一遍「深度 5 的递归查找」。
--   如果按原来的位置声明在中间，前面那个函数会把它当成全局变量，
--   写入的是全局表、后面读的是局部表，优化就静默失效了。
local weapon_part_cache = {}

-- - v3.1.0：get_weapon_attack_part_name 也需要用到「带缓存的武器部件查询」，
--   而它的实现在文件后面（依赖 clear_player_cache 等）。这里先做前向声明，
--   后面再赋值；这样查询顺序就是「先查缓存 → 没有再递归找」，联机时不会
--   因为每个玩家都重跑一遍 DFS 而掉帧。
local get_cached_weapon_parts = nil

-- ========== 失效对象安全访问 ==========
-- 切换场景（读图 / 回营地 / 进出任务）后，缓存里可能还留着已经被销毁的对象。
-- 这时直接调 obj:call("get_Name") / get_Transform 会抛
--   System.InvalidOperationException: Internal game exception thrown in
--   REMethodDefinition::invoke for via.GameObject.get_Name
-- REFramework 会把它显示在 ScriptRunner 面板里刷屏（例如
-- "ArmorVariantManager.lua:514: in upvalue 'get_primary_player'"）。
-- 调用前检查引擎 get_Valid，不能把“仍是托管对象”当作“底层场景对象仍存活”。
local function safe_object_name(obj)
    local name = SceneObject.call(obj, "get_Name")
    if type(name) == "string" then return name end
    return nil
end

local function safe_object_alive(obj)
    return SceneObject.is_alive(obj)
end

-- 辅助函数：检查玩家是否有 body 子物体
local function player_has_body(player)
    if not safe_object_alive(player) then return false end
    -- 整条 transform 链都放进 pcall：链条上任一环失效都会抛异常
    local ok, result = pcall(function()
        local transform = SceneObject.call(player, "get_Transform")
        if not transform then return false end
        local child = SceneObject.call(transform, "get_Child")
        local guard = 0
        while child do
            guard = guard + 1
            if guard > 256 then break end
            local child_obj = SceneObject.call(child, "get_GameObject")
            if child_obj then
                local name = SceneObject.call(child_obj, "get_Name")
                if name and string.find(name, "body") then
                    return true
                end
            end
            child = SceneObject.call(child, "get_Next")
        end
        return false
    end)
    return ok and result == true
end

-- 名称是否"像玩家"（大小写不敏感）。
-- - 不能写成 name:lower() —— 那会为每个组件新建一个字符串，
--   8000 个组件就是 8000 次分配，是这条扫描路径上很可观的一部分开销。
--   这里用 Lua 模式做大小写不敏感匹配，零分配。
local function name_looks_like_player(name)
    -- "player" / "female" / "male"（"female" 里本来就含 "male"，所以一条就够）
    return string.find(name, "[Pp][Ll][Aa][Yy][Ee][Rr]") ~= nil
        or string.find(name, "[Mm][Aa][Ll][Ee]") ~= nil
end

-- ============================================================================
--  按需场景扫描（回退用）
-- ----------------------------------------------------------------------------
--  - v3.1.0 起这里改成**增量式**（照搬荒野版本 tick_scanner 的思路）：
--    崛起野外要遍历约 8,000 个 Transform 组件、单次几十毫秒
--    （v3.0.5 的性能报告实测峰值 ~29ms）。旧实现只把**调用频率**降到
--    「正命中 10 秒 / 未命中 3 秒」，但**单次代价没变** ——
--    联机时只要 findMasterPlayer 短暂拿不到人，就会周期性出现这种几十毫秒的尖峰，
--    表现出来就是「联机时突然卡一下」。
--
--    现在扫描被切成每帧一小批（global_config.scanner_batch_size），
--    由 PlayerDir.scan_tick() 每帧推进；PlayerDir.scan_once() 变成**非阻塞**：
--    它只返回已有结果，没有就返回 nil（下一帧继续推进）。
--    实现挂在 PlayerDir 上，见下面的 PlayerDir.scan / scan_tick / scan_once。
-- ============================================================================

-- 获取 Body ID（防具模式）
local get_character_body_id = nil
local function get_character_body_id_impl(character)
    if not character then return nil end
    if not safe_object_alive(character) then return nil end
    -- 整条 transform 链 + get_Name 都放进 pcall（场景切换后对象可能已失效）
    local ok, body_id = pcall(function()
        local transform = SceneObject.call(character, "get_Transform")
        if transform then
            local child = SceneObject.call(transform, "get_Child")
            local guard = 0
            while child do
                guard = guard + 1
                if guard > 256 then break end
                local child_obj = SceneObject.call(child, "get_GameObject")
                if child_obj then
                    local name = SceneObject.call(child_obj, "get_Name")
                    if name and string.find(name, "body") then
                        return name
                    end
                end
                child = SceneObject.call(child, "get_Next")
            end
        end
        local go_name = SceneObject.call(character, "get_Name")
        if go_name then return go_name end
        return nil
    end)
    if ok then return body_id end
    return nil
end
get_character_body_id = function(character)
    local t0 = Profiler.begin("body_id")
    local result = get_character_body_id_impl(character)
    Profiler.finish("body_id", t0)
    Profiler.count("body_id_calls")
    return result
end

-- ========== 获取武器的主要攻击部件名称（用于预设管理ID） ==========
-- 采用原有崛起版本逻辑：基于部件前缀确定主要部件
-- - 性能要点：原来固定按 1：主列表、2：联机玩家 的顺序遍历，这里保持语义不变，
--   但把这张映射表提到外面（原来每次调用都要新建一张表，144fps 下就是每秒几百次分配）。
local WEAPON_MAIN_PART_INDEX = {
    [Utils.WEAPON_TYPE.GREATSWORD] = 1,
    [Utils.WEAPON_TYPE.SWITCH_AXE] = 1,
    [Utils.WEAPON_TYPE.LONGSWORD] = 2,
    [Utils.WEAPON_TYPE.LIGHT_BOWGUN] = 1,
    [Utils.WEAPON_TYPE.HEAVY_BOWGUN] = 1,
    [Utils.WEAPON_TYPE.HAMMER] = 1,
    [Utils.WEAPON_TYPE.GUNLANCE] = 2,
    [Utils.WEAPON_TYPE.LANCE] = 2,
    [Utils.WEAPON_TYPE.SWORD_SHIELD] = 2,
    [Utils.WEAPON_TYPE.DUAL_BLADES] = 1,
    [Utils.WEAPON_TYPE.HUNTING_HORN] = 1,
    [Utils.WEAPON_TYPE.CHARGE_BLADE] = 2,
    [Utils.WEAPON_TYPE.INSECT_GLAIVE] = 2,
    [Utils.WEAPON_TYPE.BOW] = 1,
}

local get_weapon_attack_part_name = nil
-- player_handle：该玩家的 snow.player.Player 托管对象（可选）。
-- - 联机时它很关键：武器类型（_playerWeaponType）必须读**这名玩家自己**的，
--   旧实现永远读本地玩家的，于是队友会被套上主角的武器部件。
local function get_weapon_attack_part_name_impl(player_obj, player_handle)
    if not player_obj then return nil end
    if not safe_object_alive(player_obj) then return nil end

    -- - 先查缓存（命中就不做递归查找）。
    --   旧实现是「每次都重新递归查一遍，再顺手写缓存」，等于缓存只是给
    --   紧接着的 get_cached_weapon_parts 用，自己从不命中 —— 联机时
    --   4 个玩家每轮就是 4 次深度 5 的递归。
    local weapon_parts = nil
    if get_cached_weapon_parts then
        weapon_parts = get_cached_weapon_parts(player_obj, player_handle)
    end
    if not weapon_parts then
        weapon_parts = Utils.get_current_weapon_parts(player_handle or player_obj)
    end
    if not weapon_parts then return nil end

    local weapon_type = Utils.get_current_weapon_type(player_handle or player_obj)
    if not weapon_type then return nil end

    -- 对于双刀特殊处理
    if weapon_type == Utils.WEAPON_TYPE.DUAL_BLADES then
        if weapon_parts[1] then
            return safe_object_name(weapon_parts[1])
        end
    end
    
    local main_part_index = WEAPON_MAIN_PART_INDEX
    
    local idx = main_part_index[weapon_type] or 1
    if weapon_parts[idx] then
        return safe_object_name(weapon_parts[idx])
    end
    for _, part in ipairs(weapon_parts) do
        if part then return safe_object_name(part) end
    end
    return nil
end
get_weapon_attack_part_name = function(player_obj, player_handle)
    local t0 = Profiler.begin("weapon_attack_part_name")
    local result = get_weapon_attack_part_name_impl(player_obj, player_handle)
    Profiler.finish("weapon_attack_part_name", t0)
    Profiler.count("weapon_attack_part_name_calls")
    return result
end

-- 前向声明：Mesh 组件的真实查找实现在文件后面（那时 type_mesh / get_type 都已就绪）。
-- PlayerDir.mesh_of 会对它做「按对象地址 + TTL + 存活校验」的缓存。
local get_mesh_component_recursive_uncached = nil

-- ============================================================================
--  玩家目录（PlayerDir）
-- ----------------------------------------------------------------------------
--  统一回答两个问题：① 谁是本地玩家（主角）？ ② 场景里还有哪些玩家？
--
--  - 为什么需要这一层
--    旧实现找主角的方式是「PlayerList 里第一个名字以 player 开头的对象」。
--    这在联机时**必然出错**。游戏内实测（4 人联机，崛起）：
--        player00 / player01 / player02  = 队友
--        player03                        = 本地玩家（主角）
--    对象名是按**加入房间的顺序**分配的，和「谁是本地玩家」毫无关系，
--    所以旧写法会让面板显示到队友的配置上去。
--
--  - 可靠判定方式（同样来自游戏内实测，与 Lua Bone / Lua Face 一致）
--      master = PlayerManager:findMasterPlayer()
--      本地玩家 = PlayerList 中 getPlayerIndex() == master:getPlayerIndex() 的那一个
--    4 个玩家里**恰好只有一个** index 匹配；再用对象同一性做双保险。
--    完全不再依赖对象名字。
--
--  - 性能
--    整个目录按 refresh_interval 节流重建，帧循环里读的是缓存表；
--    本地玩家的 GameObject 还会额外持久化 persist 秒，
--    避免读图 / 过场切换的瞬间面板闪烁或掉回「未知」。
--
--  - 写成一张表（而不是一堆顶层 local function）是刻意的：
--    ArmorVariantManager.lua 的 main chunk 已经用掉 189 个局部变量槽位，
--    而 Lua 的上限是 200。表字段不占槽位，所以这里统一挂在 PlayerDir 下。
-- ============================================================================
local PlayerDir = {
    entries = {},          -- { { player = 托管对象, obj = GameObject, index = n, is_local = bool } }
    others = {},           -- 只含「其他玩家」的数组（帧循环用，复用同一张表）
    local_entry = nil,
    local_index = nil,
    last_local_obj = nil,  -- 持久化：最近一次确认过的本地玩家 GameObject
    last_local_time = 0,
    last_refresh = -math.huge,
    valid = false,
    refresh_interval = 0.5,   -- 目录最长重建间隔（秒）
    persist = 1.0,            -- 本地玩家短暂读不到时沿用上次结果的时间（秒）
    refresh_count = 0,
    -- 主角 body_id 的短 TTL 缓存（省一个顶层局部变量槽位）
    primary_body_id = { ttl = 0.25, key = nil, value = nil, time = 0 },
    -- 防具部件缓存的重试间隔（见 PlayerDir.parts）
    parts_retry = 0.5,

    -- ========================================================================
    --  body_id 缓存（按角色地址）
    -- ------------------------------------------------------------------------
    --  - 照搬荒野版本的 body_id_cache + body_id_ttl：
    --    取一次 body_id 要遍历角色子物体（12 个部件 × 3 次托管调用 ≈ 36 次），
    --    而联机时每个处理周期都要给**每个玩家**取一次。缓存 1 秒后，
    --    这些遍历从「每轮 × 人数」降到「每秒 × 人数」。
    --    TTL 直接用设置里的 body_id_ttl（默认 1.0 秒，可调）。
    -- ========================================================================
    body_id = { by_char = {}, default_ttl = 1.0 },

    -- ========================================================================
    --  Mesh 组件缓存（按部件对象地址）
    -- ------------------------------------------------------------------------
    --  - 照搬荒野版本的 character_mesh_cache：
    --    get_mesh_component_recursive 每次都要 type:get_runtime_type() + getComponent，
    --    一次应用要跑 5 次。缓存后只在换装/模型重建时重算。
    -- ========================================================================
    mesh = { by_obj = {}, ttl = 2.0 },

    -- ========================================================================
    --  增量式场景扫描的状态（见下方 scan_tick / scan_once）
    -- ========================================================================
    scan = {
        state = "IDLE",           -- IDLE / PROCESSING
        transforms = nil,
        count = 0,
        index = 1,
        last_scan_time = -math.huge,
        hit_ttl = 10.0,           -- 找到玩家后的结果有效期
        miss_ttl = 3.0,           -- 「没找到」的结果有效期
        result = nil,
        result_time = -math.huge,
        result_valid = false,
        scan_count = 0,
        retry_at = -math.huge,    -- 失效快照丢弃后短暂等待，避免读图期间每帧重扫
    },
}

function PlayerDir.reset()
    PlayerDir.entries = {}
    PlayerDir.others = {}
    PlayerDir.local_entry = nil
    PlayerDir.local_index = nil
    PlayerDir.last_local_obj = nil
    PlayerDir.last_local_time = 0
    PlayerDir.last_refresh = -math.huge
    PlayerDir.valid = false
    PlayerDir.scan_reset()
    PlayerDir.body_id.by_char = {}
    PlayerDir.mesh.by_obj = {}
end

-- body_id：带 TTL 缓存（见 PlayerDir.body_id 上的说明）
-- - TTL 到期时先用**部件签名**判断模型有没有换：
--   签名没变就只续期、不重算，于是那个「遍历 12 个子物体」的动作
--   从「每轮每人一次」降到「只有真的换装时才做一次」。
--
-- - v3.1.2 补的一个坑：只有真的读到「身体部件」（名字里有 body）才值得缓存。
--   get_character_body_id 在没有 body 子物体时会退化成「角色自己的对象名」
--   （例如 player03 / 过场角色的对象名），这代表**模型还没生成完**。
--   旧实现把这种结果也按 1 秒缓存，于是事件主角初次登场后会先拿着一个找不到
--   配置的假 id 卡住，要等缓存过期才重新识别 —— 体感就是「过几秒才出现预设」。
--   现在这种结果只缓存 0.1 秒，下一拍就会重算。
function PlayerDir.body_id_of(character)
    if not safe_object_alive(character) then return nil end
    local addr = tostring(character)
    local now = os.clock()
    local ttl = tonumber(global_config.body_id_ttl) or PlayerDir.body_id.default_ttl
    if ttl < 0.1 then ttl = 0.1 end
    local cached = PlayerDir.body_id.by_char[addr]
    if cached then
        local eff_ttl = cached.short and 0.1 or ttl
        if (now - cached.time) < eff_ttl then
            return cached.id
        end
    end
    local parts = PlayerDir.parts(character)
    -- 只对「真的读到了身体部件」的结果续期；退化成对象名的结果不续期（见上面的说明）
    if cached and not cached.short and cached.id ~= nil
        and parts and cached.sig == parts.sig then
        cached.time = now            -- 模型没换 → 续期
        return cached.id
    end
    local id = get_character_body_id(character)
    local looks_like_body_part = id ~= nil and string.find(id, "body", 1, true) ~= nil
    PlayerDir.body_id.by_char[addr] = {
        id = id, time = now, sig = parts and parts.sig or nil,
        short = not looks_like_body_part
    }
    return id
end

function PlayerDir.invalidate_body_id(character)
    if not character then return end
    PlayerDir.body_id.by_char[tostring(character)] = nil
end

-- mesh 组件：带 TTL + 存活校验的缓存（见 PlayerDir.mesh 上的说明）
function PlayerDir.mesh_of(game_obj)
    if not safe_object_alive(game_obj) then return nil end
    local addr = tostring(game_obj)
    local now = os.clock()
    local cached = PlayerDir.mesh.by_obj[addr]
    if cached and (now - cached.time) < PlayerDir.mesh.ttl
        and cached.mesh ~= nil and safe_object_alive(cached.mesh) then
        return cached.mesh
    end
    local mesh = get_mesh_component_recursive_uncached(game_obj)
    if mesh ~= nil then
        PlayerDir.mesh.by_obj[addr] = { mesh = mesh, time = now }
    else
        PlayerDir.mesh.by_obj[addr] = nil
    end
    return mesh
end

-- ============================================================================
--  增量式场景扫描（照搬荒野版本 tick_scanner 的思路）
-- ----------------------------------------------------------------------------
--  scan_tick()：每帧调用一次，空闲时只做一次时间比较；扫描中每次只处理
--               scanner_batch_size 个 Transform 组件，所以永远不会出现
--               「一帧卡几十毫秒」的情况。
--  scan_once()：给「找不到本地玩家」时兜底用。非阻塞 —— 有结果就给结果，
--               没有就顺手推进一步并返回 nil（下一帧接着推进）。
-- ============================================================================
function PlayerDir.scan_reset()
    local scan = PlayerDir.scan
    scan.state = "IDLE"
    scan.transforms = nil
    scan.count = 0
    scan.index = 1
    scan.result = nil
    scan.result_valid = false
    scan.result_time = -math.huge
    scan.last_scan_time = -math.huge
    scan.retry_at = -math.huge
end

function PlayerDir.scan_tick()
    local scan = PlayerDir.scan
    local now = os.clock()

    if now < scan.retry_at then return end

    if scan.state == "IDLE" then
        -- 结果还在有效期内 → 什么都不用做（正常游玩每帧走到这里只有一次比较）
        if scan.result_valid then
            local ttl = scan.result and scan.hit_ttl or scan.miss_ttl
            if (now - scan.result_time) < ttl then return end
        end
        -- 取场景里的全部 Transform（这一次调用本身不贵，贵的是逐个读名字）
        local t_start = Profiler.begin("scene_scan_start")
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        if not scene_manager then return end
        local scene = sdk.call_native_func(scene_manager,
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local transforms = SceneObject.call(scene, "findComponents(System.Type)", type_cache.via_transform)
        if not transforms then return end
        local list = transforms:get_elements()
        if not list then return end
        Profiler.finish("scene_scan_start", t_start)
        scan.transforms = list
        scan.count = #list
        scan.index = 1
        scan.state = "PROCESSING"
        scan.result = nil
        scan.result_valid = false
        scan.scan_count = scan.scan_count + 1
        scan.last_scan_time = now
        return
    end

    -- PROCESSING：这一帧只处理一小批
    -- - 批大小用专用的 scene_scan_batch（默认 24），不直接用 UI 上的
    --   scanner_batch_size —— 后者默认 100，扫描期间会吃掉约 0.36ms/帧。
    local batch = tonumber(global_config.scene_scan_batch) or 24
    if batch < 4 then batch = 4 end
    if batch > 128 then batch = 128 end
    local t_batch = Profiler.begin("scene_scan_batch")
    local i = scan.index
    local last = i + batch - 1
    if last > scan.count then last = scan.count end
    local get_component_go = method_cache.Component_get_GameObject
    while i <= last do
        -- SystemArray/get_elements 的元素在读取时才解包；场景切换后，
        -- scan.transforms[i] 本身就可能抛 sol_lua_push，并不只是在 call 时抛。
        -- 整个读取与调用一起保护；失效后丢弃旧快照，不能每帧卡在同一批。
        local ok, game_obj = pcall(function()
            local t = scan.transforms[i]
            if t == nil then return nil end
            if not safe_object_alive(t) then error("AVM: stale Transform snapshot", 0) end
            return get_component_go:call(t)
        end)
        if not ok then
            PlayerDir.scan_reset()
            scan.retry_at = now + 0.1
            Profiler.count("scene_scan_stale_snapshot")
            Profiler.finish("scene_scan_batch", t_batch)
            return
        end
        if game_obj then
            local name = safe_object_name(game_obj)
            if name and name_looks_like_player(name) and player_has_body(game_obj) then
                scan.result = game_obj
                scan.result_time = os.clock()
                scan.result_valid = true
                scan.state = "IDLE"
                scan.transforms = nil
                scan.count = 0
                scan.index = 1
                Profiler.count("scene_scan_hits")
                Profiler.max_value("scene_scan_index_at_hit", i)
                Profiler.finish("scene_scan_batch", t_batch)
                return
            end
        end
        i = i + 1
    end
    scan.index = i
    Profiler.finish("scene_scan_batch", t_batch)

    if scan.index > scan.count then
        -- 扫完了：把「没找到」也记成有效结果（否则会一直重扫）
        scan.result = nil
        scan.result_time = os.clock()
        scan.result_valid = true
        scan.state = "IDLE"
        scan.transforms = nil
        scan.count = 0
        scan.index = 1
        Profiler.count("scene_scan_complete")
    end
end

-- 非阻塞版「扫一次」：返回已有结果；没有就返回 nil 并推进一步
function PlayerDir.scan_once()
    local scan = PlayerDir.scan
    local function current()
        if not scan.result_valid then return nil end
        if scan.result and not safe_object_alive(scan.result) then
            PlayerDir.scan_reset()
            return nil
        end
        local ttl = scan.result and scan.hit_ttl or scan.miss_ttl
        if (os.clock() - scan.result_time) < ttl then return scan.result or false end
        return nil
    end
    local value = current()
    if value ~= nil then return value or nil end
    PlayerDir.scan_tick()
    value = current()
    if value ~= nil then return value or nil end
    return nil
end

-- getPlayerIndex()：联机时区分本地玩家与其他玩家的**唯一可靠依据**
function PlayerDir.index_of(player)
    if not safe_object_alive(player) then return nil end
    local ok, idx = pcall(function() return SceneObject.call(player, "getPlayerIndex") end)
    if ok and type(idx) == "number" then return idx end
    return nil
end

function PlayerDir.to_game_object(player)
    if not safe_object_alive(player) then return nil end
    local ok, go = pcall(function() return SceneObject.call(player, "get_GameObject") end)
    if ok and go and safe_object_alive(go) then return go end
    return nil
end

-- PlayerManager:findMasterPlayer()（getMasterPlayer 作为兜底）
function PlayerDir.find_master()
    local pm = get_player_manager()
    if not pm then return nil end
    local ok, master = pcall(function() return pm:call("findMasterPlayer()") end)
    if not (ok and master and safe_object_alive(master)) then
        ok, master = pcall(function() return pm:call("getMasterPlayer") end)
        if not (ok and master and safe_object_alive(master)) then
            master = nil
        end
    end
    return master
end

-- 读 PlayerList 里的第 i 个玩家。
-- - 先走「托管对象标准调用」list:call("get_Item", i)（最稳，兼容性最好），
--   失败再退回预先缓存的 MethodDefinition 形式。
function PlayerDir.read_list_item(list, i)
    local ok, item = pcall(function() return list:call("get_Item", i) end)
    if ok and item then return item end
    if playerListGetItem then
        local ok2, item2 = pcall(playerListGetItem.call, playerListGetItem, list, i)
        if ok2 and item2 then return item2 end
    end
    return nil
end

function PlayerDir.rebuild()
    local started = Profiler.begin("player_directory_rebuild")
    PlayerDir.refresh_count = PlayerDir.refresh_count + 1
    PlayerDir.last_refresh = os.clock()

    local entries = {}
    local local_entry = nil

    local master = PlayerDir.find_master()
    local master_index = PlayerDir.index_of(master)
    local master_go = PlayerDir.to_game_object(master)

    local pm = get_player_manager()
    local list = nil
    if pm then
        local ok, field = pcall(function() return pm:get_field("PlayerList") end)
        if ok then list = field end
    end

    if list then
        local count = nil
        local ok_count, c = pcall(function() return list:call("get_Count") end)
        if ok_count and type(c) == "number" then count = c end
        local limit = 16
        if count and count > 0 and count - 1 < limit then limit = count - 1 end

        for i = 0, limit do
            local item = PlayerDir.read_list_item(list, i)
            if item and safe_object_alive(item) then
                local go = PlayerDir.to_game_object(item)
                if go then
                    local idx = PlayerDir.index_of(item)
                    local is_local = (master ~= nil and item == master)
                        or (master_index ~= nil and idx ~= nil and idx == master_index)
                        or (master_go ~= nil and go == master_go)
                    -- - 名字顺手缓存下来：面板每帧都要显示「检测到的玩家」，
                    --   不能每帧为每个玩家各做一次托管调用（旧写法就是那样）。
                    local entry = { player = item, obj = go, index = idx,
                                    is_local = is_local, name = safe_object_name(go) }
                    entries[#entries + 1] = entry
                    if is_local and local_entry == nil then local_entry = entry end
                end
            end
        end
    end

    -- 极端情况：findMasterPlayer 拿到了玩家，但它不在 PlayerList 里
    if local_entry == nil and master_go ~= nil then
        local_entry = { player = master, obj = master_go, index = master_index,
                        is_local = true, from_master = true,
                        name = safe_object_name(master_go) }
        table.insert(entries, 1, local_entry)
    end

    -- 最后兜底：PlayerManager 不可用或被清空（读图、菜单、存档预览界面）
    -- 此时才退回「场景扫描」（增量式、非阻塞，见 PlayerDir.scan_once），
    -- 而且只有在场景里**只有一个**候选时才认它是主角，以免联机时又抓成队友。
    if local_entry == nil then
        local scanned = PlayerDir.scan_once()
        if scanned then
            if #entries == 0 then
                local_entry = { player = nil, obj = scanned, index = nil, is_local = true,
                                from_scan = true, name = safe_object_name(scanned) }
                entries[#entries + 1] = local_entry
            elseif #entries == 1 then
                entries[1].is_local = true
                local_entry = entries[1]
            end
        elseif #entries == 1 then
            -- 只有一个人物在场（存档预览 / 单人读图）：它就是主角
            entries[1].is_local = true
            local_entry = entries[1]
        end
    end

    -- 其他玩家（复用同一张表，避免每 0.5 秒新建垃圾）
    local others = PlayerDir.others
    for i = #others, 1, -1 do others[i] = nil end
    for _, entry in ipairs(entries) do
        if not entry.is_local then others[#others + 1] = entry end
    end

    PlayerDir.entries = entries
    PlayerDir.local_entry = local_entry
    PlayerDir.local_index = local_entry and local_entry.index or master_index
    if local_entry and safe_object_alive(local_entry.obj) then
        PlayerDir.last_local_obj = local_entry.obj
        PlayerDir.last_local_time = os.clock()
    end
    PlayerDir.valid = true

    Profiler.count("player_directory_rebuilds")
    Profiler.count("player_directory_entries", #entries)
    Profiler.count("player_directory_others", #others)
    Profiler.finish("player_directory_rebuild", started)
end

-- 取（必要时重建）玩家目录
function PlayerDir.get()
    local now = os.clock()
    if not PlayerDir.valid
        or (now - PlayerDir.last_refresh) > PlayerDir.refresh_interval then
        PlayerDir.rebuild()
    elseif PlayerDir.local_entry ~= nil
        and not safe_object_alive(PlayerDir.local_entry.obj) then
        -- 本地玩家对象失效（换装重建 / 切场景）→ 立刻重建，不等节流
        PlayerDir.rebuild()
    elseif PlayerDir.local_entry == nil and #PlayerDir.entries == 0
        and PlayerDir.scan.result_valid and PlayerDir.scan.result ~= nil then
        -- - 场景扫描刚把人找出来（PlayerManager 完全没给出玩家的情况）：
        --   立刻重建一次，不要等到下一个节流周期，否则面板会白等半秒。
        --   注意条件里带了 #entries == 0：一旦目录里已经有候选就不会再进来，
        --   所以这里不会变成「每帧重建」。
        PlayerDir.rebuild()
    end
    return PlayerDir
end

-- 兼容旧代码：player_list 现在表示「除本地玩家以外的其他玩家」
local function refresh_player_list()
    PlayerDir.rebuild()
    player_list = PlayerDir.others
    return player_list
end

-- 诊断出口：面板与离线模拟测试都靠它读「这一拍认到了哪些玩家」
_G.__AVM_PLAYER_DIRECTORY = PlayerDir

-- ============================================================================
--  旧版 ImGui 面板：联机（多人）段落
-- ----------------------------------------------------------------------------
--  - 抽成函数是为了「在一处维护、在需要的位置调用」——
--    这一段在面板里要排在「语言」与「性能设置」**中间**。
--
--  - 面板必须永远显示**本地玩家**的配置。本地玩家由 PlayerDir 用
--    getPlayerIndex() 精确挑出（对象名 player00/01/02… 是按加入房间顺序
--    分配的，靠名字猜必然认错人）。这里把「认到了谁」直接列出来，方便一眼确认。
-- ============================================================================
local function draw_multiplayer_panel()
    if not imgui.tree_node(T("d2d_settings_multiplayer") .. "##avm_multiplayer") then
        return
    end
    local changed_multi, new_multi = imgui.checkbox(T("enable_multiplayer") .. "##mp_enable",
        global_config.enable_multiplayer ~= false)
    if changed_multi then
        global_config.enable_multiplayer = new_multi == true
        save_global_settings()
    end
    local changed_tick, new_tick = imgui.slider_int(T("multiplayer_players_per_tick") .. "##mp_tick",
        tonumber(global_config.multiplayer_players_per_tick) or 1, 0, 4)
    if changed_tick and new_tick then
        global_config.multiplayer_players_per_tick = new_tick
        save_global_settings()
    end
    local changed_scan, new_scan = imgui.slider_float(T("multiplayer_weapon_scan_interval") .. "##mp_scan",
        tonumber(global_config.multiplayer_weapon_scan_interval) or 2.0, 0.2, 10.0, "%.1f")
    if changed_scan and new_scan then
        global_config.multiplayer_weapon_scan_interval = new_scan
        save_global_settings()
    end
    if global_config.enable_multiplayer == false then
        imgui.text_colored(T("multiplayer_local_only"), 0xFF80C0FF)
    else
        imgui.text_colored(T("multiplayer_desc"), 0xFF909090)
    end
    imgui.separator()
    imgui.text_colored(T("players_title"), 0xFF80C0FF)
    local dir = PlayerDir.get()
    if #dir.entries == 0 then
        imgui.text_colored(T("player_none"), 0xFF8080FF)
        imgui.text_colored(T("player_none_hint"), 0xFF909090)
    else
        for _, entry in ipairs(dir.entries) do
            -- - 用目录建表时缓存好的名字：这里每帧都会执行，
            --   不能每帧为每个玩家各做一次托管调用。
            local name = entry.name or "?"
            local tag = entry.is_local and T("player_local") or T("player_other")
            imgui.text(string.format(T("player_line"), tag, name, tostring(entry.index or "?")))
        end
        local local_name = (dir.local_entry and dir.local_entry.name) or "?"
        imgui.text_colored(string.format(T("players_summary"), #dir.entries, local_name), 0xFF80FF80)
    end
    imgui.tree_pop()
end

-- 获取事件玩家（CG）
-- 特殊内嵌式 CG：使用 get_Count / get_Item；普通 CG：使用 ToArray
-- REFramework SystemArray 的下标从 0 开始，不能直接 ipairs（会漏首项，
-- 单元素栈会被读成空）。先用 get_elements() 取得从 1 开始的可遍历序列。
-- 当前 REF 返回的是 std::vector userdata，不能限定 type(elements)=="table"。
function PlayerDir.sequence(value)
    if value == nil then return EMPTY_PLAYER_LIST end
    local ok, elements = pcall(function() return value:get_elements() end)
    if ok and elements ~= nil then return elements end
    if type(value) == "table" then return value end
    return EMPTY_PLAYER_LIST
end
local get_event_players = nil
local function get_event_players_impl()
    local players = {}
    local eventManager = sdk.get_managed_singleton("snow.eventcut.EventManager")
    if not eventManager then return players end
    local loadHandlerStack = eventManager:call("get_LoadHandlerStack")
    if not loadHandlerStack then return players end
    for _, handler in ipairs(PlayerDir.sequence(loadHandlerStack)) do
        if handler then
            local uniqueEventManager = SceneObject.call(handler, "findUniqueEventManager")
            if uniqueEventManager then
                local eventPlayerList = SceneObject.call(uniqueEventManager, "get_EventPlayerList")
                if eventPlayerList then
                    -- 优先尝试 get_Count / get_Item（特殊内嵌式 CG）
                    local ok_count, count = pcall(function() return eventPlayerList:call("get_Count") end)
                    if ok_count and type(count) == "number" and count > 0 then
                        for i = 0, count - 1 do
                            local ok_player, eventPlayer = pcall(function() return eventPlayerList:call("get_Item", i) end)
                            if ok_player and eventPlayer then
                                local ok_go, go = pcall(function() return SceneObject.call(eventPlayer, "get_GameObject") end)
                                if ok_go and go then
                                    table.insert(players, go)
                                end
                            end
                        end
                    else
                        -- 回退到 ToArray（普通独立过场 CG）
                        local ok_arr, arr = pcall(function() return eventPlayerList:call("ToArray") end)
                        if ok_arr and arr then
                            for _, eventPlayer in ipairs(PlayerDir.sequence(arr)) do
                                if eventPlayer then
                                    local ok_go, go = pcall(function() return SceneObject.call(eventPlayer, "get_GameObject") end)
                                    if ok_go and go then
                                        table.insert(players, go)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return players
end
get_event_players = function()
    local t0 = Profiler.begin("get_event_players")
    local result = get_event_players_impl()
    Profiler.finish("get_event_players", t0)
    Profiler.count("get_event_players_calls")
    return result
end

-- 获取本地玩家（MasterPlayer）的 GameObject
-- 直接走玩家目录：目录里已经用 getPlayerIndex 精确挑出了本地玩家，
-- 不再有「按名字猜」的环节。
local get_master_player_object = nil
local function get_master_player_object_impl()
    local dir = PlayerDir.get()
    if dir.local_entry and safe_object_alive(dir.local_entry.obj) then
        return dir.local_entry.obj
    end
    -- 本地玩家短暂读不到（读图 / 菜单）：沿用最近一次确认过的对象，避免面板闪烁。
    -- 超过 PlayerDir.persist 秒还是拿不到就放弃（避免一直对着已销毁的对象调用）。
    local last = dir.last_local_obj
    if last and safe_object_alive(last)
        and (os.clock() - dir.last_local_time) <= PlayerDir.persist then
        return last
    end
    return nil
end
get_master_player_object = function()
    local t0 = Profiler.begin("get_master_player_object")
    local result = get_master_player_object_impl()
    Profiler.finish("get_master_player_object", t0)
    Profiler.count("get_master_player_object_calls")
    return result
end

-- 获取主角（本地玩家）的 GameObject
-- - 这里**只**认玩家目录给出的结果。旧实现会在拿不到 master 时退化成
--   「列表里第一个像玩家的对象」，联机时那往往是队友 —— 面板因此显示别人的配置。
--   现在连「场景扫描兜底」也统一交给玩家目录（它只在场景里只有一个候选时才接受扫描结果），
--   宁可不显示，也不显示错的。
local get_primary_player = nil
local function get_primary_player_impl()
    return get_master_player_object()
end
get_primary_player = function()
    local t0 = Profiler.begin("get_primary_player")
    local result = get_primary_player_impl()
    Profiler.finish("get_primary_player", t0)
    Profiler.count("get_primary_player_calls")
    return result
end

-- 获取主角 ID（防具模式返回 body 子物体名，武器模式返回主要攻击部件名）
-- - 性能要点：面板每帧都会问「当前 body_id 是什么」，而算一次要遍历一次子物体。
--   这里按「对象地址 + 模式」缓存 0.25 秒：面板、自动查找、应用逻辑共用同一份结果。
--   （缓存挂成 PlayerDir 的字段是为了省一个顶层局部变量槽位。）
local function get_primary_body_id()
    local primary = get_primary_player()
    if not primary then return nil end
    local cache = PlayerDir.primary_body_id
    local key = tostring(primary) .. (is_weapon_mode and "|w" or "|a")
    local now = os.clock()
    if cache.key == key and (now - cache.time) < cache.ttl then
        return cache.value
    end
    local value
    if is_weapon_mode then
        value = get_weapon_attack_part_name(primary)
    else
        -- - 走 body_id 的 TTL 缓存：面板每帧都会问，旧写法每次都遍历一次子物体
        value = PlayerDir.body_id_of(primary)
    end
    cache.key = key
    cache.value = value
    cache.time = now
    return value
end

-- 装备 / 模式 / 场景变化时作废主角 ID 缓存
local function invalidate_primary_body_id()
    local cache = PlayerDir.primary_body_id
    cache.key = nil
    cache.value = nil
    cache.time = 0
end

-- ========== 全局分组辅助函数 ==========
-- 获取包含指定材质的全局分组列表
local function get_material_global_groups(part_index, mat_name)
    if not mat_name then return {} end
    if not current_config.groups then return {} end
    local s_idx = tostring(part_index)
    local result = {}
    for g_name, g_data in pairs(current_config.groups) do
        if g_data.is_global and g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
            table.insert(result, g_name)
        end
    end
    return result
end

-- 检查材质是否被某个全局分组强制隐藏（根据当前激活的预设）
local function is_globally_hidden(part_index, mat_name)
    if current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global then
        return false
    end
    if not current_config.groups then return false end
    local s_idx = tostring(part_index)
    local body_id = get_primary_body_id()
    local saved = (body_id and active_group_presets[body_id]) or {}
    for g_name, g_data in pairs(current_config.groups) do
        if g_data.is_global and g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
            local pname = saved[g_name]
            if not pname or pname == "" then pname = g_data.default_preset end
            if pname and pname ~= "" and g_data.presets and g_data.presets[pname] then
                local def = g_data.presets[pname]
                if def and def[s_idx] and def[s_idx].materials and def[s_idx].materials[mat_name] == false then
                    return true
                end
            end
        end
    end
    return false
end

-- 仅合并全局分组的隐藏覆盖（只设置 false，不设置 true）
local function merge_global_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if p_data.materials then
            if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                if is_enabled == false then
                    overrides[p_idx].materials[mat_name] = false
                end
            end
        end
    end
    bump_overrides_version(body_id)
end

-- ========== 辅助函数 ==========
local function fix_transform_rules(rules)
    if not rules or type(rules) ~= "table" then return end
    for _, rule in ipairs(rules) do
        if not rule.targets or type(rule.targets) ~= "table" then
            rule.targets = {}
        end
    end
end

local function fix_parallel_settings(settings)
    if not settings or type(settings) ~= "table" then
        return {
            weapon = { enabled = true, priority = 1 },
            scroll = { enabled = false, priority = 2 },
            monster_hp = { enabled = false, priority = 3 },
            longsword = { enabled = false, priority = 4 },
            dual_blades = { enabled = false, priority = 5 },
            switch_axe = { enabled = false, priority = 6 },
            charge_axe = { enabled = false, priority = 7 },
            greatsword_level = { enabled = false, priority = 8 },
            hammer = { enabled = false, priority = 9 },
            bow = { enabled = false, priority = 10 }
        }
    end
    if settings.weapon == nil then settings.weapon = { enabled = true, priority = 1 } end
    if settings.scroll == nil then settings.scroll = { enabled = false, priority = 2 } end
    if settings.monster_hp == nil then settings.monster_hp = { enabled = false, priority = 3 } end
    if settings.longsword == nil then settings.longsword = { enabled = false, priority = 4 } end
    if settings.dual_blades == nil then settings.dual_blades = { enabled = false, priority = 5 } end
    if settings.switch_axe == nil then settings.switch_axe = { enabled = false, priority = 6 } end
    if settings.charge_axe == nil then settings.charge_axe = { enabled = false, priority = 7 } end
    if settings.greatsword_level == nil then settings.greatsword_level = { enabled = false, priority = 8 } end
    if settings.hammer == nil then settings.hammer = { enabled = false, priority = 9 } end
    if settings.bow == nil then settings.bow = { enabled = false, priority = 10 } end
    return settings
end

-- 更新预设列表（支持顺序）
local function update_preset_names_list()
    preset_names_list = {}
    local target_presets = nil
    local target_order = nil
    if current_group_name == "" then
        target_presets = current_config.presets
        target_order = current_config.preset_order
    else
        if current_config.groups and current_config.groups[current_group_name] then
            target_presets = current_config.groups[current_group_name].presets or {}
            target_order = current_config.groups[current_group_name].preset_order
        else
            target_presets = {}
        end
    end
    if target_presets then
        if target_order and #target_order > 0 then
            local added = {}
            for _, name in ipairs(target_order) do
                if target_presets[name] then
                    table.insert(preset_names_list, name)
                    added[name] = true
                end
            end
            for name, _ in pairs(target_presets) do
                if not added[name] then
                    table.insert(preset_names_list, name)
                end
            end
        else
            for name, _ in pairs(target_presets) do
                table.insert(preset_names_list, name)
            end
            table.sort(preset_names_list)
        end
    end
    -- 当前选中的预设（优先使用 active_group_presets 记录的预设）
    local current_body_id = get_primary_body_id()
    local active_preset_name = ""
    if current_body_id and active_group_presets[current_body_id] and active_group_presets[current_body_id][current_group_name] then
        active_preset_name = active_group_presets[current_body_id][current_group_name]
    end
    if active_preset_name == "" then
        if current_group_name == "" then
            active_preset_name = current_config.default_preset or ""
        else
            if current_config.groups and current_config.groups[current_group_name] then
                active_preset_name = current_config.groups[current_group_name].default_preset or ""
            end
        end
    end
    if active_preset_name ~= "" then
        local found = false
        for i, name in ipairs(preset_names_list) do
            if name == active_preset_name then selected_preset_index = i; found = true; break end
        end
        if not found then selected_preset_index = 1 end
    else
        selected_preset_index = 1
    end
    if #preset_names_list == 0 then selected_preset_index = 1
    elseif selected_preset_index > #preset_names_list then selected_preset_index = 1 end
end

-- 更新分组列表（支持顺序）
local function update_group_names_list()
    group_names_list = {}
    if current_config.groups then
        if current_config.group_order and #current_config.group_order > 0 then
            local added = {}
            for _, name in ipairs(current_config.group_order) do
                if current_config.groups[name] then
                    table.insert(group_names_list, name)
                    added[name] = true
                end
            end
            for name, _ in pairs(current_config.groups) do
                if not added[name] then
                    table.insert(group_names_list, name)
                end
            end
        else
            for name, _ in pairs(current_config.groups) do
                table.insert(group_names_list, name)
            end
            table.sort(group_names_list)
        end
    end
    if #group_names_list == 0 then selected_group_index = 1
    elseif selected_group_index > #group_names_list then selected_group_index = 1 end
end

-- Mesh 组件的真实查找（无缓存）。
-- 每次都要 type_mesh:get_runtime_type() + getComponent(...)，一次应用要跑 5 次，
-- 所以外面套一层 PlayerDir.mesh_of 的缓存。
get_mesh_component_recursive_uncached = function(game_obj)
    Profiler.count("get_mesh_component_uncached_calls")
    if not game_obj then return nil end
    if not safe_object_alive(game_obj) then return nil end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return nil end
    end
    local runtime_type = type_mesh:get_runtime_type()
    local mesh = SceneObject.call(game_obj, "getComponent(System.Type)", runtime_type)
    if mesh then return mesh end
    local transform = SceneObject.call(game_obj, "get_Transform")
    if transform then
        local child = SceneObject.call(transform, "get_Child")
        while child do
            local child_obj = SceneObject.call(child, "get_GameObject")
            if child_obj then
                mesh = SceneObject.call(child_obj, "getComponent(System.Type)", runtime_type)
                if mesh then return mesh end
            end
            child = SceneObject.call(child, "get_Next")
        end
    end
    return nil
end

-- 带缓存的对外接口（所有调用点都走这里）
local function get_mesh_component_recursive(game_obj)
    Profiler.count("get_mesh_component_calls")
    if game_obj == nil then return nil end
    return PlayerDir.mesh_of(game_obj)
end

-- ============================================================================
--  防具部件缓存（按角色地址）
-- ----------------------------------------------------------------------------
--  - 为什么提前到这里：apply_preset_to_character 每轮都要拿 5 个部件，
--    旧实现每个部件都重新遍历一次子物体（5 × 12 次托管调用）。
--    联机时要对 4 个玩家做同一件事，这一项会线性放大，所以必须缓存。
--
--  - 必须处理「换装后部件被重建」的情况，否则差分会在换装后静默失效：
--      part_cache[addr] = { [0..4] = 部件对象, sig = 签名, walked_at = 时间 }
--    * 签名 = 5 个部件对象地址拼接；签名变了说明模型换了 → 让上层重新应用一遍差分；
--    * 缓存里的部件一旦有失效对象，立刻重建；
--    * 部件不齐（模型还没加载好）时按 PlayerDir.parts_retry 限频重试，不每帧狂扫。
--
--  - 这几个函数挂在 PlayerDir 上（而不是新增顶层 local function）也是刻意的：
--    主 chunk 的局部变量槽位已经接近 Lua 上限 200，表字段不占槽位。
-- ============================================================================
local part_cache = {}   -- key: 角色地址, value: { [0..4]=对象, sig=字符串, walked_at=时间 }

function PlayerDir.parts_valid(entry)
    if not entry then return false, false end
    local complete = true
    for i = 0, 4 do
        local obj = entry[i]
        if obj == nil then
            complete = false
        elseif not safe_object_alive(obj) then
            return false, false -- 有部件已销毁 → 必须立刻丢弃，不能按缺件重试限频沿用
        end
    end
    return complete, true
end

function PlayerDir.walk_parts(character)
    -- 与旧的「一次性获取玩家所有防具部件」保持完全一致：
    --   * 递归遍历（部件不一定都在第一层）；
    --   * 同一编号只记第一个，但「先遇到 ch00（游戏原版）后来遇到非 ch00（MOD）」时替换，
    --     也就是优先使用 MOD 部件。
    local parts = {}
    local ok = pcall(function()
        local transform = SceneObject.call(character, "get_Transform")
        if not transform then return end
        local function traverse(node)
            local child = SceneObject.call(node, "get_Child")
            local guard = 0
            while child do
                guard = guard + 1
                if guard > 256 then break end
                local child_obj = SceneObject.call(child, "get_GameObject")
                if child_obj then
                    local name = safe_object_name(child_obj)
                    if name then
                        local target_index = nil
                        if string.find(name, "body") then target_index = 1
                        elseif string.find(name, "helm") then target_index = 0
                        elseif string.find(name, "arm") then target_index = 2
                        elseif string.find(name, "wst") then target_index = 3
                        elseif string.find(name, "leg") then target_index = 4
                        end
                        if target_index ~= nil then
                            if parts[target_index] then
                                local old_name = safe_object_name(parts[target_index])
                                local is_old_ch00 = old_name and string.find(old_name, "^ch00")
                                local is_new_ch00 = string.find(name, "^ch00")
                                if is_old_ch00 and not is_new_ch00 then
                                    parts[target_index] = child_obj
                                end
                            else
                                parts[target_index] = child_obj
                            end
                        end
                    end
                    traverse(child)
                end
                child = SceneObject.call(child, "get_Next")
            end
        end
        traverse(transform)
    end)
    if not ok then return nil end
    local sig_parts = {}
    for i = 0, 4 do
        sig_parts[#sig_parts + 1] = parts[i] and tostring(parts[i]) or "-"
    end
    parts.sig = table.concat(sig_parts, "|")
    parts.walked_at = os.clock()
    return parts
end

-- 取「某角色 5 个防具部件」的缓存表（缺失时重建）
function PlayerDir.parts(character)
    if not character then return nil end
    if not safe_object_alive(character) then return nil end
    local addr = tostring(character)
    local entry = part_cache[addr]
    local now = os.clock()
    if entry then
        local complete, alive = PlayerDir.parts_valid(entry)
        if complete then return entry end
        if not alive then
            part_cache[addr] = nil
            entry = nil
        end
        -- 不完整（模型还在生成，或该模型确实缺件）：限频重扫，不要每帧狂扫
        if entry and entry.walked_at and (now - entry.walked_at) < PlayerDir.parts_retry then
            return entry
        end
    end
    local parts = PlayerDir.walk_parts(character)
    if not parts then return entry end
    -- 签名变化（换装 / 模型重建）时打个标记，让应用层强制重刷一次差分
    if entry and entry.sig and entry.sig ~= parts.sig then
        parts.changed = true
    end
    part_cache[addr] = parts
    Profiler.count("parts_walk")
    return parts
end

local function get_character_part(character, part_index)
    Profiler.count("get_character_part_calls")
    local parts = PlayerDir.parts(character)
    if not parts then return nil end
    return parts[part_index]
end

-- 获取材质所属的非全局分组（独占）
local function get_material_group_owner(part_index, mat_name)
    if not mat_name then return nil end
    if not current_config or not current_config.groups then return nil end
    local s_idx = tostring(part_index)
    for g_name, g_data in pairs(current_config.groups) do
        if not g_data.is_global then
            if g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] then
                return g_name
            end
        end
    end
    return nil
end

-- 材质是否属于当前 UI 上下文（考虑全局分组）
local function is_material_in_current_context(part_index, mat_name)
    if current_group_name == "" then
        return get_material_group_owner(part_index, mat_name) == nil
    else
        local g_data = current_config.groups and current_config.groups[current_group_name]
        if g_data and g_data.is_global then
            local s_idx = tostring(part_index)
            return g_data.mask and g_data.mask[s_idx] and g_data.mask[s_idx][mat_name] == true
        else
            local owner = get_material_group_owner(part_index, mat_name)
            return owner == current_group_name
        end
    end
end

-- 比较两个 overrides 表是否相等（只比较材质开关，不比较 mesh_enabled）
local function is_overrides_equal(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for p_idx, p_data in pairs(a) do
        local other = b[p_idx]
        if not other then return false end
        if p_data.materials then
            if not other.materials then return false end
            for mat, val in pairs(p_data.materials) do
                if other.materials[mat] ~= val then return false end
            end
            for mat, val in pairs(other.materials) do
                if p_data.materials[mat] ~= val then return false end
            end
        elseif other.materials then
            return false
        end
    end
    for p_idx, p_data in pairs(b) do
        if not a[p_idx] then return false end
    end
    return true
end

-- ============================================================================
--  角色级「已应用」记账（v3.1.0 联机支持的关键）
-- ----------------------------------------------------------------------------
--  - 差分的「意图」（active_overrides）按 body_id（模型名）共享：
--    两个玩家穿同一套模型，本来就该看到同一份差分 —— 这部分不用改。
--  - 但「应用」必须按**角色**分别记账。v3.0.6 是按 body_id 记账的，于是联机时
--    第二个穿同款模型的玩家会被第一个玩家的版本号挡掉，永远拿不到差分。
--
--      char_applied[角色地址] = {
--          armor_body_id / armor_version,   -- 防具：已应用的 body_id 与版本号
--          weapon_id / weapon_version,      -- 武器：已应用的部件名与版本号
--          parts_sig                        -- 上次应用时的部件签名（用于检测换装）
--      }
--
--  - 每一处写入前先「读一次当前值」，只有真的不一样才写 —— 这是多人不掉帧的
--    另一半原因：N 个角色每轮只做 N×M 次读，写只在状态真的变了才发生。
--    （照搬荒野版本 v4.2.2 的做法，但在崛起上是按 body_id 共享意图 + 按角色记账。）
-- ============================================================================
--  - 同样写成一张表：主 chunk 的局部变量槽位接近 Lua 上限 200，表字段不占槽位。
-- ============================================================================
local Applied = { by_char = {}, parts_check_interval = 0.5,
                  -- 特殊CG期间按角色记录「上次应用时刻」（见 SPECIAL_CG_APPLY_INTERVAL 的说明）
                  cg_at = {}, cg_weapon_at = {} }

function Applied.get(character)
    local addr = tostring(character)
    local st = Applied.by_char[addr]
    if not st then
        st = {}
        Applied.by_char[addr] = st
    end
    return st
end

function Applied.clear()
    Applied.by_char = {}
    Applied.cg_at = {}
    Applied.cg_weapon_at = {}
end

-- 进入/离开过场时清空 CG 节流记录：新一场过场的角色应该立刻拿到差分，
-- 而不是被上一场的节流记录挡住。
function Applied.reset_cg()
    Applied.cg_at = {}
    Applied.cg_weapon_at = {}
end

-- 某个 body_id 的意图变了：所有用这个模型的角色下一轮都要重新应用
function Applied.invalidate_body(body_id)
    if not body_id then return end
    bump_overrides_version(body_id)
    for _, st in pairs(Applied.by_char) do
        if st.armor_body_id == body_id then st.armor_version = nil end
        if st.weapon_id == body_id then st.weapon_version = nil end
    end
end

-- 角色部件被重建（换装 / 模型重建）时，本角色的「已应用」记账必须作废，
-- 否则差分会在换装后静默失效。
-- 返回 true 表示「真的换装了」（调用方据此放弃这一拍的应用，等下一拍用新的 body_id）。
--
-- - v3.1.2 修：**首次见到某个角色**时不能算「换装」。
--   旧实现里 st.parts_sig 从 nil 变成真实签名也会判定为变化 → 调用方直接 return，
--   于是每个新角色（尤其是过场里刚登场的事件主角）都要多等一整轮才拿到差分。
--   首次见面时并不存在「旧 body_id 套到新部件上」的风险，所以直接放行。
function Applied.sync_parts(character, st)
    if not st then return false end
    local parts = PlayerDir.parts(character)
    if not parts then return false end
    if st.parts_sig ~= parts.sig then
        local had_sig = st.parts_sig ~= nil
        st.parts_sig = parts.sig
        st.armor_version = nil
        st.weapon_version = nil
        if had_sig then
            -- 真的换装：body_id 与 mesh 缓存都可能已经过期，一起作废
            PlayerDir.invalidate_body_id(character)
            PlayerDir.mesh.by_obj = {}
            return true
        end
    end
    return false
end

-- ============================================================================
--  应用预设到角色（角色级版本号缓存 + 先读后写）
-- ============================================================================
local apply_preset_to_character = nil
local function apply_preset_to_character_impl(character, preset_data, ignore_context, known_body_id)
    Profiler.count("apply_character_calls")
    if not character or not preset_data then return end
    if not safe_object_alive(character) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end

    -- 特殊CG期间按「角色 + 时间」节流（见 SPECIAL_CG_APPLY_INTERVAL 的说明）
    if g_is_special_cg then
        local addr = tostring(character)
        local now = os.clock()
        local last = Applied.cg_at[addr]
        if last and (now - last) < SPECIAL_CG_APPLY_INTERVAL then return end
        Applied.cg_at[addr] = now
    end

    -- 获取当前 body_id
    -- known_body_id：调用方（帧循环）刚刚已经算过一次，直接复用即可，
    -- 避免同一次逻辑里对玩家子物体做两遍遍历。
    -- - 兜底这里也走 TTL 缓存，避免内部再遍历一次子物体。
    local body_id = known_body_id or PlayerDir.body_id_of(character)
    if not body_id then return end

    -- 获取当前应该应用的意图值（active_overrides）
    local current_intent = active_overrides[body_id]
    if not current_intent then
        Profiler.count("apply_character_skip_no_intent")
        return
    end

    -- ===== 角色级版本号检查（- 联机的关键：记账按角色，不按模型）=====
    local st = Applied.get(character)
    local current_version = overrides_version[body_id] or 0
    local parts_changed = false
    if not g_is_special_cg and current_version ~= 0
        and st.armor_body_id == body_id and st.armor_version == current_version then
        -- - 快路径：版本号一致时先不碰任何托管对象。
        --   部件签名只用来发现「换装 / 模型重建」，没必要每个处理周期都复核一次；
        --   按 Applied.parts_check_interval 限频（默认 0.5 秒）即可。
        --   多人时这一条把「每轮每人 5 次存活检查」直接省掉。
        local now = os.clock()
        if (now - (st.parts_checked_at or 0)) < Applied.parts_check_interval then
            Profiler.count("apply_character_skip_version")
            return
        end
        st.parts_checked_at = now
        parts_changed = Applied.sync_parts(character, st)
        if not parts_changed
            and st.armor_body_id == body_id and st.armor_version == current_version then
            Profiler.count("apply_character_skip_version")
            return
        end
    else
        parts_changed = Applied.sync_parts(character, st)
    end
    if parts_changed then
        -- 模型刚换：这一拍不要拿旧 body_id 的意图往新部件上套，等下一拍用新的 body_id 处理
        Profiler.count("apply_character_skip_parts_changed")
        return
    end
    st.armor_body_id = body_id
    st.armor_version = current_version
    st.parts_checked_at = os.clock()

    Profiler.count("apply_character_applied")
    local parts = PlayerDir.parts(character)
    for i = 0, 4 do
        local part_obj = parts and parts[i] or nil
        if part_obj and safe_object_alive(part_obj) then
            local part_data = preset_data[tostring(i)]
            if part_data then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    TransformManager.capture_mesh(body_id, tostring(i), mesh_component, part_data, SceneObject.call)
                    if part_data.mesh_enabled ~= nil then
                        local ok_cur, cur_en = pcall(function() return SceneObject.call(mesh_component, "get_Enabled") end)
                        if not ok_cur or cur_en ~= part_data.mesh_enabled then
                            SceneObject.call(mesh_component, "set_Enabled", part_data.mesh_enabled)
                        end
                    end
                    if part_data.materials then
                        local mat_count = SceneObject.call(mesh_component, "get_MaterialNum") or 0
                        for j = 0, mat_count - 1 do
                            local mat_name = SceneObject.call(mesh_component, "getMaterialName", j)
                            if mat_name and (ignore_context or is_material_in_current_context(i, mat_name)) then
                                local mat_enabled = part_data.materials[mat_name]
                                if mat_enabled ~= nil then
                                    -- 全局分组的隐藏永远优先
                                    local want = mat_enabled
                                    if want == true and is_globally_hidden(i, mat_name) then
                                        want = false
                                    end
                                    local ok_cur, cur = pcall(function()
                                        return SceneObject.call(mesh_component, "getMaterialsEnable", j)
                                    end)
                                    if not ok_cur or cur ~= want then
                                        SceneObject.call(mesh_component, "setMaterialsEnable", j, want)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
apply_preset_to_character = function(character, preset_data, ignore_context, known_body_id)
    local t0 = Profiler.begin("apply_character")
    apply_preset_to_character_impl(character, preset_data, ignore_context, known_body_id)
    Profiler.finish("apply_character", t0)
end

-- ============================================================================
-- 应用预设到武器（角色级版本号缓存 + 先读后写）
-- character：目标角色，可选。旧调用点不带它时回退到主角。
-- ============================================================================
local apply_preset_to_weapon = nil
local function apply_preset_to_weapon_impl(weapon_parts, preset_data, ignore_context, body_id, character)
    Profiler.count("apply_weapon_calls")
    if not weapon_parts or not preset_data then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return end
    end

    -- 使用传入的 body_id，不再调用 get_primary_body_id
    if not body_id then return end

    -- 特殊CG期间按「角色 + 时间」节流（武器单独记一份，不再吃防具的额度）
    if g_is_special_cg then
        local addr = character and tostring(character) or "__primary__"
        local now = os.clock()
        local last = Applied.cg_weapon_at[addr]
        if last and (now - last) < SPECIAL_CG_APPLY_INTERVAL then return end
        Applied.cg_weapon_at[addr] = now
    end

    local current_intent = active_overrides[body_id]
    if not current_intent then
        Profiler.count("apply_weapon_skip_no_intent")
        return
    end

    -- 角色级记账（旧调用点不传 character 时，按主角记账，语义与原来一致）
    local target = character
    if not (target and safe_object_alive(target)) then
        target = get_primary_player()
    end
    local st = nil
    if target then
        st = Applied.get(target)
        if Applied.sync_parts(target, st) then
            -- 模型刚换：等下一拍用新的武器/防具标识处理
            Profiler.count("apply_weapon_skip_parts_changed")
            return
        end
    end

    local current_version = overrides_version[body_id] or 0
    if not g_is_special_cg and st and current_version ~= 0
        and st.weapon_id == body_id and st.weapon_version == current_version then
        Profiler.count("apply_weapon_skip_version")
        return
    end
    if st then
        st.weapon_id = body_id
        st.weapon_version = current_version
    end

    Profiler.count("apply_weapon_applied")
    for i, part_obj in ipairs(weapon_parts) do
        if part_obj and safe_object_alive(part_obj) then
            local part_data = preset_data[tostring(i - 1)]
            if part_data then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    TransformManager.capture_mesh(body_id, tostring(i - 1), mesh_component, part_data, SceneObject.call)
                    if part_data.mesh_enabled ~= nil then
                        local ok_cur, cur_en = pcall(function() return SceneObject.call(mesh_component, "get_Enabled") end)
                        if not ok_cur or cur_en ~= part_data.mesh_enabled then
                            SceneObject.call(mesh_component, "set_Enabled", part_data.mesh_enabled)
                        end
                    end
                    if part_data.materials then
                        local mat_count = SceneObject.call(mesh_component, "get_MaterialNum") or 0
                        for j = 0, mat_count - 1 do
                            local mat_name = SceneObject.call(mesh_component, "getMaterialName", j)
                            if mat_name and (ignore_context or is_material_in_current_context(i - 1, mat_name)) then
                                local mat_enabled = part_data.materials[mat_name]
                                if mat_enabled ~= nil then
                                    local ok_cur, cur = pcall(function()
                                        return SceneObject.call(mesh_component, "getMaterialsEnable", j)
                                    end)
                                    if not ok_cur or cur ~= mat_enabled then
                                        SceneObject.call(mesh_component, "setMaterialsEnable", j, mat_enabled)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
apply_preset_to_weapon = function(weapon_parts, preset_data, ignore_context, body_id, character)
    local t0 = Profiler.begin("apply_weapon")
    apply_preset_to_weapon_impl(weapon_parts, preset_data, ignore_context, body_id, character)
    Profiler.finish("apply_weapon", t0)
end

-- 创建分组（支持 is_global）
local function create_new_group(group_name, body_id, is_global)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    local has_selection = false
    for _, v in pairs(pending_material_selections) do
        if next(v) then has_selection = true; break end
    end
    if not has_selection then return false end
    if not current_config.groups then current_config.groups = {} end
    if current_config.groups[group_name] then return false end
    local new_group = {
        mask = deep_copy_table(pending_material_selections),
        presets = {},
        is_global = is_global == true
    }
    if not new_group.is_global then
        if current_config.presets then
            for _, preset_data in pairs(current_config.presets) do
                for part_idx_str, mats in pairs(new_group.mask) do
                    if preset_data[part_idx_str] and preset_data[part_idx_str].materials then
                        for m_name, _ in pairs(mats) do
                            preset_data[part_idx_str].materials[m_name] = nil
                        end
                    end
                end
            end
        end
    end
    current_config.groups[group_name] = new_group
    if not current_config.group_order then current_config.group_order = {} end
    table.insert(current_config.group_order, group_name)
    pending_material_selections = {}
    is_selection_mode = false
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

-- 删除分组
local function delete_group(group_name, body_id)
    if not group_name or group_name == "" then return false end
    if not body_id then return false end
    if not current_config.groups or not current_config.groups[group_name] then return false end
    current_config.groups[group_name] = nil
    if current_config.group_order then
        for i = #current_config.group_order, 1, -1 do
            if current_config.group_order[i] == group_name then
                table.remove(current_config.group_order, i)
                break
            end
        end
    end
    if current_group_name == group_name then
        current_group_name = ""
        selected_group_index = 1
        update_preset_names_list()
    end
    update_group_names_list()
    save_current_config_to_file(body_id)
    return true
end

local function get_config_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/" .. body_id .. ".json"
end

-- ========== 预设备份与恢复辅助函数 ==========
local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k, v in pairs(b) do
        if not deep_equal(v, a[k]) then return false end
    end
    return true
end

local function get_backup_path(body_id)
    if not body_id then return nil end
    return "ArmorVariantManager/backup/" .. body_id .. ".json"
end

-- 从备份恢复配置
-- - 前置声明：下面三个函数在本文件里声明得更靠后。若不前置声明，
--   restore_config_from_backup 里的调用会被编译成**全局变量**（值为 nil），
--   运行时必然报 `attempt to call a nil value (global 'load_config_data')` ——
--   面板上的「恢复我的修改」按钮因此一直是坏的（v3.0.5 的性能报告里记录过这个既有 bug）。
--   这里补上前置声明，后面那三处只做赋值、不再写 local。
local load_config_data, apply_all_defaults, apply_preset

local function restore_config_from_backup(body_id)
    if not body_id then return false end
    local path = get_config_path(body_id)
    local backup_path = get_backup_path(body_id)
    if not backup_path then return false end
    
    local backup_data = json.load_file(backup_path)
    if not backup_data then return false end
    
    json.dump_file(path, backup_data)
    
    loaded_configs[body_id] = nil
    active_overrides[body_id] = nil
    config_restored[body_id] = nil
    config_restore_handled[body_id] = nil
    -- 清除渲染缓存，强制所有角色下一帧重新应用这个模型
    Applied.invalidate_body(body_id)
    
    local data = load_config_data(body_id)
    if data then
        for k, v in pairs(data) do
            current_config[k] = deep_copy_table(v)
        end
        update_group_names_list()
        update_preset_names_list()
        apply_all_defaults(body_id)
        
        local current_preset_name = preset_names_list[selected_preset_index]
        if current_preset_name then
            apply_preset(current_preset_name)
        end
        
        local primary = get_primary_player()
        if primary then
            if is_weapon_mode then
                local weapon_parts = Utils.get_current_weapon_parts(primary)
                if weapon_parts then
                    apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                end
            else
                apply_preset_to_character(primary, active_overrides[body_id], true)
            end
        end
        return true
    end
    return false
end

-- 保存配置到文件（同时写备份）
local function save_current_config_to_file(body_id)
    if not body_id then return end
    loaded_configs[body_id] = current_config
    local path = get_config_path(body_id)
    json.dump_file(path, current_config)
    
    local backup_path = get_backup_path(body_id)
    if backup_path then
        json.dump_file(backup_path, current_config)
    end
    
    config_restored[body_id] = nil
    config_restore_handled[body_id] = nil
    -- 保存后强制下一帧重绘
    Applied.invalidate_body(body_id)
    
    -- 清除 active_overrides 缓存，强制下一帧重新合并所有默认预设
    if active_overrides[body_id] then
        active_overrides[body_id] = nil
        overrides_version[body_id] = nil
    end
    -- 清除 active_group_presets 缓存，确保下一帧 apply_all_defaults 使用配置中的默认预设，
    -- 避免变身规则之前设置的全局分组预设残留导致状态不一致
    active_group_presets[body_id] = nil
    
    -- 清除状态机缓存，强制下一帧重新应用最新的预设内容
    if TransformManager.clear_cache then
        TransformManager.clear_cache(nil,nil,true) -- 保留稀疏预设写入前的原值，保存规则也能回退
    end

    -- 用户可能在面板里刚把「怪物血量」条件开关改掉，这里重新评估钩子门控
    refresh_monster_hp_gate()
end

-- 加载配置数据（带备份比对）
load_config_data = nil
local function load_config_data_impl(body_id)
    if not body_id then return nil end
    if loaded_configs[body_id] then
        Profiler.count("load_config_data_cache_hit")
        return loaded_configs[body_id]
    end
    local path = get_config_path(body_id)
    local loaded_data = json.load_file(path)
    
    local backup_path = get_backup_path(body_id)
    local backup_data = backup_path and json.load_file(backup_path)
    if backup_data and loaded_data then
        -- 重新读取原始主配置（未补全）用于比较
        local raw_main = json.load_file(path)
        if raw_main then
            local same = deep_equal(raw_main, backup_data)
            if not same then
                config_restored[body_id] = true
            else
                config_restored[body_id] = nil
            end
        else
            config_restored[body_id] = nil
        end
    else
        config_restored[body_id] = nil
    end
    
    if loaded_data then
        -- 以下为原有的补全逻辑（确保所有字段存在）
        if not loaded_data.presets then loaded_data.presets = {} end
        if not loaded_data.default_preset then loaded_data.default_preset = "" end
        if not loaded_data.groups then loaded_data.groups = {} end
        if not loaded_data.group_order then loaded_data.group_order = {} end
        if not loaded_data.preset_order then loaded_data.preset_order = {} end

        -- === 为老版本预设自动生成 preset_order（按字母排序） ===
        if loaded_data.presets and next(loaded_data.presets) then
            if not loaded_data.preset_order or #loaded_data.preset_order == 0 then
                loaded_data.preset_order = {}
                for name, _ in pairs(loaded_data.presets) do
                    table.insert(loaded_data.preset_order, name)
                end
                table.sort(loaded_data.preset_order)
            end
        end

        -- 补充分组的 is_global 和预设顺序
        for _, g_data in pairs(loaded_data.groups) do
            if g_data.is_global == nil then g_data.is_global = false end
            if not g_data.preset_order then
                g_data.preset_order = {}
            end
            -- 为分组预设自动生成顺序
            if g_data.presets and next(g_data.presets) and #g_data.preset_order == 0 then
                for name, _ in pairs(g_data.presets) do
                    table.insert(g_data.preset_order, name)
                end
                table.sort(g_data.preset_order)
            end
        end

        if loaded_data.enable_transform == nil then loaded_data.enable_transform = false end
        if loaded_data.transform_type == nil then loaded_data.transform_type = "weapon" end
        if loaded_data.is_parallel == nil then loaded_data.is_parallel = false end
        loaded_data.parallel_settings = fix_parallel_settings(loaded_data.parallel_settings)
        if loaded_data.weapon_transform_rules == nil then
            loaded_data.weapon_transform_rules = {
                { state = "sheathed", targets = {} },
                { state = "drawn", targets = {} }
            }
        end
        if loaded_data.scroll_transform_rules == nil then
            loaded_data.scroll_transform_rules = {
                { state = "red", targets = {} },
                { state = "blue", targets = {} }
            }
        end
        if loaded_data.longsword_transform_rules == nil then
            loaded_data.longsword_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} },
                { level = 3, targets = {} }
            }
        end
        if loaded_data.dual_blades_transform_rules == nil then
            loaded_data.dual_blades_transform_rules = {
                { state = 0, targets = {} },
                { state = 1, targets = {} },
                { state = 2, targets = {} }
            }
        end
        if loaded_data.switch_axe_transform_rules == nil then
            loaded_data.switch_axe_transform_rules = {
                { state = 0, targets = {} },
                { state = 1, targets = {} },
                { state = 2, targets = {} }
            }
        end
        if loaded_data.charge_axe_transform_rules == nil then
            loaded_data.charge_axe_transform_rules = {
                { state = 0, targets = {} },
                { state = 1, targets = {} },
                { state = 2, targets = {} },
                { state = 3, targets = {} },
                { state = 4, targets = {} },
                { state = 5, targets = {} }
            }
        end
        if loaded_data.greatsword_level_transform_rules == nil then
            loaded_data.greatsword_level_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} },
                { level = 3, targets = {} }
            }
        end
        if loaded_data.hammer_transform_rules == nil then
            loaded_data.hammer_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} }
            }
        end
        if loaded_data.bow_transform_rules == nil then
            loaded_data.bow_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} },
                { level = 3, targets = {} }
            }
        end
        if loaded_data.monster_hp_transform_rules == nil then
            loaded_data.monster_hp_transform_rules = {}
        end
        fix_transform_rules(loaded_data.weapon_transform_rules)
        fix_transform_rules(loaded_data.scroll_transform_rules)
        fix_transform_rules(loaded_data.longsword_transform_rules)
        fix_transform_rules(loaded_data.dual_blades_transform_rules)
        fix_transform_rules(loaded_data.switch_axe_transform_rules)
        fix_transform_rules(loaded_data.charge_axe_transform_rules)
        fix_transform_rules(loaded_data.greatsword_level_transform_rules)
        fix_transform_rules(loaded_data.hammer_transform_rules)
        fix_transform_rules(loaded_data.bow_transform_rules)
        fix_transform_rules(loaded_data.monster_hp_transform_rules)
        loaded_configs[body_id] = loaded_data
        -- 配置从磁盘加载进来后，重新评估「是否需要怪物血量跟踪」
        refresh_monster_hp_gate()
        return loaded_data
    end
    return nil
end
load_config_data = function(body_id)
    local t0 = Profiler.begin("load_config_data")
    local result = load_config_data_impl(body_id)
    Profiler.finish("load_config_data", t0)
    Profiler.count("load_config_data_calls")
    return result
end

-- ============================================================================
-- 合并预设到 overrides（同时递增版本号）
-- ============================================================================
local function merge_preset_into_overrides(body_id, preset_data)
    if not body_id or not preset_data then return end
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    local overrides = active_overrides[body_id]
    for p_idx, p_data in pairs(preset_data) do
        if not overrides[p_idx] then overrides[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            overrides[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not overrides[p_idx].materials then overrides[p_idx].materials = {} end
            for mat_name, is_enabled in pairs(p_data.materials) do
                overrides[p_idx].materials[mat_name] = is_enabled
            end
        end
    end
    bump_overrides_version(body_id)
end

-- ============================================================================
-- 初始化默认预设（按正确顺序：主列表 -> 普通分组 -> 全局分组）
-- 为全局分组增加 Fallback：若 default_preset 缺失，则自动选取该分组的第一个预设
-- ============================================================================
apply_all_defaults = nil
local function apply_all_defaults_impl(body_id)
    local config = load_config_data(body_id)
    if not config then return end
    active_overrides[body_id] = {}
    bump_overrides_version(body_id)
    active_group_presets[body_id] = {}
    -- 清除渲染缓存，强制下一帧重新应用（apply_all_defaults 上面已经 bump 过版本号）
    Applied.invalidate_body(body_id)

    -- 1. 主列表默认预设
    if config.default_preset and config.default_preset ~= "" and config.presets then
        local def = config.presets[config.default_preset]
        if def then
            merge_preset_into_overrides(body_id, def)
            if not active_group_presets[body_id][""] or active_group_presets[body_id][""] == "" then
                active_group_presets[body_id][""] = config.default_preset
            end
        end
    end

    -- 2. 非全局分组默认预设
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if not g_data.is_global then
                if g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                    local g_def = g_data.presets[g_data.default_preset]
                    if g_def then
                        merge_preset_into_overrides(body_id, g_def)
                        if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                            active_group_presets[body_id][g_name] = g_data.default_preset
                        end
                    end
                end
            end
        end
    end

    active_overrides[body_id] = TransformManager.set_model_base(body_id, active_overrides[body_id], active_group_presets[body_id])

    -- 3. 全局分组默认预设（仅隐藏覆盖），增加 Fallback 机制
    if config.groups then
        for g_name, g_data in pairs(config.groups) do
            if g_data.is_global then
                local default_preset = g_data.default_preset
                -- 如果 default_preset 无效，自动选取该分组的第一个预设
                if not default_preset or default_preset == "" then
                    if g_data.presets and next(g_data.presets) then
                        -- 优先按 preset_order 排序，取第一个
                        if g_data.preset_order and #g_data.preset_order > 0 then
                            for _, pname in ipairs(g_data.preset_order) do
                                if g_data.presets[pname] then
                                    default_preset = pname
                                    break
                                end
                            end
                        end
                        -- 如果 preset_order 无效，按遍历顺序取第一个
                        if not default_preset then
                            for pname, _ in pairs(g_data.presets) do
                                default_preset = pname
                                break
                            end
                        end
                    end
                end
                -- 应用选定的默认预设
                if default_preset and default_preset ~= "" and g_data.presets and g_data.presets[default_preset] then
                    local g_def = g_data.presets[default_preset]
                    merge_global_preset_into_overrides(body_id, g_def)  -- 内部会递增版本号
                    if not active_group_presets[body_id][g_name] or active_group_presets[body_id][g_name] == "" then
                        active_group_presets[body_id][g_name] = default_preset
                        TransformManager.update_base_preset(body_id, config, g_name, default_preset, function(a) return a end)
                    end
                end
            end
        end
    end
end
apply_all_defaults = function(body_id)
    local t0 = Profiler.begin("apply_all_defaults")
    apply_all_defaults_impl(body_id)
    Profiler.finish("apply_all_defaults", t0)
    Profiler.count("apply_all_defaults_calls")
end

local function get_current_preset_data(preset_name)
    if current_group_name == "" then
        if current_config and current_config.presets then
            return current_config.presets[preset_name]
        end
    else
        if current_config and current_config.groups and current_config.groups[current_group_name] then
            return current_config.groups[current_group_name].presets[preset_name]
        end
    end
    return nil
end

-- 应用预设（支持全局分组覆盖重建）
-- （apply_preset 已在 restore_config_from_backup 之前前置声明，所以这里只赋值）
apply_preset = function(preset_name)
    local preset_data = get_current_preset_data(preset_name)
    if not preset_data then return end
    local current_id = get_primary_body_id()
    if current_id then
        if not active_group_presets[current_id] then active_group_presets[current_id] = {} end
        active_group_presets[current_id][current_group_name] = preset_name
        TransformManager.update_base_preset(current_id, current_config, current_group_name, preset_name, merge_overrides)
        local is_current_global = (current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name]
            and current_config.groups[current_group_name].is_global)
        if is_current_global then
            -- 全局分组：重建整个 overrides
            active_overrides[current_id] = {}
            bump_overrides_version(current_id)
            local saved = active_group_presets[current_id] or {}
            -- 主列表
            local main_preset_name = saved[""]
            if main_preset_name and main_preset_name ~= "" and current_config.presets and current_config.presets[main_preset_name] then
                merge_preset_into_overrides(current_id, current_config.presets[main_preset_name])
            elseif current_config.default_preset and current_config.default_preset ~= "" and current_config.presets then
                local def = current_config.presets[current_config.default_preset]
                if def then merge_preset_into_overrides(current_id, def) end
            end
            -- 普通分组
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if not g_data.is_global then
                        local gp_name = saved[g_name]
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_preset_into_overrides(current_id, g_data.presets[gp_name])
                        elseif g_data.default_preset and g_data.default_preset ~= "" and g_data.presets then
                            local g_def = g_data.presets[g_data.default_preset]
                            if g_def then merge_preset_into_overrides(current_id, g_def) end
                        end
                    end
                end
            end
            -- 全局分组（当前分组使用新预设，其他使用已保存或默认）
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global then
                        local gp_name = (g_name == current_group_name) and preset_name or saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        else
            -- 普通分组或主列表：直接合并，再叠加全局分组的隐藏覆盖
            merge_preset_into_overrides(current_id, preset_data)
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global and g_data.presets then
                        local saved = active_group_presets[current_id] or {}
                        local gp_name = saved[g_name]
                        if not gp_name or gp_name == "" then gp_name = g_data.default_preset end
                        if gp_name and gp_name ~= "" and g_data.presets[gp_name] then
                            merge_global_preset_into_overrides(current_id, g_data.presets[gp_name])
                        end
                    end
                end
            end
        end
        -- 清除渲染缓存，强制下一帧重新应用
        Applied.invalidate_body(current_id)
    end
    local primary = get_primary_player()
    if not primary then return end
    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if weapon_parts then
            apply_preset_to_weapon(weapon_parts, active_overrides[current_id], true, current_id)
        end
    else
        apply_preset_to_character(primary, active_overrides[current_id], true)
    end
end


-- ============================================================================
-- 保存预设（全局分组仅存储隐藏材质 false，普通分组存储全部状态）
-- ============================================================================
local function save_preset(preset_name, body_id)
    if not body_id then body_id = get_primary_body_id() end
    if not body_id then return false end
    local primary = get_primary_player()
    if not primary then return false end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then return false end
    end
    local new_preset_data = {}
    
    -- 判断当前上下文是否为全局分组
    local is_global_context = (current_group_name ~= "" and current_config.groups
        and current_config.groups[current_group_name]
        and current_config.groups[current_group_name].is_global)

    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if weapon_parts then
            for i, part_obj in ipairs(weapon_parts) do
                if part_obj then
                    local mesh_component = get_mesh_component_recursive(part_obj)
                    if mesh_component then
                        local part_data = {
                            mesh_enabled = SceneObject.call(mesh_component, "get_Enabled"),
                            materials = {}
                        }
                        local mat_count = SceneObject.call(mesh_component, "get_MaterialNum")
                        if mat_count then
                            for j = 0, mat_count - 1 do
                                local mat_name = SceneObject.call(mesh_component, "getMaterialName", j)
                                if is_material_in_current_context(i - 1, mat_name) then
                                    local is_mat_enabled = SceneObject.call(mesh_component, "getMaterialsEnable", j)
                                    -- 全局分组：仅存储 false（隐藏），跳过 true
                                    if is_global_context then
                                        if is_mat_enabled == false then
                                            part_data.materials[mat_name] = false
                                        end
                                    else
                                        part_data.materials[mat_name] = is_mat_enabled
                                    end
                                end
                            end
                        end
                        -- 只有存储了材质数据（或主列表/普通分组才保存）
                        if next(part_data.materials) or current_group_name == "" or not is_global_context then
                            new_preset_data[tostring(i - 1)] = part_data
                        end
                    end
                end
            end
        end
    else
        for i = 0, 4 do
            local part_obj = get_character_part(primary, i)
            if part_obj then
                local mesh_component = get_mesh_component_recursive(part_obj)
                if mesh_component then
                    local part_data = {
                        mesh_enabled = SceneObject.call(mesh_component, "get_Enabled"),
                        materials = {}
                    }
                    local mat_count = SceneObject.call(mesh_component, "get_MaterialNum")
                    if mat_count then
                        for j = 0, mat_count - 1 do
                            local mat_name = SceneObject.call(mesh_component, "getMaterialName", j)
                            if is_material_in_current_context(i, mat_name) then
                                local is_mat_enabled = SceneObject.call(mesh_component, "getMaterialsEnable", j)
                                -- 全局分组：仅存储 false（隐藏），跳过 true
                                if is_global_context then
                                    if is_mat_enabled == false then
                                        part_data.materials[mat_name] = false
                                    end
                                else
                                    part_data.materials[mat_name] = is_mat_enabled
                                end
                            end
                        end
                    end
                    -- 只有存储了材质数据（或主列表/普通分组才保存）
                    if next(part_data.materials) or current_group_name == "" or not is_global_context then
                        new_preset_data[tostring(i)] = part_data
                    end
                end
            end
        end
    end

    -- 如果全局分组且没有任何材质需要隐藏，仍需保存一个空表以标记预设存在
    if is_global_context and not next(new_preset_data) then
        -- 至少保存一个空结构，表示这是一个有效的预设（无隐藏项，即全部显示）
        new_preset_data = { _empty = true }  -- 用特殊标记表示空预设
    end

    if current_group_name == "" then
        if not current_config.presets then current_config.presets = {} end
        if not current_config.presets[preset_name] then
            if not current_config.preset_order then current_config.preset_order = {} end
            table.insert(current_config.preset_order, preset_name)
        end
        current_config.presets[preset_name] = new_preset_data
    else
        if not current_config.groups then current_config.groups = {} end
        if not current_config.groups[current_group_name] then
            current_config.groups[current_group_name] = { presets = {}, mask = {} }
        end
        if not current_config.groups[current_group_name].presets then
            current_config.groups[current_group_name].presets = {}
        end
        if not current_config.groups[current_group_name].presets[preset_name] then
            if not current_config.groups[current_group_name].preset_order then
                current_config.groups[current_group_name].preset_order = {}
            end
            table.insert(current_config.groups[current_group_name].preset_order, preset_name)
        end
        current_config.groups[current_group_name].presets[preset_name] = new_preset_data
    end
    update_preset_names_list()
    save_current_config_to_file(body_id)
    return true
end

-- ================== 自动查找预设（统一实现，见 PresetAutoFinder.lua） ==================
-- 旧实现的三个致命限制（导致「使用了分组的预设」必定查不到）：
--   1) 只检查顶层 presets 里的**第一个**预设；
--   2) 只检查固定部件（防具固定 "1"、武器固定 "0"）；
--      而分组预设的材质放在各分组的 mask 里，顶层母部件材质常常是 null；
--   3) 只要文件名里出现过目标 body_id 就直接 continue 跳过。
-- 现在改为：扫描全部预设文件 → 读取身上**所有部件**的真实材质 → 逐个求交集打分
-- → 命中材质数最多的胜出（文件名相同给加成，材质读不到时退化为文件名匹配）。

-- 防具模式下的部件索引（0=头 1=身 2=腕 3=腰 4=脚），与 get_character_part 的映射一致
local AUTO_FIND_ARMOR_PART_INDICES = { 0, 1, 2, 3, 4 }

-- 收集一个 GameObject 上的全部材质名
local function collect_materials_from_object(obj, out)
    if not obj then return 0 end
    local mesh = get_mesh_component_recursive(obj)
    if not mesh then return 0 end
    local mat_count = SceneObject.call(mesh, "get_MaterialNum")
    if not mat_count or mat_count == 0 then return 0 end
    local added = 0
    for i = 0, mat_count - 1 do
        local name = SceneObject.call(mesh, "getMaterialName", i)
        if name then
            out[name] = true
            added = added + 1
        end
    end
    return added
end

-- 读取当前角色（或当前武器）身上的真实材质
-- 返回：材质集合, 有效部件数, 错误信息
local function collect_current_materials(primary)
    local mats = {}
    local part_hits = 0
    if is_weapon_mode then
        local weapon_parts = Utils.get_current_weapon_parts(primary)
        if not weapon_parts or #weapon_parts == 0 then
            return mats, 0, "未找到武器部件"
        end
        for _, part in ipairs(weapon_parts) do
            if collect_materials_from_object(part, mats) > 0 then
                part_hits = part_hits + 1
            end
        end
    else
        for _, idx in ipairs(AUTO_FIND_ARMOR_PART_INDICES) do
            local part = get_character_part(primary, idx)
            if collect_materials_from_object(part, mats) > 0 then
                part_hits = part_hits + 1
            end
        end
    end
    return mats, part_hits, nil
end

local function find_auto_preset(target_body_id)
    if not target_body_id then return false, "No Body ID" end
    local primary = get_primary_player()
    if not primary then return false, "No Character" end

    local t0 = Profiler.begin("auto_find_preset")
    local current_mats, part_hits, collect_err = collect_current_materials(primary)
    local mat_total = 0
    for _ in pairs(current_mats) do mat_total = mat_total + 1 end

    local candidates, scan_diag = PresetAutoFinder.scan({
        fs = fs,
        load_json = json.load_file,
        analyze = PresetAutoFinder.analyze_config
    })
    local best, diag = PresetAutoFinder.find_best(candidates, current_mats, target_body_id)

    -- 诊断信息：无论成功失败都拼进返回文本，UI 会直接显示，方便排查
    local function build_detail()
        local parts = {
            string.format("扫描%d份", #candidates),
            string.format("身上材质%d个/%d部位", mat_total, part_hits)
        }
        if diag and diag.reason and diag.reason ~= "" then
            table.insert(parts, diag.reason)
        end
        if diag and diag.top and #diag.top > 0 then
            local head = diag.top[1]
            local kind = head.has_groups and "分组" or "顶层"
            table.insert(parts, string.format("最佳:%s[%s]命中%d/%d材质(%.0f%%)%s",
                head.base, kind, head.intersect_mats, head.file_mats,
                (head.coverage or 0) * 100,
                head.filename_match and "·与当前编号同名" or ""))
        end
        return table.concat(parts, "，")
    end

    if not best then
        Profiler.finish("auto_find_preset", t0)
        local msg = "未找到匹配的预设"
        if collect_err then
            msg = collect_err
        elseif scan_diag and scan_diag.loaded == 0 then
            msg = "未读取到任何预设文件"
        end
        return false, msg .. "｜" .. build_detail()
    end

    -- 加载：依次尝试扫描阶段记录下来的几种路径写法
    local data = nil
    for _, p in ipairs({ best.path, "reframework/data/" .. best.path,
                         string.gsub(best.path, "^ArmorVariantManager[/\\]", "") }) do
        local loaded = json.load_file(p)
        if type(loaded) == "table" and (loaded.presets or loaded.groups) then
            data = loaded
            break
        end
    end
    if not data then
        Profiler.finish("auto_find_preset", t0)
        return false, "预设文件读取失败: " .. tostring(best.path)
    end

    current_config = data
    save_current_config_to_file(target_body_id)
    -- 分组预设必须顺带刷新分组列表并重建默认覆盖，否则新 UI 里分组是空的
    update_preset_names_list()
    update_group_names_list()
    apply_all_defaults(target_body_id)
    Profiler.finish("auto_find_preset", t0)
    return true, string.format("已匹配: %s｜%s", best.base, build_detail())
end

-- ================== 手动查找预设（新版 UI 用） ==================
-- 新版 UI 的「当前 body_id」缓存。声明必须放在**使用它的函数之前**：
-- Lua 的局部变量作用域从声明语句之后才开始，若声明在使用之后，
-- 函数内部引用到的其实是同名全局变量（恒为 nil），赋值会静默失效。
local new_ui_config_body_id = nil

-- 列出所有可加载的预设文件（含 backup 目录，标注 [备份]）。
-- 防具模式下过滤掉武器预设（按文件名前缀判断），武器模式下全部列出。
local function list_manual_preset_files()
    if not fs or not fs.glob then return {} end
    local search_patterns = {
        "reframework/data/ArmorVariantManager/.*\\.json",
        "reframework\\\\data\\\\ArmorVariantManager\\\\.*\\.json",
        "ArmorVariantManager/.*\\.json",
        "ArmorVariantManager\\\\.*\\.json",
        "data/ArmorVariantManager/.*\\.json"
    }
    local all_files = {}
    for _, pattern in ipairs(search_patterns) do
        local found = fs.glob(pattern)
        if found then
            for _, f in ipairs(found) do table.insert(all_files, f) end
        end
    end
    -- 武器部件前缀集合（用于在防具模式下过滤武器预设）
    local weapon_prefixes = {}
    if Utils and Utils.WEAPON_PARTS_MAP then
        for _, parts in pairs(Utils.WEAPON_PARTS_MAP) do
            for _, part in ipairs(parts) do weapon_prefixes[part.prefix] = true end
        end
    end
    local seen = {}
    local result = {}
    for _, raw in ipairs(all_files) do
        -- 注意：这个模式捕获到的是**不带 .json 的文件名**（([^/\\]+) 后面才跟 %.json），
        -- 所以下面判断设置文件时必须拿掉扩展名再比，否则 GlobalSettings 会漏进列表。
        local file_name = string.match(raw, "([^/\\]+)%.json$") or raw
        local base_name = string.gsub(file_name, "%.json$", "")
        local lower_raw = string.lower(raw)
        local skip = base_name == "GlobalSettings" or string.find(lower_raw, "runtime") ~= nil
        if not skip then
            local is_weapon_preset = false
            for prefix, _ in pairs(weapon_prefixes) do
                if string.sub(base_name, 1, #prefix) == prefix then
                    is_weapon_preset = true
                    break
                end
            end
            if is_weapon_mode or not is_weapon_preset then
                if not seen[raw] then
                    seen[raw] = true
                    local is_backup = string.find(lower_raw, "backup") ~= nil
                    table.insert(result, {
                        path = raw,
                        name = is_backup and ("[备份] " .. base_name) or base_name
                    })
                end
            end
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- 加载指定的预设文件并立即应用到当前角色（沿用旧版面板手动查找的完整流程）
local function load_manual_preset_file(file_path, body_id)
    if not file_path or not body_id then return false, T("load_failed") end
    local data = json.load_file(file_path)
    if not data then data = json.load_file("reframework/data/" .. file_path) end
    if not data then
        local alt_path = string.gsub(file_path, "^[Aa]rmor[Vv]ariant[Mm]anager[/\\]", "")
        data = json.load_file(alt_path)
    end
    if not data or type(data) ~= "table" then
        return false, T("load_failed")
    end
    current_config = data
    save_current_config_to_file(body_id)
    update_preset_names_list()
    update_group_names_list()
    apply_all_defaults(body_id)
    local primary_apply = get_primary_player()
    if primary_apply then
        if is_weapon_mode then
            local weapon_parts = Utils.get_current_weapon_parts(primary_apply)
            if weapon_parts then
                apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
            end
        else
            apply_preset_to_character(primary_apply, active_overrides[body_id], true)
        end
    end
    -- 让新版 UI 下一帧重新读取配置
    new_ui_config_body_id = nil
    return true
end

local function get_preset_data_by_group(group_name, preset_name)
    if not preset_name then return nil end
    if group_name == "" or group_name == nil then
        if current_config.presets then
            return current_config.presets[preset_name]
        end
    else
        if current_config.groups and current_config.groups[group_name] and current_config.groups[group_name].presets then
            return current_config.groups[group_name].presets[preset_name]
        end
    end
    return nil
end

local function load_body_config(body_id)
    if not body_id then return false end
    current_config = {
        default_preset = "",
        presets = {},
        groups = {},
        enable_transform = false,
        transform_type = "weapon",
        is_parallel = false,
        parallel_settings = {
            weapon = { enabled = true, priority = 1 },
            scroll = { enabled = false, priority = 2 },
            monster_hp = { enabled = false, priority = 3 },
            longsword = { enabled = false, priority = 4 },
            dual_blades = { enabled = false, priority = 5 },
            switch_axe = { enabled = false, priority = 6 },
            charge_axe = { enabled = false, priority = 7 },
            greatsword_level = { enabled = false, priority = 8 },
            hammer = { enabled = false, priority = 9 },
            bow = { enabled = false, priority = 10 }
        },
        weapon_transform_rules = {
            { state = "sheathed", targets = {} },
            { state = "drawn", targets = {} }
        },
        scroll_transform_rules = {
            { state = "red", targets = {} },
            { state = "blue", targets = {} }
        },
        longsword_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        dual_blades_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} }
        },
        switch_axe_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} }
        },
        charge_axe_transform_rules = {
            { state = 0, targets = {} },
            { state = 1, targets = {} },
            { state = 2, targets = {} },
            { state = 3, targets = {} },
            { state = 4, targets = {} },
            { state = 5, targets = {} }
        },
        greatsword_level_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        hammer_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} }
        },
        bow_transform_rules = {
            { level = 0, targets = {} },
            { level = 1, targets = {} },
            { level = 2, targets = {} },
            { level = 3, targets = {} }
        },
        monster_hp_transform_rules = {}
    }
    local data = load_config_data(body_id)
    if data then
        current_config = data
        loaded_configs[body_id] = current_config
    end
    update_group_names_list()
    update_preset_names_list()
    if data then
        apply_all_defaults(body_id)
        return true
    end
    return false
end

-- ========== UI 辅助函数：绘制 Mesh 开关（增强：过滤、全选、反选、全局分组提示） ==========
-- 武器差分模式下，Mesh 开关强制为启用且不可关闭，以维持UI布局一致
local function draw_mesh_toggle(game_object, label, body_id, part_index)
    if not game_object then return end
    if not safe_object_alive(game_object) then return end
    if not type_mesh then
        type_mesh = get_type("via.render.Mesh")
        if not type_mesh then
            imgui.text_colored(label .. " " .. T("type_loading"), 0xFF808080)
            return
        end
    end
    local mesh_component = SceneObject.call(game_object, "getComponent(System.Type)", type_mesh:get_runtime_type())
    if mesh_component then
        if imgui.tree_node(label) then
            -- 启用模型复选框：武器模式下强制开启并禁用，防具模式正常交互
            local is_enabled = SceneObject.call(mesh_component, "get_Enabled")
            if is_weapon_mode then
                imgui.begin_disabled(true)
                imgui.checkbox(T("enable_mesh"), true)  -- 始终显示勾选，不可修改
                imgui.end_disabled()
            else
                local changed, new_value = imgui.checkbox(T("enable_mesh"), is_enabled)
                if changed then
                    SceneObject.call(mesh_component, "set_Enabled", new_value)
                    if body_id and part_index then
                        local s_idx = tostring(part_index)
                        if not active_overrides[body_id] then active_overrides[body_id] = {} end
                        if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                        active_overrides[body_id][s_idx].mesh_enabled = new_value
                        TransformManager.edit_base_field(body_id, s_idx, nil, new_value)
                        bump_overrides_version(body_id)
                    end
                end
            end

            local mat_count = SceneObject.call(mesh_component, "get_MaterialNum")
            if mat_count and mat_count > 0 then
                local s_idx = tostring(part_index)
                local function mat_is_operable(mat_name)
                    local flt = mat_filter_text[part_index] or ""
                    if flt ~= "" and not string.find(string.lower(mat_name), string.lower(flt), 1, true) then
                        return false
                    end
                    if is_selection_mode then
                        return get_material_group_owner(part_index, mat_name) == nil
                    else
                        return is_material_in_current_context(part_index, mat_name)
                    end
                end

                imgui.same_line()
                if imgui.button(T("select_all") .. "##sa_" .. s_idx) then
                    local all_on = true
                    for k = 0, mat_count - 1 do
                        local mn = SceneObject.call(mesh_component, "getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not (pending_material_selections[s_idx] and pending_material_selections[s_idx][mn]) then
                                    all_on = false; break
                                end
                            else
                                local intent = (active_overrides[body_id]
                                    and active_overrides[body_id][s_idx]
                                    and active_overrides[body_id][s_idx].materials
                                    and active_overrides[body_id][s_idx].materials[mn])
                                local cur_on = (intent ~= nil) and intent or SceneObject.call(mesh_component, "getMaterialsEnable", k)
                                if not cur_on then
                                    all_on = false; break
                                end
                            end
                        end
                    end
                    local target_val = not all_on
                    for k = 0, mat_count - 1 do
                        local mn = SceneObject.call(mesh_component, "getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                pending_material_selections[s_idx][mn] = target_val or nil
                            else
                                SceneObject.call(mesh_component, "setMaterialsEnable", k, target_val)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = target_val
                                    TransformManager.edit_base_field(body_id, s_idx, mn, target_val)
                                    bump_overrides_version(body_id)
                                end
                            end
                        end
                    end
                end

                imgui.same_line()
                if imgui.button(T("invert_select") .. "##inv_" .. s_idx) then
                    for k = 0, mat_count - 1 do
                        local mn = SceneObject.call(mesh_component, "getMaterialName", k)
                        if mn and mat_is_operable(mn) then
                            if is_selection_mode then
                                if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                local cur = pending_material_selections[s_idx][mn]
                                pending_material_selections[s_idx][mn] = (not cur) or nil
                            else
                                local cur = SceneObject.call(mesh_component, "getMaterialsEnable", k)
                                local nv = not cur
                                SceneObject.call(mesh_component, "setMaterialsEnable", k, nv)
                                if body_id then
                                    if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                    if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                    if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                    active_overrides[body_id][s_idx].materials[mn] = nv
                                    TransformManager.edit_base_field(body_id, s_idx, mn, nv)
                                    bump_overrides_version(body_id)
                                end
                            end
                        end
                    end
                end

                imgui.same_line()
                imgui.set_next_item_width(140)
                local flt_cur = mat_filter_text[part_index] or ""
                local flt_changed, flt_val = imgui.input_text("##matflt_" .. s_idx, flt_cur)
                if flt_changed then mat_filter_text[part_index] = flt_val end
                if flt_cur ~= "" then
                    imgui.same_line()
                    if imgui.button("x##fltclr_" .. s_idx) then mat_filter_text[part_index] = "" end
                end

                imgui.separator()
                imgui.text(T("materials") .. " (" .. tostring(mat_count) .. "):")
                local filter_str = string.lower(mat_filter_text[part_index] or "")
                for i = 0, mat_count - 1 do
                    local mat_name = SceneObject.call(mesh_component, "getMaterialName", i)
                    if mat_name then
                        if filter_str == "" or string.find(string.lower(mat_name), filter_str, 1, true) then
                            local is_mat_enabled = SceneObject.call(mesh_component, "getMaterialsEnable", i)
                            local owner = get_material_group_owner(part_index, mat_name)
                            local global_groups = get_material_global_groups(part_index, mat_name)
                            if is_selection_mode then
                                local is_selected = pending_material_selections[s_idx] and pending_material_selections[s_idx][mat_name]
                                if owner and not new_group_is_global then
                                    imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF808080)
                                else
                                    local changed_sel, new_sel = imgui.checkbox(string.format("[%d] %s", i, mat_name), is_selected or false)
                                    if changed_sel then
                                        if not pending_material_selections[s_idx] then pending_material_selections[s_idx] = {} end
                                        pending_material_selections[s_idx][mat_name] = new_sel
                                    end
                                    if #global_groups > 0 then
                                        local body_id_hint = get_primary_body_id()
                                        local saved = (body_id_hint and active_group_presets[body_id_hint]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname = saved[gname]
                                            if not pname or pname == "" then pname = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname and g_data.presets and g_data.presets[pname]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            else
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_visible"), gname), 0xFF80C0FF)
                                            end
                                        end
                                    end
                                end
                            else
                                if is_material_in_current_context(part_index, mat_name) then
                                    local mat_label = string.format("[%d] %s", i, mat_name)
                                    local intent_val = (active_overrides[body_id]
                                        and active_overrides[body_id][s_idx]
                                        and active_overrides[body_id][s_idx].materials
                                        and active_overrides[body_id][s_idx].materials[mat_name])
                                    local display_val = (intent_val ~= nil) and intent_val or is_mat_enabled
                                    local mat_changed, mat_new_val = imgui.checkbox(mat_label, display_val)
                                    if mat_changed then
                                        if body_id and part_index then
                                            if not active_overrides[body_id] then active_overrides[body_id] = {} end
                                            if not active_overrides[body_id][s_idx] then active_overrides[body_id][s_idx] = { materials = {} } end
                                            if not active_overrides[body_id][s_idx].materials then active_overrides[body_id][s_idx].materials = {} end
                                            active_overrides[body_id][s_idx].materials[mat_name] = mat_new_val
                                            TransformManager.edit_base_field(body_id, s_idx, mat_name, mat_new_val)
                                            bump_overrides_version(body_id)
                                        end
                                        local render_val
                                        if mat_new_val == true and is_globally_hidden(part_index, mat_name) then
                                            render_val = false
                                        else
                                            render_val = mat_new_val
                                        end
                                        SceneObject.call(mesh_component, "setMaterialsEnable", i, render_val)
                                    end
                                    if #global_groups > 0 then
                                        local body_id_hint2 = get_primary_body_id()
                                        local saved2 = (body_id_hint2 and active_group_presets[body_id_hint2]) or {}
                                        for _, gname in ipairs(global_groups) do
                                            local g_data = current_config.groups and current_config.groups[gname]
                                            local pname2 = saved2[gname]
                                            if not pname2 or pname2 == "" then pname2 = g_data and g_data.default_preset end
                                            local def_preset = g_data and pname2 and g_data.presets and g_data.presets[pname2]
                                            local global_hidden = def_preset and def_preset[s_idx] and def_preset[s_idx].materials and (def_preset[s_idx].materials[mat_name] == false)
                                            if global_hidden then
                                                imgui.same_line()
                                                imgui.text_colored(string.format(T("in_global_group_hidden"), gname), 0xFF4080FF)
                                            end
                                        end
                                    end
                                else
                                    if current_group_name == "" and owner then
                                        imgui.text_colored(string.format("[%d] %s (%s: %s)", i, mat_name, T("already_in_group"), owner), 0xFF804040)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            imgui.tree_pop()
        end
    else
        imgui.text_colored(label .. " " .. T("no_mesh"), 0xFF808080)
    end
end

-- 辅助函数：绘制条件的目标列表（分组下拉框支持全局分组前缀）
local function draw_targets_ui(targets, rule_type, rule_idx, body_id, player_obj)
    for j, target in ipairs(targets) do
        imgui.push_id(rule_type .. "_" .. rule_idx .. "_target_" .. j)
        local all_groups = { "" }
        local all_groups_display = { T("main_list") or "Main" }
        if current_config.groups then
            local ordered_gnames = {}
            local in_order = {}
            if current_config.group_order then
                for _, gname in ipairs(current_config.group_order) do
                    if current_config.groups[gname] then
                        table.insert(ordered_gnames, gname)
                        in_order[gname] = true
                    end
                end
            end
            for gname, _ in pairs(current_config.groups) do
                if not in_order[gname] then table.insert(ordered_gnames, gname) end
            end
            for _, gname in ipairs(ordered_gnames) do
                local g_data = current_config.groups[gname]
                table.insert(all_groups, gname)
                if g_data.is_global then
                    table.insert(all_groups_display, T("global_group_label") .. " " .. gname)
                else
                    table.insert(all_groups_display, gname)
                end
            end
        end
        local g_idx = 1
        for idx, g in ipairs(all_groups) do
            if g == (target.group or "") then g_idx = idx; break end
        end
        imgui.set_next_item_width(120)
        local c_g, v_g = imgui.combo("##group", g_idx, all_groups_display)
        if c_g then
            target.group = all_groups[v_g]
            target.preset = ""
            save_current_config_to_file(body_id)
        end
        imgui.same_line()
        local target_presets = {}
        if target.group == "" or target.group == nil then
            if current_config.presets then
                local in_order = {}
                if current_config.preset_order then
                    for _, pname in ipairs(current_config.preset_order) do
                        if current_config.presets[pname] then
                            table.insert(target_presets, pname)
                            in_order[pname] = true
                        end
                    end
                end
                for pname, _ in pairs(current_config.presets) do
                    if not in_order[pname] then table.insert(target_presets, pname) end
                end
            end
        else
            if current_config.groups and current_config.groups[target.group] and current_config.groups[target.group].presets then
                local g_data = current_config.groups[target.group]
                local in_order = {}
                if g_data.preset_order then
                    for _, pname in ipairs(g_data.preset_order) do
                        if g_data.presets[pname] then
                            table.insert(target_presets, pname)
                            in_order[pname] = true
                        end
                    end
                end
                for pname, _ in pairs(g_data.presets) do
                    if not in_order[pname] then table.insert(target_presets, pname) end
                end
            end
        end
        local p_idx = 1
        local found = false
        for idx, p in ipairs(target_presets) do
            if p == target.preset then p_idx = idx; found = true; break end
        end
        if not found and #target_presets > 0 then
            target.preset = target_presets[1]
            save_current_config_to_file(body_id)
        end
        if #target_presets == 0 then table.insert(target_presets, "None") end
        imgui.set_next_item_width(150)
        local c_p, v_p = imgui.combo("##preset", p_idx, target_presets)
        if c_p and target_presets[v_p] ~= "None" then
            target.preset = target_presets[v_p]
            save_current_config_to_file(body_id)
        end
        imgui.same_line()
        if imgui.button(T("delete_condition") .. "##del_cond") then
            table.remove(targets, j)
            save_current_config_to_file(body_id)
        end
        imgui.pop_id()
    end
end

-- 纯函数合并覆盖（用于 TransformManager）
merge_overrides = function(base, add)
    local result = deep_copy_table(base) or {}
    if not add then return result end
    for p_idx, p_data in pairs(add) do
        if not result[p_idx] then result[p_idx] = { materials = {} } end
        if p_data.mesh_enabled ~= nil then
            result[p_idx].mesh_enabled = p_data.mesh_enabled
        end
        if p_data.materials then
            if not result[p_idx].materials then result[p_idx].materials = {} end
            for m, en in pairs(p_data.materials) do
                result[p_idx].materials[m] = en
            end
        end
    end
    return result
end

-- ========== 过场动画强制显示装备 ==========
local function pre_function(args)
    args[4] = sdk.to_ptr(false)
end
local function post_function(retval)
    return retval
end
if not pcall(function()
    sdk.hook(sdk.find_type_definition("snow.eventcut.EventPlayerLoader"):get_method("<reqStandby>g__set_equip_index|88_0(snow.player.PlayerRequestEquipsData.EquipPack, System.Int32, System.Boolean, snow.eventcut.EventPlayerLoader.<>c__DisplayClass88_0)"), pre_function, post_function)
end) then
    log.debug("[ArmorVariantManager] Failed to hook EventPlayerLoader")
end

-- ========== 运行时配置加载（独立于 UI 的 current_config） ==========
local get_runtime_config = nil
local function get_runtime_config_impl(body_id)
    if not loaded_configs[body_id] then
        local default_config = {
            default_preset = "",
            presets = {},
            groups = {},
            enable_transform = false,
            transform_type = "weapon",
            is_parallel = false,
            parallel_settings = {
                weapon = { enabled = true, priority = 1 },
                scroll = { enabled = false, priority = 2 },
                monster_hp = { enabled = false, priority = 3 },
                longsword = { enabled = false, priority = 4 },
                dual_blades = { enabled = false, priority = 5 },
                switch_axe = { enabled = false, priority = 6 },
                charge_axe = { enabled = false, priority = 7 },
                greatsword_level = { enabled = false, priority = 8 },
                hammer = { enabled = false, priority = 9 },
                bow = { enabled = false, priority = 10 }
            },
            weapon_transform_rules = {
                { state = "sheathed", targets = {} },
                { state = "drawn", targets = {} }
            },
            scroll_transform_rules = {
                { state = "red", targets = {} },
                { state = "blue", targets = {} }
            },
            longsword_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} },
                { level = 3, targets = {} }
            },
            dual_blades_transform_rules = {
                { state = 0, targets = {} },
                { state = 1, targets = {} },
                { state = 2, targets = {} }
            },
            switch_axe_transform_rules = {
                { state = 0, targets = {} },
                { state = 1, targets = {} },
                { state = 2, targets = {} }
            },
            charge_axe_transform_rules = {
                { state = 0, targets = {} },
                { state = 1, targets = {} },
                { state = 2, targets = {} },
                { state = 3, targets = {} },
                { state = 4, targets = {} },
                { state = 5, targets = {} }
            },
            greatsword_level_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} },
                { level = 3, targets = {} }
            },
            hammer_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} }
            },
            bow_transform_rules = {
                { level = 0, targets = {} },
                { level = 1, targets = {} },
                { level = 2, targets = {} },
                { level = 3, targets = {} }
            },
            monster_hp_transform_rules = {}
        }
        local data = load_config_data(body_id)
        if data then
            for k, v in pairs(data) do
                default_config[k] = v
            end
        end
        loaded_configs[body_id] = default_config
        refresh_monster_hp_gate()
    end
    return loaded_configs[body_id]
end
get_runtime_config = function(body_id)
    local t0 = Profiler.begin("get_runtime_config")
    local result = get_runtime_config_impl(body_id)
    Profiler.finish("get_runtime_config", t0)
    Profiler.count("get_runtime_config_calls")
    return result
end

-- ========== 帧率解锁与渲染比例 ==========
local app = sdk.get_native_singleton("via.Application")
local set_MaxFps = app and sdk.find_type_definition("via.Application"):get_method("set_MaxFps")
local render = sdk.get_native_singleton("via.render.Renderer")
local set_ImageQualityRate = render and sdk.find_type_definition("via.render.Renderer"):get_method("set_ImageQualityRate")

-- 应用帧率（自动模式：读取游戏选项中的帧率上限）
local function apply_fps_cap()
    if not app or not set_MaxFps then return end
    local stmOptionManager = sdk.get_managed_singleton("snow.StmOptionManager")
    if stmOptionManager then
        local optionContainer = stmOptionManager:get_field("_StmOptionDataContainer")
        if optionContainer then
            local frameRateOption = optionContainer:call("getFrameRateOption") -- 返回 0~7 对应 fps_option 索引
            local fps_option = { 30, 60, 90, 120, 144, 165, 240, 600 }
            local desiredFPS = fps_option[frameRateOption + 1] or 60
            set_MaxFps:call(app, desiredFPS + 0.0)
        end
    end
end

-- 应用渲染比例
local function apply_image_quality()
    if not render or not set_ImageQualityRate then return end
    if global_config.enable_image_quality then
        set_ImageQualityRate:call(render, global_config.image_quality_rate + 0.0)
    end
end

-- 钩子函数：当游戏选项改变或过场动画播放时刷新帧率
local function on_game_option_changed()
    apply_fps_cap()
    apply_image_quality()
end

-- 安全 hook（如果目标函数存在）
local function safe_hook(type_def, method_name, pre_cb, post_cb)
    if type_def and type_def.get_method then
        local method = type_def:get_method(method_name)
        if method then
            sdk.hook(method, pre_cb or function() end, post_cb or function(ret) return ret end)
            return true
        end
    end
    return false
end

-- Hook 游戏选项写入（修改帧率触发）
local stmOptionManagerType = sdk.find_type_definition("snow.StmOptionManager")
if stmOptionManagerType then
    safe_hook(stmOptionManagerType, "writeGraphicOptionOnIniFile", nil, on_game_option_changed)
end

-- Hook 过场动画播放（确保过场中帧率正确）
local uniqueEventManagerType = sdk.find_type_definition("snow.eventcut.UniqueEventManager")
if uniqueEventManagerType then
    safe_hook(uniqueEventManagerType, "playEventCommon", nil, on_game_option_changed)
end

-- Hook 渲染质量变更（确保渲染比例被重新应用）
local renderAppManagerType = sdk.find_type_definition("snow.RenderAppManager")
if renderAppManagerType then
    safe_hook(renderAppManagerType, "setSamplerQuality", nil, apply_image_quality)
end

-- 初始化时立即应用一次
apply_fps_cap()
apply_image_quality()

-- ========== 场景切换时清除所有状态缓存 ==========
local current_flow_state = 0  -- 0=未知, 1=据点, 2=任务中, 其他=其他状态

local questManagerTypeDef = sdk.find_type_definition("snow.QuestManager")
if questManagerTypeDef then
    local onChangedGameStatus = questManagerTypeDef:get_method("onChangedGameStatus")
    if onChangedGameStatus then
        sdk.hook(onChangedGameStatus,
            function(args)
                -- 记录当前游戏状态（1=据点，2=任务中）
                local flow_state = sdk.to_int64(args[3])
                current_flow_state = flow_state

                -- 性能诊断：进出任务/据点时先把当前窗口落盘，避免最后一段数据丢失
                if Profiler.enabled then Profiler.flush() end

                -- 场景切换时重置所有缓存（但不重置首次刷新标志）
                Applied.clear()     -- 角色级「已应用」记账
                PlayerDir.reset()        -- 玩家目录（场景换了，玩家对象全部作废）
                invalidate_primary_body_id()
                PlayerDir.scan_reset()   -- 场景换了，旧的玩家对象引用必须作废
                part_cache = {}          -- 清空防具部件缓存
                weapon_part_cache = {}   -- 清空武器部件缓存
                overrides_version = {}   -- 清空版本号
                if TransformManager.clear_cache then TransformManager.clear_cache() end
                current_group_name = ""
                active_overrides = {}
                active_group_presets = {}
                update_preset_names_list()
                update_group_names_list()
                -- 重置事件玩家状态
                last_has_event_players = nil
                cached_event_players = {}
                cached_has_event_players = false
            end,
            function(retval) return retval end
        )
    end
end

-- ========== 特殊CG刷新间隔与每帧处理玩家数量（可手动调节） ==========
-- - v3.1.2：这两个值都调高了 —— 事件主角初次登场要「过几秒」才正常，
--   除了节流口径的问题（见 SPECIAL_CG_APPLY_INTERVAL），处理节奏本身也偏慢：
--   旧值是「每 15 帧处理一批、每批 2 人」，一场过场里有 3~4 个角色时，
--   同一个角色要好几轮才轮到一次。
local SPECIAL_CG_UPDATE_INTERVAL = 8       -- 特殊CG每N帧处理一次（原 15）
local SPECIAL_CG_PLAYERS_PER_FRAME = 3     -- 每次处理几个角色（原 2）

-- ========== 正常游玩刷新间隔（可手动调节） ==========
local NORMAL_UPDATE_INTERVAL = 10           -- 正常游玩每N帧处理一次，默认10帧
-- - v3.1.0：其他玩家用**更慢**的节奏（见帧循环里的说明）。
--   队友身上的差分变化不需要 14 次/秒，0.2 秒的延迟肉眼分辨不出来，
--   但开销直接降到 1/3。
local MULTIPLAYER_UPDATE_INTERVAL = 30      -- 联机：其他玩家每N帧推进一次，默认30帧

-- ========== 事件玩家缓存（每5帧刷新） ==========
local cached_event_players = {}
local cached_has_event_players = false

-- ========== 每帧更新 ==========
local last_frame_time = 0
local frame_interval = 1/30
local global_frame_counter = 0  -- 全局帧计数器，用于降频

-- 事件玩家存在状态（用于检测变化以重置缓存）
local last_has_event_players = nil
-- 特殊CG玩家轮询索引
local special_cg_next_index = 1

-- 首次刷新标志（启动后只执行一次）
local first_apply_done = false

-- 确保强制展开节点标志存在（如果尚未定义，则初始化）
if force_open_presets_node == nil then
    force_open_presets_node = false
end

-- ========== 玩家部件缓存（防具） ==========
-- - 实现在文件靠前处（PlayerDir.parts / part_cache）。
--   这里只保留一个兼容别名，避免同一件事有两份实现、两套行为。
local function get_all_cached_character_parts(character)
    Profiler.count("get_all_cached_character_parts_calls")
    return PlayerDir.parts(character)
end

-- 兼容旧调用：取某个角色的单个防具部件
local function get_cached_character_part(character, part_index)
    return get_character_part(character, part_index)
end

-- ========== 玩家部件缓存（武器） ==========
-- （weapon_part_cache 已提前到文件靠前处声明，原因见那里的注释）

-- 缓存版获取武器部件列表
-- player_handle：该玩家的 Player 托管对象（可选），用来读**他自己**的武器类型
local function weapon_parts_alive(parts)
    if not parts then return false end
    local found_any = false
    -- 最多 2 个部件（各武器类型在 Utils.WEAPON_PARTS_MAP 里），循环上限给 8 足够
    for i = 1, 8 do
        local p = parts[i]
        if p ~= nil then
            found_any = true
            if not safe_object_alive(p) then return false end
        end
    end
    return found_any
end

local function get_cached_weapon_parts_impl(player_obj, player_handle)
    if not player_obj then return nil end
    if not safe_object_alive(player_obj) then return nil end
    local player_addr = tostring(player_obj)
    local cached = weapon_part_cache[player_addr]
    if cached then
        -- - 缓存里**任一**部件失效都要重查（旧实现只看第一个部件，
        --   换武器时可能留下部分失效的列表）
        if weapon_parts_alive(cached) then
            return cached
        end
        weapon_part_cache[player_addr] = nil
    end
    -- 缓存缺失或失效：重新递归查找
    local weapon_parts = Utils.get_current_weapon_parts(player_handle or player_obj)
    if weapon_parts_alive(weapon_parts) then
        weapon_part_cache[player_addr] = weapon_parts
    else
        weapon_parts = nil
    end
    return weapon_parts
end
get_cached_weapon_parts = function(player_obj, player_handle)
    local t0 = Profiler.begin("get_cached_weapon_parts")
    local result = get_cached_weapon_parts_impl(player_obj, player_handle)
    Profiler.finish("get_cached_weapon_parts", t0)
    Profiler.count("get_cached_weapon_parts_calls")
    return result
end

-- ========== 清除缓存函数 ==========
-- 清除特定玩家的所有缓存（防具 + 武器 + 版本号）
local function clear_player_cache(player_addr)
    if player_addr then
        if part_cache[player_addr] then
            part_cache[player_addr] = nil
        end
        if weapon_part_cache[player_addr] then
            weapon_part_cache[player_addr] = nil
        end
    end
end

-- ========== 刷新玩家列表 ==========
-- - v3.1.0：这份实现已经合并进玩家目录（见文件靠前的 refresh_player_list）。
--   旧版本这里还有第二份定义，会**覆盖**靠前那份，导致「联机时把队友当成主角」的
--   回退逻辑又把玩家列表塞满队友。现在只保留一份，避免两套语义打架。

-- ============================================================================
--  新版 UI（D2D）接入层
-- ----------------------------------------------------------------------------
--  这里只做「把崛起版本核心能力暴露给 UI」这一件事，不改变任何已有语义：
--    * 所有游戏逻辑仍然调用上面既有的函数；
--    * 变身规则的运行时应用仍然由 re.on_frame 里的既有代码负责，
--      UI 只负责编辑 current_config 并调用 save_current_config_to_file。
-- ============================================================================
-- 与旧版面板展开时的行为保持一致：把当前 body_id 的配置同步到 current_config
local function sync_current_config_for_body(body_id)
    if not body_id then return end
    if new_ui_config_body_id == body_id then return end
    local config = loaded_configs[body_id]
    if config then
        for k, v in pairs(config) do
            current_config[k] = deep_copy_table(v)
        end
        new_ui_config_body_id = body_id
        update_preset_names_list()
        update_group_names_list()
    else
        load_body_config(body_id)
        new_ui_config_body_id = body_id
    end
end

-- 把选中的预设记录为默认预设（等价于旧版面板的「设为默认预设」按钮）
local function set_preset_as_default(preset_name, body_id)
    if not preset_name or preset_name == "" then return false end
    body_id = body_id or get_primary_body_id()
    if not body_id then return false end
    if current_group_name == "" then
        current_config.default_preset = preset_name
    else
        if current_config.groups and current_config.groups[current_group_name] then
            current_config.groups[current_group_name].default_preset = preset_name
        end
    end
    save_current_config_to_file(body_id)
    return true
end

-- 防具 / 武器 模式切换（等价于旧版面板的两个复选框）
local function switch_variant_mode(weapon_mode)
    weapon_mode = weapon_mode == true
    if is_weapon_mode == weapon_mode then return end
    is_weapon_mode = weapon_mode
    refresh_player_list()
    local new_body_id = get_primary_body_id()
    if new_body_id then
        active_overrides[new_body_id] = nil
        loaded_configs[new_body_id] = nil
        load_body_config(new_body_id)
        new_ui_config_body_id = new_body_id
    end
    update_preset_names_list()
    update_group_names_list()
end

-- 取某个部位的网格组件列表（防具 1 个 / 武器 1 个）
local function get_part_meshes(character, body_id, part_index)
    if part_index == nil then return {} end
    if is_weapon_mode then
        local weapon_parts = get_cached_weapon_parts(character)
        local part_obj = weapon_parts and weapon_parts[part_index + 1]
        if not part_obj or not safe_object_alive(part_obj) then return {} end
        local mesh = get_mesh_component_recursive(part_obj)
        return mesh and { mesh } or {}
    end
    if not character then return {} end
    local part_obj = get_cached_character_part(character, part_index)
    if not part_obj or not safe_object_alive(part_obj) then return {} end
    local mesh = get_mesh_component_recursive(part_obj)
    return mesh and { mesh } or {}
end

-- 读取网格当前的显示状态与材质列表
local function get_part_mesh_view(meshes)
    local mesh = meshes and meshes[1]
    if not mesh or not safe_object_alive(mesh) then return nil end
    local ok, view = pcall(function()
        local result = {
            mesh_enabled = SceneObject.call(mesh, "get_Enabled") ~= false,
            materials = {}
        }
        local count = SceneObject.call(mesh, "get_MaterialNum") or 0
        for i = 0, count - 1 do
            table.insert(result.materials, {
                name = SceneObject.call(mesh, "getMaterialName", i),
                enabled = SceneObject.call(mesh, "getMaterialsEnable", i) ~= false,
                index = i
            })
        end
        return result
    end)
    if ok then return view end
    return nil
end

-- 设置整个部位网格的显示 / 隐藏
local function set_part_mesh_enabled(body_id, part_index, meshes, enabled)
    if not body_id or part_index == nil then return end
    local key = tostring(part_index)
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    if not active_overrides[body_id][key] then
        active_overrides[body_id][key] = { materials = {} }
    elseif not active_overrides[body_id][key].materials then
        active_overrides[body_id][key].materials = {}
    end
    active_overrides[body_id][key].mesh_enabled = enabled == true
    TransformManager.edit_base_field(body_id, key, nil, enabled == true)
    bump_overrides_version(body_id)
    for _, mesh in ipairs(meshes or {}) do
        if safe_object_alive(mesh) then
            pcall(function() SceneObject.call(mesh, "set_Enabled", enabled == true) end)
        end
    end
end

-- 设置单个材质的显示 / 隐藏（全局分组隐藏优先）
local function set_part_material_enabled(body_id, part_index, meshes, material_name, enabled)
    if not body_id or part_index == nil or not material_name then return end
    local key = tostring(part_index)
    if not active_overrides[body_id] then active_overrides[body_id] = {} end
    if not active_overrides[body_id][key] then
        active_overrides[body_id][key] = { materials = {} }
    elseif not active_overrides[body_id][key].materials then
        active_overrides[body_id][key].materials = {}
    end
    active_overrides[body_id][key].materials[material_name] = enabled == true
    TransformManager.edit_base_field(body_id, key, material_name, enabled == true)
    bump_overrides_version(body_id)
    local render_enabled = enabled == true
    if render_enabled and is_globally_hidden(part_index, material_name) then
        render_enabled = false
    end
    for _, mesh in ipairs(meshes or {}) do
        if safe_object_alive(mesh) then
            pcall(function()
                local count = SceneObject.call(mesh, "get_MaterialNum") or 0
                for i = 0, count - 1 do
                    if SceneObject.call(mesh, "getMaterialName", i) == material_name then
                        SceneObject.call(mesh, "setMaterialsEnable", i, render_enabled)
                    end
                end
            end)
        end
    end
end

local function get_part_count(character, weapon_mode)
    if not weapon_mode then return 5 end -- 崛起版本防具部位为 0~4（没有 slinger）
    local weapon_parts = get_cached_weapon_parts(character)
    return (weapon_parts and #weapon_parts) or 1
end

-- 防具显示顺序沿用崛起版本旧面板的 {2,1,0,4,3}
local function get_part_order(weapon_mode)
    if weapon_mode then return nil end
    return { 2, 1, 0, 4, 3 }
end

local function get_part_label(character, weapon_mode, part_index)
    if not weapon_mode then return nil end
    local weapon_parts = get_cached_weapon_parts(character)
    local part_obj = weapon_parts and weapon_parts[part_index + 1]
    if not part_obj or not safe_object_alive(part_obj) then return nil end
    local weapon_type = Utils.get_current_weapon_type(character)
    local part_name = Utils.get_weapon_part_name(weapon_type, part_index)
    if part_name and part_name ~= "" then return part_name end
    local ok, name = pcall(function() return SceneObject.call(part_obj, "get_Name") end)
    return ok and name or nil
end

-- 变身总开关（等价于旧版面板「启用变身」复选框的处理逻辑）
local function set_enable_transform(context, enabled)
    enabled = enabled == true
    local body_id = (context and context.body_id) or get_primary_body_id()
    current_config.enable_transform = enabled
    if not body_id then return end
    local primary = (context and context.character) or get_primary_player()
    if primary and safe_object_alive(primary) then
        if enabled then
            local char_addr = tostring(primary)
            TransformManager.clear_cache(char_addr)
            local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config,
                primary, active_overrides[body_id] or {}, merge_overrides
            )
            active_overrides[body_id] = new_overrides
            bump_overrides_version(body_id)
            if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
            if current_config.groups then
                for g_name, g_data in pairs(current_config.groups) do
                    if g_data.is_global then
                        if activated_targets and activated_targets[g_name] then
                            active_group_presets[body_id][g_name] = activated_targets[g_name]
                        elseif all_targeted_groups and all_targeted_groups[g_name] then
                            active_group_presets[body_id][g_name] = g_data.default_preset or ""
                        end
                    end
                end
            end
            if is_weapon_mode then
                local weapon_parts = get_cached_weapon_parts(primary)
                if weapon_parts then
                    apply_preset_to_weapon(weapon_parts, new_overrides, true, body_id)
                end
            else
                apply_preset_to_character(primary, new_overrides, true)
            end
        else
            apply_all_defaults(body_id)
            if active_overrides[body_id] then
                if is_weapon_mode then
                    local weapon_parts = get_cached_weapon_parts(primary)
                    if weapon_parts then
                        apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                    end
                else
                    apply_preset_to_character(primary, active_overrides[body_id], true)
                end
            end
        end
    end
    save_current_config_to_file(body_id)
end

-- ============================================================================
--  deps：新版 UI 与崛起版本核心之间的唯一契约
-- ----------------------------------------------------------------------------
--  注意：这里必须先「前置声明」variant_manager_ui 再赋值。
--  Lua 的局部变量作用域从声明语句之后才开始，因此如果写成
--      local variant_manager_ui = VariantManagerUI.new({ ... })
--  那么构造成员函数里的 variant_manager_ui 会被解析成**全局变量**（nil），
--  在 select_group / delete_group 里执行 `variant_manager_ui.material_offset = 0`
--  会直接报「attempt to index a nil value」。
--  （荒野版本 v4.0.0 的 ArmorVariantManager.lua 第 2266 / 2320 行正是这种情况，
--    错误被 UI update() 里的 pcall 吞掉，表现为「切换分组后预设列表不刷新」。）
-- ============================================================================
local variant_manager_ui = nil
variant_manager_ui = VariantManagerUI.new({
    config = global_config,
    translate = T,
    version = version,
    author = author,
    bridge_client_id = "ArmorVariantManager",
    bridge_runtime_directory = "ArmorVariantManager/Runtime",
    save_settings = save_global_settings,
    save_transform = function(context)
        local body_id = (context and context.body_id) or get_primary_body_id()
        if body_id then save_current_config_to_file(body_id) end
    end,
    get_context = function()
        local body_id = get_primary_body_id()
        if body_id then sync_current_config_for_body(body_id) end
        local active_preset_name = body_id and active_group_presets[body_id]
            and active_group_presets[body_id][current_group_name] or ""
        if not active_preset_name or active_preset_name == "" then
            if current_group_name == "" then
                active_preset_name = current_config.default_preset or ""
            else
                local group = current_config.groups and current_config.groups[current_group_name]
                active_preset_name = group and group.default_preset or ""
            end
        end
        if active_preset_name ~= "" then
            for index, preset_name in ipairs(preset_names_list) do
                if preset_name == active_preset_name then
                    selected_preset_index = index
                    break
                end
            end
        end
        return {
            body_id = body_id,
            character = get_primary_player(),
            weapon_mode = is_weapon_mode,
            group_name = current_group_name,
            group_names = group_names_list,
            preset_names = preset_names_list,
            selected_preset_index = selected_preset_index,
            selected_preset_name = active_preset_name ~= "" and active_preset_name
                or preset_names_list[selected_preset_index],
            config_restored = body_id and config_restored[body_id] == true
                and config_restore_handled[body_id] ~= true,
            config = current_config
        }
    end,
    has_any_presets = function(config)
        if config and config.presets and next(config.presets) then return true end
        for _, group in pairs((config and config.groups) or {}) do
            if group.presets and next(group.presets) then return true end
        end
        return false
    end,
    auto_find_preset = function(body_id)
        local ok, found, message = pcall(find_auto_preset, body_id)
        if not ok then return false, tostring(found) end
        if found == true then
            new_ui_config_body_id = nil
        end
        return found == true, message
    end,
    list_manual_preset_files = function()
        local ok, files = pcall(list_manual_preset_files)
        if not ok or type(files) ~= "table" then return {} end
        return files
    end,
    load_manual_preset_file = function(file_path, body_id)
        local ok, loaded, message = pcall(load_manual_preset_file, file_path, body_id)
        if not ok then return false, tostring(loaded) end
        return loaded == true, message
    end,
    restore_backup = function(body_id)
        if not body_id then return false end
        config_restore_handled[body_id] = true
        local restored = restore_config_from_backup(body_id) == true
        if restored then new_ui_config_body_id = nil end
        return restored
    end,
    dismiss_backup = function(body_id)
        if not body_id then return end
        config_restore_handled[body_id] = true
        config_restored[body_id] = nil
    end,
    set_mode = function(weapon_mode)
        switch_variant_mode(weapon_mode)
    end,
    select_group = function(group_name)
        group_name = group_name or ""
        if group_name ~= "" and (not current_config.groups or not current_config.groups[group_name]) then
            group_name = ""
        end
        current_group_name = group_name
        selected_group_index = 1
        for i, name in ipairs(group_names_list) do
            if name == current_group_name then
                selected_group_index = i + 1
                break
            end
        end
        variant_manager_ui.material_offset = 0
        update_preset_names_list()
        local body_id = get_primary_body_id()
        local active_preset = body_id and active_group_presets[body_id]
            and active_group_presets[body_id][current_group_name]
        if active_preset and active_preset ~= "" then
            for index, preset_name in ipairs(preset_names_list) do
                if preset_name == active_preset then
                    selected_preset_index = index
                    break
                end
            end
        end
    end,
    select_preset = function(index)
        selected_preset_index = index
    end,
    reorder_groups = function(items)
        local body_id = get_primary_body_id()
        if not body_id or not current_config then return end
        current_config.group_order = {}
        for _, item in ipairs(items or {}) do
            if item.name and item.name ~= "" then
                table.insert(current_config.group_order, item.name)
            end
        end
        update_group_names_list()
        update_preset_names_list()
        save_current_config_to_file(body_id)
    end,
    create_group = function(group_name, is_global, selections)
        local body_id = get_primary_body_id()
        if not body_id then return false end
        pending_material_selections = selections or {}
        is_selection_mode = true
        local created = create_new_group(group_name, body_id, is_global == true)
        if created then
            current_group_name = group_name
            selected_group_index = 1
            for i, name in ipairs(group_names_list) do
                if name == current_group_name then selected_group_index = i + 1; break end
            end
            selected_preset_index = 1
            update_group_names_list()
            update_preset_names_list()
        else
            pending_material_selections = {}
            is_selection_mode = false
        end
        return created == true
    end,
    delete_group = function(group_name)
        local body_id = get_primary_body_id()
        if not body_id then return false end
        local deleted = delete_group(group_name, body_id)
        if deleted then
            selected_preset_index = 1
            variant_manager_ui.material_offset = 0
            update_group_names_list()
            update_preset_names_list()
        end
        return deleted == true
    end,
    reorder_presets = function(items)
        local body_id = get_primary_body_id()
        if not body_id or not current_config then return end
        local target = current_config
        if current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name] then
            target = current_config.groups[current_group_name]
        end
        target.preset_order = {}
        for _, preset_name in ipairs(items or {}) do
            table.insert(target.preset_order, preset_name)
        end
        update_preset_names_list()
        save_current_config_to_file(body_id)
    end,
    create_preset = function(preset_name)
        local body_id = get_primary_body_id()
        if not body_id or not preset_name or preset_name == "" then return false end
        local saved = save_preset(preset_name, body_id)
        if saved then update_preset_names_list() end
        return saved == true
    end,
    overwrite_preset = function(preset_name)
        local body_id = get_primary_body_id()
        if not body_id or not preset_name or preset_name == "" then return false end
        local saved = save_preset(preset_name, body_id)
        if saved then update_preset_names_list() end
        return saved == true
    end,
    delete_preset = function(preset_name)
        local body_id = get_primary_body_id()
        if not body_id or not preset_name or preset_name == "" or not current_config then return false end
        local target = current_config
        if current_group_name ~= "" and current_config.groups
            and current_config.groups[current_group_name] then
            target = current_config.groups[current_group_name]
        end
        if not target.presets or not target.presets[preset_name] then return false end
        target.presets[preset_name] = nil
        if target.default_preset == preset_name then target.default_preset = "" end
        if target.preset_order then
            for index = #target.preset_order, 1, -1 do
                if target.preset_order[index] == preset_name then
                    table.remove(target.preset_order, index)
                    break
                end
            end
        end
        update_preset_names_list()
        save_current_config_to_file(body_id)
        return true
    end,
    set_default_preset = function(preset_name)
        return set_preset_as_default(preset_name, get_primary_body_id())
    end,
    set_auto_default_enabled = function(enabled, preset_name, body_id)
        global_config.auto_set_selected_preset_as_default = enabled == true
        save_global_settings()
        if global_config.auto_set_selected_preset_as_default then
            return set_preset_as_default(preset_name, body_id or get_primary_body_id())
        end
        return true
    end,
    auto_set_default_preset = function(preset_name, body_id)
        if not global_config.auto_set_selected_preset_as_default then return false end
        return set_preset_as_default(preset_name, body_id or get_primary_body_id())
    end,
    apply_preset = apply_preset,
    set_enable_transform = set_enable_transform,
    -- 当前状态显示统一交给崛起版本的 TransformManager（它已经处理了全部 10 种条件）
    get_transform_state_text = function(type_key, character)
        if not character then return nil end
        if current_config.is_parallel then return nil end
        if type_key ~= current_config.transform_type then return nil end
        local ok, text = pcall(function()
            return TransformManager.get_current_state_display(current_config, character)
        end)
        if ok and type(text) == "string" and text ~= "" then return text end
        return nil
    end,
    get_meshes = get_part_meshes,
    get_mesh_view = function(meshes)
        return get_part_mesh_view(meshes)
    end,
    get_override = function(body_id, part_index)
        if not body_id or part_index == nil then return nil end
        return active_overrides[body_id] and active_overrides[body_id][tostring(part_index)]
    end,
    set_mesh_enabled = set_part_mesh_enabled,
    set_material_enabled = set_part_material_enabled,
    get_material_occupancy = function(part_index, material_name)
        return {
            owner = get_material_group_owner(part_index, material_name),
            global_groups = get_material_global_groups(part_index, material_name),
            in_context = is_material_in_current_context(part_index, material_name)
        }
    end,
    get_part_count = get_part_count,
    get_part_order = get_part_order,
    get_part_label = get_part_label,
    mesh_toggle_locked = function(weapon_mode)
        return weapon_mode == true
    end,
    apply_image_quality = apply_image_quality
})
if variant_manager_ui and not variant_manager_ui.update then
    setmetatable(variant_manager_ui, { __index = VariantManagerUI })
end

-- ========== 运行时循环 ==========
-- 整个每帧循环放进 xpcall 里执行：
--   切换场景时 via.GameObject 等引擎对象可能瞬间失效，调用它们会抛异常。
--   失效场景对象由 SceneObject 在调用前排除；此处仅为意外异常兜底。
--   意外异常按错误级别保留堆栈及计数，同一位置限频，不再永久隐藏后续故障。
local reported_frame_errors = {}

-- 错误处理器提到函数外面：原来每帧都会新建一个闭包，是没必要的 GC 压力
local function frame_error_handler(e)
    if debug and debug.traceback then
        return debug.traceback(tostring(e), 2)
    end
    return tostring(e)
end

local function run_frame_quietly(frame_body)
    local ok, err = xpcall(frame_body, frame_error_handler)
    if ok then return end
    SceneObject.frame_errors = (SceneObject.frame_errors or 0) + 1
    local message = tostring(err)
    local key = string.match(message, "ArmorVariantManager%.lua:%d+[^\n]*") or message
    local now = os.clock()
    if reported_frame_errors[key] and now - reported_frame_errors[key] < 10 then return end
    reported_frame_errors[key] = now
    if log and log.error then
        pcall(function()
            log.error("[ArmorVariantManager] 帧更新失败（累计 " .. SceneObject.frame_errors .. " 次）："
                .. message)
        end)
    end
end

-- ============================================================================
--  联机辅助（MP）：配置存在性判断 / 武器查找限频 / 单玩家处理
-- ----------------------------------------------------------------------------
--  - 统一挂在一张表上，理由同 PlayerDir：主 chunk 的局部变量槽位接近 Lua 上限 200。
-- ============================================================================
local MP = {
    presence_ttl = 2.0,
    presence = {},      -- body_id -> { value = bool, time = number }
    scan_time = {},     -- 角色地址 -> 上次武器部件查找时刻
    next_index = 1,     -- 其他玩家轮询下标
    cg_buffer = {},     -- CG 事件玩家的 entry 复用表
}

-- 没有配置的玩家直接跳过（只对「其他玩家」生效，本地玩家行为与 v3.0.6 完全一致）。
-- 用短 TTL 缓存判断结果，避免每次去翻预设表。
function MP.has_config(body_id)
    if not body_id then return false end
    local now = os.clock()
    local cached = MP.presence[body_id]
    if cached and (now - cached.time) < MP.presence_ttl then
        return cached.value
    end
    local cfg = get_runtime_config(body_id)
    local value = false
    if cfg then
        if cfg.presets and next(cfg.presets) ~= nil then
            value = true
        elseif cfg.groups then
            for _, g_data in pairs(cfg.groups) do
                if g_data and g_data.presets and next(g_data.presets) ~= nil then
                    value = true
                    break
                end
            end
        end
    end
    MP.presence[body_id] = { value = value, time = now }
    return value
end

-- 非本地玩家的武器部件查找限频（武器部件的递归查找偏贵）
function MP.scan_allowed(player_obj, is_local)
    if is_local then return true end
    local interval = tonumber(global_config.multiplayer_weapon_scan_interval) or 2.0
    local addr = tostring(player_obj)
    local now = os.clock()
    local last = MP.scan_time[addr]
    if last and (now - last) < interval then return false end
    MP.scan_time[addr] = now
    return true
end

-- ============================================================================
--  单轮处理一个玩家（防具 + 武器）—— CG 与非 CG 共用同一份实现
-- ----------------------------------------------------------------------------
--  entry = { obj = GameObject, player = snow.player.Player 或 nil,
--            index = getPlayerIndex() 或 nil, is_local = bool }
--  cg_mode = true 表示这是过场里的角色：跳过规则评估，直接套用当前意图
--            （保持 v3.0.6 的轻量行为）
--
--  - 联机的两条关键改动都在这里：
--     1. 规则评估会把「这名玩家自己」的 handle 传下去
--        （武器类型 / 各武器状态都读他自己的，而不是永远读主角的）；
--     2. 没有差分配置的玩家直接跳过，避免给队友白跑一遍 apply_all_defaults。
-- ============================================================================
function MP.process(entry, cg_mode)
    if not entry then return end
    local player_obj = entry.obj
    if not (player_obj and safe_object_alive(player_obj)) then return end
    local player_handle = entry.player
    if player_handle and not safe_object_alive(player_handle) then return end
    local is_local = entry.is_local == true
    -- 性能诊断分段名：本地玩家与其他玩家分开统计，
    -- 打开 debug_profile 后一眼就能看出掉帧到底是谁的开销。
    local phase_armor = is_local and "player_armor" or "other_armor"
    local phase_weapon = is_local and "player_weapon" or "other_weapon"

    -- ============================================================
    -- 防具
    -- ============================================================
    local t_armor = Profiler.begin(phase_armor)
    -- - body_id 走 TTL 缓存（照搬荒野的 body_id_cache）：
    --   否则每个处理周期都要为每个玩家遍历一遍子物体（≈36 次托管调用）。
    local armor_id = PlayerDir.body_id_of(player_obj)
    if armor_id and (is_local or MP.has_config(armor_id)) then
        local armor_config = get_runtime_config(armor_id)
        -- - 必须先初始化「默认意图」再评估变身规则：
        --   变身规则是把目标预设**合并到**当前意图上的，若这里是空的 {},
        --   那些没有被任何规则引用到的默认材质就会丢失（与 v3.0.6 行为不一致）。
        if not active_overrides[armor_id] then
            apply_all_defaults(armor_id)
        end
        if armor_config and armor_config.enable_transform and not cg_mode then
            local char_addr = tostring(player_obj)
            local new_overrides, changed, activated_targets, all_targeted_groups =
                TransformManager.apply_transform_rules(
                    char_addr, "armor_" .. armor_id, armor_config, player_obj,
                    active_overrides[armor_id] or {}, merge_overrides, player_handle)
            if not active_group_presets[armor_id] then active_group_presets[armor_id] = {} end
            if activated_targets then
                for g_name, p_name in pairs(activated_targets) do
                    active_group_presets[armor_id][g_name] = p_name
                end
            end

            if armor_config.groups then
                for g_name, g_data in pairs(armor_config.groups) do
                    if g_data.is_global then
                        if activated_targets and activated_targets[g_name] then
                            active_group_presets[armor_id][g_name] = activated_targets[g_name]
                        elseif all_targeted_groups and all_targeted_groups[g_name] then
                            active_group_presets[armor_id][g_name] = g_data.default_preset or ""
                        end
                    end
                end
            end

            if changed then
                active_overrides[armor_id] = new_overrides
                bump_overrides_version(armor_id)
            end
            apply_preset_to_character(player_obj, new_overrides, true, armor_id)
        else
            -- CG 角色 / 未启用变身规则：直接套用当前意图
            apply_preset_to_character(player_obj, active_overrides[armor_id], true, armor_id)
        end
    end
    Profiler.finish(phase_armor, t_armor)

    -- ============================================================
    -- 武器
    -- ============================================================
    local t_weapon = Profiler.begin(phase_weapon)
    if is_local or MP.scan_allowed(player_obj, false) then
        local weapon_id = get_weapon_attack_part_name(player_obj, player_handle)
        if weapon_id and (is_local or MP.has_config(weapon_id)) then
            local weapon_config = get_runtime_config(weapon_id)
            if not active_overrides[weapon_id] then
                apply_all_defaults(weapon_id)
            end
            local weapon_parts = get_cached_weapon_parts(player_obj, player_handle)
            if weapon_parts then
                if weapon_config and weapon_config.enable_transform and not cg_mode then
                    local char_addr = tostring(player_obj)
                    local new_overrides, changed, activated_targets, all_targeted_groups =
                        TransformManager.apply_transform_rules(
                            char_addr, "weapon_" .. weapon_id, weapon_config, player_obj,
                            active_overrides[weapon_id] or {}, merge_overrides, player_handle)
                    if not active_group_presets[weapon_id] then active_group_presets[weapon_id] = {} end
                    if activated_targets then
                        for g_name, p_name in pairs(activated_targets) do
                            active_group_presets[weapon_id][g_name] = p_name
                        end
                    end

                    if weapon_config.groups then
                        for g_name, g_data in pairs(weapon_config.groups) do
                            if g_data.is_global then
                                if activated_targets and activated_targets[g_name] then
                                    active_group_presets[weapon_id][g_name] = activated_targets[g_name]
                                elseif all_targeted_groups and all_targeted_groups[g_name] then
                                    active_group_presets[weapon_id][g_name] = g_data.default_preset or ""
                                end
                            end
                        end
                    end

                    if changed then
                        active_overrides[weapon_id] = new_overrides
                        bump_overrides_version(weapon_id)
                    end
                    apply_preset_to_weapon(weapon_parts, new_overrides, true, weapon_id, player_obj)
                else
                    if active_overrides[weapon_id] then
                        apply_preset_to_weapon(weapon_parts, active_overrides[weapon_id], true, weapon_id, player_obj)
                    end
                end
            end
        end
    end
    Profiler.finish(phase_weapon, t_weapon)
end

-- 联机：其他玩家的轮询下标 + CG 事件玩家的 entry 复用表，都在 MP 表里
-- （MP.next_index / MP.cg_buffer，见上面 MP 的定义）

local function avm_frame_update()
    Profiler.enter_frame()
    local plugin_t0 = Profiler.begin("plugin_frame")

    -- 新版 UI 的每帧输入 / 开关处理（未启用时内部会立即返回）
    local t_ui_update = Profiler.begin("ui_update")
    variant_manager_ui:update()
    Profiler.finish("ui_update", t_ui_update)

    -- 帧计数器递增
    global_frame_counter = global_frame_counter + 1
    if global_frame_counter > 1000000 then
        global_frame_counter = 1
    end

    -- ====================================================================
    -- 场景扫描（增量式，非阻塞）
    -- --------------------------------------------------------------------
    -- - 只有在「确实没有本地玩家」时才推进扫描：正常游玩（据点/任务里
    --   findMasterPlayer 正常）这一段每帧只做一次「本地玩家对象是否还活着」
    --   的判断，不产生任何其它开销。
    --   旧实现是「一次性全场景扫描」，野外要遍历约 8000 个组件、单次几十毫秒，
    --   联机时只要短暂拿不到 master 就会出现肉眼可见的尖峰。
    -- ====================================================================
    if PlayerDir.local_entry == nil
        or not safe_object_alive(PlayerDir.local_entry.obj) then
        PlayerDir.scan_tick()
    end

    -- ====================================================================
    -- 获取事件玩家列表（CG角色），每5帧刷新一次
    -- ====================================================================
    local event_players
    local has_event_players
    if global_frame_counter % 5 == 0 then
        local t_event = Profiler.begin("event_players_poll")
        event_players = get_event_players()
        has_event_players = (#event_players > 0)
        Profiler.finish("event_players_poll", t_event)
        -- 检测事件玩家列表变化（进入或离开CG），重置所有缓存
        if has_event_players ~= last_has_event_players then
            Applied.clear()
            PlayerDir.reset()
            invalidate_primary_body_id()
            part_cache = {}
            weapon_part_cache = {}
            PlayerDir.scan_reset()
            overrides_version = {}
            if TransformManager.clear_cache then TransformManager.clear_cache() end
            current_group_name = ""
            active_overrides = {}
            active_group_presets = {}
            update_preset_names_list()
            update_group_names_list()
            -- - 无论进还是出过场，CG 节流记录都要清掉：
            --   新一场过场的角色必须**立刻**拿到差分，不能被上一场的节流记录挡住
            --   （这正是「事件主角初次登场是无预设状态」的另一个成因）。
            Applied.reset_cg()
            if not has_event_players then
                special_cg_next_index = 1  -- 重置轮询索引
            end
            last_has_event_players = has_event_players
        end
        -- 缓存当前结果
        cached_event_players = event_players
        cached_has_event_players = has_event_players
    else
        event_players = cached_event_players or EMPTY_PLAYER_LIST
        has_event_players = cached_has_event_players or false
    end
    -- 更新全局CG标志（供 apply_preset_to_character 等使用）
    g_is_special_cg = has_event_players

    -- ====================================================================
    -- 确定要处理的玩家
    -- --------------------------------------------------------------------
    --  - v3.1.0 起，玩家身份由玩家目录统一给出：
    --      * 本地玩家 = PlayerList 中 getPlayerIndex() == findMasterPlayer() 的那一个；
    --      * 其他玩家 = 列表里剩下的（联机队友）。
    --    旧实现在这里退化成「列表里第一个像玩家的对象」，联机时会把队友当成主角。
    --
    --  - 处理顺序与预算：
    --      * 本地玩家：每轮都处理（响应速度和单人时完全一样）；
    --      * 其他玩家：每轮最多处理 multiplayer_players_per_tick 个，轮询推进，
    --        并且没有差分配置的会被 MP.has_config 直接挡掉。
    --        这样联机时的额外开销是「可预期的常数」，而不是随人数线性增长。
    -- ====================================================================
    local local_entry = nil
    local targets = nil
    if not has_event_players then
        local dir = PlayerDir.get()
        local_entry = dir.local_entry
        targets = dir.entries
    end

    -- ====================================================================
    -- 首次刷新（仅针对本地玩家，且只执行一次）
    -- 模拟面板展开操作：调用 load_body_config 强制重新加载配置
    -- 该操作不受降频影响，以确保启动时立即生效
    -- ====================================================================
    local local_player = get_primary_player()
    if local_player and not first_apply_done then
        local t_first_apply = Profiler.begin("first_apply")
        local armor_id = get_character_body_id(local_player)
        if armor_id then
            -- 强制重新加载配置（从磁盘读取，模拟面板展开）
            load_body_config(armor_id)
            -- 应用当前 UI 选中的预设
            local current_preset_name = preset_names_list[selected_preset_index]
            if current_preset_name then
                apply_preset(current_preset_name)
            end
            -- 强制触发一次规则评估，确保当前状态正确
            local armor_config = get_runtime_config(armor_id)
            if armor_config and armor_config.enable_transform then
                local char_addr = tostring(local_player)
                local player_handle = local_entry and local_entry.player or nil
                local new_overrides, changed, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                    char_addr, "armor_" .. armor_id, armor_config, local_player,
                    active_overrides[armor_id] or {}, merge_overrides, player_handle
                )
                if not active_group_presets[armor_id] then active_group_presets[armor_id] = {} end
                if activated_targets then
                    for g_name, p_name in pairs(activated_targets) do
                        active_group_presets[armor_id][g_name] = p_name
                    end
                end
                if changed then
                    active_overrides[armor_id] = new_overrides
                    bump_overrides_version(armor_id)
                    apply_preset_to_character(local_player, new_overrides, true)
                else
                    apply_preset_to_character(local_player, new_overrides, true)
                end
            end
        end
        first_apply_done = true
        Profiler.finish("first_apply", t_first_apply)
    end

    -- ====================================================================
    -- CG 场景（有事件玩家）：降频 + 轮询处理
    --   过场里的角色不是 snow.player.Player，拿不到「他自己的」武器状态，
    --   所以沿用 v3.0.6 的轻量做法：跳过规则评估，直接套用当前意图。
    -- ====================================================================
    if has_event_players then
        local t_cg_block = Profiler.begin("cg_block")
        if global_frame_counter % SPECIAL_CG_UPDATE_INTERVAL == 0 then
            local cg_count = #event_players
            if cg_count > 0 then
                for i = #MP.cg_buffer, 1, -1 do MP.cg_buffer[i] = nil end
                for i = 1, cg_count do
                    MP.cg_buffer[i] = { obj = event_players[i], is_local = false, is_event = true }
                end
                if special_cg_next_index > cg_count then special_cg_next_index = 1 end
                local start_idx = special_cg_next_index
                local end_idx = math.min(start_idx + SPECIAL_CG_PLAYERS_PER_FRAME - 1, cg_count)
                for i = start_idx, end_idx do
                    MP.process(MP.cg_buffer[i], true)
                end
                special_cg_next_index = end_idx + 1
                if special_cg_next_index > cg_count then special_cg_next_index = 1 end
            end
        end
        Profiler.finish("cg_block", t_cg_block)
    elseif global_frame_counter % NORMAL_UPDATE_INTERVAL == 0 then
        -- ================================================================
        -- 正常游玩（非 CG）
        -- ================================================================
        local t_noncg_block = Profiler.begin("noncg_block")

        -- 1) 本地玩家（主角）：每轮都处理，响应速度与单机完全一致
        if local_entry and safe_object_alive(local_entry.obj) then
            MP.process(local_entry, false)
            Profiler.count("players_processed_local")
        elseif local_player then
            -- 玩家目录这一拍没给出本地玩家（读图 / 切场景）：用主角对象兜一下
            MP.process({ obj = local_player, is_local = true }, false)
            Profiler.count("players_processed_local_fallback")
        end

        -- 2) 其他玩家（联机队友）
        -- ------------------------------------------------------------------
        --  - 单独用一个**更慢**的节奏：队友身上的差分变化不需要 14 次/秒，
        --    肉眼能分辨的延迟在 0.2 秒以上。这里用 MULTIPLAYER_UPDATE_INTERVAL
        --    帧推进一次（默认 30 帧 ≈ 0.2 秒 @144fps），每次只处理预算内的 1 人。
        --    于是「其他玩家」的总开销被压到本地玩家的 1/3 以下，
        --    而且与具体人数无关（轮询保证每个人都会被轮到）。
        -- ------------------------------------------------------------------
        if global_config.enable_multiplayer ~= false and targets
            and global_frame_counter % MULTIPLAYER_UPDATE_INTERVAL == 0 then
            local others = PlayerDir.others
            local other_count = #others
            if other_count > 0 then
                local budget = tonumber(global_config.multiplayer_players_per_tick) or 1
                if budget < 0 then budget = 0 end
                if budget > other_count then budget = other_count end
                for _ = 1, budget do
                    if MP.next_index > other_count then MP.next_index = 1 end
                    local entry = others[MP.next_index]
                    MP.next_index = MP.next_index + 1
                    MP.process(entry, false)
                    Profiler.count("players_processed_other")
                end
            else
                MP.next_index = 1
            end
        end
        Profiler.finish("noncg_block", t_noncg_block)
    end

    Profiler.finish("plugin_frame", plugin_t0)
end

re.on_frame(function()
    run_frame_quietly(avm_frame_update)
end)

-- 性能诊断：脚本被重置前先把最后一个窗口写出去
re.on_script_reset(function()
    if Profiler.enabled then Profiler.flush() end
end)

-- ========== UI 绘制（使用主玩家） ==========
local current_config_body_id = nil

re.on_draw_ui(function()
    if imgui.tree_node(T("mod_name")) then
        imgui.text_colored(string.format(T("version") .. ": %s | " .. T("author") .. ": %s", version, author), 0xFF808080)
        imgui.separator()
        -- 新版独立 UI：启用时跳过旧版 ImGui 面板（两者共用同一份配置与预设文件）
        if variant_manager_ui:draw_settings() then
            imgui.tree_pop()
            return
        end

        local status, err = pcall(function()
            local primary = get_primary_player()
            if primary then
                local body_id = get_primary_body_id()
                if body_id then
                    if current_config_body_id ~= body_id then
                        local config = loaded_configs[body_id]
                        if config then
                            for k, v in pairs(config) do
                                current_config[k] = deep_copy_table(v)
                            end
                            current_config_body_id = body_id
                            update_preset_names_list()
                            update_group_names_list()
                        else
                            load_body_config(body_id)
                            current_config_body_id = body_id
                        end
                    end

                    -- 模式切换
                    local armor_mode_text = T("armor_mode") or "Armor Variant"
                    local weapon_mode_text = T("weapon_mode") or "Weapon Variant"
                    local changed_armor, new_armor = imgui.checkbox(armor_mode_text, not is_weapon_mode)
                    if changed_armor and new_armor then
                        if is_weapon_mode ~= false then
                            is_weapon_mode = false
                            last_body_id = nil
                            last_weapon_type = nil
                            refresh_player_list()
                            local new_body_id = get_primary_body_id()
                            if new_body_id then
                                active_overrides[new_body_id] = nil
                                loaded_configs[new_body_id] = nil
                                load_body_config(new_body_id)
                                current_config_body_id = new_body_id
                            end
                            update_preset_names_list()
                            update_group_names_list()
                        end
                    end
                    imgui.same_line()
                    local changed_weapon, new_weapon = imgui.checkbox(weapon_mode_text, is_weapon_mode)
                    if changed_weapon and new_weapon then
                        if is_weapon_mode ~= true then
                            is_weapon_mode = true
                            last_body_id = nil
                            last_weapon_type = nil
                            refresh_player_list()
                            local new_body_id = get_primary_body_id()
                            if new_body_id then
                                active_overrides[new_body_id] = nil
                                loaded_configs[new_body_id] = nil
                                load_body_config(new_body_id)
                                current_config_body_id = new_body_id
                            end
                            update_preset_names_list()
                            update_group_names_list()
                        end
                    end
                    imgui.separator()

                    -- 预设管理区域
                    if force_open_presets_node then
                        imgui.set_next_item_open(true)
                        force_open_presets_node = false
                    end

                    local group_suffix = ""
                    if current_group_name ~= "" then
                        local g_data = current_config.groups and current_config.groups[current_group_name]
                        if g_data and g_data.is_global then
                            group_suffix = " " .. T("global_group_label")
                        end
                    end
                    if imgui.tree_node(T("presets_manager") .. " (" .. body_id .. ")" .. group_suffix) then
                        if config_restored[body_id] and not config_restore_handled[body_id] then
                            imgui.text_colored(T("config_restored_warning") or "Your local preset has been changed. Restore from backup?", 0xFF00CCFF)
                            if imgui.button(T("restore_from_backup") or "Restore My Changes") then
                                config_restore_handled[body_id] = true
                                restore_config_from_backup(body_id)
                            end
                            imgui.same_line()
                            if imgui.button(T("dismiss") or "Dismiss") then
                                config_restore_handled[body_id] = true
                                config_restored[body_id] = nil
                            end
                            imgui.separator()
                        end

                        -- 分组下拉列表
                        local full_group_list = {T("main_list")}
                        for _, gname in ipairs(group_names_list) do
                            local g_data = current_config.groups and current_config.groups[gname]
                            if g_data and g_data.is_global then
                                table.insert(full_group_list, T("global_group_label") .. " " .. gname)
                            else
                                table.insert(full_group_list, gname)
                            end
                        end
                        local current_group_combo_index = 1
                        if current_group_name ~= "" then
                            for i, gname in ipairs(group_names_list) do
                                if gname == current_group_name then current_group_combo_index = i + 1 break end
                            end
                        end

                        if imgui.begin_table("PresetsLayout", 2, 512) then
                            imgui.table_setup_column("PresetArea", 2048, 1.0)
                            imgui.table_setup_column("GroupArea", 2048, 1.0)
                            imgui.table_next_row()
                            imgui.table_next_column()
                            imgui.text(T("preset") .. ":")
                            imgui.table_next_column()
                            imgui.text(T("group") .. ":")
                            imgui.table_next_row()
                            imgui.table_next_column()
                            imgui.set_next_item_width(-1)
                            if #preset_names_list > 0 then
                                local changed_idx, idx = imgui.combo("##preset_selector", selected_preset_index, preset_names_list)
                                if changed_idx then
                                    selected_preset_index = idx
                                    local current_preset_name = preset_names_list[selected_preset_index]
                                    if current_preset_name then apply_preset(current_preset_name) end
                                end
                            else
                                imgui.text_colored("[" .. T("no_presets") .. "]", 0xFF808080)
                            end
                            imgui.table_next_column()
                            imgui.set_next_item_width(-1)
                            local changed_g, g_idx = imgui.combo("##group_selector", current_group_combo_index, full_group_list)
                            if changed_g then
                                current_group_name = (g_idx == 1) and "" or group_names_list[g_idx - 1]
                                selected_group_index = g_idx
                                update_preset_names_list()
                            end
                            imgui.table_next_row()
                            imgui.table_next_column()
                            if #preset_names_list > 0 then
                                local current_preset_name = preset_names_list[selected_preset_index]
                                local ctx_default = (current_group_name == "") and current_config.default_preset or
                                                   (current_config.groups[current_group_name] and current_config.groups[current_group_name].default_preset)
                                if imgui.button(T("delete_preset")) then
                                    if current_group_name == "" then
                                        current_config.presets[current_preset_name] = nil
                                        if current_config.default_preset == current_preset_name then current_config.default_preset = "" end
                                        if current_config.preset_order then
                                            for pi = #current_config.preset_order, 1, -1 do
                                                if current_config.preset_order[pi] == current_preset_name then
                                                    table.remove(current_config.preset_order, pi); break
                                                end
                                            end
                                        end
                                    else
                                        if current_config.groups[current_group_name] then
                                            current_config.groups[current_group_name].presets[current_preset_name] = nil
                                            if current_config.groups[current_group_name].default_preset == current_preset_name then
                                                current_config.groups[current_group_name].default_preset = ""
                                            end
                                            if current_config.groups[current_group_name].preset_order then
                                                for pi = #current_config.groups[current_group_name].preset_order, 1, -1 do
                                                    if current_config.groups[current_group_name].preset_order[pi] == current_preset_name then
                                                        table.remove(current_config.groups[current_group_name].preset_order, pi); break
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    update_preset_names_list()
                                    save_current_config_to_file(body_id)
                                end
                                imgui.same_line()
                                if imgui.button(T("set_as_default")) then
                                    if current_group_name == "" then
                                        current_config.default_preset = current_preset_name
                                    else
                                        if current_config.groups[current_group_name] then current_config.groups[current_group_name].default_preset = current_preset_name end
                                    end
                                    save_current_config_to_file(body_id)
                                end
                                if ctx_default == current_preset_name then
                                    imgui.same_line()
                                    imgui.text_colored(T("is_default"), 0xFF00FF00)
                                else
                                    imgui.same_line()
                                    imgui.text_colored(T("selected_not_default"), 0xFF00CCFF)
                                end
                                imgui.same_line()
                                if imgui.button(T("sort") .. "##p_sort") then
                                    sort_mode = "preset"
                                    sort_temp_list = {}
                                    for _, pn in ipairs(preset_names_list) do
                                        table.insert(sort_temp_list, pn)
                                    end
                                    sort_selected_index = selected_preset_index
                                    force_open_presets_node = true
                                end
                            end
                            imgui.spacing()
                            imgui.text(T("create_new_preset"))
                            imgui.set_next_item_width(-1)
                            local cp, ptext = imgui.input_text("##new_preset_name_input", new_preset_name)
                            if cp then new_preset_name = ptext end
                            if imgui.button(T("save_preset") .. "##p_left") then
                                if new_preset_name ~= "" then
                                    if save_preset(new_preset_name, body_id) then
                                        new_preset_name = ""
                                        update_preset_names_list()
                                    end
                                end
                            end
                            if #preset_names_list > 0 then
                                imgui.same_line()
                                if imgui.button(T("overwrite_preset") .. "##p_overwrite") then
                                    local current_preset_name = preset_names_list[selected_preset_index]
                                    if current_preset_name and current_preset_name ~= "" then
                                        save_preset(current_preset_name, body_id)
                                    end
                                end
                            end
                            imgui.table_next_column()
                            if not is_selection_mode then
                                if imgui.button(T("start_selection") .. "##right") then
                                    is_selection_mode = true
                                    pending_material_selections = {}
                                end
                                if current_group_name ~= "" then
                                    imgui.same_line()
                                    if imgui.button(T("delete_group") .. "##right") then
                                        delete_group(current_group_name, body_id)
                                    end
                                end
                                if current_config.groups and next(current_config.groups) then
                                    imgui.same_line()
                                    if imgui.button(T("sort") .. "##g_sort") then
                                        sort_mode = "group"
                                        sort_temp_list = {}
                                        for _, gn in ipairs(group_names_list) do
                                            table.insert(sort_temp_list, gn)
                                        end
                                        sort_selected_index = 1
                                        if current_group_name ~= "" then
                                            for gi, gn in ipairs(sort_temp_list) do
                                                if gn == current_group_name then sort_selected_index = gi; break end
                                            end
                                        end
                                        force_open_presets_node = true
                                    end
                                end
                            else
                                imgui.text_colored(T("selection_mode") .. " ", 0xFF00FFFF)
                                imgui.text_colored(T("selection_mode_desc") .. " ", 0xFF00FFFF)
                                local cg, gtext = imgui.input_text(T("name") .. "##gn", new_group_name)
                                if cg then new_group_name = gtext end
                                local cg_global, new_is_global = imgui.checkbox(T("is_global_group") .. "##gisgl", new_group_is_global)
                                if cg_global then new_group_is_global = new_is_global end
                                if new_group_is_global then
                                    imgui.same_line()
                                    imgui.text_colored(T("is_global_group_desc"), 0xFF80FFFF)
                                end
                                if imgui.button(T("confirm_creation") .. "##gconfirm") then
                                    if new_group_name ~= "" and create_new_group(new_group_name, body_id, new_group_is_global) then
                                        current_group_name = new_group_name
                                        new_group_name = ""
                                        new_group_is_global = false
                                        is_selection_mode = false
                                        update_group_names_list()
                                        update_preset_names_list()
                                    end
                                end
                                imgui.same_line()
                                if imgui.button(T("cancel") .. "##gcancel") then
                                    is_selection_mode = false
                                    new_group_is_global = false
                                end
                            end
                            imgui.end_table()
                        end

                        -- 分组材质预览
                        if current_group_name ~= "" then
                            local group_data = current_config.groups[current_group_name]
                            if group_data then
                                local group_type = group_data.is_global and (" " .. T("global_group_label")) or ""
                                if group_data and group_data.mask and imgui.tree_node(T("materials") .. " in " .. current_group_name .. group_type) then
                                    for p_idx, mats in pairs(group_data.mask) do
                                        local part_name = T(PART_INDEX_TO_NAME[tonumber(p_idx)]) or p_idx
                                        for m_name, _ in pairs(mats) do
                                            imgui.text("  • [" .. part_name .. "] " .. tostring(m_name))
                                        end
                                    end
                                    imgui.tree_pop()
                                end
                            end
                        end

                        local has_any_data = (next(current_config.presets) ~= nil)
                        if not has_any_data and current_config.groups then
                            for _, g in pairs(current_config.groups) do
                                if g.presets and next(g.presets) then has_any_data = true break end
                            end
                        end
                        if not has_any_data then
                            imgui.separator()
                            if imgui.button(T("auto_find_preset")) then
                                local st, res, m = pcall(find_auto_preset, body_id)
                                auto_find_log = st and (res and m or "Failed: " .. m) or "Lua Error: " .. tostring(res)
                            end
                            if auto_find_log ~= "" then imgui.text_colored(auto_find_log, 0xFF00FFFF) end
                        end

-- ================== 手动查找预设（防具模式专用） ==================
if not is_weapon_mode then
    imgui.separator()
    if imgui.button(T("manual_find_preset")) then
        show_manual_selector = not show_manual_selector
        if show_manual_selector then
            -- 扫描所有预设文件
            manual_files = {}
            manual_file_names = {}
            local search_patterns = {
                "reframework/data/ArmorVariantManager/.*\\.json",
                "reframework\\data\\ArmorVariantManager\\.*\\.json",
                "ArmorVariantManager/.*\\.json",
                "ArmorVariantManager\\\\.*\\.json",
                "data/ArmorVariantManager/.*\\.json"
            }
            local all_files = {}
            for _, pattern in ipairs(search_patterns) do
                local found = fs.glob(pattern)
                if found and #found > 0 then
                    for _, f in ipairs(found) do
                        table.insert(all_files, f)
                    end
                end
            end

            -- 统一路径格式：去掉 reframework/data/ 前缀，统一使用 "ArmorVariantManager/xxx.json"
            local normalized_files = {}
            for _, f in ipairs(all_files) do
                local norm = f
                -- 去掉 reframework\data\ 或 reframework/data/ 前缀
                norm = string.gsub(norm, "^[Rr]eframework[/\\][Dd]ata[/\\]", "")
                norm = string.gsub(norm, "^[Dd]ata[/\\]", "")
                -- 确保以 ArmorVariantManager/ 开头
                if not string.match(norm, "^[Aa]rmor[Vv]ariant[Mm]anager[/\\]") then
                    norm = "ArmorVariantManager/" .. norm
                end
                -- 统一使用正斜杠
                norm = string.gsub(norm, "\\", "/")
                table.insert(normalized_files, norm)
            end

            -- 去重
            local seen = {}
            local unique_files = {}
            for _, f in ipairs(normalized_files) do
                if not seen[f] then
                    seen[f] = true
                    table.insert(unique_files, f)
                end
            end

            -- 构建武器前缀集合
            local weapon_prefixes = {}
            for _, parts in pairs(Utils.WEAPON_PARTS_MAP) do
                for _, part in ipairs(parts) do
                    weapon_prefixes[part.prefix] = true
                end
            end

            -- 过滤武器预设（根据文件名前缀）
            local filtered = {}
            for _, f in ipairs(unique_files) do
                local name = string.match(f, "([^/\\]+)%.json$") or f
                local is_weapon = false
                for prefix, _ in pairs(weapon_prefixes) do
                    if string.sub(name, 1, #prefix) == prefix then
                        is_weapon = true
                        break
                    end
                end
                if not is_weapon then
                    table.insert(filtered, f)
                end
            end

            -- 按 f_body 前缀分组排序（先正常，后 f_body）
            local normal = {}
            local fbody = {}
            for _, f in ipairs(filtered) do
                local name = string.match(f, "([^/\\]+)%.json$") or f
                if string.sub(name, 1, 6) == "f_body" then
                    table.insert(fbody, f)
                else
                    table.insert(normal, f)
                end
            end
            table.sort(normal)
            table.sort(fbody)

            -- ====== 新增：主路径优先 + 备份标注逻辑 ======
            -- 先合并所有文件
            local all_sorted = {}
            for _, f in ipairs(normal) do table.insert(all_sorted, f) end
            for _, f in ipairs(fbody) do table.insert(all_sorted, f) end

            -- 按文件名分组，优先选择主路径，备份路径做标注
            local file_groups = {}  -- key: 文件名, value: { main_path, backup_path }
            for _, f in ipairs(all_sorted) do
                local name = string.match(f, "([^/\\]+)%.json$") or f
                local is_backup = string.find(f, "/backup/") ~= nil
                if not file_groups[name] then
                    file_groups[name] = { main_path = nil, backup_path = nil }
                end
                if is_backup then
                    file_groups[name].backup_path = f
                else
                    file_groups[name].main_path = f
                end
            end

            -- 重新构建 manual_files 和显示名称
            manual_files = {}
            manual_file_names = {}
            for name, paths in pairs(file_groups) do
                if paths.main_path then
                    -- 有主路径：优先使用主路径，显示纯文件名
                    table.insert(manual_files, paths.main_path)
                    table.insert(manual_file_names, name)
                elseif paths.backup_path then
                    -- 只有备份路径：使用备份路径，显示带 [备份] 标识的文件名
                    table.insert(manual_files, paths.backup_path)
                    table.insert(manual_file_names, "[备份] " .. name)
                end
            end

            -- 按原始排序规则重新排序（先 normal，后 f_body）
            -- 由于我们重新构建了列表，需要重新按类型排序
            local normal_final = {}
            local fbody_final = {}
            for i, f in ipairs(manual_files) do
                local name = string.match(f, "([^/\\]+)%.json$") or f
                if string.sub(name, 1, 6) == "f_body" then
                    table.insert(fbody_final, i)
                else
                    table.insert(normal_final, i)
                end
            end
            table.sort(normal_final)
            table.sort(fbody_final)

            local reordered_files = {}
            local reordered_names = {}
            for _, idx in ipairs(normal_final) do
                table.insert(reordered_files, manual_files[idx])
                table.insert(reordered_names, manual_file_names[idx])
            end
            for _, idx in ipairs(fbody_final) do
                table.insert(reordered_files, manual_files[idx])
                table.insert(reordered_names, manual_file_names[idx])
            end
            manual_files = reordered_files
            manual_file_names = reordered_names

            if #manual_files > 0 then
                selected_manual_file_index = 1
            end
            manual_load_error = ""
        end
    end

    if show_manual_selector then
        imgui.indent(20)
        if #manual_files > 0 then
            imgui.set_next_item_width(200)
            local changed, idx = imgui.combo("##manual_file_selector", selected_manual_file_index, manual_file_names)
            if changed then
                selected_manual_file_index = idx
            end
            imgui.same_line()
            if imgui.button(T("load_selected_preset")) then
                local file_path = manual_files[selected_manual_file_index]
                if file_path then
                    -- 尝试多种路径加载
                    local data = json.load_file(file_path)
                    if not data then
                        data = json.load_file("reframework/data/" .. file_path)
                    end
                    if not data then
                        local alt_path = string.gsub(file_path, "^[Aa]rmor[Vv]ariant[Mm]anager[/\\]", "")
                        data = json.load_file(alt_path)
                    end
                    if data and type(data) == "table" then
                        current_config = data
                        save_current_config_to_file(body_id)
                        update_preset_names_list()
                        update_group_names_list()
                        apply_all_defaults(body_id)
                        local primary_apply = get_primary_player()
                        if primary_apply then
                            if is_weapon_mode then
                                local weapon_parts = Utils.get_current_weapon_parts(primary_apply)
                                if weapon_parts then
                                    apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                                end
                            else
                                apply_preset_to_character(primary_apply, active_overrides[body_id], true)
                            end
                        end
                        show_manual_selector = false
                        manual_load_error = ""
                    else
                        manual_load_error = T("load_failed") or "Failed to load file: " .. tostring(file_path)
                    end
                end
            end
            imgui.same_line()
            if imgui.button(T("cancel")) then
                show_manual_selector = false
            end
            if manual_load_error ~= "" then
                imgui.text_colored(manual_load_error, 0xFF0000FF)
            end
        else
            imgui.text_colored(T("no_preset_files") or "No preset files found", 0xFF808080)
        end
        imgui.unindent(20)
    end
end
-- ================== 手动查找结束 ==================

                        imgui.tree_pop() -- 预设管理树节点结束
                    end

                    -- 排序界面
                    if sort_mode then
                        imgui.separator()
                        local sort_title = (sort_mode == "group") and (T("sort") .. " - " .. T("group")) or (T("sort") .. " - " .. T("preset"))
                        imgui.text_colored(sort_title, 0xFF00FFFF)
                        imgui.spacing()
                        if #sort_temp_list == 0 then
                            imgui.text_colored(T("no_items_to_sort") or "No items to sort.", 0xFF808080)
                        else
                            if sort_selected_index and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                imgui.text_colored(T("sort_hint_selected") .. ": " .. sort_temp_list[sort_selected_index], 0xFFFFFF80)
                            else
                                imgui.text_colored(T("sort_hint_click"), 0xFF808080)
                            end
                            imgui.spacing()
                            for si, sname in ipairs(sort_temp_list) do
                                if si <= 1 then imgui.begin_disabled() end
                                if imgui.button(T("move_up") .. "##su_" .. si) then
                                    if si > 1 then
                                        sort_temp_list[si], sort_temp_list[si - 1] = sort_temp_list[si - 1], sort_temp_list[si]
                                        if sort_selected_index == si then sort_selected_index = si - 1
                                        elseif sort_selected_index == si - 1 then sort_selected_index = si end
                                    end
                                end
                                if si <= 1 then imgui.end_disabled() end
                                imgui.same_line()
                                if si >= #sort_temp_list then imgui.begin_disabled() end
                                if imgui.button(T("move_down") .. "##sd_" .. si) then
                                    if si < #sort_temp_list then
                                        sort_temp_list[si], sort_temp_list[si + 1] = sort_temp_list[si + 1], sort_temp_list[si]
                                        if sort_selected_index == si then sort_selected_index = si + 1
                                        elseif sort_selected_index == si + 1 then sort_selected_index = si end
                                    end
                                end
                                if si >= #sort_temp_list then imgui.end_disabled() end
                                imgui.same_line()
                                if si == sort_selected_index then
                                    imgui.push_style_color(21, 0xFF00AAFF)
                                end
                                if imgui.button(tostring(si) .. ". " .. sname .. "##sn_" .. si) then
                                    sort_selected_index = si
                                end
                                if si == sort_selected_index then
                                    imgui.pop_style_color(1)
                                end
                                if sort_selected_index and sort_selected_index ~= si and sort_selected_index >= 1 and sort_selected_index <= #sort_temp_list then
                                    imgui.same_line()
                                    if imgui.button(T("sort_insert_here") .. "##si_" .. si) then
                                        local item = table.remove(sort_temp_list, sort_selected_index)
                                        table.insert(sort_temp_list, si, item)
                                        sort_selected_index = si
                                    end
                                end
                            end
                        end
                        imgui.spacing()
                        if imgui.button(T("sort_confirm") .. "##sort_ok") then
                            if sort_mode == "group" then
                                current_config.group_order = {}
                                for _, gn in ipairs(sort_temp_list) do
                                    table.insert(current_config.group_order, gn)
                                end
                                update_group_names_list()
                            elseif sort_mode == "preset" then
                                if current_group_name == "" then
                                    current_config.preset_order = {}
                                    for _, pn in ipairs(sort_temp_list) do
                                        table.insert(current_config.preset_order, pn)
                                    end
                                else
                                    local g = current_config.groups and current_config.groups[current_group_name]
                                    if g then
                                        g.preset_order = {}
                                        for _, pn in ipairs(sort_temp_list) do
                                            table.insert(g.preset_order, pn)
                                        end
                                    end
                                end
                                update_preset_names_list()
                            end
                            save_current_config_to_file(body_id)
                            sort_mode = nil
                            sort_temp_list = {}
                        end
                        imgui.same_line()
                        if imgui.button(T("sort_cancel") .. "##sort_no") then
                            sort_mode = nil
                            sort_temp_list = {}
                        end
                    end

                    -- 变身管理区域
                    if imgui.tree_node(T("transform_manager")) then
                        local enable_transform = current_config.enable_transform
                        local changed_enable, new_enable = imgui.checkbox(T("enable_transform"), enable_transform)
                        if changed_enable then
                            current_config.enable_transform = new_enable
                            if new_enable then
                                local char_addr = tostring(primary)
                                TransformManager.clear_cache(char_addr)
                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                )
                                active_overrides[body_id] = new_overrides
                                bump_overrides_version(body_id)
                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                if current_config.groups then
                                    for g_name, g_data in pairs(current_config.groups) do
                                        if g_data.is_global then
                                            if activated_targets and activated_targets[g_name] then
                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                            end
                                        end
                                    end
                                end
                                if is_weapon_mode then
                                    local weapon_parts = get_cached_weapon_parts(primary)
                                    if weapon_parts then
                                        apply_preset_to_weapon(weapon_parts, new_overrides, true, body_id)
                                    end
                                else
                                    apply_preset_to_character(primary, new_overrides, true)
                                end
                            else
                                apply_all_defaults(body_id)
                                if active_overrides[body_id] then
                                    if is_weapon_mode then
                                        local weapon_parts = get_cached_weapon_parts(primary)
                                        if weapon_parts then
                                            apply_preset_to_weapon(weapon_parts, active_overrides[body_id], true, body_id)
                                        end
                                    else
                                        apply_preset_to_character(primary, active_overrides[body_id], true)
                                    end
                                end
                            end
                            save_current_config_to_file(body_id)
                        end
                        imgui.separator()
                        if current_config.enable_transform then
                            local current_state_str = TransformManager.get_current_state_display(current_config, primary)
                            if current_state_str ~= "" then
                                imgui.text(T("current_state") .. ": " .. current_state_str)
                                imgui.separator()
                            end
                            local mode_text = current_config.is_parallel and T("current_mode_parallel") or T("current_mode_selection")
                            imgui.text(mode_text)
                            local parallel_btn_text = current_config.is_parallel and T("switch_to_selection") or T("switch_to_parallel")
                            if imgui.button(parallel_btn_text) then
                                current_config.is_parallel = not current_config.is_parallel
                                save_current_config_to_file(body_id)
                            end
                            if not current_config.is_parallel then
                                local c_type_idx = 1
                                if current_config.transform_type == "weapon" then c_type_idx = 1
                                elseif current_config.transform_type == "scroll" then c_type_idx = 2
                                elseif current_config.transform_type == "monster_hp" then c_type_idx = 3
                                elseif current_config.transform_type == "longsword" then c_type_idx = 4
                                elseif current_config.transform_type == "dual_blades" then c_type_idx = 5
                                elseif current_config.transform_type == "switch_axe" then c_type_idx = 6
                                elseif current_config.transform_type == "charge_axe" then c_type_idx = 7
                                elseif current_config.transform_type == "greatsword_level" then c_type_idx = 8
                                elseif current_config.transform_type == "hammer" then c_type_idx = 9
                                elseif current_config.transform_type == "bow" then c_type_idx = 10
                                end
                                local c_type_list = {
                                    T("condition_weapon"), T("condition_scroll"), T("condition_monster_hp"),
                                    T("condition_longsword"), T("condition_dual_blades"), T("condition_switch_axe"),
                                    T("condition_charge_axe"), T("condition_greatsword_level"),
                                    T("condition_hammer"), T("condition_bow")
                                }
                                local c_changed, c_val = imgui.combo(T("transform_condition_type"), c_type_idx, c_type_list)
                                if c_changed then
                                    if c_val == 1 then current_config.transform_type = "weapon"
                                    elseif c_val == 2 then current_config.transform_type = "scroll"
                                    elseif c_val == 3 then current_config.transform_type = "monster_hp"
                                    elseif c_val == 4 then current_config.transform_type = "longsword"
                                    elseif c_val == 5 then current_config.transform_type = "dual_blades"
                                    elseif c_val == 6 then current_config.transform_type = "switch_axe"
                                    elseif c_val == 7 then current_config.transform_type = "charge_axe"
                                    elseif c_val == 8 then current_config.transform_type = "greatsword_level"
                                    elseif c_val == 9 then current_config.transform_type = "hammer"
                                    else current_config.transform_type = "bow" end
                                    save_current_config_to_file(body_id)
                                end

                                -- 武器条件
                                if current_config.transform_type == "weapon" then
                                    for i, rule in ipairs(current_config.weapon_transform_rules) do
                                        imgui.push_id("weapon_rule_" .. i)
                                        imgui.text(rule.state == "sheathed" and T("weapon_sheathed") or T("weapon_drawn"))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "weapon", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##weapon_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 红蓝书
                                elseif current_config.transform_type == "scroll" then
                                    for i, rule in ipairs(current_config.scroll_transform_rules) do
                                        imgui.push_id("scroll_rule_" .. i)
                                        imgui.text(rule.state == "red" and T("scroll_red") or T("scroll_blue"))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "scroll", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##scroll_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 怪物血量
                                elseif current_config.transform_type == "monster_hp" then
                                    local curHP = TransformManager.get_current_raw_state(current_config, primary)
                                    if curHP then
                                        imgui.text(string.format(T("monster_current_hp"), curHP))
                                    else
                                        imgui.text_colored(T("no_monster_target"), 0xFF808080)
                                    end
                                    imgui.separator()
                                    if imgui.button(T("add_hp_node")) then
                                        table.insert(current_config.monster_hp_transform_rules, { threshold = 50, targets = {} })
                                        save_current_config_to_file(body_id)
                                    end
                                    for i, rule in ipairs(current_config.monster_hp_transform_rules) do
                                        imgui.push_id("monster_hp_rule_" .. i)
                                        imgui.set_next_item_width(120)
                                        local c_t, v_t_str = imgui.input_text(T("monster_hp_threshold") .. "##" .. i, tostring(rule.threshold))
                                        if c_t then
                                            local num = tonumber(v_t_str)
                                            if num then
                                                if num < 0 then num = 0 end
                                                if num > 100 then num = 100 end
                                                rule.threshold = num
                                                save_current_config_to_file(body_id)
                                            end
                                        end
                                        imgui.same_line()
                                        if imgui.button(T("delete_node") .. "##" .. i) then
                                            table.remove(current_config.monster_hp_transform_rules, i)
                                            save_current_config_to_file(body_id)
                                        end
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "monster_hp", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##monster_hp_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 太刀气刃等级
                                elseif current_config.transform_type == "longsword" then
                                    for i, rule in ipairs(current_config.longsword_transform_rules) do
                                        imgui.push_id("longsword_rule_" .. i)
                                        local level_names = {
                                            [0] = T("spirit_level_0"),
                                            [1] = T("spirit_level_1"),
                                            [2] = T("spirit_level_2"),
                                            [3] = T("spirit_level_3")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("%s %d", T("spirit_level"), rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "longsword", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##longsword_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 双刀鬼人状态
                                elseif current_config.transform_type == "dual_blades" then
                                    for i, rule in ipairs(current_config.dual_blades_transform_rules) do
                                        imgui.push_id("dual_blades_rule_" .. i)
                                        local state_names = {
                                            [0] = T("dual_normal"),
                                            [1] = T("dual_kijin"),
                                            [2] = T("dual_enhancement")
                                        }
                                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "dual_blades", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##dual_blades_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 斩斧模式
                                elseif current_config.transform_type == "switch_axe" then
                                    for i, rule in ipairs(current_config.switch_axe_transform_rules) do
                                        imgui.push_id("switch_axe_rule_" .. i)
                                        local state_names = {
                                            [0] = T("switch_axe_axe"),
                                            [1] = T("switch_axe_sword"),
                                            [2] = T("switch_axe_awakened")
                                        }
                                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "switch_axe", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##switch_axe_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 盾斧强化状态
                                elseif current_config.transform_type == "charge_axe" then
                                    for i, rule in ipairs(current_config.charge_axe_transform_rules) do
                                        imgui.push_id("charge_axe_rule_" .. i)
                                        local state_names = {
                                            [0] = T("charge_axe_axe"),
                                            [1] = T("charge_axe_sword"),
                                            [2] = T("charge_axe_axe_enhanced"),
                                            [3] = T("charge_axe_shield"),
                                            [4] = T("charge_axe_sword_enhanced"),
                                            [5] = T("charge_axe_triple")
                                        }
                                        imgui.text(state_names[rule.state] or string.format("State %d", rule.state))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "charge_axe", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##charge_axe_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 大剑蓄力等级
                                elseif current_config.transform_type == "greatsword_level" then
                                    for i, rule in ipairs(current_config.greatsword_level_transform_rules) do
                                        imgui.push_id("greatsword_level_rule_" .. i)
                                        local level_names = {
                                            [0] = T("greatsword_level_0"),
                                            [1] = T("greatsword_level_1"),
                                            [2] = T("greatsword_level_2"),
                                            [3] = T("greatsword_level_3")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("%s %d", T("greatsword_level"), rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "greatsword_level", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##greatsword_level_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 大锤蓄力等级
                                elseif current_config.transform_type == "hammer" then
                                    for i, rule in ipairs(current_config.hammer_transform_rules) do
                                        imgui.push_id("hammer_rule_" .. i)
                                        local level_names = {
                                            [0] = T("hammer_level_0"),
                                            [1] = T("hammer_level_1"),
                                            [2] = T("hammer_level_2")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "hammer", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##hammer_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end

                                -- 弓箭蓄力等级
                                elseif current_config.transform_type == "bow" then
                                    for i, rule in ipairs(current_config.bow_transform_rules) do
                                        imgui.push_id("bow_rule_" .. i)
                                        local level_names = {
                                            [0] = T("bow_level_0"),
                                            [1] = T("bow_level_1"),
                                            [2] = T("bow_level_2"),
                                            [3] = T("bow_level_3")
                                        }
                                        imgui.text(level_names[rule.level] or string.format("Level %d", rule.level))
                                        imgui.indent(20)
                                        draw_targets_ui(rule.targets, "bow", i, body_id, primary)
                                        if imgui.button("+ " .. T("add_condition") .. "##bow_add_" .. i) then
                                            local default_preset = current_config.default_preset or ""
                                            if default_preset == "" and next(current_config.presets) then
                                                for name, _ in pairs(current_config.presets) do
                                                    default_preset = name
                                                    break
                                                end
                                            end
                                            table.insert(rule.targets, { group = "", preset = default_preset })
                                            save_current_config_to_file(body_id)
                                            if current_config.enable_transform then
                                                local char_addr = tostring(primary)
                                                TransformManager.clear_cache(char_addr)
                                                local new_overrides, _, activated_targets, all_targeted_groups = TransformManager.apply_transform_rules(
                                                    char_addr, (is_weapon_mode and "weapon_" or "armor_") .. body_id, current_config, primary, active_overrides[body_id] or {}, merge_overrides
                                                )
                                                active_overrides[body_id] = new_overrides
                                                bump_overrides_version(body_id)
                                                if not active_group_presets[body_id] then active_group_presets[body_id] = {} end
                                                if current_config.groups then
                                                    for g_name, g_data in pairs(current_config.groups) do
                                                        if g_data.is_global then
                                                            if activated_targets and activated_targets[g_name] then
                                                                active_group_presets[body_id][g_name] = activated_targets[g_name]
                                                            elseif all_targeted_groups and all_targeted_groups[g_name] then
                                                                active_group_presets[body_id][g_name] = g_data.default_preset or ""
                                                            end
                                                        end
                                                    end
                                                end
                                                if is_weapon_mode then
                                                    local wp = get_cached_weapon_parts(primary)
                                                    if wp then apply_preset_to_weapon(wp, new_overrides, true) end
                                                else
                                                    apply_preset_to_character(primary, new_overrides, true)
                                                end
                                            end
                                        end
                                        imgui.unindent(20)
                                        imgui.separator()
                                        imgui.pop_id()
                                    end
                                end
                            else
                                -- 并行模式
                                imgui.indent(10)
                                local function draw_parallel_setting(cond_key, label)
                                    local set = current_config.parallel_settings[cond_key]
                                    if not set then return end
                                    local changed_en, val_en = imgui.checkbox(T("enable") .. " " .. label, set.enabled)
                                    if changed_en then set.enabled = val_en; save_current_config_to_file(body_id) end
                                    imgui.same_line()
                                    imgui.set_next_item_width(80)
                                    local changed_pri, val_pri = imgui.input_text(T("priority") .. "##" .. cond_key, tostring(set.priority))
                                    if changed_pri then
                                        local p = tonumber(val_pri)
                                        if p then set.priority = p; save_current_config_to_file(body_id) end
                                    end
                                end
                                draw_parallel_setting("weapon", T("condition_weapon"))
                                draw_parallel_setting("scroll", T("condition_scroll"))
                                draw_parallel_setting("monster_hp", T("condition_monster_hp"))
                                draw_parallel_setting("longsword", T("condition_longsword"))
                                draw_parallel_setting("dual_blades", T("condition_dual_blades"))
                                draw_parallel_setting("switch_axe", T("condition_switch_axe"))
                                draw_parallel_setting("charge_axe", T("condition_charge_axe"))
                                draw_parallel_setting("greatsword_level", T("condition_greatsword_level"))
                                draw_parallel_setting("hammer", T("condition_hammer"))
                                draw_parallel_setting("bow", T("condition_bow"))
                                imgui.unindent(10)
                                if imgui.tree_node(T("parallel_rules_details")) then
                                    imgui.tree_pop()
                                end
                            end
                        end
                        imgui.tree_pop()
                    end

                    -- 部件列表
                    if is_weapon_mode then
                        if imgui.tree_node(T("weapon_parts") or "Weapon Parts") then
                            local weapon_parts = get_cached_weapon_parts(primary)
                            local weapon_type = Utils.get_current_weapon_type(primary)
                            if weapon_parts and #weapon_parts > 0 then
                                for idx, part_obj in ipairs(weapon_parts) do
                                    if part_obj and safe_object_alive(part_obj) then
                                        local mesh_comp = get_mesh_component_recursive(part_obj)
                                        if mesh_comp then
                                            local mesh_game_obj = mesh_comp:call("get_GameObject")
                                            local obj_name = mesh_game_obj:call("get_Name")
                                            local part_name = Utils.get_weapon_part_name(weapon_type, idx - 1)
                                            draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, idx - 1)
                                        else
                                            local obj_name = SceneObject.call(part_obj, "get_Name")
                                            imgui.text_colored(string.format("Part %d [%s] (No Mesh)", idx - 1, obj_name), 0xFF808080)
                                        end
                                    else
                                        imgui.text_colored(string.format("Part %d (Missing)", idx - 1), 0xFF808080)
                                    end
                                end
                            else
                                imgui.text_colored(T("weapon_not_equipped") or "No weapon equipped", 0xFF808080)
                            end
                            imgui.tree_pop()
                        end
                    else
                        local armor_parts = { [0]=T("helm"), [1]=T("body"), [2]=T("arm"), [3]=T("waist"), [4]=T("leg") }
                        if imgui.tree_node(T("armor_parts")) then
                            local armor_order = {2, 1, 0, 4, 3}
                            for _, idx in ipairs(armor_order) do
                                local part_obj = get_cached_character_part(primary, idx)
                                local part_name = armor_parts[idx]
                                if part_obj then
                                    local mesh_comp = get_mesh_component_recursive(part_obj)
                                    -- - get_GameObject() 有可能拿不到（部件刚重建、mesh 还没就绪）。
                                    --   以前这里直接索引它，一旦为 nil 就会抛错 —— 而这段在 pcall
                                    --   里，于是错误后面的**整块面板内容（语言 / 联机 / 性能设置…）
                                    --   全部被截断**，玩家只会看到「面板少了一截」。必须判空。
                                    local mesh_game_obj = mesh_comp and mesh_comp:call("get_GameObject")
                                    if mesh_game_obj then
                                        local obj_name = mesh_game_obj:call("get_Name")
                                        draw_mesh_toggle(mesh_game_obj, string.format("%s [%s]", part_name, obj_name), body_id, idx)
                                    else
                                        local obj_name = SceneObject.call(part_obj, "get_Name")
                                        imgui.text_colored(string.format("%s [%s] (No Mesh)", part_name, obj_name), 0xFF808080)
                                    end
                                else
                                    imgui.text_colored(part_name .. " " .. T("not_equipped"), 0xFF808080)
                                end
                            end
                            imgui.tree_pop()
                        end
                    end

                    imgui.separator()
                    if imgui.tree_node(T("language")) then
                        local is_en = global_config.language == "en"
                        local changed_en, new_en = imgui.checkbox("English", is_en)
                        if changed_en and new_en then
                            global_config.language = "en"
                            save_global_settings()
                        end
                        imgui.same_line()
                        local is_zh = global_config.language == "zh"
                        local changed_zh, new_zh = imgui.checkbox("中文", is_zh)
                        if changed_zh and new_zh then
                            global_config.language = "zh"
                            save_global_settings()
                        end
                        imgui.tree_pop()
                    end
                    imgui.separator()
                    -- - 联机（多人）排在「语言」与「性能设置」中间：
                    --   它是最常动的开关（联机卡就关掉、单人玩无所谓），
                    --   放这里进面板翻两下就能看到，不必越过一大堆内容。
                    draw_multiplayer_panel()
                    imgui.separator()
                    if imgui.tree_node(T("performance_settings")) then
                        imgui.text(T("performance_desc"))
                        imgui.spacing()
                        local changed_si, val_si = imgui.slider_float(T("scan_interval"), global_config.scan_interval, 0.1, 5.0)
                        if changed_si then
                            global_config.scan_interval = val_si
                            save_global_settings()
                        end
                        local changed_ttl, val_ttl = imgui.slider_float(T("refresh_interval"), global_config.body_id_ttl, 0.1, 10.0)
                        if changed_ttl then
                            global_config.body_id_ttl = val_ttl
                            save_global_settings()
                        end
                        local changed_bs, val_bs = imgui.slider_int(T("scanner_batch_size"), global_config.scanner_batch_size, 10, 1000)
                        if changed_bs then
                            global_config.scanner_batch_size = val_bs
                            save_global_settings()
                        end

                        imgui.separator()
                        imgui.text(T("image_quality") or "Image Quality")
                        local changed_iq_enable, new_iq_enable = imgui.checkbox(T("enable_image_quality") or "Enable Custom Image Quality", global_config.enable_image_quality)
                        if changed_iq_enable then
                            global_config.enable_image_quality = new_iq_enable
                            save_global_settings()
                            apply_image_quality()
                        end
                        if global_config.enable_image_quality then
                            local current_rate = global_config.image_quality_rate
                            local display_percent = math.floor(current_rate * 100 + 0.5)
                            local changed_rate, new_rate = imgui.slider_float(T("image_quality_rate") or "Image Quality (%)", current_rate, 0.1, 4.0)
                            if changed_rate then
                                global_config.image_quality_rate = new_rate
                                save_global_settings()
                                apply_image_quality()
                            end
                            imgui.same_line()
                            imgui.text(string.format("(%d%%)", math.floor(global_config.image_quality_rate * 100)))
                        end

                        imgui.tree_pop()
                    end
                else
                    if is_weapon_mode then
                        imgui.text_colored(T("weapon_not_equipped") or "No weapon detected", 0xFF0000FF)
                    else
                        imgui.text_colored(T("no_body_part"), 0xFF0000FF)
                    end
                end
            else
                imgui.text_colored(T("waiting_for_player"), 0xFF0000FF)
            end
        end)
        if not status then
            imgui.text_colored(T("lua_error") .. tostring(err), 0xFF0000FF)
        end
        imgui.tree_pop()
    end
end)
