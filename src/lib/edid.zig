//! EDID parsing (phase 37).
//!
//! A POS panel is whatever the shop bought. The kernel must not guess its
//! resolution: it reads the panel's EDID blob and programs the panel's preferred
//! timing. On QEMU's bochs-display the same 256-byte blob is exposed at the
//! start of the second MMIO BAR, so this parser is exercised by the real driver
//! and by host tests with a synthetic blob.
//!
//! Only the base block is needed to mode-set: header, manufacturer, product,
//! serial, week/year, physical size, chromaticity presence, established and
//! standard timings, four detailed timing descriptors, and the range-limits
//! descriptor that caps pixel clock and refresh. Extension blocks (CEA-861 for
//! HDMI/audio) are counted, not parsed; that belongs with HDMI modesetting.

const std = @import("std");

pub const block_size: usize = 128;
pub const header = [8]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };

pub const Error = error{
    TooShort,
    BadHeader,
    BadChecksum,
    NoTimings,
};

/// One detailed timing descriptor, decoded.
pub const Timing = struct {
    pixel_clock_khz: u32,
    hactive: u32,
    hblank: u32,
    vactive: u32,
    vblank: u32,
    hsync_offset: u32,
    hsync_width: u32,
    vsync_offset: u32,
    vsync_width: u32,
    /// Digital separate sync with positive polarities: what panels use.
    hsync_positive: bool = false,
    vsync_positive: bool = false,
    interlaced: bool = false,

    pub fn htotal(self: Timing) u32 {
        return self.hactive + self.hblank;
    }

    pub fn vtotal(self: Timing) u32 {
        return self.vactive + self.vblank;
    }

    /// Refresh in millihertz, so the comparison in tests needs no float.
    pub fn refreshMilliHz(self: Timing) u32 {
        const total = self.htotal() * self.vtotal();
        if (total == 0) return 0;
        return @intCast((@as(u64, self.pixel_clock_khz) * 1_000_000) / total);
    }

    pub fn refreshHz(self: Timing) u32 {
        const total = self.htotal() * self.vtotal();
        if (total == 0) return 0;
        return @intCast((@as(u64, self.pixel_clock_khz) * 1000) / total);
    }
};

/// A "standard timing" entry: the byte-pair form that predates detailed
/// descriptors. Kept because a panel that only lists standard timings still has
/// to give the kernel a usable mode.
pub const StandardTiming = struct {
    width: u32,
    height: u32,
    refresh_hz: u32,
};

pub const Info = struct {
    manufacturer: [3]u8 = .{ '?', '?', '?' },
    product: u16 = 0,
    serial: u32 = 0,
    week: u8 = 0,
    year: u16 = 0,
    version_major: u8 = 0,
    version_minor: u8 = 0,
    width_cm: u8 = 0,
    height_cm: u8 = 0,
    gamma: u8 = 0,
    digital: bool = false,
    preferred: ?Timing = null,
    /// Every decoded detailed timing, preferred first (as in the blob).
    timings: [4]Timing = undefined,
    timing_count: usize = 0,
    standard: [8]StandardTiming = undefined,
    standard_count: usize = 0,
    name: [14]u8 = [_]u8{' '} ** 14,
    name_len: usize = 0,
    /// Horizontal and vertical rate limits from the 0xFD descriptor.
    min_vrate_hz: u32 = 0,
    max_vrate_hz: u32 = 0,
    min_hrate_khz: u32 = 0,
    max_hrate_khz: u32 = 0,
    max_pixel_clock_khz: u32 = 0,
    extensions: u8 = 0,
    checksum: u8 = 0,

    pub fn nameSlice(self: *const Info) []const u8 {
        return self.name[0..self.name_len];
    }

    /// The mode to program: preferred timing when the panel lists one,
    /// otherwise the fastest standard timing, otherwise nothing.
    pub fn bestTiming(self: *const Info) ?Timing {
        if (self.preferred) |t| return t;
        for (self.timings[0..self.timing_count]) |t| return t;

        var best: ?StandardTiming = null;
        for (self.standard[0..self.standard_count]) |s| {
            const candidate = best orelse {
                best = s;
                continue;
            };
            if (s.width * s.height > candidate.width * candidate.height) best = s;
        }
        const s = best orelse return null;
        // A standard timing has no blanking information; synthesise a CVT-like
        // 5% blanking interval so the caller gets a usable total.
        return Timing{
            .pixel_clock_khz = @intCast((@as(u64, s.width) * s.height * s.refresh_hz) / 900),
            .hactive = s.width,
            .hblank = s.width / 20,
            .vactive = s.height,
            .vblank = s.height / 50,
            .hsync_offset = 0,
            .hsync_width = 0,
            .vsync_offset = 0,
            .vsync_width = 0,
        };
    }

    pub fn preferredResolution(self: *const Info) ?struct { width: u32, height: u32 } {
        const t = self.bestTiming() orelse return null;
        return .{ .width = t.hactive, .height = t.vactive };
    }
};

