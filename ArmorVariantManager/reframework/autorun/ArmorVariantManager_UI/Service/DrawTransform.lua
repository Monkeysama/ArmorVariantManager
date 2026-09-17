-- =============================================================================
-- 外部 reframework-d2d 兼容层：在 Lua 侧复现本项目 fork 的作用域变换
-- =============================================================================
-- 为什么需要这一层：
--   ArmorVariantManager_UI.dll 是 reframework-d2d 的 fork，额外提供
--     d2d.push_transform(x, y, scale) / d2d.pop_transform()
--   （C++ 侧用 D2D1 矩阵实现，连字形一起缩放），弹窗整体缩放依赖它。
--   游戏目录里同时存在第三方 reframework-d2d.dll 时，本 DLL 会主动让出渲染器
--   （避免两套 renderer 抢 SwapChain），Lua 拿到的 d2d 全局由外部插件提供，
--   而外部插件没有这两个函数。
--   此时若只把缺失的函数补成空实现，缩放会静默失效：
--   输入换算（Runtime.ui_scale）仍按缩放走，绘制却停在 1.0，
--   表现为拖动边框后画面尺寸不变，且鼠标与控件错位。
--
-- 复现方式（与 C++ 语义逐项对齐）：
--   * 组合顺序：C++ 为 M * Scale(s) * Translation(x, y)（D2D1 行向量约定），
--     因此累加关系是 scale' = scale * s、offset' = offset * s + (x, y)；
--   * 坐标参数 -> offset + point * scale；长度/半径/线宽 -> length * scale；
--   * 文本 -> 换成同族、字号 * scale 的字体绘制（D2D 字形无法单独变换），
--     但 measure 始终用原始字号，布局尺寸仍是逻辑值，缩放不改变排版；
--   * 未进入变换作用域时全部直接透传，外部 D2D 原有绘制路径零改动。
-- =============================================================================

local DrawTransform = {}

local unpack_values = table.unpack or unpack

-- 绘制函数参数位置（1 基），与 ArmorVariantManager_UI.dll 的 lua 绑定一致。
--   x / y    坐标参数：分别用变换的 x / y 偏移做平移，再乘缩放
--   lengths  长度/半径/线宽：只乘缩放
--   font     字体对象所在位置：缩放时换成同族放大字体
--   font_base 字体对象所在位置：始终使用原始字号（用于测量）
local ARG_SPEC = {
    text = { x = { 3 }, y = { 4 }, font = 1 },
    measure_text = { font_base = 1 },
    fill_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    filled_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    outline_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5 } },
    rounded_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5, 6, 7 } },
    fill_rounded_rect = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5, 6 } },
    quad = { x = { 1, 3, 5, 7 }, y = { 2, 4, 6, 8 }, lengths = { 9 } },
    fill_quad = { x = { 1, 3, 5, 7 }, y = { 2, 4, 6, 8 } },
    line = { x = { 1, 3 }, y = { 2, 4 }, lengths = { 5 } },
    image = { x = { 2 }, y = { 3 }, lengths = { 4, 5 } },
    fill_circle = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    fill_oval = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    circle = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5 } },
    oval = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 5 } },
    pie = { x = { 1 }, y = { 2 }, lengths = { 3 } },
    outline_pie = { x = { 1 }, y = { 2 }, lengths = { 3, 6 } },
    ring = { x = { 1 }, y = { 2 }, lengths = { 3, 4 } },
    outline_ring = { x = { 1 }, y = { 2 }, lengths = { 3, 4, 7 } }
}

local EMPTY = {}

-- 字体代理：布局代码只使用 measure，测量一律走原始字号（逻辑尺寸）。
local FONT_PROXY_MEASURE = function(proxy, value)
    return proxy.base:measure(value)
end

local FONT_PROXY_MT = {
    __index = function(_, key)
        if key == "measure" then return FONT_PROXY_MEASURE end
        return nil
    end
}

local function is_font_proxy(value)
    return type(value) == "table" and rawget(value, "__avm_font_proxy") == true
end

-- 外部 D2D 不支持对字形做矩阵变换，只能按缩放换一个字号重新创建字体。
-- 字号必须是整数（lua 绑定签名是 int），四舍五入到最近整数即可，
-- 例如 18 号字在 0.65 倍下渲染为 12 号，与原生矩阵缩放的视觉差异可忽略。
local function resolve_scaled_font(proxy, scale)
    if scale == 1 then return proxy.base end
    local size = math.floor(proxy.size * scale + 0.5)
    if size < 1 then size = 1 end
    local cached = proxy.scaled[size]
    if cached then return cached end
    local created = proxy.make_variant(size)
    if created == nil then created = proxy.base end
    proxy.scaled[size] = created
    return created
