//! Kernel threads and their stacks (phase 14).
//!
//! A thread is a saved exception frame plus a stack. Creating one means
//! allocating a physically contiguous stack, zeroing it, and writing a
//! synthetic trap frame at the top whose ELR points at the scheduler's
//! bootstrap function. From that moment the thread is indistinguishable from
//! one that was preempted mid-execution: the scheduler switches to it by
//! returning its frame pointer and the exception stub does the rest.
//!
//! That is why there is no separate "start a thread" assembly path: one context
//! switch mechanism handles new threads, resumed threads and exiting threads.

const std = @import("std");
const pmm = @import("pmm.zig");
const trap = @import("../arch/aarch64/trap.zig");

pub const State = enum {
    unused,
    ready,
    running,
    blocked,
    dead,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .unused => "unused",
            .ready => "ready",
            .running => "running",
            .blocked => "blocked",
            .dead => "dead",
        };
    }
};

pub const EntryFn = *const fn (?*anyopaque) void;

/// Eight pages (32 KiB). Formatting in a debug build is stack-hungry: a single
/// klog line can pass through several layers of std.fmt with large temporary
/// buffers. 16 KiB was measured at 94% used by the shell, which is far too close
/// to the edge for production code; the POS workloads will be measured again
/// once they exist.
pub const stack_pages: u32 = 8;
pub const stack_bytes: usize = stack_pages * pmm.page_size;

pub const max_threads: usize = 24;

pub const Thread = struct {
    id: u32 = 0,
    name: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,
    state: State = .unused,

    /// Saved stack pointer: the address of this thread's trap frame.
    sp: usize = 0,
    stack_base: usize = 0,
    stack_pages: u32 = 0,
    owns_stack: bool = true,

    entry: ?EntryFn = null,
    arg: ?*anyopaque = null,

    /// Core this thread prefers; woken threads are queued there.
    cpu: u32 = 0,
    runs: u64 = 0,
    /// Absolute uptime (ms) at which a sleeping thread becomes runnable.
    wake_at_ms: u64 = 0,
    is_idle: bool = false,
    /// Cooperative kill flag: the thread is terminated at its next safe point
    /// (a reschedule), never in the middle of touching its own stack.
    kill_requested: bool = false,

    /// Pinned threads never migrate: the scheduler refuses to steal them and
    /// woken instances are queued on their home core. Used for work whose
    /// timing must be predictable (the POS UI thread, real-time probes).
    pinned: bool = false,

    /// True from the moment this thread is selected on a core until it has
    /// actually left it. A thread that is still on a CPU must never be put on
    /// another core's run queue, or two cores execute the same stack.
    on_cpu: bool = false,
    /// A wakeup that arrived while `on_cpu` was true. Applied by the scheduler
    /// at the point the thread really leaves the CPU.
    pending_wake: bool = false,

    /// Run-queue link (only valid while queued).
    next: ?*Thread = null,
    /// Wait-queue link (only valid while blocked on a primitive).
    wait_next: ?*Thread = null,

    pub fn nameSlice(self: *const Thread) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub var table: [max_threads]Thread = [_]Thread{.{}} ** max_threads;
var next_id: u32 = 1;

pub fn reset() void {
    table = [_]Thread{.{}} ** max_threads;
    next_id = 1;
}

fn allocateSlot() ?*Thread {
    for (&table) |*t| {
        if (t.state == .unused) return t;
    }
    return null;
}

fn setName(t: *Thread, name: []const u8) void {
    const n = @min(name.len, t.name.len);
    @memcpy(t.name[0..n], name[0..n]);
    t.name_len = @intCast(n);
}

/// Reserve a thread slot without a stack (used for the boot thread, which runs
/// on the statically allocated boot stack).
pub fn allocateBare(name: []const u8) ?*Thread {
    const t = allocateSlot() orelse return null;
    t.* = .{};
    t.id = next_id;
    next_id += 1;
    t.state = .running;
    t.owns_stack = false;
    setName(t, name);
    return t;
}

/// Create a runnable thread. `bootstrap` is the address the exception return
/// sequence enters first; it is supplied by the scheduler so this module never
/// has to know scheduler policy.
pub fn create(
    alloc: *pmm.PageAllocator,
    name: []const u8,
    entry: EntryFn,
    arg: ?*anyopaque,
    bootstrap: usize,
) ?*Thread {
    const t = allocateSlot() orelse return null;
    const base = alloc.allocContiguous(stack_pages) orelse return null;

    t.* = .{};
    t.id = next_id;
    next_id += 1;
    t.state = .ready;
    t.entry = entry;
    t.arg = arg;
    t.stack_base = base;
    t.stack_pages = stack_pages;
    t.owns_stack = true;
    setName(t, name);

    // A fresh stack must never contain stale kernel memory: zeros also make an
    // overflow visible as an all-zero frame instead of garbage registers.
    const bytes: [*]u8 = @ptrFromInt(base);
    @memset(bytes[0..stack_bytes], 0);

    const top = base + stack_bytes;
    const frame: *trap.Frame = @ptrFromInt(top - @sizeOf(trap.Frame));
    frame.* = std.mem.zeroes(trap.Frame);
    frame.elr = bootstrap;
    frame.spsr = trap.el1_thread_spsr; // EL1h, interrupts open
    // x19 carries the thread pointer into the bootstrap, which is the
    // callee-saved register the ABI guarantees survives the entry sequence.
    frame.x[19] = @intFromPtr(t);

    t.sp = @intFromPtr(frame);
    return t;
}

/// Return a thread's slot and stack to the pool. Must be called with the
/// thread's stack no longer in use (the scheduler reaps from another stack).
pub fn destroy(alloc: *pmm.PageAllocator, t: *Thread) void {
    if (t.owns_stack and t.stack_base != 0) {
        alloc.freeRange(t.stack_base, t.stack_pages);
    }
    t.* = .{};
}

pub fn find(id: u32) ?*Thread {
    for (&table) |*t| {
        if (t.state != .unused and t.id == id) return t;
    }
    return null;
}

pub fn liveCount() u32 {
    var n: u32 = 0;
    for (&table) |*t| {
        if (t.state != .unused) n += 1;
    }
    return n;
}

test "state labels are stable for the thread listing" {
    try std.testing.expectEqualStrings("running", State.running.label());
    try std.testing.expectEqualStrings("blocked", State.blocked.label());
}

test "thread slots are identified and reused" {
    reset();
    const a = allocateBare("a").?;
    const b = allocateBare("b").?;
    try std.testing.expect(a.id != b.id);
    try std.testing.expectEqual(@as(u32, 2), liveCount());
    try std.testing.expect(find(a.id) == a);
    a.* = .{}; // as destroy would leave it
    try std.testing.expectEqual(@as(u32, 1), liveCount());
    try std.testing.expect(find(a.id) == null);
    reset();
}
