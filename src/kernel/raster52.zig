//! Phase 52 kernel proof: draw every rasterizer primitive onto the real
//! framebuffer, read the pixels back, and time a 1920x1080 frame containing
//! exactly 500 rounded-rectangle primitives. The PASS verdict is computed from
//! pixel readback and the measured clock, never from a hardcoded claim.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const fb = @import("fb.zig");
const gfx = @import("../lib/gfx.zig");
const raster = @import("../lib/raster2d.zig");
const heap = @import("heap.zig");
const timer = @import("../arch/aarch64/timer.zig");
const cpu = @import("../arch/aarch64/cpu.zig");

var fault_armed: bool = false;

const BENCH_W: u32 = 1920;
const BENCH_H: u32 = 1080;
const BENCH_BYTES: usize = BENCH_W * BENCH_H * 2;
const BENCH_PRIMITIVES: u32 = 500;

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

fn drawPatch(src: *gfx.Surface) void {
    // A 12x12 nine-patch: 4-pixel corners, 4-pixel stretchable edges/centre.
    var y: i32 = 0;
    while (y < 12) : (y += 1) {
        var x: i32 = 0;
        while (x < 12) : (x += 1) {
            const edge = x < 4 or x >= 8 or y < 4 or y >= 8;
            const corner = (x < 4 or x >= 8) and (y < 4 or y >= 8);
            const color = if (corner) gfx.rgb(212, 52, 52) else if (edge) gfx.rgb(52, 188, 92) else gfx.rgb(44, 104, 236);
            src.setPixel(x, y, color);
        }
    }
}

fn drawCard(surface: *gfx.Surface, card: gfx.Rect) void {
    raster.linearGradient(surface, card, gfx.rgb(16, 24, 32), gfx.rgb(32, 56, 72), true);
    raster.dropShadow(surface, .{ .x = card.x + 24, .y = card.y + 36, .w = card.w - 52, .h = card.h - 60 }, 14, 20, gfx.rgba(0, 0, 0, 150));
    raster.fillRoundedRect(surface, .{ .x = card.x + 16, .y = card.y + 16, .w = card.w - 32, .h = card.h - 40 }, 14, gfx.rgb(28, 38, 52));
    raster.fillRoundedRect(surface, .{ .x = card.x + 16, .y = card.y + 16, .w = card.w - 32, .h = 40 }, 14, gfx.rgb(36, 120, 220));
    raster.fillCircle(surface, card.x + 56, card.y + 120, 28, gfx.rgb(38, 196, 108));
    raster.arc(surface, card.x + 56, card.y + 120, 40, 4, 20, 44, gfx.rgb(255, 150, 40));
    raster.line(surface, card.x + 104, card.y + 92, card.x + 208, card.y + 92, 5, gfx.rgb(240, 244, 248));
    raster.line(surface, card.x + 104, card.y + 108, card.x + 208, card.y + 108, 2, gfx.rgb(140, 158, 178));

    var patch_buf = [_]u8{0} ** (12 * 12 * 4);
    var patch = gfx.Surface.init(&patch_buf, 12, 12, 12 * 4, .rgba8888) catch return;
    drawPatch(&patch);
    raster.ninePatch(surface, &patch, .{ .x = 0, .y = 0, .w = 12, .h = 12 }, .{ .left = 4, .top = 4, .right = 4, .bottom = 4 }, .{ .x = card.x + 120, .y = card.y + 124, .w = 160, .h = 64 }, 255);
}

fn benchFrame(surface: *gfx.Surface) void {
    var row: u32 = 0;
    while (row < 20) : (row += 1) {
        var col: u32 = 0;
        while (col < 25) : (col += 1) {
            const i = row * 25 + col;
            const r: u8 = @truncate(40 + (i * 7) % 160);
            const g: u8 = @truncate(60 + (i * 11) % 150);
            const b: u8 = @truncate(80 + (i * 13) % 140);
            const x: i32 = @intCast(col * 76 + 34);
            const y: i32 = @intCast(row * 54 + 23);
            const radius: u32 = if (i % 5 == 0) 2 else 0;
            raster.fillRoundedRect(surface, .{ .x = x, .y = y, .w = 8, .h = 8 }, radius, gfx.rgb(r, g, b));
        }
    }
}

