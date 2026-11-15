//! The block layer (phase 34).
//!
//! One interface between everything above (partitions, the filesystem, the POS
//! database) and whatever storage device is below: a backend with `read`,
//! `write` and `flush`, plus a request scheduler that batches I/O the way a
//! rotating disk or a flash translation layer likes it.
//!
//! Two ordering rules are the whole point, and both are visible in the code:
//!
//!   * **The elevator only reorders inside a run.** Requests are queued in
//!     order; each run of requests *not* separated by a flush is sorted by
//!     starting LBA, which turns scattered writes into a sequential sweep. A
//!     flush is never moved: it is a barrier, and nothing queued after it can
//!     be executed before it.
//!   * **A flush means everything before it is on the medium.** The scheduler
//!     dispatches in order, synchronously, so a flush request can only run after
//!     every earlier request has completed. Callers that need durability call
//!     `addFlush` last and check the result.
//!
//! Statistics are counted here (requests, sectors, bytes, errors) and in the
//! device driver (retries, timeouts, device resets), so a failing disk shows up
//! as numbers rather than a hang.

const std = @import("std");

pub const sector_size = 512;
/// Requests the elevator holds at once. This is the reordering window.
pub const max_batch = 64;

pub const Error = error{
    NoDevice,
    NoSpace,
    NoMemory,
    Full,
    Timeout,
    IoError,
    Unsupported,
};

pub const Op = enum(u8) { read, write, flush };

pub const Request = struct {
    op: Op,
    lba: u64 = 0,
    count: u32 = 0,
    buf: ?[*]u8 = null,
};

pub const Stats = struct {
    submitted: u64 = 0,
    dispatched: u64 = 0,
    /// Requests the elevator moved to a different position.
    reordered: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    sectors: u64 = 0,
    bytes: u64 = 0,
    errors: u64 = 0,
    failed_requests: u64 = 0,
};

pub var stats: Stats = .{};

/// The device behind the layer. Function-pointer based so the scheduler has no
/// idea whether it is talking to virtio-blk, a RAM disk or a future NVMe.
pub const Backend = struct {
    capacity_sectors: u64 = 0,
    read: *const fn (lba: u64, buf: [*]u8, count: u32) Error!void,
    write: *const fn (lba: u64, buf: [*]const u8, count: u32) Error!void,
    flush: *const fn () Error!void,
};

pub var backend: ?Backend = null;

pub fn install(b: Backend) void {
    backend = b;
}

pub fn uninstall() void {
    backend = null;
}

pub fn present() bool {
    return backend != null;
}

pub fn capacitySectors() u64 {
    return if (backend) |b| b.capacity_sectors else 0;
}

pub fn capacityBytes() u64 {
    return capacitySectors() * sector_size;
}

/// Sort each run of non-flush requests by LBA. Returns how many requests moved.
fn insertionSort(items: []Request) usize {
    var moved: usize = 0;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].lba > key.lba) : (j -= 1) {
            items[j] = items[j - 1];
            moved += 1;
        }
        if (j != i) {
            items[j] = key;
            moved += 1;
        }
    }
    return moved;
}

pub const Scheduler = struct {
    requests: [max_batch]Request = undefined,
    count: usize = 0,

    pub fn reset(self: *Scheduler) void {
        self.count = 0;
    }

    pub fn add(self: *Scheduler, request: Request) Error!void {
        if (request.op != .flush) {
            if (request.count == 0) return error.NoSpace;
            if (backend) |b| {
                if (b.capacity_sectors != 0 and request.lba + request.count > b.capacity_sectors) {
                    return error.NoSpace;
                }
            }
        }
        if (self.count == max_batch) return error.Full;
        self.requests[self.count] = request;
        self.count += 1;
        stats.submitted += 1;
        return;
    }

    pub fn addRead(self: *Scheduler, lba: u64, buf: [*]u8, count: u32) Error!void {
        return self.add(.{ .op = .read, .lba = lba, .count = count, .buf = buf });
    }

    pub fn addWrite(self: *Scheduler, lba: u64, buf: [*]const u8, count: u32) Error!void {
        return self.add(.{ .op = .write, .lba = lba, .count = count, .buf = @constCast(buf) });
    }

    pub fn addFlush(self: *Scheduler) Error!void {
        return self.add(.{ .op = .flush });
    }

    /// Plan the dispatch order. A flush is a barrier: runs are sorted, flushes
    /// keep their queue position, so no request crosses one.
    pub fn plan(self: *Scheduler) usize {
        var moved: usize = 0;
        var start: usize = 0;
        while (start < self.count) {
            var end = start;
            while (end < self.count and self.requests[end].op != .flush) : (end += 1) {}
            moved += insertionSort(self.requests[start..end]);
            start = if (end < self.count) end + 1 else end;
        }
        stats.reordered += moved;
        return moved;
    }

    /// Execute the batch in planned order. The first failure stops the batch:
    /// continuing past an I/O error would make "what reached the medium"
    /// unanswerable.
    pub fn dispatch(self: *Scheduler) Error!void {
        const b = backend orelse {
            self.count = 0;
            return error.NoDevice;
        };
        _ = self.plan();
        for (self.requests[0..self.count]) |request| {
            switch (request.op) {
                .flush => b.flush() catch |err| {
                    stats.errors += 1;
                    stats.failed_requests += 1;
                    self.count = 0;
                    return err;
                },
                .read => b.read(request.lba, request.buf.?, request.count) catch |err| {
                    stats.errors += 1;
                    stats.failed_requests += 1;
                    self.count = 0;
                    return err;
                },
                .write => b.write(request.lba, request.buf.?, request.count) catch |err| {
                    stats.errors += 1;
                    stats.failed_requests += 1;
                    self.count = 0;
                    return err;
                },
            }
            stats.dispatched += 1;
            switch (request.op) {
                .flush => stats.flushes += 1,
                .read => {
                    stats.reads += 1;
                    stats.sectors += request.count;
                    stats.bytes += @as(u64, request.count) * sector_size;
                },
                .write => {
                    stats.writes += 1;
                    stats.sectors += request.count;
                    stats.bytes += @as(u64, request.count) * sector_size;
                },
            }
        }
        self.count = 0;
        return;
    }
};

