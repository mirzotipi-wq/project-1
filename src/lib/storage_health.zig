//! Phase 49 storage-health policy.
//!
//! This is the pure part: bounded counters, a bounded bad-sector table, a
//! retry/recovery ledger and the transition to a pre-failure warning. The
//! device driver owns the actual request retry and calls these methods; the
//! filesystem and shell only read the snapshot. No allocator, no unbounded
//! scan and no device-specific register access live here.

const std = @import("std");

pub const max_bad_blocks: usize = 32;
pub const max_retries: u8 = 3;

pub const Op = enum {
    read,
    write,
    flush,

    pub fn label(self: Op) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .flush => "flush",
        };
    }
};

pub const Reason = enum {
    io,
    timeout,
    unsupported,
    bad_block,

    pub fn label(self: Reason) []const u8 {
        return switch (self) {
            .io => "io",
            .timeout => "timeout",
            .unsupported => "unsupported",
            .bad_block => "bad-block",
        };
    }
};

pub const State = enum {
    healthy,
    degraded,
    failing,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .failing => "failing",
        };
    }
};

pub const BadBlock = struct {
    lba: u64 = 0,
    count: u32 = 0,
    failures: u32 = 0,
};

pub const Snapshot = struct {
    state: State = .healthy,
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    sectors_read: u64 = 0,
    sectors_written: u64 = 0,
    retries: u64 = 0,
    recovered: u64 = 0,
    unrecovered: u64 = 0,
    read_failures: u64 = 0,
    write_failures: u64 = 0,
    flush_failures: u64 = 0,
    bad_refusals: u64 = 0,
    warnings: u32 = 0,
    bad_count: usize = 0,
    last_error: bool = false,
    last_lba: u64 = 0,
    last_count: u32 = 0,
    last_op: Op = .read,
    last_reason: Reason = .io,
};

fn overlap(a_lba: u64, a_count: u32, b_lba: u64, b_count: u32) bool {
    if (a_count == 0 or b_count == 0) return false;
    const a_end = std.math.add(u64, a_lba, a_count) catch return true;
    const b_end = std.math.add(u64, b_lba, b_count) catch return true;
    return a_lba < b_end and b_lba < a_end;
}

pub const Health = struct {
    state: State = .healthy,
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    sectors_read: u64 = 0,
    sectors_written: u64 = 0,
    retries: u64 = 0,
    recovered: u64 = 0,
    unrecovered: u64 = 0,
    read_failures: u64 = 0,
    write_failures: u64 = 0,
    flush_failures: u64 = 0,
    bad_refusals: u64 = 0,
    warnings: u32 = 0,
    warned_recovered: bool = false,
    warned_failure: bool = false,
    warned_bad: bool = false,
    warned_full: bool = false,
    bad: [max_bad_blocks]BadBlock = [_]BadBlock{.{}} ** max_bad_blocks,
    bad_count: usize = 0,
    last_error: bool = false,
    last_lba: u64 = 0,
    last_count: u32 = 0,
    last_op: Op = .read,
    last_reason: Reason = .io,

    pub fn reset(self: *Health) void {
        self.* = .{};
    }

    /// One successful request, whether or not it needed a retry. Sector counts
    /// are the media-era counters an eMMC/SD health surface would expose.
    pub fn complete(self: *Health, op: Op, sectors: u32) void {
        switch (op) {
            .read => {
                self.reads += 1;
                self.sectors_read += sectors;
            },
            .write => {
                self.writes += 1;
                self.sectors_written += sectors;
            },
            .flush => self.flushes += 1,
        }
    }

    /// A failed attempt that will be retried. The first recovered error turns a
    /// healthy disk into a degraded one and raises the warning exactly once.
    pub fn noteRetry(self: *Health, op: Op, reason: Reason, lba: u64, count: u32) void {
        self.retries += 1;
        self.last_error = true;
        self.last_op = op;
        self.last_reason = reason;
        self.last_lba = lba;
        self.last_count = count;
        if (self.state == .healthy) {
            self.state = .degraded;
            if (!self.warned_recovered) {
                self.warned_recovered = true;
                self.warnings += 1;
            }
        }
    }

    /// A request survived at least one failed attempt.
    pub fn noteRecovered(self: *Health, op: Op, lba: u64) void {
        self.recovered += 1;
        self.last_error = true;
        self.last_op = op;
        self.last_lba = lba;
        if (self.state == .failing and self.bad_count == 0) self.state = .degraded;
    }

    /// The request exhausted its retry budget, or the device refused it.
    pub fn noteFailure(self: *Health, op: Op, reason: Reason, lba: u64, count: u32) void {
        self.unrecovered += 1;
        switch (op) {
            .read => self.read_failures += 1,
            .write => self.write_failures += 1,
            .flush => self.flush_failures += 1,
        }
        self.state = .failing;
        self.last_error = true;
        self.last_op = op;
        self.last_reason = reason;
        self.last_lba = lba;
        self.last_count = count;
        if (!self.warned_failure) {
            self.warned_failure = true;
            self.warnings += 1;
        }
    }

    /// Quarantine a range that exhausted its retries. The table is bounded; a
    /// full table is itself a pre-failure warning, never an eviction of an
    /// older bad range.
    pub fn addBad(self: *Health, lba: u64, count: u32) bool {
        if (count == 0) return false;
        var i: usize = 0;
        while (i < self.bad_count) : (i += 1) {
            if (overlap(self.bad[i].lba, self.bad[i].count, lba, count)) {
                self.bad[i].failures += 1;
                self.state = .failing;
                return true;
            }
        }
        if (self.bad_count == self.bad.len) {
            if (!self.warned_full) {
                self.warned_full = true;
                self.warnings += 1;
            }
            return false;
        }
        self.bad[self.bad_count] = .{ .lba = lba, .count = count, .failures = 1 };
        self.bad_count += 1;
        self.state = .failing;
        if (!self.warned_bad) {
            self.warned_bad = true;
            self.warnings += 1;
        }
        return true;
    }

    pub fn isBad(self: *const Health, lba: u64, count: u32) bool {
        var i: usize = 0;
        while (i < self.bad_count) : (i += 1) {
            if (overlap(self.bad[i].lba, self.bad[i].count, lba, count)) return true;
        }
        return false;
    }

    pub fn noteBadRefusal(self: *Health) void {
        self.bad_refusals += 1;
    }

    /// A scrub read all sectors in the range successfully. Remove any bad range
    /// that overlaps it; a fully recovered disk returns to degraded, not healthy,
    /// because the warning history stays visible to the supervisor.
    pub fn clearBad(self: *Health, lba: u64, count: u32) u32 {
        var removed: u32 = 0;
        var i: usize = 0;
        while (i < self.bad_count) {
            if (overlap(self.bad[i].lba, self.bad[i].count, lba, count)) {
                var j = i;
                while (j + 1 < self.bad_count) : (j += 1) self.bad[j] = self.bad[j + 1];
                self.bad_count -= 1;
                removed += 1;
            } else {
                i += 1;
            }
        }
        if (removed != 0 and self.bad_count == 0 and self.state == .failing) self.state = .degraded;
        return removed;
    }

    pub fn badSlice(self: *const Health) []const BadBlock {
        return self.bad[0..self.bad_count];
    }

    pub fn snapshot(self: *const Health) Snapshot {
        return .{
            .state = self.state,
            .reads = self.reads,
            .writes = self.writes,
            .flushes = self.flushes,
            .sectors_read = self.sectors_read,
            .sectors_written = self.sectors_written,
            .retries = self.retries,
            .recovered = self.recovered,
            .unrecovered = self.unrecovered,
            .read_failures = self.read_failures,
            .write_failures = self.write_failures,
            .flush_failures = self.flush_failures,
            .bad_refusals = self.bad_refusals,
            .warnings = self.warnings,
            .bad_count = self.bad_count,
            .last_error = self.last_error,
            .last_lba = self.last_lba,
            .last_count = self.last_count,
            .last_op = self.last_op,
            .last_reason = self.last_reason,
        };
    }
};

