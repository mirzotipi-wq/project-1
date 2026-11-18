//! Persistent power journal (phase 40).
//!
//! The journal is the answer to "what happened before the reset?". It lives on
//! partition 1 of the attached disk as `POWER.JNL`, so the same FAT32 driver
//! that serves the shell owns the bytes and the file survives a machine reset.
//! Records are the fixed 72-byte format in `lib/power.zig`; a torn tail is
//! ignored and the valid history before it survives.
//!
//! The journal is not a filesystem journal and does not pretend to be one.
//! CASSAFS's write-ahead journal is phase 43. This is the power manager's
//! append-only event log: boot, clean shutdown, brown-out, reboot and watchdog
//! recovery. `flush()` writes the whole file and issues a device flush, which
//! is the durability guarantee the shutdown path needs.
//!
//! Boot ordering: the block device is bound, then `power.init` mounts partition
//! 1, loads the file, appends the boot record and flushes it. The shell's own
//! FAT mount comes later and refreshes its cache before each command, so the
//! two mounted views cannot serve a stale FAT sector to each other.

const std = @import("std");
const block = @import("block.zig");
const partition = @import("partition.zig");
const block_view = @import("block_view.zig");
const fat32 = @import("fat32.zig");
const rtc = @import("../devices/pl031.zig");
const timer = @import("../arch/aarch64/timer.zig");
const klog = @import("klog.zig");
const power_lib = @import("../lib/power.zig");

pub const file_name = "POWER.JNL";

pub const Snapshot = struct {
    active: bool = false,
    mounted: bool = false,
    count: usize = 0,
    flushes: u32 = 0,
    writes: u32 = 0,
    seq: u64 = 0,
    previous_clean: bool = false,
    has_previous: bool = false,
    reason: []const u8 = "not initialised",
    last_error: []const u8 = "",
};

var table: partition.Table = .{};
var volume: fat32.Volume = undefined;
var records: [power_lib.journal_max_records]power_lib.JournalRecord = undefined;
var count: usize = 0;
var seq: u64 = 0;
var snap: Snapshot = .{};
var file_buf: [fat32.max_file_bytes]u8 = undefined;
var verify_buf: [fat32.max_file_bytes]u8 = undefined;
var verify_records: [power_lib.journal_max_records]power_lib.JournalRecord = undefined;

pub fn snapshot() *const Snapshot {
    return &snap;
}

pub fn recordAt(index: usize) ?*const power_lib.JournalRecord {
    if (index >= count) return null;
    return &records[index];
}

pub fn last() ?*const power_lib.JournalRecord {
    if (count == 0) return null;
    return &records[count - 1];
}

fn appendRaw(kind: power_lib.JournalKind, detail: []const u8, temp_mc: i32, throttle: u8) void {
    seq += 1;
    const wall = rtc.unixSeconds() orelse 0;
    const record = power_lib.JournalRecord.make(kind, detail, seq, timer.uptimeMs(), wall, temp_mc, throttle);
    power_lib.appendRecord(records[0..], &count, record);
}

pub fn init() void {
    snap = .{};
    count = 0;
    seq = 0;
    if (!block.present()) {
        snap.reason = "no block device; power events are memory-only";
        return;
    }
    partition.read(.{}, &table) catch |err| {
        snap.reason = switch (err) {
            error.NoTable => "no partition table; power events are memory-only",
            else => "partition table unreadable; power events are memory-only",
        };
        return;
    };
    if (table.count == 0) {
        snap.reason = "disk has no partition; power events are memory-only";
        return;
    }
    const view = block_view.View.fromPartition(&table.entries[0]) catch {
        snap.reason = "partition 1 lies outside the disk";
        return;
    };
    volume = fat32.mount(view) catch |err| {
        snap.reason = switch (err) {
            error.BadBoot, error.BadGeometry, error.Unsupported => "partition 1 is not a mountable FAT32",
            else => "partition 1 is unreadable",
        };
        return;
    };
    snap.mounted = true;
    volume.refresh() catch {
        snap.reason = "partition 1 could not be refreshed";
        return;
    };
    if (volume.readFile(file_name, &file_buf)) |n| {
        const decoded = power_lib.decodeJournal(file_buf[0..n], records[0..]);
        count = decoded;
        if (count > 0) {
            seq = records[count - 1].seq;
            snap.has_previous = true;
            snap.previous_clean = power_lib.journalClean(records[count - 1].kind);
        }
        if (decoded == 0 and n != 0) {
            snap.last_error = "journal header was invalid; starting a new history";
            klog.warn("journal", "POWER.JNL had {d} byte(s) but no valid record; starting over", .{n});
        }
    } else |err| {
        if (err != error.NotFound) {
            snap.reason = "POWER.JNL could not be read";
            snap.last_error = @errorName(err);
            return;
        }
    }
    snap.active = true;
    snap.reason = "FAT32 partition 1";
    snap.count = count;
    snap.seq = seq;
}

pub fn boot(watchdog_reset: bool, temp_mc: i32, throttle: u8) void {
    if (!snap.active) return;
    appendRaw(if (watchdog_reset) .watchdog_boot else .boot, if (watchdog_reset) "boot after watchdog reset" else "boot", temp_mc, throttle);
    _ = flush();
}

pub fn append(kind: power_lib.JournalKind, detail: []const u8, temp_mc: i32, throttle: u8) void {
    if (!snap.active) return;
    appendRaw(kind, detail, temp_mc, throttle);
}

/// Rewrite the journal file and make it durable. Called after the boot record,
/// by `power flush`, and by every shutdown path. Returns whether the write and
/// the device flush both completed.
pub fn flush() bool {
    if (!snap.active) return false;
    const n = power_lib.encodeJournal(records[0..count], file_buf[0..]) orelse {
        snap.last_error = "journal is larger than the file buffer";
        return false;
    };
    volume.refresh() catch |err| {
        snap.last_error = @errorName(err);
        return false;
    };
    _ = volume.writeFile(file_name, file_buf[0..n]) catch |err| {
        snap.last_error = @errorName(err);
        klog.err("journal", "POWER.JNL write failed: {s}", .{@errorName(err)});
        return false;
    };
    volume.sync() catch |err| {
        snap.last_error = @errorName(err);
        klog.err("journal", "POWER.JNL flush failed: {s}", .{@errorName(err)});
        return false;
    };
    snap.flushes += 1;
    snap.writes += 1;
    snap.count = count;
    snap.seq = seq;
    snap.last_error = "";
    return true;
}

/// Append a record and prove it can be read back from the file. Used by
/// `power selftest`; it does not power anything off.
pub fn selfTest() bool {
    if (!snap.active) return true; // absence is a supported configuration
    appendRaw(.selftest, "power journal selftest", 42_000, 0);
    if (!flush()) return false;
    const n = volume.readFile(file_name, &verify_buf) catch return false;
    const decoded = power_lib.decodeJournal(verify_buf[0..n], verify_records[0..]);
    if (decoded < 2) return false;
    const tail = &verify_records[decoded - 1];
    return tail.kind == .selftest and std.mem.eql(u8, tail.detailSlice(), "power journal selftest");
}

pub fn previousClean() bool {
    return snap.previous_clean;
}

pub fn hasPrevious() bool {
    return snap.has_previous;
}
