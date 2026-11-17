//! USB HID report decoding (phase 38).
//!
//! The USB host stack arrives in phase 39, but the *reports* it will deliver
//! are a fixed, documented format, and the translation from a report to the
//! kernel's input events does not need a controller to be written or tested.
//! Keeping that decoder here means the boot keyboard, an absolute touch panel
//! and a barcode scanner all share one path with virtio-input, and phase 39 only
//! has to add enumeration and transfers.
//!
//! Three report decoders:
//!
//!   * **Boot keyboard**: 8 bytes (modifiers, reserved, six usages). The decoder
//!     diffs against the previous report, so a key held across reports produces
//!     one press and a release only when it disappears. The error-rollover usage
//!     (0x01) is ignored rather than reported as a key.
//!   * **Boot mouse**: 3+ bytes (buttons, dx, dy, wheel). Relative, signed.
//!   * **Absolute pointer/touch**: buttons, 16-bit little-endian x and y in the
//!     panel's own coordinate space, which is what a retail touch controller
//!     reports after calibration.

const std = @import("std");

pub const keyboard_report_size = 8;
pub const mouse_report_size = 3;
pub const pointer_report_size = 5;

pub const rollover_usage: u8 = 0x01;

pub const Change = struct {
    usage: u8,
    pressed: bool,
};

pub const BootKeyboard = struct {
    previous: [6]u8 = [_]u8{0} ** 6,
    modifiers: u8 = 0,

    pub fn reset(self: *BootKeyboard) void {
        self.previous = [_]u8{0} ** 6;
        self.modifiers = 0;
    }

    /// Diff one report against the previous one. Returns the number of changes
    /// written to `out` (at most 12: six presses and six releases).
    pub fn decode(self: *BootKeyboard, report: []const u8, out: *[12]Change) usize {
        if (report.len < keyboard_report_size) return 0;
        self.modifiers = report[0];

        var current: [6]u8 = undefined;
        @memcpy(&current, report[2..8]);

        // Rollover: the keyboard could not report every key. Keep the previous
        // state rather than inventing presses or releases.
        for (current) |usage| {
            if (usage == rollover_usage) return 0;
        }

        var n: usize = 0;
        for (current) |usage| {
            if (usage == 0) continue;
            if (contains(self.previous, usage)) continue;
            if (n < out.len) {
                out[n] = .{ .usage = usage, .pressed = true };
                n += 1;
            }
        }
        for (self.previous) |usage| {
            if (usage == 0) continue;
            if (contains(current, usage)) continue;
            if (n < out.len) {
                out[n] = .{ .usage = usage, .pressed = false };
                n += 1;
            }
        }
        self.previous = current;
        return n;
    }
};

fn contains(list: [6]u8, value: u8) bool {
    for (list) |entry| {
        if (entry == value) return true;
    }
    return false;
}

pub const BootMouse = struct {
    buttons: u8 = 0,
    dx: i16 = 0,
    dy: i16 = 0,
    wheel: i16 = 0,
    valid: bool = false,
};

pub fn decodeBootMouse(report: []const u8) BootMouse {
    if (report.len < mouse_report_size) return .{};
    return .{
        .buttons = report[0] & 0x07,
        .dx = @as(i8, @bitCast(report[1])),
        .dy = @as(i8, @bitCast(report[2])),
        .wheel = if (report.len >= 4) @as(i8, @bitCast(report[3])) else 0,
        .valid = true,
    };
}

pub const AbsolutePointer = struct {
    buttons: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,
    /// A touch report carries contact separately from the button byte on some
    /// panels; the simple report treats a non-zero button mask as contact.
    contact: bool = false,
    valid: bool = false,
};

pub fn decodeAbsolutePointer(report: []const u8) AbsolutePointer {
    if (report.len < pointer_report_size) return .{};
    const x = std.mem.readInt(u16, report[1..3], .little);
    const y = std.mem.readInt(u16, report[3..5], .little);
    return .{
        .buttons = report[0] & 0x07,
        .x = x,
        .y = y,
        .contact = report[0] & 0x07 != 0,
        .valid = true,
    };
}

