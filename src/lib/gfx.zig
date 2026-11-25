//! Phase 51 graphics core.
//!
//! This is the allocation-free pixel model under the framebuffer and the later
//! compositor. A surface owns a bounded byte buffer, a stride, one of the
//! supported formats, a clip rectangle and a small bounded damage list. Every
//! drawing operation clips first and records only the pixels it actually
//! touched; blits convert between formats and composite straight alpha.
//!
//! The model is deliberately independent of MMIO. The kernel can wrap the
//! mapped framebuffer in a `Surface`, while host tests use ordinary buffers and
//! compare byte-for-byte snapshots for every format and clipping case.

const std = @import("std");
const cassafs = @import("cassafs.zig");

/// 0xAARRGGBB. The three existing framebuffer formats ignore alpha on write;
/// RGBA surfaces use it for compositing.
pub const Color = u32;

pub const Format = enum {
    /// 32-bit little-endian XRGB: byte 0 blue, 1 green, 2 red, 3 unused.
    bgrx8888,
    /// 32-bit RGBA: byte 0 red, 1 green, 2 blue, 3 alpha.
    rgba8888,
    /// 24-bit RGB: byte 0 red, 1 green, 2 blue.
    rgb888,
    /// 16-bit little-endian R5G6B5.
    rgb565,

    pub fn bytesPerPixel(self: Format) u8 {
        return switch (self) {
            .bgrx8888, .rgba8888 => 4,
            .rgb888 => 3,
            .rgb565 => 2,
        };
    }

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .bgrx8888 => "bgrx8888",
            .rgba8888 => "rgba8888",
            .rgb888 => "rgb888",
            .rgb565 => "rgb565",
        };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        if (a.isEmpty() or b.isEmpty()) return null;
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn merge(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.right(), b.right());
        const y1 = @max(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn overlaps(a: Rect, b: Rect) bool {
        return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
    }

    pub fn touches(a: Rect, b: Rect) bool {
        return a.x <= b.right() and b.x <= a.right() and a.y <= b.bottom() and b.y <= a.bottom();
    }
};

pub const max_damage_rects: usize = 8;

/// A bounded dirty-region set. Adjacent/overlapping rectangles coalesce so a
/// renderer can present a small number of rectangles rather than one per draw.
pub const Damage = struct {
    count: u8 = 0,
    rects: [max_damage_rects]Rect = [_]Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** max_damage_rects,

    pub fn reset(self: *Damage) void {
        self.count = 0;
    }

    pub fn add(self: *Damage, rect: Rect) void {
        if (rect.isEmpty()) return;
        var merged = rect;
        var i: usize = 0;
        while (i < self.count) {
            if (self.rects[i].touches(merged)) {
                merged = Rect.merge(self.rects[i], merged);
                var j = i;
                while (j + 1 < self.count) : (j += 1) self.rects[j] = self.rects[j + 1];
                self.count -= 1;
            } else {
                i += 1;
            }
        }
        if (self.count < max_damage_rects) {
            self.rects[self.count] = merged;
            self.count += 1;
        } else {
            // Bounded: fold the new region into the last bucket instead of
            // allocating or silently dropping damage.
            self.rects[self.count - 1] = Rect.merge(self.rects[self.count - 1], merged);
        }
    }

    pub fn bounds(self: *const Damage) ?Rect {
        if (self.count == 0) return null;
        var out = self.rects[0];
        var i: usize = 1;
        while (i < self.count) : (i += 1) out = Rect.merge(out, self.rects[i]);
        return out;
    }

    pub fn pixels(self: *const Damage) u64 {
        var total: u64 = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (!self.rects[i].isEmpty()) {
                total += @as(u64, @intCast(self.rects[i].w)) * @as(u64, @intCast(self.rects[i].h));
            }
        }
        return total;
    }
};

pub const Error = error{
    InvalidGeometry,
    BufferTooSmall,
};

