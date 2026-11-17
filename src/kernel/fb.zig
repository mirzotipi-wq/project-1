//! Framebuffer core (phase 37): the pixel surface the whole UI is built on.
//!
//! This module knows nothing about a specific graphics card. A driver hands it a
//! mode (geometry, stride, pixel format and the physical base of the linear
//! framebuffer) and it owns every write after that: rectangles, gradients,
//! bitmap text, the panel self-test pattern, the boot splash and the panic
//! screen. Keeping the drawing code here means the compositor (phase 54), the
//! widget toolkit (phase 55) and the POS app all draw through one reviewed
//! pixel path, and the panic screen draws through exactly the same one.
//!
//! It is deliberately allocation-free: every routine writes into the mapped
//! surface with bounds checks, so it is safe from a fault handler that runs with
//! interrupts disabled and no heap to rely on.

const std = @import("std");
const font = @import("../lib/font5x7.zig");
const klog = @import("klog.zig");

pub const Color = u32;

pub const Palette = struct {
    pub const black: Color = 0x000000;
    pub const white: Color = 0xFFFFFF;
    pub const background: Color = 0x0B0D10;
    pub const surface: Color = 0x151A21;
    pub const amber: Color = 0xF2A33A;
    pub const amber_dim: Color = 0x8A5B1E;
    pub const text: Color = 0xEDEFF2;
    pub const text_dim: Color = 0x9AA3AD;
    pub const green: Color = 0x35C46A;
    pub const red: Color = 0xE0353B;
    pub const blue: Color = 0x3B82F6;
    pub const grid: Color = 0x232A33;
    pub const panic_bg: Color = 0x2A0709;
    pub const panic_bar: Color = 0xE0353B;
};

pub const Format = enum {
    /// 32-bit little-endian XRGB: byte 0 blue, 1 green, 2 red, 3 unused.
    bgrx8888,
    rgb565,
    rgb888,

    pub fn bytesPerPixel(self: Format) u8 {
        return switch (self) {
            .bgrx8888 => 4,
            .rgb565 => 2,
            .rgb888 => 3,
        };
    }

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .bgrx8888 => "x8r8g8b8",
            .rgb565 => "r5g6b5",
            .rgb888 => "r8g8b8",
        };
    }
};

