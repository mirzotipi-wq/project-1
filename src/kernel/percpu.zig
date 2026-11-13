//! Per-CPU state (phase 18).
//!
//! Each core points TPIDR_EL1 at its own entry in `cpus`. Everything that is
//! inherently local — the running thread, its run queue, the reschedule flag,
//! interrupt and switch counters — lives here instead of in a global, so no
//! lock is needed to read it and two cores never fight over the same cache
//! line for a counter that is only ever touched locally.
//!
//! Threads are referenced as pointers, and the run queue is an intrusive list
//! through `Thread.next`; both are only mutated under the scheduler lock.

const cpu = @import("../arch/aarch64/cpu.zig");
const Thread = @import("thread.zig").Thread;

pub const max_cpus: usize = 8;

pub const Cpu = struct {
    id: u32 = 0,
    online: bool = false,

    /// Thread currently executing on this core (always non-null once the
    /// scheduler is running: it points at the idle thread when nothing else is
    /// runnable).
    current: ?*Thread = null,
    /// The thread this core runs when the run queue is empty.
    idle: ?*Thread = null,
    /// Set when this core should reschedule at the next exception exit.
    need_resched: bool = false,
    /// Ticks remaining in the running thread's slice.
    slice_left: u32 = 0,
    /// A thread that died on this core and must be reaped from another stack.
    pending_reap: ?*Thread = null,

    runq_head: ?*Thread = null,
    runq_tail: ?*Thread = null,
    runq_len: u32 = 0,

    // ---- statistics (per-core, read without locks) ------------------------
    ticks: u64 = 0,
    switches: u64 = 0,
    preemptions: u64 = 0,
    irqs: u64 = 0,
    spawned: u64 = 0,
};

pub var cpus: [max_cpus]Cpu = [_]Cpu{.{}} ** max_cpus;
pub var cpu_count: u32 = 1;

pub fn slice() []Cpu {
    return cpus[0..cpu_count];
}

/// This core's state. Requires TPIDR_EL1 to have been bound at bring-up.
pub inline fn this() *Cpu {
    return @ptrFromInt(cpu.sysRead("tpidr_el1"));
}

/// Bind the calling core to its slot. Called once per core, before anything
/// that can take an interrupt runs.
pub fn bindSelf(id: u32) void {
    cpu.sysWrite("tpidr_el1", @intFromPtr(&cpus[id]));
}

/// Reset the table to its pre-SMP state (boot CPU only, before threads exist).
pub fn reset() void {
    cpus = [_]Cpu{.{}} ** max_cpus;
    cpu_count = 1;
    cpus[0].id = 0;
    cpus[0].online = true;
}

pub fn onlineCount() u32 {
    var n: u32 = 0;
    for (slice()) |*c| {
        if (c.online) n += 1;
    }
    return n;
}