end

-- 外部 D2D 是否缺少本项目 fork 的作用域变换扩展。
function DrawTransform.needs_wrap(api)
    if type(api) ~= "table" then return false end
    return type(api.push_transform) ~= "function" or type(api.pop_transform) ~= "function"
end

-- 用坐标换算代理包住外部 d2d 全局。
-- 未命中 ARG_SPEC 的成员（surface_size、register、bridge 等）原样透传。
function DrawTransform.wrap(api)
    if type(api) ~= "table" then return api end

    local facade = setmetatable({}, { __index = api })
    -- 栈顶为累计变换，语义与 C++ 侧一致；初值为单位变换。
    local stack = { { scale = 1, x = 0, y = 0 } }

    -- 字体工厂：优先沿用 UI 现有的 Font.new 形式，旧版回退到 create_font。
    local font_factory = nil
    if type(api.Font) == "table" and type(api.Font.new) == "function" then
        font_factory = function(...) return api.Font.new(...) end
    elseif type(api.create_font) == "function" then
        font_factory = function(...) return api.create_font(...) end
    end

    local function make_font(...)
        local count = select("#", ...)
        local args = { ... }
        local base_ok, base = pcall(font_factory, unpack_values(args, 1, count))
        if not base_ok or base == nil then return nil end
        -- 只有「族名 + 字号」的构造形式才能换算字号；字体文件路径形式直接返回原字体。
        if count < 2 or type(args[2]) ~= "number" then return base end

        local proxy = {
            __avm_font_proxy = true,
            base = base,
            size = args[2],
            scaled = {}
        }
        -- 用与原始调用完全相同的参数个数构造变体，避免触碰可选参数的默认值。
        proxy.make_variant = function(new_size)
            local ok, font
            if count >= 4 then
                ok, font = pcall(font_factory, args[1], new_size, args[3], args[4])
            elseif count == 3 then
                ok, font = pcall(font_factory, args[1], new_size, args[3])
            else
                ok, font = pcall(font_factory, args[1], new_size)
            end
            if ok then return font end
            return nil
        end
        return setmetatable(proxy, FONT_PROXY_MT)
    end

    if font_factory then
        facade.Font = setmetatable({ new = make_font }, { __index = api.Font })
    end

    facade.push_transform = function(x, y, scale)
        local top = stack[#stack]
        local factor = tonumber(scale) or 1
        -- 与 C++ 侧 std::max(0.01f, scale) 保持一致，避免零/负缩放。
        if factor <= 0 then factor = 0.01 end
        stack[#stack + 1] = {
            scale = top.scale * factor,
            x = top.x * factor + (tonumber(x) or 0),
            y = top.y * factor + (tonumber(y) or 0)
        }
    end

    facade.pop_transform = function()
        -- 与 C++ 侧一致：单位变换不允许被弹出。
        if #stack > 1 then table.remove(stack) end
    end

    for name, spec in pairs(ARG_SPEC) do
        local raw = api[name]
        if type(raw) == "function" then
            local xs = spec.x or EMPTY
            local ys = spec.y or EMPTY
            local lengths = spec.lengths or EMPTY
            local x_count = #xs
            local y_count = #ys
            local length_count = #lengths
            local font_index = spec.font
            local base_font_index = spec.font_base
            local font_arg = font_index or base_font_index

            facade[name] = function(...)
                local top = stack[#stack]
                local identity = top.scale == 1 and top.x == 0 and top.y == 0
                local count = select("#", ...)
                local args = nil

                if font_arg then
                    args = { ... }
                    local font = args[font_arg]
                    if is_font_proxy(font) then
                        args[font_arg] = base_font_index and font.base
                            or resolve_scaled_font(font, top.scale)
                    end
                end

                if identity then
                    if args then return raw(unpack_values(args, 1, count)) end
                    return raw(...)
                end

                if not args then
                    args = { ... }
                end
                for i = 1, x_count do
                    local index = xs[i]
                    local value = args[index]
                    if type(value) == "number" then
                        args[index] = top.x + value * top.scale
                    end
                end
                for i = 1, y_count do
                    local index = ys[i]
                    local value = args[index]
                    if type(value) == "number" then
                        args[index] = top.y + value * top.scale
                    end
                end
                for i = 1, length_count do
                    local index = lengths[i]
                    local value = args[index]
                    if type(value) == "number" then
                        args[index] = value * top.scale
                    end
                end
                return raw(unpack_values(args, 1, count))
            end
        end
    end

    return facade
end

return DrawTransform