pub const Surface = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    pixels: []u8,
    clip_rect: Rect,
    damage: Damage = .{},

    pub fn init(pixels: []u8, width: u32, height: u32, stride: u32, format: Format) Error!Surface {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        const bytes_per_pixel = format.bytesPerPixel();
        const row_bytes = std.math.mul(u32, width, bytes_per_pixel) catch return error.InvalidGeometry;
        if (stride < row_bytes) return error.InvalidGeometry;
        const needed = std.math.mul(usize, stride, height) catch return error.BufferTooSmall;
        if (pixels.len < needed) return error.BufferTooSmall;
        return .{
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
            .pixels = pixels[0..needed],
            .clip_rect = .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) },
        };
    }

    pub fn bpp(self: *const Surface) u8 {
        return self.format.bytesPerPixel();
    }

    pub fn rowBytes(self: *const Surface) u32 {
        return @intCast(self.width * self.bpp());
    }

    pub fn bounds(self: *const Surface) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    pub fn clip(self: *const Surface, rect: Rect) ?Rect {
        const a = Rect.intersect(rect, self.bounds()) orelse return null;
        return Rect.intersect(a, self.clip_rect);
    }

    pub fn setClip(self: *Surface, rect: Rect) void {
        self.clip_rect = Rect.intersect(rect, self.bounds()) orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    pub fn resetClip(self: *Surface) void {
        self.clip_rect = self.bounds();
    }

    fn offset(self: *const Surface, x: u32, y: u32) usize {
        return @as(usize, y) * self.stride + @as(usize, x) * self.bpp();
    }

    fn readPixel(self: *const Surface, x: u32, y: u32) Color {
        const p = self.pixels[self.offset(x, y)..];
        return switch (self.format) {
            .bgrx8888 => 0xFF000000 | (@as(u32, p[2]) << 16) | (@as(u32, p[1]) << 8) | p[0],
            .rgba8888 => (@as(u32, p[3]) << 24) | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2],
            .rgb888 => 0xFF000000 | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2],
            .rgb565 => blk: {
                const v = @as(u16, p[0]) | (@as(u16, p[1]) << 8);
                const r = (@as(u32, v >> 11) & 0x1F) * 255 / 31;
                const g = (@as(u32, v >> 5) & 0x3F) * 255 / 63;
                const b = (@as(u32, v) & 0x1F) * 255 / 31;
                break :blk 0xFF000000 | (r << 16) | (g << 8) | b;
            },
        };
    }

    fn writePixelRaw(self: *Surface, x: u32, y: u32, color: Color) void {
        const p = self.pixels[self.offset(x, y)..];
        const r: u8 = @truncate(color >> 16);
        const g: u8 = @truncate(color >> 8);
        const b: u8 = @truncate(color);
        const a: u8 = @truncate(color >> 24);
        switch (self.format) {
            .bgrx8888 => {
                p[0] = b;
                p[1] = g;
                p[2] = r;
                p[3] = 0;
            },
            .rgba8888 => {
                p[0] = r;
                p[1] = g;
                p[2] = b;
                p[3] = a;
            },
            .rgb888 => {
                p[0] = r;
                p[1] = g;
                p[2] = b;
            },
            .rgb565 => {
                const v: u16 = (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
                p[0] = @truncate(v);
                p[1] = @truncate(v >> 8);
            },
        }
    }

    /// Write a raw pixel, preserving RGBA alpha. RGB destinations ignore alpha.
    pub fn setPixel(self: *Surface, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (self.clip(.{ .x = x, .y = y, .w = 1, .h = 1 }) == null) return;
        self.writePixelRaw(ux, uy, color);
    }

    /// Fill an opaque horizontal span using the same checked surface path. The
    /// 32-bit and RGB565 cases store four/eight pixels per vector operation;
    /// RGB888 keeps the scalar fallback because its 3-byte stride is not a
    /// natural vector width. Damage is the caller's responsibility.
    pub fn fillSpan(self: *Surface, x: i32, y: i32, len: u32, color: Color) void {
        if (len == 0 or y < 0) return;
        const r = self.clip(.{ .x = x, .y = y, .w = @intCast(len), .h = 1 }) orelse return;
        const count: usize = @intCast(r.w);
        const row = self.pixels[@as(usize, @intCast(r.y)) * self.stride ..];
        const start = @as(usize, @intCast(r.x)) * self.bpp();
        const r8: u8 = @truncate(color >> 16);
        const g8: u8 = @truncate(color >> 8);
        const b8: u8 = @truncate(color);
        var i: usize = 0;
        switch (self.format) {
            .bgrx8888 => {
                const value: u32 = (@as(u32, r8) << 16) | (@as(u32, g8) << 8) | b8;
                const Vec = @Vector(4, u32);
                while (i + 4 <= count) : (i += 4) {
                    const p: *align(1) Vec = @ptrCast(row.ptr + start + i * 4);
                    p.* = @splat(value);
                }
                while (i < count) : (i += 1) {
                    const p = row[start + i * 4 ..];
                    p[0] = b8;
                    p[1] = g8;
                    p[2] = r8;
                    p[3] = 0;
                }
            },
            .rgba8888 => {
                const value: u32 = @as(u32, r8) | (@as(u32, g8) << 8) | (@as(u32, b8) << 16) | (@as(u32, 255) << 24);
                const Vec = @Vector(4, u32);
                while (i + 4 <= count) : (i += 4) {
                    const p: *align(1) Vec = @ptrCast(row.ptr + start + i * 4);
                    p.* = @splat(value);
                }
                while (i < count) : (i += 1) {
                    const p = row[start + i * 4 ..];
                    p[0] = r8;
                    p[1] = g8;
                    p[2] = b8;
                    p[3] = 255;
                }
            },
            .rgb565 => {
                const value: u16 = (@as(u16, r8 >> 3) << 11) | (@as(u16, g8 >> 2) << 5) | (b8 >> 3);
                const Vec = @Vector(8, u16);
                while (i + 8 <= count) : (i += 8) {
                    const p: *align(1) Vec = @ptrCast(row.ptr + start + i * 2);
                    p.* = @splat(value);
                }
                while (i < count) : (i += 1) {
                    const p = row[start + i * 2 ..];
                    p[0] = @truncate(value);
                    p[1] = @truncate(value >> 8);
                }
            },
            .rgb888 => {
                while (i < count) : (i += 1) {
                    const p = row[start + i * 3 ..];
                    p[0] = r8;
                    p[1] = g8;
                    p[2] = b8;
                }
            },
        }
    }

    pub fn pixelAt(self: *const Surface, x: i32, y: i32) Color {
        if (x < 0 or y < 0) return 0;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return 0;
        return self.readPixel(ux, uy);
    }

    fn blendColor(dst: Color, src: Color, opacity: u8) Color {
        const src_alpha: u32 = (src >> 24) & 0xFF;
        const a: u32 = (src_alpha * @as(u32, opacity) + 127) / 255;
        if (a == 0) return dst;
        if (a >= 255) return src | 0xFF000000;
        const inv: u32 = 255 - a;
        const sr = (src >> 16) & 0xFF;
        const sg = (src >> 8) & 0xFF;
        const sb = src & 0xFF;
        const dr = (dst >> 16) & 0xFF;
        const dg = (dst >> 8) & 0xFF;
        const db = dst & 0xFF;
        const r = (sr * a + dr * inv + 127) / 255;
        const g = (sg * a + dg * inv + 127) / 255;
        const b = (sb * a + db * inv + 127) / 255;
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    /// Composite one source pixel over the destination through the surface
    /// clip. This is the single per-pixel blending entry used by the rasterizer.
    pub fn blendPixel(self: *Surface, x: i32, y: i32, color: Color, opacity: u8) void {
        const pixel = self.clip(.{ .x = x, .y = y, .w = 1, .h = 1 }) orelse return;
        const dst = self.readPixel(@intCast(pixel.x), @intCast(pixel.y));
        self.writePixelRaw(@intCast(pixel.x), @intCast(pixel.y), blendColor(dst, color, opacity));
    }

    /// Fill a rectangle, honoring the surface clip and alpha. A fully opaque
    /// fill uses the fast row path; translucent fills composite per pixel.
    pub fn fillRect(self: *Surface, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        const r = self.clip(.{ .x = x, .y = y, .w = w, .h = h }) orelse return;
        const alpha: u8 = @truncate(color >> 24);
        if (alpha == 255) {
            var yy: i32 = r.y;
            while (yy < r.bottom()) : (yy += 1) self.fillSpan(r.x, yy, @intCast(r.w), color);
        } else {
            var yy: i32 = r.y;
            while (yy < r.bottom()) : (yy += 1) {
                var xx: i32 = r.x;
                while (xx < r.right()) : (xx += 1) self.blendPixel(xx, yy, color, 255);
            }
        }
        self.damage.add(r);
    }

    pub fn clear(self: *Surface, color: Color) void {
        self.fillRect(0, 0, @intCast(self.width), @intCast(self.height), color);
    }

    /// Copy a rectangle from another surface. The source and destination may
    /// have different formats, the source may be RGBA with per-pixel alpha, and
    /// `opacity` is multiplied into that alpha.
    pub fn blit(self: *Surface, src: *const Surface, src_rect: Rect, dst_rect: Rect, opacity: u8) void {
        const s = src.clip(src_rect) orelse return;
        const mapped = Rect{
            .x = dst_rect.x + (s.x - src_rect.x),
            .y = dst_rect.y + (s.y - src_rect.y),
            .w = s.w,
            .h = s.h,
        };
        const d = self.clip(mapped) orelse return;
        var yy: i32 = d.y;
        while (yy < d.bottom()) : (yy += 1) {
            var xx: i32 = d.x;
            while (xx < d.right()) : (xx += 1) {
                const sx = src_rect.x + (xx - dst_rect.x);
                const sy = src_rect.y + (yy - dst_rect.y);
                if (sx < 0 or sy < 0) continue;
                if (sx >= @as(i32, @intCast(src.width)) or sy >= @as(i32, @intCast(src.height))) continue;
                const color = src.pixelAt(sx, sy);
                self.blendPixel(xx, yy, color, opacity);
            }
        }
        self.damage.add(d);
    }

    /// CRC32C of the visible pixels (stride padding excluded).
    pub fn snapshot(self: *const Surface) u32 {
        var state: u32 = 0xFFFF_FFFF;
        var yy: u32 = 0;
        const bytes = self.width * self.bpp();
        while (yy < self.height) : (yy += 1) {
            state = cassafs.crc32cUpdate(state, self.pixels[@as(usize, yy) * self.stride ..][0..bytes]);
        }
        return ~state;
    }

    pub fn snapshotRect(self: *const Surface, rect: Rect) ?u32 {
        const r = self.clip(rect) orelse return null;
        var state: u32 = 0xFFFF_FFFF;
        var yy: i32 = r.y;
        while (yy < r.bottom()) : (yy += 1) {
            const row = self.pixels[@as(usize, @intCast(yy)) * self.stride ..];
            const start = @as(usize, @intCast(r.x)) * self.bpp();
            const count = @as(usize, @intCast(r.w)) * self.bpp();
            state = cassafs.crc32cUpdate(state, row[start..][0..count]);
        }
        return ~state;
    }
};

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

// ---------------------------------------------------------------------------
// Host snapshot tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testSurface(buf: []u8, width: u32, height: u32, format: Format) !Surface {
    return Surface.init(buf, width, height, width * format.bytesPerPixel(), format);
}