pub const Mode = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Bytes from one row's start to the next. May exceed width * bpp.
    stride: u32 = 0,
    format: Format = .bgrx8888,
    /// Physical base of the linear framebuffer, for diagnostics.
    phys: u64 = 0,
    /// Bytes the driver says are mapped and usable.
    size: u64 = 0,

    pub fn bpp(self: Mode) u8 {
        return self.format.bytesPerPixel();
    }

    pub fn frameBytes(self: Mode) u64 {
        return @as(u64, self.stride) * self.height;
    }

    pub fn pixelCount(self: Mode) u64 {
        return @as(u64, self.width) * self.height;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Framebuffer = struct {
    mode: Mode,
    base: [*]u8,
    /// Diagnostics: what this surface has drawn since it was installed.
    pixels_written: u64 = 0,
    fills: u64 = 0,
    frames: u64 = 0,

    pub fn init(mode: Mode, base: [*]u8) Framebuffer {
        return .{ .mode = mode, .base = base };
    }

    fn rowPtr(self: *const Framebuffer, y: u32) [*]u8 {
        return self.base + @as(usize, y) * self.mode.stride;
    }

    /// Clip a rectangle to the surface, returning null when nothing is left.
    pub fn clip(self: *const Framebuffer, x: i32, y: i32, w: i32, h: i32) ?Rect {
        if (w <= 0 or h <= 0) return null;
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, @as(i32, @intCast(self.mode.width)));
        const y1 = @min(y + h, @as(i32, @intCast(self.mode.height)));
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn put(self: *Framebuffer, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.mode.width or uy >= self.mode.height) return;
        self.writePixel(ux, uy, color);
    }

    pub fn writePixel(self: *Framebuffer, x: u32, y: u32, color: Color) void {
        const row = self.rowPtr(y);
        const r: u8 = @truncate(color >> 16);
        const g: u8 = @truncate(color >> 8);
        const b: u8 = @truncate(color);
        switch (self.mode.format) {
            .bgrx8888 => {
                const p: [*]align(1) u32 = @ptrCast(row + @as(usize, x) * 4);
                p[0] = @as(u32, r) << 16 | @as(u32, g) << 8 | b;
            },
            .rgb888 => {
                const p = row + @as(usize, x) * 3;
                p[0] = r;
                p[1] = g;
                p[2] = b;
            },
            .rgb565 => {
                const p: [*]align(1) u16 = @ptrCast(row + @as(usize, x) * 2);
                const v: u16 = (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
                p[0] = v;
            },
        }
        self.pixels_written += 1;
    }

    pub fn pixelAt(self: *const Framebuffer, x: u32, y: u32) Color {
        if (x >= self.mode.width or y >= self.mode.height) return 0;
        const row = self.rowPtr(y);
        return switch (self.mode.format) {
            .bgrx8888 => blk: {
                const p: [*]align(1) const u32 = @ptrCast(row + @as(usize, x) * 4);
                break :blk p[0] & 0x00FF_FFFF;
            },
            .rgb888 => blk: {
                const p = row + @as(usize, x) * 3;
                break :blk @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2];
            },
            .rgb565 => blk: {
                const p: [*]align(1) const u16 = @ptrCast(row + @as(usize, x) * 2);
                const v = p[0];
                const r = (@as(u32, v >> 11) & 0x1f) * 255 / 31;
                const g = (@as(u32, v >> 5) & 0x3f) * 255 / 63;
                const b = (@as(u32, v) & 0x1f) * 255 / 31;
                break :blk (r << 16) | (g << 8) | b;
            },
        };
    }

    pub fn fillRect(self: *Framebuffer, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        const r = self.clip(x, y, w, h) orelse return;
        const r8: u8 = @truncate(color >> 16);
        const g8: u8 = @truncate(color >> 8);
        const b8: u8 = @truncate(color);
        var row_index: u32 = @intCast(r.y);
        const end_y: u32 = @intCast(r.y + r.h);
        const start_x: usize = @intCast(r.x);
        const count: usize = @intCast(r.w);
        while (row_index < end_y) : (row_index += 1) {
            const row = self.rowPtr(row_index);
            switch (self.mode.format) {
                .bgrx8888 => {
                    const p: [*]align(1) u32 = @ptrCast(row);
                    const v: u32 = @as(u32, r8) << 16 | @as(u32, g8) << 8 | b8;
                    @memset(p[start_x..][0..count], v);
                },
                .rgb888 => {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const p = row + (start_x + i) * 3;
                        p[0] = r8;
                        p[1] = g8;
                        p[2] = b8;
                    }
                },
                .rgb565 => {
                    const p: [*]align(1) u16 = @ptrCast(row);
                    const v: u16 = (@as(u16, r8 >> 3) << 11) | (@as(u16, g8 >> 2) << 5) | (b8 >> 3);
                    @memset(p[start_x..][0..count], v);
                },
            }
            self.pixels_written += count;
        }
        self.fills += 1;
    }

    pub fn clear(self: *Framebuffer, color: Color) void {
        self.fillRect(0, 0, @intCast(self.mode.width), @intCast(self.mode.height), color);
    }

    /// Vertical gradient between two colours, written row by row.
    pub fn fillGradient(self: *Framebuffer, x: i32, y: i32, w: i32, h: i32, top: Color, bottom: Color) void {
        const r = self.clip(x, y, w, h) orelse return;
        var row_index: u32 = 0;
        const rows: u32 = @intCast(r.h);
        while (row_index < rows) : (row_index += 1) {
            const t = if (rows <= 1) 0 else (@as(u32, row_index) * 255) / (rows - 1);
            const color = lerpColor(top, bottom, @intCast(t));
            self.fillRect(r.x, r.y + @as(i32, @intCast(row_index)), r.w, 1, color);
        }
    }

    pub fn drawGlyph(self: *Framebuffer, x: i32, y: i32, ch: u8, scale: u32, color: Color) void {
        const rows = font.glyph(ch);
        const s: u32 = if (scale == 0) 1 else scale;
        for (rows, 0..) |bits, ry| {
            var col: u3 = 0;
            while (col < font.glyph_width) : (col += 1) {
                const mask: u8 = @as(u8, 1) << (4 - col);
                if (bits & mask == 0) continue;
                self.fillRect(
                    x + @as(i32, @intCast(col)) * @as(i32, @intCast(s)),
                    y + @as(i32, @intCast(ry)) * @as(i32, @intCast(s)),
                    @intCast(s),
                    @intCast(s),
                    color,
                );
            }
        }
    }

    /// Draw `text` and return the x just past it.
    pub fn drawText(self: *Framebuffer, x: i32, y: i32, text: []const u8, scale: u32, color: Color) i32 {
        const s: u32 = if (scale == 0) 1 else scale;
        var cursor = x;
        var line_y = y;
        for (text) |ch| {
            if (ch == '\n') {
                cursor = x;
                line_y += @intCast(font.glyph_height * s);
                continue;
            }
            self.drawGlyph(cursor, line_y, ch, s, color);
            cursor += @intCast(font.advance * s);
        }
        return cursor;
    }

    /// Draw centred horizontally in the panel.
    pub fn drawTextCentered(self: *Framebuffer, y: i32, text: []const u8, scale: u32, color: Color) void {
        const width = font.textWidth(text, scale);
        const x: i32 = @intCast((self.mode.width -| width) / 2);
        _ = self.drawText(x, y, text, scale, color);
    }

    pub fn drawTextRight(self: *Framebuffer, x_right: i32, y: i32, text: []const u8, scale: u32, color: Color) void {
        const width = font.textWidth(text, scale);
        _ = self.drawText(x_right - @as(i32, @intCast(width)), y, text, scale, color);
    }

    /// Write a known pattern at the bottom-right corner and read it back through
    /// the MMU. This is the proof that the framebuffer the driver mapped is the
    /// memory the device scans out, not a private buffer.
    pub fn verifyReadback(self: *Framebuffer) bool {
        if (self.mode.width < 2 or self.mode.height < 2) return false;
        const x = self.mode.width - 2;
        const y = self.mode.height - 2;
        const before = self.pixelAt(x, y);
        const probe: Color = 0x00A5_5A;
        self.put(@intCast(x), @intCast(y), probe);
        const read = self.pixelAt(x, y);
        self.put(@intCast(x), @intCast(y), before);
        return read == probe;
    }

    /// The panel self-test: colour bars, a per-channel ramp, a geometry grid,
    /// corner markers and the mode in text. Deterministic, so a screenshot can
    /// be checked against it pixel for pixel.
    pub fn drawTestPattern(self: *Framebuffer) void {
        const w = self.mode.width;
        const h = self.mode.height;
        self.clear(Palette.background);
        if (w < 32 or h < 32) return;

        // Top third: eight colour bars.
        const bars = [8]Color{
            0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00,
            0xFF00FF, 0xFF0000, 0x0000FF, 0x000000,
        };
        const bar_h = h / 3;
        for (bars, 0..) |color, i| {
            const x0: u32 = @intCast((@as(u64, w) * i) / bars.len);
            const x1: u32 = @intCast((@as(u64, w) * (i + 1)) / bars.len);
            self.fillRect(@intCast(x0), 0, @intCast(x1 - x0), @intCast(bar_h), color);
        }

        // Middle third: 8-bit grey ramp, one column per level.
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const level: u8 = @intCast((@as(u64, x) * 255) / @max(w - 1, 1));
            self.fillRect(@intCast(x), @intCast(bar_h), 1, @intCast(bar_h), rgb(level, level, level));
        }

        // Bottom third: red, green and blue channel ramps stacked.
        const band = h / 9;
        var i: u32 = 0;
        while (i < w) : (i += 1) {
            const level: u8 = @intCast((@as(u64, i) * 255) / @max(w - 1, 1));
            self.fillRect(@intCast(i), @intCast(h - 3 * band), 1, @intCast(band), rgb(level, 0, 0));
            self.fillRect(@intCast(i), @intCast(h - 2 * band), 1, @intCast(band), rgb(0, level, 0));
            self.fillRect(@intCast(i), @intCast(h - band), 1, @intCast(band), rgb(0, 0, level));
        }

        // Geometry grid every 64 px, then a one-pixel border.
        var gx: u32 = 0;
        while (gx < w) : (gx += 64) self.fillRect(@intCast(gx), 0, 1, @intCast(h), Palette.grid);
        var gy: u32 = 0;
        while (gy < h) : (gy += 64) self.fillRect(0, @intCast(gy), @intCast(w), 1, Palette.grid);
        self.fillRect(0, 0, @intCast(w), 1, Palette.white);
        self.fillRect(0, @intCast(h - 1), @intCast(w), 1, Palette.white);
        self.fillRect(0, 0, 1, @intCast(h), Palette.white);
        self.fillRect(@intCast(w - 1), 0, 1, @intCast(h), Palette.white);

        // Corner markers name the channel that must be correct at that corner.
        const marker: u32 = @min(24, @min(w, h) / 8);
        self.fillRect(2, 2, @intCast(marker), @intCast(marker), 0xFF0000);
        self.fillRect(@intCast(w - marker - 2), 2, @intCast(marker), @intCast(marker), 0x00FF00);
        self.fillRect(2, @intCast(h - marker - 2), @intCast(marker), @intCast(marker), 0x0000FF);
        self.fillRect(@intCast(w - marker - 2), @intCast(h - marker - 2), @intCast(marker), @intCast(marker), 0xFFFFFF);

        // Label the mode in the middle of the panel. A panel too small for the
        // label gets the pattern without it rather than a clipped box.
        if (w < 320 or h < 200) return;
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "CASSA {d}x{d} {s}", .{
            w, h, self.mode.format.label(),
        }) catch "CASSA";
        const scale: u32 = if (w >= 800) 3 else 2;
        const text_h = font.glyph_height * scale;
        const label_bg = Rect{
            .x = @intCast((w -| (font.textWidth(label, scale) + 40)) / 2),
            .y = @intCast(h / 2 - text_h / 2 - 12),
            .w = @intCast(font.textWidth(label, scale) + 40),
            .h = @intCast(text_h + 24),
        };
        self.fillRect(label_bg.x, label_bg.y, label_bg.w, label_bg.h, 0x000000);
        self.fillRect(label_bg.x, label_bg.y, label_bg.w, 2, Palette.amber);
        self.drawTextCentered(@intCast(h / 2 - text_h / 2), label, scale, Palette.text);
    }

    /// The first thing a shop sees: brand, version, panel and boot state.
    pub fn drawSplash(self: *Framebuffer, version: []const u8, status: []const u8) void {
        const w = self.mode.width;
        const h = self.mode.height;
        self.clear(Palette.background);
        self.fillGradient(0, 0, @intCast(w), @intCast(h), 0x0B0D10, 0x161C24);

        const scale: u32 = if (w >= 1000) 7 else 4;
        const word_y: i32 = @intCast(h / 2 -| 120);
        _ = self.drawText(@intCast(w / 10), word_y, "CASSA", scale, Palette.amber);

        const sub_scale: u32 = if (w >= 1000) 2 else 1;
        _ = self.drawText(
            @intCast(w / 10),
            word_y + @as(i32, @intCast(font.glyph_height * scale + 20)),
            "point of sale",
            sub_scale,
            Palette.text_dim,
        );

        self.fillRect(@intCast(w / 10), @intCast(h / 2 + 20), @intCast(w - 2 * (w / 10)), 1, Palette.amber_dim);

        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "v{s}   {d}x{d}   {s}   {d} bpp", .{
            version, w, h, self.mode.format.label(), self.mode.bpp() * 8,
        }) catch "cassa";
        _ = self.drawText(@intCast(w / 10), @intCast(h / 2 + 40), line, sub_scale, Palette.text_dim);

        _ = self.drawText(@intCast(w / 10), @intCast(h - 60), status, sub_scale, Palette.text);

        // A small amber square in the corner is the "panel is live" marker.
        self.fillRect(@intCast(w - 40), @intCast(h - 40), 16, 16, Palette.amber);
    }

    /// Panic-to-screen: the same fault report the serial console gets, drawn
    /// with the same pixel path the UI uses. Called with interrupts disabled.
    pub fn drawPanic(self: *Framebuffer, header: []const u8, body: []const u8) void {
        const w = self.mode.width;
        const h = self.mode.height;
        self.clear(Palette.panic_bg);
        self.fillRect(0, 0, @intCast(w), 44, Palette.panic_bar);

        const title_scale: u32 = if (w >= 800) 2 else 1;
        _ = self.drawText(16, 12, "CASSA KERNEL PANIC", title_scale, Palette.white);

        var y: i32 = 60;
        const scale: u32 = if (w >= 1000) 2 else 1;
        _ = self.drawText(16, y, header, scale, Palette.white);
        y += @as(i32, @intCast(font.glyph_height * scale + 12));

        const line_h: i32 = @intCast(font.glyph_height * scale + 4);
        const max_chars: usize = @intCast((w -| 32) / (font.advance * scale));
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            if (y > @as(i32, @intCast(h)) - line_h * 2) break;
            var rest = line;
            if (rest.len == 0) {
                y += line_h;
                continue;
            }
            while (rest.len > 0) {
                const take = @min(rest.len, max_chars);
                _ = self.drawText(16, y, rest[0..take], scale, Palette.text);
                rest = rest[take..];
                y += line_h;
                if (y > @as(i32, @intCast(h)) - line_h * 2) break;
            }
        }

        const footer = "halted: the serial console has the full report";
        _ = self.drawText(16, @intCast(h -| (font.glyph_height * scale + 16)), footer, scale, Palette.text_dim);
    }

    pub fn describe(self: *const Framebuffer, write: anytype) void {
        write("  panel        : {d}x{d} at {d} bpp ({s}), stride {d}\n", .{
            self.mode.width, self.mode.height, self.mode.bpp() * 8, self.mode.format.label(), self.mode.stride,
        });
        write("  framebuffer  : 0x{x}, {d} KiB mapped, {d} KiB per frame\n", .{
            self.mode.phys, self.mode.size / 1024, self.mode.frameBytes() / 1024,
        });
        write("  drawn        : {d} pixels in {d} fills, {d} frame(s)\n", .{
            self.pixels_written, self.fills, self.frames,
        });
    }
};

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub fn lerpColor(a: Color, b: Color, t: u8) Color {
    const inv: u32 = 255 - t;
    const r = ((a >> 16 & 0xff) * inv + (b >> 16 & 0xff) * t) / 255;
    const g = ((a >> 8 & 0xff) * inv + (b >> 8 & 0xff) * t) / 255;
    const bl = ((a & 0xff) * inv + (b & 0xff) * t) / 255;
    return (@as(u32, @intCast(r)) << 16) | (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(bl));
}