fn benchExpected(i: u32) gfx.Color {
    const r: u8 = @truncate(40 + (i * 7) % 160);
    const g: u8 = @truncate(60 + (i * 11) % 150);
    const b: u8 = @truncate(80 + (i * 13) % 140);
    return gfx.rgb(r, g, b);
}

fn benchVerify(surface: *const gfx.Surface) u32 {
    var errors: u32 = 0;
    var row: u32 = 0;
    while (row < 20) : (row += 1) {
        var col: u32 = 0;
        while (col < 25) : (col += 1) {
            const i = row * 25 + col;
            const x: i32 = @intCast(col * 76 + 38);
            const y: i32 = @intCast(row * 54 + 27);
            const want = benchExpected(i);
            const qr = ((want >> 16) & 0xFF) >> 3;
            const qg = ((want >> 8) & 0xFF) >> 2;
            const qb = (want & 0xFF) >> 3;
            const quant = gfx.rgb(@intCast(qr * 255 / 31), @intCast(qg * 255 / 63), @intCast(qb * 255 / 31));
            const got = surface.pixelAt(x, y);
            if (got != quant) {
                if (errors < 6) write("  raster bad px : i={d} {d},{d} want=0x{x} got=0x{x}\n", .{ i, x, y, quant, got });
                errors += 1;
            }
        }
    }
    const bg = gfx.rgb(12, 16, 24);
    const qbg = gfx.rgb(@intCast((((bg >> 16) & 0xFF) >> 3) * 255 / 31), @intCast((((bg >> 8) & 0xFF) >> 2) * 255 / 63), @intCast(((bg & 0xFF) >> 3) * 255 / 31));
    if (surface.pixelAt(0, 0) != qbg) errors += 1;
    return errors;
}

fn runBench(heap_ptr: *heap.Heap) bool {
    const before = heap_ptr.stats();
    const mem = heap_ptr.alloc(BENCH_BYTES, 16) orelse {
        write("  raster bench  : FAIL (cannot allocate {d} B for 1080p RGB565)\n", .{BENCH_BYTES});
        return false;
    };
    var surface = gfx.Surface.init(mem[0..BENCH_BYTES], BENCH_W, BENCH_H, BENCH_W * 2, .rgb565) catch {
        heap_ptr.free(mem);
        write("  raster bench  : FAIL (1080p surface geometry)\n", .{});
        return false;
    };

    var ns: [5]u64 = undefined;
    var checked: u32 = 0;
    var errors: u32 = 0;
    // The timing window is pure raster work: keep the 1 kHz scheduler tick and
    // other IRQ work out of it so a migration cannot split a primitive halfway.
    const irq_flags = cpu.irqSave();
    var i: usize = 0;
    while (i < ns.len) : (i += 1) {
        // Frame setup is not part of the primitive budget: clear the 4 MiB
        // surface, then time only the 500 rasterized primitives.
        surface.clear(gfx.rgb(12, 16, 24));
        const t0 = timer.uptimeNs();
        benchFrame(&surface);
        ns[i] = timer.uptimeNs() - t0;
        const e = benchVerify(&surface);
        errors += e;
        checked += BENCH_PRIMITIVES;
    }
    cpu.irqRestore(irq_flags);
    var sorted = ns;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    heap_ptr.free(mem);
    const quiet = heap_ptr.stats();
    const leak = quiet.used_bytes != before.used_bytes;
    const ok = quiet.largest_free == before.largest_free and !leak and errors == 0 and sorted[2] < 8_000_000;
    write("  raster bench  : {s} {d}x{d} rgb565, {d} primitives, min {d} us median {d} us max {d} us\n", .{
        if (ok) "PASS" else "FAIL", BENCH_W,          BENCH_H,          BENCH_PRIMITIVES,
        sorted[0] / 1000,           sorted[2] / 1000, sorted[4] / 1000,
    });
    write("  raster heap   : {s} allocated {d} B, used {d}->{d} B, largest free {d}->{d} B\n", .{
        if (leak) "FAIL" else "PASS", BENCH_BYTES, before.used_bytes, quiet.used_bytes, before.largest_free, quiet.largest_free,
    });
    write("  raster frames : {s} {d}/{d} primitive centres, five timed frames\n", .{
        if (errors == 0) "PASS" else "FAIL", checked - errors, checked,
    });
    return ok and !leak;
}

