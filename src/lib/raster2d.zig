//! Phase 52 rasterizer: rounded rectangles, anti-aliased lines and arcs,
//! gradients, layered shadows, nine-patch scaling and the public span fast
//! paths. All logic is fixed-point/vector-integer Zig: the kernel never needs
//! floating point, libc or a second graphics path.

const std = @import("std");
const gfx = @import("gfx.zig");

pub const Insets = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

/// Anti-aliased circle/rounded-corner coverage. `dx` and `dy` are doubled
/// pixel-center offsets and `rd` is the doubled radius, so half pixels remain
/// exact integers. The one-pixel band around the ideal circle is ramped
/// linearly, which is deliberately cheap and deterministic.
fn circleCoverage(dx: i32, dy: i32, rd: i32) u8 {
    if (rd <= 0) return 0;
    const d2: i64 = @as(i64, dx) * dx + @as(i64, dy) * dy;
    const inner: i64 = rd - 1;
    const outer: i64 = rd + 1;
    const inner2 = inner * inner;
    const outer2 = outer * outer;
    if (d2 <= inner2) return 255;
    if (d2 >= outer2) return 0;
    const span = outer2 - inner2;
    const cov = 255 - @divTrunc((d2 - inner2) * 255, span);
    return @intCast(@max(0, @min(255, cov)));
}

fn paint(dst: *gfx.Surface, x: i32, y: i32, color: gfx.Color, coverage: u8) void {
    if (coverage == 0) return;
    const alpha: u32 = (color >> 24) & 0xFF;
    const a: u32 = (alpha * @as(u32, coverage) + 127) / 255;
    if (a == 0) return;
    const src = (color & 0x00FF_FFFF) | (a << 24);
    if (a == 255) dst.setPixel(x, y, src) else dst.blendPixel(x, y, src, 255);
}

/// Fill a rounded rectangle. The straight cross is written with vector spans;
/// only the four corner squares take the per-pixel coverage path.
pub fn fillRoundedRect(dst: *gfx.Surface, rect: gfx.Rect, radius_in: u32, color: gfx.Color) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const visible = dst.clip(rect) orelse return;
    const limit: u32 = @intCast(@divTrunc(@min(rect.w, rect.h), 2));
    const radius = @min(radius_in, limit);
    if (radius == 0) {
        dst.fillRect(rect.x, rect.y, rect.w, rect.h, color);
        return;
    }
    const r: i32 = @intCast(radius);
    const mid_y0 = rect.y + r;
    const mid_y1 = rect.bottom() - r;
    if (mid_y1 > mid_y0) dst.fillRect(rect.x, mid_y0, rect.w, mid_y1 - mid_y0, color);
    const middle_w = rect.w - 2 * r;
    if (middle_w > 0) {
        dst.fillRect(rect.x + r, rect.y, middle_w, r, color);
        dst.fillRect(rect.x + r, rect.bottom() - r, middle_w, r, color);
    }

    const corners = [_]gfx.Rect{
        .{ .x = rect.x, .y = rect.y, .w = r, .h = r },
        .{ .x = rect.right() - r, .y = rect.y, .w = r, .h = r },
        .{ .x = rect.x, .y = rect.bottom() - r, .w = r, .h = r },
        .{ .x = rect.right() - r, .y = rect.bottom() - r, .w = r, .h = r },
    };
    for (corners, 0..) |corner, ci| {
        const cx = if (ci == 0 or ci == 2) rect.x + r else rect.right() - r;
        const cy = if (ci < 2) rect.y + r else rect.bottom() - r;
        const c = dst.clip(corner) orelse continue;
        var y: i32 = c.y;
        while (y < c.bottom()) : (y += 1) {
            var x: i32 = c.x;
            while (x < c.right()) : (x += 1) {
                const dx: i32 = 2 * x + 1 - 2 * cx;
                const dy: i32 = 2 * y + 1 - 2 * cy;
                paint(dst, x, y, color, circleCoverage(dx, dy, 2 * r));
            }
        }
    }
    dst.damage.add(visible);
}

pub fn fillCircle(dst: *gfx.Surface, cx: i32, cy: i32, radius: u32, color: gfx.Color) void {
    if (radius == 0) return;
    const d: i32 = @intCast(radius * 2);
    fillRoundedRect(dst, .{ .x = cx - @as(i32, @intCast(radius)), .y = cy - @as(i32, @intCast(radius)), .w = d, .h = d }, radius, color);
}

