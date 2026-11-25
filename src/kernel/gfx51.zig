//! Phase 51 kernel proof: exercise the pure graphics core on a scratch surface
//! and then on the real mapped framebuffer. The shell command deliberately does
//! not trust a log line: the PASS verdict comes from reading pixels back through
//! the same surface after every drawing operation.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const fb = @import("fb.zig");
const gfx = @import("../lib/gfx.zig");

var fault_armed: bool = false;

fn write(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

fn mapFormat(format: fb.Format) gfx.Format {
    return switch (format) {
        .bgrx8888 => .bgrx8888,
        .rgb888 => .rgb888,
        .rgb565 => .rgb565,
    };
}

fn formatChecks() bool {
    inline for (.{ gfx.Format.bgrx8888, gfx.Format.rgba8888, gfx.Format.rgb888, gfx.Format.rgb565 }) |format| {
        var buf = [_]u8{0} ** (4 * 4 * 4);
        var s = gfx.Surface.init(&buf, 4, 4, 4 * 4, format) catch return false;
        s.setPixel(0, 0, gfx.rgba(255, 0, 0, 128));
        const red = s.pixelAt(0, 0);
        if ((red >> 16) & 0xFF != 255) return false;
        if (format == .rgba8888 and red >> 24 != 128) return false;
    }
    return true;
}

fn scratchChecks() bool {
    var dst_buf = [_]u8{0} ** (12 * 10 * 4);
    var src_buf = [_]u8{0} ** (4 * 4 * 4);
    var dst = gfx.Surface.init(&dst_buf, 12, 10, 12 * 4, .rgba8888) catch return false;
    var src = gfx.Surface.init(&src_buf, 4, 4, 4 * 4, .rgba8888) catch return false;

    dst.clear(gfx.rgb(10, 20, 30));
    dst.setClip(.{ .x = 2, .y = 2, .w = 8, .h = 6 });
    dst.fillRect(-3, -3, 8, 8, gfx.rgb(255, 0, 0));
    dst.fillRect(8, 6, 8, 8, gfx.rgb(0, 255, 0));
    const clip_ok = dst.pixelAt(2, 2) == gfx.rgb(255, 0, 0) and
        dst.pixelAt(1, 1) == gfx.rgb(10, 20, 30) and
        dst.pixelAt(9, 7) == gfx.rgb(0, 255, 0) and
        dst.pixelAt(2, 0) == gfx.rgb(10, 20, 30);
    if (!clip_ok) {
        write("  scratch clip: 2,2=0x{x} 1,1=0x{x} 9,7=0x{x} 2,0=0x{x}\n", .{ dst.pixelAt(2, 2), dst.pixelAt(1, 1), dst.pixelAt(9, 7), dst.pixelAt(2, 0) });
        return false;
    }

    dst.setClip(.{ .x = 2, .y = 2, .w = 8, .h = 6 });
    dst.fillRect(3, 3, 2, 2, gfx.rgba(0, 0, 255, 128));
    const blend_ok = dst.pixelAt(3, 3) == gfx.rgb(127, 0, 128);
    if (!blend_ok) {
        write("  scratch blend: 3,3=0x{x}\n", .{dst.pixelAt(3, 3)});
        return false;
    }

    src.clear(gfx.rgba(0, 0, 0, 0));
    src.setPixel(0, 0, gfx.rgba(255, 255, 255, 255));
    src.setPixel(1, 0, gfx.rgba(255, 255, 255, 0));
    src.setPixel(0, 1, gfx.rgba(0, 255, 0, 128));
    dst.setClip(.{ .x = 2, .y = 2, .w = 8, .h = 6 });
    dst.blit(&src, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .x = 2, .y = 2, .w = 4, .h = 4 }, 255);
    const blit_ok = dst.pixelAt(2, 2) == gfx.rgb(255, 255, 255) and
        dst.pixelAt(3, 2) == gfx.rgb(255, 0, 0) and
        dst.pixelAt(2, 3) == gfx.rgb(127, 128, 0) and
        dst.pixelAt(3, 3) == gfx.rgb(127, 0, 128);
    if (!blit_ok) {
        write("  scratch blit: 2,2=0x{x} 3,2=0x{x} 2,3=0x{x} 3,3=0x{x}\n", .{ dst.pixelAt(2, 2), dst.pixelAt(3, 2), dst.pixelAt(2, 3), dst.pixelAt(3, 3) });
        return false;
    }

    dst.damage.reset();
    dst.fillRect(2, 2, 2, 2, gfx.rgb(1, 2, 3));
    dst.fillRect(4, 4, 2, 2, gfx.rgb(1, 2, 3));
    const damage_ok = dst.damage.count == 1 and
        dst.damage.pixels() == 16 and
        dst.damage.bounds() != null;
    if (!damage_ok) {
        write("  scratch damage: count={d} pixels={d}\n", .{ dst.damage.count, dst.damage.pixels() });
        return false;
    }

    return true;
}