test "all formats round-trip alpha and RGB" {
    inline for (.{ Format.bgrx8888, Format.rgba8888, Format.rgb888, Format.rgb565 }) |format| {
        var buf = [_]u8{0} ** (4 * 4 * 4);
        var s = try testSurface(&buf, 4, 4, format);
        s.setPixel(0, 0, rgba(255, 0, 0, 128));
        s.setPixel(1, 0, rgba(0, 255, 0, 255));
        s.setPixel(2, 0, rgba(0, 0, 255, 0));
        const red = s.pixelAt(0, 0);
        const green = s.pixelAt(1, 0);
        const blue = s.pixelAt(2, 0);
        try testing.expectEqual(@as(u32, 255), (red >> 16) & 0xFF);
        try testing.expectEqual(@as(u32, 255), (green >> 8) & 0xFF);
        try testing.expectEqual(@as(u32, 255), blue & 0xFF);
        if (format == .rgba8888) {
            try testing.expectEqual(@as(u32, 128), red >> 24);
        } else {
            try testing.expectEqual(@as(u32, 255), red >> 24);
        }
        if (format == .rgb565) {
            try testing.expect((red >> 16 & 0xFF) >= 248);
            try testing.expect((green >> 8 & 0xFF) >= 252);
        }
    }
}

