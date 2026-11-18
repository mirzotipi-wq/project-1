//! Power, thermal and recovery policy (phase 40).
//!
//! This file is the part of the power subsystem that can be reasoned about
//! without hardware: the thermal ladder and its hysteresis, the dummy-watchdog
//! schedule, and the on-disk power-journal record format. The kernel side
//! (`kernel/thermal.zig`, `kernel/journal.zig`, `kernel/power.zig`) owns the
//! devices and does the I/O.
//!
//! The thermal policy is deliberately a duty cycle rather than a frequency
//! request. QEMU has no DVFS, and neither do many fixed-clock POS boards; what
//! every AArch64 core can do is stop running user work for a measured fraction
//! of scheduler ticks (the idle thread executes `wfi`). The throttle percentage
//! is therefore also the share of ticks that must be given to idle, which makes
//! the behaviour verifiable from the scheduler's own counters.
//!
//! Journal records are fixed 72-byte little-endian records with a CRC32. A file
//! is a sequence of them; decoding stops at the first invalid record, so a
//! torn tail loses at most the unfinished record and never invalidates the
//! shutdown history before it.

const std = @import("std");

// ---------------------------------------------------------------------------
// Thermal policy
// ---------------------------------------------------------------------------

pub const ThermalState = enum { normal, warm, hot, critical };

pub const warm_mc: i32 = 70_000;
pub const hot_mc: i32 = 82_000;
pub const critical_mc: i32 = 92_000;
pub const warm_exit_mc: i32 = 67_000;
pub const hot_exit_mc: i32 = 79_000;
pub const critical_exit_mc: i32 = 89_000;

pub fn thermalLabel(state: ThermalState) []const u8 {
    return switch (state) {
        .normal => "normal",
        .warm => "warm",
        .hot => "hot",
        .critical => "critical",
    };
}

/// The quadrant of scheduler ticks handed to idle at each ladder step:
/// normal 0/4, warm 1/4, hot 2/4, critical 3/4.
pub fn throttlePercent(state: ThermalState) u8 {
    return switch (state) {
        .normal => 0,
        .warm => 25,
        .hot => 50,
        .critical => 75,
    };
}

pub fn idleQuarters(state: ThermalState) u8 {
    return throttlePercent(state) / 25;
}

pub const ThermalPolicy = struct {
    state: ThermalState = .normal,
    temp_mc: i32 = 42_000,
    transitions: u32 = 0,

    /// Move the ladder one sample forward. The exit thresholds are lower than
    /// the entry thresholds, so a temperature hovering on a boundary cannot
    /// oscillate between two throttle levels.
    pub fn sample(self: *ThermalPolicy, mc: i32) ThermalState {
        self.temp_mc = mc;
        const next: ThermalState = switch (self.state) {
            .normal => if (mc >= critical_mc) .critical else if (mc >= hot_mc) .hot else if (mc >= warm_mc) .warm else .normal,
            .warm => if (mc >= critical_mc) .critical else if (mc >= hot_mc) .hot else if (mc < warm_exit_mc) .normal else .warm,
            .hot => if (mc >= critical_mc) .critical else if (mc < hot_exit_mc) .warm else .hot,
            .critical => if (mc < critical_exit_mc) .hot else .critical,
        };
        if (next != self.state) {
            self.state = next;
            self.transitions += 1;
        }
        return self.state;
    }

    pub fn throttle(self: *const ThermalPolicy) u8 {
        return throttlePercent(self.state);
    }

    pub fn shouldIdle(self: *const ThermalPolicy, tick: u64) bool {
        const quarters = idleQuarters(self.state);
        if (quarters == 0) return false;
        return tick % 4 < quarters;
    }
};

// ---------------------------------------------------------------------------
// Watchdog schedule
// ---------------------------------------------------------------------------

pub const watchdog_timeout_ms: u32 = 2_000;
pub const watchdog_kick_ms: u32 = 250;

/// Convert a timeout to the i6300ESB timer preload. The part counts 30 ns PCI
/// ticks and shifts the preload by 15 in its 1 kHz mode, so one preload unit is
/// 983040 ns. The result is clamped to the register's 20 bits.
pub fn watchdogPreload(ms: u32) u32 {
    const ns_per_unit: u64 = 983_040;
    if (ms == 0) return 1;
    const want = @as(u64, ms) * 1_000_000;
    const units = (want + ns_per_unit - 1) / ns_per_unit;
    return @intCast(@min(@max(units, 1), 0x000f_ffff));
}

