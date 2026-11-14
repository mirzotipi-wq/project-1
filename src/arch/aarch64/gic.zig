//! ARM Generic Interrupt Controller v2 and v3.
//!
//! Phase 11 of the plan. Both generations are supported behind one API; the
//! variant is selected from the device tree compatible string, never from a
//! build flag.

const std = @import("std");
const cpu = @import("cpu.zig");
const klog = @import("../../kernel/klog.zig");

pub const Version = enum { v2, v3 };

pub const spurious_id: u32 = 1023;

var version: Version = .v2;
var initialized = false;

// v2: distributor + CPU interface. v3: distributor + redistributor.
var dist_base: usize = 0;
var cpu_base: usize = 0;
var redist_base: usize = 0;

fn mmio32(base: usize) *volatile u32 {
    return @ptrFromInt(base);
}

fn mmio8(base: usize) *volatile u8 {
    return @ptrFromInt(base);
}

fn distRead(off: usize) u32 {
    return mmio32(dist_base + off).*;
}

fn distWrite(off: usize, value: u32) void {
    mmio32(dist_base + off).* = value;
}

// Distributor registers shared by both versions.
const GICD_CTLR = 0x0000;
const GICD_ISENABLER = 0x0100;
const GICD_ICENABLER = 0x0180;
const GICD_IPRIORITYR = 0x0400;
const GICD_ITARGETSR = 0x0800;
const GICD_IGROUPR = 0x0080;

// v2 CPU interface registers (relative to GICC base).
const GICC_CTLR = 0x0000;
const GICC_PMR = 0x0004;
const GICC_IAR = 0x000c;
const GICC_EOIR = 0x0010;

// v3 redistributor registers.
const GICR_CTLR = 0x0000;
const GICR_WAKER = 0x0014;
const GICR_SGI_BASE = 0x10000;
const GICR_IGROUPR0 = 0x0080;
const GICR_ISENABLER0 = 0x0100;
const GICR_ICENABLER0 = 0x0180;
const GICR_IPRIORITYR = 0x0400;

const WAKER_PROCESSOR_SLEEP: u32 = 1 << 1;
const WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;

const CTLR_RWP: u32 = 1 << 31;

fn waitForRwp() void {
    var guard: u32 = 1_000_000;
    while ((distRead(GICD_CTLR) & CTLR_RWP) != 0 and guard > 0) : (guard -= 1) {}
}

fn initV2(dist: usize, cpu_if: usize) void {
    dist_base = dist;
    cpu_base = cpu_if;

    distWrite(GICD_CTLR, 0);
    waitForRwp();

    // Group 1 for everything; no security extensions at EL1.
    distWrite(GICD_CTLR, 1);
    waitForRwp();

    mmio32(cpu_base + GICC_PMR).* = 0xF0;
    mmio32(cpu_base + GICC_CTLR).* = 1;

    version = .v2;
    initialized = true;
    klog.info("gic", "GICv2 up: dist=0x{x} cpu=0x{x}", .{ dist, cpu_if });
}

fn waitForWake() void {
    waitForWakeAt(redist_base);
}

fn waitForWakeAt(base: usize) void {
    var guard: u32 = 1_000_000;
    while ((mmio32(base + GICR_WAKER).* & WAKER_CHILDREN_ASLEEP) != 0 and guard > 0) : (guard -= 1) {}
}

/// GICv3 redistributors are laid out in memory with a fixed stride; the
/// architecture leaves the size up to the implementation (SGI frames make it
/// 128 KiB on some parts, 256 KiB on others). QEMU's `virt` machine uses
/// 0x20000, and the device tree's `reg` entry describes exactly one of them.
const redist_stride_v3: usize = 0x2_0000;

fn initV3(dist: usize, redist: usize) void {
    dist_base = dist;
    redist_base = redist;

    distWrite(GICD_CTLR, 0);
    waitForRwp();
    // ARE_NS | EnableGrp1NS | EnableGrp0
    distWrite(GICD_CTLR, (1 << 4) | (1 << 1) | (1 << 0));
    waitForRwp();

    // Wake this core's redistributor (redistributor 0 == boot CPU for now;
    // per-CPU redistributor selection arrives with SMP in phase 18).
    mmio32(redist_base + GICR_WAKER).* &= ~WAKER_PROCESSOR_SLEEP;
    waitForWake();

    // System-register interface.
    cpu.sysWrite("icc_sre_el1", 0x7); // SRE | DFB | DIB
    cpu.isb();
    cpu.sysWrite("icc_pmr_el1", 0xFF);
    cpu.sysWrite("icc_ctlr_el1", 0); // EOImode = 0
    cpu.sysWrite("icc_igrpen0_el1", 1);
    cpu.sysWrite("icc_igrpen1_el1", 1);
    cpu.isb();

    version = .v3;
    initialized = true;
    klog.info("gic", "GICv3 up: dist=0x{x} redist=0x{x}", .{ dist, redist });
}

pub fn init(dist: usize, second: usize, kind: Version) void {
    switch (kind) {
        .v2 => initV2(dist, second),
        .v3 => initV3(dist, second),
    }
}

pub fn getVersion() Version {
    return version;
}

pub fn isReady() bool {
    return initialized;
}

