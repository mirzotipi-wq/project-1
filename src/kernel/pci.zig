//! PCIe host bridge (phase 32): the terminal's internal buses.
//!
//! QEMU's `virt` machine exposes a `pci-host-ecam-generic` root complex: a flat
//! 256 MiB window of memory-mapped configuration space, one bus range, and a
//! device tree that says where the windows are and how a legacy interrupt pin
//! becomes an interrupt-controller line. This module turns that description into
//! a bus the rest of the kernel can use, and turns every function it finds into
//! a **device object** in the phase-31 driver model, so a PCI function is not
//! hidden inside the bridge driver: it appears in `devices`, can be bound by a
//! driver that claims it, and is counted with everything else.
//!
//! Nothing here assumes a vendor, a device id, a BAR layout or a slot number.
//! The only fixed knowledge is the PCI/PCIe register layout itself.
//!
//! Honest limits, by design rather than omission:
//!
//!   * The walk covers the root complex's `bus-range`. Bridges downstream of it
//!     are seen as devices (class 0x0604) but their secondary buses are not
//!     walked yet: that needs a resource tree and is later phase work.
//!   * BAR assignment has no allocator: functions are packed into the host
//!     bridge's windows in discovery order, which is enough for a flat
//!     single-bus machine and will need a real resource tree once bridges and
//!     hotplug exist.
//!   * MSI is programmed through the GICv2m frame, which is what `virt` provides
//!     with GICv2. When the machine has an ITS instead, that is detected and
//!     reported as "present, not programmed": an ITS needs ITS commands, LPI
//!     tables and device tables, and pretending otherwise would be a lie. The
//!     INTx path is used then.
//!   * MSI vectors are allocated from the frame's SPI range with no free-list.

const std = @import("std");
const fdt = @import("../lib/fdt.zig");
const machine_mod = @import("machine.zig");
const klog = @import("klog.zig");
const driver = @import("driver.zig");
const gic = @import("../arch/aarch64/gic.zig");

pub const max_functions = 24;
pub const max_bars = 6;

/// Vendor id every absent function reads back as.
pub const no_vendor: u16 = 0xFFFF;

pub const BarKind = enum { absent, mem32, mem64, io };

pub const Bar = struct {
    kind: BarKind = .absent,
    size: u64 = 0,
    /// Where the kernel put it. Zero until assigned.
    assigned: u64 = 0,
};

pub const Function = struct {
    bus: u8 = 0,
    dev: u8 = 0,
    func: u8 = 0,
    vendor: u16 = 0,
    device: u16 = 0,
    /// Class code, subclass and programming interface as one 24-bit value.
    class_code: u32 = 0,
    header_type: u8 = 0,
    bars: [max_bars]Bar = [_]Bar{.{}} ** max_bars,
    /// Capability-list offsets, when present.
    msi_off: ?u16 = null,
    msix_off: ?u16 = null,
    pcie_off: ?u16 = null,
    /// Legacy interrupt pin (1..4) and the SPI the platform maps it to.
    intx_pin: u8 = 0,
    intx_spi: u32 = 0,
    intx_routed: bool = false,
    /// MSI: the vector allocated and whether the capability was enabled.
    msi_vector: u32 = 0,
    msi_on: bool = false,
};

/// What the platform can do about message-signalled interrupts.
pub const MsiKind = enum {
    none,
    /// GICv2m frame: a doorbell register that raises an SPI. Programmable here.
    v2m,
    /// GICv3 ITS: present, but programming it needs ITS commands, LPI tables and
    /// device tables. Detected, reported, not used.
    its,
};

pub const Root = struct {
    ecam: u64 = 0,
    ecam_len: u64 = 0,
    /// MMIO window function BARs are placed in.
    mmio: u64 = 0,
    mmio_len: u64 = 0,
    io: u64 = 0,
    io_len: u64 = 0,
    bus_first: u8 = 0,
    bus_last: u8 = 0xFF,
    /// `interrupt-map` / `interrupt-map-mask`, pointing into the device tree.
    imap: []const u8 = &.{},
    imask: [4]u32 = .{ 0, 0, 0, 0 },
    msi: MsiKind = .none,
    msi_base: u64 = 0,
    msi_spi_base: u32 = 0,
    msi_spi_count: u32 = 0,
    /// MSI vectors handed out so far.
    msi_used: u32 = 0,
    /// Functions whose MSI/MSI-X vector this kernel programmed.
    msi_functions: usize = 0,
    /// Functions that advertised MSI/MSI-X but are delivered by INTx instead.
    msi_fallbacks: usize = 0,
    /// BAR allocation cursor inside the MMIO window.
    mmio_next: u64 = 0,
};

// ---------------------------------------------------------------------------
// Configuration space
// ---------------------------------------------------------------------------

