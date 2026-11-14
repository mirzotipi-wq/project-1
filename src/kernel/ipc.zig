//! IPC endpoints (phase 24).
//!
//! An endpoint is a kernel object two processes meet on. One side sends a
//! request, the other receives it and answers. Both sides reach the object only
//! through a capability handle, so an endpoint nobody granted you is not
//! reachable by guessing a number.
//!
//! The kernel copies every message itself, into the receiving process's own
//! buffer while that process's address space is loaded. No process ever holds a
//! pointer into another process's memory, and no message depends on one.
//!
//! Blocking is a loop inside the syscall that parks the thread (`blocked` plus
//! an optional timer deadline) and yields. Waking is a state transition plus a
//! run-queue push: the sleeper re-reads the endpoint when it runs again. Nothing
//! polls, and a thread that is not runnable is not on any run queue, which is
//! what "a blocked receiver never spins" means in measurable terms.
//!
//! One endpoint holds at most one request and one reply. That is the whole
//! backpressure story: a second sender parks until the slot is free or its
//! deadline expires, rather than growing a queue in kernel memory nobody
//! accounted for.

const std = @import("std");
const cap = @import("cap.zig");
const klog = @import("klog.zig");
const sched = @import("sched.zig");
const thread_mod = @import("thread.zig");
const user_space = @import("addrspace.zig");
const sync = @import("sync.zig");
const timer = @import("../arch/aarch64/timer.zig");

pub const msg_size: usize = 64;
pub const max_endpoints: usize = 8;

/// Exactly one cache-line-sized message, carried inline.
pub const Message = extern struct {
    tag: u64 = 0,
    words: [7]u64 = [_]u64{0} ** 7,
};

pub const Error = error{
    BadHandle,
    Permission,
    Invalid,
    Fault,
    Timeout,
    Again,
    NoMemory,
    TableFull,
};

/// `.done` carries the syscall's two results (value and, for a receive, the
/// handle that travelled with the message); `.block` means the caller already
/// parked itself and the syscall layer must reschedule instead of returning.
pub const Result = struct { value: u64 = 0, extra: u64 = 0 };
pub const Outcome = union(enum) { done: Result, block };

pub var sends: u64 = 0;
pub var receives: u64 = 0;
pub var replies: u64 = 0;
pub var timeouts: u64 = 0;
/// Replies the kernel refused to deliver: nothing owed, or the caller's
/// deadline had already passed.
pub var late_replies: u64 = 0;
pub var full_events: u64 = 0;
pub var transfers: u64 = 0;
pub var transfer_failures: u64 = 0;

const Endpoint = struct {
    used: bool = false,
    object_id: u32 = 0,

    /// Request in flight: sender to receiver.
    req_valid: bool = false,
    req: Message = .{},
    req_from: u32 = 0,
    req_transfer: u64 = 0,
    req_is_call: bool = false,
    /// Caller waiting for the answer, while the request is still queued.
    req_thread: ?*thread_mod.Thread = null,

    /// Request sequence. Bumped for every call, and copied into `recv_seq` when
    /// the receiver takes that call, so an answer can be tied to the exact call
    /// it belongs to. A thread identity cannot do that: the same thread makes the
    /// next call, and an answer that arrives late would otherwise be delivered
    /// to it as if it were the answer to the newer request.
    req_seq: u32 = 0,
    recv_seq: u32 = 0,
    rep_seq: u32 = 0,

    /// Reply in flight: receiver back to the caller.
    rep_valid: bool = false,
    rep: Message = .{},
    rep_to: ?*thread_mod.Thread = null,
    /// Set when a request has been taken and an answer is still owed.
    reply_owed: bool = false,
    reply_target: ?*thread_mod.Thread = null,

    /// Whoever is parked on each role, with their absolute deadline.
    recv_thread: ?*thread_mod.Thread = null,
    recv_deadline: u64 = 0,
    send_thread: ?*thread_mod.Thread = null,
    send_deadline: u64 = 0,
    reply_thread: ?*thread_mod.Thread = null,
    reply_deadline: u64 = 0,

    /// A reply with no caller left to take it.
    replied_to_nobody: u64 = 0,
};

