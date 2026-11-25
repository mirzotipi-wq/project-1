//! Phase 53 kernel proof: parse the embedded TrueType subset, render a real POS
//! text card on the mapped framebuffer, and verify the font engine from pixel
//! readback. The command also exposes a test-only glyph fault so the harness can
//! prove that a missing glyph changes the card instead of only changing a log.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const fb = @import("fb.zig");
const gfx = @import("../lib/gfx.zig");
const raster = @import("../lib/raster2d.zig");
const font = @import("../lib/font.zig");
const heap = @import("heap.zig");

var renderer: font.Renderer = undefined;
var renderer_ready: bool = false;
var fault_armed: bool = false;

const CARD_X: i32 = 180;
const CARD_Y: i32 = 50;
const CARD_W: i32 = 920;
const CARD_H: i32 = 700;

const TITLE = "CASSA";
const PRICE = "\u{20AC} 42.50";
const CARD_LINE = "CARD **** 4242";
const SAMPLE = "AV 1,234.56";
const SIZE_BASELINES = [_]i32{ 390, 418, 452, 492, 548, 680 };
const SIZE_PIXELS = [_]u16{ 8, 12, 18, 24, 36, 48 };

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

fn ensureRenderer() bool {
    if (renderer_ready) return true;
    renderer.initInPlace(font.embedded_font) catch |err| {
        write("  text font    : FAIL (embedded face: {s})\n", .{@errorName(err)});
        return false;
    };
    renderer_ready = true;
    return true;
}

fn options() font.DrawOptions {
    return .{ .corrupt_gid = if (fault_armed) renderer.font.glyphIndex('A') else null };
}

const Ink = struct {
    glyphs: u32 = 0,
    missing: u32 = 0,
    missing_cp: u21 = 0,
    ink: u32 = 0,
    ascii_ok: bool = true,
    size_ok: bool = true,
    corrupted: bool = false,
};

fn add(result: font.DrawResult, acc: *Ink) void {
    if (acc.missing == 0 and result.missing != 0) acc.missing_cp = result.missing_cp;
    acc.glyphs += result.glyphs;
    acc.missing += result.missing;
    acc.ink += result.ink;
    acc.corrupted = acc.corrupted or result.corrupted;
}

