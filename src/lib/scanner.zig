//! Barcode scanner fast path (phase 38).
//!
//! A USB barcode scanner is a keyboard that types very fast. The OS therefore
//! cannot treat its keystrokes as typing: a scan must reach the POS application
//! as **one atomic event**, in order, with the individual keystrokes suppressed
//! — otherwise a cart line would receive ten separate digit events and the
//! application would have to guess where the scan started and ended.
//!
//! This module is that decision, and nothing else: keys go in with timestamps,
//! and out comes either silence (the candidate is still being collected), the
//! collected bytes (the burst was not a scan, so the keystrokes are released
//! unchanged and in order), or one complete barcode.
//!
//! The candidate rules, all configurable:
//!
//!   * only characters in the scan charset start or continue a candidate
//!     (digits and `-` by default: what EAN/UPC/Code-128 retail scans use),
//!   * every gap between keys must stay within `gap_timeout_ms`,
//!   * the whole scan must finish within `max_duration_ms`,
//!   * the suffix (Enter by default) commits a scan of at least `min_length`,
//!   * a configured prefix must be matched before the payload starts.
//!
//! A burst that breaks a rule is *released*, not swallowed: the held characters
//! and the key that broke it are handed back as ordinary keystrokes, so a
//! cashier typing a quantity instead of scanning it sees exactly what they
//! typed. That is the property the tests below pin down.

const std = @import("std");

pub const max_payload = 64;
const max_prefix = 8;
const release_size = max_payload + max_prefix + 4;

pub const Config = struct {
    /// Characters a scanner types before the payload. Empty means none.
    prefix: []const u8 = "",
    /// Character that commits a scan. Enter (CR) is what scanners send.
    suffix: u8 = '\r',
    min_length: usize = 4,
    max_length: usize = max_payload,
    /// A gap longer than this ends the candidate: humans type slower.
    gap_timeout_ms: u32 = 40,
    /// The whole scan must fit in this window.
    max_duration_ms: u32 = 500,
    /// Only digits and `-` are payload characters. Turning this off accepts
    /// alphanumeric symbologies (Code 39/128 in their letter forms).
    digits_only: bool = true,
};