/// Anti-aliased thick line with round caps. Distance is measured in doubled
/// coordinates; projection stays integer and is clamped to the segment.
pub fn line(dst: *gfx.Surface, x0: i32, y0: i32, x1: i32, y1: i32, width: u32, color: gfx.Color) void {
    if (width == 0) return;
    const w: i32 = @intCast(width);
    const ax: i32 = 2 * x0;
    const ay: i32 = 2 * y0;
    const vx: i32 = 2 * (x1 - x0);
    const vy: i32 = 2 * (y1 - y0);
    const len2: i64 = @as(i64, vx) * vx + @as(i64, vy) * vy;
    const pad = w + 2;
    const dx_abs: i32 = if (x1 >= x0) x1 - x0 else x0 - x1;
    const dy_abs: i32 = if (y1 >= y0) y1 - y0 else y0 - y1;
    const box = gfx.Rect{
        .x = @min(x0, x1) - pad,
        .y = @min(y0, y1) - pad,
        .w = dx_abs + 2 * pad + 1,
        .h = dy_abs + 2 * pad + 1,
    };
    const c = dst.clip(box) orelse return;
    var y: i32 = c.y;
    while (y < c.bottom()) : (y += 1) {
        var x: i32 = c.x;
        while (x < c.right()) : (x += 1) {
            const px: i32 = 2 * x + 1;
            const py: i32 = 2 * y + 1;
            var ddx: i32 = 0;
            var ddy: i32 = 0;
            if (len2 == 0) {
                ddx = px - ax;
                ddy = py - ay;
            } else {
                const wx: i32 = px - ax;
                const wy: i32 = py - ay;
                var dot: i64 = @as(i64, wx) * vx + @as(i64, wy) * vy;
                if (dot < 0) dot = 0;
                if (dot > len2) dot = len2;
                const qx: i32 = @intCast(@as(i64, ax) + @divTrunc(@as(i64, vx) * dot, len2));
                const qy: i32 = @intCast(@as(i64, ay) + @divTrunc(@as(i64, vy) * dot, len2));
                ddx = px - qx;
                ddy = py - qy;
            }
            paint(dst, x, y, color, circleCoverage(ddx, ddy, 2 * w));
        }
    }
    dst.damage.add(c);
}

// Q14 cos/sin for 0..64 steps of a full turn. Screen y grows downwards, so the
// sine table is intentionally positive-clockwise in framebuffer space.
const COS64 = [_]i16{
    16384,  16305,  16069,  15679,  15137,  14449,  13623,  12665,
    11585,  10394,  9102,   7723,   6270,   4756,   3196,   1606,
    0,      -1606,  -3196,  -4756,  -6270,  -7723,  -9102,  -10394,
    -11585, -12665, -13623, -14449, -15137, -15679, -16069, -16305,
    -16384, -16305, -16069, -15679, -15137, -14449, -13623, -12665,
    -11585, -10394, -9102,  -7723,  -6270,  -4756,  -3196,  -1606,
    0,      1606,   3196,   4756,   6270,   7723,   9102,   10394,
    11585,  12665,  13623,  14449,  15137,  15679,  16069,  16305,
    16384,
};
const SIN64 = [_]i16{
    0,      1606,   3196,   4756,   6270,   7723,   9102,   10394,
    11585,  12665,  13623,  14449,  15137,  15679,  16069,  16305,
    16384,  16305,  16069,  15679,  15137,  14449,  13623,  12665,
    11585,  10394,  9102,   7723,   6270,   4756,   3196,   1606,
    0,      -1606,  -3196,  -4756,  -6270,  -7723,  -9102,  -10394,
    -11585, -12665, -13623, -14449, -15137, -15679, -16069, -16305,
    -16384, -16305, -16069, -15679, -15137, -14449, -13623, -12665,
    -11585, -10394, -9102,  -7723,  -6270,  -4756,  -3196,  -1606,
    0,
};

/// Anti-aliased circular arc. Angles are steps of 1/64 turn, with 0 pointing
/// right and 16 pointing down the screen. The arc is a chain of round-capped
/// AA segments; 64 steps keep the chord error below a pixel at POS UI sizes.
pub fn arc(dst: *gfx.Surface, cx: i32, cy: i32, radius: u32, width: u32, start: u8, end: u8, color: gfx.Color) void {
    if (radius == 0 or width == 0 or end <= start or start >= 64) return;
    const stop: u8 = @min(end, 64);
    const rad: i32 = @intCast(radius);
    var i: u8 = start;
    while (i < stop) : (i += 1) {
        const a0: usize = @as(usize, i % 64);
        const a1: usize = @as(usize, (i + 1) % 64);
        const x0 = cx + @divTrunc(@as(i32, COS64[a0]) * rad, 16384);
        const y0 = cy + @divTrunc(@as(i32, SIN64[a0]) * rad, 16384);
        const x1 = cx + @divTrunc(@as(i32, COS64[a1]) * rad, 16384);
        const y1 = cy + @divTrunc(@as(i32, SIN64[a1]) * rad, 16384);
        line(dst, x0, y0, x1, y1, width, color);
    }
}