pub fn watchdogKickDue(now_ms: u64, last_kick_ms: u64) bool {
    return now_ms >= last_kick_ms and now_ms - last_kick_ms >= watchdog_kick_ms;
}

// ---------------------------------------------------------------------------
// Power journal records
// ---------------------------------------------------------------------------

pub const journal_record_size: usize = 72;
pub const journal_max_records: usize = 96;
pub const journal_magic: u32 = 0x4c4e_4a43; // "CJNL" little-endian
pub const journal_version: u8 = 1;
pub const journal_detail = 24;

pub const JournalKind = enum(u8) {
    boot = 1,
    clean_shutdown = 2,
    brownout = 3,
    reboot = 4,
    watchdog_boot = 5,
    thermal = 6,
    selftest = 7,
    power_event = 8,
};

pub fn journalKindLabel(kind: JournalKind) []const u8 {
    return switch (kind) {
        .boot => "boot",
        .clean_shutdown => "clean shutdown",
        .brownout => "brownout shutdown",
        .reboot => "clean reboot",
        .watchdog_boot => "boot after watchdog reset",
        .thermal => "thermal event",
        .selftest => "selftest",
        .power_event => "power event",
    };
}

/// A clean record means the path deliberately brought storage and the journal
/// to rest. A boot record on its own is not clean: it says a session started,
/// but nothing says it ended.
pub fn journalClean(kind: JournalKind) bool {
    return kind == .clean_shutdown or kind == .brownout or kind == .reboot;
}

pub const JournalRecord = struct {
    seq: u64 = 0,
    uptime_ms: u64 = 0,
    wall_sec: u64 = 0,
    temp_mc: i32 = 0,
    throttle_permille: u32 = 0,
    kind: JournalKind = .power_event,
    detail: [journal_detail]u8 = [_]u8{0} ** journal_detail,
    detail_len: u8 = 0,

    pub fn make(kind: JournalKind, detail: []const u8, seq: u64, uptime_ms: u64, wall_sec: u64, temp_mc: i32, throttle_percent: u8) JournalRecord {
        var r = JournalRecord{
            .seq = seq,
            .uptime_ms = uptime_ms,
            .wall_sec = wall_sec,
            .temp_mc = temp_mc,
            .throttle_permille = @as(u32, throttle_percent) * 10,
            .kind = kind,
        };
        const n = @min(detail.len, r.detail.len);
        @memcpy(r.detail[0..n], detail[0..n]);
        r.detail_len = @intCast(n);
        return r;
    }

    pub fn detailSlice(self: *const JournalRecord) []const u8 {
        return self.detail[0..@min(self.detail_len, self.detail.len)];
    }
};

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

fn writeU32(bytes: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], value, .little);
}

fn writeU64(bytes: []u8, off: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[off..][0..8], value, .little);
}

/// CRC32 (reflected 0xEDB88320), the same polynomial the partition tables use.
pub fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (bytes) |b| {
        crc ^= b;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    return ~crc;
}

pub fn encodeRecord(record: JournalRecord, out: *[journal_record_size]u8) void {
    @memset(out, 0);
    writeU32(out, 0, journal_magic);
    out[4] = journal_version;
    out[5] = @intFromEnum(record.kind);
    out[6] = @min(record.detail_len, journal_detail);
    out[7] = 0;
    writeU64(out, 8, record.seq);
    writeU64(out, 16, record.uptime_ms);
    writeU64(out, 24, record.wall_sec);
    std.mem.writeInt(i32, out[32..36], record.temp_mc, .little);
    writeU32(out, 36, record.throttle_permille);
    const n = @min(record.detail_len, journal_detail);
    @memcpy(out[40..][0..n], record.detail[0..n]);
    // bytes 64..67 are reserved and stay zero.
    writeU32(out, 68, crc32(out[0..68]));
}

