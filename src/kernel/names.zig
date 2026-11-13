//! Service names (phase 28).
//!
//! A name is the stable identity a POS application asks for: `pos://printer`,
//! `pos://checkout`. The rules are deliberately small and completely pure so they
//! can be unit-tested on the host: a lowercase scheme, then one to sixteen
//! characters of `a-z`, `0-9` and `-`, not starting or ending with a dash. That is
//! enough to name every device in a shop and narrow enough that a typo is
//! rejected instead of silently becoming a different service.
//!
//! The translation from a service's lifecycle to the answer a caller gets lives
//! here too, because the interesting part of a registry is not the lookup — it is
//! the refusal. A call site must be able to tell "no such service" from "it is
//! restarting" and from "it crash-looped and was parked", because those three
//! mean different things to a till: hide the feature, retry, or raise an alarm.

const std = @import("std");

pub const scheme = "pos://";
pub const max_suffix = 16;
pub const max_len = scheme.len + max_suffix;

/// Why a name resolved or did not. The numeric values are the ABI: they are
/// returned to user programs, so they must not be renumbered.
pub const Reason = enum(u8) {
    ok = 0,
    unknown = 1,
    stopped = 2,
    restarting = 3,
    failed = 4,
    exited = 5,
    duplicate = 6,
    invalid_name = 7,
    full = 8,
    no_memory = 9,
};

pub const Lifecycle = enum { stopped, running, restarting, failed };

pub fn valid(name: []const u8) bool {
    if (name.len <= scheme.len or name.len > max_len) return false;
    if (!std.mem.startsWith(u8, name, scheme)) return false;
    const tail = name[scheme.len..];
    if (tail.len == 0 or tail.len > max_suffix) return false;
    if (tail[0] == '-' or tail[tail.len - 1] == '-') return false;
    for (tail) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// The part after `pos://`, for display.
pub fn suffix(name: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, name, scheme)) return name;
    return name[scheme.len..];
}

pub fn reasonLabel(r: Reason) []const u8 {
    return switch (r) {
        .ok => "ok",
        .unknown => "unknown name",
        .stopped => "not running",
        .restarting => "restarting",
        .failed => "crash-loop parked",
        .exited => "exited, restart pending",
        .duplicate => "already registered",
        .invalid_name => "invalid name",
        .full => "name table full",
        .no_memory => "out of memory",
    };
}

/// What a caller is told about a service right now. `child_alive` distinguishes a
/// service the supervisor believes is running from one whose child has already
/// died but has not been noticed yet: the second must not be reported as usable.
pub fn reasonFor(life: Lifecycle, child_alive: bool) Reason {
    return switch (life) {
        .running => if (child_alive) .ok else .exited,
        .restarting => .restarting,
        .failed => .failed,
        .stopped => .stopped,
    };
}

test "valid names are the pos scheme plus a lowercase device name" {
    try std.testing.expect(valid("pos://printer"));
    try std.testing.expect(valid("pos://checkout"));
    try std.testing.expect(valid("pos://receipt-2"));
    try std.testing.expect(valid("pos://a"));
    try std.testing.expect(valid("pos://0123456789abcdef"));
}

test "everything else is refused as a name, not looked up" {
    try std.testing.expect(!valid("printer"));
    try std.testing.expect(!valid("pos://"));
    try std.testing.expect(!valid("POS://printer"));
    try std.testing.expect(!valid("pos://Printer"));
    try std.testing.expect(!valid("pos://print er"));
    try std.testing.expect(!valid("pos://-printer"));
    try std.testing.expect(!valid("pos://printer-"));
    try std.testing.expect(!valid("pos://0123456789abcdefg"));
    try std.testing.expect(!valid("file://printer"));
}

test "the suffix is what a display shows" {
    try std.testing.expectEqualStrings("printer", suffix("pos://printer"));
    try std.testing.expectEqualStrings("printer", suffix("printer"));
}

test "a running service with a live child is the only ok answer" {
    try std.testing.expectEqual(Reason.ok, reasonFor(.running, true));
    try std.testing.expectEqual(Reason.exited, reasonFor(.running, false));
    try std.testing.expectEqual(Reason.restarting, reasonFor(.restarting, false));
    try std.testing.expectEqual(Reason.failed, reasonFor(.failed, false));
    try std.testing.expectEqual(Reason.stopped, reasonFor(.stopped, false));
}

test "every reason has its own label, and ok is zero for the ABI" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Reason.ok));
    var seen: [10][]const u8 = undefined;
    var n: usize = 0;
    for ([_]Reason{ .ok, .unknown, .stopped, .restarting, .failed, .exited, .duplicate, .invalid_name, .full, .no_memory }) |r| {
        const label = reasonLabel(r);
        try std.testing.expect(label.len > 0);
        for (seen[0..n]) |other| try std.testing.expect(!std.mem.eql(u8, other, label));
        seen[n] = label;
        n += 1;
    }
}
