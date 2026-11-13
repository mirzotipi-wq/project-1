//! The preemptive scheduler (phases 15–17).
//!
//! Cassa switches context at *exception boundaries*. Every thread that is not
//! running is parked on a trap frame that sits at the top of its kernel stack;
//! `reschedule` saves the current stack pointer into the outgoing thread and
//! returns the incoming thread's frame address. The exception trampoline then
//! loads SP from that return value and executes its normal restore-and-`eret`
//! sequence. There is no switch routine that runs on a half-valid stack, no
//! register set that has to be duplicated in assembly and C, and a brand new
//! thread is just a frame that was written by hand instead of by the CPU.
//!
//! Policy: fixed-slice round robin per core, with work stealing between cores
//! when a queue runs dry. The slice is a handful of 1 kHz ticks so that an
//! interactive POS terminal never waits long for a keystroke, while the shell
//! and a payment workload still make progress.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const timer = @import("../arch/aarch64/timer.zig");
const trap = @import("../arch/aarch64/trap.zig");
const percpu = @import("percpu.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const user_space = @import("addrspace.zig");
const thread_mod = @import("thread.zig");
const sync = @import("sync.zig");
const klog = @import("klog.zig");
const pmm = @import("pmm.zig");
const smp = @import("smp.zig");

pub const Thread = thread_mod.Thread;
pub const State = thread_mod.State;

/// Ticks (milliseconds at the current 1 kHz tick) a thread runs before it is
/// preempted. Four gives 250 voluntary switches per second per core.
pub const slice_ticks: u32 = 4;

/// One scheduler lock for every run queue. It is taken with IRQs masked and is
/// only ever held for a few pointer stores, so a global lock is cheaper than
/// per-CPU locking here and removes a whole class of ordering bugs.
var lock: sync.IrqSpinLock = .{};
var alloc: ?*pmm.PageAllocator = null;

/// Last few context switches, kept in memory so a fault report can show the
/// history that led to the crash. Cheap (two stores per switch) and far more
/// useful than a single snapshot of the current thread.
pub const SwitchRecord = struct {
    ms: u64,
    cpu: u32,
    prev: u32,
    next: u32,
    next_sp: usize,
    prev_elr: u64,
    next_elr: u64,
};

const trace_capacity = 64;
pub var trace_ring: [trace_capacity]SwitchRecord = undefined;
var trace_head: usize = 0;
var trace_count: usize = 0;

fn traceSwitch(cpu_id: u32, prev: *Thread, next: *Thread, frame: *trap.Frame) void {
    trace_ring[trace_head] = .{
        .ms = timer.uptimeMs(),
        .cpu = cpu_id,
        .prev = prev.id,
        .next = next.id,
        .next_sp = next.sp,
        .prev_elr = frame.elr,
        .next_elr = (@as(*trap.Frame, @ptrFromInt(next.sp))).elr,
    };
    trace_head = (trace_head + 1) % trace_capacity;
    if (trace_count < trace_capacity) trace_count += 1;
}

/// Format the trace into `out`, oldest first. Used by the fault reporter.
pub fn traceDump(out: []u8) []u8 {
    var stream = std.io.fixedBufferStream(out);
    const w = stream.writer();
    const n = trace_count;
    const start = (trace_head + trace_capacity - n) % trace_capacity;
    w.print("scheduler trace (oldest first, {d} switches):\n", .{n}) catch {};
    for (0..n) |i| {
        const r = trace_ring[(start + i) % trace_capacity];
        const prev_name = if (thread_mod.find(r.prev)) |t| t.nameSlice() else "-";
        const next_name = if (thread_mod.find(r.next)) |t| t.nameSlice() else "-";
        w.print("  {d: >6} ms cpu{d} {d}:{s} -> {d}:{s} sp=0x{x} elr=0x{x} next_elr=0x{x}\n", .{
            r.ms, r.cpu, r.prev, prev_name, r.next, next_name, r.next_sp, r.prev_elr, r.next_elr,
        }) catch {};
    }
    return stream.getWritten();
}

pub const KernelBackend = struct {
    pub const Node = Thread;
    pub const Handle = *Thread;

    pub fn current() *Thread {
        return running();
    }
    pub fn block(t: *Thread) void {
        t.state = .blocked;
    }
    pub fn wake(t: *Thread) void {
        makeReady(t);
    }
    pub fn schedule() void {
        yieldNow();
    }
};

/// Blocking semaphore with kernel threads as waiters.
pub const Semaphore = sync.Semaphore(KernelBackend);

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

/// Turn the currently executing context into the boot thread and create the
/// CPU 0 idle thread. Called once, after the physical allocator exists.
pub fn init(p: *pmm.PageAllocator) void {
    alloc = p;
    thread_mod.reset();
    percpu.reset();

    const boot = thread_mod.allocateBare("boot") orelse @panic("sched: no thread slot for the boot thread");
    boot.cpu = 0;
    boot.runs = 1;
    // The boot context runs on this core from the first instruction, so it is
    // on a CPU before any scheduler transition says so. Without this a wakeup
    // from another core would queue it while it is still running here.
    boot.on_cpu = true;
    boot.state = .running;
    percpu.cpus[0].current = boot;

    createIdle(0);
    timer.setTickHook(&tick);
    klog.info("sched", "round-robin scheduler ready ({d} tick slice, preemptive)", .{slice_ticks});
}

/// Create the idle thread for a core. It is never enqueued: it is selected
/// directly whenever that core's run queue is empty.
pub fn createIdle(id: u32) void {
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "idle/{d}", .{id}) catch "idle";
    const t = thread_mod.create(alloc.?, name, idleLoop, null, @intFromPtr(&threadBootstrap)) orelse
        @panic("sched: cannot create an idle thread");
    t.is_idle = true;
    t.state = .running;
    t.cpu = id;
    percpu.cpus[id].idle = t;
    if (id == 0) {
        // The boot context runs until kmain finishes; the idle thread takes
        // over at the first schedule with nothing runnable.
        percpu.cpus[id].slice_left = slice_ticks;
    }
}