/// Enable an interrupt line and give it a mid priority.
pub fn enableIrq(intid: u32) void {
    if (!initialized or intid >= 1020) return;
    const prio_off = GICD_IPRIORITYR + intid;
    switch (version) {
        .v2 => {
            mmio8(dist_base + prio_off).* = 0xA0;
            if (intid < 32) {
                // PPIs/SGIs live in the per-CPU bank; no targeting needed.
            } else {
                const target_off = GICD_ITARGETSR + (intid & ~@as(u32, 3));
                mmio32(dist_base + target_off).* = 0x0101_0101;
            }
            distWrite(GICD_ISENABLER + (intid / 32) * 4, @as(u32, 1) << @intCast(intid % 32));
        },
        .v3 => {
            if (intid < 32) {
                mmio32(redist_base + GICR_IGROUPR0).* = 0xFFFF_FFFF;
                mmio8(redist_base + GICR_IPRIORITYR + intid).* = 0xA0;
                mmio32(redist_base + GICR_ISENABLER0).* = @as(u32, 1) << @intCast(intid);
            } else {
                mmio8(dist_base + prio_off).* = 0xA0;
                distWrite(GICD_IGROUPR + (intid / 32) * 4, 0xFFFF_FFFF);
                distWrite(GICD_ISENABLER + (intid / 32) * 4, @as(u32, 1) << @intCast(intid % 32));
            }
        },
    }
}

pub fn disableIrq(intid: u32) void {
    if (!initialized or intid >= 1020) return;
    switch (version) {
        .v2 => distWrite(GICD_ICENABLER + (intid / 32) * 4, @as(u32, 1) << @intCast(intid % 32)),
        .v3 => {
            if (intid < 32) {
                mmio32(redist_base + GICR_ICENABLER0).* = @as(u32, 1) << @intCast(intid);
            } else {
                distWrite(GICD_ICENABLER + (intid / 32) * 4, @as(u32, 1) << @intCast(intid % 32));
            }
        },
    }
}

/// Is the line actually enabled? Route and enable are only worth anything if
/// the controller reads back the bit: the PCIe probe checks it after routing an
/// INTx and after a driver claims an SPI.
pub fn irqEnabled(intid: u32) bool {
    if (!initialized or intid >= 1020) return false;
    return switch (version) {
        .v2 => distRead(GICD_ISENABLER + (intid / 32) * 4) & (@as(u32, 1) << @intCast(intid % 32)) != 0,
        .v3 => if (intid < 32)
            mmio32(redist_base + GICR_ISENABLER0).* & (@as(u32, 1) << @intCast(intid)) != 0
        else
            distRead(GICD_ISENABLER + (intid / 32) * 4) & (@as(u32, 1) << @intCast(intid % 32)) != 0,
    };
}

/// Acknowledge the highest-priority pending interrupt.
pub fn acknowledge() u32 {
    return switch (version) {
        .v2 => mmio32(cpu_base + GICC_IAR).* & 0x3FF,
        .v3 => @intCast(cpu.sysRead("icc_iar1_el1") & 0xFFFFFF),
    };
}

/// Signal end of interrupt.
pub fn endOfInterrupt(intid: u32) void {
    if (intid >= 1020) return;
    switch (version) {
        .v2 => mmio32(cpu_base + GICC_EOIR).* = intid,
        .v3 => {
            cpu.sysWrite("icc_eoir1_el1", intid);
        },
    }
}

// ---------------------------------------------------------------------------
// Per-core bring-up
// ---------------------------------------------------------------------------

/// Initialise the calling core's interrupt interface. Must run on each core:
/// the distributor is global, the CPU interface (v2) and redistributor (v3) are
/// not. Both generations also leave the timer PPI and the reschedule SGI
/// enabled locally here, because for v3 the enable bits live in the
/// redistributor that belongs to this core.
pub fn initCpu(index: u32) void {
    if (!initialized) return;
    switch (version) {
        .v2 => {
            mmio32(cpu_base + GICC_PMR).* = 0xF0;
            mmio32(cpu_base + GICC_CTLR).* = 1;
            distWrite(GICD_ISENABLER + 0, (1 << 30) | 1);
            distWrite(GICD_IPRIORITYR + 96, 0xA0A0_A0A0);
            distWrite(GICD_IPRIORITYR + 0, 0xA0A0_A0A0);
        },
        .v3 => {
            const rb = redist_base + @as(usize, index) * redist_stride_v3;
            mmio32(rb + GICR_WAKER).* &= ~WAKER_PROCESSOR_SLEEP;
            waitForWakeAt(rb);

            cpu.sysWrite("icc_sre_el1", 0x7);
            cpu.isb();
            cpu.sysWrite("icc_pmr_el1", 0xFF);
            cpu.sysWrite("icc_ctlr_el1", 0);
            cpu.sysWrite("icc_igrpen1_el1", 1);
            cpu.isb();

            mmio32(rb + GICR_IGROUPR0).* = 0xFFFF_FFFF;
            mmio32(rb + GICR_ISENABLER0).* = (1 << 30) | 1;
        },
    }
}

/// Send a software-generated interrupt to one core (SGI 0 is the reschedule
/// IPI). The target is an Aff0 value, i.e. the core number within its cluster,
/// which is what the device tree's MPIDR gives us for cores 0..N on every
/// current multi-core AArch64 part.
pub fn sendSgi(target_aff0: u64, intid: u32) void {
    if (!initialized) return;
    switch (version) {
        .v2 => {
            const value: u32 = (@as(u32, @intCast(target_aff0 & 0xFF)) << 24) | (intid & 0xF);
            mmio32(dist_base + 0xF00).* = value;
        },
        .v3 => {
            const value: u64 = (target_aff0 << 16) |
                (@as(u64, intid) << 24) |
                (@as(u64, 1) << @intCast(target_aff0 & 0xF));
            cpu.sysWrite("icc_sgi1r_el1", value);
        },
    }
}

test "spurious interrupt id is outside the implementable range" {
    try std.testing.expect(spurious_id >= 1020);
}