fn ecamAddress(root: *const Root, bus: u8, dev: u8, func: u8, off: u16) usize {
    // ECAM: one 4 KiB page per function, bus in bits 20..27, device in 15..19,
    // function in 12..14. That layout is why a 256-bus window is 256 MiB.
    const addr = root.ecam +
        (@as(u64, bus) << 20) +
        (@as(u64, dev) << 15) +
        (@as(u64, func) << 12) +
        @as(u64, off & 0xFFC);
    return @intCast(addr);
}

pub fn read32(root: *const Root, bus: u8, dev: u8, func: u8, off: u16) u32 {
    const p: *volatile u32 = @ptrFromInt(ecamAddress(root, bus, dev, func, off));
    return p.*;
}

fn write32(root: *const Root, bus: u8, dev: u8, func: u8, off: u16, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(ecamAddress(root, bus, dev, func, off));
    p.* = value;
}

/// Write a 16-bit register that may not be word-aligned by rebuilding its word:
/// configuration space is only reliably accessible as aligned 32-bit accesses.
fn write16(root: *const Root, bus: u8, dev: u8, func: u8, off: u16, value: u16) void {
    const word_off = off & 0xFFFC;
    const shift: u5 = @intCast((off & 3) * 8);
    const mask: u32 = @as(u32, 0xFFFF) << shift;
    var word = read32(root, bus, dev, func, word_off);
    word = (word & ~mask) | ((@as(u32, value) << shift) & mask);
    write32(root, bus, dev, func, word_off, word);
}

fn read16(root: *const Root, bus: u8, dev: u8, func: u8, off: u16) u16 {
    const word = read32(root, bus, dev, func, off & 0xFFFC);
    const shift: u5 = @intCast((off & 3) * 8);
    return @truncate(word >> shift);
}

fn read8At(root: *const Root, bus: u8, dev: u8, func: u8, off: u16) u8 {
    const word = read32(root, bus, dev, func, off & 0xFFFC);
    const shift: u5 = @intCast((off & 3) * 8);
    return @truncate(word >> shift);
}

// ---------------------------------------------------------------------------
// Device tree description of the bridge
// ---------------------------------------------------------------------------

/// A window declared by `ranges`: PCI side, CPU side, size.
pub const Window = struct {
    flags: u32,
    pci: u64,
    cpu: u64,
    size: u64,

    pub fn isIo(self: Window) bool {
        return (self.flags & 0x0300_0000) == 0x0100_0000;
    }
    pub fn isPrefetchable(self: Window) bool {
        return (self.flags & 0x4300_0000) == 0x4200_0000;
    }
};

/// Decode `ranges` without being told the parent's address-cell count.
///
/// The node's own `#address-cells`/`#size-cells` give the PCI side; the parent's
/// cell count is not stored on this node, and QEMU's `virt` root uses one cell
/// while other trees use two. Rather than guess, every plausible parent width is
/// tried and accepted only when it divides the property exactly. Ambiguity is an
/// error, not a coin flip.
pub fn parseRanges(raw: []const u8, child_cells: usize, size_cells: usize, out: []Window) ?[]Window {
    if (raw.len == 0 or raw.len % 4 != 0) return null;
    const words = raw.len / 4;
    const candidates = [_]usize{ 1, 2, 0 };
    var chosen: ?usize = null;
    for (candidates) |parent_cells| {
        const entry = 1 + child_cells + parent_cells + size_cells;
        if (entry == 0 or words % entry != 0) continue;
        if (chosen != null) return null; // ambiguous: refuse
        chosen = parent_cells;
    }
    const parent_cells = chosen orelse return null;
    const entry = 1 + child_cells + parent_cells + size_cells;
    const count = @min(words / entry, out.len);

    var produced: usize = 0;
    for (0..count) |i| {
        const base = i * entry;
        const flags = std.mem.readInt(u32, raw[base * 4 ..][0..4], .big);
        var pci: u64 = 0;
        for (0..child_cells) |c| {
            pci = (pci << 32) | std.mem.readInt(u32, raw[(base + 1 + c) * 4 ..][0..4], .big);
        }
        var cpu: u64 = 0;
        for (0..parent_cells) |c| {
            cpu = (cpu << 32) | std.mem.readInt(u32, raw[(base + 1 + child_cells + c) * 4 ..][0..4], .big);
        }
        var size: u64 = 0;
        for (0..size_cells) |c| {
            size = (size << 32) | std.mem.readInt(u32, raw[(base + 1 + child_cells + parent_cells + c) * 4 ..][0..4], .big);
        }
        if (size == 0) continue;
        out[produced] = .{ .flags = flags, .pci = pci, .cpu = cpu, .size = size };
        produced += 1;
    }
    if (produced == 0) return null;
    return out[0..produced];
}

