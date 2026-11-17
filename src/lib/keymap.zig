//! Keyboard translation tables (phase 38).
//!
//! Two physical languages reach the kernel: **evdev** codes from virtio-input
//! (the Linux KEY_* numbering) and **HID usage** ids from a USB boot keyboard
//! (phase 39's xHCI feeds the same decoder). Both resolve to one `Key`, so the
//! rest of the system never asks where a keystroke came from.
//!
//! Remapping lives here too: a `from -> to` table in evdev space that the input
//! core applies before translation, which is how a POS terminal fixes a
//! broken key or swaps layouts without a rebuild. The table and the lookup are
//! pure, so both are unit-tested on the host.

const std = @import("std");

pub const Modifier = enum(u8) {
    none = 0,
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_meta,
    right_meta,
    caps_lock,
    num_lock,
    scroll_lock,
};

pub const Category = enum { character, navigation, function_key, keypad, modifier, other };

pub const Key = struct {
    name: []const u8 = "unknown",
    /// The character produced without shift, 0 when the key is not a character.
    ascii: u8 = 0,
    /// The character produced with shift (or with caps lock, for letters).
    shifted: u8 = 0,
    modifier: Modifier = .none,
    category: Category = .other,

    pub fn isCharacter(self: Key) bool {
        return self.ascii != 0;
    }

    pub fn isModifier(self: Key) bool {
        return self.modifier != .none;
    }
};

fn character(name: []const u8, plain: u8, shifted: u8) Key {
    return .{ .name = name, .ascii = plain, .shifted = shifted, .category = .character };
}

fn modified(name: []const u8, modifier: Modifier) Key {
    return .{ .name = name, .modifier = modifier, .category = .modifier };
}

fn nav(name: []const u8) Key {
    return .{ .name = name, .category = .navigation };
}

fn function(name: []const u8) Key {
    return .{ .name = name, .category = .function_key };
}

fn keypad(name: []const u8, digit: u8) Key {
    return .{ .name = name, .ascii = digit, .shifted = digit, .category = .keypad };
}