fn lerp(a: u32, b: u32, t: u32) u32 {
    return (a * (255 - t) + b * t + 127) / 255;
}

fn mix(c0: gfx.Color, c1: gfx.Color, t: u32) gfx.Color {
    return (lerp((c0 >> 24) & 0xFF, (c1 >> 24) & 0xFF, t) << 24) |
        (lerp((c0 >> 16) & 0xFF, (c1 >> 16) & 0xFF, t) << 16) |
        (lerp((c0 >> 8) & 0xFF, (c1 >> 8) & 0xFF, t) << 8) |
        lerp(c0 & 0xFF, c1 & 0xFF, t);
}

/// Two-stop linear gradient. Vertical gradients use the vector span path;
/// horizontal gradients composite one pixel per column.
pub fn linearGradient(dst: *gfx.Surface, rect: gfx.Rect, c0: gfx.Color, c1: gfx.Color, vertical: bool) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const c = dst.clip(rect) orelse return;
    if (vertical) {
        const denom: u32 = @intCast(@max(1, rect.h - 1));
        var y: i32 = c.y;
        while (y < c.bottom()) : (y += 1) {
            const t: u32 = @intCast(@divTrunc(@as(u32, @intCast(y - rect.y)) * 255, denom));
            const col = mix(c0, c1, t);
            if ((col >> 24) & 0xFF == 255) {
                dst.fillSpan(c.x, y, @intCast(c.w), col);
            } else {
                var x: i32 = c.x;
                while (x < c.right()) : (x += 1) dst.blendPixel(x, y, col, 255);
            }
        }
    } else {
        const denom: u32 = @intCast(@max(1, rect.w - 1));
        var y: i32 = c.y;
        while (y < c.bottom()) : (y += 1) {
            var x: i32 = c.x;
            while (x < c.right()) : (x += 1) {
                const t: u32 = @intCast(@divTrunc(@as(u32, @intCast(x - rect.x)) * 255, denom));
                dst.blendPixel(x, y, mix(c0, c1, t), 255);
            }
        }
    }
    dst.damage.add(c);
}

/// A soft shadow built from four concentric rounded layers. This is a bounded
/// approximation, not a Gaussian blur: it has no floating point and its cost
/// is known before drawing.
pub fn dropShadow(dst: *gfx.Surface, rect: gfx.Rect, radius: u32, spread: u32, color: gfx.Color) void {
    if (rect.w <= 0 or rect.h <= 0 or spread == 0) return;
    const alpha: u32 = (color >> 24) & 0xFF;
    const layers: u32 = 4;
    const dx: i32 = @intCast(spread / 2);
    const dy: i32 = @intCast(spread / 3 + 1);
    var i: u32 = layers;
    while (i > 0) {
        i -= 1;
        const grow: i32 = @intCast(@divTrunc(spread * i, layers));
        const a: u32 = alpha * (layers - i) / layers;
        if (a == 0) continue;
        const c = (color & 0x00FF_FFFF) | (a << 24);
        fillRoundedRect(dst, .{
            .x = rect.x + dx - grow,
            .y = rect.y + dy - grow,
            .w = rect.w + 2 * grow,
            .h = rect.h + 2 * grow,
        }, radius + @as(u32, @intCast(grow)), c);
    }
}

fn blitScaled(dst: *gfx.Surface, src: *const gfx.Surface, sr: gfx.Rect, dr: gfx.Rect, opacity: u8) void {
    if (sr.w <= 0 or sr.h <= 0 or dr.w <= 0 or dr.h <= 0) return;
    const s = src.clip(sr) orelse return;
    const d = dst.clip(dr) orelse return;
    var y: i32 = d.y;
    while (y < d.bottom()) : (y += 1) {
        const sy = sr.y + @divTrunc((y - dr.y) * sr.h, dr.h);
        if (sy < s.y or sy >= s.bottom()) continue;
        var x: i32 = d.x;
        while (x < d.right()) : (x += 1) {
            const sx = sr.x + @divTrunc((x - dr.x) * sr.w, dr.w);
            if (sx < s.x or sx >= s.right()) continue;
            dst.blendPixel(x, y, src.pixelAt(sx, sy), opacity);
        }
    }
    dst.damage.add(d);
}