test "a recovered media error degrades the disk and raises one warning" {
    var health = Health{};
    health.complete(.read, 8);
    health.noteRetry(.read, .io, 2048, 8);
    health.noteRecovered(.read, 2048);
    const s = health.snapshot();
    try std.testing.expectEqual(State.degraded, s.state);
    try std.testing.expectEqual(@as(u64, 1), s.retries);
    try std.testing.expectEqual(@as(u64, 1), s.recovered);
    try std.testing.expectEqual(@as(u32, 1), s.warnings);
    try std.testing.expectEqual(@as(usize, 0), s.bad_count);
    try std.testing.expectEqual(@as(u64, 1), s.reads);
    try std.testing.expectEqual(@as(u64, 8), s.sectors_read);
}

test "an exhausted retry quarantines a bounded range and scrub clears it" {
    var health = Health{};
    health.noteRetry(.read, .io, 2048, 16);
    health.noteFailure(.read, .io, 2048, 16);
    try std.testing.expect(health.addBad(2048, 16));
    const failed = health.snapshot();
    try std.testing.expectEqual(State.failing, failed.state);
    try std.testing.expectEqual(@as(usize, 1), failed.bad_count);
    try std.testing.expect(health.isBad(2048, 8));
    try std.testing.expect(!health.isBad(2064, 8));
    // Overlapping failures update the existing entry rather than growing without
    // bound, so repeated reads of one sick sector stay one bad range.
    try std.testing.expect(health.addBad(2050, 4));
    try std.testing.expectEqual(@as(usize, 1), health.bad_count);
    try std.testing.expectEqual(@as(u32, 1), health.clearBad(2048, 16));
    const scrubbed = health.snapshot();
    try std.testing.expectEqual(@as(usize, 0), scrubbed.bad_count);
    try std.testing.expectEqual(State.degraded, scrubbed.state);
}

test "the bad-block table is bounded and reports a full table" {
    var health = Health{};
    var i: usize = 0;
    while (i < max_bad_blocks) : (i += 1) {
        try std.testing.expect(health.addBad(@as(u64, i) * 16, 1));
    }
    try std.testing.expectEqual(max_bad_blocks, health.bad_count);
    try std.testing.expect(!health.addBad(4096, 1));
    try std.testing.expectEqual(max_bad_blocks, health.bad_count);
    try std.testing.expect(health.warned_full);
}

test "write and flush failures have their own counters and reasons" {
    var health = Health{};
    health.noteFailure(.write, .timeout, 99, 4);
    health.noteFailure(.flush, .unsupported, 0, 0);
    const s = health.snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.write_failures);
    try std.testing.expectEqual(@as(u64, 1), s.flush_failures);
    try std.testing.expectEqual(Reason.unsupported, s.last_reason);
    try std.testing.expectEqual(Op.flush, s.last_op);
    try std.testing.expectEqual(@as(u32, 0), s.last_count);
}
