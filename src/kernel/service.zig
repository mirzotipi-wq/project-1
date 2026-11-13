//! Service supervision (phase 27).
//!
//! A till survives because the things it depends on are supervised rather than
//! trusted. Each service is a record in the kernel — a name, an image, its
//! arguments and a restart policy — and one kernel thread walks that table every
//! few milliseconds: it notices a child that died, records why, decides whether
//! to restart it, and starts it again after a backoff. The supervisor never
//! blocks on a child, so a service that hangs or crashes cannot take the
//! supervisor with it, and a service that crashes in a loop is parked instead of
//! being restarted forever.
//!
//! Faults are already isolated by the kernel (a faulting EL0 program dies and the
//! machine keeps running); this layer is what turns that into a policy.

const std = @import("std");
const process = @import("process.zig");
const sched = @import("sched.zig");
const restart = @import("restart.zig");
const timer = @import("../arch/aarch64/timer.zig");
const klog = @import("klog.zig");

pub const max_services = 4;
pub const max_argv = 3;

pub const Service = struct {
    used: bool = false,
    name: []const u8 = "",
    image: []const u8 = "",
    argv: [max_argv][]const u8 = [_][]const u8{""} ** max_argv,
    argc: u8 = 0,
    state: restart.State = .stopped,
    pid: u32 = 0,
    failures: u32 = 0,
    restarts: u32 = 0,
    /// Bumped on every launch. A caller that resolved a service can compare it
    /// after the fact and learn that the pid it holds belongs to an older run.
    generation: u32 = 0,
    started_ms: u64 = 0,
    next_restart_ms: u64 = 0,
    last_code: i64 = 0,
    last_kind: []const u8 = "",
    last_delay_ms: u64 = 0,
    policy: restart.Policy = .{},
};

var table: [max_services]Service = [_]Service{.{}} ** max_services;
const env = [_][]const u8{ "POS_TERM=cassa-1", "POS_SERVICE=1" };

pub var starts: u64 = 0;
pub var restarts_total: u64 = 0;
pub var failures_total: u64 = 0;
pub var crash_loops: u64 = 0;
pub var stops: u64 = 0;
pub var reaps: u64 = 0;

pub fn find(name: []const u8) ?*Service {
    for (&table) |*s| {
        if (s.used and std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

pub fn register(name: []const u8, image: []const u8, argv: []const []const u8) ?*Service {
    if (find(name) != null) return find(name);
    for (&table) |*s| {
        if (s.used) continue;
        var srv = Service{ .used = true, .name = name, .image = image };
        var i: usize = 0;
        while (i < argv.len and i < max_argv) : (i += 1) {
            srv.argv[i] = argv[i];
            srv.argc += 1;
        }
        s.* = srv;
        return s;
    }
    return null;
}

fn launch(s: *Service) bool {
    const p = process.spawnElf(s.image, s.argv[0..s.argc], &env) orelse {
        s.state = .failed;
        return false;
    };
    s.pid = p.pid;
    s.state = .running;
    s.started_ms = timer.uptimeMs();
    s.generation += 1;
    starts += 1;
    return true;
}

pub fn start(name: []const u8) bool {
    const s = find(name) orelse return false;
    if (s.state == .running) return true;
    s.failures = 0;
    s.state = .stopped;
    return launch(s);
}

/// Kill the child. The supervisor sees the death and applies the restart policy,
/// which is what makes "kill it and watch it come back" a real test.
pub fn kill(name: []const u8) bool {
    const s = find(name) orelse return false;
    if (s.state != .running) return false;
    return process.kill(s.pid);
}

/// Take a service down on purpose: no restart, and its child is reaped.
pub fn stop(name: []const u8) bool {
    const s = find(name) orelse return false;
    if (s.state == .running) _ = process.kill(s.pid);
    s.state = .stopped;
    s.next_restart_ms = 0;
    stops += 1;
    return true;
}

pub fn poll() void {
    const now = timer.uptimeMs();
    for (&table) |*s| {
        if (!s.used) continue;
        switch (s.state) {
            .running => {
                const st = process.stateOf(s.pid);
                if (st == .running) {
                    // A service that stayed up long enough is healthy again.
                    if (s.failures != 0) {
                        s.failures = restart.failuresAfterUptime(s.policy, s.failures, now - s.started_ms);
                    }
                    continue;
                }
                if (process.processOfPid(s.pid)) |p| {
                    s.last_code = p.exit_code;
                    s.last_kind = if (p.fault) |f| f.kind else "";
                }
                _ = process.waitReaped(s.pid, 0);
                reaps += 1;
                failures_total += 1;
                s.failures += 1;
                const d = restart.afterFailure(s.policy, s.failures);
                s.state = d.state;
                s.last_delay_ms = d.delay_ms;
                s.next_restart_ms = now + d.delay_ms;
                if (d.state == .failed) {
                    crash_loops += 1;
                    klog.warn("svc", "'{s}' crash loop: {d} failures, parked", .{ s.name, s.failures });
                } else {
                    klog.info("svc", "'{s}' died (code {d}), restarting in {d} ms", .{
                        s.name, s.last_code, d.delay_ms,
                    });
                }
            },
            .restarting => {
                if (now >= s.next_restart_ms) {
                    if (launch(s)) {
                        s.restarts += 1;
                        restarts_total += 1;
                        klog.info("svc", "'{s}' restarted, pid {d} (restart {d})", .{
                            s.name, s.pid, s.failures,
                        });
                    }
                }
            },
            else => {
                // Orphan reaping: a child of a stopped or parked service leaves
                // no thread and no process record behind.
                if (s.pid != 0 and process.stateOf(s.pid) != .running) {
                    _ = process.waitReaped(s.pid, 0);
                    s.pid = 0;
                    reaps += 1;
                }
            },
        }
    }
}

/// The supervisor thread. It never waits on a child: it polls, then sleeps.
pub fn supervisorLoop(_: ?*anyopaque) void {
    while (true) {
        poll();
        sched.sleepMsBlocking(10);
    }
}

pub fn count() usize {
    var n: usize = 0;
    for (&table) |*s| {
        if (s.used) n += 1;
    }
    return n;
}

pub fn at(index: usize) ?*const Service {
    if (index >= max_services) return null;
    const s = &table[index];
    if (!s.used) return null;
    return s;
}

pub fn stateLabel(s: restart.State) []const u8 {
    return switch (s) {
        .stopped => "stopped",
        .running => "running",
        .restarting => "restarting",
        .failed => "failed",
    };
}
