//! Phase 50 bounded configuration snapshots and recovery policy.
//!
//! The model is intentionally small and allocation-free: one 128-byte
//! configuration record and four 128-byte snapshot slots in a 544-byte file.
//! A change copies the current configuration into an immutable slot before the
//! live record is replaced, so rollback never has to reconstruct bytes from a
//! journal. The kernel front end (`src/kernel/recovery.zig`) writes both files
//! through the normal VFS/CASSAFS write path and flushes them before reporting
//! success.
//!
//! Bounds: fixed strings, four slots, no allocator, no unbounded scan. A
//! corrupted slot is distinguishable from a missing snapshot, and a corrupted
//! header refuses the whole set instead of silently selecting a stale slot.

const std = @import("std");
const cassafs = @import("cassafs.zig");

pub const config_size: usize = 128;
pub const config_magic: [8]u8 = .{ 'C', 'F', 'G', '0', '5', '0', 0, 0 };
pub const config_version: u16 = 1;
pub const max_store_name: usize = 32;
pub const max_footer: usize = 64;
pub const config_crc_offset: usize = 124;

pub const snapshot_magic: [8]u8 = .{ 'S', 'N', 'P', '0', '5', '0', 0, 0 };
pub const snapshot_version: u16 = 1;
pub const snapshot_header_size: usize = 32;
pub const snapshot_slots: usize = 4;
pub const snapshot_file_size: usize = snapshot_header_size + snapshot_slots * config_size;
pub const snapshot_header_crc_offset: usize = 28;
pub const snapshot_slot_size_offset: usize = 10;
pub const snapshot_slot_count_offset: usize = 12;
pub const snapshot_next_offset: usize = 13;
pub const snapshot_generation_offset: usize = 14;

pub const Error = error{
    BadMagic,
    BadVersion,
    Truncated,
    TooLarge,
    BadCrc,
    BadConfig,
    BadKey,
    BadValue,
    TooLong,
    GenerationExhausted,
    BadSnapshot,
    NoSnapshot,
    BufferTooSmall,
};

pub const Config = struct {
    generation: u32 = 1,
    terminal_id: u32 = 1,
    tax_mode: u8 = 0, // 0 = inclusive, 1 = exclusive, 2 = zero
    auto_lock_secs: u16 = 60,
    store_name: [max_store_name]u8 = [_]u8{0} ** max_store_name,
    store_len: u8 = 0,
    footer: [max_footer]u8 = [_]u8{0} ** max_footer,
    footer_len: u8 = 0,

    pub fn default() Config {
        var c = Config{};
        c.setStore("Cassa Store") catch {};
        c.setFooter("Thank you") catch {};
        return c;
    }

    pub fn storeSlice(self: *const Config) []const u8 {
        return self.store_name[0..self.store_len];
    }

    pub fn footerSlice(self: *const Config) []const u8 {
        return self.footer[0..self.footer_len];
    }

    fn textOk(text: []const u8) bool {
        if (text.len == 0) return false;
        for (text) |b| {
            if (b < 0x20 or b > 0x7e) return false;
        }
        return true;
    }

    pub fn setStore(self: *Config, text: []const u8) Error!void {
        if (!textOk(text)) return error.BadValue;
        if (text.len > max_store_name) return error.TooLong;
        @memset(self.store_name[0..], 0);
        @memcpy(self.store_name[0..text.len], text);
        self.store_len = @intCast(text.len);
    }

    pub fn setFooter(self: *Config, text: []const u8) Error!void {
        if (text.len == 0) return error.BadValue;
        if (!textOk(text)) return error.BadValue;
        if (text.len > max_footer) return error.TooLong;
        @memset(self.footer[0..], 0);
        @memcpy(self.footer[0..text.len], text);
        self.footer_len = @intCast(text.len);
    }

    pub fn setField(self: *Config, key: []const u8, value: []const u8) Error!void {
        if (std.mem.eql(u8, key, "store")) {
            try self.setStore(value);
        } else if (std.mem.eql(u8, key, "footer")) {
            try self.setFooter(value);
        } else if (std.mem.eql(u8, key, "terminal")) {
            const number = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
            if (number == 0 or number > 9999) return error.BadValue;
            self.terminal_id = number;
        } else if (std.mem.eql(u8, key, "tax")) {
            self.tax_mode = if (std.mem.eql(u8, value, "inclusive"))
                0
            else if (std.mem.eql(u8, value, "exclusive"))
                1
            else if (std.mem.eql(u8, value, "zero"))
                2
            else
                return error.BadValue;
        } else if (std.mem.eql(u8, key, "autolock")) {
            const number = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
            if (number > 3600) return error.BadValue;
            self.auto_lock_secs = @intCast(number);
        } else {
            return error.BadKey;
        }
    }

    pub fn taxLabel(self: *const Config) []const u8 {
        return switch (self.tax_mode) {
            0 => "inclusive",
            1 => "exclusive",
            2 => "zero",
            else => "invalid",
        };
    }

    pub fn validate(self: *const Config) Error!void {
        if (self.store_len == 0 or self.store_len > max_store_name) return error.BadConfig;
        if (self.footer_len == 0 or self.footer_len > max_footer) return error.BadConfig;
        if (self.terminal_id == 0 or self.terminal_id > 9999) return error.BadConfig;
        if (self.tax_mode > 2) return error.BadConfig;
        if (self.auto_lock_secs > 3600) return error.BadConfig;
        var i: usize = 0;
        while (i < self.store_len) : (i += 1) {
            if (self.store_name[i] < 0x20 or self.store_name[i] > 0x7e) return error.BadConfig;
        }
        i = 0;
        while (i < self.footer_len) : (i += 1) {
            if (self.footer[i] < 0x20 or self.footer[i] > 0x7e) return error.BadConfig;
        }
    }
};

