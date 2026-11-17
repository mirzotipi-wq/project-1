//! A 5x7 bitmap font for the framebuffer console (phase 37).
//!
//! Why a bitmap font before a vector one: a panic has to be legible on screen
//! before the font engine exists (phase 53), and a POS panel has to show its
//! boot state before the compositor does. The glyphs are ordinary Zig data —
//! rows top to bottom, five bits per row, bit 4 is the leftmost column — so the
//! table is readable, diffable and checkable in a unit test rather than an
//! opaque binary blob.
//!
//! Coverage is printable ASCII (0x20..0x7E). Anything else renders as a blank
//! with the same advance, so a bad byte in a log line never disturbs layout.

pub const glyph_width: u32 = 5;
pub const glyph_height: u32 = 7;
/// One blank column between glyphs.
pub const advance: u32 = glyph_width + 1;

pub const first_printable: u8 = 0x20;
pub const last_printable: u8 = 0x7e;
pub const glyph_count: usize = last_printable - first_printable + 1;

pub const Glyph = [glyph_height]u8;

/// ASCII 0x20..0x7E, one row per byte.
pub const glyphs: [glyph_count]Glyph = .{
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }, // space
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 }, // !
    .{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }, // "
    .{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010 }, // #
    .{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 }, // $
    .{ 0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011 }, // %
    .{ 0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101 }, // &
    .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }, // '
    .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 }, // (
    .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 }, // )
    .{ 0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000 }, // *
    .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 }, // +
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100, 0b01000 }, // ,
    .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 }, // -
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 }, // .
    .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 }, // /
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }, // 0
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 1
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 }, // 2
    .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 }, // 3
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, // 4
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, // 5
    .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, // 6
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, // 7
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, // 8
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 }, // 9
    .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 }, // :
    .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b00100, 0b01000 }, // ;
    .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 }, // <
    .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 }, // =
    .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 }, // >
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100 }, // ?
    .{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110 }, // @
    .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, // A
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }, // B
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }, // C
    .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 }, // D
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }, // E
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }, // F
    .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 }, // G
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, // H
    .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // I
    .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 }, // J
    .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }, // K
    .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }, // L
    .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 }, // M
    .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }, // N
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // O
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }, // P
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }, // Q
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }, // R
    .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 }, // S
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, // T
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // U
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 }, // V
    .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 }, // W
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 }, // X
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 }, // Y
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }, // Z
    .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 }, // [
    .{ 0b10000, 0b01000, 0b01000, 0b00100, 0b00010, 0b00010, 0b00001 }, // backslash
    .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 }, // ]
    .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000 }, // ^
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 }, // _
    .{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }, // `
    .{ 0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111 }, // a
    .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 }, // b
    .{ 0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110 }, // c
    .{ 0b00001, 0b00001, 0b01111, 0b10001, 0b10001, 0b10001, 0b01111 }, // d
    .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110 }, // e
    .{ 0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000 }, // f
    .{ 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 }, // g
    .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001 }, // h
    .{ 0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 }, // i
    .{ 0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100 }, // j
    .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010 }, // k
    .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // l
    .{ 0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10101, 0b10101 }, // m
    .{ 0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001 }, // n
    .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 }, // o
    .{ 0b00000, 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000 }, // p
    .{ 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001 }, // q
    .{ 0b00000, 0b00000, 0b10110, 0b11000, 0b10000, 0b10000, 0b10000 }, // r
    .{ 0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 }, // s
    .{ 0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110 }, // t
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101 }, // u
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 }, // v
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010 }, // w
    .{ 0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 }, // x
    .{ 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 }, // y
    .{ 0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 }, // z
    .{ 0b00010, 0b00100, 0b00100, 0b01000, 0b00100, 0b00100, 0b00010 }, // {
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, // |
    .{ 0b01000, 0b00100, 0b00100, 0b00010, 0b00100, 0b00100, 0b01000 }, // }
    .{ 0b00000, 0b00000, 0b01000, 0b10101, 0b00010, 0b00000, 0b00000 }, // ~
};

/// Rows for `ch`, or a blank glyph when it is outside printable ASCII.
pub fn glyph(ch: u8) Glyph {
    if (ch < first_printable or ch > last_printable) {
        return glyphs[0];
    }
    return glyphs[ch - first_printable];
}

/// Width in pixels of `text` drawn at `scale`, excluding the trailing blank
/// column: what a layout engine needs to centre it.
pub fn textWidth(text: []const u8, scale: u32) u32 {
    if (text.len == 0) return 0;
    return (@as(u32, @intCast(text.len)) * advance - 1) * scale;
}

test "the table covers printable ASCII exactly once" {
    try std.testing.expectEqual(@as(usize, 95), glyphs.len);
    try std.testing.expectEqual(@as(u8, 0x20), first_printable);
    try std.testing.expectEqual(@as(u8, 0x7e), last_printable);
}

test "glyphs outside printable ASCII fall back to blank" {
    try std.testing.expectEqualSlices(u8, &glyphs[0], &glyph('\n'));
    try std.testing.expectEqualSlices(u8, &glyphs[0], &glyph(0x7f));
    try std.testing.expectEqualSlices(u8, &glyphs[0], &glyph(0));
}

test "letters have ink and spaces do not" {
    var ink: u32 = 0;
    for (glyph('A')) |row| ink += @popCount(row);
    try std.testing.expect(ink > 10);

    var blank: u32 = 0;
    for (glyph(' ')) |row| blank += @popCount(row);
    try std.testing.expectEqual(@as(u32, 0), blank);

    // Every visible glyph fits inside five columns.
    for (glyphs[1..]) |g| {
        for (g) |row| try std.testing.expectEqual(@as(u8, 0), row & 0b1110_0000);
    }
}

test "text width excludes the trailing column" {
    try std.testing.expectEqual(@as(u32, 0), textWidth("", 1));
    try std.testing.expectEqual(@as(u32, 5), textWidth("A", 1));
    try std.testing.expectEqual(@as(u32, 11), textWidth("AA", 1));
    try std.testing.expectEqual(@as(u32, 10), textWidth("A", 2));
    try std.testing.expectEqual(@as(u32, 33), textWidth("AB", 3));
}

const std = @import("std");