/// Entry point every new thread lands on. It runs with interrupts open, on the
/// thread's own stack, with `current` already pointing at it.
fn threadBootstrap() callconv(.C) noreturn {
    const pc = percpu.this();
    const t = pc.current orelse @panic("sched: bootstrap with no current thread");
    klog.debug("sched", "thread {d} '{s}' started on core {d}", .{ t.id, t.nameSlice(), pc.id });
    if (t.entry) |entry| entry(t.arg);
    exitCurrent();
}

fn idleLoop(_: ?*anyopaque) void {
    while (true) {
        cpu.irqEnable();
        cpu.wfe();
        // A thread that exited on this core left its stack to be freed here.
        // Idle is the natural place: it is guaranteed not to be running on the
        // dead thread's stack.
        reapPending(percpu.this());
    }
}

// ---------------------------------------------------------------------------
// Run queues
// ---------------------------------------------------------------------------

fn pushTail(pc: *percpu.Cpu, t: *Thread) void {
    t.next = null;
    if (pc.runq_tail) |tail| tail.next = t else pc.runq_head = t;
    pc.runq_tail = t;
    pc.runq_len += 1;
}

fn popHead(pc: *percpu.Cpu) ?*Thread {
    const head = pc.runq_head orelse return null;
    pc.runq_head = head.next;
    if (pc.runq_head == null) pc.runq_tail = null;
    head.next = null;
    pc.runq_len -= 1;
    return head;
}

/// Take one thread from the busiest other core. Called with the lock held.
fn stealLocked(pc: *percpu.Cpu) ?*Thread {
    for (percpu.slice()) |*other| {
        if (other.id == pc.id) continue;
        if (!other.online) continue;
        if (other.runq_len < 2) continue;
        if (other.runq_head) |head| {
            if (head.pinned) continue;
        }
        if (popHead(other)) |t| {
            t.cpu = pc.id;
            return t;
        }
    }
    return null;
}

/// Make a blocked thread runnable again. Safe from IRQ context and from any
/// core.
///
/// The subtle case is a wakeup that arrives while the thread is still on a CPU
/// — it has marked itself blocked but has not executed its reschedule yet. If
/// we queued it now, another core could pick it up and two cores would run the
/// same kernel stack (this is exactly what the scheduler trace caught: the same
/// thread resumed on all four cores). Instead the wake is remembered in
/// `pending_wake` and applied by `reschedule` at the instant the thread leaves
/// the CPU.
pub fn makeReady(t: *Thread) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    makeReadyLocked(percpu.this(), t);
}