// ---------------------------------------------------------------------------
// The installed surface
// ---------------------------------------------------------------------------

var installed: ?Framebuffer = null;

/// Publish a surface. Called by the display driver once the mode is programmed.
pub fn install(mode: Mode, base: [*]u8) *Framebuffer {
    installed = Framebuffer.init(mode, base);
    if (installed) |*s| return s;
    unreachable;
}

pub fn uninstall() void {
    installed = null;
}

pub fn screen() ?*Framebuffer {
    if (installed) |*s| return s;
    return null;
}

/// Panic helper for callers that must not know whether a panel exists.
pub fn panicScreen(header: []const u8, body: []const u8) void {
    if (screen()) |s| s.drawPanic(header, body);
}

pub fn bootSplash(version: []const u8, status: []const u8) void {
    if (screen()) |s| s.drawSplash(version, status);
}

/// One line for the boot log: what the panel is, or that there is none.
pub fn describeInstalled() void {
    if (screen()) |s| {
        klog.info("fb", "surface {d}x{d} {s} at 0x{x}, {d} KiB per frame", .{
            s.mode.width, s.mode.height, s.mode.format.label(), s.mode.phys, s.mode.frameBytes() / 1024,
        });
    } else {
        klog.info("fb", "no framebuffer installed: the UI has no panel on this machine", .{});
    }
}

