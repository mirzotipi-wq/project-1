//! Restart policy (phase 27).
//!
//! The decision logic for a supervised service is pure: given how many times it
//! has failed, how long it ran, and its policy, it says whether to restart now,
//! wait, or give up. Keeping it out of the kernel lets a crash-loop rule be
//! unit-tested on the host instead of discovered on a serial line.
//!
//! Two rules make a crash loop survivable:
//!
//!   * backoff grows with the number of consecutive failures, so a service that
//!     dies instantly is not restarted in a tight loop that starves the till;
//!   * a service that stays up for `stable_ms` is considered healthy again, so a
//!     machine that crashed once at boot is not permanently "failing".

const std = @import("std");

pub const State = enum { stopped, running, restarting, failed };

pub const Policy = struct {
    /// Consecutive failures tolerated before the service is parked.
    max_restarts: u32 = 6,
    /// First delay, doubled on every consecutive failure.
    base_ms: u64 = 5,
    /// Ceiling for the delay, so a restart is never hours away.
    max_delay_ms: u64 = 160,
    /// Uptime after which the failure count is forgiven.
    stable_ms: u64 = 250,
};

pub const Decision = struct {
    state: State,
    delay_ms: u64 = 0,
};

/// Delay before restart number `failures` (1-based). 5, 10, 20, 40 ... capped.
pub fn backoffMs(policy: Policy, failures: u32) u64 {
    if (failures == 0) return 0;
    const shift: u6 = @intCast(@min(failures - 1, 5));
    var delay = policy.base_ms << shift;
    if (delay > policy.max_delay_ms) delay = policy.max_delay_ms;
    return delay;
}

/// A service died unexpectedly: decide what to do about it.
pub fn afterFailure(policy: Policy, failures: u32) Decision {
    if (failures >= policy.max_restarts) return .{ .state = .failed };
    return .{ .state = .restarting, .delay_ms = backoffMs(policy, failures) };
}

/// A service that has been up long enough is no longer "failing".
pub fn failuresAfterUptime(policy: Policy, failures: u32, uptime_ms: u64) u32 {
    if (uptime_ms >= policy.stable_ms) return 0;
    return failures;
}

test "backoff doubles and then stays capped" {
    const p = Policy{ .base_ms = 5, .max_delay_ms = 40 };
    try std.testing.expectEqual(@as(u64, 0), backoffMs(p, 0));
    try std.testing.expectEqual(@as(u64, 5), backoffMs(p, 1));
    try std.testing.expectEqual(@as(u64, 10), backoffMs(p, 2));
    try std.testing.expectEqual(@as(u64, 20), backoffMs(p, 3));
    try std.testing.expectEqual(@as(u64, 40), backoffMs(p, 4));
    try std.testing.expectEqual(@as(u64, 40), backoffMs(p, 9));
}

test "the crash loop trips at max_restarts and not before" {
    const p = Policy{ .max_restarts = 3 };
    try std.testing.expectEqual(State.restarting, afterFailure(p, 1).state);
    try std.testing.expectEqual(State.restarting, afterFailure(p, 2).state);
    try std.testing.expectEqual(State.failed, afterFailure(p, 3).state);
    try std.testing.expectEqual(State.failed, afterFailure(p, 4).state);
}

test "a stable run forgives the failures" {
    const p = Policy{ .stable_ms = 250 };
    try std.testing.expectEqual(@as(u32, 3), failuresAfterUptime(p, 3, 249));
    try std.testing.expectEqual(@as(u32, 0), failuresAfterUptime(p, 3, 250));
    try std.testing.expectEqual(@as(u32, 0), failuresAfterUptime(p, 3, 60_000));
}