/// The platform's MSI controller, from the tree. A GICv2m frame is programmable
/// here; an ITS is detected and reported but not driven yet.
fn findMsi(tree: fdt.Fdt) struct { kind: MsiKind, base: u64, spi_base: u32, spi_count: u32 } {
    if (tree.findByCompatible("arm,gic-v2m-frame")) |node| {
        var regs: [4]fdt.Reg = undefined;
        const found = tree.regs(node, &regs);
        const base = if (found.len > 0) found[0].base else 0;
        var spi_base: u32 = 0;
        var spi_count: u32 = 0;
        if (tree.prop(node, "arm,msi-base-spi")) |raw| {
            if (raw.len >= 4) spi_base = std.mem.readInt(u32, raw[0..4], .big);
        }
        if (tree.prop(node, "arm,msi-num-spis")) |raw| {
            if (raw.len >= 4) spi_count = std.mem.readInt(u32, raw[0..4], .big);
        }
        // QEMU's virt omits these on its single frame; the PCI binding's default
        // for a frame is SPI 32..63, which is what the machine actually routes.
        if (spi_count == 0) {
            spi_base = 32;
            spi_count = 32;
        }
        return .{ .kind = .v2m, .base = base, .spi_base = spi_base, .spi_count = spi_count };
    }
    if (tree.findByCompatible("arm,gic-v3-its") != null) {
        return .{ .kind = .its, .base = 0, .spi_base = 0, .spi_count = 0 };
    }
    return .{ .kind = .none, .base = 0, .spi_base = 0, .spi_count = 0 };
}

