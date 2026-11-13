//! Resource accounting (phase 29): the ledger and the watchdog.
//!
//! A till is shared: the checkout service, a printer daemon and whatever a
//! cashier's session started all run on the same memory. This module makes sure
//! no single one of them can take the machine away from the others, and that
//! when one tries the transcript says which process, which resource and by how
//! much.
//!
//! The policy (quotas, levels, OOM score, ladder) lives in `quota.zig` and is
//! host-tested. Enforcement happens at the three funnels where a resource is
//! actually handed out:
//!
//!   * `addrspace` refuses a frame past the process's page budget;
//!   * `cap` refuses a handle past its handle quota;
//!   * `sched` does not pick a throttled thread until its window reopens.
//!
//! One kernel thread samples every 100 ms. It never blocks on a process it
//! watches and never runs on an allocation or scheduling path, so a wedged or
//! spinning service cannot stop the accounting that is meant to catch it.

const std = @import("std");
const quota = @import("quota.zig");
const process = @import("process.zig");
const thread_mod = @import("thread.zig");
const cap = @import("cap.zig");
const sched = @import("sched.zig");
const klog = @import("klog.zig");
const timer = @import("../arch/aarch64/timer.zig");

pub const Quota = quota.Quota;
pub const Usage = quota.Usage;
pub const Level = quota.Level;
pub const Step = quota.Step;
pub const levelLabel = quota.levelLabel;

pub const max_entries: usize = 8;

pub const Entry = struct {
    used: bool = false,
    pid: u32 = 0,
    quota: Quota = .{},

    // Last sample.
    pages: u32 = 0,
    peak_pages: u32 = 0,
    handles: u32 = 0,
    cpu_window: u64 = 0,
    cpu_total: u64 = 0,
    cpu_base: u64 = 0,
    window_start: u64 = 0,
    score: u32 = 0,
    level: Level = .ok,

    strikes: u32 = 0,
    warnings: u32 = 0,
    throttles: u32 = 0,
    kills: u32 = 0,
    pressure: bool = false,
    sampled_ms: u64 = 0,
};

/// A copy of one process's accounting, for the `SYS_ACCOUNT` query.
pub const Snapshot = struct {
    pages: u32 = 0,
    handles: u32 = 0,
    cpu_ms: u64 = 0,
    level: Level = .ok,
    score: u32 = 0,
    /// Bit 0: the machine reported memory pressure during this process's life.
    flags: u64 = 0,
};

var entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries;

/// Monotonic for the life of the boot, so a probe can assert a path ran even
/// after the process it ran for has been reaped.
pub var samples: u64 = 0;
pub var warnings_total: u64 = 0;
pub var throttles_total: u64 = 0;
pub var kills_total: u64 = 0;
pub var pressures: u64 = 0;
/// Samples in which a process was over its *page* quota. Counted separately so
/// a page cap can be shown even when the funnel that would refuse an allocation
/// depends on an empty pool elsewhere.
pub var page_breaches: u64 = 0;
pub var pressure_victims: u64 = 0;

/// Free pages below this are reported as pressure. The default is a fraction of
/// the smallest machine Cassa targets; the probe raises it deliberately to
/// observe the path on a host with plenty of RAM.
pub var watermark_pages: usize = 256;
/// Below this, a process over its quota is killed on the spot instead of being
/// throttled first: waiting another window can fail an allocation for everyone.
pub var critical_pages: usize = 96;

pub fn init() void {
    // The capability table asks this module before installing a handle, so an
    // authority leak is bounded by the same policy as a page leak.
    cap.setHandleLimitHook(handleLimit);
}

fn threadFor(pid: u32) ?*thread_mod.Thread {
    const p = process.processOfPid(pid) orelse return null;
    if (p.state != .running) return null;
    return thread_mod.find(p.thread_id);
}

pub fn find(pid: u32) ?*Entry {
    for (&entries) |*e| {
        if (e.used and e.pid == pid) return e;
    }
    return null;
}

/// Start accounting for a process. Called by the process layer at creation, so
/// every EL0 process has a ledger before its first instruction runs.
pub fn attach(pid: u32, q: Quota) ?*Entry {
    if (find(pid)) |e| {
        e.quota = q;
        setPageBudget(pid, q.pages);
        return e;
    }
    for (&entries) |*e| {
        if (e.used) continue;
        e.* = .{ .used = true, .pid = pid, .quota = q, .window_start = timer.uptimeMs() };
        setPageBudget(pid, q.pages);
        return e;
    }
    return null;
}

pub fn detach(pid: u32) void {
    for (&entries) |*e| {
        if (e.used and e.pid == pid) e.* = .{};
    }
}

/// Re-quota a live process. Used when a service is launched with its own policy.
pub fn setQuota(pid: u32, q: Quota) bool {
    const e = find(pid) orelse return false;
    e.quota = q;
    setPageBudget(pid, q.pages);
    return true;
}

fn setPageBudget(pid: u32, pages: u32) void {
    const t = threadFor(pid) orelse return;
    const as = t.address_space orelse return;
    as.page_budget = pages;
}

/// Hook for `cap`: the number of handles this pid may hold.
pub fn handleLimit(pid: u32) u32 {
    const e = find(pid) orelse return std.math.maxInt(u32);
    return e.quota.handles;
}