// ---------------------------------------------------------------------------
// Tests: draw into an ordinary host buffer.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testMode(width: u32, height: u32, format: Format) Mode {
    return .{
        .width = width,
        .height = height,
        .stride = width * format.bytesPerPixel(),
        .format = format,
        .size = @as(u64, width) * height * format.bytesPerPixel(),
    };
}

test "a pixel round-trips through all three formats" {
    inline for (.{ Format.bgrx8888, Format.rgb888, Format.rgb565 }) |format| {
        var buf = [_]u8{0} ** (8 * 8 * 4);
        var f = Framebuffer.init(testMode(8, 8, format), &buf);
        const colors = [_]Color{ 0xFF0000, 0x00FF00, 0x0000FF, 0x123456 };
        for (colors, 0..) |c, i| {
            f.put(@intCast(i), 0, c);
        }
        // 32-bit and 24-bit are exact; 565 quantises, so compare roughly.
        try testing.expectEqual(@as(Color, 0xFF0000), f.pixelAt(0, 0));
        try testing.expectEqual(@as(Color, 0x00FF00), f.pixelAt(1, 0));
        try testing.expectEqual(@as(Color, 0x0000FF), f.pixelAt(2, 0));
        if (format == .rgb565) {
            const got = f.pixelAt(3, 0);
            try testing.expect(@abs(@as(i32, @intCast(got >> 16 & 0xff)) - 0x12) < 8);
        } else {
            try testing.expectEqual(@as(Color, 0x123456), f.pixelAt(3, 0));
        }
    }
}