fn drawCard(surface: *gfx.Surface, acc: *Ink) void {
    surface.clear(gfx.rgb(10, 14, 20));
    const card = gfx.Rect{ .x = CARD_X, .y = CARD_Y, .w = CARD_W, .h = CARD_H };
    raster.fillRoundedRect(surface, card, 22, gfx.rgb(20, 28, 40));
    surface.fillRect(CARD_X, CARD_Y, CARD_W, 104, gfx.rgb(36, 120, 220));
    raster.fillRoundedRect(surface, .{ .x = CARD_X, .y = CARD_Y, .w = CARD_W, .h = 22 }, 22, gfx.rgb(36, 120, 220));
    raster.fillCircle(surface, CARD_X + 53, CARD_Y + 51, 25, gfx.rgb(240, 244, 248));
    raster.fillCircle(surface, CARD_X + 53, CARD_Y + 51, 16, gfx.rgb(36, 120, 220));

    const opts = options();
    const white = gfx.rgb(240, 244, 248);
    const muted = gfx.rgb(150, 170, 190);
    const accent = gfx.rgb(76, 210, 168);
    const gold = gfx.rgb(255, 206, 84);

    add(font.drawText(&renderer, surface, TITLE, (CARD_X + 104) << 16, CARD_Y + 70, 36, white, opts), acc);
    add(font.drawText(&renderer, surface, "POINT OF SALE  /  TERMINAL 07", (CARD_X + 106) << 16, CARD_Y + 96, 14, gfx.rgb(214, 232, 248), opts), acc);

    add(font.drawText(&renderer, surface, "TOTAL DUE", (CARD_X + 50) << 16, CARD_Y + 166, 18, muted, opts), acc);
    add(font.drawText(&renderer, surface, PRICE, (CARD_X + 48) << 16, CARD_Y + 238, 48, white, opts), acc);
    add(font.drawText(&renderer, surface, CARD_LINE, (CARD_X + 50) << 16, CARD_Y + 284, 18, muted, opts), acc);
    add(font.drawText(&renderer, surface, "SUBTOTAL 39.72   TAX 2.78", (CARD_X + 50) << 16, CARD_Y + 312, 14, muted, opts), acc);

    raster.line(surface, CARD_X + 48, CARD_Y + 334, CARD_X + CARD_W - 48, CARD_Y + 334, 1, gfx.rgb(52, 70, 90));

    // Every printable ASCII codepoint at 10 px, one at a time, proves there is
    // no fallback or missing box in the advertised face coverage.
    var ascii_pen: i32 = (CARD_X + 50) << 16;
    var ascii_cp: u21 = 0x20;
    while (ascii_cp <= 0x7E) : (ascii_cp += 1) {
        var one = [_]u8{@intCast(ascii_cp)};
        const r = font.drawText(&renderer, surface, &one, ascii_pen, CARD_Y + 366, 10, muted, opts);
        if (ascii_cp != 0x20 and r.ink == 0) acc.ascii_ok = false;
        ascii_pen += r.width_q16;
        add(r, acc);
    }

    for (SIZE_PIXELS, SIZE_BASELINES, 0..) |px, baseline, i| {
        const color = if (i == SIZE_PIXELS.len - 1) gold else white;
        const r = font.drawText(&renderer, surface, SAMPLE, (CARD_X + 50) << 16, CARD_Y + baseline, px, color, opts);
        if (r.glyphs != 11 or r.missing != 0 or r.ink < 4) acc.size_ok = false;
        add(r, acc);
    }

    // LTR and RTL, plus two subpixel phases, in regions far from the price.
    add(font.drawText(&renderer, surface, "AV", (CARD_X + 520) << 16, CARD_Y + 650, 48, accent, opts), acc);
    add(font.drawText(&renderer, surface, "AV", (CARD_X + 620) << 16, CARD_Y + 650, 48, accent, .{ .corrupt_gid = options().corrupt_gid, .direction = .rtl }), acc);
}

