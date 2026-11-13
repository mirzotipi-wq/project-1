//! Process registry (phases 21-22).
//!
//! A process here is deliberately thin: one address space, one EL0 thread and a
//! small record of how it ended. That is enough to answer every question the
//! shell and the fault path need to ask — who is running, what did it exit
//! with, and what killed it — without inventing a file table or a parent/child
//! relationship that nothing uses yet.

const std = @import("std");
const user_space = @import("addrspace.zig");
const sched = @import("sched.zig");
const thread_mod = @import("thread.zig");
const trap = @import("../arch/aarch64/trap.zig");
const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const cap = @import("cap.zig");
const ipc = @import("ipc.zig");

pub const State = enum { free, running, exited, killed };

pub const Fault = struct {
    kind: []const u8,
    addr: u64,
    pc: u64,
};

pub const Process = struct {
    pid: u32 = 0,
    thread_id: u32 = 0,
    state: State = .free,
    exit_code: i64 = 0,
    fault: ?Fault = null,
};

pub const max_processes: usize = 8;

var table: [max_processes]Process = [_]Process{.{}} ** max_processes;
var next_pid: u32 = 100;
var alloc: ?*pmm.PageAllocator = null;

pub var spawns: u32 = 0;
pub var exits: u32 = 0;
pub var kills: u32 = 0;

pub fn init(p: *pmm.PageAllocator) void {
    alloc = p;
}

fn freeSlot() ?*Process {
    for (&table) |*p| {
        if (p.state == .free) return p;
        // A finished process becomes reusable once its thread and address space
        // have been reaped. The exit record survives as long as anyone can
        // still ask about it, which is what the probes rely on.
        if (p.state != .running and thread_mod.find(p.thread_id) == null) {
            // A dead process leaves no authority behind.
            cap.releaseProcess(p.pid);
            p.* = .{};
            return p;
        }
    }
    return null;
}

fn slotForThread(thread_id: u32) ?*Process {
    for (&table) |*p| {
        if (p.state != .free and p.thread_id == thread_id) return p;
    }
    return null;
}

fn slotForPid(pid: u32) ?*Process {
    for (&table) |*p| {
        if (p.state != .free and p.pid == pid) return p;
    }
    return null;
}

/// Which authority a new process is born with. The read-only profile exists so
/// the probe can show two holders of one object each bounded by their own mask.
pub const Profile = enum { full, read_only };

/// Launch the demo image at EL0 in a brand new address space.
pub fn spawn(mode: u64, secret: u64, name: []const u8) ?*Process {
    return spawnWith(mode, secret, name, .full, false);
}

pub fn spawnReadOnly(mode: u64, secret: u64, name: []const u8) ?*Process {
    return spawnWith(mode, secret, name, .read_only, false);
}

/// A process that is also born holding the bootstrap IPC endpoint. Only the
/// processes that are meant to talk to each other get it: an outsider does not.
pub fn spawnIpc(mode: u64, secret: u64, name: []const u8) ?*Process {
    return spawnWith(mode, secret, name, .full, true);
}

fn spawnWith(mode: u64, secret: u64, name: []const u8, profile: Profile, endpoint: bool) ?*Process {
    const a = alloc orelse return null;
    const slot = freeSlot() orelse return null;
    const image = @import("../user/image.zig").bytes;
    const as = user_space.create(a, image) orelse return null;
    user_space.setArgs(as, mode, secret);
    const t = thread_mod.createUser(a, name, as, user_space.code_va, as.stackTop()) orelse {
        user_space.destroy(a, as);
        return null;
    };
    slot.* = .{ .pid = next_pid, .thread_id = t.id, .state = .running };
    next_pid += 1;
    spawns += 1;

    // Authority is granted here and nowhere else: a process is born with
    // exactly these handles and can only ever narrow them.
    const caps: ?cap.Grants = switch (profile) {
        .full => cap.grantForProcess(slot.pid),
        .read_only => cap.grantReadOnlyProfile(slot.pid),
    };
    if (caps) |c| {
        user_space.setHandles(as, c.console, c.ledger, c.supervisor, c.page);
        if (endpoint) {
            const object = ipc.bootstrapObjectId();
            if (object != 0) {
                const h = cap.grant(slot.pid, object, cap.R_READ | cap.R_WRITE) catch 0;
                user_space.setEndpointHandle(as, h);
            }
        }
    } else {
        klog.warn("proc", "pid {d}: could not build a capability table", .{slot.pid});
    }
    // Report before the thread is runnable: it can exit, be reaped and have its
    // address space released before this function would otherwise return.
    klog.info("proc", "pid {d} '{s}': EL0 entry 0x{x}, stack 0x{x}, {d} KiB, mode {d}", .{
        slot.pid, name, user_space.code_va, as.stackTop(), as.bytes() / 1024, mode,
    });
    sched.admit(t);
    return slot;
}

