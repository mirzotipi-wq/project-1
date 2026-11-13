//! Service registry (phase 28).
//!
//! The supervisor knows services by a compiled-in name; an application knows the
//! shop's devices by *their* names — `pos://printer`, `pos://checkout`. This table
//! is the mapping between the two, and the only place a name becomes an identity.
//!
//! Three properties matter more than the lookup itself:
//!
//!   * a name is validated before it is looked up, so `Printer` is a refusal and
//!     not a miss that quietly reads as "no printer in this shop";
//!   * every answer is a *reason*, never an ambient error: unknown, stopped,
//!     restarting, crash-loop parked, exited;
//!   * the answer carries the service's generation, which changes on every start,
//!     so a caller that resolved and then used a pid can tell that the service was
//!     restarted underneath it instead of talking to a recycled pid.
//!
//! The table is fixed (eight names, matching the four service slots with room for
//! aliases) and duplicates are refused, so registration cannot grow without bound.

const std = @import("std");
const service = @import("service.zig");
const process = @import("process.zig");
const names = @import("names.zig");
const sync = @import("sync.zig");
const timer = @import("../arch/aarch64/timer.zig");
const klog = @import("klog.zig");

pub const max_names = 8;

pub const Entry = struct {
    used: bool = false,
    name: [names.max_len]u8 = [_]u8{0} ** names.max_len,
    len: u8 = 0,
    /// The supervisor's name for the service, e.g. "printer".
    target: []const u8 = "",
    lookups: u64 = 0,
    registered_ms: u64 = 0,

    pub fn storedName(self: *const Entry) []const u8 {
        return self.name[0..self.len];
    }
};

var table: [max_names]Entry = [_]Entry{.{}} ** max_names;
var lock = sync.IrqSpinLock{};

pub var registers: u64 = 0;
pub var lookups: u64 = 0;
pub var hits: u64 = 0;
pub var refusals: u64 = 0;
pub var lazy_starts: u64 = 0;

pub const Resolved = struct {
    reason: names.Reason,
    name: []const u8,
    pid: u32 = 0,
    generation: u32 = 0,
};

pub fn count() usize {
    const flags = lock.acquire();
    defer lock.release(flags);
    var n: usize = 0;
    for (&table) |*e| {
        if (e.used) n += 1;
    }
    return n;
}

pub fn entryAt(index: usize) ?*const Entry {
    if (index >= max_names) return null;
    const flags = lock.acquire();
    defer lock.release(flags);
    const e = &table[index];
    if (!e.used) return null;
    return e;
}

fn findLocked(name: []const u8) ?*Entry {
    for (&table) |*e| {
        if (e.used and std.mem.eql(u8, e.storedName(), name)) return e;
    }
    return null;
}

/// Bind a name to a service already known to the supervisor. The service must
/// exist: a name that points at nothing is a manifest error, refused here rather
/// than turning into a mystery at the call site later.
pub fn register(name: []const u8, target: []const u8) names.Reason {
    if (!names.valid(name)) return .invalid_name;
    if (service.find(target) == null) return .unknown;
    const flags = lock.acquire();
    defer lock.release(flags);
    if (findLocked(name) != null) {
        refusals += 1;
        return .duplicate;
    }
    for (&table) |*e| {
        if (e.used) continue;
        e.used = true;
        e.len = @intCast(name.len);
        @memcpy(e.name[0..name.len], name);
        e.target = target;
        e.lookups = 0;
        e.registered_ms = timer.uptimeMs();
        registers += 1;
        klog.info("reg", "registered {s} -> service '{s}'", .{ name, target });
        return .ok;
    }
    refusals += 1;
    return .full;
}

fn lifecycleOf(s: *const service.Service) names.Lifecycle {
    return switch (s.state) {
        .running => .running,
        .restarting => .restarting,
        .failed => .failed,
        .stopped => .stopped,
    };
}

/// Take a snapshot of one service, translating its lifecycle into the reason a
/// caller sees. Reading the service without the registry lock is deliberate: the
/// answer is a snapshot, and the generation is what makes a stale snapshot
/// detectable. Taking a lock the supervisor also takes would make a lookup able
/// to block behind a restart.
fn describe(stored: []const u8, target: []const u8, reason_out: *names.Reason, pid_out: *u32, gen_out: *u32) void {
    const svc = service.find(target) orelse {
        reason_out.* = .unknown;
        return;
    };
    const alive = svc.pid != 0 and process.stateOf(svc.pid) == .running;
    reason_out.* = names.reasonFor(lifecycleOf(svc), alive);
    pid_out.* = svc.pid;
    gen_out.* = svc.generation;
    _ = stored;
}

pub fn lookup(name: []const u8) Resolved {
    var r = Resolved{ .reason = .invalid_name, .name = name };
    if (!names.valid(name)) {
        const flags = lock.acquire();
        lookups += 1;
        refusals += 1;
        lock.release(flags);
        return r;
    }
    const flags = lock.acquire();
    lookups += 1;
    const e = findLocked(name) orelse {
        refusals += 1;
        lock.release(flags);
        r.reason = .unknown;
        return r;
    };
    e.lookups += 1;
    const stored = e.storedName();
    const target = e.target;
    lock.release(flags);

    var reason: names.Reason = .unknown;
    var pid: u32 = 0;
    var gen: u32 = 0;
    describe(stored, target, &reason, &pid, &gen);

    const flags2 = lock.acquire();
    if (reason == .ok) hits += 1 else refusals += 1;
    lock.release(flags2);

    return .{ .reason = reason, .name = stored, .pid = pid, .generation = gen };
}

/// Resolve, starting the service if it is registered but down. A parked crash
/// loop is *not* started: the policy parked it, and one call site does not get to
/// overrule the policy. It gets `.failed` and has to cope.
pub fn ensure(name: []const u8) Resolved {
    const first = lookup(name);
    if (first.reason != .stopped) return first;
    const target = blk: {
        const flags = lock.acquire();
        defer lock.release(flags);
        const e = findLocked(name) orelse break :blk null;
        break :blk e.target;
    };
    const t = target orelse return first;
    if (!service.start(t)) return first;
    lazy_starts += 1;
    klog.info("reg", "lazy start {s} -> service '{s}'", .{ name, t });
    return lookup(name);
}