fn le16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn decodeManufacturer(raw: u16) [3]u8 {
    // Five-bit letters, 'A' = 1, big-endian across the two bytes.
    var out: [3]u8 = undefined;
    out[0] = @intCast('A' + ((raw >> 10) & 0x1f) - 1);
    out[1] = @intCast('A' + ((raw >> 5) & 0x1f) - 1);
    out[2] = @intCast('A' + (raw & 0x1f) - 1);
    for (out) |c| {
        if (c < 'A' or c > 'Z') return .{ '?', '?', '?' };
    }
    return out;
}

/// Decode the 18-byte detailed timing descriptor at `off`. Returns null for a
/// display descriptor (pixel clock 0), which carries a name or range limits.
fn decodeDetailed(bytes: []const u8, off: usize) ?Timing {
    const clock_10khz = le16(bytes, off);
    if (clock_10khz == 0) return null;

    const hactive: u32 = @as(u32, bytes[off + 2]) | (@as(u32, bytes[off + 4] & 0xf0) << 4);
    const hblank: u32 = @as(u32, bytes[off + 3]) | (@as(u32, bytes[off + 4] & 0x0f) << 8);
    const vactive: u32 = @as(u32, bytes[off + 5]) | (@as(u32, bytes[off + 7] & 0xf0) << 4);
    const vblank: u32 = @as(u32, bytes[off + 6]) | (@as(u32, bytes[off + 7] & 0x0f) << 8);

    // Byte 17 is the flags byte; the second byte of the pair is the next
    // descriptor, so it must not be read as part of this one.
    const flags = bytes[off + 17];
    return Timing{
        .pixel_clock_khz = @as(u32, clock_10khz) * 10,
        .hactive = hactive,
        .hblank = hblank,
        .vactive = vactive,
        .vblank = vblank,
        .hsync_offset = @as(u32, bytes[off + 8]) | (@as(u32, bytes[off + 11] & 0xc0) << 2),
        .hsync_width = @as(u32, bytes[off + 9]) | (@as(u32, bytes[off + 11] & 0x30) << 4),
        .vsync_offset = @as(u32, bytes[off + 10] >> 4) | (@as(u32, bytes[off + 11] & 0x0c) << 2),
        .vsync_width = @as(u32, bytes[off + 10] & 0x0f) | (@as(u32, bytes[off + 11] & 0x03) << 4),
        .hsync_positive = (flags & 0x2) != 0,
        .vsync_positive = (flags & 0x4) != 0,
        .interlaced = (flags & 0x80) != 0,
    };
}

/// Decode one of the four 18-byte descriptor slots. Detailed timings come back
/// as timings; display descriptors fill in the name or the range limits.
fn decodeDescriptor(bytes: []const u8, off: usize, info: *Info) void {
    if (decodeDetailed(bytes, off)) |t| {
        if (info.timing_count < info.timings.len) {
            info.timings[info.timing_count] = t;
            info.timing_count += 1;
        }
        if (info.preferred == null) info.preferred = t;
        return;
    }

    // Display descriptor: byte 3 is the tag.
    switch (bytes[off + 3]) {
        0xfc => { // monitor name
            var i: usize = 0;
            while (i < 13) : (i += 1) {
                const c = bytes[off + 5 + i];
                if (c == 0x0a or c == 0x00) break;
                info.name[info.name_len] = c;
                info.name_len += 1;
            }
        },
        0xfd => { // range limits
            info.min_vrate_hz = bytes[off + 5];
            info.max_vrate_hz = bytes[off + 6];
            info.min_hrate_khz = bytes[off + 7];
            info.max_hrate_khz = bytes[off + 8];
            info.max_pixel_clock_khz = @as(u32, bytes[off + 9]) * 10_000;
        },
        else => {},
    }
}