/// Nine-patch scaling. Corners keep their source size (unless the destination
/// is smaller, in which case they are clipped), while the four edges and the
/// centre are nearest-neighbour stretched. Source and destination must differ.
pub fn ninePatch(dst: *gfx.Surface, src: *const gfx.Surface, src_rect: gfx.Rect, insets: Insets, dst_rect: gfx.Rect, opacity: u8) void {
    if (src_rect.w <= 0 or src_rect.h <= 0 or dst_rect.w <= 0 or dst_rect.h <= 0) return;
    const l: i32 = @intCast(@min(insets.left, @as(u32, @intCast(@divTrunc(src_rect.w, 2)))));
    const r: i32 = @intCast(@min(insets.right, @as(u32, @intCast(@divTrunc(src_rect.w, 2)))));
    const t: i32 = @intCast(@min(insets.top, @as(u32, @intCast(@divTrunc(src_rect.h, 2)))));
    const b: i32 = @intCast(@min(insets.bottom, @as(u32, @intCast(@divTrunc(src_rect.h, 2)))));
    const dl: i32 = @min(l, @divTrunc(dst_rect.w, 2));
    const dr: i32 = @min(r, @divTrunc(dst_rect.w, 2));
    const dt: i32 = @min(t, @divTrunc(dst_rect.h, 2));
    const db: i32 = @min(b, @divTrunc(dst_rect.h, 2));
    const sx = [_]i32{ src_rect.x, src_rect.x + l, src_rect.right() - r, src_rect.right() };
    const dx = [_]i32{ dst_rect.x, dst_rect.x + dl, dst_rect.right() - dr, dst_rect.right() };
    const sy = [_]i32{ src_rect.y, src_rect.y + t, src_rect.bottom() - b, src_rect.bottom() };
    const dy = [_]i32{ dst_rect.y, dst_rect.y + dt, dst_rect.bottom() - db, dst_rect.bottom() };
    var row: usize = 0;
    while (row < 3) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const s = gfx.Rect{ .x = sx[col], .y = sy[row], .w = sx[col + 1] - sx[col], .h = sy[row + 1] - sy[row] };
            const d = gfx.Rect{ .x = dx[col], .y = dy[row], .w = dx[col + 1] - dx[col], .h = dy[row + 1] - dy[row] };
            blitScaled(dst, src, s, d, opacity);
        }
    }
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

test "rounded rectangle clips corners and fills its straight body" {
    var buf = [_]u8{0} ** (48 * 32 * 4);
    var s = try gfx.Surface.init(&buf, 48, 32, 48 * 4, .rgba8888);
    s.clear(gfx.rgb(0, 0, 0));
    fillRoundedRect(&s, .{ .x = 4, .y = 4, .w = 40, .h = 24 }, 8, gfx.rgb(200, 40, 40));
    try std.testing.expectEqual(gfx.rgb(200, 40, 40), s.pixelAt(24, 16));
    try std.testing.expectEqual(gfx.rgb(200, 40, 40), s.pixelAt(4, 16));
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), s.pixelAt(4, 4));
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), s.pixelAt(12, 3));
}

test "circle is round at the centre and clipped at the corners" {
    var buf = [_]u8{0} ** (32 * 32 * 4);
    var s = try gfx.Surface.init(&buf, 32, 32, 32 * 4, .rgba8888);
    s.clear(gfx.rgb(0, 0, 0));
    fillCircle(&s, 16, 16, 10, gfx.rgb(0, 220, 80));
    try std.testing.expectEqual(gfx.rgb(0, 220, 80), s.pixelAt(16, 16));
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), s.pixelAt(16, 4));
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), s.pixelAt(6, 6));
}