test "drawing outside the panel is clipped, never written" {
    var buf = [_]u8{0} ** (16 * 16 * 4);
    var f = Framebuffer.init(testMode(16, 16, .bgrx8888), &buf);

    f.fillRect(-100, -100, 50, 50, 0xFF0000);
    f.fillRect(1000, 1000, 50, 50, 0xFF0000);
    f.put(-1, 0, 0xFFFFFF);
    f.put(16, 16, 0xFFFFFF);
    for (buf) |b| try testing.expectEqual(@as(u8, 0), b);

    // A rectangle overlapping an edge draws only the visible part.
    f.fillRect(14, 0, 10, 2, 0x00FF00);
    try testing.expectEqual(@as(Color, 0x00FF00), f.pixelAt(15, 0));
    try testing.expectEqual(@as(Color, 0), f.pixelAt(13, 0));
    try testing.expectEqual(@as(u64, 4), f.pixels_written);
}

test "text advances by the font's cell width and clips at the edge" {
    var buf = [_]u8{0} ** (12 * 10 * 4);
    var f = Framebuffer.init(testMode(12, 10, .bgrx8888), &buf);

    const end = f.drawText(0, 0, "AB", 1, Palette.white);
    try testing.expectEqual(@as(i32, 12), end);
    try testing.expect(f.pixels_written > 0);

    // At scale 2, one glyph is 10 px wide, so two glyphs overflow a 12 px panel.
    f.pixels_written = 0;
    _ = f.drawText(0, 0, "AB", 2, Palette.white);
    try testing.expect(f.pixels_written > 0);
    try testing.expect(f.pixels_written < 2 * 5 * 7 * 4);
}

