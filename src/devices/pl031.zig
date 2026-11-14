//! PL031 real-time clock and the civil-date arithmetic a receipt needs.
//!
//! The PL031 counts seconds since an epoch the firmware sets (Unix time on
//! QEMU). It is the first driver in the tree that exists purely for the till:
//! every receipt, journal entry and end-of-day report is stamped with a time
//! that survives a power cut, not with uptime.
//!
//! The register layout is the ARM PrimeCell RTC: data (seconds), match, load,
//! control, then the interrupt registers. Only reading is implemented; the
//! match interrupt belongs with the alarm feature, not the clock.

const std = @import("std");

// Register offsets from the PL031 base.
const RTCDR = 0x00;
const RTCLR = 0x08;
const RTCCR = 0x0c;

pub const DateTime = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// 0 = Sunday, as `tm_wday`.
    weekday: u8,

    pub fn dayName(self: DateTime) []const u8 {
        const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        return names[self.weekday % 7];
    }
};

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm, restricted
/// to the non-negative range a clock can report). Pure, so it is host-tested.
pub fn civilFromDays(days: u64) struct { year: u64, month: u8, day: u8 } {
    const z = days + 719_468;
    const era = z / 146_097;
    const doe = z % 146_097; // [0, 146096]
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153; // [0, 11], March-based
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = y + @as(u64, @intFromBool(m <= 2)), .month = @intCast(m), .day = @intCast(d) };
}

pub fn civilFromUnix(secs: u64) DateTime {
    const days = secs / 86_400;
    const rem = secs % 86_400;
    const date = civilFromDays(days);
    return .{
        .year = @intCast(date.year),
        .month = date.month,
        .day = date.day,
        .hour = @intCast(rem / 3600),
        .minute = @intCast((rem % 3600) / 60),
        .second = @intCast(rem % 60),
        // 1970-01-01 was a Thursday; 0 = Sunday.
        .weekday = @intCast((days + 4) % 7),
    };
}

/// `YYYY-MM-DD HH:MM:SS` into `buf`; returns the written slice.
pub fn format(dt: DateTime, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    }) catch "?";
}

fn mmio32(reg_base: usize, off: usize) *volatile u32 {
    return @ptrFromInt(reg_base + off);
}

var base: usize = 0;
var present: bool = false;
/// The value the clock was loaded with, read once at probe: QEMU leaves the
/// epoch in RTCLR, which is what a battery-backed part does.
var epoch: u32 = 0;

pub fn init(reg_base: usize) void {
    base = reg_base;
    present = true;
    epoch = mmio32(base, RTCLR).*;
}

pub fn remove() void {
    present = false;
}

pub fn isPresent() bool {
    return present;
}

/// Seconds since the Unix epoch, or null when the clock is not in the machine.
pub fn unixSeconds() ?u64 {
    if (!present) return null;
    return mmio32(base, RTCDR).*;
}

pub fn now() ?DateTime {
    return civilFromUnix(unixSeconds() orelse return null);
}

pub fn epochSeconds() u32 {
    return epoch;
}

pub fn control() u32 {
    if (!present) return 0;
    return mmio32(base, RTCCR).*;
}

// ---------------------------------------------------------------------------
// Tests: the arithmetic, not the hardware.
// ---------------------------------------------------------------------------

test "unix epoch and known leap days" {
    const a = civilFromUnix(0);
    try std.testing.expectEqual(@as(u32, 1970), a.year);
    try std.testing.expectEqual(@as(u8, 1), a.month);
    try std.testing.expectEqual(@as(u8, 1), a.day);
    try std.testing.expectEqual(@as(u8, 4), a.weekday); // Thursday

    const b = civilFromUnix(951_782_400); // 2000-02-29 00:00:00 UTC
    try std.testing.expectEqual(@as(u32, 2000), b.year);
    try std.testing.expectEqual(@as(u8, 2), b.month);
    try std.testing.expectEqual(@as(u8, 29), b.day);

    const c = civilFromUnix(1_709_164_800); // 2024-02-29
    try std.testing.expectEqual(@as(u32, 2024), c.year);
    try std.testing.expectEqual(@as(u8, 2), c.month);
    try std.testing.expectEqual(@as(u8, 29), c.day);

    const d = civilFromUnix(1_709_251_200); // 2024-03-01
    try std.testing.expectEqual(@as(u8, 3), d.month);
    try std.testing.expectEqual(@as(u8, 1), d.day);

    // The day rolls over exactly on the second.
    const e = civilFromUnix(86_399);
    try std.testing.expectEqual(@as(u8, 23), e.hour);
    try std.testing.expectEqual(@as(u8, 59), e.minute);
    try std.testing.expectEqual(@as(u8, 59), e.second);
    const f = civilFromUnix(86_400);
    try std.testing.expectEqual(@as(u8, 2), f.day);
    try std.testing.expectEqual(@as(u8, 0), f.hour);
}

test "1900 and 2100 are not leap years, 2000 is" {
    // 2100-03-01 is 47541 days after the epoch, and February 2100 has 28 days.
    const march = civilFromUnix(4_107_542_400);
    try std.testing.expectEqual(@as(u32, 2100), march.year);
    try std.testing.expectEqual(@as(u8, 3), march.month);
    try std.testing.expectEqual(@as(u8, 1), march.day);

    const feb28 = civilFromUnix(4_107_542_400 - 86_400);
    try std.testing.expectEqual(@as(u8, 2), feb28.month);
    try std.testing.expectEqual(@as(u8, 28), feb28.day);
}

test "formatting pads every field" {
    var buf: [32]u8 = undefined;
    const dt = civilFromUnix(951_782_400);
    try std.testing.expectEqualStrings("2000-02-29 00:00:00 UTC", format(dt, &buf));
    try std.testing.expectEqualStrings("Tue", dt.dayName());
}
