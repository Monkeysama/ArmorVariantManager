-- RE4 的 REFF 网页接口:快照 / 操作 / 帮助。只服务 v3 配置(整套造型 + 状态组 + 条件状态 + 预设库);
-- v2 配置在网页上只给"迁移旧配置",ImGui 面板照旧能用 v2。
--
-- 网页只拿到可序列化的数据(字符串、数字、布尔),不传托管对象。改配置一律走 Ops / OpsV3,
-- 和 ImGui 面板同一套语义;存盘与重写由 Main 提供的 commit 完成。
-- 网页维护自己的"当前角色",和 ImGui 面板的选择互不影响;每个操作都带上角色 id,
-- 角色在两次刷新之间变了就拒绝执行,避免改到别人身上。
--
-- 注意:Lua 空表在 JSON 里会变成 null,网页端统一按"缺省"处理。
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local OpsV3 = require("ArmorVariantManager_Core.Games.RE4.OpsV3")
local M3 = require("ArmorVariantManager_Core.Games.RE4.ModelV3")
local Palette = require("ArmorVariantManager_Core.Games.RE4.Palette")
local Mdf2 = require("ArmorVariantManager_Core.Games.RE4.Mdf2")
local MdfReplace = require("ArmorVariantManager_Core.Games.RE4.MdfReplace")
-- 默认贴图失效规则(离线材质库生成);加载失败就不做判断,不影响调色盘本身
local ok_effects, MaterialEffects = pcall(require, "ArmorVariantManager_Core.Games.RE4.MaterialEffects")
local effects_index = ok_effects and Palette.effects_index(MaterialEffects) or nil
local Bridge = require("ArmorVariantManager_Core.UI.Reff.Bridge")

local Reff = {}

-- 条件在网页下拉框里的分组
local CATEGORY = {
    hp_ratio = "hp", hp_vital = "hp", hp_decreased = "hp", hp_increased = "hp",
    is_crouch = "move", is_walk = "move", is_run = "move", is_quick_turn = "move", is_jumping = "move",
    is_falling = "move", is_landing = "move", is_ladder = "move", is_hook_shot = "move", is_boat = "move",
    is_damaging = "damage", is_upper_body_damage = "damage", is_burning = "damage", is_invincible = "damage",
    has_armor_mesh = "other",
}