/// Read the bridge's description out of the machine's device tree.
pub fn parseRoot(m: *const machine_mod.Machine, dev: *const driver.Device) driver.ProbeError!Root {
    if (dev.reg_count == 0) return error.NoRegion;
    if (!m.fdt_valid or m.dtb == 0) return error.Unsupported;
    const bytes: [*]const u8 = @ptrFromInt(m.dtb);
    const tree = fdt.Fdt.init(bytes[0..m.dtb_size]) catch return error.Unsupported;
    const node: fdt.Node = .{ .off = dev.node_off };

    var root = Root{ .ecam = dev.regs[0].base, .ecam_len = dev.regs[0].size };

    if (tree.prop(node, "bus-range")) |raw| {
        if (raw.len >= 8) {
            root.bus_first = @truncate(std.mem.readInt(u32, raw[0..4], .big));
            root.bus_last = @truncate(std.mem.readInt(u32, raw[4..8], .big));
        }
    }

    var child_cells: usize = 3;
    var size_cells: usize = 2;
    if (tree.prop(node, "#address-cells")) |raw| {
        if (raw.len >= 4) child_cells = std.mem.readInt(u32, raw[0..4], .big);
    }
    if (tree.prop(node, "#size-cells")) |raw| {
        if (raw.len >= 4) size_cells = std.mem.readInt(u32, raw[0..4], .big);
    }
    var windows: [8]Window = undefined;
    if (tree.prop(node, "ranges")) |raw| {
        if (parseRanges(raw, child_cells, size_cells, &windows)) |list| {
            for (list) |w| {
                if (w.isIo()) {
                    root.io = w.cpu;
                    root.io_len = w.size;
                } else if (w.cpu != 0 and w.size > root.mmio_len) {
                    root.mmio = w.cpu;
                    root.mmio_len = w.size;
                }
            }
        }
    }
    if (root.mmio_len == 0) return error.NoRegion;
    root.mmio_next = root.mmio;

    if (tree.prop(node, "interrupt-map-mask")) |raw| {
        const n = @min(raw.len / 4, root.imask.len);
        for (0..n) |i| root.imask[i] = std.mem.readInt(u32, raw[i * 4 ..][0..4], .big);
    }
    if (tree.prop(node, "interrupt-map")) |raw| root.imap = raw;

    const msi = findMsi(tree);
    root.msi = msi.kind;
    root.msi_base = msi.base;
    root.msi_spi_base = msi.spi_base;
    root.msi_spi_count = msi.spi_count;
    return root;
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

fn write32Abs(addr: u64, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(@as(usize, @intCast(addr)));
    p.* = value;
}

fn read32Abs(addr: u64) u32 {
    const p: *volatile u32 = @ptrFromInt(@as(usize, @intCast(addr)));
    return p.*;
}

fn findCaps(root: *const Root, f: *Function) void {
    const status = read16(root, f.bus, f.dev, f.func, 0x06);
    if (status & (1 << 4) == 0) return; // no capability list
    var off: u16 = @as(u16, read8At(root, f.bus, f.dev, f.func, 0x34)) & 0xFC;
    var guard: usize = 0;
    while (off >= 0x40 and off < 0x100 and guard < 48) : (guard += 1) {
        const word = read32(root, f.bus, f.dev, f.func, off);
        const id: u8 = @truncate(word);
        switch (id) {
            0x05 => f.msi_off = off,
            0x10 => f.pcie_off = off,
            0x11 => f.msix_off = off,
            else => {},
        }
        const next: u8 = @truncate(word >> 8);
        if (next == 0 or next == off) break;
        off = @as(u16, next) & 0xFC;
    }
}

/// Size one BAR by writing all ones and reading the mask back. The register is
/// restored exactly as it was found, so this is safe to run on a live bus.
///
/// An unassigned 32-bit memory BAR reads back zero, which is the same value an
/// unimplemented BAR reads: only the all-ones write tells them apart. That is
/// why there is no early return on a zero register.
fn sizeBar(root: *const Root, f: *Function, index: usize) Bar {
    const off: u16 = @intCast(0x10 + index * 4);
    const original = read32(root, f.bus, f.dev, f.func, off);

    write32(root, f.bus, f.dev, f.func, off, 0xFFFF_FFFF);
    const mask = read32(root, f.bus, f.dev, f.func, off);
    write32(root, f.bus, f.dev, f.func, off, original);

    // No bits respond: nothing behind this slot.
    if (mask == 0 or mask == 0xFFFF_FFFF) return .{};

    const kind: BarKind = if (mask & 1 != 0)
        .io
    else if ((mask & 0x6) == 0x4)
        .mem64
    else
        .mem32;

    var size_hi: u32 = 0;
    if (kind == .mem64 and index + 1 < max_bars) {
        const next_off: u16 = @intCast(off + 4);
        const next_original = read32(root, f.bus, f.dev, f.func, next_off);
        write32(root, f.bus, f.dev, f.func, next_off, 0xFFFF_FFFF);
        size_hi = read32(root, f.bus, f.dev, f.func, next_off);
        write32(root, f.bus, f.dev, f.func, next_off, next_original);
    }

    const size = barSizeFromMask(mask, size_hi);
    if (size == 0) return .{};
    return .{ .kind = kind, .size = size };
}

/// A BAR's size is the inverted mask plus one. Pure, so the decode is host-tested
/// against the values QEMU's devices actually report.
pub fn barSizeFromMask(lo: u32, hi: u32) u64 {
    if (hi == 0) {
        // 32-bit BAR: complement inside 32 bits, or the high half of the u64
        // turns into ones and every size looks unmappable.
        const mask: u32 = lo & 0xFFFF_FFF0;
        if (mask == 0) return 0;
        return @as(u64, (~mask) +% 1);
    }
    const mask: u64 = (@as(u64, hi) << 32) | @as(u64, lo & 0xFFFF_FFF0);
    return (~mask) +% 1;
}

fn scanFunction(root: *const Root, bus: u8, dev: u8, func: u8) Function {
    var f = Function{ .bus = bus, .dev = dev, .func = func };
    const id = read32(root, bus, dev, func, 0x00);
    f.vendor = @truncate(id);
    f.device = @truncate(id >> 16);
    f.class_code = read32(root, bus, dev, func, 0x08) >> 8;
    f.header_type = read8At(root, bus, dev, func, 0x0E);
    f.intx_pin = read8At(root, bus, dev, func, 0x3D) & 0x07;
    findCaps(root, &f);
    // A type-0 header carries six BARs. A bridge has two and its own window
    // registers; only the endpoint layout is sized here.
    if ((f.header_type & 0x7F) == 0) {
        var i: usize = 0;
        while (i < max_bars) : (i += 1) {
            f.bars[i] = sizeBar(root, &f, i);
            if (f.bars[i].kind == .mem64 and i + 1 < max_bars) i += 1;
        }
    }
    return f;
}

/// Walk the root complex's bus range. Every present function is appended; the
/// count is returned, and `out.len` bounds it honestly.
pub fn walk(root: *const Root, out: []Function) usize {
    var n: usize = 0;
    var bus: u16 = root.bus_first;
    while (bus <= root.bus_last and n < out.len) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32 and n < out.len) : (dev += 1) {
            if (read16(root, @truncate(bus), dev, 0, 0x00) == no_vendor) continue;
            out[n] = scanFunction(root, @truncate(bus), dev, 0);
            n += 1;
            // Header type bit 7 means the device has more than one function.
            const multifunction = out[n - 1].header_type & 0x80 != 0;
            var func: u8 = 1;
            while (multifunction and func < 8 and n < out.len) : (func += 1) {
                if (read16(root, @truncate(bus), dev, func, 0x00) == no_vendor) continue;
                out[n] = scanFunction(root, @truncate(bus), dev, func);
                n += 1;
            }
        }
    }
    return n;
}