/// evdev `KEY_*` code -> semantic key. The table covers everything a POS
/// keyboard actually has: the full alpha block, digits, punctuation, editing
/// and navigation keys, the keypad, and the modifiers. Unknown codes answer
/// `.{}` instead of guessing.
pub fn evdev(code: u16) Key {
    return switch (code) {
        1 => .{ .name = "Esc", .category = .other },
        2 => character("1", '1', '!'),
        3 => character("2", '2', '@'),
        4 => character("3", '3', '#'),
        5 => character("4", '4', '$'),
        6 => character("5", '5', '%'),
        7 => character("6", '6', '^'),
        8 => character("7", '7', '&'),
        9 => character("8", '8', '*'),
        10 => character("9", '9', '('),
        11 => character("0", '0', ')'),
        12 => character("-", '-', '_'),
        13 => character("=", '=', '+'),
        14 => .{ .name = "Backspace", .ascii = 0x7f, .shifted = 0x7f, .category = .character },
        15 => .{ .name = "Tab", .ascii = '\t', .shifted = '\t', .category = .character },
        16 => character("Q", 'q', 'Q'),
        17 => character("W", 'w', 'W'),
        18 => character("E", 'e', 'E'),
        19 => character("R", 'r', 'R'),
        20 => character("T", 't', 'T'),
        21 => character("Y", 'y', 'Y'),
        22 => character("U", 'u', 'U'),
        23 => character("I", 'i', 'I'),
        24 => character("O", 'o', 'O'),
        25 => character("P", 'p', 'P'),
        26 => character("[", '[', '{'),
        27 => character("]", ']', '}'),
        28 => .{ .name = "Enter", .ascii = '\r', .shifted = '\r', .category = .character },
        29 => modified("LeftCtrl", .left_ctrl),
        30 => character("A", 'a', 'A'),
        31 => character("S", 's', 'S'),
        32 => character("D", 'd', 'D'),
        33 => character("F", 'f', 'F'),
        34 => character("G", 'g', 'G'),
        35 => character("H", 'h', 'H'),
        36 => character("J", 'j', 'J'),
        37 => character("K", 'k', 'K'),
        38 => character("L", 'l', 'L'),
        39 => character(";", ';', ':'),
        40 => character("'", '\'', '"'),
        41 => character("`", '`', '~'),
        42 => modified("LeftShift", .left_shift),
        43 => character("\\", '\\', '|'),
        44 => character("Z", 'z', 'Z'),
        45 => character("X", 'x', 'X'),
        46 => character("C", 'c', 'C'),
        47 => character("V", 'v', 'V'),
        48 => character("B", 'b', 'B'),
        49 => character("N", 'n', 'N'),
        50 => character("M", 'm', 'M'),
        51 => character(",", ',', '<'),
        52 => character(".", '.', '>'),
        53 => character("/", '/', '?'),
        54 => modified("RightShift", .right_shift),
        55 => .{ .name = "Kp*", .ascii = '*', .shifted = '*', .category = .keypad },
        56 => modified("LeftAlt", .left_alt),
        57 => character("Space", ' ', ' '),
        58 => modified("CapsLock", .caps_lock),
        59...68 => blk: {
            const names = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10" };
            break :blk function(names[code - 59]);
        },
        69 => modified("NumLock", .num_lock),
        70 => modified("ScrollLock", .scroll_lock),
        71 => keypad("Kp7", '7'),
        72 => keypad("Kp8", '8'),
        73 => keypad("Kp9", '9'),
        74 => .{ .name = "Kp-", .ascii = '-', .shifted = '-', .category = .keypad },
        75 => keypad("Kp4", '4'),
        76 => keypad("Kp5", '5'),
        77 => keypad("Kp6", '6'),
        78 => .{ .name = "Kp+", .ascii = '+', .shifted = '+', .category = .keypad },
        79 => keypad("Kp1", '1'),
        80 => keypad("Kp2", '2'),
        81 => keypad("Kp3", '3'),
        82 => keypad("Kp0", '0'),
        83 => .{ .name = "Kp.", .ascii = '.', .shifted = '.', .category = .keypad },
        87 => function("F11"),
        88 => function("F12"),
        96 => .{ .name = "KpEnter", .ascii = '\r', .shifted = '\r', .category = .keypad },
        97 => modified("RightCtrl", .right_ctrl),
        98 => .{ .name = "Kp/", .ascii = '/', .shifted = '/', .category = .keypad },
        100 => modified("RightAlt", .right_alt),
        102 => nav("Home"),
        103 => nav("Up"),
        104 => nav("PageUp"),
        105 => nav("Left"),
        106 => nav("Right"),
        107 => nav("End"),
        108 => nav("Down"),
        109 => nav("PageDown"),
        110 => nav("Insert"),
        111 => .{ .name = "Delete", .category = .navigation },
        119 => .{ .name = "Pause", .category = .other },
        125 => modified("LeftMeta", .left_meta),
        126 => modified("RightMeta", .right_meta),
        else => .{},
    };
}

/// HID keyboard usage id -> evdev code, so a USB keyboard produces the same
/// events as a virtio keyboard. Only the boot-keyboard page (0x04..0xE7) is
/// translated; consumer/page-up keys belong with the USB phase.
pub fn hidUsageToEvdev(usage: u8) u16 {
    return switch (usage) {
        0x04 => 30, // a
        0x05 => 48, // b
        0x06 => 46, // c
        0x07 => 32, // d
        0x08 => 18, // e
        0x09 => 33, // f
        0x0a => 34, // g
        0x0b => 35, // h
        0x0c => 23, // i
        0x0d => 36, // j
        0x0e => 37, // k
        0x0f => 38, // l
        0x10 => 50, // m
        0x11 => 49, // n
        0x12 => 24, // o
        0x13 => 25, // p
        0x14 => 16, // q
        0x15 => 19, // r
        0x16 => 31, // s
        0x17 => 20, // t
        0x18 => 22, // u
        0x19 => 47, // v
        0x1a => 17, // w
        0x1b => 45, // x
        0x1c => 21, // y
        0x1d => 44, // z
        0x1e => 2,
        0x1f => 3,
        0x20 => 4,
        0x21 => 5,
        0x22 => 6,
        0x23 => 7,
        0x24 => 8,
        0x25 => 9,
        0x26 => 10,
        0x27 => 11,
        0x28 => 28, // enter
        0x29 => 1, // escape
        0x2a => 14, // backspace
        0x2b => 15, // tab
        0x2c => 57, // space
        0x2d => 12,
        0x2e => 13,
        0x2f => 26,
        0x30 => 27,
        0x31 => 43,
        0x33 => 39,
        0x34 => 40,
        0x35 => 41,
        0x36 => 51,
        0x37 => 52,
        0x38 => 53,
        0x39 => 58, // caps lock
        0x3a...0x45 => 59 + (usage - 0x3a), // F1..F12
        0x49 => 110, // insert
        0x4a => 102, // home
        0x4b => 104, // page up
        0x4c => 111, // delete
        0x4d => 107, // end
        0x4e => 109, // page down
        0x4f => 106, // right
        0x50 => 105, // left
        0x51 => 108, // down
        0x52 => 103, // up
        0x53 => 69, // num lock
        0x54 => 98, // kp /
        0x55 => 55, // kp *
        0x56 => 74, // kp -
        0x57 => 78, // kp +
        0x58 => 96, // kp enter
        0x59 => 79, // kp 1
        0x5a => 80,
        0x5b => 81,
        0x5c => 75,
        0x5d => 76,
        0x5e => 77,
        0x5f => 71,
        0x60 => 72,
        0x61 => 73,
        0x62 => 82,
        0x63 => 83,
        0xe0 => 29, // left ctrl
        0xe1 => 42, // left shift
        0xe2 => 56, // left alt
        0xe3 => 125, // left meta
        0xe4 => 97, // right ctrl
        0xe5 => 54, // right shift
        0xe6 => 100, // right alt
        0xe7 => 126, // right meta
        else => 0,
    };
}

