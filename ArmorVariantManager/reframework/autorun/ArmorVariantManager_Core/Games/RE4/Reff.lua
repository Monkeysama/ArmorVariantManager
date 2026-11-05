-- RE4 的 REFF 网页接口:快照 / 操作 / 帮助。
--
-- 网页只拿到可序列化的数据(字符串、数字、布尔),不传托管对象。改配置一律走 Ops,
-- 和 ImGui 面板同一套语义;存盘与重写由 Main 提供的 commit 完成。
-- 网页维护自己的"当前角色",和 ImGui 面板的选择互不影响;每个操作都带上角色 id,
-- 角色在两次刷新之间变了就拒绝执行,避免改到别人身上。
local Ops = require("ArmorVariantManager_Core.Games.RE4.Ops")
local Bridge = require("ArmorVariantManager_Core.UI.Reff.Bridge")

local Reff = {}

-- deps(都由 Main.start 提供):
--   version, global_config, save_global_settings, T
--   targets()                      -> Targets.collect()
--   groups(targets)                -> collect_character_groups
--   pick_group(groups, order, id)  -> pick_character_group
--   resolve_key(target), cfg_key(id), register_kind(id), load_config(id, source, allow_kin)
--   commit(id, changed, reapply), reset_ui_state()
--   ordered_presets(layer), char_display(char), target_label(target)
--   TransformManager, Registry, Utils, documentation
--   编辑 / 归属 / 存档(和面板同一批函数):slot_label, visible_slots, request_reapply,
--   snapshot_before_destructive, config_is_trivial, make_independent, reset_config, try_match_kin,
--   save_slot, load_slot, delete_slot, all_slot_entries, auto_slot_name, has_backup, has_onload_backup,
--   restore_backup, restore_onload_backup, start_preview, get_preview
function Reff.new(deps)
    local controller = {}
    local selected = nil
    local T, TM, Registry = deps.T, deps.TransformManager, deps.Registry

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

    local function condition_defs(context)
        local out = {}
        for _, def in ipairs(Registry.all()) do
            local row = { id = def.id, kind = def.kind, label = T(def.label_key) }
            if def.kind == "number" then row.ops = Registry.NUM_OPS
            elseif def.kind == "enum" then
                row.ops = Registry.ENUM_OPS
                row.options = {}
                for _, o in ipairs(def.options and def.options(context, language()) or {}) do
                    row.options[#row.options + 1] = { value = o.value, label = o.label }
                end
            end
            -- 当前值:规则编辑时对着调阈值用。读不到(没有玩家、方法缺失)就不给。
            if context then
                local ok, value = pcall(def.get, context)
                if ok and (type(value) == "number" or type(value) == "boolean") then row.value = value end
            end
            out[#out + 1] = row
        end
        return out
    end

    local function condition_row(c)
        local def = Registry.get(c.type)
        local row = { type = tostring(c.type), op = c.op, value = c.value,
                      label = def and T(def.label_key) or tostring(c.type), known = def ~= nil }
        if def and def.kind == "enum" and def.value_label then
            row.valueLabel = def.value_label(c.value, language())
        end
        return row
    end

    local function rule_row(rule, index, priority, effective_name, context)
        local driven = rule.dissolve_hp_driven == true
        -- 用带闩锁的判定:「保持中」的那几秒也算命中,否则概览和画面对不上
        local hits = (not driven) and priority ~= nil and TM.rule_hits(rule, context) == true
        local row = { index = index, preset = tostring(rule.preset or ""), priority = priority,
            logic = (rule.logic == "OR") and "OR" or "AND", hold = tonumber(rule.hold) or 0,
            conditions = {}, hits = hits, effective = hits and effective_name == rule.preset,
            orphan = priority == nil,
            dissolve = { enabled = rule.dissolve_enabled == true,
                hideTime = tonumber(rule.dissolve_hide_time) or 0.5, showTime = tonumber(rule.dissolve_show_time) or 0.5 },
            hpDrive = { enabled = driven, upper = tonumber(rule.dissolve_hp_upper) or 100,
                lower = tonumber(rule.dissolve_hp_lower) or 0, invert = rule.dissolve_hp_invert == true } }
        for _, c in ipairs(rule.conditions or {}) do row.conditions[#row.conditions + 1] = condition_row(c) end
        return row
    end

    -- 预设里存的材质值(整套造型二值整份,状态组稀疏 = 没写的是"不管")。只拷值,不交出配置表。
    local function preset_values(preset)
        local out = {}
        for slot, data in pairs(preset or {}) do
            if type(data) == "table" and type(data.materials) == "table" and next(data.materials) then
                out[slot] = {}
                for m, v in pairs(data.materials) do out[slot][m] = v == true end
            end
        end
        return out
    end

    -- 整套造型的逐槛位闸门,三态(同面板列表上的标记):
    --   全部对不上 → mismatch(整份跳过);部分对不上 → partial,列出被跳过的槛位;都对得上 → ok。
    -- 只报"模型上真有、预设里也写了、但对不上"的槛位,模型上不存在的槛位不算问题。
    local function base_match(source, preset)
        local usable = TM.usable_slots(source, preset)
        local skipped = {}
        for _, slot in ipairs(deps.Utils.MESH_SLOTS) do
            local sd = preset and preset[slot]
            local has_stored = type(sd) == "table" and next(sd.materials or {}) ~= nil
            if has_stored and deps.Utils.get_mesh(source, slot) and not usable[slot] then
                skipped[#skipped + 1] = deps.slot_label(slot)
            end
        end
        if next(usable) == nil then return { status = "mismatch", skipped = skipped } end
        return { status = (#skipped > 0) and "partial" or "ok", skipped = skipped }
    end

    local function layer_row(name, layer, is_base, context, source)
        local effective, from_rule = TM.pick_active_preset(layer, context)
        local presets = deps.ordered_presets(layer)
        local row = { name = name, base = is_base, presets = presets, active = layer.active or "",
            effective = effective, fromRule = from_rule == true, auto = layer.auto ~= false,
            advanced = (not is_base) and TM.axis_is_advanced(layer) == true, rules = {},
            values = {}, match = is_base and {} or nil }
        for _, preset in ipairs(presets) do
            row.values[preset] = preset_values(layer.presets[preset])
            if is_base then row.match[preset] = base_match(source, layer.presets[preset]) end
        end
        -- 按优先级(状态顺序)列规则;指向已不存在状态的规则排在最后,标成孤儿 ——
        -- 它永远不会生效,但必须看得见、删得掉
        local shown = {}
        for priority, preset in ipairs(presets) do
            for i, rule in ipairs(layer.rules or {}) do
                if rule.preset == preset then
                    shown[i] = true
                    row.rules[#row.rules + 1] = rule_row(rule, i, priority, effective, context)
                end
            end
        end
        for i, rule in ipairs(layer.rules or {}) do
            if not shown[i] then row.rules[#row.rules + 1] = rule_row(rule, i, nil, effective, context) end
        end
        return row
    end

    function controller.snapshot()
        local g = deps.global_config
        local snapshot = { game = "RE4", version = deps.version, language = language(),
            settings = { weaponHideStorage = g.weapon_hide_storage == true,
                uiDissolveEnabled = g.ui_dissolve_enabled ~= false,
                uiDissolveTime = tonumber(g.ui_dissolve_time) or 1.0 },
            characters = {}, character = "" }
        local cur, groups, order = current()
        for _, gid in ipairs(order) do
            local group = groups[gid]
            local row = { id = gid, label = deps.char_display(group.char) or gid,
                configured = group.key ~= nil, targets = {} }
            for _, t in ipairs(group.targets) do row.targets[#row.targets + 1] = deps.target_label(t) end
            snapshot.characters[#snapshot.characters + 1] = row
        end
        if not cur then return snapshot end

        local context, config = cur.context, cur.config
        snapshot.character = cur.group.gid
        local shared = deps.cfg_key(cur.kind_id)
        if shared ~= cur.kind_id then snapshot.sharedWith = shared end

        -- 状态条:血量 + 当前为真的布尔条件。没有玩家(只剩傀儡)时条件没有值可显示。
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
        local source = cur.target.source
        snapshot.base = layer_row(T("base_layer"), config.base, true, context, source)
        snapshot.axes = {}
        for _, name in ipairs(TM.get_axis_names(config)) do
            snapshot.axes[#snapshot.axes + 1] = layer_row(name, config.axes[name], false, context, source)
        end

        -- 编辑用:当前代表目标(优先玩家)各槛位的材质与显示状态、备注、护甲镜像、作用域冲突。
        -- 镜像开着时 armor 在预设里编辑没有意义(resolve 会整份覆盖),标出来让页面收起它。
        local editor = { armorMirror = config.armor_mirrors_body == true, slots = {}, conflicts = {} }
        for _, slot in ipairs(deps.visible_slots(source)) do
            local mesh = deps.Utils.get_mesh(source, slot)
            local states = deps.Utils.current_material_states(mesh)
            local notes = (config.material_notes or {})[slot] or {}
            local row = { id = slot, label = deps.slot_label(slot), materials = {},
                mirrored = slot == "armor" and config.armor_mirrors_body == true }
            local seen = {}
            for _, m in ipairs(deps.Utils.get_material_names(mesh)) do
                -- 同一个 mesh 里材质名可能重复;配置按名字存,页面上一个名字一行
                if not seen[m] then
                    seen[m] = true
                    row.materials[#row.materials + 1] = { name = m, enabled = states[m] ~= false, note = notes[m] }
                end
            end
            editor.slots[#editor.slots + 1] = row
        end
        for _, c in ipairs(TM.find_scope_conflicts(config)) do
            local parts = {}
            for _, part in ipairs(c.parts) do parts[#parts + 1] = { axis = part.axis, on = part.on, off = part.off } end
            editor.conflicts[#editor.conflicts + 1] = { key = c.key, parts = parts }
        end
        local preview = deps.get_preview()
        if preview and preview.target_id == cur.target.id then
            editor.locating = { slot = preview.slot, material = preview.mat }
        end
        snapshot.editor = editor

        -- 归属:共用时只能「独立」;独立时可以初始化;配置没什么可丢时才给「匹配同角色配置」。
        snapshot.ownership = { shared = shared ~= cur.kind_id,
            canReset = shared == cur.kind_id,
            canMatchKin = shared == cur.kind_id and deps.config_is_trivial(config) }

        -- 存档:命名存档跨角色列出(自己的在前,别人的只能读不能删)+ 两个自动还原点。
        local saves = { slots = {}, hasBackup = deps.has_backup(cur.kind_id) == true,
            hasOnload = deps.has_onload_backup(cur.kind_id) == true }
        for _, e in ipairs(deps.all_slot_entries(cur.kind_id)) do
            saves.slots[#saves.slots + 1] = { key = e.key, name = e.name, own = e.own == true, label = e.label }
        end
        snapshot.saves = saves
        return snapshot
    end

    local function integer(value) return math.tointeger(tonumber(value)) end

    -- 一个操作只改当前角色的一层;名字为 nil 时是整套造型。
    local layer_actions = {
        active = function(l, p) return Ops.set_active(l, tostring(p.preset or "")) end,
        auto = function(l, p) return Ops.set_auto(l, p.enabled == true) end,
        ["rule-delete"] = function(l, p) return Ops.delete_rule(l, integer(p.rule)) end,
        ["condition-delete"] = function(l, p) return Ops.delete_condition(l, p.preset, integer(p.index)) end,
        hold = function(l, p) return Ops.set_hold(l, p.preset, p.value) end,
        dissolve = function(l, p) return Ops.set_dissolve(l, p.preset, p.enabled == true) end,
        ["dissolve-time"] = function(l, p) return Ops.set_dissolve_time(l, p.preset, p.field, p.value) end,
        ["hp-drive"] = function(l, p) return Ops.set_hp_driven(l, p.preset, p.enabled == true) end,
        ["hp-bound"] = function(l, p) return Ops.set_hp_bound(l, p.preset, p.field, p.value) end,
        ["hp-invert"] = function(l, p) return Ops.set_hp_invert(l, p.preset, p.enabled == true) end,
        ["condition-add"] = function(l, p, cur)
            local c = type(p.condition) == "table" and p.condition or {}
            local cond = Ops.make_condition(deps.Registry.get(c.type), c.op, c.value, cur.context, language())
            if not cond then return false end
            return Ops.add_condition(l, p.preset, cond, p.logic)
        end,

        -- 预设 / 状态的编辑。整套造型新建时抓当前外观,状态组从空开始(同面板)。
        ["preset-new"] = function(l, _, cur, is_base)
            return Ops.new_preset(l, is_base and deps.Utils.capture_current_as_preset(cur.target.source) or {})
        end,
        ["preset-duplicate"] = function(l, p) return Ops.duplicate_preset(l, p.preset) end,
        ["preset-rename"] = function(l, p) return Ops.rename_preset(l, p.preset, p.name) end,
        ["preset-move"] = function(l, p) return Ops.move_preset(l, p.preset, integer(p.offset)) end,
        -- 删除和重新抓取不可逆,先留一份备份(「最近一次删除 / 覆写之前」还原点)
        ["preset-delete"] = function(l, p, cur)
            if not l.presets[p.preset] then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            return Ops.delete_preset(l, p.preset)
        end,
        -- 只有整套造型能整份重新抓取;逐槛位覆写,对不上的槛位保持原值(判据同应用时的闸门)
        ["preset-recapture"] = function(l, p, cur, is_base)
            local prev = l.presets[p.preset]
            if not is_base or not prev then return false end
            deps.snapshot_before_destructive(cur.kind_id)
            local source = cur.target.source
            return Ops.replace_preset(l, p.preset,
                deps.Utils.capture_preserving_unmatched(source, prev, TM.usable_slots(source, prev)))
        end,
        material = function(l, p, _, is_base)
            local value = p.value
            if is_base then value = p.value == true or p.value == "on" end
            return Ops.set_material(l.presets[p.preset], p.slot, p.material, value, is_base)
        end,
        ["slot-bulk"] = function(l, p, cur, is_base)
            local mesh = deps.Utils.get_mesh(cur.target.source, p.slot)
            if not mesh then return false end
            return Ops.bulk_slot(l.presets[p.preset], p.slot, p.op, deps.Utils.get_material_names(mesh),
                deps.Utils.current_material_states(mesh), is_base)
        end,
    }

    -- 角色级操作:不针对某一层。返回 changed, reapply;已经自己存过盘的返回 "saved"。
    local config_actions = {
        ["axis-new"] = function(p, cur) return Ops.new_axis(cur.config, p.name) end,
        ["axis-rename"] = function(p, cur) return Ops.rename_axis(cur.config, p.axis, p.name) end,
        ["axis-delete"] = function(p, cur) return Ops.delete_axis(cur.config, p.axis) end,
        ["armor-mirror"] = function(p, cur) return Ops.set_armor_mirror(cur.config, p.enabled == true) end,
        note = function(p, cur) return Ops.set_note(cur.config, p.slot, p.material, p.text) end,
        -- 定位只是临时预览,不改配置
        locate = function(p, cur)
            if type(p.slot) ~= "string" or type(p.material) ~= "string" then return false end
            deps.start_preview(cur.target.id, p.slot, p.material)
            return "saved"
        end,
        ["make-independent"] = function(_, cur) return deps.make_independent(cur.kind_id) and "saved" end,
        ["reset-config"] = function(_, cur) return deps.reset_config(cur.kind_id, cur.target.source) and "saved" end,
        ["match-kin"] = function(_, cur)
            if not deps.config_is_trivial(cur.config) then return false end
            if not deps.try_match_kin(cur.kind_id, cur.target.source) then error(T("reff_no_kin")) end
            deps.request_reapply()
            return "saved"
        end,
        -- 命名存档:留空自动命名,重名覆盖(存档位的直觉);读档复制进当前角色,不动来源
        ["slot-save"] = function(p, cur)
            local name = (type(p.name) == "string" and p.name ~= "") and p.name or deps.auto_slot_name()
            deps.save_slot(cur.kind_id, name)
            return "saved"
        end,
        ["slot-load"] = function(p, cur)
            if not deps.load_slot(cur.kind_id, p.name, p.key) then return false end
            deps.request_reapply()
            return "saved"
        end,
        ["slot-delete"] = function(p, cur) return deps.delete_slot(cur.kind_id, p.name) and "saved" end,
        restore = function(p, cur)
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
        local handler, config_handler = layer_actions[p.kind], config_actions[p.kind]
        if not handler and not config_handler then error(T("reff_action_rejected")) end
        local cur = current()
        if not cur or (p.character and p.character ~= cur.group.gid) then error(T("reff_character_changed")) end
        local changed, reapply
        if config_handler then
            changed, reapply = config_handler(p, cur)
        else
            local layer = p.axis and cur.config.axes[p.axis] or (not p.axis and cur.config.base)
            if not layer then error(T("reff_action_rejected")) end
            changed, reapply = handler(layer, p, cur, layer == cur.config.base)
        end
        if not changed then error(T("reff_action_rejected")) end
        if changed ~= "saved" then deps.commit(cur.kind_id, changed, reapply) end
        -- 面板上正在填的表单(hold 输入框、正在编辑的预设名之类)按旧值缓存,改过之后让它重新读
        deps.reset_ui_state()
        return controller.snapshot()
    end

    function controller.documentation()
        local docs = deps.documentation[language()] or deps.documentation.en
        local out = { sections = {} }
        for _, section in ipairs(docs) do
            local row = { id = section.id, title = section.title, entries = {} }
            for _, entry in ipairs(section.entries) do
                local paragraphs = {}
                for _, p in ipairs(entry.paragraphs) do paragraphs[#paragraphs + 1] = p end
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