/// Give every BAR an address inside the host bridge's windows and check the
/// device took it. A BAR that cannot be placed is left unassigned, and the
/// caller reports it instead of pretending the function is usable.
pub fn assignBars(root: *Root, functions: []Function) usize {
    var placed: usize = 0;
    for (functions) |*f| {
        for (0..max_bars) |slot| {
            const bar = &f.bars[slot];
            if (bar.kind == .absent or bar.size == 0) continue;
            const is_io = bar.kind == .io;
            const base = if (is_io) root.io else root.mmio;
            const limit = base + (if (is_io) root.io_len else root.mmio_len);
            if (base == 0 or base + bar.size > limit) {
                klog.warn("pci", "{d:0>2}:{d:0>2}.{d} BAR{d} size 0x{x} does not fit its window", .{
                    f.bus, f.dev, f.func, slot, bar.size,
                });
                continue;
            }
            var cursor = if (is_io) base else root.mmio_next;
            cursor = (cursor + bar.size - 1) & ~(bar.size - 1);
            if (cursor + bar.size > limit) {
                klog.warn("pci", "{d:0>2}:{d:0>2}.{d} BAR{d} size 0x{x} does not fit the window 0x{x}+0x{x}", .{
                    f.bus, f.dev, f.func, slot, bar.size, base, limit - base,
                });
                continue;
            }
            const reg: u16 = @intCast(0x10 + slot * 4);
            const value: u32 = if (is_io) @truncate(cursor | 1) else @truncate(cursor);
            write32(root, f.bus, f.dev, f.func, reg, value);
            const readback = read32(root, f.bus, f.dev, f.func, reg);
            const mask: u32 = if (is_io) 0xFFFF_FFFC else 0xFFFF_FFF0;
            if ((readback & mask) != (value & mask)) {
                klog.warn("pci", "{d:0>2}:{d:0>2}.{d} BAR{d} would not take 0x{x} (read back 0x{x})", .{
                    f.bus, f.dev, f.func, slot, value, readback,
                });
                continue;
            }
            bar.assigned = cursor;
            if (!is_io) root.mmio_next = cursor + bar.size;
            placed += 1;
        }
    }
    return placed;
}

// ---------------------------------------------------------------------------
// Interrupts: MSI first when the platform can, INTx otherwise
// ---------------------------------------------------------------------------

/// Resolve a legacy interrupt pin through the host bridge's `interrupt-map`.
///
/// Layout, as the PCI binding defines it: the child specifier has as many cells
/// as `interrupt-map-mask`, then the parent phandle, then the parent's specifier.
/// QEMU's `virt` tree uses four child cells and five parent cells (two address
/// cells before the controller's type/intid/flags). The number of entries is the
/// masked device groups times four pins, which is how the entry length is
/// recovered without hardcoding it.
pub fn matchInterruptMap(map: []const u8, mask: [4]u32, devfn: u8, pin: u8) ?u32 {
    if (map.len == 0 or map.len % 4 != 0) return null;
    if (pin == 0 or pin > 4) return null;
    const words = map.len / 4;
    const groups = @as(usize, 1) << @as(u5, @intCast(@popCount(mask[0])));
    const entries = groups * 4;
    if (words % entries != 0) return null;
    const entry = words / entries;
    const child_cells: usize = 4;
    if (entry <= child_cells + 1) return null;
    const parent_cells = entry - child_cells - 1;
    if (parent_cells < 3) return null;

    const dev_cell: u32 = (@as(u32, devfn) << 8) & mask[0];
    for (0..entries) |i| {
        const base = i * entry;
        const w0 = std.mem.readInt(u32, map[(base + 0) * 4 ..][0..4], .big);
        const w1 = std.mem.readInt(u32, map[(base + 1) * 4 ..][0..4], .big);
        const w2 = std.mem.readInt(u32, map[(base + 2) * 4 ..][0..4], .big);
        const w3 = std.mem.readInt(u32, map[(base + 3) * 4 ..][0..4], .big);
        if ((w0 & mask[0]) != dev_cell) continue;
        if ((w1 & mask[1]) != 0 or (w2 & mask[2]) != 0) continue;
        if ((w3 & mask[3]) != (@as(u32, pin) & mask[3])) continue;
        // The parent specifier's last three cells are type, number, flags, and
        // the number is an *index* into that type's range: an SPI 3 is GIC
        // interrupt 35, a PPI 5 is 21. Using the index as the id enables the
        // wrong line, which looks like a working route until the first
        // interrupt arrives.
        const type_at = base + child_cells + 1 + (parent_cells - 3);
        const number_at = type_at + 1;
        const kind = std.mem.readInt(u32, map[type_at * 4 ..][0..4], .big);
        const number = std.mem.readInt(u32, map[number_at * 4 ..][0..4], .big);
        return switch (kind) {
            0 => 32 + number, // SPI
            1 => 16 + number, // PPI
            else => number,
        };
    }
    return null;
}

fn routeIntx(f: *Function, root: *const Root) bool {
    if (f.intx_pin == 0 or f.intx_pin > 4) return false;
    const devfn: u8 = (f.dev << 3) | (f.func & 7);
    const spi = matchInterruptMap(root.imap, root.imask, devfn, f.intx_pin) orelse return false;
    f.intx_spi = spi;
    // A route that is not unmasked is not a route: the proof is that the
    // controller would deliver it, and the probe reads the enable bit back.
    gic.enableIrq(spi);
    f.intx_routed = gic.irqEnabled(spi);
    return f.intx_routed;
}