pub fn pageAllocator() ?*pmm.PageAllocator {
    return alloc;
}

pub fn currentPid() u32 {
    const t = sched.running();
    if (slotForThread(t.id)) |p| return p.pid;
    return 0;
}

/// Called from the exit syscall. The thread dies here; its address space is
/// released when the scheduler reaps the stack it is still standing on.
pub fn exitCurrent(code: i64) void {
    const t = sched.running();
    if (slotForThread(t.id)) |p| {
        p.state = .exited;
        p.exit_code = code;
        exits += 1;
        klog.info("proc", "pid {d} exited with code {d}", .{ p.pid, code });
    }
    sched.markDead();
}

/// An exception taken by EL0 code. The process is terminated and the kernel
/// keeps running: nothing a user program can do is allowed to take the machine
/// down, and every attempted privilege escalation leaves a log line naming the
/// cause, the address and the program counter.
pub fn faultCurrent(frame: *trap.Frame, esr: u64, far: u64) *trap.Frame {
    const t = sched.running();
    const pid = currentPid();
    const kind = faultKind(esr);
    kills += 1;
    klog.warn("proc", "pid {d} faulted at EL0: {s} addr=0x{x} pc=0x{x} esr=0x{x}", .{
        pid, kind, far, frame.elr, esr,
    });
    if (slotForThread(t.id)) |p| {
        p.state = .killed;
        p.fault = .{ .kind = kind, .addr = far, .pc = frame.elr };
    }
    sched.markDead();
    return sched.reschedule(frame);
}

fn faultKind(esr: u64) []const u8 {
    const ec = (esr >> 26) & 0x3F;
    const fsc = esr & 0x3F;
    return switch (ec) {
        0x00 => "undefined instruction",
        0x03 => "trapped coprocessor access",
        0x07 => "trapped FP/SIMD access",
        0x11, 0x18 => "trapped system register access",
        0x20 => "instruction abort",
        0x22 => "pc alignment fault",
        0x24 => if (fsc >= 0b001100 and fsc <= 0b001111) "data abort (permission)" else "data abort (translation)",
        0x26 => "sp alignment fault",
        0x3C => "brk instruction",
        else => "unclassified exception",
    };
}

pub fn stateOf(pid: u32) State {
    if (slotForPid(pid)) |p| return p.state;
    return .free;
}

pub fn processOfPid(pid: u32) ?*Process {
    return slotForPid(pid);
}

/// Wait for a process to stop running. Returns the state it reached.
pub fn wait(pid: u32, timeout_ms: u64) State {
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 1) {
        const s = stateOf(pid);
        if (s != .running) return s;
        sched.sleepMsBlocking(1);
    }
    return stateOf(pid);
}

/// Wait until the thread is gone and its address space released, so callers can
/// compare the free-page counter without racing the reaper.
pub fn waitReaped(pid: u32, timeout_ms: u64) bool {
    const p = slotForPid(pid) orelse return true;
    const id = p.thread_id;
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 1) {
        if (thread_mod.find(id) == null) return true;
        sched.sleepMsBlocking(1);
    }
    return false;
}

pub fn liveCount() u32 {
    var n: u32 = 0;
    for (&table) |*p| {
        if (p.state == .running) n += 1;
    }
    return n;
}

test "state names are stable for the probe output" {
    try std.testing.expectEqualStrings("running", @tagName(State.running));
    try std.testing.expectEqualStrings("killed", @tagName(State.killed));
}