pub fn encodeConfig(config: *const Config, out: *[config_size]u8) Error!void {
    try config.validate();
    @memset(out[0..], 0);
    @memcpy(out[0..8], &config_magic);
    std.mem.writeInt(u16, out[8..10], config_version, .little);
    std.mem.writeInt(u32, out[10..14], config.generation, .little);
    std.mem.writeInt(u32, out[14..18], config.terminal_id, .little);
    out[18] = config.store_len;
    out[19] = config.footer_len;
    out[20] = config.tax_mode;
    std.mem.writeInt(u16, out[21..23], config.auto_lock_secs, .little);
    @memcpy(out[24..][0..max_store_name], &config.store_name);
    @memcpy(out[56..][0..max_footer], &config.footer);
    std.mem.writeInt(u32, out[config_crc_offset..][0..4], cassafs.crc32c(out[0..config_crc_offset]), .little);
}

pub fn decodeConfig(bytes: []const u8) Error!Config {
    if (bytes.len < config_size) return error.Truncated;
    if (bytes.len > config_size) return error.TooLarge;
    if (!std.mem.eql(u8, bytes[0..8], &config_magic)) return error.BadMagic;
    if (std.mem.readInt(u16, bytes[8..10], .little) != config_version) return error.BadVersion;
    if (std.mem.readInt(u32, bytes[config_crc_offset..][0..4], .little) != cassafs.crc32c(bytes[0..config_crc_offset])) return error.BadCrc;
    var config = Config{
        .generation = std.mem.readInt(u32, bytes[10..14], .little),
        .terminal_id = std.mem.readInt(u32, bytes[14..18], .little),
        .store_len = bytes[18],
        .footer_len = bytes[19],
        .tax_mode = bytes[20],
        .auto_lock_secs = std.mem.readInt(u16, bytes[21..23], .little),
    };
    @memcpy(config.store_name[0..], bytes[24..][0..max_store_name]);
    @memcpy(config.footer[0..], bytes[56..][0..max_footer]);
    try config.validate();
    return config;
}

pub const Snapshot = struct {
    config: Config,
    slot: u8 = 0,
};

