//! AArch64 MMU: 4 KiB granule, 48-bit virtual addresses, identity mapping
//! during bring-up, W^X for the kernel image and correct device attributes.
//!
//! Phase 9 of the plan. The page tables live in a static pool inside .bss, so
//! no allocator is needed to turn the MMU on — a deliberate chicken-and-egg
//! ordering constraint.

const std = @import("std");
const cpu = @import("cpu.zig");
const klog = @import("../../kernel/klog.zig");
const symbols = @import("../../kernel/symbols.zig");

pub const page_size: usize = 4096;
pub const block_size: usize = 2 * 1024 * 1024;

const entries = 512;
const max_tables = 40;
const addr_mask: u64 = 0x0000_FFFF_FFFF_F000;

pub const Kind = enum { device, normal, normal_nc };

/// A physically contiguous region to identity-map.
pub const Region = struct {
    base: usize,
    size: usize,
    kind: Kind,
    exec: bool = false,
    read_only: bool = false,
};

var tables: [max_tables][entries]u64 align(page_size) = undefined;
var tables_used: usize = 0;
var root: *[entries]u64 = undefined;

// ---------------------------------------------------------------------------
// Descriptor construction
// ---------------------------------------------------------------------------

const AF: u64 = 1 << 10; // access flag
const SH_INNER: u64 = 0b11 << 8; // inner shareable
const AP_RO: u64 = 1 << 7; // read-only at EL1
const PXN: u64 = 1 << 53; // privileged execute-never
const UXN: u64 = 1 << 54; // unprivileged execute-never

fn attrIndex(kind: Kind) u64 {
    return switch (kind) {
        .device => 0,
        .normal => 1,
        .normal_nc => 2,
    };
}

fn attrs(kind: Kind, exec: bool, read_only: bool) u64 {
    var a: u64 = attrIndex(kind) << 2;
    a |= AF;
    if (kind != .device) a |= SH_INNER;
    if (read_only) a |= AP_RO;
    if (!exec) a |= PXN | UXN;
    return a;
}

fn l0Index(va: usize) usize {
    return (va >> 39) & (entries - 1);
}

fn tableIndex(va: usize) usize {
    return (va >> 12) & (entries - 1);
}

fn l2Index(va: usize) usize {
    return (va >> 21) & (entries - 1);
}

fn l1Index(va: usize) usize {
    return (va >> 30) & (entries - 1);
}

fn allocTable() *[entries]u64 {
    if (tables_used >= max_tables) @panic("mmu: page-table pool exhausted");
    const t = &tables[tables_used];
    tables_used += 1;
    @memset(t, 0);
    return t;
}

fn asTable(entry: u64) *[entries]u64 {
    return @ptrFromInt(entry & addr_mask);
}

fn ensureL2(va: usize) *[entries]u64 {
    const l0e = &root[l0Index(va)];
    if (l0e.* & 0b11 != 0b11) {
        const t = allocTable();
        l0e.* = @intFromPtr(t) | 0b11;
    }
    const l1 = asTable(l0e.*);
    const l1e = &l1[l1Index(va)];
    if (l1e.* & 0b11 != 0b11) {
        const t = allocTable();
        l1e.* = @intFromPtr(t) | 0b11;
    }
    return asTable(l1e.*);
}

fn ensureL3(va: usize) *[entries]u64 {
    const l2 = ensureL2(va);
    const e = &l2[l2Index(va)];
    switch (e.* & 0b11) {
        0b01 => {
            // Split a 2 MiB block into 4 KiB pages, preserving attributes.
            const block = e.*;
            const base = block & addr_mask;
            const low_attrs = block & 0xFFF;
            const t = allocTable();
            for (0..entries) |i| {
                t[i] = (base + i * page_size) | low_attrs | 0b11;
            }
            e.* = @intFromPtr(t) | 0b11;
        },
        0b11 => {},
        else => {
            const t = allocTable();
            e.* = @intFromPtr(t) | 0b11;
        },
    }
    return asTable(e.*);
}

// ---------------------------------------------------------------------------
// Public mapping API
// ---------------------------------------------------------------------------

fn mapRangePa(va_base: usize, pa_base: usize, size: usize, r: Region) void {
    const a = attrs(r.kind, r.exec, r.read_only);
    var off: usize = 0;
    while (off < size) {
        const va = va_base + off;
        const pa = pa_base + off;
        const remaining = size - off;
        if (va % block_size == 0 and pa % block_size == 0 and remaining >= block_size) {
            const l2 = ensureL2(va);
            l2[l2Index(va)] = (pa & addr_mask) | a | 0b01;
            off += block_size;
        } else {
            const l3 = ensureL3(va);
            l3[tableIndex(va)] = (pa & addr_mask) | a | 0b11;
            off += page_size;
        }
    }
}

pub fn mapRegion(r: Region) void {
    mapRangePa(r.base, r.base, r.size, r);
}

/// Map one 4 KiB page (used later by user-space and MMIO windows).
pub fn mapPage(va: usize, pa: usize, kind: Kind, exec: bool, read_only: bool) void {
    const l3 = ensureL3(va);
    l3[tableIndex(va)] = (pa & addr_mask) | attrs(kind, exec, read_only) | 0b11;
}