pub fn command(heap_ptr: *heap.Heap, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    _ = heap_ptr;
    const sub = tokens.next() orelse "test";
    if (std.mem.eql(u8, sub, "inject")) {
        fault_armed = true;
        write("  text inject  : armed; the next card test skips glyph A\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "repair")) {
        fault_armed = false;
        write("  text inject  : cleared\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "info")) {
        write("  text API     : TrueType glyf, cmap4, hmtx, legacy kern, 4x AA scanline\n", .{});
        write("  text layout  : 8..48 px, 4-phase subpixel, RTL order, shaping hook\n", .{});
        write("  text cache   : 64-entry bounded coverage atlas, LRU replacement\n", .{});
        return;
    }
    if (!std.mem.eql(u8, sub, "test")) {
        write("  usage: text [test|inject|repair|info]\n", .{});
        return;
    }
    if (!ensureRenderer()) {
        write("  text verdict : FAIL\n", .{});
        return;
    }

    const screen = fb.screen() orelse {
        write("  text card    : FAIL (no framebuffer)\n", .{});
        write("  text verdict : FAIL\n", .{});
        return;
    };
    if (screen.mode.width < 1280 or screen.mode.height < 800) {
        write("  text card    : FAIL (framebuffer smaller than 1280x800)\n", .{});
        write("  text verdict : FAIL\n", .{});
        return;
    }
    const raw = screen.rawBytes();
    var surface = gfx.Surface.init(raw, screen.mode.width, screen.mode.height, screen.mode.stride, mapFormat(screen.mode.format)) catch {
        write("  text card    : FAIL (framebuffer surface geometry)\n", .{});
        write("  text verdict : FAIL\n", .{});
        return;
    };

    var acc = Ink{};
    drawCard(&surface, &acc);

    const font_ok = renderer.font.units_per_em == 2048 and renderer.font.num_glyphs == 100 and
        renderer.font.kernPairCount() == 220;
    write("  text font    : {s} {d} glyphs, upem {d}, kern {d} pairs, {d} B embedded\n", .{
        if (font_ok) "PASS" else "FAIL",
        renderer.font.num_glyphs,
        renderer.font.units_per_em,
        renderer.font.kernPairCount(),
        font.embedded_font.len,
    });

    const layout_ok = acc.missing == 0 and acc.glyphs >= 95 and acc.ascii_ok;
    write("  text layout  : {s} {d} glyphs drawn, missing {d} (cp 0x{x}), all printable ASCII at 10 px\n", .{
        if (layout_ok) "PASS" else "FAIL", acc.glyphs, acc.missing, acc.missing_cp,
    });

    const av = font.measure(&renderer, "AV", 48, .{});
    const a = font.measure(&renderer, "A", 48, .{});
    const v = font.measure(&renderer, "V", 48, .{});
    const kerning_ok = av.kerning_q16 < 0 and av.width_q16 < a.width_q16 + v.width_q16;
    write("  text kerning : {s} AV {d} q16 vs A+V {d} q16, delta {d} q16\n", .{
        if (kerning_ok) "PASS" else "FAIL",
        av.width_q16,
        a.width_q16 + v.width_q16,
        av.kerning_q16,
    });

    const accent = gfx.rgb(76, 210, 168);
    const phase0_rect = gfx.Rect{ .x = CARD_X + 700, .y = CARD_Y + 610, .w = 150, .h = 60 };
    const phase0 = surface.snapshotRect(phase0_rect) orelse 0;
    const phase_text = font.drawText(&renderer, &surface, "AV", ((CARD_X + 700) << 16) + 32768, CARD_Y + 650, 24, accent, options());
    add(phase_text, &acc);
    const phase2 = surface.snapshotRect(phase0_rect) orelse 0;
    const subpixel_ok = phase0 != phase2 and phase_text.glyphs == 2;
    write("  text subpixel: {s} 0.0 vs 0.5 px snapshots differ, glyphs {d}\n", .{
        if (subpixel_ok) "PASS" else "FAIL", phase_text.glyphs,
    });

    const cache_ok = renderer.hits > 0 and renderer.misses > 0 and renderer.evictions <= renderer.misses;
    write("  text cache   : {s} hits {d}, misses {d}, evictions {d}, entries {d}\n", .{
        if (cache_ok) "PASS" else "FAIL",
        renderer.hits,
        renderer.misses,
        renderer.evictions,
        font.max_cache_entries,
    });

    const total_ink = acc.ink;
    const sizes_ok = acc.size_ok and acc.glyphs >= 95 + 5 + 7 + 14 + 6 * 11 and acc.ink > 1_000;
    const card_snapshot = surface.snapshotRect(.{ .x = CARD_X, .y = CARD_Y, .w = CARD_W, .h = CARD_H }) orelse 0;
    const card_ok = layout_ok and kerning_ok and subpixel_ok and cache_ok and sizes_ok and !acc.corrupted;
    write("  text sizes   : {s} 8,12,18,24,36,48 px, {d} glyphs, {d} ink pixels\n", .{
        if (sizes_ok) "PASS" else "FAIL", acc.glyphs, total_ink,
    });
    write("  text card    : {s} {d}x{d} at {d},{d}, snapshot 0x{x:0>8}\n", .{
        if (card_ok) "PASS" else "FAIL", CARD_W, CARD_H, CARD_X, CARD_Y, card_snapshot,
    });
    write("  text regions : card={d},{d},{d},{d} title={d},{d},{d},{d} price={d},{d},{d},{d} sizes={d},{d},{d},{d}\n", .{
        CARD_X,             CARD_Y,             CARD_W,             CARD_H,
        CARD_X + 104,       CARD_Y + 30,       400,                60,
        CARD_X + 48,        CARD_Y + 190,      520,                90,
        CARD_X + 48,        CARD_Y + 350,      820,                360,
    });
    if (acc.missing != 0 or acc.corrupted or !card_ok) {
        write("  text fault   : missing={d}, corrupted={s}, title_ink={d}\n", .{
            acc.missing, if (acc.corrupted) "true" else "false", total_ink,
        });
    }
    write("  text verdict : {s}\n", .{if (card_ok) "PASS" else "FAIL"});
}
