-- 独立面板各页共用的文字拼装,对应 web/src/re4/util.ts(两边的句子要一致)。
local M = {}

function M.split_key(key)
    local i = key:find("/", 1, true)
    if not i then return key, "" end
    return key:sub(1, i - 1), key:sub(i + 1)
end
function M.key_of(slot, material) return slot .. "/" .. material end

-- 部位名只留中文 / 英文名,去掉括号里的内部 id(「身体 (body / 00)」→「身体」)
function M.short_slot(label)
    label = tostring(label or "")
    local s = label:gsub("%s*[%(（][^%(%)（）]*[%)）]%s*$", "")
    return s ~= "" and s or label
end

function M.slot_label(snap, id)
    for _, s in ipairs(snap.slots or {}) do
        if s.id == id then return M.short_slot(s.label) end
    end
    return id
end

-- ---------------------------------------------------------------- 显示名(双语)
-- 名字是引用键,发动作一律用 name;显示用 label(快照里只在和名字不同时才有,见 Reff.lua 的 label_if)。
-- 对应 web/src/re4/util.ts 的 labelOf / baseLabel / groupLabel / optionLabel / stateLabel
function M.label(x) return x and (x.label or x.name) or "" end
function M.base_label(snap, name)
    for _, p in ipairs((snap.base and snap.base.presets) or {}) do if p.name == name then return M.label(p) end end
    return name
end
local function group_of(snap, name)
    for _, g in ipairs(snap.groups or {}) do if g.name == name then return g end end
end
function M.group_label(snap, name)
    local g = group_of(snap, name)
    return g and M.label(g) or name
end
function M.option_label(snap, group, name)
    local g = group_of(snap, group)
    for _, o in ipairs(g and g.options or {}) do if o.name == name then return M.label(o) end end
    return name
end
-- 第 i 个条件状态的显示名;states 省略时取 snap.states
function M.state_label(states, i) return states[i or 0] and M.label(states[i]) or nil end

local KIND_KEY = { active = "kindActive", partial = "kindPartial", outranked = "kindOutranked", idle = "kindIdle",
    off = "kindOff", paused = "kindPaused" }
M.KIND_KEY = KIND_KEY

function M.kind_text(st, states, t)
    local text = t(KIND_KEY[st.kind] or "kindIdle")
    if st.kind == "outranked" and st.by and states[st.by] then text = text .. "，" .. t("coveredBy", M.label(states[st.by])) end
    if st.holding and (st.kind == "active" or st.kind == "partial") then text = text .. "，" .. t("holding") end
    return text
end

-- 认领结果的文字和颜色类别("ok" / "bad" / "broken")
function M.result_text(r, states, t)
    if not r then return "", nil end
    if r.kind == "broken" then return t("broken"), "broken" end
    if r.kind == "win" then return t("win"), "ok" end
    return t("coveredBy", M.state_label(states, r.by) or "?"), "bad"
end

local OP_TEXT = { ["<="] = "≤", ["<"] = "<", [">="] = "≥", [">"] = ">", ["=="] = "=", ["~="] = "≠" }
function M.op_text(op) return OP_TEXT[op or "<="] or tostring(op or "") end

local function num_text(v)
    if type(v) ~= "number" then return tostring(v) end
    local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
    return s
end
M.num_text = num_text

function M.condition_text(c, t)
    if not c.known then return t("unknownCondition") .. " " .. tostring(c.type) end
    if type(c.value) == "boolean" then return c.value and c.label or (c.label .. " = " .. t("no")) end
    if c.valueLabel ~= nil then return c.label .. " " .. (c.op == "~=" and "≠" or "=") .. " " .. c.valueLabel end
    local pct = c.label:sub(-1) == "%"
    return c.label:gsub("%s*%%$", "") .. " " .. M.op_text(c.op) .. " " .. num_text(c.value) .. (pct and "%" or "")
end

function M.condition_sentence(st, t)
    if st.hp then return t("sentenceHp", num_text(st.hp.upper), num_text(st.hp.lower)) end
    if #st.conditions == 0 then return t("sentenceNoCond") end
    local parts = {}
    for i, c in ipairs(st.conditions) do parts[i] = M.condition_text(c, t) end
    local joined = table.concat(parts, st.logic == "OR" and ("，" .. t("or")) or ("，" .. t("and")))
    return t("sentenceWhen", joined) .. ((st.hold or 0) > 0 and t("sentenceHold", num_text(st.hold)) or "")
end

function M.target_sentence(st, t, snap)
    local parts = {}
    if st.base then parts[#parts + 1] = t("targetPair", t("baseTarget"), snap and M.base_label(snap, st.base) or st.base) end
    for _, tg in ipairs(st.targets) do
        parts[#parts + 1] = t("targetPair", snap and M.group_label(snap, tg.group) or tg.group,
            snap and M.option_label(snap, tg.group, tg.option) or tg.option)
    end
    if st.weapons then
        parts[#parts + 1] = t("targetPair", t("weaponsTarget"), t(st.weapons == "all" and "weaponsAll" or "weaponsStowed"))
    end
    if #parts == 0 then return t("noTargets") end
    return table.concat(parts, t("targetSep"))
end

-- 条件行右边的"现在:…"
function M.current_value_text(def, t)
    if not def or def.value == nil then return "" end
    if def.kind == "bool" then return def.value and t("yes") or t("no") end
    if def.kind == "enum" then
        for _, o in ipairs(def.options or {}) do if o.value == def.value then return o.label end end
        return tostring(def.value)
    end
    if def.label:sub(-1) == "%" then return num_text(math.floor(def.value * 10 + 0.5) / 10) .. "%" end
    return num_text(def.value)
end

-- 某个状态组 / 选项被哪些条件状态用着(group = nil 表示整套造型)
function M.users_of(snap, group, option)
    local out = {}
    for _, s in ipairs(snap.states or {}) do
        local hit = false
        if group == nil then
            hit = option == nil and s.base ~= nil or (option ~= nil and s.base == option)
        else
            for _, tg in ipairs(s.targets) do
                if tg.group == group and (option == nil or tg.option == option) then hit = true end
            end
        end
        if hit then out[#out + 1] = s end
    end
    return out
end

function M.names(list, sep)
    local out = {}
    for i, s in ipairs(list) do out[i] = M.label(s) end
    return table.concat(out, sep or "」「")
end

function M.find(list, pred)
    for i, v in ipairs(list or {}) do if pred(v) then return v, i end end
    return nil
end

function M.contains(list, value)
    for _, v in ipairs(list or {}) do if v == value then return true end end
    return false
end

return M