test "the test pattern's corner markers land on the corners" {
    var buf = [_]u8{0} ** (64 * 64 * 4);
    var f = Framebuffer.init(testMode(64, 64, .bgrx8888), &buf);
    f.drawTestPattern();
    try testing.expectEqual(@as(Color, 0xFF0000), f.pixelAt(3, 3));
    try testing.expectEqual(@as(Color, 0x00FF00), f.pixelAt(60, 3));
    try testing.expectEqual(@as(Color, 0x0000FF), f.pixelAt(3, 60));
    try testing.expectEqual(@as(Color, 0xFFFFFF), f.pixelAt(60, 60));
    // The border is white all round.
    try testing.expectEqual(@as(Color, 0xFFFFFF), f.pixelAt(32, 0));
    try testing.expectEqual(@as(Color, 0xFFFFFF), f.pixelAt(0, 32));
}

test "the panic screen paints and stays inside the panel" {
    var buf = [_]u8{0} ** (320 * 200 * 4);
    var f = Framebuffer.init(testMode(320, 200, .bgrx8888), &buf);
    f.drawPanic("data abort at EL1", "ESR 0x96000045\nFAR 0x10\nPC 0x40081234\nthis line is long enough to need wrapping over more than one row of the panel and then some");
    try testing.expectEqual(Palette.panic_bar, f.pixelAt(4, 4));
    try testing.expectEqual(Palette.panic_bg, f.pixelAt(200, 190));
    try testing.expect(f.pixels_written > 1000);
}

test "gradient interpolates between the endpoints" {
    var buf = [_]u8{0} ** (4 * 8 * 4);
    var f = Framebuffer.init(testMode(4, 8, .bgrx8888), &buf);
    f.fillGradient(0, 0, 4, 8, 0x000000, 0xFFFFFF);
    try testing.expectEqual(@as(Color, 0x000000), f.pixelAt(0, 0));
    try testing.expectEqual(@as(Color, 0xFFFFFF), f.pixelAt(0, 7));
    const mid = f.pixelAt(0, 4);
    try testing.expect(mid > 0x404040 and mid < 0xC0C0C0);

    try testing.expectEqual(@as(Color, 0x808080), lerpColor(0x000000, 0xFFFFFF, 128));
}