// ---------------------------------------------------------------------------
// Tests: the ordering rules, with no device in sight.
// ---------------------------------------------------------------------------

fn noRead(_: u64, _: [*]u8, _: u32) Error!void {}
fn noWrite(_: u64, _: [*]const u8, _: u32) Error!void {}
fn noFlush() Error!void {}

test "the elevator sorts a run by starting LBA" {
    var scheduler = Scheduler{};
    var buf: [sector_size]u8 = undefined;
    try scheduler.addWrite(100, &buf, 1);
    try scheduler.addWrite(10, &buf, 1);
    try scheduler.addWrite(50, &buf, 1);
    try std.testing.expectEqual(@as(usize, 3), scheduler.count);
    const moved = scheduler.plan();
    try std.testing.expect(moved > 0);
    try std.testing.expectEqual(@as(u64, 10), scheduler.requests[0].lba);
    try std.testing.expectEqual(@as(u64, 50), scheduler.requests[1].lba);
    try std.testing.expectEqual(@as(u64, 100), scheduler.requests[2].lba);
}

test "a flush is a barrier: nothing crosses it" {
    var scheduler = Scheduler{};
    var buf: [sector_size]u8 = undefined;
    try scheduler.addWrite(100, &buf, 1);
    try scheduler.addWrite(10, &buf, 1);
    try scheduler.addFlush();
    try scheduler.addWrite(300, &buf, 1);
    try scheduler.addWrite(200, &buf, 1);
    _ = scheduler.plan();
    try std.testing.expectEqual(@as(u64, 10), scheduler.requests[0].lba);
    try std.testing.expectEqual(@as(u64, 100), scheduler.requests[1].lba);
    try std.testing.expectEqual(Op.flush, scheduler.requests[2].op);
    try std.testing.expectEqual(@as(u64, 200), scheduler.requests[3].lba);
    try std.testing.expectEqual(@as(u64, 300), scheduler.requests[4].lba);
}

test "a full window is refused, not silently dropped" {
    var scheduler = Scheduler{};
    var buf: [sector_size]u8 = undefined;
    for (0..max_batch) |_| try scheduler.addWrite(1, &buf, 1);
    try std.testing.expectError(error.Full, scheduler.addWrite(2, &buf, 1));
}

test "dispatch runs every request against the backend in order" {
    const Recorder = struct {
        var order: [8]u64 = [_]u64{0} ** 8;
        var count: usize = 0;
        var flushes: usize = 0;
        fn read(lba: u64, _: [*]u8, _: u32) Error!void {
            order[count] = lba;
            count += 1;
        }
        fn write(lba: u64, _: [*]const u8, _: u32) Error!void {
            order[count] = lba;
            count += 1;
        }
        fn flush() Error!void {
            flushes += 1;
        }
    };
    Recorder.count = 0;
    Recorder.flushes = 0;
    install(.{ .capacity_sectors = 1024, .read = Recorder.read, .write = Recorder.write, .flush = Recorder.flush });
    defer uninstall();
    var scheduler = Scheduler{};
    var buf: [sector_size]u8 = undefined;
    try scheduler.addWrite(90, &buf, 1);
    try scheduler.addWrite(20, &buf, 1);
    try scheduler.addFlush();
    try scheduler.dispatch();
    try std.testing.expectEqual(@as(usize, 2), Recorder.count);
    try std.testing.expectEqual(@as(u64, 20), Recorder.order[0]);
    try std.testing.expectEqual(@as(u64, 90), Recorder.order[1]);
    try std.testing.expectEqual(@as(usize, 1), Recorder.flushes);
}

test "a backend that refuses stops the batch and is counted" {
    const Refuser = struct {
        var calls: usize = 0;
        fn read(_: u64, _: [*]u8, _: u32) Error!void {
            calls += 1;
            return error.IoError;
        }
        fn write(_: u64, _: [*]const u8, _: u32) Error!void {
            calls += 1;
            return error.IoError;
        }
        fn flush() Error!void {}
    };
    Refuser.calls = 0;
    const before = stats.errors;
    install(.{ .capacity_sectors = 1024, .read = Refuser.read, .write = Refuser.write, .flush = Refuser.flush });
    defer uninstall();
    var scheduler = Scheduler{};
    var buf: [sector_size]u8 = undefined;
    try scheduler.addRead(1, &buf, 1);
    try scheduler.addRead(2, &buf, 1);
    try std.testing.expectError(error.IoError, scheduler.dispatch());
    try std.testing.expectEqual(@as(usize, 1), Refuser.calls);
    try std.testing.expect(stats.errors > before);
    try std.testing.expectEqual(@as(usize, 0), scheduler.count);
}
