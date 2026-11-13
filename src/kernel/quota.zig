//! Resource-quota policy (phase 29), pure and host-tested.
//!
//! Kept apart from `account.zig` on purpose: this file is arithmetic over three
//! numbers and nothing else, so the rules that decide when a process is warned,
//! slowed or killed can be tested on a workstation instead of inferred from a
//! serial log after a runaway service.

const std = @import("std");

/// Everything a process is allowed to use. The defaults are deliberately well
/// above what a POS service needs, so a normal boot never touches the ladder.
pub const Quota = struct {
    pages: u32 = 32,
    handles: u32 = 12,
    cpu_ms: u64 = 250,
    window_ms: u64 = 500,
};

pub const Usage = struct {
    pages: u32 = 0,
    handles: u32 = 0,
    cpu_ms: u64 = 0,
};

pub const Level = enum { ok, near, over };

/// What the watchdog does about a sample. Ordered by severity.
pub const Step = enum { none, warn, throttle, kill };

/// The "near" band starts here: 80 % of any quota.
pub const near_percent: u32 = 80;

fn permille(used: u64, limit: u64) u32 {
    if (limit == 0) return if (used > 0) 1000 else 0;
    // Saturate before multiplying: a runaway can report any u64, and the score
    // must clamp rather than trap on overflow in a debug build.
    if (used >= limit) return 1000;
    const p: u128 = (@as(u128, used) * 1000) / @as(u128, limit);
    return @intCast(@min(p, 1000));
}

/// `over` is a fact (a quota was exceeded); `near` is a warning band. Both are
/// decided by the worst of the three resources, because they are independent: a
/// process at 100 % of its handles is as much of a problem as one at 100 % of
/// its memory, even though the numbers are not comparable.
pub fn level(u: Usage, q: Quota) Level {
    if (u.pages > q.pages or u.handles > q.handles or u.cpu_ms > q.cpu_ms) return .over;
    const near: u32 = near_percent * 10;
    if (permille(u.pages, q.pages) >= near or
        permille(u.handles, q.handles) >= near or
        permille(u.cpu_ms, q.cpu_ms) >= near) return .near;
    return .ok;
}

/// How attractive this process is as an OOM victim, 0…1000. Memory dominates
/// (an OOM is about memory), then handles, then CPU. A process far past its page
/// quota and one exactly at it score the same, because past the limit the
/// absolute amount no longer changes the decision — both are over budget.
pub fn oomScore(u: Usage, q: Quota) u32 {
    const pages = (@as(u64, permille(u.pages, q.pages)) * 600) / 1000;
    const handles = (@as(u64, permille(u.handles, q.handles)) * 250) / 1000;
    const cpu = (@as(u64, permille(u.cpu_ms, q.cpu_ms)) * 150) / 1000;
    return @intCast(@min(pages + handles + cpu, 1000));
}

/// The escalation ladder. `strikes` is how many actions have already been taken
/// for this over-budget period:
///
///   0 → warn (report it, let it run)
///   1 → throttle (take the CPU away for a window)
///   2 → kill (it kept going after being slowed)
///
/// A process in the `near` band is warned once but never throttled: being close
/// to a limit is not a fault.
pub fn escalate(l: Level, strikes: u32) Step {
    return switch (l) {
        .ok => .none,
        .near => if (strikes == 0) .warn else .none,
        .over => switch (strikes) {
            0 => .warn,
            1 => .throttle,
            else => .kill,
        },
    };
}

pub fn levelLabel(l: Level) []const u8 {
    return switch (l) {
        .ok => "ok",
        .near => "near",
        .over => "over",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "level reports over before near, and near only in the band" {
    const q = Quota{ .pages = 10, .handles = 4, .cpu_ms = 100 };
    try std.testing.expectEqual(Level.ok, level(.{ .pages = 1, .handles = 1, .cpu_ms = 1 }, q));
    try std.testing.expectEqual(Level.near, level(.{ .pages = 8, .handles = 1, .cpu_ms = 1 }, q));
    try std.testing.expectEqual(Level.over, level(.{ .pages = 11, .handles = 1, .cpu_ms = 1 }, q));
    // A quota is a ceiling, not a target: exactly at it is still inside.
    try std.testing.expectEqual(Level.near, level(.{ .pages = 10, .handles = 1, .cpu_ms = 1 }, q));
    try std.testing.expectEqual(Level.over, level(.{ .pages = 1, .handles = 5, .cpu_ms = 1 }, q));
    try std.testing.expectEqual(Level.over, level(.{ .pages = 1, .handles = 1, .cpu_ms = 101 }, q));
}

test "a zero quota is a hard wall, not a division by zero" {
    const q = Quota{ .pages = 0, .handles = 0, .cpu_ms = 0 };
    try std.testing.expectEqual(Level.ok, level(.{}, q));
    try std.testing.expectEqual(Level.over, level(.{ .pages = 1 }, q));
    try std.testing.expectEqual(@as(u32, 600), oomScore(.{ .pages = 1 }, q));
}

test "oom score ranks memory above handles above cpu" {
    const q = Quota{ .pages = 100, .handles = 100, .cpu_ms = 100 };
    const memory = oomScore(.{ .pages = 100 }, q);
    const handles = oomScore(.{ .handles = 100 }, q);
    const cpu = oomScore(.{ .cpu_ms = 100 }, q);
    try std.testing.expect(memory > handles);
    try std.testing.expect(handles > cpu);
    try std.testing.expect(cpu > 0);
    // Nothing is above 1000, however far past its quota it went.
    try std.testing.expectEqual(@as(u32, 1000), oomScore(.{ .pages = 10_000, .handles = 10_000, .cpu_ms = 10_000 }, q));
    try std.testing.expectEqual(@as(u32, 0), oomScore(.{}, q));
}

test "the ladder warns, then throttles, then kills" {
    try std.testing.expectEqual(Step.none, escalate(.ok, 0));
    try std.testing.expectEqual(Step.warn, escalate(.near, 0));
    try std.testing.expectEqual(Step.none, escalate(.near, 1));
    try std.testing.expectEqual(Step.warn, escalate(.over, 0));
    try std.testing.expectEqual(Step.throttle, escalate(.over, 1));
    try std.testing.expectEqual(Step.kill, escalate(.over, 2));
    try std.testing.expectEqual(Step.kill, escalate(.over, 99));
}

test "permille saturates so a runaway cannot wrap the score" {
    const q = Quota{ .pages = 3, .handles = 3, .cpu_ms = 3 };
    const huge = Usage{ .pages = std.math.maxInt(u32), .handles = std.math.maxInt(u32), .cpu_ms = std.math.maxInt(u64) };
    try std.testing.expectEqual(@as(u32, 1000), oomScore(huge, q));
}