fn makeReadyLocked(pc: *percpu.Cpu, t: *Thread) void {
    if (t.state == .unused or t.state == .dead) return;
    if (t.on_cpu) {
        t.pending_wake = true;
        pc.need_resched = true;
        return;
    }
    // A thread that is already runnable is already on some core's run queue.
    // Queueing it a second time (two cores waking the same sleeper, or a wake
    // and the deadline scan racing) would let two cores run one kernel stack,
    // which is exactly how a thread ends up jumping into its own stack.
    if (t.state != .blocked) return;
    t.state = .ready;
    t.pending_wake = false;
    if (!t.pinned or t.cpu >= percpu.cpu_count) {
        t.cpu = pc.id;
        pushTail(pc, t);
        pc.need_resched = true;
        return;
    }
    // Pinned: always run on the core it was created on, even if the wakeup
    // came from somewhere else.
    const home = &percpu.cpus[t.cpu];
    pushTail(home, t);
    home.need_resched = true;
    if (home.id != pc.id) smp.sendRescheduleIpi(home.id);
}

// ---------------------------------------------------------------------------
// Tick
// ---------------------------------------------------------------------------

/// Called from the timer interrupt on every core at 1 kHz.
pub fn tick() void {
    const pc = percpu.this();
    pc.ticks += 1;
    wakeSleepers(timer.uptimeMs());
    reapAll();

    const cur = pc.current orelse return;
    if (cur.is_idle) {
        // Idle only ever runs when there is nothing to do. Look at every queue,
        // not just this core's: an idle core should pull work off a busy one
        // rather than watch it from a distance.
        var work = pc.runq_head != null;
        if (!work) {
            for (percpu.slice()) |*other| {
                if (other.id != pc.id and other.runq_len > 1) {
                    work = true;
                    break;
                }
            }
        }
        if (work) pc.need_resched = true;
    } else if (pc.slice_left > 0) {
        pc.slice_left -= 1;
    }
    if (!cur.is_idle and pc.slice_left == 0) pc.need_resched = true;
}

fn wakeSleepers(now_ms: u64) void {
    const flags = lock.acquire();
    defer lock.release(flags);
    const pc = percpu.this();
    for (&thread_mod.table) |*t| {
        if (t.state != .blocked or t.wake_at_ms == 0) continue;
        if (now_ms < t.wake_at_ms) continue;
        t.wake_at_ms = 0;
        makeReadyLocked(pc, t);
    }
}

// ---------------------------------------------------------------------------
// Switching
// ---------------------------------------------------------------------------

/// Free every thread that is finished and no longer running anywhere.
///
/// A single "pending reap" slot per core is not enough: several short-lived
/// threads can exit on one core between two schedules, and every one of them
/// owns a stack. The invariant that makes a scan safe is `on_cpu`: the scheduler
/// clears it at the instant a thread leaves a core, so `dead && !on_cpu` means
/// no core is executing on that stack and no queue references it.
fn reapAll() void {
    const flags = lock.acquire();
    defer lock.release(flags);
    const self = percpu.this().current;
    for (&thread_mod.table) |*t| {
        if (t.state != .dead or t.on_cpu) continue;
        if (self == t) continue;
        if (alloc) |a| thread_mod.destroy(a, t);
    }
}

fn reapPending(pc: *percpu.Cpu) void {
    _ = pc;
    reapAll();
}