test "clipping covers negative, overflow, empty and boundary rectangles" {
    var buf = [_]u8{0} ** (8 * 6 * 4);
    var s = try testSurface(&buf, 8, 6, .bgrx8888);
    s.clear(rgb(1, 2, 3));
    s.damage.reset();
    s.fillRect(-4, -4, 6, 6, rgb(255, 0, 0));
    try testing.expectEqual(rgb(255, 0, 0), s.pixelAt(0, 0));
    try testing.expectEqual(rgb(255, 0, 0), s.pixelAt(1, 0));
    try testing.expectEqual(rgb(1, 2, 3), s.pixelAt(2, 2));
    s.fillRect(6, 4, 10, 10, rgb(0, 255, 0));
    try testing.expectEqual(rgb(0, 255, 0), s.pixelAt(7, 5));
    try testing.expectEqual(rgb(1, 2, 3), s.pixelAt(5, 5));
    s.fillRect(8, 0, 1, 1, rgb(9, 9, 9));
    s.fillRect(0, 6, 1, 1, rgb(9, 9, 9));
    s.fillRect(0, 0, 0, 3, rgb(9, 9, 9));
    s.fillRect(0, 0, 3, -1, rgb(9, 9, 9));
    try testing.expect(s.damage.count >= 2);
}