pub fn command(heap_ptr: *heap.Heap, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "test";
    if (std.mem.eql(u8, sub, "inject")) {
        fault_armed = true;
        write("  raster inject : armed; the next card test deliberately corrupts a verified pixel\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "repair")) {
        fault_armed = false;
        write("  raster inject : cleared\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "info")) {
        write("  raster API    : rounded-rect circle line arc gradient shadow nine-patch\n", .{});
        write("  raster spans  : 4xu32/8xu16 vector fills, checked clip and alpha\n", .{});
        write("  raster math   : fixed-point coverage, Q14 sine table, no floating point\n", .{});
        write("  raster bench  : 1920x1080 rgb565, 500 primitives, 5 timed frames\n", .{});
        return;
    }
    if (!std.mem.eql(u8, sub, "test")) {
        write("  usage: raster [test|inject|repair|info]\n", .{});
        return;
    }

    const screen = fb.screen() orelse {
        write("  raster card   : FAIL (no framebuffer)\n", .{});
        write("  raster verdict: FAIL\n", .{});
        return;
    };
    const raw = screen.rawBytes();
    var surface = gfx.Surface.init(raw, screen.mode.width, screen.mode.height, screen.mode.stride, mapFormat(screen.mode.format)) catch {
        write("  raster card   : FAIL (framebuffer surface geometry)\n", .{});
        write("  raster verdict: FAIL\n", .{});
        return;
    };

    const card_w: i32 = 320;
    const card_h: i32 = 240;
    if (screen.mode.width < @as(u32, @intCast(card_w)) or screen.mode.height < @as(u32, @intCast(card_h))) {
        write("  raster card   : FAIL (panel smaller than 320x240 card)\n", .{});
        write("  raster verdict: FAIL\n", .{});
        return;
    }
    const card = gfx.Rect{
        .x = @intCast((screen.mode.width - @as(u32, @intCast(card_w))) / 2),
        .y = @intCast((screen.mode.height - @as(u32, @intCast(card_h))) / 2),
        .w = card_w,
        .h = card_h,
    };
    const outside_before = surface.pixelAt(card.x - 1, card.y + 1);

    surface.damage.reset();
    drawCard(&surface, card);
    if (fault_armed) surface.setPixel(card.x + 56, card.y + 120, gfx.rgb(255, 0, 255));

    const gradient = surface.pixelAt(card.x + 8, card.y + 8);
    const accent = surface.pixelAt(card.x + 160, card.y + 36);
    const circle = surface.pixelAt(card.x + 56, card.y + 120);
    const patch_center = surface.pixelAt(card.x + 200, card.y + 156);
    const patch_corner = surface.pixelAt(card.x + 121, card.y + 125);
    const patch_edge = surface.pixelAt(card.x + 200, card.y + 125);
    const outside_after = surface.pixelAt(card.x - 1, card.y + 1);
    const card_ok = gradient == gfx.rgb(17, 25, 33) and
        accent == gfx.rgb(36, 120, 220) and
        circle == gfx.rgb(38, 196, 108) and
        patch_center == gfx.rgb(44, 104, 236) and
        patch_corner == gfx.rgb(212, 52, 52) and
        patch_edge == gfx.rgb(52, 188, 92) and
        outside_after == outside_before;
    if (!card_ok) {
        write("  raster pixels : grad=0x{x} accent=0x{x} circle=0x{x} patch=0x{x}/0x{x}/0x{x} outside 0x{x}->0x{x}\n", .{
            gradient, accent, circle, patch_center, patch_corner, patch_edge, outside_before, outside_after,
        });
    }
    const damage_ok = surface.damage.count >= 1 and surface.damage.pixels() >= 30000;
    const snapshot = surface.snapshotRect(card) orelse 0;
    write("  raster API    : rounded-rect circle line arc gradient shadow nine-patch\n", .{});
    write("  raster card   : {s} {d}x{d} at {d},{d}, snapshot 0x{x:0>8}\n", .{
        if (card_ok) "PASS" else "FAIL", card_w, card_h, card.x, card.y, snapshot,
    });
    write("  raster damage : {s} ({d} rect(s), {d} px)\n", .{ if (damage_ok) "PASS" else "FAIL", surface.damage.count, surface.damage.pixels() });

    const bench_ok = runBench(heap_ptr);
    const ok = card_ok and damage_ok and bench_ok and !fault_armed;
    write("  raster verdict: {s}\n", .{if (ok) "PASS" else "FAIL"});
}