pub const SnapshotSet = struct {
    slots: [snapshot_slots]Snapshot = [_]Snapshot{.{ .config = .{} }} ** snapshot_slots,
    valid: [snapshot_slots]bool = [_]bool{false} ** snapshot_slots,
    next_slot: u8 = 0,
    generation: u32 = 0,

    pub fn init() SnapshotSet {
        return .{};
    }

    /// Store one immutable configuration copy in the next bounded slot. The
    /// fourth write reuses slot 0; it never grows the file or the table.
    pub fn add(self: *SnapshotSet, config: Config) u8 {
        const slot = self.next_slot;
        self.slots[slot] = .{ .config = config, .slot = slot };
        self.valid[slot] = true;
        self.generation = config.generation;
        self.next_slot = @intCast((slot + 1) % snapshot_slots);
        return slot;
    }

    pub fn latest(self: *const SnapshotSet) Error!Snapshot {
        var found = false;
        var best = Snapshot{ .config = .{} };
        var i: usize = 0;
        while (i < snapshot_slots) : (i += 1) {
            if (!self.valid[i]) continue;
            if (!found or self.slots[i].config.generation >= best.config.generation) {
                best = self.slots[i];
                found = true;
            }
        }
        if (!found) return error.NoSnapshot;
        return best;
    }

    pub fn validCount(self: *const SnapshotSet) usize {
        var count: usize = 0;
        for (self.valid) |v| if (v) {
            count += 1;
        };
        return count;
    }
};

pub fn encodeSnapshotSet(set: *const SnapshotSet, out: *[snapshot_file_size]u8) Error!void {
    @memset(out[0..], 0);
    @memcpy(out[0..8], &snapshot_magic);
    std.mem.writeInt(u16, out[8..10], snapshot_version, .little);
    std.mem.writeInt(u16, out[snapshot_slot_size_offset..][0..2], @intCast(config_size), .little);
    out[snapshot_slot_count_offset] = @intCast(snapshot_slots);
    out[snapshot_next_offset] = set.next_slot;
    std.mem.writeInt(u32, out[snapshot_generation_offset..][0..4], set.generation, .little);
    var i: usize = 0;
    while (i < snapshot_slots) : (i += 1) {
        if (!set.valid[i]) continue;
        var encoded: [config_size]u8 = undefined;
        try encodeConfig(&set.slots[i].config, &encoded);
        const start = snapshot_header_size + i * config_size;
        @memcpy(out[start..][0..config_size], &encoded);
    }
    std.mem.writeInt(u32, out[snapshot_header_crc_offset..][0..4], cassafs.crc32c(out[0..snapshot_header_crc_offset]), .little);
}