test "thick line is anti-aliased and clipped" {
    var buf = [_]u8{0} ** (40 * 24 * 4);
    var s = try gfx.Surface.init(&buf, 40, 24, 40 * 4, .rgba8888);
    s.clear(gfx.rgb(0, 0, 0));
    line(&s, 4, 12, 35, 12, 3, gfx.rgb(255, 255, 255));
    try std.testing.expectEqual(gfx.rgb(255, 255, 255), s.pixelAt(20, 12));
    line(&s, 2, 2, 37, 21, 2, gfx.rgb(255, 0, 0));
    var partial: u32 = 0;
    var yy: i32 = 0;
    while (yy < 24) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < 40) : (xx += 1) {
            const v = (s.pixelAt(xx, yy) >> 16) & 0xFF;
            if (v > 0 and v < 255) partial += 1;
        }
    }
    try std.testing.expect(partial > 0);
    line(&s, -20, -20, 80, 40, 2, gfx.rgb(255, 0, 0));
    try std.testing.expect(s.snapshotRect(.{ .x = 0, .y = 0, .w = 40, .h = 24 }) != null);
}

test "arc sweeps only the requested quadrant" {
    var buf = [_]u8{0} ** (80 * 80 * 4);
    var s = try gfx.Surface.init(&buf, 80, 80, 80 * 4, .rgba8888);
    s.clear(gfx.rgb(0, 0, 0));
    arc(&s, 40, 40, 24, 3, 0, 16, gfx.rgb(255, 128, 0));
    try std.testing.expect((s.pixelAt(64, 40) >> 16) & 0xFF > 200);
    try std.testing.expect((s.pixelAt(40, 64) >> 8) & 0xFF > 60);
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), s.pixelAt(16, 40));
}

test "vertical gradient is exact at both ends" {
    var buf = [_]u8{0} ** (16 * 32 * 4);
    var s = try gfx.Surface.init(&buf, 16, 32, 16 * 4, .rgba8888);
    s.clear(gfx.rgb(0, 0, 0));
    linearGradient(&s, .{ .x = 0, .y = 0, .w = 16, .h = 32 }, gfx.rgb(0, 0, 0), gfx.rgb(200, 100, 50), true);
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), s.pixelAt(8, 0));
    try std.testing.expectEqual(gfx.rgb(200, 100, 50), s.pixelAt(8, 31));
    const mid = s.pixelAt(8, 15);
    try std.testing.expect((mid >> 16) & 0xFF > 80 and ((mid >> 16) & 0xFF) < 120);
}

test "shadow is darker inside and absent far outside" {
    var buf = [_]u8{0} ** (64 * 64 * 4);
    var s = try gfx.Surface.init(&buf, 64, 64, 64 * 4, .rgba8888);
    s.clear(gfx.rgb(80, 80, 80));
    dropShadow(&s, .{ .x = 20, .y = 20, .w = 24, .h = 16 }, 4, 16, gfx.rgba(0, 0, 0, 180));
    const inside = s.pixelAt(30, 30);
    try std.testing.expect((inside >> 16) & 0xFF < 40);
    try std.testing.expectEqual(gfx.rgb(80, 80, 80), s.pixelAt(4, 4));
}

test "nine-patch keeps corners and stretches edges and centre" {
    var src_buf = [_]u8{0} ** (12 * 12 * 4);
    var src = try gfx.Surface.init(&src_buf, 12, 12, 12 * 4, .rgba8888);
    var y: i32 = 0;
    while (y < 12) : (y += 1) {
        var x: i32 = 0;
        while (x < 12) : (x += 1) {
            const corner = (x < 4 or x >= 8) and (y < 4 or y >= 8);
            const edge = x < 4 or x >= 8 or y < 4 or y >= 8;
            src.setPixel(x, y, if (corner) gfx.rgb(200, 0, 0) else if (edge) gfx.rgb(0, 200, 0) else gfx.rgb(0, 0, 200));
        }
    }
    var dst_buf = [_]u8{0} ** (40 * 32 * 4);
    var dst = try gfx.Surface.init(&dst_buf, 40, 32, 40 * 4, .rgba8888);
    dst.clear(gfx.rgb(0, 0, 0));
    ninePatch(&dst, &src, .{ .x = 0, .y = 0, .w = 12, .h = 12 }, .{ .left = 4, .top = 4, .right = 4, .bottom = 4 }, .{ .x = 4, .y = 4, .w = 32, .h = 24 }, 255);
    try std.testing.expectEqual(gfx.rgb(200, 0, 0), dst.pixelAt(5, 5));
    try std.testing.expectEqual(gfx.rgb(0, 200, 0), dst.pixelAt(20, 5));
    try std.testing.expectEqual(gfx.rgb(0, 200, 0), dst.pixelAt(5, 20));
    try std.testing.expectEqual(gfx.rgb(0, 0, 200), dst.pixelAt(20, 20));
    try std.testing.expectEqual(gfx.rgb(0, 0, 0), dst.pixelAt(2, 2));
}
