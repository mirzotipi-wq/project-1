//! Pure display-driver decisions (phase 37).
//!
//! Two choices a display driver must make before it touches a device: which BAR
//! is the framebuffer and which is its register page, and which mode to program
//! given what the panel says it prefers. Neither needs a page table or a CPU
//! register, so both live here and are unit-tested on the host; the driver keeps
//! only the MMIO and mapping work.

const std = @import("std");
const driver = @import("../kernel/driver.zig");
const edid = @import("edid.zig");

pub const Bars = struct {
    vram: u64 = 0,
    vram_size: u64 = 0,
    mmio: u64 = 0,
    ok: bool = false,
};

/// Bars are published in slot order but only assigned slots appear, so geometry
/// — not slot number — identifies them: VRAM is at least a megabyte, the
/// register page is order 4 KiB.
pub fn classifyBars(dev: *const driver.Device) Bars {
    var out = Bars{};
    for (dev.regs[0..dev.reg_count]) |r| {
        if (r.size >= 1024 * 1024) {
            out.vram = r.base;
            out.vram_size = r.size;
        } else if (r.size >= 0x1000 and r.size <= 0x10000) {
            out.mmio = r.base;
        }
    }
    out.ok = out.vram != 0 and out.mmio != 0;
    return out;
}

pub const Choice = struct {
    width: u32,
    height: u32,
    /// The panel's preference was unusable and the safe default was used.
    fell_back: bool,
};

pub const default_width: u32 = 1024;
pub const default_height: u32 = 768;

/// The panel's preferred timing wins when it is sane and fits in the VRAM the
/// device actually has; otherwise a conservative default.
pub fn choose(panel: ?edid.Info, vram_size: u64) Choice {
    if (panel) |p| {
        if (p.bestTiming()) |t| {
            const fits = @as(u64, t.hactive) * t.vactive * 4 <= vram_size;
            if (t.hactive >= 640 and t.vactive >= 480 and
                t.hactive <= 4096 and t.vactive <= 4096 and fits)
            {
                return .{ .width = t.hactive, .height = t.vactive, .fell_back = false };
            }
            return .{ .width = default_width, .height = default_height, .fell_back = true };
        }
    }
    return .{ .width = default_width, .height = default_height, .fell_back = false };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bars are classified by geometry, not slot number" {
    var dev = driver.Device{};
    dev.reg_count = 3;
    dev.regs[0] = .{ .base = 0x1000_0000, .size = 16 * 1024 * 1024 };
    dev.regs[1] = .{ .base = 0x1010_0000, .size = 0x1000 };
    dev.regs[2] = .{ .base = 0x1020_0000, .size = 0x100 };
    const bars = classifyBars(&dev);
    try testing.expect(bars.ok);
    try testing.expectEqual(@as(u64, 0x1000_0000), bars.vram);
    try testing.expectEqual(@as(u64, 16 * 1024 * 1024), bars.vram_size);
    try testing.expectEqual(@as(u64, 0x1010_0000), bars.mmio);

    var missing = driver.Device{};
    missing.reg_count = 1;
    missing.regs[0] = .{ .base = 0x1000_0000, .size = 16 * 1024 * 1024 };
    try testing.expect(!classifyBars(&missing).ok);
}

test "the panel's preferred timing wins when it fits" {
    var panel = std.mem.zeroes(edid.Info);
    panel.preferred = .{
        .pixel_clock_khz = 83_500,
        .hactive = 1280,
        .hblank = 400,
        .vactive = 800,
        .vblank = 31,
        .hsync_offset = 48,
        .hsync_width = 32,
        .vsync_offset = 3,
        .vsync_width = 6,
    };
    const choice = choose(panel, 16 * 1024 * 1024);
    try testing.expectEqual(@as(u32, 1280), choice.width);
    try testing.expectEqual(@as(u32, 800), choice.height);
    try testing.expect(!choice.fell_back);
}

test "a mode that does not fit VRAM falls back to a safe default" {
    var panel = std.mem.zeroes(edid.Info);
    panel.preferred = .{
        .pixel_clock_khz = 594_000,
        .hactive = 3840,
        .hblank = 560,
        .vactive = 2160,
        .vblank = 90,
        .hsync_offset = 0,
        .hsync_width = 0,
        .vsync_offset = 0,
        .vsync_width = 0,
    };
    const choice = choose(panel, 16 * 1024 * 1024);
    try testing.expectEqual(@as(u32, default_width), choice.width);
    try testing.expectEqual(@as(u32, default_height), choice.height);
    try testing.expect(choice.fell_back);

    // The same panel on a 64 MiB framebuffer is fine.
    const roomy = choose(panel, 64 * 1024 * 1024);
    try testing.expectEqual(@as(u32, 3840), roomy.width);
    try testing.expect(!roomy.fell_back);
}

test "no EDID means the default, not a refusal" {
    const choice = choose(null, 16 * 1024 * 1024);
    try testing.expectEqual(@as(u32, 1024), choice.width);
    try testing.expectEqual(@as(u32, 768), choice.height);
    try testing.expect(!choice.fell_back);
}