pub fn snapshot(pid: u32) Snapshot {
    const e = find(pid) orelse return .{};
    var out = Snapshot{ .level = e.level, .score = e.score, .flags = if (e.pressure) 1 else 0 };
    // Answer with live numbers: a service asking about itself should not have to
    // wait for the next watchdog tick to learn it is over budget.
    if (threadFor(pid)) |t| {
        const pages: u32 = if (t.address_space) |as| @intCast(as.mappedPages()) else 0;
        const handles: u32 = @intCast(cap.handleCount(pid));
        const used = t.cpu_ms - e.cpu_base;
        const usage = Usage{ .pages = pages, .handles = handles, .cpu_ms = used };
        out.pages = pages;
        out.handles = handles;
        out.cpu_ms = used;
        out.level = quota.level(usage, e.quota);
        out.score = quota.oomScore(usage, e.quota);
    }
    return out;
}

// ---------------------------------------------------------------------------
// The watchdog
// ---------------------------------------------------------------------------

/// One sample of every live process. Public so the shell can force a sample
/// (`accounting sample`) instead of waiting for the next tick.
pub fn tick() void {
    const now = timer.uptimeMs();
    samples += 1;

    for (&entries) |*e| {
        if (!e.used) continue;
        const t = threadFor(e.pid) orelse continue;
        const as = t.address_space;
        const pages: u32 = if (as) |s| @intCast(s.mappedPages()) else 0;
        const handles: u32 = @intCast(cap.handleCount(e.pid));
        const total = t.cpu_ms;

        // The CPU window rolls: `cpu_window` is what the process used since the
        // window opened, which is the number a fair share is about.
        if (now >= e.window_start + e.quota.window_ms) {
            e.window_start = now;
            e.cpu_base = total;
        }
        const used_ms = total - e.cpu_base;

        e.pages = pages;
        e.handles = handles;
        e.cpu_total = total;
        e.cpu_window = used_ms;
        if (pages > e.peak_pages) e.peak_pages = pages;
        if (pages > e.quota.pages) page_breaches += 1;
        const usage = Usage{ .pages = pages, .handles = handles, .cpu_ms = used_ms };
        e.score = quota.oomScore(usage, e.quota);
        e.level = quota.level(usage, e.quota);
        e.sampled_ms = now;

        switch (quota.escalate(e.level, e.strikes)) {
            .none => {
                if (e.level == .ok and e.strikes > 0) e.strikes -= 1;
            },
            .warn => {
                e.strikes += 1;
                e.warnings += 1;
                warnings_total += 1;
                klog.warn("acct", "pid {d}: {s} quota — pages {d}/{d}, handles {d}/{d}, cpu {d}/{d} ms, oom score {d}", .{
                    e.pid, quota.levelLabel(e.level), pages, e.quota.pages, handles, e.quota.handles,
                    used_ms, e.quota.cpu_ms, e.score,
                });
            },
            .throttle => {
                e.strikes += 1;
                e.throttles += 1;
                throttles_total += 1;
                // The thread stays ready and in its queue; the scheduler simply
                // does not pick it until the window reopens. Nothing is blocked
                // and no wake is lost.
                t.throttled_until_ms = now + e.quota.window_ms;
                klog.warn("acct", "pid {d}: throttled for {d} ms (cpu {d}/{d} ms, oom score {d})", .{
                    e.pid, e.quota.window_ms, used_ms, e.quota.cpu_ms, e.score,
                });
            },
            .kill => {
                e.strikes += 1;
                e.kills += 1;
                kills_total += 1;
                klog.warn("acct", "pid {d}: killed by the watchdog after {d} strikes (pages {d}/{d}, handles {d}/{d}, cpu {d}/{d} ms)", .{
                    e.pid, e.strikes, pages, e.quota.pages, handles, e.quota.handles,
                    used_ms, e.quota.cpu_ms,
                });
                _ = process.kill(e.pid);
            },
        }
    }

    pressureCheck();
}

/// Report (and, past the critical mark, act on) memory pressure. A victim is
/// chosen by OOM score, so the process closest to — or furthest past — its own
/// budget is the one named, not simply the largest.
fn pressureCheck() void {
    const alloc = process.pageAllocator() orelse return;
    const free = alloc.stats().free_pages;
    if (free >= watermark_pages) return;
    pressures += 1;
    var victim: ?*Entry = null;
    for (&entries) |*e| {
        if (!e.used) continue;
        e.pressure = true;
        if (victim == null or e.score > victim.?.score) victim = e;
    }
    if (victim) |v| {
        klog.warn("acct", "memory pressure: {d} pages free (< {d}), victim pid {d} score {d} level {s}", .{
            free, watermark_pages, v.pid, v.score, quota.levelLabel(v.level),
        });
        if (free < critical_pages and v.score > 500) {
            klog.warn("acct", "memory critical: killing pid {d} to keep the till serving", .{v.pid});
            pressure_victims += 1;
            _ = process.kill(v.pid);
        }
    } else {
        klog.warn("acct", "memory pressure: {d} pages free (< {d}), no process to charge", .{ free, watermark_pages });
    }
}

/// The watchdog thread: one sample every 100 ms, then sleep.
pub fn watchdogLoop(_: ?*anyopaque) void {
    while (true) {
        tick();
        sched.sleepMsBlocking(100);
    }
}

pub fn entryAt(index: usize) ?*const Entry {
    if (index >= entries.len) return null;
    if (!entries[index].used) return null;
    return &entries[index];
}

/// Forget every entry. Only used by the host self-test, where the table starts
/// empty for each run.
pub fn resetForTest() void {
    entries = [_]Entry{.{}} ** max_entries;
}