/// IRQ-safe: a timer interrupt that preempts a core inside one of these
/// sections must not be able to spin on the same lock.
var lock: sync.IrqSpinLock = .{};
var endpoints: [max_endpoints]Endpoint = [_]Endpoint{.{}} ** max_endpoints;
var bootstrap_id: u32 = 0;

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

/// Create the bootstrap endpoint every IPC process is born holding. It exists so
/// a server can hand its own endpoint to a client: the first transfer needs a
/// channel both sides already have.
pub fn init() void {
    const object = cap.create(.endpoint, "endpoint") orelse return;
    bootstrap_id = object.id;
    for (&endpoints) |*e| {
        if (e.used) continue;
        e.* = .{ .used = true, .object_id = object.id };
        return;
    }
}

pub fn bootstrapObjectId() u32 {
    return bootstrap_id;
}

fn endpointFor(object_id: u32, create_it: bool) ?*Endpoint {
    for (&endpoints) |*e| {
        if (e.used and e.object_id == object_id) return e;
    }
    if (!create_it) return null;
    for (&endpoints) |*e| {
        if (e.used) continue;
        e.* = .{ .used = true, .object_id = object_id };
        return e;
    }
    return null;
}

/// Create a fresh endpoint and hand the caller a handle to it.
pub fn create(pid: u32) Error!u64 {
    const object = cap.create(.endpoint, "endpoint") orelse return Error.NoMemory;
    const flags = lock.acquire();
    const ok = endpointFor(object.id, true) != null;
    lock.release(flags);
    if (!ok) return Error.NoMemory;
    return cap.grant(pid, object.id, cap.R_READ | cap.R_WRITE | cap.R_CONTROL) catch Error.TableFull;
}

fn mapCapError(e: cap.Error) Error {
    return switch (e) {
        error.BadHandle => Error.BadHandle,
        error.Permission => Error.Permission,
        error.TableFull => Error.TableFull,
        error.Invalid => Error.Invalid,
    };
}

/// Resolve a handle to an endpoint, requiring `need` rights on it.
fn resolve(pid: u32, handle: u64, need: u32) Error!*Endpoint {
    const object = cap.access(pid, handle, need) catch |e| return mapCapError(e);
    if (object.kind != .endpoint) return Error.Invalid;
    return endpointFor(object.id, true) orelse Error.Invalid;
}

// ---------------------------------------------------------------------------
// Message copies (always in the caller's own context)
// ---------------------------------------------------------------------------

fn readMessage(as: *const user_space.AddressSpace, va: usize) Error!Message {
    if (!user_space.checkPtr(as, va, msg_size, .read)) return Error.Fault;
    var msg: Message = .{};
    const src: [*]const u8 = @ptrFromInt(va);
    @memcpy(std.mem.asBytes(&msg), src[0..msg_size]);
    return msg;
}

fn writeMessage(as: *const user_space.AddressSpace, va: usize, msg: Message) Error!void {
    if (!user_space.checkPtr(as, va, msg_size, .write)) return Error.Fault;
    const dst: [*]u8 = @ptrFromInt(va);
    @memcpy(dst[0..msg_size], std.mem.asBytes(&msg));
}

// ---------------------------------------------------------------------------
// Waiting
// ---------------------------------------------------------------------------

fn deadlineOf(timeout_ms: u64) u64 {
    if (timeout_ms == 0) return 0; // no deadline
    return timer.uptimeMs() + timeout_ms;
}

fn expired(deadline: u64) bool {
    return deadline != 0 and timer.uptimeMs() >= deadline;
}