/// Modifier state carried across events. The kernel keeps one per keyboard.
pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    caps: bool = false,
    num: bool = false,

    /// Fold a key press or release into the state. Returns true when the key
    /// was a modifier (so the caller does not emit it as a character).
    pub fn update(self: *Modifiers, key: Key, pressed: bool) bool {
        const down = pressed;
        switch (key.modifier) {
            .none => return false,
            .left_shift, .right_shift => self.shift = down,
            .left_ctrl, .right_ctrl => self.ctrl = down,
            .left_alt, .right_alt => self.alt = down,
            .left_meta, .right_meta => self.meta = down,
            .caps_lock => {
                if (pressed) self.caps = !self.caps;
            },
            .num_lock => {
                if (pressed) self.num = !self.num;
            },
            .scroll_lock => {},
        }
        return true;
    }

    pub fn bits(self: Modifiers) u8 {
        var b: u8 = 0;
        if (self.shift) b |= 1;
        if (self.ctrl) b |= 2;
        if (self.alt) b |= 4;
        if (self.meta) b |= 8;
        if (self.caps) b |= 16;
        if (self.num) b |= 32;
        return b;
    }

    /// The character a key produces with this modifier state.
    pub fn text(self: Modifiers, key: Key) u8 {
        if (!key.isCharacter()) return 0;
        const letter = key.ascii >= 'a' and key.ascii <= 'z';
        const use_shifted = if (letter) self.shift != self.caps else self.shift;
        return if (use_shifted) key.shifted else key.ascii;
    }
};

// ---------------------------------------------------------------------------
// Remapping
// ---------------------------------------------------------------------------

/// Sentinel for "no remap": evdev code 0 is KEY_RESERVED and never a real key.
pub const identity: u16 = 0;
const max_remaps = 32;

const Remap = struct { from: u16, to: u16 };
var remaps: [max_remaps]Remap = undefined;
var remap_count: usize = 0;
var remap_hits: u64 = 0;

/// Add or replace a remap. Returns false when the table is full.
pub fn setRemap(from: u16, to: u16) bool {
    for (remaps[0..remap_count]) |*r| {
        if (r.from == from) {
            r.to = to;
            return true;
        }
    }
    if (remap_count >= max_remaps) return false;
    remaps[remap_count] = .{ .from = from, .to = to };
    remap_count += 1;
    return true;
}

pub fn resetRemaps() void {
    remap_count = 0;
}

pub fn remapFor(code: u16) u16 {
    for (remaps[0..remap_count]) |r| {
        if (r.from == code) {
            remap_hits += 1;
            return r.to;
        }
    }
    return code;
}

pub fn remapCount() usize {
    return remap_count;
}

pub fn remapHits() u64 {
    return remap_hits;
}

pub fn remapAt(index: usize) ?Remap {
    if (index >= remap_count) return null;
    return remaps[index];
}