/// Decode one record. Returns null for a torn, foreign or corrupt record; the
/// caller stops there rather than interpreting bytes whose checksum failed.
pub fn decodeRecord(bytes: []const u8) ?JournalRecord {
    if (bytes.len < journal_record_size) return null;
    if (readU32(bytes, 0) != journal_magic) return null;
    if (bytes[4] != journal_version) return null;
    const kind_raw = bytes[5];
    const kind = std.meta.intToEnum(JournalKind, kind_raw) catch return null;
    const detail_len = bytes[6];
    if (detail_len > journal_detail) return null;
    if (readU32(bytes, 68) != crc32(bytes[0..68])) return null;
    var record = JournalRecord{
        .seq = readU64(bytes, 8),
        .uptime_ms = readU64(bytes, 16),
        .wall_sec = readU64(bytes, 24),
        .temp_mc = std.mem.readInt(i32, bytes[32..36], .little),
        .throttle_permille = readU32(bytes, 36),
        .kind = kind,
        .detail_len = detail_len,
    };
    @memcpy(record.detail[0..detail_len], bytes[40..][0..detail_len]);
    return record;
}

/// Append into a fixed ring. When the journal is full the oldest record is
/// dropped, so the last shutdown is never the record that gets evicted.
pub fn appendRecord(records: []JournalRecord, count: *usize, record: JournalRecord) void {
    if (records.len == 0) return;
    if (count.* < records.len) {
        records[count.*] = record;
        count.* += 1;
        return;
    }
    std.mem.copyForwards(JournalRecord, records[0 .. records.len - 1], records[1..]);
    records[records.len - 1] = record;
}

pub fn encodeJournal(records: []const JournalRecord, out: []u8) ?usize {
    const need = records.len * journal_record_size;
    if (out.len < need) return null;
    for (records, 0..) |record, i| {
        var raw: [journal_record_size]u8 = undefined;
        encodeRecord(record, &raw);
        @memcpy(out[i * journal_record_size ..][0..journal_record_size], &raw);
    }
    return need;
}

/// Decode as many complete records as the prefix holds. A bad record ends the
/// scan; it does not discard the valid history before it.
pub fn decodeJournal(bytes: []const u8, records: []JournalRecord) usize {
    var count: usize = 0;
    var off: usize = 0;
    while (off + journal_record_size <= bytes.len and count < records.len) {
        const record = decodeRecord(bytes[off..][0..journal_record_size]) orelse break;
        records[count] = record;
        count += 1;
        off += journal_record_size;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "thermal ladder enters at the thresholds and throttles each step" {
    var p = ThermalPolicy{};
    try std.testing.expectEqual(ThermalState.normal, p.sample(42_000));
    try std.testing.expectEqual(@as(u8, 0), p.throttle());
    try std.testing.expectEqual(ThermalState.warm, p.sample(70_000));
    try std.testing.expectEqual(@as(u8, 25), p.throttle());
    try std.testing.expectEqual(ThermalState.hot, p.sample(82_000));
    try std.testing.expectEqual(@as(u8, 50), p.throttle());
    try std.testing.expectEqual(ThermalState.critical, p.sample(92_000));
    try std.testing.expectEqual(@as(u8, 75), p.throttle());
    try std.testing.expectEqual(@as(u32, 3), p.transitions);
}

test "thermal hysteresis prevents boundary oscillation" {
    var p = ThermalPolicy{};
    _ = p.sample(90_000); // hot
    _ = p.sample(80_000);
    try std.testing.expectEqual(ThermalState.hot, p.state);
    _ = p.sample(79_000);
    try std.testing.expectEqual(ThermalState.hot, p.state);
    _ = p.sample(78_999);
    try std.testing.expectEqual(ThermalState.warm, p.state);
    _ = p.sample(68_000);
    try std.testing.expectEqual(ThermalState.warm, p.state);
    _ = p.sample(66_999);
    try std.testing.expectEqual(ThermalState.normal, p.state);
}

test "thermal idle pattern is an exact duty cycle" {
    var p = ThermalPolicy{};
    _ = p.sample(42_000);
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(!p.shouldIdle(i));
    }
    _ = p.sample(70_000);
    var warm: u32 = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        if (p.shouldIdle(i)) warm += 1;
    }
    try std.testing.expectEqual(@as(u32, 25), warm);
    _ = p.sample(82_000);
    var hot: u32 = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        if (p.shouldIdle(i)) hot += 1;
    }
    try std.testing.expectEqual(@as(u32, 50), hot);
    _ = p.sample(92_000);
    var critical: u32 = 0;
    i = 0;
    while (i < 100) : (i += 1) {
        if (p.shouldIdle(i)) critical += 1;
    }
    try std.testing.expectEqual(@as(u32, 75), critical);
}