fn programMsi(root: *Root, f: *Function) bool {
    if (root.msi != .v2m or root.msi_used >= root.msi_spi_count) return false;
    const off = f.msi_off orelse return false;
    const spi = root.msi_spi_base + root.msi_used;
    // GICv2m: writing an SPI number to SETSPI_NSR raises it. The message address
    // a device writes to is exactly that register.
    const doorbell = root.msi_base + 0x40;
    const control = read16(root, f.bus, f.dev, f.func, off + 2);
    const is_64 = control & (1 << 7) != 0;
    write32(root, f.bus, f.dev, f.func, off + 4, @truncate(doorbell));
    if (is_64) write32(root, f.bus, f.dev, f.func, off + 8, @truncate(doorbell >> 32));
    const data_off: u16 = off + 4 + @as(u16, if (is_64) 8 else 4);
    write32(root, f.bus, f.dev, f.func, data_off, spi);
    // Enable, then read the bit back: a capability that will not latch is not a
    // working path, and the caller must fall back rather than claim success.
    write16(root, f.bus, f.dev, f.func, off + 2, control | 1);
    const after = read16(root, f.bus, f.dev, f.func, off + 2);
    if (after & 1 == 0) return false;
    // The frame raises an SPI, and an SPI that is disabled in the distributor is
    // delivered nowhere: enable it and prove it latched.
    gic.enableIrq(spi);
    if (!gic.irqEnabled(spi)) return false;
    f.msi_vector = spi;
    f.msi_on = true;
    root.msi_used += 1;
    return true;
}

/// Program one MSI-X vector. PCIe devices on this machine are modern virtio,
/// which exposes MSI-X rather than MSI, so this is the path that actually runs:
/// the table entry lives in one of the device's BARs, the vector's message is
/// the GICv2m doorbell with the allocated SPI as data, and the capability's
/// enable bit is the proof it latched.
fn programMsix(root: *Root, f: *Function) bool {
    if (root.msi != .v2m or root.msi_used >= root.msi_spi_count) return false;
    const off = f.msix_off orelse return false;
    const control = read16(root, f.bus, f.dev, f.func, off + 2);
    const table = read32(root, f.bus, f.dev, f.func, off + 4);
    const bir: usize = @intCast(table & 0x7);
    const table_off: u64 = table & 0xFFFF_FFF8;
    if (bir >= max_bars) {
        klog.warn("pci", "msi-x table BIR {d} out of range", .{bir});
        return false;
    }
    const bar = f.bars[bir];
    if (bar.kind == .absent or bar.assigned == 0) {
        klog.warn("pci", "msi-x table lives in BAR{d} (kind {s}, assigned 0x{x}) — cannot program it", .{
            bir, @tagName(bar.kind), bar.assigned,
        });
        return false;
    }

    const entry = bar.assigned + table_off;
    const spi = root.msi_spi_base + root.msi_used;
    const doorbell = root.msi_base + 0x40;
    write32Abs(entry + 0, @truncate(doorbell));
    write32Abs(entry + 4, @truncate(doorbell >> 32));
    write32Abs(entry + 8, spi);
    write32Abs(entry + 12, 0); // vector control: unmasked

    write16(root, f.bus, f.dev, f.func, off + 2, control | 0x8000);
    const after = read16(root, f.bus, f.dev, f.func, off + 2);
    if (after & 0x8000 == 0) {
        klog.warn("pci", "msi-x enable bit did not latch (control 0x{x} -> 0x{x})", .{ control, after });
        return false;
    }
    if (read32Abs(entry + 8) != spi) {
        klog.warn("pci", "msi-x table entry at 0x{x} reads back {d}, wanted {d}", .{ entry, read32Abs(entry + 8), spi });
        return false;
    }

    gic.enableIrq(spi);
    if (!gic.irqEnabled(spi)) return false;
    f.msi_vector = spi;
    f.msi_on = true;
    root.msi_used += 1;
    return true;
}

/// Does the function's interrupt path actually exist? A capability that is
/// advertised but not programmed, or a route whose line is masked, is a failure
/// the probe must report rather than a detail to discover at the till.
pub fn deliveryOk(f: *const Function) bool {
    if (f.msi_on) return (f.msi_off != null or f.msix_off != null) and f.msi_vector != 0 and gic.irqEnabled(f.msi_vector);
    if (f.intx_routed) return f.intx_pin != 0 and f.intx_spi != 0 and gic.irqEnabled(f.intx_spi);
    // Nothing claimed and nothing routed: only honest when the device has no
    // legacy pin, otherwise the route was attempted and failed.
    return f.intx_pin == 0;
}

/// Pick the delivery path for every function: MSI when the platform has a
/// programmable controller and the function has the capability, INTx otherwise.
pub fn connectInterrupts(root: *Root, functions: []Function) void {
    for (functions) |*f| {
        if (programMsi(root, f) or programMsix(root, f)) {
            root.msi_functions += 1;
            continue;
        }
        if ((f.msi_off != null or f.msix_off != null) and f.intx_pin != 0) {
            root.msi_fallbacks += 1;
        }
        _ = routeIntx(f, root);
    }
}