/// Translate a physical code (after remapping) into a key.
pub fn translate(code: u16) Key {
    return evdev(remapFor(code));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "letters, digits and punctuation translate with shift" {
    const a = evdev(30);
    try std.testing.expectEqualStrings("A", a.name);
    try std.testing.expectEqual(@as(u8, 'a'), a.ascii);
    try std.testing.expectEqual(@as(u8, 'A'), a.shifted);

    var mods = Modifiers{};
    try std.testing.expect(!mods.update(a, true));
    try std.testing.expectEqual(@as(u8, 'a'), mods.text(a));

    _ = mods.update(evdev(42), true);
    try std.testing.expectEqual(@as(u8, 'A'), mods.text(a));
    try std.testing.expectEqual(@as(u8, '!'), mods.text(evdev(2)));
}

test "caps lock affects letters and not digits" {
    var mods = Modifiers{};
    _ = mods.update(evdev(58), true); // caps on
    try std.testing.expect(mods.caps);
    try std.testing.expectEqual(@as(u8, 'A'), mods.text(evdev(30))); // caps upper-cases letters
    try std.testing.expectEqual(@as(u8, '1'), mods.text(evdev(2))); // but not digits

    // caps + shift cancels out, as on every desktop.
    _ = mods.update(evdev(42), true);
    try std.testing.expectEqual(@as(u8, 'a'), mods.text(evdev(30)));
    _ = mods.update(evdev(42), false);

    _ = mods.update(evdev(58), true); // caps off
    try std.testing.expectEqual(@as(u8, 'a'), mods.text(evdev(30)));
}

test "enter, backspace and tab carry their control characters" {
    try std.testing.expectEqual(@as(u8, '\r'), evdev(28).ascii);
    try std.testing.expectEqual(@as(u8, '\t'), evdev(15).ascii);
    try std.testing.expectEqual(@as(u8, 0x7f), evdev(14).ascii);
    try std.testing.expect(evdev(103).category == .navigation);
    try std.testing.expectEqualStrings("F5", evdev(63).name);
    try std.testing.expectEqual(@as(u8, '7'), evdev(71).ascii);
    try std.testing.expect(evdev(70).isModifier());
}

test "unknown codes are inert, not fatal" {
    const unknown = evdev(240);
    try std.testing.expectEqual(@as(u8, 0), unknown.ascii);
    try std.testing.expect(!unknown.isCharacter());
    try std.testing.expectEqualStrings("unknown", unknown.name);
}

test "HID usages reach the same keys as evdev" {
    try std.testing.expectEqual(@as(u16, 30), hidUsageToEvdev(0x04));
    try std.testing.expectEqual(evdev(30).name, evdev(hidUsageToEvdev(0x04)).name);
    try std.testing.expectEqual(@as(u16, 28), hidUsageToEvdev(0x28));
    try std.testing.expectEqual(@as(u16, 1), hidUsageToEvdev(0x29));
    try std.testing.expectEqual(@as(u16, 42), hidUsageToEvdev(0xe1));
    try std.testing.expectEqual(@as(u16, 0), hidUsageToEvdev(0xff));
    // Every boot-keyboard letter maps to a letter.
    var usage: u8 = 0x04;
    while (usage <= 0x1d) : (usage += 1) {
        try std.testing.expect(evdev(hidUsageToEvdev(usage)).isCharacter());
    }
}

test "remaps rewrite a code and are cleared by reset" {
    resetRemaps();
    try std.testing.expectEqual(@as(u16, 30), remapFor(30));
    try std.testing.expect(setRemap(30, 31));
    try std.testing.expectEqual(@as(u16, 31), remapFor(30));
    try std.testing.expectEqualStrings("S", translate(30).name);
    try std.testing.expectEqual(@as(usize, 1), remapCount());
    resetRemaps();
    try std.testing.expectEqualStrings("A", translate(30).name);
    try std.testing.expectEqual(@as(usize, 0), remapCount());
}

test "modifier bits pack for the event record" {
    var mods = Modifiers{};
    _ = mods.update(evdev(42), true);
    _ = mods.update(evdev(29), true);
    try std.testing.expectEqual(@as(u8, 1 | 2), mods.bits());
    _ = mods.update(evdev(42), false);
    try std.testing.expectEqual(@as(u8, 2), mods.bits());
}