/// Pick the next thread on this core and return the trap frame to resume.
/// Called with IRQs masked, from an exception handler.
pub fn reschedule(frame: *trap.Frame) *trap.Frame {
    const pc = percpu.this();
    reapPending(pc);

    const flags = lock.acquire();
    const prev = pc.current orelse {
        lock.release(flags);
        return frame;
    };
    prev.sp = @intFromPtr(frame);

    // A requested kill takes effect here and nowhere else: the thread has a
    // valid frame, is not holding any of its own data mid-update, and will
    // never be resumed.
    if (prev.kill_requested and prev.state != .dead and prev.state != .unused) prev.state = .dead;

    // Apply any wake that arrived while this thread was still running. From
    // here on it is genuinely off the CPU, so it is safe to queue.
    var prev_runnable = false;
    if (prev.pending_wake and prev.state != .dead) {
        prev.pending_wake = false;
        prev.state = .ready;
        prev_runnable = true;
    }

    if (prev.state == .running and !prev.is_idle) {
        prev.state = .ready;
        prev_runnable = true;
    } else if (prev.state == .dead) {
        // The thread exited on this stack; hand it to whoever runs next.
        pc.pending_reap = prev;
    }

    var next: *Thread = popHead(pc) orelse stealLocked(pc) orelse pc.idle.?;
    // A thread that is already marked on-CPU is running somewhere else. Two
    // cores must never share one kernel stack, so a queue entry that names such
    // a thread is dropped here (and counted) instead of being resumed: that is
    // a split brain, and running it would corrupt the stack of whichever core
    // is currently executing it.
    if (next.on_cpu) {
        double_run_events += 1;
        next = pc.idle.?;
    }
    if (next.state == .dead or next.state == .unused) {
        klog.err("sched", "core {d} selected thread {d} in state {s} (sp=0x{x})", .{ pc.id, next.id, next.state.label(), next.sp });
        @panic("scheduler: selected a non-runnable thread");
    }

    if (next == prev) {
        // Nothing else to run: keep going, do not queue ourselves.
        prev.state = .running;
        prev.on_cpu = true;
        pc.slice_left = slice_ticks;
        pc.need_resched = false;
        lock.release(flags);
        return frame;
    }

    if (prev_runnable) pushTail(pc, prev);

    // A frame that does not point at kernel code can only come from a corrupted
    // stack. Detect it here, where the offending thread is still identifiable,
    // instead of letting the CPU jump into nowhere.
    const next_frame: *trap.Frame = @ptrFromInt(next.sp);
    // A kernel thread resumes in kernel text; a user thread resumes anywhere in
    // its own window. Both are checked, because a frame that points outside the
    // space the thread is allowed to run in means the stack was corrupted.
    // A user thread is normally parked in its own code, but a blocking syscall
    // parks it *inside the kernel*: the frame then records an EL1 return
    // address and the syscall resumes when the thread is next scheduled. Both
    // are legitimate; anything else is a corrupted stack.
    const elr = next_frame.elr;
    const kernel_frame = (next_frame.spsr & 0xF) != 0;
    const in_kernel_text = elr >= 0x4008_0000 and elr < 0x401b_0000;
    const elr_ok = if (next.address_space != null)
        (in_kernel_text and kernel_frame) or
            (elr >= user_space.code_va and elr < user_space.window_end)
    else
        in_kernel_text;
    // A frame whose saved PSTATE is not one of the two states a thread can be in
    // (EL0t for user code, EL1h for kernel code) is not a frame any more. Without
    // this check `eret` would restore a nonsense mode and the core would jump
    // into whatever address the garbage names.
    const spsr_mode = next_frame.spsr & 0xF;
    const spsr_ok = spsr_mode == 0 or spsr_mode == 5;
    if (next.sp < 0x4000_0000 or next.sp >= 0x4100_0000 or !elr_ok or !spsr_ok) {
        klog.err("sched", "corrupt frame for thread {d} '{s}' on core {d}: sp=0x{x} elr=0x{x} spsr=0x{x} state={s}", .{
            next.id, next.nameSlice(), pc.id, next.sp, next_frame.elr, next_frame.spsr, next.state.label(),
        });
        klog.err("sched", "previous thread {d} '{s}' elr=0x{x} state={s}", .{
            prev.id, prev.nameSlice(), frame.elr, prev.state.label(),
        });
        @panic("scheduler: corrupt thread frame");
    }

    // The tables are installed before the old thread is marked off-CPU: once
    // `on_cpu` clears another core may reap it, and reaping frees the very
    // tables this core would still be using.
    installAddressSpace(pc, next);
    // `prev` is still the stack this core is executing on: the switch happens in
    // the trampoline, after this function returns. Clearing `on_cpu` here would
    // let another core reap the stack while this core is still using it, which
    // shows up as a thread resuming on a freed, recycled stack. The trampoline
    // calls `cassa_after_switch` once `mov sp, x0` has happened.
    pc.switching_out = prev;

    next.state = .running;
    next.on_cpu = true;
    next.pending_wake = false;
    next.runs += 1;
    pc.current = next;
    pc.switches += 1;
    pc.preemptions += 1;
    traceSwitch(pc.id, prev, next, frame);
    pc.slice_left = slice_ticks;
    pc.need_resched = false;
    lock.release(flags);

    return @ptrFromInt(next.sp);
}

/// Called by the exception trampoline right after the stack pointer has been
/// switched, so the outgoing thread can finally be marked off-CPU.
export fn cassa_after_switch() callconv(.C) void {
    const pc = percpu.this();
    const prev = pc.switching_out orelse return;
    pc.switching_out = null;
    const flags = lock.acquire();
    prev.on_cpu = false;
    // A wake that arrived during the switch was deferred because the thread was
    // still on this core. Now that it is off, the wake has to be applied here or
    // it would be lost: `reschedule` has already run its pending-wake check.
    if (prev.pending_wake and prev.state != .dead and prev.state != .unused) {
        prev.pending_wake = false;
        prev.state = .ready;
        pushTail(pc, prev);
        pc.need_resched = true;
    }
    lock.release(flags);
}