// ---------------------------------------------------------------------------
// Publishing the bus into the driver model
// ---------------------------------------------------------------------------

pub const Bus = struct {
    root: Root = .{},
    functions: [max_functions]Function = [_]Function{.{}} ** max_functions,
    count: usize = 0,
    published: usize = 0,
    bars_placed: usize = 0,
    /// Names and compatible strings live here: the device model keeps slices.
    names: [max_functions][12]u8 = std.mem.zeroes([max_functions][12]u8),
    compats: [max_functions][18]u8 = std.mem.zeroes([max_functions][18]u8),
};

var g_bus: Bus = .{};

pub fn current() *Bus {
    return &g_bus;
}

pub fn classLabel(class_code: u32) []const u8 {
    const base = (class_code >> 16) & 0xFF;
    return switch (base) {
        0x00 => "unclassified",
        0x01 => "mass storage",
        0x02 => "network",
        0x03 => "display",
        0x04 => "multimedia",
        0x05 => "memory",
        0x06 => "bridge",
        0x07 => "communication",
        0x08 => "system",
        0x09 => "input",
        0x0A => "docking",
        0x0B => "processor",
        0x0C => "serial bus",
        0x0D => "wireless",
        0x0E => "intelligent I/O",
        0x0F => "satellite",
        0x10 => "encryption",
        0x11 => "signal processing",
        else => "other",
    };
}

/// Publish every function as a device the model owns. The bridge driver is not
/// hiding them: they are unbound and listed like any other device waiting for a
/// driver, which is what the virtio transport phase binds.
pub fn publishAll(devices: []Function) usize {
    var made: usize = 0;
    for (devices) |*f| {
        if (made >= max_functions) break;
        const name = std.fmt.bufPrint(&g_bus.names[made], "pci{d}:{d:0>2}.{d}", .{ f.bus, f.dev, f.func }) catch continue;
        const compat = std.fmt.bufPrint(&g_bus.compats[made], "pci,{x:0>4}:{x:0>4}", .{ f.vendor, f.device }) catch continue;

        var dev = driver.Device{ .name = name, .compatible = compat, .from_tree = false, .state = .unbound };
        dev.compatibles[0] = compat;
        dev.compatible_count = 1;

        var bar_n: u8 = 0;
        for (f.bars) |bar| {
            if (bar.kind == .absent or bar.assigned == 0) continue;
            if (dev.reg_count < driver.max_regions) {
                dev.regs[dev.reg_count] = .{ .base = bar.assigned, .size = bar.size };
                dev.reg_count += 1;
            }
            if (bar_n < 6) {
                dev.pci.bars[bar_n] = bar.assigned;
                dev.pci.bar_sizes[bar_n] = bar.size;
                bar_n += 1;
            }
        }
        dev.pci.bus = f.bus;
        dev.pci.dev = f.dev;
        dev.pci.func = f.func;
        dev.pci.vendor = f.vendor;
        dev.pci.device = f.device;
        dev.pci.class_code = f.class_code;
        dev.pci.header_type = f.header_type;
        dev.pci.intx_pin = f.intx_pin;
        dev.pci.intx_spi = f.intx_spi;
        dev.pci.intx_routed = f.intx_routed;
        dev.pci.msi = f.msi_off != null;
        dev.pci.msix = f.msix_off != null;
        dev.pci.msi_vector = f.msi_vector;
        dev.pci.msi_on = f.msi_on;
        dev.pci.bar_count = bar_n;
        if (driver.publish(dev) != null) made += 1;
    }
    g_bus.published = made;
    return made;
}

/// `lspci`-equivalent: the same facts QEMU's `info pci` prints, one line per
/// function, including where the kernel placed each BAR.
pub fn printTable(write: anytype) void {
    write("  bus:dev.fn  vendor:device  class            bars                       irq\n", .{});
    for (g_bus.functions[0..g_bus.count]) |*f| {
        var bars: [96]u8 = undefined;
        var used: usize = 0;
        for (f.bars) |bar| {
            if (bar.kind == .absent) continue;
            const kind: []const u8 = switch (bar.kind) {
                .mem32, .mem64 => "mem",
                .io => "io",
                else => "?",
            };
            const text = std.fmt.bufPrint(bars[used..], "{s}{s} 0x{x}+0x{x}", .{
                if (used > 0) " " else "",
                kind,
                bar.assigned,
                bar.size,
            }) catch continue;
            used += text.len;
        }
        var irq: [24]u8 = undefined;
        const irq_text = std.fmt.bufPrint(&irq, "{s}{s}", .{
            if (f.msi_on) "msi" else "intx",
            if (f.msi_on) "" else if (f.intx_routed) " (routed)" else " (unrouted)",
        }) catch "";
        write("  {d:0>2}:{d:0>2}.{d}   {x:0>4}:{x:0>4}   {s:<16} {s:<26} {s}\n", .{
            f.bus, f.dev, f.func, f.vendor, f.device, classLabel(f.class_code), bars[0..used], irq_text,
        });
    }
    write("  {d} function(s) on {d} bus(es): {d} BAR(s) placed, MSI {s}\n", .{
        g_bus.count,
        @as(u32, g_bus.root.bus_last) - @as(u32, g_bus.root.bus_first) + 1,
        g_bus.bars_placed,
        switch (g_bus.root.msi) {
            .none => "unavailable (no GICv2m frame and no ITS)",
            .v2m => "via GICv2m",
            .its => "controller present (ITS), not programmed — INTx used",
        },
    });
}