test "watchdog preload converts milliseconds into i6300esb units" {
    try std.testing.expectEqual(@as(u32, 2035), watchdogPreload(2_000));
    try std.testing.expectEqual(@as(u32, 1018), watchdogPreload(1_000));
    try std.testing.expectEqual(@as(u32, 1), watchdogPreload(0));
    try std.testing.expect(watchdogPreload(60_000) <= 0x000f_ffff);
}

test "watchdog kick schedule is rate limited and handles wrap" {
    try std.testing.expect(watchdogKickDue(250, 0));
    try std.testing.expect(!watchdogKickDue(249, 0));
    try std.testing.expect(!watchdogKickDue(500, 300));
    try std.testing.expect(watchdogKickDue(550, 300));
    try std.testing.expect(!watchdogKickDue(0, 100)); // reset, not a wrap kick
}

test "journal record round trip preserves every field" {
    const r = JournalRecord.make(.brownout, "brownout asserted", 7, 1234, 1_700_000_000, 94_500, 75);
    var raw: [journal_record_size]u8 = undefined;
    encodeRecord(r, &raw);
    const got = decodeRecord(&raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(r.seq, got.seq);
    try std.testing.expectEqual(r.uptime_ms, got.uptime_ms);
    try std.testing.expectEqual(r.wall_sec, got.wall_sec);
    try std.testing.expectEqual(r.temp_mc, got.temp_mc);
    try std.testing.expectEqual(r.throttle_permille, got.throttle_permille);
    try std.testing.expectEqual(r.kind, got.kind);
    try std.testing.expectEqualStrings("brownout asserted", got.detailSlice());
}

test "journal rejects a corrupt or foreign record" {
    const r = JournalRecord.make(.boot, "boot", 1, 1, 1, 42_000, 0);
    var raw: [journal_record_size]u8 = undefined;
    encodeRecord(r, &raw);
    try std.testing.expect(decodeRecord(&raw) != null);
    raw[45] ^= 0x40;
    try std.testing.expect(decodeRecord(&raw) == null);
    raw[45] ^= 0x40;
    raw[4] = 9;
    try std.testing.expect(decodeRecord(&raw) == null);
}

test "journal scan keeps the valid prefix before a torn tail" {
    var records: [4]JournalRecord = undefined;
    records[0] = JournalRecord.make(.boot, "boot", 1, 10, 100, 42_000, 0);
    records[1] = JournalRecord.make(.clean_shutdown, "clean", 2, 20, 200, 43_000, 0);
    var bytes: [4 * journal_record_size]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 2 * journal_record_size), encodeJournal(records[0..2], &bytes));
    const decoded = decodeJournal(&bytes, records[0..]);
    try std.testing.expectEqual(@as(usize, 2), decoded);
    try std.testing.expect(journalClean(records[1].kind));
    try std.testing.expect(!journalClean(records[0].kind));
    // Damage the second record, not the unused tail beyond the encoded
    // prefix: the scan must return the one record before the damage.
    bytes[journal_record_size + 10] ^= 1;
    const prefix = decodeJournal(&bytes, records[0..]);
    try std.testing.expectEqual(@as(usize, 1), prefix);
}

test "journal ring evicts the oldest record only when full" {
    var records: [3]JournalRecord = undefined;
    var count: usize = 0;
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        appendRecord(&records, &count, JournalRecord.make(.power_event, "event", i, i, i, 42_000, 0));
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(u64, 2), records[0].seq);
    try std.testing.expectEqual(@as(u64, 4), records[2].seq);
}

test "journal detail is bounded and the clean predicate covers every clean kind" {
    const long = "this detail is much longer than twenty-four bytes";
    const r = JournalRecord.make(.clean_shutdown, long, 1, 1, 1, 0, 0);
    try std.testing.expectEqual(@as(usize, journal_detail), r.detailSlice().len);
    try std.testing.expect(journalClean(.clean_shutdown));
    try std.testing.expect(journalClean(.brownout));
    try std.testing.expect(journalClean(.reboot));
    try std.testing.expect(!journalClean(.boot));
    try std.testing.expect(!journalClean(.watchdog_boot));
    try std.testing.expect(!journalClean(.thermal));
}