fn drawFrag(src: *gfx.Surface) void {
    // A source image is raw RGBA, not a composite destination: setPixel keeps
    // the alpha channel exactly as authored so the blit can composite it.
    var y: i32 = 0;
    while (y < 32) : (y += 1) {
        var x: i32 = 0;
        while (x < 32) : (x += 1) {
            const color: gfx.Color = if (x < 16 and y < 16)
                gfx.rgba(255, 255, 255, 255)
            else if (x >= 16 and y < 16)
                gfx.rgba(255, 0, 255, 0)
            else if (x < 16)
                gfx.rgba(0, 255, 0, 128)
            else
                gfx.rgba(255, 128, 0, 255);
            src.setPixel(x, y, color);
        }
    }
}

pub fn command(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "test";

    if (std.mem.eql(u8, sub, "inject")) {
        fault_armed = true;
        write("  gfx inject  : armed; the next test deliberately corrupts its card\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "repair")) {
        fault_armed = false;
        write("  gfx inject  : cleared\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "info")) {
        write("  gfx formats : bgrx8888 rgba8888 rgb888 rgb565\n", .{});
        write("  gfx core    : surfaces, clipped blits, straight alpha, bounded damage\n", .{});
        return;
    }
    if (!std.mem.eql(u8, sub, "test")) {
        write("  usage: gfx [test|inject|repair|info]\n", .{});
        return;
    }

    const screen = fb.screen() orelse {
        write("  gfx formats : bgrx8888 rgba8888 rgb888 rgb565\n", .{});
        write("  gfx core    : FAIL (no framebuffer)\n", .{});
        return;
    };
    const raw = screen.rawBytes();
    var surface = gfx.Surface.init(raw, screen.mode.width, screen.mode.height, screen.mode.stride, mapFormat(screen.mode.format)) catch {
        write("  gfx core    : FAIL (framebuffer surface geometry)\n", .{});
        return;
    };

    if (!formatChecks()) {
        write("  gfx encode  : FAIL (format round-trip)\n", .{});
        write("  gfx core    : FAIL\n", .{});
        return;
    }
    if (!scratchChecks()) {
        write("  gfx core    : FAIL (scratch clip/blit/blend/damage)\n", .{});
        return;
    }

    const card_w: i32 = 128;
    const card_h: i32 = 96;
    if (screen.mode.width < @as(u32, @intCast(card_w)) or screen.mode.height < @as(u32, @intCast(card_h))) {
        write("  gfx core    : FAIL (panel smaller than 128x96 test card)\n", .{});
        return;
    }
    const card_x: i32 = @intCast((screen.mode.width - @as(u32, @intCast(card_w))) / 2);
    const card_y: i32 = @intCast((screen.mode.height - @as(u32, @intCast(card_h))) / 2);
    const card = gfx.Rect{ .x = card_x, .y = card_y, .w = card_w, .h = card_h };
    const outside_before = surface.pixelAt(card_x - 1, card_y + 1);

    var frag_buf = [_]u8{0} ** (32 * 32 * 4);
    var frag = gfx.Surface.init(&frag_buf, 32, 32, 32 * 4, .rgba8888) catch {
        write("  gfx core    : FAIL (source surface)\n", .{});
        return;
    };
    drawFrag(&frag);

    surface.damage.reset();
    surface.setClip(card);
    surface.fillRect(card_x, card_y, card_w, card_h, gfx.rgb(16, 24, 32));
    // This rectangle starts outside the card; the clip must trim it before it
    // can touch the neighbouring framebuffer pixels.
    surface.fillRect(card_x - 16, card_y - 16, 64, 64, gfx.rgb(220, 32, 32));
    surface.fillRect(card_x + 64, card_y, 64, 48, gfx.rgb(32, 180, 64));
    surface.fillRect(card_x, card_y + 48, 48, 48, gfx.rgba(0, 64, 255, 128));
    surface.blit(&frag, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .{ .x = card_x + 64, .y = card_y + 48, .w = 32, .h = 32 }, 255);
    if (fault_armed) {
        // Test-only negative control: make the observable card wrong without
        // changing the library, so the readback verifier must reject it.
        surface.setPixel(card_x + 8, card_y + 8, gfx.rgb(255, 0, 255));
    }
    surface.resetClip();

    const red = surface.pixelAt(card_x + 8, card_y + 8);
    const green = surface.pixelAt(card_x + 72, card_y + 8);
    const blue = surface.pixelAt(card_x + 8, card_y + 56);
    const source_white = surface.pixelAt(card_x + 72, card_y + 56);
    const source_clear = surface.pixelAt(card_x + 80, card_y + 56);
    const source_green = surface.pixelAt(card_x + 72, card_y + 72);
    const outside_after = surface.pixelAt(card_x - 1, card_y + 1);
    const expected_blue = gfx.rgb(8, 44, 144);
    if (red != gfx.rgb(220, 32, 32) or green != gfx.rgb(32, 180, 64) or blue != expected_blue or
        source_white != gfx.rgb(255, 255, 255) or source_clear != gfx.rgb(16, 24, 32) or
        source_green != gfx.rgb(8, 140, 16) or outside_after != outside_before)
    {
        write("  card px: red=0x{x} green=0x{x} blue=0x{x} white=0x{x} clear=0x{x} srcgreen=0x{x} outside 0x{x}->0x{x}\n", .{
            red, green, blue, source_white, source_clear, source_green, outside_before, outside_after,
        });
    }

    const card_ok = red == gfx.rgb(220, 32, 32) and
        green == gfx.rgb(32, 180, 64) and
        blue == expected_blue and
        source_white == gfx.rgb(255, 255, 255) and
        source_clear == gfx.rgb(16, 24, 32) and
        source_green == gfx.rgb(8, 140, 16) and
        outside_after == outside_before;
    const damage_ok = surface.damage.count >= 1 and surface.damage.pixels() >= @as(u64, @intCast(card_w * card_h));
    const snapshot = surface.snapshotRect(card) orelse 0;

    write("  gfx formats : bgrx8888 rgba8888 rgb888 rgb565\n", .{});
    write("  gfx encode  : PASS (all four formats round-trip)\n", .{});
    write("  gfx clip    : {s} (negative and overflow draws clipped to the card)\n", .{if (card_ok) "PASS" else "FAIL"});
    write("  gfx blit    : {s} (RGBA source, per-pixel alpha, clipped)\n", .{if (source_white == gfx.rgb(255, 255, 255) and source_clear == gfx.rgb(16, 24, 32)) "PASS" else "FAIL"});
    write("  gfx damage  : {s} ({d} rect(s), {d} px)\n", .{ if (damage_ok) "PASS" else "FAIL", surface.damage.count, surface.damage.pixels() });
    write("  gfx frame   : {d}x{d} {s}, card {d},{d} {d}x{d}\n", .{
        screen.mode.width, screen.mode.height, screen.mode.format.label(), card_x, card_y, card_w, card_h,
    });
    write("  gfx snapshot: 0x{x:0>8}\n", .{snapshot});
    write("  gfx core    : {s}\n", .{if (card_ok and damage_ok and !fault_armed) "PASS" else "FAIL"});
}