/// Decode the eight two-byte standard timing entries.
fn decodeStandard(bytes: []const u8, info: *Info) void {
    for (0..8) |i| {
        const off = 38 + i * 2;
        // 0x01,0x01 is the spec's "unused" marker; an all-zero pair is what a
        // blank region of the blob holds and is equally not a timing.
        if (bytes[off] == 0x01 and bytes[off + 1] == 0x01) continue;
        if (bytes[off] == 0x00) continue;
        const width = (@as(u32, bytes[off]) + 31) * 8;
        const aspect: u32 = (bytes[off + 1] >> 6) & 0x03;
        const height: u32 = switch (aspect) {
            0 => width * 10 / 16, // 16:10
            1 => width * 3 / 4, // 4:3
            2 => width * 4 / 5, // 5:4
            else => width * 9 / 16, // 16:9
        };
        if (info.standard_count >= info.standard.len) continue;
        info.standard[info.standard_count] = .{
            .width = width,
            .height = height,
            .refresh_hz = @as(u32, (bytes[off + 1] & 0x3f)) + 60,
        };
        info.standard_count += 1;
    }
}

pub fn parse(bytes: []const u8) Error!Info {
    if (bytes.len < block_size) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..8], &header)) return error.BadHeader;

    var sum: u8 = 0;
    for (bytes[0..block_size]) |b| sum +%= b;
    if (sum != 0) return error.BadChecksum;

    var info = Info{};
    info.manufacturer = decodeManufacturer(le16(bytes, 8));
    info.product = le16(bytes, 10);
    info.serial = @as(u32, bytes[12]) | (@as(u32, bytes[13]) << 8) |
        (@as(u32, bytes[14]) << 16) | (@as(u32, bytes[15]) << 24);
    info.week = bytes[16];
    info.year = if (bytes[17] == 0) 0 else @as(u16, 1990) + bytes[17];
    info.version_major = bytes[18];
    info.version_minor = bytes[19];
    info.digital = (bytes[20] & 0x80) != 0;
    info.width_cm = bytes[21];
    info.height_cm = bytes[22];
    info.gamma = bytes[23];
    info.extensions = bytes[126];
    info.checksum = bytes[127];

    decodeStandard(bytes, &info);
    for (0..4) |slot| decodeDescriptor(bytes, 54 + slot * 18, &info);

    if (info.preferred == null and info.standard_count == 0) return error.NoTimings;
    return info;
}

// ---------------------------------------------------------------------------
// Tests: a synthetic 1280x800 panel, built field by field.
// ---------------------------------------------------------------------------

fn put16(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value);
    buf[off + 1] = @truncate(value >> 8);
}

fn finaliseChecksum(buf: []u8) void {
    var sum: u8 = 0;
    for (buf[0..127]) |b| sum +%= b;
    buf[127] = 0 -% sum;
}

/// 1280x800 at 60 Hz: pixel clock 83.5 MHz, htotal 1680, vtotal 831.
fn synthetic1280x800() [128]u8 {
    var buf = [_]u8{0} ** 128;
    @memcpy(buf[0..8], &header);

    // Manufacturer "QEM", product 0x1234, serial 0xdeadbeef.
    put16(&buf, 8, (('Q' - 'A' + 1) << 10) | (('E' - 'A' + 1) << 5) | ('M' - 'A' + 1));
    put16(&buf, 10, 0x1234);
    put16(&buf, 12, 0xbeef);
    put16(&buf, 14, 0xdead);
    buf[16] = 12;
    buf[17] = 33; // 2023
    buf[18] = 1;
    buf[19] = 4;
    buf[20] = 0x80 | 0x0a; // digital, 8 bits per primary
    buf[21] = 30; // 300 mm
    buf[22] = 19; // 190 mm
    buf[23] = 0x78; // gamma 2.2

    // Preferred detailed timing at 54.
    const off = 54;
    put16(&buf, off, 8350); // 10 kHz units -> 83.5 MHz
    buf[off + 2] = 1280 & 0xff;
    buf[off + 3] = 400 & 0xff; // hblank
    buf[off + 4] = @intCast(((1280 >> 8) << 4) | ((400 >> 8) & 0x0f));
    buf[off + 5] = 800 & 0xff;
    buf[off + 6] = 31 & 0xff; // vblank
    buf[off + 7] = @intCast(((800 >> 8) << 4) | ((31 >> 8) & 0x0f));
    buf[off + 8] = 48; // hsync offset
    buf[off + 9] = 32; // hsync width
    buf[off + 10] = 0x30; // vsync offset 3, width 0
    buf[off + 11] = 0x18; // high bits for the above
    buf[off + 17] = 0x18 | 0x04 | 0x02; // digital separate, +h +v

    // Monitor name descriptor at 72.
    buf[72] = 0;
    buf[72 + 3] = 0xfc;
    @memcpy(buf[77..90], "CassaPanel 12");

    // Range limits descriptor at 90: 50-75 Hz, 30-90 kHz, 170 MHz.
    buf[90] = 0;
    buf[90 + 3] = 0xfd;
    buf[95] = 50;
    buf[96] = 75;
    buf[97] = 30;
    buf[98] = 90;
    buf[99] = 17;

    // A standard timing: 1280x720 at 60 Hz would be 0x50 with 4:3 bits; put a
    // plain 1024x768 entry (0x61, aspect 4:3, 60 Hz) in slot 0.
    buf[38] = 0x61;
    buf[39] = 0x40; // 4:3, refresh 0 -> 60
    buf[40] = 0x01;
    buf[41] = 0x01;

    finaliseChecksum(&buf);
    return buf;
}