// ---------------------------------------------------------------------------
// Tests: decoding, with no hardware in sight.
// ---------------------------------------------------------------------------

test "BAR size comes from the all-ones mask" {
    // QEMU pci-testdev: a 4 KiB memory BAR and a 256-byte I/O BAR.
    try std.testing.expectEqual(@as(u64, 0x1000), barSizeFromMask(0xFFFF_F000, 0));
    try std.testing.expectEqual(@as(u64, 0x100), barSizeFromMask(0xFFFF_FF00, 0));
    try std.testing.expectEqual(@as(u64, 0x10_0000), barSizeFromMask(0xFFF0_0000, 0));
    // A 64-bit BAR takes its high half from the next register; a 4 GiB one
    // reads back zero in the low half and ones above it.
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), barSizeFromMask(0x0000_0000, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u64, 0x1000), barSizeFromMask(0xFFFF_F000, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u64, 0), barSizeFromMask(0, 0)); // no BAR at all
}

test "ranges decode finds the windows without being told the parent width" {
    var windows: [4]Window = undefined;
    var prop: [21 * 4]u8 = undefined;
    const words = [_]u32{
        0x0100_0000, 0x0, 0x0, 0x0,      0x3eff_0000, 0x0, 0x1_0000,
        0x0200_0000, 0x0, 0x0, 0x1000_0000, 0x1000_0000, 0x0, 0x2eff_0000,
        0x0300_0000, 0x0, 0x0, 0x0,          0x0,     0x0, 0x0,
    };
    for (words, 0..) |w, i| std.mem.writeInt(u32, prop[i * 4 ..][0..4], w, .big);
    const list = parseRanges(&prop, 3, 2, &windows).?;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(list[0].isIo());
    try std.testing.expectEqual(@as(u64, 0x3eff_0000), list[0].cpu);
    try std.testing.expectEqual(@as(u64, 0x1_0000), list[0].size);
    try std.testing.expect(!list[1].isIo());
    try std.testing.expectEqual(@as(u64, 0x1000_0000), list[1].cpu);
    try std.testing.expectEqual(@as(u64, 0x2eff_0000), list[1].size);
}

test "interrupt-map maps a pin to the SPI the platform chose" {
    // The full map QEMU's virt tree emits: four masked device groups times four
    // pins, each entry four child cells, the phandle, five parent cells.
    var words: [16 * 10]u32 = undefined;
    for (0..4) |g| {
        for (0..4) |p| {
            const i = (g * 4 + p) * 10;
            words[i + 0] = @intCast(g << 11);
            words[i + 1] = 0;
            words[i + 2] = 0;
            words[i + 3] = @intCast(p + 1);
            words[i + 4] = 0x8005;
            words[i + 5] = 0; // parent address cells (the GIC has two)
            words[i + 6] = 0;
            words[i + 7] = 0; // SPI
            words[i + 8] = @intCast(g * 4 + p);
            words[i + 9] = 4;
        }
    }
    var prop: [words.len * 4]u8 = undefined;
    for (words, 0..) |w, i| std.mem.writeInt(u32, prop[i * 4 ..][0..4], w, .big);
    const mask = [4]u32{ 0x1800, 0, 0, 7 };
    // Root port (dev 0) is group 0, device 1 is group 1, device 8 wraps back to
    // group 0 — the mask only looks at two device bits.
    // An SPI index maps to the GIC id the distributor knows: 32 + index.
    try std.testing.expectEqual(@as(?u32, 32), matchInterruptMap(&prop, mask, 0, 1));
    try std.testing.expectEqual(@as(?u32, 33), matchInterruptMap(&prop, mask, 0, 2));
    try std.testing.expectEqual(@as(?u32, 36), matchInterruptMap(&prop, mask, 1 << 3, 1));
    try std.testing.expectEqual(@as(?u32, 47), matchInterruptMap(&prop, mask, 3 << 3, 4));
    try std.testing.expectEqual(@as(?u32, 32), matchInterruptMap(&prop, mask, 8 << 3, 1));
    // No pin 5 exists.
    try std.testing.expectEqual(@as(?u32, null), matchInterruptMap(&prop, mask, 1 << 3, 5));
}
