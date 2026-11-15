//! Partition-offset block view (phase 36).
//!
//! A filesystem must be able to treat its partition as a disk that starts at
//! LBA 0. This wraps the physical backend so every read and write is translated
//! by the partition's first LBA, and every request is checked against the
//! partition's length — not the disk's. That check is the phase-34 discipline
//! (`block.fits`, bytes converted to sectors exactly once) applied one layer up:
//! a filesystem bug must be a typed error, never a write into the neighbouring
//! partition.
//!
//! The view owns a copy of the backend's function pointers, so it stays valid
//! even if the block layer's installed backend is replaced.

const std = @import("std");
const block = @import("block.zig");
const partition = @import("partition.zig");

pub const Error = block.Error;

pub const View = struct {
    backend: block.Backend,
    /// First LBA of the partition on the physical disk.
    base_lba: u64,
    /// Length of the partition in sectors.
    sectors: u64,
    /// Where this view came from, for the shell and the record.
    index: u8 = 0,
    scheme: partition.Scheme = .none,

    pub fn capacitySectors(self: *const View) u64 {
        return self.sectors;
    }

    pub fn capacityBytes(self: *const View) u64 {
        return self.sectors * block.sector_size;
    }

    /// Wrap the whole installed disk, for a filesystem that has no partition
    /// table of its own (a superfloppy).
    pub fn wholeDisk() Error!View {
        const b = block.backend orelse return error.NoDevice;
        return .{ .backend = b, .base_lba = 0, .sectors = b.capacity_sectors };
    }

    /// Wrap one parsed partition. The partition must lie inside the disk; a
    /// table that claims otherwise is refused here rather than clamped.
    pub fn fromPartition(entry: *const partition.Entry) Error!View {
        const b = block.backend orelse return error.NoDevice;
        if (entry.last_lba < entry.first_lba) return error.NoSpace;
        const start = entry.first_lba;
        const len = entry.last_lba - entry.first_lba + 1;
        if (start >= b.capacity_sectors or len > b.capacity_sectors - start) return error.NoSpace;
        return .{
            .backend = b,
            .base_lba = start,
            .sectors = len,
            .index = entry.index,
            .scheme = entry.scheme,
        };
    }

    fn check(self: *const View, lba: u64, buf_len: usize) Error!u32 {
        if (buf_len == 0 or buf_len % block.sector_size != 0) return error.NoSpace;
        if (buf_len / block.sector_size > 0xffff_ffff) return error.NoSpace;
        const count: u32 = @intCast(buf_len / block.sector_size);
        if (!block.fits(self.sectors, lba, @intCast(buf_len))) return error.NoSpace;
        if (self.base_lba + lba < self.base_lba) return error.NoSpace;
        return count;
    }

    pub fn read(self: *const View, lba: u64, buf: []u8) Error!void {
        const count = try self.check(lba, buf.len);
        return self.backend.read(self.base_lba + lba, buf.ptr, count);
    }

    pub fn write(self: *const View, lba: u64, buf: []const u8) Error!void {
        const count = try self.check(lba, buf.len);
        return self.backend.write(self.base_lba + lba, buf.ptr, count);
    }

    pub fn flush(self: *const View) Error!void {
        return self.backend.flush();
    }
};

// ---------------------------------------------------------------------------
// Tests: translation, the last sector, and every refusal path, with a
// recording backend that never touches a device.
// ---------------------------------------------------------------------------

const Recorder = struct {
    var last_lba: u64 = 0;
    var last_count: u32 = 0;
    var calls: usize = 0;
    var fail_next: bool = false;

    fn read(lba: u64, _: [*]u8, count: u32) Error!void {
        calls += 1;
        last_lba = lba;
        last_count = count;
        if (fail_next) {
            fail_next = false;
            return error.IoError;
        }
    }
    fn write(lba: u64, _: [*]const u8, count: u32) Error!void {
        calls += 1;
        last_lba = lba;
        last_count = count;
        if (fail_next) {
            fail_next = false;
            return error.IoError;
        }
    }
    fn flush() Error!void {}
};

fn recorderBackend(capacity: u64) block.Backend {
    return .{ .capacity_sectors = capacity, .read = Recorder.read, .write = Recorder.write, .flush = Recorder.flush };
}

test "a view translates the LBA and keeps the count" {
    Recorder.calls = 0;
    block.install(recorderBackend(1000));
    defer block.uninstall();
    const view = View{ .backend = block.backend.?, .base_lba = 300, .sectors = 100 };
    var buf: [2 * block.sector_size]u8 = undefined;
    try view.read(0, &buf);
    try std.testing.expectEqual(@as(u64, 300), Recorder.last_lba);
    try std.testing.expectEqual(@as(u32, 2), Recorder.last_count);
    try view.write(98, &buf);
    try std.testing.expectEqual(@as(u64, 398), Recorder.last_lba);
}

test "the last sector of a partition is addressable, one past it is not" {
    Recorder.calls = 0;
    block.install(recorderBackend(1000));
    defer block.uninstall();
    const view = View{ .backend = block.backend.?, .base_lba = 10, .sectors = 20 };
    var one: [block.sector_size]u8 = undefined;
    try view.read(19, &one);
    try std.testing.expectError(error.NoSpace, view.read(20, &one));
    try std.testing.expectError(error.NoSpace, view.write(20, &one));
    var two: [2 * block.sector_size]u8 = undefined;
    try std.testing.expectError(error.NoSpace, view.read(19, &two));
}

test "a misaligned or empty request is refused before the backend sees it" {
    Recorder.calls = 0;
    block.install(recorderBackend(1000));
    defer block.uninstall();
    const view = View{ .backend = block.backend.?, .base_lba = 0, .sectors = 100 };
    var buf: [3]u8 = .{ 1, 2, 3 };
    try std.testing.expectError(error.NoSpace, view.read(0, &buf));
    try std.testing.expectError(error.NoSpace, view.write(0, &buf));
    try std.testing.expectEqual(@as(usize, 0), Recorder.calls);
}

test "a partition outside the disk is refused, not clamped" {
    block.install(recorderBackend(1000));
    defer block.uninstall();
    var e = partition.Entry{ .first_lba = 900, .last_lba = 1200 };
    try std.testing.expectError(error.NoSpace, View.fromPartition(&e));
    e = partition.Entry{ .first_lba = 100, .last_lba = 99 };
    try std.testing.expectError(error.NoSpace, View.fromPartition(&e));
    e = partition.Entry{ .first_lba = 100, .last_lba = 199, .index = 1, .scheme = .gpt };
    const view = try View.fromPartition(&e);
    try std.testing.expectEqual(@as(u64, 100), view.base_lba);
    try std.testing.expectEqual(@as(u64, 100), view.sectors);
    try std.testing.expectEqual(@as(u8, 1), view.index);
    try std.testing.expectEqual(partition.Scheme.gpt, view.scheme);
}

test "a backend error is returned unchanged" {
    Recorder.calls = 0;
    block.install(recorderBackend(100));
    defer block.uninstall();
    const view = View{ .backend = block.backend.?, .base_lba = 0, .sectors = 100 };
    var buf: [block.sector_size]u8 = undefined;
    Recorder.fail_next = true;
    try std.testing.expectError(error.IoError, view.read(0, &buf));
}
