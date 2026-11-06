-- 独立面板(没有 REFF 时的兜底图形界面)的颜色(ARGB)与尺寸。
-- 照搬 ShapeKeySystem 的 ShapeKeySystem_UI/Theme.lua(d026d06,2026-11-04):两个插件的用户基本是同一批人,
-- 观感一致;状态色按 AVM 的约定:绿 = 生效、红 = 被覆盖(有问题)、灰 = 未命中。

local T = {}

T.c = {
    shade    = 0x66000000,
    panel    = 0xF2161C23,
    panel2   = 0xFF1D252E,
    panel3   = 0xFF26303B,
    ink      = 0xFF0F1419,
    line     = 0xFF34404C,
    text     = 0xFFE6E1D6,
    muted    = 0xFF8F9AA5,
    faint    = 0xFF5D6872,
    brass    = 0xFFD6A24A,
    brass_dim = 0xFF8A6A33,
    signal   = 0xFF58C4B0,
    signal_dim = 0xFF2B6158,
    warn     = 0xFFE0875A,
    ok       = 0xFF7FC47A,
    ok_dim   = 0xFF2F5A33,
    error    = 0xFFE05A5A,
    error_dim = 0xFF5A2A2A,
}

T.font = { body = 14, small = 12, title = 16, big = 15 }

T.m = {
    title_h = 40, rail_w = 132, status_h = 26, pad = 14, row_h = 28, gap = 8, radius = 4,
    min_w = 640, min_h = 420,
}

return T