pub const Barcode = struct {
    text: [max_payload]u8 = [_]u8{0} ** max_payload,
    len: usize = 0,
    /// First key to committing suffix: the scanner/HID burst.
    latency_ms: u32 = 0,
    first_ms: u64 = 0,

    pub fn slice(self: *const Barcode) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Outcome = union(enum) {
    /// Consumed while matching a prefix; no key reaches the application yet.
    swallowed,
    /// Held for the candidate window; no key reaches the application yet.
    held,
    /// One atomic scan.
    barcode: Barcode,
    /// The candidate was not a scan: these bytes must be emitted as keystrokes,
    /// in this order, followed by nothing else.
    release: []const u8,
};

pub const Stats = struct {
    scans: u64 = 0,
    released: u64 = 0,
    swallowed_prefix: u64 = 0,
    short_scans: u64 = 0,
    timeouts: u64 = 0,
    overflows: u64 = 0,
    last_latency_ms: u32 = 0,
    max_latency_ms: u32 = 0,
    /// Keys currently held inside a candidate (0 when idle).
    held_keys: usize = 0,
};

pub const Scanner = struct {
    config: Config = .{},
    /// Payload being collected.
    buffer: [max_payload]u8 = [_]u8{0} ** max_payload,
    len: usize = 0,
    /// Prefix progress while matching.
    prefix_pos: usize = 0,
    /// The prefix matched and payload collection has begun.
    active: bool = false,
    /// Keys held so they can be released as one run.
    held: [release_size]u8 = [_]u8{0} ** release_size,
    held_len: usize = 0,
    first_ms: u64 = 0,
    last_ms: u64 = 0,
    drop: [release_size]u8 = [_]u8{0} ** release_size,
    stats: Stats = .{},

    pub fn reset(self: *Scanner) void {
        self.len = 0;
        self.prefix_pos = 0;
        self.active = false;
        self.held_len = 0;
        self.first_ms = 0;
        self.last_ms = 0;
        self.stats.held_keys = 0;
    }

    fn inCharset(self: *const Scanner, ch: u8) bool {
        if (ch >= '0' and ch <= '9') return true;
        if (ch == '-') return true;
        if (!self.config.digits_only) {
            const lower = std.ascii.toLower(ch);
            if (lower >= 'a' and lower <= 'z') return true;
            if (ch == '.' or ch == ' ') return true;
        }
        return false;
    }

    fn hold(self: *Scanner, ch: u8) bool {
        if (self.held_len >= self.held.len) {
            self.stats.overflows += 1;
            return false;
        }
        self.held[self.held_len] = ch;
        self.held_len += 1;
        self.stats.held_keys = self.held_len;
        return true;
    }

    /// Abandon the candidate: the held keys plus `extra` are released in order.
    fn abandon(self: *Scanner, extra: ?u8) Outcome {
        var n: usize = 0;
        for (self.held[0..self.held_len]) |ch| {
            self.drop[n] = ch;
            n += 1;
        }
        if (extra) |ch| {
            if (n < self.drop.len) {
                self.drop[n] = ch;
                n += 1;
            }
        }
        const released = n;
        self.held_len = 0;
        self.stats.held_keys = 0;
        self.len = 0;
        self.active = false;
        self.prefix_pos = 0;
        self.stats.released += 1;
        return .{ .release = self.drop[0..released] };
    }

    /// Feed one typed character with the time it arrived.
    pub fn feed(self: *Scanner, ch: u8, now_ms: u64) Outcome {
        const cfg = self.config;

        // A candidate in progress ends when the burst does.
        if (self.held_len > 0 or self.prefix_pos > 0) {
            const gap = now_ms -| self.last_ms;
            const duration = now_ms -| self.first_ms;
            if (gap > cfg.gap_timeout_ms or duration > cfg.max_duration_ms) {
                self.stats.timeouts += 1;
                return self.abandon(ch);
            }
        }

        // Prefix matching comes first, and a mismatched prefix is released
        // keystroke by keystroke: the user really did type those characters.
        if (cfg.prefix.len > 0 and !self.active and self.len == 0) {
            if (self.prefix_pos < cfg.prefix.len) {
                if (ch == cfg.prefix[self.prefix_pos]) {
                    if (!self.hold(ch)) return self.abandon(null);
                    if (self.prefix_pos == 0) {
                        self.first_ms = now_ms;
                    }
                    self.last_ms = now_ms;
                    self.prefix_pos += 1;
                    self.stats.swallowed_prefix += 1;
                    if (self.prefix_pos == cfg.prefix.len) {
                        // Prefix complete: it is not part of the payload, so
                        // the held prefix bytes are dropped.
                        self.held_len = 0;
                        self.stats.held_keys = 0;
                        self.active = true;
                        self.first_ms = now_ms;
                    }
                    return .swallowed;
                }
                // Mismatch: release what matched and this key.
                return self.abandon(ch);
            }
        } else if (cfg.prefix.len == 0) {
            self.active = true;
        }

        if (!self.active) {
            // No prefix and not active cannot happen with the rule above, but
            // a state machine must always have an answer.
            return self.abandon(ch);
        }

        // Suffix commits (or releases, when the payload is too short).
        if (ch == cfg.suffix) {
            if (self.len >= cfg.min_length) {
                var barcode = Barcode{
                    .len = self.len,
                    .first_ms = self.first_ms,
                    .latency_ms = @intCast(now_ms -| self.first_ms),
                };
                @memcpy(barcode.text[0..self.len], self.buffer[0..self.len]);
                self.stats.scans += 1;
                self.stats.last_latency_ms = barcode.latency_ms;
                if (barcode.latency_ms > self.stats.max_latency_ms) {
                    self.stats.max_latency_ms = barcode.latency_ms;
                }
                self.reset();
                return .{ .barcode = barcode };
            }
            self.stats.short_scans += 1;
            return self.abandon(ch);
        }

        // A payload character continues the candidate.
        if (self.inCharset(ch)) {
            if (self.len >= cfg.max_length or !self.hold(ch)) {
                self.stats.overflows += 1;
                return self.abandon(ch);
            }
            if (self.len == 0) self.first_ms = now_ms;
            self.buffer[self.len] = ch;
            self.len += 1;
            self.last_ms = now_ms;
            return .held;
        }

        // Anything else ends the candidate and is typed normally.
        return self.abandon(ch);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn feedAll(s: *Scanner, text: []const u8, start_ms: u64, step_ms: u64) !?Barcode {
    var now = start_ms;
    var out: ?Barcode = null;
    for (text) |ch| {
        const outcome = s.feed(ch, now);
        switch (outcome) {
            .barcode => |b| out = b,
            .release => |bytes| {
                // A scan must never be released piecemeal.
                try testing.expect(bytes.len > 0);
            },
            else => {},
        }
        now += step_ms;
    }
    return out;
}

test "a fast digit burst ending in Enter is one barcode" {
    var s = Scanner{};
    const barcode = (try feedAll(&s, "5901234123457\r", 1000, 1)).?;
    try testing.expectEqualStrings("5901234123457", barcode.slice());
    try testing.expectEqual(@as(u32, 13), barcode.latency_ms);
    try testing.expectEqual(@as(u32, 13), s.stats.last_latency_ms);
    try testing.expectEqual(@as(u64, 1), s.stats.scans);
    try testing.expectEqual(@as(usize, 0), s.stats.held_keys);
}

test "letters are typed, never scanned" {
    var s = Scanner{};
    var now: u64 = 0;
    for ("help\r") |ch| {
        const outcome = s.feed(ch, now);
        switch (outcome) {
            .release => |bytes| try testing.expectEqual(ch, bytes[bytes.len - 1]),
            .held, .swallowed => try testing.expect(ch >= '0' and ch <= '9'),
            .barcode => return error.UnexpectedBarcode,
        }
        now += 2;
    }
    try testing.expectEqual(@as(u64, 0), s.stats.scans);
}

test "a short digit run is released as keystrokes, Enter included" {
    var s = Scanner{};
    const outcome = s.feed('1', 0);
    try testing.expect(outcome == .held);
    _ = s.feed('2', 1);
    const last = s.feed('\r', 2);
    try testing.expect(last == .release);
    try testing.expectEqualStrings("12\r", last.release);
    try testing.expectEqual(@as(u64, 1), s.stats.short_scans);
}

test "a slow human typing digits is not a scan" {
    var s = Scanner{};
    _ = s.feed('1', 0);
    // 200 ms later: outside the 40 ms burst window.
    const outcome = s.feed('2', 200);
    try testing.expect(outcome == .release);
    try testing.expectEqualStrings("1" ++ [_]u8{'2'}, outcome.release);
    _ = s.feed('3', 201);
    _ = s.feed('4', 202);
    const end = s.feed('\r', 203);
    // Only 3 and 4 are in the new candidate: too short, so it is released.
    try testing.expect(end == .release);
    try testing.expectEqualStrings("34\r", end.release);
    try testing.expectEqual(@as(u64, 0), s.stats.scans);
}

test "a configured prefix must match before the payload" {
    var s = Scanner{};
    s.config.prefix = "$$";
    var outcome = s.feed('$', 0);
    try testing.expect(outcome == .swallowed);
    outcome = s.feed('$', 1);
    try testing.expect(outcome == .swallowed);
    outcome = s.feed('4', 2);
    try testing.expect(outcome == .held);
    _ = s.feed('0', 3);
    _ = s.feed('0', 4);
    _ = s.feed('1', 5);
    const end = s.feed('\r', 6);
    try testing.expect(end == .barcode);
    try testing.expectEqualStrings("4001", end.barcode.slice());
    try testing.expectEqual(@as(u64, 2), s.stats.swallowed_prefix);
}

test "a wrong prefix is released as typed characters" {
    var s = Scanner{};
    s.config.prefix = "$$";
    _ = s.feed('$', 0);
    const outcome = s.feed('x', 1);
    try testing.expect(outcome == .release);
    try testing.expectEqualStrings("$x", outcome.release);
}

test "alphanumeric symbologies are accepted when configured" {
    var s = Scanner{};
    s.config.digits_only = false;
    const barcode = (try feedAll(&s, "ABC123\r", 0, 1)).?;
    // Payload characters are preserved exactly as the scanner sent them.
    try testing.expectEqualStrings("ABC123", barcode.slice());
}

test "a payload longer than the cap is released, not truncated" {
    var s = Scanner{};
    s.config.max_length = 6;
    var now: u64 = 0;
    var released: usize = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        switch (s.feed('7', now)) {
            .release => |bytes| released += bytes.len,
            else => {},
        }
        now += 1;
    }
    try testing.expect(released > 0);
    try testing.expectEqual(@as(u64, 1), s.stats.overflows);
    // A letter flushes whatever the overflow left pending, in order.
    const flush = s.feed('x', now);
    try testing.expect(flush == .release);
    try testing.expectEqual(@as(usize, 0), s.stats.held_keys);
}

test "latency is measured from the first payload key" {
    var s = Scanner{};
    _ = s.feed('9', 5000);
    _ = s.feed('9', 5003);
    _ = s.feed('9', 5007);
    _ = s.feed('9', 5011);
    const end = s.feed('\r', 5012);
    try testing.expectEqual(@as(u32, 12), end.barcode.latency_ms);
}