/// Point this core's TTBR0 at the address space the next thread needs. A
/// kernel thread (or the idle thread) gets the kernel's own tables back, which
/// is what makes a user address space impossible to reach from kernel code that
/// is not acting on that process's behalf.
fn installAddressSpace(pc: *percpu.Cpu, next: *Thread) void {
    const want: usize = if (next.address_space) |as| as.root else mmu.kernelRootPa();
    if (pc.ttbr0 == want) return;
    mmu.switchToRoot(want);
    pc.ttbr0 = want;
}

/// Called at the end of every IRQ with the interrupted frame.
pub fn preempt(frame: *trap.Frame) *trap.Frame {
    const pc = percpu.this();
    if (!pc.need_resched) return frame;
    return reschedule(frame);
}

/// An IPI from another core asking this one to look at its run queue.
pub fn onRescheduleIpi(_: u32) void {
    percpu.this().need_resched = true;
}

// ---------------------------------------------------------------------------
// Thread API used by the kernel and the shell
// ---------------------------------------------------------------------------

pub fn running() *Thread {
    return percpu.this().current orelse @panic("sched: no current thread");
}

/// Create a thread that the scheduler will never migrate to another core.
pub fn spawnPinned(name: []const u8, entry: thread_mod.EntryFn, arg: ?*anyopaque) ?u32 {
    const id = spawnInner(name, entry, arg, true) orelse return null;
    return id;
}

pub fn spawn(name: []const u8, entry: thread_mod.EntryFn, arg: ?*anyopaque) ?u32 {
    return spawnInner(name, entry, arg, false);
}

fn spawnInner(name: []const u8, entry: thread_mod.EntryFn, arg: ?*anyopaque, pinned: bool) ?u32 {
    const a = alloc orelse return null;
    const t = thread_mod.create(a, name, entry, arg, @intFromPtr(&threadBootstrap)) orelse return null;
    const flags = lock.acquire();
    const pc = percpu.this();
    t.cpu = pc.id;
    t.pinned = pinned;
    t.on_cpu = false;
    pushTail(pc, t);
    pc.need_resched = true;
    pc.spawned += 1;
    lock.release(flags);
    return t.id;
}

/// Put a freshly created thread on this core's run queue.
pub fn admit(t: *Thread) void {
    const flags = lock.acquire();
    const pc = percpu.this();
    t.cpu = pc.id;
    t.on_cpu = false;
    pushTail(pc, t);
    pc.need_resched = true;
    pc.spawned += 1;
    lock.release(flags);
}

/// How many times a run-queue entry named a thread that was already on a CPU.
/// Always zero in a healthy system; the shell prints it so a regression in the
/// wake path shows up as a number instead of a mystery fault.
pub var double_run_events: u64 = 0;

/// Give up the CPU for the rest of this thread's slice (syscall 64). Returns
/// only once the thread is scheduled again.
pub fn yieldNow() void {
    asm volatile ("svc #64" ::: "memory");
}

/// Block from ordinary kernel code (not inside a syscall). Used by the shell.
pub fn sleepMsBlocking(ms: u64) void {
    sleepCurrent(ms);
    yieldNow();
}

/// Block for at least `ms` milliseconds (syscall 66).
pub fn sleepCurrent(ms: u64) void {
    const t = running();
    t.wake_at_ms = timer.uptimeMs() + ms;
    if (t.wake_at_ms == 0) t.wake_at_ms = 1;
    t.state = .blocked;
}

/// Terminate the calling thread (syscall 65). Never returns to it.
pub fn exitCurrent() noreturn {
    asm volatile ("svc #65" ::: "memory");
    unreachable;
}

pub fn markDead() void {
    running().state = .dead;
}

/// Ask a specific core to reschedule (used when a thread is woken remotely).
pub fn kick(id: u32) void {
    smp.sendRescheduleIpi(id);
}

pub fn threadCount() u32 {
    return thread_mod.liveCount();
}

pub fn find(id: u32) ?*Thread {
    return thread_mod.find(id);
}

test "slice is short enough for an interactive terminal" {
    try std.testing.expect(slice_ticks >= 1 and slice_ticks <= 10);
}