-- deps(都由 Main.start 提供):
--   version, global_config, save_global_settings, T
--   targets()                      -> Targets.collect()
--   groups(targets)                -> collect_character_groups
--   pick_group(groups, order, id)  -> pick_character_group
--   resolve_key(target), cfg_key(id), register_kind(id), load_config(id, source, allow_kin)
--   commit(id, changed, reapply), reset_ui_state(), request_reapply()
--   char_display(char), target_label(target), slot_label(slot), visible_slots(source)
--   TransformManager, Registry, Utils, documentation
--   snapshot_before_destructive, has_backup, has_onload_backup, restore_backup, restore_onload_backup,
--   start_preview, get_preview
--   preview(可选):Portrait.connect 的网页接口 { snapshot(), action(request) }
--   v3:migrate_to_v3, preset_view, dismiss_preset_hint, apply_preset, save_current_as_preset,
--      update_source_preset, restore_autosave, promote_autosave, preset_lib
--   调色:palette_profiles, palette_profile_errors, palette_dump, all_meshes, forget_palette
function Reff.new(deps)
    local controller = {}
    local selected = nil
    local notice = nil     -- 一次性提示(迁移结果之类),随下一份快照交给网页
    local T, TM, Registry, Utils = deps.T, deps.TransformManager, deps.Registry, deps.Utils

    -- 调色盘:只有网页开着调色页时快照才带 palette(参数多,不必每次都读)。
    -- palette_sel = 网页选中的材质键("slot/材质"),只给它们读当前值;
    -- palette_cache[mesh|序号] = { name, has = {参数 = 类型}, main, addons, missing },mesh 换实例就是新键
    local palette_open, palette_sel, palette_cache = false, {}, {}
    local palette_dirty = false   -- 拖动中的实时写入还没存盘
    -- 一份调色覆盖表(方案)。scheme = "" / nil 表示「选中的那一份」:初始(mdf2 原值)只读,
    -- create = true 时选着初始就自动新建一个方案并选中,接住这次修改。方案不存在返回 nil
    local function palette_table(cfg, scheme, create)
        if scheme == nil or scheme == "" then
            if create then OpsV3.ensure_palette(cfg, deps.global_config.language == "zh" and "方案" or "Scheme") end
            scheme = cfg.palette_active
        end
        return type(scheme) == "string" and type(cfg.palettes) == "table" and cfg.palettes[scheme] or nil
    end
    -- 调色页编辑的就是选中的那一份:cfg.palette_active(选中就生效),没有 = 初始
    local function selected_scheme(cfg) return cfg.palette_active or "" end

    local function language() return deps.global_config.language == "zh" and "zh" or "en" end

    -- 当前角色 = 网页选中的那一组;没选过或已离场时退回主控。和面板同一套分组。
    local function current()
        local groups, order = deps.groups(deps.targets())
        if #order == 0 then return nil, groups, order end
        local group = deps.pick_group(groups, order, selected)
        selected = group.gid
        local target = group.rep
        local kind_id = group.key or group.gid
        local _, how = deps.resolve_key(target)
        deps.register_kind(kind_id)
        -- 同 apply_target:只有身份认不出来时才允许跨角色认亲
        local config = deps.load_config(kind_id, target.source, how == "legacy")
        return { group = group, target = target, kind_id = kind_id, config = config,
                 context = target.context }, groups, order
    end

    -- 全身预览拍谁:网页选中的那一组的代表模型;没选过或已离场时退回主控(同 current,但不读配置)
    function controller.preview_target()
        local groups, order = deps.groups(deps.targets())
        if #order == 0 then return nil end
        local group = deps.pick_group(groups, order, selected)
        return group and group.rep or nil
    end

    local function condition_defs(context)
        local out = {}
        for _, def in ipairs(Registry.all()) do
            local row = { id = def.id, kind = def.kind, label = T(def.label_key), category = CATEGORY[def.id] or "combat" }
            if def.kind == "number" then row.ops = Registry.NUM_OPS
            elseif def.kind == "enum" then
                row.ops = Registry.ENUM_OPS
                row.options = {}
                for _, o in ipairs(def.options and def.options(context, language()) or {}) do
                    row.options[#row.options + 1] = { value = o.value, label = o.label }
                end
            end
            if context then
                local ok, value = pcall(def.get, context)
                if ok and (type(value) == "number" or type(value) == "boolean") then row.value = value end
            end
            out[#out + 1] = row
        end
        return out
    end

    local function result_of(r)
        if not r then return nil end
        return { kind = r.kind, by = r.by }
    end

    local function state_row(st, i, v3, context)
        local s = v3.status[i] or { kind = "idle" }
        local t = v3.targets[i] or {}
        local row = { name = st.name, enabled = st.enabled, exclusive = st.exclusive, logic = st.logic,
            hold = st.hold, fadeIn = st.fade_in, fadeOut = st.fade_out, base = st.base,
            baseResult = result_of(t.base), kind = s.kind, by = s.by, holding = s.holding == true,
            hp = st.hp and { upper = st.hp.upper, lower = st.hp.lower, invert = st.hp.invert } or nil,
            targets = {}, conditions = {}, palette = st.palette, paletteResult = result_of(t.palette) }
        for j, tg in ipairs(st.targets) do
            row.targets[j] = { group = tg.group, option = tg.option, result = result_of(t[j]) }
        end
        for ci, c in ipairs(st.conditions) do
            local def = Registry.get(c.type)
            local cr = { type = tostring(c.type), op = c.op, value = c.value, known = def ~= nil,
                label = def and T(def.label_key) or tostring(c.type) }
            if def and def.kind == "enum" and def.value_label then cr.valueLabel = def.value_label(c.value, language()) end
            if context and def then cr.met = Registry.eval_condition(c, context) == true end
            row.conditions[ci] = cr
        end
        return row
    end

    local function values_of(preset)
        local out = {}
        for slot, data in pairs(preset or {}) do
            if type(data) == "table" and type(data.materials) == "table" then
                for m, v in pairs(data.materials) do out[M3.key_of(slot, m)] = v == true end
            end
        end
        return out
    end

    -- 整套造型的逐槛位闸门:全部对不上 → mismatch;部分对不上 → partial(列出被跳过的槛位)
    local function base_match(source, preset)
        local usable = TM.usable_slots(source, preset)
        local skipped = {}
        for _, slot in ipairs(Utils.MESH_SLOTS) do
            local sd = preset and preset[slot]
            local has_stored = type(sd) == "table" and next(sd.materials or {}) ~= nil
            if has_stored and Utils.get_mesh(source, slot) and not usable[slot] then
                skipped[#skipped + 1] = deps.slot_label(slot)
            end
        end
        if next(usable) == nil then return { status = "mismatch", skipped = skipped } end
        return { status = (#skipped > 0) and "partial" or "ok", skipped = skipped }
    end

    -- 一个材质的识别结果(缓存)。missing = 映射里写了、但这个材质没有或类型不对的参数
    local function palette_info(mesh, j, profiles)
        local key = tostring(mesh) .. "|" .. j
        local c = palette_cache[key]
        if c then return c end
        local name = mesh:call("getMaterialName", j)
        local vars = Palette.read_vars(mesh, j)
        local has = {}
        for n, v in pairs(vars) do has[n] = v.t end
        -- 先认母材质(离线材质库):自动生成的原版母材质映射按它匹配,默认贴图失效也按它判断
        local textures, master = nil, nil
        if effects_index then
            local ok_m = pcall(function()
                textures = Palette.read_textures(mesh, j)
                master = Palette.find_master(effects_index, mesh:call("getMaterialVariableNum", j), textures)
            end)
            if not ok_m then textures, master = nil, nil end
        end
        local main, addons = Palette.match(profiles, has, master and master.id or nil)
        local missing, seen = {}, {}
        local all = {}
        if main then all[1] = main end
        for _, a in ipairs(addons) do all[#all + 1] = a end
        for _, p in ipairs(all) do
            for _, g in ipairs(p.groups) do
                for _, e in ipairs(g.params) do
                    if not seen[e.param] and not Palette.entry_usable(e, has) then seen[e.param] = true; missing[#missing + 1] = e.param end
                end
            end
        end
        local ids = {}
        for _, a in ipairs(addons) do ids[#ids + 1] = a.id end
        -- 哪些参数因为贴图槽绑了默认(null)贴图而改了不生效
        local dead = nil
        if master then
            local ok_d, d = pcall(Palette.ineffective, effects_index, master, textures)
            if ok_d then dead = d end
        end
        c = { name = name, vars = vars, has = has, main = main, addons = ids, addon_list = addons, missing = missing,
              generic = (not main) and Palette.generic(has) or nil, ineffective = dead }
        palette_cache[key] = c
        return c
    end

    local function palette_snapshot(cur)
        local profiles = deps.palette_profiles()
        local source, config = cur.target.source, cur.config
        local scheme = selected_scheme(config)
        local pal = palette_table(config, scheme) or {}
        local out = { materials = {}, profiles = {}, values = {}, overrides = {}, selected = {},
                      errors = deps.palette_profile_errors(), scheme = scheme }
        local used, live, sel, listed = {}, {}, {}, {}
        for _, k in ipairs(palette_sel) do sel[k] = true end
        local notes = config.material_notes or {}
        out.replacing = MdfReplace.busy()
        -- 护甲同步身体外观时护甲的调色照抄身体(按材质名),护甲的材质不列出来
        for _, slot in ipairs(deps.visible_slots(source, config.armor_mirrors_body == true)) do
            local mesh = Utils.get_mesh(source, slot)
            -- 「替换 mdf」能不能用:ok / packed(不是松散文件)/ plugin(原生插件太旧)
            local replace = mesh and MdfReplace.check(mesh) or nil
            local ok, count = pcall(function() return mesh and mesh:call("get_MaterialNum") or 0 end)
            for j = 0, (ok and count or 0) - 1 do
                local okc, c = pcall(palette_info, mesh, j, profiles)
                if okc and type(c.name) == "string" then
                    live[tostring(mesh) .. "|" .. j] = true
                    local key = slot .. "/" .. c.name
                    -- 同名材质(同一 mesh 里重复的名字)只列第一个;写入时也按名字,一起改
                    if not listed[key] then
                        listed[key] = true
                        local ov = (pal[slot] or {})[c.name]
                        local n = 0
                        for _ in pairs(ov or {}) do n = n + 1 end
                        out.materials[#out.materials + 1] = { key = key, slot = slot, material = c.name,
                            note = (notes[slot] or {})[c.name], main = c.main and c.main.id or nil, addons = c.addons,
                            missing = c.missing, generic = c.generic, overridden = n, ineffective = c.ineffective, replace = replace }
                        if c.main then used[c.main.id] = c.main end
                        for _, a in ipairs(c.addon_list) do used[a.id] = a end
                        out.overrides[key] = ov or false
                        if sel[key] then
                            out.selected[#out.selected + 1] = key
                            -- 当前值叠加上覆盖值:改完到下一帧才真正写进 mesh,直接读会读到旧值,界面就跳回去了
                            local values = {}
                            for name, var in pairs(c.vars) do
                                local v = Palette.read_value(mesh, j, var)
                                local o = ov and ov[name]
                                if type(o) == "number" and var.t == Palette.TYPE_FLOAT then v = o
                                elseif type(o) == "table" and type(v) == "table" then
                                    for k, i in pairs({ x = 1, y = 2, z = 3, w = 4 }) do if type(o[k]) == "number" then v[i] = o[k] end end
                                end
                                values[name] = v
                            end
                            out.values[key] = values
                        end
                    end
                end
            end
        end
        for key in pairs(palette_cache) do if not live[key] then palette_cache[key] = nil end end
        for id, p in pairs(used) do
            out.profiles[id] = { id = p.id, label = p.label, addon = p.addon, enums = p.enums, groups = p.groups, sections = p.sections }
        end
        return out
    end

    local function v3_snapshot(snapshot, cur)
        local context, config, source = cur.context, cur.config, cur.target.source
        snapshot.status = { flags = {} }
        if context then
            snapshot.status.hp = TM.get_character_hp_percent(context)
            for _, def in ipairs(Registry.all()) do
                if def.kind == "bool" then
                    local ok, value = pcall(def.get, context)
                    if ok and value == true then snapshot.status.flags[#snapshot.status.flags + 1] = T(def.label_key) end
                end
            end
        end
        snapshot.conditions = condition_defs(context)
        snapshot.auto = config.conditions.auto
        snapshot.armorMirror = config.armor_mirrors_body == true

        -- 解算一遍拿到各层选择、条件状态结果和最终材质。缓存键单独起一个,不干扰应用循环的变化检测。
        local resolved, _, info = TM.resolve("reff:" .. tostring(cur.target.id), config, context, source)
        local v3 = info.v3

        -- 当前模型各槛位的材质(编辑、作用域、最终材质都按这个列)
        snapshot.slots, snapshot.look = {}, {}
        local notes = config.material_notes or {}
        for _, slot in ipairs(deps.visible_slots(source)) do
            local mesh = Utils.get_mesh(source, slot)
            local row = { id = slot, label = deps.slot_label(slot), materials = {},
                mirrored = slot == "armor" and config.armor_mirrors_body == true }
            local seen = {}
            for _, m in ipairs(Utils.get_material_names(mesh)) do
                if not seen[m] then
                    seen[m] = true
                    row.materials[#row.materials + 1] = { name = m, note = (notes[slot] or {})[m] }
                    local data = resolved[slot]
                    snapshot.look[#snapshot.look + 1] = { slot = slot, material = m,
                        on = not (data and data.materials[m] == false) }
                end
            end
            snapshot.slots[#snapshot.slots + 1] = row
        end

        local base = config.base
        local base_layer = info.layers.base or {}
        snapshot.base = { active = base.active, effective = v3.picks.base, fromState = base_layer.prio, presets = {} }
        for _, name in ipairs(base.order) do
            snapshot.base.presets[#snapshot.base.presets + 1] = { name = name, values = values_of(base.presets[name]),
                match = base_match(source, base.presets[name]), height = (base.heights or {})[name],
                palette = (base.palettes or {})[name] }
        end

        snapshot.groups = {}
        for _, g in ipairs(config.groups) do
            local key = M3.layer_key(g.name)
            local row = { name = g.name, scope = {}, active = g.active, effective = v3.picks[key],
                fromState = (info.layers[key] or {}).prio, options = {} }
            for k, s in ipairs(g.scope) do row.scope[k] = s end
            for _, name in ipairs(g.order) do
                row.options[#row.options + 1] = { name = name, values = values_of(g.options[name]), height = (g.heights or {})[name],
                    palette = (g.palettes or {})[name] }
            end
            snapshot.groups[#snapshot.groups + 1] = row
        end

        -- 这一帧生效的模型高度(厘米,nil = 不抬高;总开关关掉时也照算,界面上另外标出)
        -- heightSource:来自哪一层("override" / "base" / 状态组名 + 选项名);heightOverride:快速切换页的全局覆盖
        local cm, src = M3.height_of(config, v3.picks)
        snapshot.height, snapshot.heightSource = cm, src
        local o = config.height_override
        snapshot.heightOverride = { enabled = type(o) == "table" and o.enabled == true, cm = type(o) == "table" and o.cm or 0 }

        -- 调色方案:列表(按 palette_order)、各自被引用几次、这一帧生效的(从下到上,不含编辑预览)
        local schemes = config.palettes or {}
        local used = {}
        local function count(n) if type(n) == "string" then used[n] = (used[n] or 0) + 1 end end
        for _, n in pairs(base.palettes or {}) do count(n) end
        for _, g in ipairs(config.groups) do for _, n in pairs(g.palettes or {}) do count(n) end end
        for _, st in ipairs(config.conditions.states) do count(st.palette) end
        snapshot.palettes = { list = {}, active = M3.palette_layers(config, v3), selected = config.palette_active or "" }
        for _, n in ipairs(config.palette_order or {}) do
            local mats = 0
            for _, ms in pairs(schemes[n] or {}) do for _ in pairs(ms) do mats = mats + 1 end end
            snapshot.palettes.list[#snapshot.palettes.list + 1] = { name = n, used = used[n] or 0, materials = mats }
        end

        -- 快捷键(Alt + 数字):全部绑定,按数字排;网页据此在各处显示 / 判断互斥
        snapshot.hotkeys = {}
        for d = 0, 9 do
            local b = (config.hotkeys or {})[tostring(d)]
            if b then
                local row = { digit = d, kind = b.kind, group = b.group, option = b.option, scheme = b.scheme,
                    cycle = M3.hotkey_is_cycle(b), skip = {} }
                for k, n in ipairs(b.skip or {}) do row.skip[k] = n end
                snapshot.hotkeys[#snapshot.hotkeys + 1] = row
            end
        end

        if palette_open then
            local ok, pal = pcall(palette_snapshot, cur)
            snapshot.palette = ok and pal or { error = tostring(pal) }
        end

        snapshot.states = {}
        for i, st in ipairs(config.conditions.states) do snapshot.states[i] = state_row(st, i, v3, context) end

        local preview = deps.get_preview()
        if preview and preview.target_id == cur.target.id then
            snapshot.locating = { slot = preview.slot, material = preview.mat }
        end

        local view = deps.preset_view(cur.kind_id, source)
        local p = { current = view.current, dismissed = view.dismissed == true, list = {}, better = {}, autosaves = {} }
        if view.source then p.source = { id = view.source.id, name = view.source.name, own = view.source.source == "user" } end
        for _, r in ipairs(view.presets) do
            p.list[#p.list + 1] = { id = r.entry.id, name = r.entry.name, source = r.entry.source, match = r.match }
        end
        for _, e in ipairs(view.better) do p.better[#p.better + 1] = { id = e.id, name = e.name } end
        for k, a in ipairs(view.autosaves) do p.autosaves[k] = { name = a.name, time = a.time } end
        snapshot.presets = p
        snapshot.backups = { hasBackup = deps.has_backup(cur.kind_id) == true,
            hasOnload = deps.has_onload_backup(cur.kind_id) == true }
    end

    function controller.snapshot()
        local g = deps.global_config
        local snapshot = { game = "RE4", version = deps.version, language = language(),
            settings = { weaponHideStorage = g.weapon_hide_storage == true,
                uiDissolveEnabled = g.ui_dissolve_enabled ~= false, blockGameMouse = g.block_game_mouse ~= false,
                heightEnabled = g.height_enabled ~= false,
                uiDissolveTime = tonumber(g.ui_dissolve_time) or 1.0,
                previewDistance = tonumber(g.portrait_distance) or 3.0, previewHeight = tonumber(g.portrait_height) or 0.0 },
            characters = {}, character = "", notice = notice,
            preview = deps.preview and deps.preview.snapshot() or nil }
        notice = nil
        local cur, groups, order = current()
        for _, gid in ipairs(order) do
            local group = groups[gid]
            local row = { id = gid, label = deps.char_display(group.char) or gid,
                configured = group.key ~= nil, targets = {} }
            for _, t in ipairs(group.targets) do row.targets[#row.targets + 1] = deps.target_label(t) end
            snapshot.characters[#snapshot.characters + 1] = row
        end
        if not cur then return snapshot end
        snapshot.character = cur.group.gid
        snapshot.configVersion = M3.is_v3(cur.config) and 3 or 2
        if snapshot.configVersion == 3 then v3_snapshot(snapshot, cur) end
        return snapshot
    end

    local function integer(value) return math.tointeger(tonumber(value)) end
    local function str(value) return type(value) == "string" and value or nil end

    -- v3 的操作。返回 changed, reapply;已经自己存过盘的返回 "saved"。
    local actions = {
        manual = function(p, cfg) return OpsV3.set_manual(cfg, str(p.layer), str(p.option) or "") end,
        auto = function(p, cfg) return OpsV3.set_auto(cfg, p.enabled == true) end,
        ["armor-mirror"] = function(p, cfg) return Ops.set_armor_mirror(cfg, p.enabled == true) end,
        note = function(p, cfg) return Ops.set_note(cfg, p.slot, p.material, p.text) end,
        -- 定位只是临时预览,不改配置
        locate = function(p, _, cur)
            if type(p.slot) ~= "string" or type(p.material) ~= "string" then return false end
            deps.start_preview(cur.target.id, p.slot, p.material)
            return "saved"
        end,

        -- 整套造型。新建 = 抓当前外观;删除和重新抓取不可逆,先留还原点
        ["base-new"] = function(_, cfg, cur) return Ops.new_preset(cfg.base, Utils.capture_current_as_preset(cur.target.source)) end,
        ["base-duplicate"] = function(p, cfg) return Ops.duplicate_preset(cfg.base, p.preset) end,
        ["base-rename"] = function(p, cfg) return OpsV3.rename_base(cfg, p.preset, p.name) end,
        ["base-move"] = function(p, cfg) return Ops.move_preset(cfg.base, p.preset, integer(p.offset)) end,
        ["base-delete"] = function(p, cfg, cur)
            if not cfg.base.presets[p.preset] then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            return OpsV3.delete_base(cfg, p.preset)
        end,
        ["base-recapture"] = function(p, cfg, cur)
            local prev = cfg.base.presets[p.preset]
            if not prev then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            local source = cur.target.source
            return Ops.replace_preset(cfg.base, p.preset,
                Utils.capture_preserving_unmatched(source, prev, TM.usable_slots(source, prev)))
        end,
        -- 调色盘。view:网页打开 / 关闭调色页、换选中的材质(不改配置)
        ["palette-view"] = function(p, cfg)
            palette_open = p.open == true

            local keys = {}
            for _, k in ipairs(type(p.keys) == "table" and p.keys or {}) do
                if type(k) == "string" and #keys < 64 then keys[#keys + 1] = k end
            end
            palette_sel = keys
            -- 拖动后没点确定就关了面板 / 换了材质:实时改动已经生效,这里补存一次
            if palette_dirty then palette_dirty = false; return true, false end
            return "saved"
        end,
        -- set:writes = { { slot, material, param, component?, value }, ... }(整体调色一次发一批)
        -- live = 拖动中:只改内存里的配置并重写模型,不存盘;松手 / 确定时再发一次不带 live 的,存盘
        ["palette-set"] = function(p, cfg)
            local changed = false
            -- 选着初始时自动新建方案:这算改了配置结构,即使是拖动中也要存盘
            local had = cfg.palette_active
            local pal = palette_table(cfg, str(p.scheme), true)
            if not pal then return false end
            if cfg.palette_active ~= had then p.live = nil end
            for _, w in ipairs(type(p.writes) == "table" and p.writes or {}) do
                if Palette.set_in(pal, w) then changed = true end
            end
            if p.live == true then
                if changed then palette_dirty = true; deps.request_reapply() end
                return "saved"
            end
            -- 最终值和最后一次拖动的值一样时 changed 为 false,但拖动中的改动还没存盘
            if not changed and not palette_dirty then return "saved" end
            palette_dirty = false
            return true, true
        end,
        -- reset:targets = { { slot, material }, ... };param / component 可选(缺省 = 全部)
        ["palette-reset"] = function(p, cfg)
            local changed = false
            local pal = palette_table(cfg, str(p.scheme))
            for _, t in ipairs(type(p.targets) == "table" and p.targets or {}) do
                if type(t) == "table" and Palette.reset_in(pal, t.slot, t.material, str(p.param), str(p.component)) then changed = true end
            end
            if not changed then return "saved" end
            return true, true
        end,
        ["palette-reload"] = function()
            deps.palette_profiles(true)
            palette_cache = {}
            if deps.forget_mdf2 then deps.forget_mdf2() end
            return "saved"
        end,
        -- 导出 mdf2 材质预设(RE Mesh Editor 格式,见 Mdf2.lua):写到 data/ArmorVariantManager/mdf2_presets/RE4/<预设名>.json,
        -- 拷进插件的 Presets/RE4/ 就能在 Blender 里套用。参数值用当前的(调色改过的也在)。
        -- 材质头、Flags、Padding、贴图、MMTRS / GPBF 取自 mod 的 mdf2(原生插件读 natives/STM/...);
        -- 读不到(原版材质在 pak 里、原生插件太旧)时只用运行时数据,通知里标明是近似值和原因
        ["palette-export"] = function(p, _, cur)
            local name = str(p.name)
            if not Mdf2.valid_name(name) then error(T("reff_preset_name_invalid")) end
            local mesh = Utils.get_mesh(cur.target.source, str(p.slot))
            local count = mesh and mesh:call("get_MaterialNum") or 0
            for j = 0, count - 1 do
                if mesh:call("getMaterialName", j) == p.material then
                    local preset, reason = Mdf2.export(mesh, j, p.material, Palette, effects_index)
                    local path = "ArmorVariantManager/mdf2_presets/RE4/" .. name .. ".json"
                    if not deps.palette_dump(path, preset) then return false end
                    notice = { kind = "palette-exported", path = "reframework/data/" .. path, exact = reason == nil, reason = reason }
                    return "saved"
                end
            end
            return false
        end,

        -- 模型高度:cm = nil 清除
        -- 替换 mdf:把这个槽位网格的 mdf2 里涉及的调色覆盖值写进原文件并当场换上,随后清空这些覆盖值(见 MdfReplace.lua)。
        -- 换上要等几帧(资源异步加载),清配置和存盘在那时做;这里只开始
        ["palette-replace"] = function(p, cfg, cur)
            local slot = str(p.slot)
            local mesh = Utils.get_mesh(cur.target.source, slot)
            if not mesh then return false end
            local kind_id = cur.kind_id
            -- 写进去的是选中方案里这个槽位的值(写完从方案里清掉,它们成了新的初始);选着初始时没有可写的
            local pal = palette_table(cfg, "")
            if not pal then error(T("reff_replace_nothing")) end
            local ok, info = pcall(MdfReplace.start, {
                mesh = mesh, overrides = pal[slot],
                meshes = deps.all_meshes, forget = deps.forget_palette, reapply = deps.request_reapply,
                clear = function(names)
                    local mats = pal[slot]
                    if not mats then return end
                    for name in pairs(names) do mats[name] = nil end
                    if next(mats) == nil then pal[slot] = nil end
                    deps.commit(kind_id, true, true)
                end,
                log = function(msg) if log and log.info then log.info("[AVM] " .. msg) end end,
            })
            if not ok then
                local msg = tostring(info):gsub("^.-%.lua:%d+: ", "")
                local KNOWN = { busy = "reff_replace_busy", ["nothing to write"] = "reff_replace_nothing", ["not replaceable"] = "reff_replace_packed" }
                error(KNOWN[msg] and T(KNOWN[msg]) or msg)
            end
            notice = { kind = "mdf-replaced", path = info.path }
            return "saved"
        end,
        -- 调色方案。new:from = nil 空方案 / "" 复制常驻 / 方案名 复制那个;建好就切到它编辑
        -- from = nil:空方案(= 初始);方案名:复制那个方案
        ["palette-scheme-new"] = function(p, cfg) return OpsV3.new_palette(cfg, str(p.name), str(p.from)) end,
        -- 选中:选中的方案一直生效,调色页也编辑它;scheme = "" 只用常驻调色
        ["palette-scheme-select"] = function(p, cfg) return OpsV3.set_palette_active(cfg, str(p.scheme) or "") end,
        ["palette-scheme-rename"] = function(p, cfg) return OpsV3.rename_palette(cfg, str(p.scheme), str(p.name)) end,
        ["palette-scheme-delete"] = function(p, cfg, cur)
            if not palette_table(cfg, str(p.scheme)) or str(p.scheme) == "" then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            return OpsV3.delete_palette(cfg, p.scheme)
        end,
        -- 引用:layer = "base" / 状态组名 + option;scheme = "" 取消
        ["palette-ref"] = function(p, cfg) return OpsV3.set_palette_ref(cfg, str(p.layer), str(p.option), str(p.scheme) or "") end,
        ["state-palette"] = function(p, cfg) return OpsV3.set_state_palette(cfg, integer(p.index), str(p.scheme) or "") end,
        ["base-height"] = function(p, cfg) return OpsV3.set_height(cfg, "base", p.preset, p.cm) end,
        -- 快捷键(Alt + 数字):target = { kind = "base" / "group" / "palette", group?, option? / scheme? },
        -- 没有 option / scheme = 轮换整个结构;clear 清掉一个键;skip:轮换里包不包括某一项(item = "" 是「（无）」/「初始」)
        ["hotkey-set"] = function(p, cfg)
            local t = type(p.target) == "table" and p.target or nil
            if not t then return false end
            return OpsV3.set_hotkey(cfg, p.digit, { kind = str(t.kind), group = str(t.group), option = str(t.option), scheme = str(t.scheme) })
        end,
        ["hotkey-clear"] = function(p, cfg) return OpsV3.set_hotkey(cfg, p.digit, nil) end,
        ["hotkey-skip"] = function(p, cfg)
            local s = type(p.structure) == "table" and p.structure or {}
            return OpsV3.set_hotkey_skip(cfg, { kind = str(s.kind), group = str(s.group) }, str(p.item), p.included == true)
        end,
        ["option-height"] = function(p, cfg) return OpsV3.set_height(cfg, p.group, p.option, p.cm) end,
        ["height-override"] = function(p, cfg)
            local enabled = nil
            if p.enabled ~= nil then enabled = p.enabled == true end
            return OpsV3.set_height_override(cfg, enabled, p.cm)
        end,
        ["base-material"] = function(p, cfg)
            return Ops.set_material(cfg.base.presets[p.preset], p.slot, p.material, p.value == true, true)
        end,

        -- 状态组
        ["group-new"] = function(p, cfg) return OpsV3.new_group(cfg, str(p.name)) end,
        ["group-rename"] = function(p, cfg) return OpsV3.rename_group(cfg, p.group, str(p.name)) end,
        ["group-move"] = function(p, cfg) return OpsV3.move_group(cfg, p.group, integer(p.offset)) end,
        ["group-delete"] = function(p, cfg, cur)
            if not M3.find_group(cfg, p.group) then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            return OpsV3.delete_group(cfg, p.group)
        end,
        ["scope-add"] = function(p, cfg) return OpsV3.scope_add(cfg, p.group, p.slot, p.material) end,
        ["scope-remove"] = function(p, cfg) return OpsV3.scope_remove(cfg, p.group, p.slot, p.material) end,
        ["scope-set"] = function(p, cfg, cur)
            if not M3.find_group(cfg, p.group) then return false end
            if type(p.remove) == "table" and #p.remove > 0 then deps.snapshot_before_destructive(cur.kind_id) end
            return OpsV3.scope_set(cfg, p.group, p.add, p.remove)
        end,
        ["option-new"] = function(p, cfg) return OpsV3.new_option(cfg, p.group, str(p.name)) end,
        ["option-duplicate"] = function(p, cfg) return OpsV3.duplicate_option(cfg, p.group, p.option) end,
        ["option-rename"] = function(p, cfg) return OpsV3.rename_option(cfg, p.group, p.option, str(p.name)) end,
        ["option-move"] = function(p, cfg) return OpsV3.move_option(cfg, p.group, p.option, integer(p.offset)) end,
        ["option-delete"] = function(p, cfg, cur)
            local g = M3.find_group(cfg, p.group)
            if not g or not g.options[p.option] then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            return OpsV3.delete_option(cfg, p.group, p.option)
        end,
        ["option-material"] = function(p, cfg)
            return OpsV3.set_option_material(cfg, p.group, p.option, p.slot, p.material, p.value)
        end,

        -- 条件状态
        ["state-new"] = function(p, cfg) return OpsV3.new_state(cfg, str(p.name)) end,
        ["state-delete"] = function(p, cfg) return OpsV3.delete_state(cfg, integer(p.index)) end,
        ["state-move"] = function(p, cfg) return OpsV3.move_state(cfg, integer(p.from), integer(p.to)) end,
        ["state-rename"] = function(p, cfg) return OpsV3.rename_state(cfg, integer(p.index), str(p.name)) end,
        ["state-field"] = function(p, cfg) return OpsV3.set_state_field(cfg, integer(p.index), p.field, p.value) end,
        ["state-hp"] = function(p, cfg)
            return OpsV3.set_state_hp(cfg, integer(p.index), type(p.hp) == "table" and p.hp or nil)
        end,
        ["state-base"] = function(p, cfg) return OpsV3.set_state_base(cfg, integer(p.index), str(p.preset)) end,
        ["state-target"] = function(p, cfg) return OpsV3.set_state_target(cfg, integer(p.index), p.group, p.option) end,
        ["state-target-group"] = function(p, cfg) return OpsV3.change_target_group(cfg, integer(p.index), integer(p.target), p.group) end,
        ["state-target-remove"] = function(p, cfg) return OpsV3.remove_state_target(cfg, integer(p.index), integer(p.target)) end,
        ["condition-add"] = function(p, cfg, cur)
            local c = type(p.condition) == "table" and p.condition or {}
            local cond = Ops.make_condition(Registry.get(c.type), c.op, c.value, cur.context, language())
            if not cond then return false end
            return OpsV3.add_condition(cfg, integer(p.index), cond)
        end,
        ["condition-set"] = function(p, cfg, cur)
            local c = type(p.condition) == "table" and p.condition or {}
            local cond = Ops.make_condition(Registry.get(c.type), c.op, c.value, cur.context, language())
            if not cond then return false end
            return OpsV3.set_condition(cfg, integer(p.index), integer(p.condition_index), cond)
        end,
        ["condition-delete"] = function(p, cfg) return OpsV3.delete_condition(cfg, integer(p.index), integer(p.condition_index)) end,

        -- 预设库
        ["preset-apply"] = function(p, _, cur) return deps.apply_preset(cur.kind_id, str(p.id)) and "saved" end,
        ["preset-save"] = function(p, _, cur) return deps.save_current_as_preset(cur.kind_id, str(p.name)) and "saved" end,
        ["preset-update"] = function(_, _, cur) return deps.update_source_preset(cur.kind_id) and "saved" end,
        ["preset-rename"] = function(p) return deps.preset_lib.rename(str(p.id), str(p.name)) and "saved" end,
        ["preset-delete"] = function(p) return deps.preset_lib.delete(str(p.id)) and "saved" end,
        ["preset-dismiss"] = function(_, _, cur) return deps.dismiss_preset_hint(cur.kind_id, cur.target.source) and "saved" end,
        ["autosave-restore"] = function(p, _, cur) return deps.restore_autosave(cur.kind_id, integer(p.index)) and "saved" end,
        ["autosave-promote"] = function(p, _, cur) return deps.promote_autosave(cur.kind_id, integer(p.index), str(p.name)) and "saved" end,
        restore = function(p, _, cur)
            local ok = (p.which == "backup" and deps.restore_backup(cur.kind_id))
                or (p.which == "onload" and deps.restore_onload_backup(cur.kind_id))
            if not ok then return false end
            deps.request_reapply()
            return "saved"
        end,
    }

    function controller.action(p)
        p = type(p) == "table" and p or {}
        if p.kind == "character" then
            selected = p.id
            palette_sel = {}    -- 选中的材质键是按角色的
            return controller.snapshot()
        end
        if p.kind == "setting" then
            if not Ops.set_global(deps.global_config, p.id, p.value) then error(T("reff_action_rejected")) end
            deps.save_global_settings()
            return controller.snapshot()
        end
        local cur = current()
        if not cur or (p.character and p.character ~= cur.group.gid) then error(T("reff_character_changed")) end

        if p.kind == "migrate" then
            local report = deps.migrate_to_v3(cur.kind_id)
            if not report then error(T("reff_action_rejected")) end
            notice = { kind = "migrated", presets = #(report.presets or {}) }
            deps.reset_ui_state()
            return controller.snapshot()
        end
        -- 其他操作只认 v3:v2 配置要先迁移
        if not M3.is_v3(cur.config) then error(T("reff_needs_migration")) end
        local handler = actions[p.kind]
        if not handler then error(T("reff_action_rejected")) end
        local changed, reapply = handler(p, cur.config, cur)
        if not changed then error(T("reff_action_rejected")) end
        if changed ~= "saved" then deps.commit(cur.kind_id, changed, reapply) end
        -- 面板上正在填的表单按旧值缓存,改过之后让它重新读
        deps.reset_ui_state()
        return controller.snapshot()
    end

    -- 全身预览的心跳(可见、尺寸);没有预览能力时如实报告
    function controller.preview(request)
        if not deps.preview then return { available = false, enabled = false, status = "preview_native_missing" } end
        return deps.preview.action(request)
    end

    function controller.documentation()
        local docs = deps.documentation[language()] or deps.documentation.en
        local out = { sections = {} }
        for _, section in ipairs(docs) do
            local row = { id = section.id, title = section.title, entries = {} }
            for _, entry in ipairs(section.entries) do
                local paragraphs = {}
                for _, para in ipairs(entry.paragraphs) do paragraphs[#paragraphs + 1] = para end
                row.entries[#row.entries + 1] = { title = entry.title, paragraphs = paragraphs }
            end
            out.sections[#out.sections + 1] = row
        end
        return out
    end

    return controller
end

-- REFF 未安装时 Bridge 直接返回 nil,REF 原生面板照常可用。
function Reff.connect(deps)
    local controller = Reff.new(deps)
    return controller, Bridge.register(controller)
end

return Reff