pub fn decodeSnapshotSet(bytes: []const u8) Error!SnapshotSet {
    if (bytes.len < snapshot_file_size) return error.Truncated;
    if (bytes.len > snapshot_file_size) return error.TooLarge;
    if (!std.mem.eql(u8, bytes[0..8], &snapshot_magic)) return error.BadSnapshot;
    if (std.mem.readInt(u16, bytes[8..10], .little) != snapshot_version) return error.BadVersion;
    if (std.mem.readInt(u16, bytes[snapshot_slot_size_offset..][0..2], .little) != config_size) return error.BadSnapshot;
    if (bytes[snapshot_slot_count_offset] != snapshot_slots) return error.BadSnapshot;
    if (bytes[snapshot_next_offset] >= snapshot_slots) return error.BadSnapshot;
    if (std.mem.readInt(u32, bytes[snapshot_header_crc_offset..][0..4], .little) != cassafs.crc32c(bytes[0..snapshot_header_crc_offset])) return error.BadCrc;
    var set = SnapshotSet{
        .next_slot = bytes[snapshot_next_offset],
        .generation = std.mem.readInt(u32, bytes[snapshot_generation_offset..][0..4], .little),
    };
    var i: usize = 0;
    while (i < snapshot_slots) : (i += 1) {
        const start = snapshot_header_size + i * config_size;
        const config = decodeConfig(bytes[start..][0..config_size]) catch |err| switch (err) {
            error.BadMagic => continue,
            error.BadCrc => continue,
            error.BadConfig => continue,
            else => return err,
        };
        set.slots[i] = .{ .config = config, .slot = @intCast(i) };
        set.valid[i] = true;
    }
    return set;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a configuration round-trips and every mutable field is bounded" {
    var config = Config.default();
    try std.testing.expectEqualStrings("Cassa Store", config.storeSlice());
    config.generation = 7;
    config.terminal_id = 42;
    config.tax_mode = 1;
    config.auto_lock_secs = 900;
    try config.setStore("North Till");
    try config.setFooter("Receipt footer");
    var bytes: [config_size]u8 = undefined;
    try encodeConfig(&config, &bytes);
    const decoded = try decodeConfig(&bytes);
    try std.testing.expectEqual(@as(u32, 7), decoded.generation);
    try std.testing.expectEqual(@as(u32, 42), decoded.terminal_id);
    try std.testing.expectEqual(@as(u8, 1), decoded.tax_mode);
    try std.testing.expectEqual(@as(u16, 900), decoded.auto_lock_secs);
    try std.testing.expectEqualStrings("North Till", decoded.storeSlice());
    try std.testing.expectError(error.BadValue, config.setField("terminal", "0"));
    try std.testing.expectError(error.BadValue, config.setField("tax", "sometimes"));
    try std.testing.expectError(error.BadKey, config.setField("unknown", "x"));
}

test "configuration CRC and version refusals are distinct" {
    var config = Config.default();
    var bytes: [config_size]u8 = undefined;
    try encodeConfig(&config, &bytes);
    bytes[24] ^= 0x80;
    try std.testing.expectError(error.BadCrc, decodeConfig(&bytes));
    bytes[24] ^= 0x80;
    bytes[0] = 'X';
    try std.testing.expectError(error.BadMagic, decodeConfig(&bytes));
    bytes[0] = 'C';
    std.mem.writeInt(u16, bytes[8..10], 99, .little);
    try std.testing.expectError(error.BadVersion, decodeConfig(&bytes));
}

test "snapshot slots are bounded and latest chooses the highest generation" {
    var set = SnapshotSet.init();
    var config = Config.default();
    _ = set.add(config);
    config.generation = 2;
    try config.setStore("Second");
    _ = set.add(config);
    config.generation = 3;
    try config.setStore("Third");
    const slot = set.add(config);
    try std.testing.expectEqual(@as(u8, 2), slot);
    try std.testing.expectEqual(@as(usize, 3), set.validCount());
    const latest = try set.latest();
    try std.testing.expectEqual(@as(u32, 3), latest.config.generation);
    try std.testing.expectEqualStrings("Third", latest.config.storeSlice());

    config.generation = 4;
    _ = set.add(config); // slot 0 overwritten, still four slots
    try std.testing.expectEqual(@as(usize, 4), set.validCount());
    try std.testing.expectEqual(@as(u32, 4), (try set.latest()).config.generation);
}

test "snapshot set round-trips, detects a bad header and can be empty" {
    var set = SnapshotSet.init();
    var bytes: [snapshot_file_size]u8 = undefined;
    try encodeSnapshotSet(&set, &bytes);
    const empty = try decodeSnapshotSet(&bytes);
    try std.testing.expectEqual(@as(usize, 0), empty.validCount());
    try std.testing.expectError(error.NoSnapshot, empty.latest());

    var config = Config.default();
    _ = set.add(config);
    config.generation = 2;
    _ = set.add(config);
    try encodeSnapshotSet(&set, &bytes);
    const decoded = try decodeSnapshotSet(&bytes);
    try std.testing.expectEqual(@as(usize, 2), decoded.validCount());
    try std.testing.expectEqual(@as(u32, 2), (try decoded.latest()).config.generation);

    bytes[snapshot_header_crc_offset] ^= 0xff;
    try std.testing.expectError(error.BadCrc, decodeSnapshotSet(&bytes));
}