test "synthetic panel parses field for field" {
    const blob = synthetic1280x800();
    const info = try parse(&blob);

    try std.testing.expectEqualStrings("QEM", &info.manufacturer);
    try std.testing.expectEqual(@as(u16, 0x1234), info.product);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), info.serial);
    try std.testing.expectEqual(@as(u16, 2023), info.year);
    try std.testing.expect(info.digital);
    try std.testing.expectEqualStrings("CassaPanel 12", info.nameSlice());

    const t = info.preferred.?;
    try std.testing.expectEqual(@as(u32, 1280), t.hactive);
    try std.testing.expectEqual(@as(u32, 800), t.vactive);
    try std.testing.expectEqual(@as(u32, 1680), t.htotal());
    try std.testing.expectEqual(@as(u32, 831), t.vtotal());
    // 83 500 000 / (1680 * 831) = 59.8 Hz.
    try std.testing.expectEqual(@as(u32, 59), t.refreshHz());
    try std.testing.expect(t.hsync_positive and t.vsync_positive);

    try std.testing.expectEqual(@as(u32, 50), info.min_vrate_hz);
    try std.testing.expectEqual(@as(u32, 75), info.max_vrate_hz);
    try std.testing.expectEqual(@as(u32, 170_000), info.max_pixel_clock_khz);

    try std.testing.expectEqual(@as(usize, 1), info.standard_count);
    try std.testing.expectEqual(@as(u32, 1024), info.standard[0].width);
    try std.testing.expectEqual(@as(u32, 768), info.standard[0].height);

    const res = info.preferredResolution().?;
    try std.testing.expectEqual(@as(u32, 1280), res.width);
    try std.testing.expectEqual(@as(u32, 800), res.height);
}

test "header, length and checksum are enforced" {
    const blob = synthetic1280x800();

    try std.testing.expectError(error.TooShort, parse(blob[0..64]));

    var bad_header = blob;
    bad_header[1] = 0x00;
    try std.testing.expectError(error.BadHeader, parse(&bad_header));

    var bad_sum = blob;
    bad_sum[20] ^= 0x01;
    try std.testing.expectError(error.BadChecksum, parse(&bad_sum));
}

test "a panel with only a standard timing still yields a mode" {
    var buf = [_]u8{0} ** 128;
    @memcpy(buf[0..8], &header);
    put16(&buf, 8, (('A' - 'A' + 1) << 10) | (('C' - 'A' + 1) << 5) | ('M' - 'A' + 1));
    buf[18] = 1;
    buf[19] = 3;
    buf[38] = 0x4f; // (79 + 31) * 8 = 880
    buf[39] = 0x40 | 0x00; // 4:3 aspect, refresh 60 + 0
    finaliseChecksum(&buf);

    const info = try parse(&buf);
    try std.testing.expect(info.preferred == null);
    const t = info.bestTiming().?;
    try std.testing.expectEqual(@as(u32, 880), t.hactive);
    try std.testing.expectEqual(@as(u32, 660), t.vactive);
}

test "interlaced and analog flags survive the decode" {
    var blob = synthetic1280x800();
    blob[54 + 17] = 0x80; // interlaced, separate sync, negative polarity
    finaliseChecksum(&blob);
    const info = try parse(&blob);
    const t = info.preferred.?;
    try std.testing.expect(t.interlaced);
    try std.testing.expect(!t.hsync_positive);
}
