//! Machine discovery from firmware (phase 6).
//!
//! Everything the kernel needs to know about the board comes from the device
//! tree. When no tree is passed (a bootloader that only loads a flat image),
//! conservative defaults for the QEMU `virt` machine are used so the kernel
//! still comes up and says what it assumed.

const std = @import("std");
const fdt = @import("../lib/fdt.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const klog = @import("klog.zig");

pub const GicKind = enum { v2, v3 };

/// How firmware exposes PSCI. The device tree says which instruction to use;
/// guessing wrong hangs the core instead of failing cleanly.
pub const PsciMethod = enum { none, hvc, smc };

pub const Machine = struct {
    model: []const u8 = "unknown (no device tree)",
    ram_base: usize = 0x4000_0000,
    ram_size: usize = 512 * 1024 * 1024,
    uart_base: usize = 0x0900_0000,
    uart_clock: u32 = 24_000_000,
    gic_dist: usize = 0x0800_0000,
    gic_second: usize = 0x0801_0000,
    gic_kind: GicKind = .v2,
    timer_freq: u64 = 0,
    dtb: usize = 0,
    dtb_size: usize = 0,
    fdt_valid: bool = false,
    bootargs: []const u8 = "",

    // ---- SMP discovery -----------------------------------------------------
    /// Cores described by the device tree (clamped to the kernel's CPU table).
    cpu_count: u8 = 1,
    /// MPIDR of each core, in device-tree order. Core 0 is the boot CPU.
    cpu_mpidr: [8]u64 = [_]u64{0} ** 8,
    psci: PsciMethod = .none,
};

fn readBe32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

fn dtbSize(addr: usize) ?usize {
    if (addr == 0) return null;
    const head: [*]const u8 = @ptrFromInt(addr);
    if (readBe32(head[0..8], 0) != 0xd00d_feed) return null;
    const total: usize = readBe32(head[0..8], 4);
    if (total < 40 or total > 16 * 1024 * 1024) return null;
    return total;
}

fn propU32(tree: fdt.Fdt, node: fdt.Node, name: []const u8) ?u32 {
    const value = tree.prop(node, name) orelse return null;
    if (value.len < 4) return null;
    return readBe32(value, 0);
}

pub fn detect(dtb_addr: usize) Machine {
    var m = Machine{ .timer_freq = cpu.cntFrq() };
    m.dtb = dtb_addr;

    const size = dtbSize(dtb_addr) orelse return m;
    m.dtb_size = size;

    const bytes: [*]const u8 = @ptrFromInt(dtb_addr);
    const tree = fdt.Fdt.init(bytes[0..size]) catch return m;
    m.fdt_valid = true;
    m.model = tree.model();
    m.bootargs = tree.bootArgs();

    // RAM: take the largest memory region.
    var regions: [16]fdt.Reg = undefined;
    const memories = tree.memoryRegions(&regions);
    if (memories.len != 0) {
        var best = memories[0];
        for (memories) |r| {
            if (r.size > best.size) best = r;
        }
        m.ram_base = @intCast(best.base);
        m.ram_size = @intCast(best.size);
    }

    // Console.
    if (tree.findByCompatible("arm,pl011") orelse tree.findByName("pl011")) |uart_node| {
        var regs: [4]fdt.Reg = undefined;
        const found = tree.regs(uart_node, &regs);
        if (found.len > 0) m.uart_base = @intCast(found[0].base);
        if (propU32(tree, uart_node, "clock-frequency")) |hz| m.uart_clock = hz;
    }

    // Interrupt controller.
    if (tree.findByCompatible("arm,gic-v3")) |gic| {
        var regs: [4]fdt.Reg = undefined;
        const found = tree.regs(gic, &regs);
        if (found.len >= 2) {
            m.gic_dist = @intCast(found[0].base);
            m.gic_second = @intCast(found[1].base);
            m.gic_kind = .v3;
        }
    } else if (tree.findByCompatible("arm,cortex-a15-gic") orelse tree.findByCompatible("arm,gic-400")) |gic| {
        var regs: [4]fdt.Reg = undefined;
        const found = tree.regs(gic, &regs);
        if (found.len >= 2) {
            m.gic_dist = @intCast(found[0].base);
            m.gic_second = @intCast(found[1].base);
            m.gic_kind = .v2;
        }
    }

    // SMP: how to release the secondaries, and who they are.
    if (tree.findByName("psci")) |psci| {
        if (tree.prop(psci, "method")) |raw| {
            const method = std.mem.trimRight(u8, raw, "\x00");
            if (std.mem.eql(u8, method, "hvc")) {
                m.psci = .hvc;
            } else if (std.mem.eql(u8, method, "smc")) {
                m.psci = .smc;
            }
        }
    }

    if (tree.findByName("cpus")) |cpus| {
        var count: usize = 0;
        var child = tree.firstChild(cpus);
        while (child) |c| : (child = tree.nextSibling(c)) {
            if (count >= m.cpu_mpidr.len) break;
            if (!std.mem.startsWith(u8, tree.name(c), "cpu@")) continue;
            // A /cpus child has a single address cell containing the MPIDR.
            const reg = tree.prop(c, "reg") orelse {
                m.cpu_mpidr[count] = count;
                count += 1;
                continue;
            };
            if (reg.len < 4) continue;
            m.cpu_mpidr[count] = readBe32(reg, 0);
            count += 1;
        }
        if (count > 0) m.cpu_count = @intCast(count);
    }

    return m;
}

pub fn describe(m: *const Machine) void {
    klog.info("machine", "device tree: {s} (0x{x}, {d} bytes)", .{ if (m.fdt_valid) "parsed" else "absent", m.dtb, m.dtb_size });
    klog.info("machine", "model: {s}", .{m.model});
    klog.info("machine", "ram:   0x{x} + {d} MiB", .{ m.ram_base, m.ram_size / (1024 * 1024) });
    klog.info("machine", "uart:  0x{x} @ {d} Hz", .{ m.uart_base, m.uart_clock });
    klog.info("machine", "gic:   {s} dist=0x{x} second=0x{x}", .{ @tagName(m.gic_kind), m.gic_dist, m.gic_second });
    klog.info("machine", "timer: {d} Hz counter", .{m.timer_freq});
    klog.info("machine", "cpus:  {d} described, PSCI {s}", .{ m.cpu_count, @tagName(m.psci) });
    if (m.bootargs.len > 0) klog.info("machine", "cmdline: {s}", .{m.bootargs});
}
