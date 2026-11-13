//! Structured kernel logging with an in-memory ring buffer for post-mortems.
//!
//! Phase 4 of the plan. Output format:
//!   [    12.345678] INFO  boot     message
//! Timestamps come straight from the generic counter so logging works before
//! the timer driver exists (as long as CNTFRQ is readable).

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const cpu = @import("../arch/aarch64/cpu.zig");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warn => "WARN ",
            .info => "INFO ",
            .debug => "DEBUG",
        };
    }
};

/// Messages above this level are compiled out at the call site.
pub const max_level: Level = if (@import("builtin").mode == .Debug) .debug else .info;

/// Runtime filter, adjusted by the shell.
pub var filter: Level = max_level;

// ---------------------------------------------------------------------------
// Counter -> nanoseconds
// ---------------------------------------------------------------------------

var counter_freq: u64 = 0;
var counter_epoch: u64 = 0;

pub fn setCounterFrequency(freq: u64) void {
    counter_freq = freq;
    counter_epoch = cpu.cntPct();
}

pub fn uptimeNanos() u64 {
    if (counter_freq == 0) return 0;
    const delta = cpu.cntPct() -% counter_epoch;
    return @intCast(@as(u128, delta) * 1_000_000_000 / counter_freq);
}

// ---------------------------------------------------------------------------
// Ring buffer
// ---------------------------------------------------------------------------

const ring_capacity = 16 * 1024;
var ring: [ring_capacity]u8 = undefined;
var ring_len: usize = 0;
var ring_head: usize = 0;

fn ringAppend(bytes: []const u8) void {
    for (bytes) |b| {
        ring[ring_head] = b;
        ring_head = (ring_head + 1) % ring_capacity;
        if (ring_len < ring_capacity) ring_len += 1;
    }
}

/// Copy the captured log out, oldest byte first. Returns the number of bytes.
pub fn ringDump(out: []u8) []u8 {
    const n = @min(out.len, ring_len);
    const start = (ring_head + ring_capacity - ring_len) % ring_capacity;
    for (0..n) |i| out[i] = ring[(start + i) % ring_capacity];
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const LineWriter = struct {
    buf: []u8,
    len: usize = 0,
    truncated: bool = false,

    pub const Error = error{};

    pub fn writeFn(self: *LineWriter, bytes: []const u8) Error!usize {
        const space = self.buf.len - self.len;
        if (bytes.len > space) {
            @memcpy(self.buf[self.len..], bytes[0..space]);
            self.len = self.buf.len;
            self.truncated = true;
            return bytes.len;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return bytes.len;
    }
};

fn emit(comptime level: Level, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(filter)) return;

    var line: [512]u8 = undefined;
    var w = LineWriter{ .buf = &line };
    const writer = std.io.GenericWriter(*LineWriter, LineWriter.Error, LineWriter.writeFn){ .context = &w };

    const ns = uptimeNanos();
    const secs = ns / 1_000_000_000;
    const usec = (ns % 1_000_000_000) / 1000;

    std.fmt.format(writer, "[{d:>5}.{d:0>6}] {s} {s: <8} ", .{ secs, usec, level.label(), scope }) catch {};
    std.fmt.format(writer, fmt, args) catch {};
    _ = w.writeFn("\n") catch 0;

    uart.writeAll(w.buf[0..w.len]);
    ringAppend(w.buf[0..w.len]);
}

pub fn err(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.err, scope, fmt, args);
}

pub fn warn(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.warn, scope, fmt, args);
}

pub fn info(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.info, scope, fmt, args);
}

pub fn debug(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.debug, scope, fmt, args);
}

test "level ordering lets filters work by integer comparison" {
    try std.testing.expect(@intFromEnum(Level.err) < @intFromEnum(Level.debug));
}