pub fn unmapPage(va: usize) void {
    const l3 = ensureL3(va);
    l3[tableIndex(va)] = 0;
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();
}

/// Walk the tables and translate a virtual address, for fault diagnostics.
pub fn translate(va: usize) ?usize {
    const l0e = root[l0Index(va)];
    if (l0e & 0b11 != 0b11) return null;
    const l1e = asTable(l0e)[l1Index(va)];
    if (l1e & 0b11 == 0) return null;
    if (l1e & 0b11 == 0b01) return (l1e & addr_mask) | (va & 0x3FFF_FFFF);
    const l2e = asTable(l1e)[l2Index(va)];
    if (l2e & 0b11 == 0) return null;
    if (l2e & 0b11 == 0b01) return (l2e & addr_mask) | (va & 0x1F_FFFF);
    const l3e = asTable(l2e)[tableIndex(va)];
    if (l3e & 0b11 == 0) return null;
    return (l3e & addr_mask) | (va & 0xFFF);
}

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

/// Build an identity map for the discovered memory map plus the kernel's W^X
/// permissions, then flip the MMU on with caches enabled.
pub fn init(regions: []const Region) void {
    root = allocTable();

    for (regions) |r| {
        if (r.size == 0) continue;
        mapRegion(r);
    }

    // Re-map the kernel image with least privilege: text RX, rodata R,
    // data/bss RW. All of it is identity mapped and non-executable except
    // the text segment.
    const text_start = @intFromPtr(&symbols.__text_start);
    const text_end = @intFromPtr(&symbols.__text_end);
    const rodata_end = @intFromPtr(&symbols.__rodata_end);
    const data_end = @intFromPtr(&symbols.__data_end);

    mapRangePa(text_start, text_start, text_end - text_start, .{
        .base = text_start,
        .size = text_end - text_start,
        .kind = .normal,
        .exec = true,
        .read_only = true,
    });
    if (rodata_end > text_end) {
        mapRangePa(text_end, text_end, rodata_end - text_end, .{
            .base = text_end,
            .size = rodata_end - text_end,
            .kind = .normal,
            .exec = false,
            .read_only = true,
        });
    }
    _ = data_end; // data/bss keep the default RW, non-executable mapping

    klog.debug("mmu", "page tables built: {d} tables, {d} KiB", .{ tables_used, tables_used * 4 });
}

pub fn enable() void {
    // MAIR: 0 = Device-nGnRnE, 1 = Normal WB/WA, 2 = Normal non-cacheable.
    const mair: u64 = 0x00 | (0xFF << 8) | (0x44 << 16);
    cpu.sysWrite("mair_el1", mair);

    // 48-bit VA, 4 KiB granule, inner-shareable WB walks, 40-bit PA.
    // T0SZ = 16 selects a 48-bit VA space, which makes the walk start at L0 and
    // exactly matches the four-level tree built above.
    const tcr: u64 = 16 | // T0SZ
        (0 << 7) | // EPD0
        (1 << 8) | // IRGN0 = WB/WA
        (1 << 10) | // ORGN0 = WB/WA
        (3 << 12) | // SH0 = inner shareable
        (0 << 14) | // TG0 = 4 KiB
        (16 << 16) | // T1SZ
        (1 << 23) | // EPD1: TTBR1 disabled while the kernel is identity mapped
        (2 << 32); // IPS = 40-bit physical addresses
    cpu.sysWrite("tcr_el1", tcr);
    cpu.sysWrite("ttbr0_el1", @intFromPtr(root));
    cpu.sysWrite("ttbr1_el1", 0);

    cpu.dsbSy();
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();

    var sctlr = cpu.sysRead("sctlr_el1");
    sctlr |= (1 << 0) | // M: MMU enable
        (1 << 2) | // C: data cache
        (1 << 12) | // I: instruction cache
        (1 << 19); // WXN: writable implies never-executable
    sctlr &= ~@as(u64, 1 << 1); // no alignment checking
    cpu.sysWrite("sctlr_el1", sctlr);
    cpu.isb();

    klog.info("mmu", "enabled: 4 KiB granule, 48-bit VA, caches on, W^X on", .{});
}

test "descriptor attributes set the execute-never bits" {
    const a = attrs(.normal, false, true);
    try std.testing.expect((a & PXN) != 0);
    try std.testing.expect((a & UXN) != 0);
    try std.testing.expect((a & AP_RO) != 0);
    const code = attrs(.normal, true, true);
    try std.testing.expect((code & PXN) == 0);
    try std.testing.expect((code & AF) != 0);
}

test "index helpers follow the 48-bit level layout" {
    try std.testing.expectEqual(@as(usize, 0), l0Index(0x4008_0000));
    try std.testing.expectEqual(@as(usize, 1), l1Index(0x4008_0000));
    try std.testing.expectEqual(@as(usize, 1), l1Index(0x4000_0000));
    try std.testing.expectEqual(@as(usize, 0), l2Index(0x4008_0000));
    try std.testing.expectEqual(@as(usize, 8), l2Index(0x4100_0000));
    try std.testing.expectEqual(@as(usize, 0x80), tableIndex(0x4008_0000));
    try std.testing.expectEqual(@as(usize, 0x9C), tableIndex(0x4009_c438));
}