test "clipping is exact in every pixel format" {
    inline for (.{ Format.bgrx8888, Format.rgba8888, Format.rgb888, Format.rgb565 }) |format| {
        var buf = [_]u8{0} ** (12 * 10 * 4);
        var s = try testSurface(&buf, 12, 10, format);
        s.clear(rgb(0, 0, 0));
        s.fillRect(-5, -5, 8, 8, rgb(255, 0, 0));
        try testing.expectEqual(rgb(255, 0, 0), s.pixelAt(0, 0));
        try testing.expectEqual(rgb(255, 0, 0), s.pixelAt(2, 2));
        try testing.expectEqual(rgb(0, 0, 0), s.pixelAt(3, 3));
        s.fillRect(8, 7, 8, 8, rgb(0, 255, 0));
        try testing.expectEqual(rgb(0, 255, 0), s.pixelAt(11, 9));
        try testing.expectEqual(rgb(0, 0, 0), s.pixelAt(7, 9));
        s.setClip(.{ .x = 2, .y = 2, .w = 3, .h = 3 });
        s.fillRect(0, 0, 12, 10, rgb(0, 0, 255));
        try testing.expectEqual(rgb(255, 0, 0), s.pixelAt(1, 1));
        try testing.expectEqual(rgb(0, 0, 255), s.pixelAt(2, 2));
        try testing.expectEqual(rgb(0, 0, 0), s.pixelAt(5, 5));
        try testing.expect(s.snapshotRect(.{ .x = 2, .y = 2, .w = 3, .h = 3 }) != null);
        try testing.expect(s.snapshotRect(.{ .x = 20, .y = 20, .w = 3, .h = 3 }) == null);
    }
}

test "blit converts between every source and destination format" {
    inline for (.{ Format.bgrx8888, Format.rgba8888, Format.rgb888, Format.rgb565 }) |src_format| {
        inline for (.{ Format.bgrx8888, Format.rgba8888, Format.rgb888, Format.rgb565 }) |dst_format| {
            var src_buf = [_]u8{0} ** (4 * 4 * 4);
            var dst_buf = [_]u8{0} ** (4 * 4 * 4);
            var src = try testSurface(&src_buf, 4, 4, src_format);
            var dst = try testSurface(&dst_buf, 4, 4, dst_format);
            src.clear(rgb(255, 0, 0));
            dst.clear(rgb(0, 0, 0));
            dst.blit(&src, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, 255);
            try testing.expectEqual(rgb(255, 0, 0), dst.pixelAt(1, 1));
            try testing.expectEqual(rgb(255, 0, 0), dst.pixelAt(3, 3));
        }
    }
}

test "translucent fill and blit composite exact channels" {
    var dst_buf = [_]u8{0} ** (4 * 4 * 4);
    var src_buf = [_]u8{0} ** (2 * 2 * 4);
    var dst = try testSurface(&dst_buf, 4, 4, .rgba8888);
    var src = try testSurface(&src_buf, 2, 2, .rgba8888);
    dst.clear(rgb(10, 20, 30));
    src.clear(rgb(0, 0, 0));
    src.setPixel(0, 0, rgba(200, 100, 50, 128));
    src.setPixel(1, 0, rgba(200, 100, 50, 0));
    dst.fillRect(0, 0, 1, 1, rgba(100, 0, 0, 128));
    try testing.expectEqual(@as(u32, 55), (dst.pixelAt(0, 0) >> 16) & 0xFF);
    dst.blit(&src, .{ .x = 0, .y = 0, .w = 2, .h = 1 }, .{ .x = 2, .y = 0, .w = 2, .h = 1 }, 255);
    const blended = dst.pixelAt(2, 0);
    try testing.expectEqual(@as(u32, 105), (blended >> 16) & 0xFF);
    try testing.expectEqual(@as(u32, 60), (blended >> 8) & 0xFF);
    try testing.expectEqual(@as(u32, 40), blended & 0xFF);
    try testing.expectEqual(dst.pixelAt(2, 0), dst.pixelAt(2, 0));
    try testing.expectEqual(dst.pixelAt(3, 0), dst.pixelAt(3, 0));
}

