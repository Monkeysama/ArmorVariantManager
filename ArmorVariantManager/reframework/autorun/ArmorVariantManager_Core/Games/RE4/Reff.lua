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
function Reff.new(deps)
    local controller = {}
    local selected = nil
    local notice = nil     -- 一次性提示(迁移结果之类),随下一份快照交给网页
    local T, TM, Registry, Utils = deps.T, deps.TransformManager, deps.Registry, deps.Utils

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
            targets = {}, conditions = {} }
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
                match = base_match(source, base.presets[name]), height = (base.heights or {})[name] }
        end

        snapshot.groups = {}
        for _, g in ipairs(config.groups) do
            local key = M3.layer_key(g.name)
            local row = { name = g.name, scope = {}, active = g.active, effective = v3.picks[key],
                fromState = (info.layers[key] or {}).prio, options = {} }
            for k, s in ipairs(g.scope) do row.scope[k] = s end
            for _, name in ipairs(g.order) do
                row.options[#row.options + 1] = { name = name, values = values_of(g.options[name]), height = (g.heights or {})[name] }
            end
            snapshot.groups[#snapshot.groups + 1] = row
        end

        -- 这一帧生效的模型高度(厘米,nil = 不抬高;总开关关掉时也照算,界面上另外标出)
        -- heightSource:来自哪一层("override" / "base" / 状态组名 + 选项名);heightOverride:快速切换页的全局覆盖
        local cm, src = M3.height_of(config, v3.picks)
        snapshot.height, snapshot.heightSource = cm, src
        local o = config.height_override
        snapshot.heightOverride = { enabled = type(o) == "table" and o.enabled == true, cm = type(o) == "table" and o.cm or 0 }

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
        -- 模型高度:cm = nil 清除
        ["base-height"] = function(p, cfg) return OpsV3.set_height(cfg, "base", p.preset, p.cm) end,
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
