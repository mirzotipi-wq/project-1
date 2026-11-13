//! SMP bring-up (phase 18).
//!
//! Secondary cores are started with PSCI CPU_ON, which is how every modern
//! AArch64 firmware (and QEMU's `virt` machine) releases them from the
//! spin-table / holding pen. The entry point must be physical (secondaries
//! start with the MMU off), so the trampoline below does the absolute minimum:
//! pick a stack from a static table by context id, then call Zig.
//!
//! Once in Zig, each core repeats the local half of the bring-up — vectors,
//! MMU, GIC CPU interface, timer — and joins the scheduler as its own idle
//! thread. Its first timer interrupt is what gives the scheduler a frame to
//! save, after which that core is an ordinary participant.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const exceptions = @import("../arch/aarch64/exceptions.zig");
const gic = @import("../arch/aarch64/gic.zig");
const timer = @import("../arch/aarch64/timer.zig");
const irq = @import("../kernel/irq.zig");
const machine = @import("machine.zig");
const percpu = @import("percpu.zig");
const sched = @import("sched.zig");
const klog = @import("klog.zig");

/// SGI 0: "look at your run queue". Targets are identified by Aff0, which on
/// every current AArch64 SoC is the core number within the cluster.
pub const ipi_reschedule: u32 = 0;
/// "Stop everything": sent by the panic reporter to every other core so the
/// terminal shows one coherent crash report instead of four interleaved ones.
pub const ipi_stop: u32 = 1;

fn onStop(_: u32) void {
    cpu.allInterruptsDisable();
    while (true) cpu.wfe();
}

pub fn stopOtherCores() void {
    const self = percpu.this().id;
    for (percpu.slice()) |*pc| {
        if (pc.id == self or !pc.online) continue;
        gic.sendSgi(pc.id, ipi_stop);
    }
    cpu.dsbSy();
}

const secondary_stack_size = 16 * 1024;

/// Exported so the entry trampoline can address it with adrp/:lo12:.
export var cassa_secondary_stacks: [percpu.max_cpus][secondary_stack_size]u8 align(16) = undefined;

/// First instruction executed on a core released by PSCI. x0 carries the
/// context id we passed to CPU_ON. No stack, no MMU, no caches: only what the
/// trampoline itself needs.
export fn cassa_secondary_entry() callconv(.Naked) noreturn {
    asm volatile (
        \\mov x9, x0
        \\adrp x10, cassa_secondary_stacks
        \\add x10, x10, :lo12:cassa_secondary_stacks
        \\lsl x11, x9, #14
        \\add x10, x10, x11
        \\add x10, x10, #16384
        \\mov sp, x10
        \\bl cassa_secondary_main
        \\1: wfe
        \\b 1b
    );
}

export fn cassa_secondary_main(context: u64) callconv(.C) noreturn {
    const id: u32 = @intCast(context & 0xFF);
    cpu.allInterruptsDisable();
    cpu.enableFp();

    percpu.bindSelf(id);
    const pc = percpu.this();
    pc.id = id;

    exceptions.init();
    mmu.enableOnThisCpu();
    gic.initCpu(id);
    timer.initCpu();

    pc.online = true;
    pc.current = pc.idle orelse @panic("smp: secondary core has no idle thread");
    pc.slice_left = sched.slice_ticks;

    klog.info("smp", "core {d} online (MPIDR 0x{x})", .{ id, cpu.sysRead("mpidr_el1") & 0xFF_FFFF });
    cpu.irqEnable();

    // Run the idle loop on this core's bring-up stack. The first tick saves a
    // frame here, after which the scheduler treats this core like any other.
    while (true) {
        cpu.wfe();
    }
}

// ---------------------------------------------------------------------------
// PSCI
// ---------------------------------------------------------------------------

const PSCI_CPU_ON_64: u64 = 0xC400_0003;

fn psciCall(method: machine.PsciMethod, function: u64, a0: u64, a1: u64, a2: u64) i64 {
    var result: i64 = undefined;
    switch (method) {
        .hvc => asm volatile ("hvc #0"
            : [ret] "={x0}" (result),
            : [func] "{x0}" (function),
              [a] "{x1}" (a0),
              [b] "{x2}" (a1),
              [c] "{x3}" (a2),
            : "memory", "x1", "x2", "x3",
        ),
        .smc => asm volatile ("smc #0"
            : [ret] "={x0}" (result),
            : [func] "{x0}" (function),
              [a] "{x1}" (a0),
              [b] "{x2}" (a1),
              [c] "{x3}" (a2),
            : "memory", "x1", "x2", "x3",
        ),
        .none => return -1,
    }
    return result;
}

fn cpuOn(method: machine.PsciMethod, mpidr: u64, entry: usize, context: u64) i64 {
    return psciCall(method, PSCI_CPU_ON_64, mpidr, @intCast(entry), context);
}

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

pub fn sendRescheduleIpi(id: u32) void {
    gic.sendSgi(id, ipi_reschedule);
}

/// Start every secondary core described by the device tree and wait (briefly)
/// for them to check in. A machine without PSCI keeps running on one core: the
/// kernel says so instead of pretending.
pub fn startAll(m: *const machine.Machine) void {
    irq.register(ipi_reschedule, sched.onRescheduleIpi);
    irq.register(ipi_stop, onStop);

    const count: u32 = @min(m.cpu_count, percpu.max_cpus);
    percpu.cpu_count = count;

    if (count <= 1) {
        klog.info("smp", "single core: no secondary CPUs described by firmware", .{});
        return;
    }
    if (m.psci == .none) {
        klog.warn("smp", "{d} cores described but no PSCI node; running on one core", .{count});
        percpu.cpu_count = 1;
        return;
    }

    for (1..count) |id| {
        // Idle thread for the core must exist before it can join.
        sched.createIdle(@intCast(id));
        const rc = cpuOn(m.psci, m.cpu_mpidr[id], @intFromPtr(&cassa_secondary_entry), id);
        if (rc != 0) {
            klog.warn("smp", "CPU_ON for core {d} (MPIDR 0x{x}) returned {d}", .{ id, m.cpu_mpidr[id], rc });
        }
    }

    const deadline = timer.uptimeNs() + 300_000_000;
    while (percpu.onlineCount() < count and timer.uptimeNs() < deadline) {
        cpu.dsbSy();
    }

    const online = percpu.onlineCount();
    if (online == count) {
        klog.info("smp", "{d} cores online", .{online});
    } else {
        klog.warn("smp", "{d} of {d} cores online (PSCI {s})", .{ online, count, @tagName(m.psci) });
        percpu.cpu_count = @max(online, 1);
    }
}