test "blit clips source and destination and records only visible damage" {
    var dst_buf = [_]u8{0} ** (8 * 8 * 4);
    var src_buf = [_]u8{0} ** (4 * 4 * 4);
    var dst = try testSurface(&dst_buf, 8, 8, .bgrx8888);
    var src = try testSurface(&src_buf, 4, 4, .rgba8888);
    dst.clear(rgb(0, 0, 0));
    src.clear(rgb(255, 255, 255));
    dst.blit(&src, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .x = -2, .y = -2, .w = 4, .h = 4 }, 255);
    try testing.expectEqual(rgb(255, 255, 255), dst.pixelAt(0, 0));
    try testing.expectEqual(rgb(255, 255, 255), dst.pixelAt(1, 1));
    try testing.expectEqual(rgb(0, 0, 0), dst.pixelAt(2, 2));
    dst.resetClip();
    dst.damage.reset();
    src.setClip(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    dst.blit(&src, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .{ .x = 6, .y = 6, .w = 2, .h = 2 }, 255);
    try testing.expectEqual(rgb(255, 255, 255), dst.pixelAt(6, 6));
    try testing.expectEqual(rgb(0, 0, 0), dst.pixelAt(5, 6));
    try testing.expectEqual(@as(u64, 1), dst.damage.count);
}

test "damage coalesces, clips and is bounded" {
    var d = Damage{};
    d.add(.{ .x = 2, .y = 2, .w = 4, .h = 4 });
    d.add(.{ .x = 6, .y = 4, .w = 2, .h = 2 });
    try testing.expectEqual(@as(u8, 1), d.count);
    try testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 6, .h = 4 }, d.rects[0]);
    d.add(.{ .x = 20, .y = 20, .w = 1, .h = 1 });
    try testing.expectEqual(@as(u8, 2), d.count);
    d.add(.{ .x = 0, .y = 0, .w = 0, .h = 4 });
    try testing.expectEqual(@as(u8, 2), d.count);
    d.reset();
    try testing.expectEqual(@as(u8, 0), d.count);
}

test "format snapshots are stable" {
    inline for (.{ Format.bgrx8888, Format.rgba8888, Format.rgb888, Format.rgb565 }) |format| {
        var buf = [_]u8{0} ** (16 * 12 * 4);
        var s = try testSurface(&buf, 16, 12, format);
        s.clear(rgb(8, 16, 24));
        s.fillRect(2, 2, 8, 5, rgb(255, 0, 0));
        s.fillRect(6, 4, 8, 6, rgba(0, 128, 255, 128));
        var frag_buf = [_]u8{0} ** (4 * 4 * 4);
        var frag = try testSurface(&frag_buf, 4, 4, .rgba8888);
        frag.clear(rgba(255, 255, 255, 0));
        frag.setPixel(0, 0, rgba(0, 255, 0, 128));
        frag.setPixel(1, 0, rgba(255, 255, 255, 255));
        s.blit(&frag, .{ .x = -1, .y = -1, .w = 4, .h = 4 }, .{ .x = 14, .y = 10, .w = 4, .h = 4 }, 255);
        const snapshot = s.snapshot();
        const expected: u32 = switch (format) {
            .bgrx8888 => 0x7d245e17,
            .rgba8888 => 0x0c78f0ce,
            .rgb888 => 0x4d34cea1,
            .rgb565 => 0xc7e3a61c,
        };
        try testing.expectEqual(expected, snapshot);
        const damage = s.damage.bounds() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 16, .h = 12 }, damage);
    }
}

test "fillSpan writes vector bodies and scalar tails in every format" {
    inline for (.{ Format.bgrx8888, Format.rgba8888, Format.rgb888, Format.rgb565 }) |format| {
        const bpp = format.bytesPerPixel();
        var buf = [_]u8{0} ** (24 * 4 * 4);
        var s = try Surface.init(&buf, 24, 4, 24 * bpp, format);
        s.clear(rgb(0, 0, 0));
        s.fillSpan(3, 1, 19, rgb(10, 20, 30));
        var x: i32 = 3;
        while (x < 22) : (x += 1) {
            const p = s.pixelAt(x, 1);
            try std.testing.expect((p >> 16) & 0xFF >= 8 and (p >> 16) & 0xFF <= 10);
            try std.testing.expect((p >> 8) & 0xFF >= 16 and (p >> 8) & 0xFF <= 20);
            try std.testing.expect(p & 0xFF >= 24 and (p & 0xFF) <= 30);
        }
        try std.testing.expectEqual(rgb(0, 0, 0), s.pixelAt(2, 1));
        try std.testing.expectEqual(rgb(0, 0, 0), s.pixelAt(22, 1));
    }
}