/// Park the current thread until someone makes it ready or its deadline fires.
/// The thread must already be marked blocked by the caller, under the lock, so
/// that a waker on another core can never miss it.
fn park(deadline: u64) void {
    const t = sched.running();
    t.wake_at_ms = deadline; // 0 means: only a wakeup can release me
    sched.yieldNow();
}

fn wakeUp(t: ?*thread_mod.Thread) void {
    if (t) |w| sched.makeReady(w);
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/// Send one message and return. Parks only if the request slot is occupied,
/// which is the backpressure case.
pub fn send(
    pid: u32,
    as: *const user_space.AddressSpace,
    handle: u64,
    msg_va: usize,
    timeout_ms: u64,
    transfer: u64,
) Error!Outcome {
    const msg = try readMessage(as, msg_va);
    if (transfer != 0) cap.checkTransferable(pid, transfer) catch |e| return mapCapError(e);
    const ep = try resolve(pid, handle, cap.R_WRITE);
    const t = sched.running();
    const deadline = deadlineOf(timeout_ms);

    while (true) {
        const flags = lock.acquire();
        sweep(ep);
        if (!ep.req_valid) {
            ep.req = msg;
            ep.req_valid = true;
            ep.req_from = pid;
            ep.req_transfer = transfer;
            ep.req_is_call = false;
            ep.req_thread = null;
            const waiter = ep.recv_thread;
            ep.recv_thread = null;
            ep.recv_deadline = 0;
            sends += 1;
            lock.release(flags);
            wakeUp(waiter);
            return .{ .done = .{} };
        }
        if (expired(deadline)) {
            full_events += 1;
            timeouts += 1;
            lock.release(flags);
            return Error.Timeout;
        }
        ep.send_thread = t;
        ep.send_deadline = deadline;
        t.state = .blocked;
        t.wake_at_ms = deadline;
        lock.release(flags);
        park(deadline);
    }
}

/// Send a request and wait for the answer. Blocks the caller for the whole
/// round trip, which is the common service-call shape.
pub fn call(
    pid: u32,
    as: *const user_space.AddressSpace,
    handle: u64,
    msg_va: usize,
    reply_va: usize,
    timeout_ms: u64,
    transfer: u64,
) Error!Outcome {
    const msg = try readMessage(as, msg_va);
    if (!user_space.checkPtr(as, reply_va, msg_size, .write)) return Error.Fault;
    if (transfer != 0) cap.checkTransferable(pid, transfer) catch |e| return mapCapError(e);
    const ep = try resolve(pid, handle, cap.R_WRITE);
    const t = sched.running();
    const deadline = deadlineOf(timeout_ms);
    var call_seq: u32 = 0;

    // Publish the request. A second caller waits here for the slot.
    while (true) {
        const flags = lock.acquire();
        sweep(ep);
        if (!ep.req_valid) {
            // A new call cannot have an answer yet: anything in the reply slot
            // belongs to an older call and must not be delivered to this one.
            if (ep.rep_valid) {
                ep.rep_valid = false;
                ep.rep_to = null;
            }
            ep.req = msg;
            ep.req_valid = true;
            ep.req_from = pid;
            ep.req_transfer = transfer;
            ep.req_is_call = true;
            ep.req_thread = t;
            // Record the caller's deadline now: the server may answer after the
            // caller has already given up, and that answer must be refused.
            ep.reply_deadline = deadline;
            ep.req_seq +%= 1;
            call_seq = ep.req_seq;
            const waiter = ep.recv_thread;
            ep.recv_thread = null;
            ep.recv_deadline = 0;
            sends += 1;
            lock.release(flags);
            wakeUp(waiter);
            break;
        }
        if (expired(deadline)) {
            full_events += 1;
            timeouts += 1;
            lock.release(flags);
            return Error.Timeout;
        }
        ep.send_thread = t;
        ep.send_deadline = deadline;
        t.state = .blocked;
        t.wake_at_ms = deadline;
        lock.release(flags);
        park(deadline);
    }

    // Wait for the answer. Checking before parking is what makes a reply that
    // arrived during the publish impossible to lose.
    while (true) {
        const flags = lock.acquire();
        if (ep.rep_valid and ep.rep_to == t and ep.rep_seq == call_seq) {
            const answer = ep.rep;
            ep.rep_valid = false;
            ep.rep_to = null;
            ep.reply_thread = null;
            ep.reply_deadline = 0;
            lock.release(flags);
            try writeMessage(as, reply_va, answer);
            replies += 1;
            return .{ .done = .{ .value = msg_size } };
        }
        if (expired(deadline)) {
            // Give the request back if nobody has taken it: a timed-out call
            // must not surface later as a phantom request.
            if (ep.req_valid and ep.req_thread == t) {
                ep.req_valid = false;
                ep.req_thread = null;
                ep.req_transfer = 0;
            }
            // Leave the deadline behind: a reply that arrives now must be
            // refused rather than handed to the next call.
            ep.reply_thread = null;
            timeouts += 1;
            lock.release(flags);
            return Error.Timeout;
        }
        ep.reply_thread = t;
        ep.reply_deadline = deadline;
        t.state = .blocked;
        t.wake_at_ms = deadline;
        lock.release(flags);
        park(deadline);
    }
}

/// Take one message out of the endpoint. Parks while there is nothing to take.
pub fn recv(
    pid: u32,
    as: *const user_space.AddressSpace,
    handle: u64,
    buf_va: usize,
    timeout_ms: u64,
) Error!Outcome {
    if (!user_space.checkPtr(as, buf_va, msg_size, .write)) return Error.Fault;
    const ep = try resolve(pid, handle, cap.R_READ);
    const t = sched.running();
    const deadline = deadlineOf(timeout_ms);

    while (true) {
        const flags = lock.acquire();
        sweep(ep);
        if (ep.req_valid) {
            const msg = ep.req;
            const from = ep.req_from;
            const xfer = ep.req_transfer;
            const was_call = ep.req_is_call;
            const caller = ep.req_thread;
            ep.req_valid = false;
            ep.req = .{};
            ep.req_transfer = 0;
            ep.req_thread = null;
            if (was_call) {
                ep.reply_owed = true;
                ep.reply_target = caller;
                ep.recv_seq = ep.req_seq;
            }
            receives += 1;
            // The request slot is free again: whoever was blocked on it may go.
            const sender = ep.send_thread;
            ep.send_thread = null;
            ep.send_deadline = 0;
            lock.release(flags);
            wakeUp(sender);

            try writeMessage(as, buf_va, msg);
            var installed: u64 = 0;
            if (xfer != 0) {
                if (cap.transfer(from, pid, xfer)) |h| {
                    installed = h;
                    transfers += 1;
                } else |_| {
                    transfer_failures += 1;
                }
            }
            return .{ .done = .{ .value = msg_size, .extra = installed } };
        }
        if (expired(deadline)) {
            timeouts += 1;
            lock.release(flags);
            return Error.Timeout;
        }
        ep.recv_thread = t;
        ep.recv_deadline = deadline;
        t.state = .blocked;
        t.wake_at_ms = deadline;
        lock.release(flags);
        park(deadline);
    }
}

/// Answer the request that was last taken from this endpoint.
pub fn reply(
    pid: u32,
    as: *const user_space.AddressSpace,
    handle: u64,
    msg_va: usize,
) Error!Outcome {
    const msg = try readMessage(as, msg_va);
    const ep = try resolve(pid, handle, cap.R_WRITE);

    const flags = lock.acquire();
    sweep(ep);
    if (!ep.reply_owed or ep.reply_target == null) {
        ep.replied_to_nobody += 1;
        late_replies += 1;
        klog.debug("ipc", "reply refused: nothing owed (recv_seq {d}, req_seq {d})", .{ ep.recv_seq, ep.req_seq });
        lock.release(flags);
        return Error.Again;
    }
    const target = ep.reply_target.?;
    // A caller whose deadline has passed is gone, whether or not its thread has
    // run yet. It is going to return ETIMEDOUT from `call`; handing it this
    // answer would turn that timeout into a success, and leaving the answer in
    // `rep_valid` would let the same thread's *next* call — which has the same
    // identity — take it as its own reply. Both are decided by the deadline
    // alone, so the refusal cannot depend on which thread happens to run first.
    // A call whose deadline passed is over even if its caller has not run yet:
    // it will return ETIMEDOUT, and handing it this answer would turn that into
    // a success. Decided by the deadline alone, never by which thread runs first.
    if (ep.reply_deadline != 0 and expired(ep.reply_deadline)) {
        klog.debug("ipc", "reply refused as late: deadline {d} now {d}, seq {d}", .{ ep.reply_deadline, timer.uptimeMs(), ep.recv_seq });
        ep.reply_owed = false;
        ep.reply_target = null;
        if (ep.reply_thread == target) {
            ep.reply_thread = null;
        }
        ep.replied_to_nobody += 1;
        late_replies += 1;
        lock.release(flags);
        return Error.Again;
    }
    ep.reply_owed = false;
    ep.reply_target = null;
    ep.rep = msg;
    ep.rep_valid = true;
    ep.rep_to = target;
    ep.rep_seq = ep.recv_seq;
    // If the caller is waiting on *this* call, hand it over now; if it is still
    // on its way into the wait it will find the reply when it gets there. A
    // caller that has already published a newer call must not be woken by an
    // older answer: the answer stays in the slot, the caller's wait matches on
    // the sequence, and the newer answer replaces it when it arrives.
    if (ep.reply_thread == target and ep.recv_seq == ep.req_seq) {
        ep.reply_thread = null;
        ep.reply_deadline = 0;
    }
    replies += 1;
    lock.release(flags);
    sched.makeReady(target);
    return .{ .done = .{} };
}

// ---------------------------------------------------------------------------
// Housekeeping
// ---------------------------------------------------------------------------

/// Drop waiters whose deadline has passed, and answers nobody is waiting for.
/// Called under the lock at the start of every operation, so a stale record can
/// never be mistaken for a live one.
fn sweep(ep: *Endpoint) void {
    if (ep.recv_thread != null and expired(ep.recv_deadline)) {
        ep.recv_thread = null;
        ep.recv_deadline = 0;
        timeouts += 1;
    }
    if (ep.send_thread != null and expired(ep.send_deadline)) {
        ep.send_thread = null;
        ep.send_deadline = 0;
        timeouts += 1;
    }
    if (ep.reply_thread != null and expired(ep.reply_deadline)) {
        // The parked caller is not waiting any more, but its deadline stays on
        // the endpoint: that is what makes the answer it is about to miss be
        // refused as late instead of accepted for a caller returning ETIMEDOUT.
        ep.reply_thread = null;
    }
    if (ep.rep_valid) {
        if (ep.rep_to) |t| {
            if (t.state == .dead) {
                ep.rep_valid = false;
                ep.rep_to = null;
            }
        }
    }
    if (ep.req_valid) {
        if (ep.req_thread) |t| {
            if (t.state == .dead) {
                ep.req_valid = false;
                ep.req_thread = null;
                ep.req_transfer = 0;
            }
        }
    }
}

pub fn liveEndpoints() u32 {
    var n: u32 = 0;
    for (&endpoints) |*e| {
        if (e.used) n += 1;
    }
    return n;
}

pub fn endpointSlots() usize {
    return endpoints.len;
}

pub fn endpointAt(index: usize) ?*const Endpoint {
    if (index >= endpoints.len) return null;
    if (!endpoints[index].used) return null;
    return &endpoints[index];
}
