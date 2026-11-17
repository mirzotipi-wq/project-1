//! Bochs-display (QEMU's simple linear-framebuffer PCI adapter), phase 37.
//!
//! The device is deliberately the easiest real panel in the tree: BAR 0 is the
//! VRAM window, BAR 2 is a 4 KiB MMIO page that carries the EDID blob at offset
//! 0 and the "bochs dispi" (VBE) register window at 0x500. A 16-bit index/data
//! pair programs the mode; the device then scans out of BAR 0.
//!
//! The driver reads the panel's EDID, picks the preferred timing, programs it,
//! maps the VRAM as normal non-cacheable memory (not Device-nGnRnE: a pixel
//! write should not be an ordered device transaction), verifies a write/read
//! round trip through the MMU, and publishes the surface to `fb`.
//!
//! Everything here is what a real panel brings: the mode comes from the panel,
//! not from a table in the kernel.

const std = @import("std");
const driver = @import("../kernel/driver.zig");
const klog = @import("../kernel/klog.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const fb = @import("../kernel/fb.zig");
const edid = @import("../lib/edid.zig");
const display_mode = @import("../lib/display_mode.zig");

pub const vendor_id: u16 = 0x1234;
pub const device_id: u16 = 0x1111;

/// Offsets inside BAR 2.
const edid_offset: usize = 0x000;
const dispi_offset: usize = 0x500;
const qext_offset: usize = 0x600;

/// VBE / bochs dispi register indices.
const Reg = enum(u16) {
    id = 0x0,
    xres = 0x1,
    yres = 0x2,
    bpp = 0x3,
    enable = 0x4,
    bank = 0x5,
    virt_width = 0x6,
    virt_height = 0x7,
    x_offset = 0x8,
    y_offset = 0x9,
    video_memory_64k = 0xa,
};

const enable_disabled: u16 = 0x00;
const enable_enabled: u16 = 0x01;
const enable_lfb: u16 = 0x40;
const enable_noclearmem: u16 = 0x80;

const qext_byteorder: usize = 0x604;
const qext_little_endian: u32 = 0x1e1e1e1e;

pub const Display = struct {
    present: bool = false,
    vram_phys: u64 = 0,
    vram_size: u64 = 0,
    mmio_phys: u64 = 0,
    dispi_id: u16 = 0,
    vram_64k: u16 = 0,

    width: u32 = 0,
    height: u32 = 0,
    bpp: u8 = 0,
    stride: u32 = 0,
    mapped_bytes: u64 = 0,

    edid_ok: bool = false,
    edid_name: [14]u8 = [_]u8{' '} ** 14,
    edid_name_len: usize = 0,
    edid_manufacturer: [3]u8 = .{ '?', '?', '?' },
    edid_year: u16 = 0,
    preferred_refresh_hz: u32 = 0,

    mode_sets: u32 = 0,
    fallbacks: u32 = 0,
    refusals: u32 = 0,
    last_reason: []const u8 = "not probed",
};

var display: Display = .{};

pub fn info() *const Display {
    return &display;
}

pub fn present() bool {
    return display.present;
}

fn reg16(base: usize, off: usize) *volatile u16 {
    return @ptrFromInt(base + off);
}

fn mmio32(base: usize, off: usize) *volatile u32 {
    return @ptrFromInt(base + off);
}

// The dispi window is directly addressed: one 16-bit register per index, at
// 0x500 + index * 2. There is no index latch (QEMU's bochs_display_vbe_ops
// derives the register from the address itself).
fn dispiRead(base: usize, index: Reg) u16 {
    return reg16(base, dispi_offset + @as(usize, @intFromEnum(index)) * 2).*;
}

fn dispiWrite(base: usize, index: Reg, value: u16) void {
    reg16(base, dispi_offset + @as(usize, @intFromEnum(index)) * 2).* = value;
}

fn readByte(base: u64, off: usize) u8 {
    const p: *volatile u8 = @ptrFromInt(base + off);
    return p.*;
}

fn readEdid(mmio: u64) ?edid.Info {
    var blob: [edid.block_size]u8 = undefined;
    for (&blob, 0..) |*b, i| b.* = readByte(mmio, edid_offset + i);
    return edid.parse(&blob) catch null;
}

/// Program the panel. Returns the stride the device reports.
fn programMode(width: u32, height: u32) !u32 {
    if (!display.present) return error.NoDisplay;

    const frame_bytes = @as(u64, width) * height * 4;
    if (width == 0 or height == 0 or frame_bytes > display.vram_size) return error.ModeTooLarge;

    const mmio: usize = @intCast(display.mmio_phys);
    dispiWrite(mmio, .enable, enable_disabled);
    dispiWrite(mmio, .xres, @intCast(width));
    dispiWrite(mmio, .yres, @intCast(height));
    dispiWrite(mmio, .bpp, 32);
    dispiWrite(mmio, .virt_width, @intCast(width));
    dispiWrite(mmio, .virt_height, @intCast(height));
    dispiWrite(mmio, .x_offset, 0);
    dispiWrite(mmio, .y_offset, 0);
    dispiWrite(mmio, .enable, enable_enabled | enable_lfb | enable_noclearmem);

    const got_w = dispiRead(mmio, .xres);
    const got_h = dispiRead(mmio, .yres);
    const got_bpp = dispiRead(mmio, .bpp);
    const virt = dispiRead(mmio, .virt_width);
    if (got_w != width or got_h != height or got_bpp != 32) {
        display.refusals += 1;
        display.last_reason = "device refused the mode";
        return error.ModeRefused;
    }
    display.width = got_w;
    display.height = got_h;
    display.bpp = 32;
    display.stride = @as(u32, if (virt >= width) virt else got_w) * 4;
    display.mode_sets += 1;
    return display.stride;
}

/// Map the visible part of VRAM into the kernel's address space and hand it to
/// the framebuffer core.
fn publishSurface() !void {
    const visible = @as(u64, display.stride) * display.height;
    const page_size: u64 = mmu.page_size;
    const map_bytes = (visible + page_size - 1) & ~(page_size - 1);
    if (map_bytes == 0 or map_bytes > display.vram_size) return error.ModeTooLarge;

    mmu.mapRegion(.{
        .base = @intCast(display.vram_phys),
        .size = @intCast(map_bytes),
        .kind = .normal_nc,
    });
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();
    display.mapped_bytes = map_bytes;

    const base: [*]u8 = @ptrFromInt(display.vram_phys);
    const surface = fb.install(.{
        .width = display.width,
        .height = display.height,
        .stride = display.stride,
        .format = .bgrx8888,
        .phys = display.vram_phys,
        .size = map_bytes,
    }, base);
    surface.clear(fb.Palette.background);
    if (!surface.verifyReadback()) {
        fb.uninstall();
        return error.ReadbackFailed;
    }
}

pub fn probe(dev: *driver.Device) driver.ProbeError!void {
    const bars = display_mode.classifyBars(dev);
    if (!bars.ok) {
        display.last_reason = "framebuffer BAR or MMIO BAR missing";
        return error.NoRegion;
    }
    const vram = bars.vram;
    const vram_size = bars.vram_size;
    const mmio = bars.mmio;

    // An all-ones read is what an unclaimed BAR returns, and it must not pass
    // for an interface id: require a real VBE id in the supported range.
    const id = dispiRead(@intCast(mmio), .id);
    if (id < 0xb0c0 or id > 0xb0c5) {
        display.last_reason = "dispi interface did not answer";
        return error.Unsupported;
    }

    // The QEMU extension register says which byte order the scanout uses. A
    // big-endian panel is refused rather than drawn with swapped channels.
    if (mmio32(@intCast(mmio), qext_byteorder).* == 0xbebebebe) {
        display.last_reason = "big-endian scanout is not supported";
        return error.Unsupported;
    }
    _ = qext_little_endian;

    display.vram_phys = vram;
    display.vram_size = vram_size;
    display.mmio_phys = mmio;
    display.dispi_id = id;
    display.vram_64k = dispiRead(@intCast(mmio), .video_memory_64k);
    display.present = true;

    const panel = readEdid(mmio);
    if (panel) |p| {
        display.edid_ok = true;
        display.edid_manufacturer = p.manufacturer;
        display.edid_year = p.year;
        display.edid_name = p.name;
        display.edid_name_len = p.name_len;
        if (p.bestTiming()) |t| display.preferred_refresh_hz = t.refreshHz();
        klog.info("fb", "edid: {s} '{s}' {d}, {d}x{d} preferred, {d} Hz", .{
            &p.manufacturer,
            p.nameSlice(),
            p.year,
            if (p.bestTiming()) |t| t.hactive else 0,
            if (p.bestTiming()) |t| t.vactive else 0,
            display.preferred_refresh_hz,
        });
    } else {
        display.fallbacks += 1;
        klog.warn("fb", "no readable EDID: header {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}, checksum {x:0>2}", .{
            readByte(mmio, 0), readByte(mmio, 1), readByte(mmio, 2), readByte(mmio, 3),
            readByte(mmio, 4), readByte(mmio, 5), readByte(mmio, 6), readByte(mmio, 7),
            readByte(mmio, edid.block_size - 1),
        });
    }

    const choice = display_mode.choose(panel, vram_size);
    if (choice.fell_back) {
        display.fallbacks += 1;
        klog.warn("fb", "the panel's preferred timing does not fit {d} KiB of VRAM: using {d}x{d}", .{
            vram_size / 1024, choice.width, choice.height,
        });
    }
    const stride = programMode(choice.width, choice.height) catch |err| {
        display.last_reason = switch (err) {
            error.ModeTooLarge => "mode does not fit VRAM",
            error.ModeRefused => "device refused the mode",
            else => "mode programming failed",
        };
        display.present = false;
        return error.Unsupported;
    };

    publishSurface() catch |err| {
        display.last_reason = switch (err) {
            error.ReadbackFailed => "framebuffer readback failed",
            error.ModeTooLarge => "framebuffer does not fit the mapping",
        };
        display.present = false;
        return error.NoMemory;
    };

    display.last_reason = "ok";
    klog.info("fb", "bochs-display {d}x{d}x{d}, stride {d}, vram {d} KiB, dispi 0x{x}", .{
        display.width, display.height, display.bpp, stride, display.vram_size / 1024, id,
    });
}

/// Shell-driven mode change: the same path a future display-settings UI uses.
pub fn setMode(width: u32, height: u32) !void {
    if (!display.present) return error.NoDisplay;
    if (fb.screen()) |surface| surface.clear(fb.Palette.black);
    const stride = try programMode(width, height);
    _ = stride;
    try publishSurface();
    // The surface is fresh; leave it blank so the caller decides what to draw
    // (the shell prints the new mode, the UI would lay itself out again).
    if (fb.screen()) |surface| surface.clear(fb.Palette.black);
}

pub fn remove(_: *driver.Device) void {
    fb.uninstall();
    if (display.present) {
        const mmio: usize = @intCast(display.mmio_phys);
        dispiWrite(mmio, .enable, enable_disabled);
    }
    display.present = false;
    display.last_reason = "removed";
}

pub fn describe(write: anytype) void {
    if (!display.present) {
        write("  display      : none ({s})\n", .{display.last_reason});
        return;
    }
    write("  display      : bochs-display, dispi 0x{x}, vram {d} KiB ({d} x 64 KiB)\n", .{
        display.dispi_id, display.vram_size / 1024, display.vram_64k,
    });
    write("  mode         : {d}x{d}x{d}, stride {d}, {d} KiB mapped\n", .{
        display.width, display.height, display.bpp, display.stride, display.mapped_bytes / 1024,
    });
    if (display.edid_ok) {
        write("  edid         : {s} '{s}' {d}, {d} Hz preferred\n", .{
            &display.edid_manufacturer,
            display.edid_name[0..display.edid_name_len],
            display.edid_year,
            display.preferred_refresh_hz,
        });
    } else {
        write("  edid         : absent, default mode used\n", .{});
    }
    write("  mode changes : {d} ({d} fallback(s), {d} refusal(s))\n", .{
        display.mode_sets, display.fallbacks, display.refusals,
    });
}