/// A scanner is a keyboard: turn a decoded usage into the evdev code the input
/// core speaks. Re-exported so phase 39 does not need the keymap module.
pub fn usageToEvdev(usage: u8) u16 {
    return @import("keymap.zig").hidUsageToEvdev(usage);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a boot keyboard reports a press once and a release when it disappears" {
    var kb = BootKeyboard{};
    var changes: [12]Change = undefined;

    var press = [_]u8{0} ** 8;
    press[2] = 0x04; // 'a'
    try testing.expectEqual(@as(usize, 1), kb.decode(&press, &changes));
    try testing.expectEqual(@as(u8, 0x04), changes[0].usage);
    try testing.expect(changes[0].pressed);

    // The same report again: nothing changed.
    try testing.expectEqual(@as(usize, 0), kb.decode(&press, &changes));

    // Release.
    const release = [_]u8{0} ** 8;
    try testing.expectEqual(@as(usize, 1), kb.decode(&release, &changes));
    try testing.expect(!changes[0].pressed);
}

test "modifiers are exposed and both keys in one report are reported" {
    var kb = BootKeyboard{};
    var changes: [12]Change = undefined;
    var report = [_]u8{0} ** 8;
    report[0] = 0x02; // left shift
    report[2] = 0x04; // a
    report[3] = 0x05; // b
    try testing.expectEqual(@as(usize, 2), kb.decode(&report, &changes));
    try testing.expectEqual(@as(u8, 0x02), kb.modifiers);
}

test "N-key rollover is not invented as key presses" {
    var kb = BootKeyboard{};
    var changes: [12]Change = undefined;
    var report = [_]u8{0} ** 8;
    report[2] = 0x04;
    try testing.expectEqual(@as(usize, 1), kb.decode(&report, &changes));

    var rollover = [_]u8{0} ** 8;
    rollover[2] = rollover_usage;
    try testing.expectEqual(@as(usize, 0), kb.decode(&rollover, &changes));
    // The previous state was kept: releasing 'a' is still a release.
    const release = [_]u8{0} ** 8;
    try testing.expectEqual(@as(usize, 1), kb.decode(&release, &changes));
    try testing.expect(!changes[0].pressed);
}

test "short reports are refused instead of read out of bounds" {
    var kb = BootKeyboard{};
    var changes: [12]Change = undefined;
    try testing.expectEqual(@as(usize, 0), kb.decode(&[_]u8{ 0, 0, 4 }, &changes));
    try testing.expect(!decodeBootMouse(&[_]u8{ 0, 1 }).valid);
    try testing.expect(!decodeAbsolutePointer(&[_]u8{ 0, 1, 2 }).valid);
}

test "a boot mouse decodes signed motion and buttons" {
    const mouse = decodeBootMouse(&[_]u8{ 0x01, 0xFE, 0x05, 0xFF });
    try testing.expect(mouse.valid);
    try testing.expectEqual(@as(u8, 1), mouse.buttons);
    try testing.expectEqual(@as(i16, -2), mouse.dx);
    try testing.expectEqual(@as(i16, 5), mouse.dy);
    try testing.expectEqual(@as(i16, -1), mouse.wheel);
}

test "an absolute pointer decodes panel coordinates little-endian" {
    const pointer = decodeAbsolutePointer(&[_]u8{ 0x01, 0x02, 0x01, 0x04, 0x02 });
    try testing.expect(pointer.valid);
    try testing.expectEqual(@as(u16, 258), pointer.x);
    try testing.expectEqual(@as(u16, 516), pointer.y);
    try testing.expect(pointer.contact);
}

test "HID usages reach the same key table as virtio" {
    try testing.expectEqual(@as(u16, 30), usageToEvdev(0x04));
    try testing.expectEqual(@as(u16, 28), usageToEvdev(0x28));
}
