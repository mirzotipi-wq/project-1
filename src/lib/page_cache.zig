//! A bounded 4 KiB page cache for the CASSAFS block device (phase 44).
//!
//! This is deliberately a cache *below* the VFS and *above* the format: the
//! sectors, records, CRC32C checks, scanner and write path do not know it is
//! there. CASSAFS sees a `cassafs.Device` that happens to keep a small LRU set
//! of decoded blocks in memory.
//!
//! Policies:
//!   * clean pages are evicted in least-recently-used order;
//!   * dirty pages are written back when evicted, when the dirty bound is
//!     exceeded, or on `flush`;
//!   * a read miss fetches the requested page and a bounded run of following
//!     pages (readahead);
//!   * a failed writeback leaves the page dirty and returns the backing error.
//!     It never drops data or reports a successful commit.
//!
//! No heap allocation: the caller owns the page array so the kernel can place
//! it in `.bss` and host tests can use a small stack array.

const std = @import("std");
const cassafs = @import("cassafs.zig");

pub const Page = struct {
    block: u32 = 0,
    state: State = .empty,
    stamp: u64 = 0,
    data: [cassafs.block_size]u8 = undefined,
};

pub const State = enum { empty, clean, dirty };

pub const Options = struct {
    /// Maximum dirty pages retained before oldest dirty pages are written back.
    max_dirty: usize = 16,
    /// Consecutive pages fetched on a read miss, excluding the requested page.
    readahead: usize = 4,
};

pub const Stats = struct {
    capacity: usize = 0,
    used: usize = 0,
    dirty: usize = 0,
    max_dirty: usize = 0,
    readahead: usize = 0,
    read_calls: u64 = 0,
    write_calls: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    writebacks: u64 = 0,
    flushes: u64 = 0,
    readahead_reads: u64 = 0,
    readahead_hits: u64 = 0,
    readahead_errors: u64 = 0,
    errors: u64 = 0,

    pub fn hitRate(self: Stats) u64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return (self.hits * 100) / total;
    }

    pub fn pressure(self: Stats) u64 {
        if (self.capacity == 0) return 0;
        return (@as(u64, self.used) * 100) / self.capacity;
    }
};

pub const PageCache = struct {
    backing: cassafs.Device,
    pages: []Page,
    max_dirty: usize,
    readahead: usize,
    clock: u64 = 0,
    stats: Stats = .{},
    /// One cache-owned bounce block. Keeping this off the call stack matters:
    /// a CASSAFS mount scan already uses a full block of stack, and two nested
    /// 4 KiB locals here overflowed the 64 KiB shell stack once.
    scratch: [cassafs.block_size]u8 = undefined,

    pub fn init(backing: cassafs.Device, pages: []Page, options: Options) cassafs.Error!PageCache {
        if (backing.blocks == 0 or pages.len == 0) return error.NoSpace;
        var max_dirty = options.max_dirty;
        if (max_dirty == 0) max_dirty = 1;
        if (max_dirty > pages.len) max_dirty = pages.len;
        const cache = PageCache{
            .backing = backing,
            .pages = pages,
            .max_dirty = max_dirty,
            .readahead = @min(options.readahead, pages.len - 1),
            .stats = .{
                .capacity = pages.len,
                .max_dirty = max_dirty,
                .readahead = @min(options.readahead, pages.len - 1),
            },
        };
        for (pages) |*page| page.* = .{};
        return cache;
    }

    /// The cache presents exactly the backing device's block range. The
    /// returned device is valid while this PageCache is alive.
    pub fn device(self: *PageCache) cassafs.Device {
        return .{
            .ctx = self,
            .blocks = self.backing.blocks,
            .read_fn = deviceRead,
            .write_fn = deviceWrite,
            .flush_fn = deviceFlush,
        };
    }

    pub fn reset(self: *PageCache, backing: cassafs.Device) cassafs.Error!void {
        if (backing.blocks == 0) return error.NoSpace;
        self.backing = backing;
        for (self.pages) |*page| page.* = .{};
        self.clock = 0;
        self.stats = .{
            .capacity = self.pages.len,
            .max_dirty = self.max_dirty,
            .readahead = self.readahead,
        };
    }

    pub fn statsSnapshot(self: *const PageCache) Stats {
        return self.stats;
    }

    fn nextStamp(self: *PageCache) u64 {
        self.clock +%= 1;
        return self.clock;
    }

    fn find(self: *const PageCache, block: u32) ?usize {
        var i: usize = 0;
        while (i < self.pages.len) : (i += 1) {
            const page = &self.pages[i];
            if (page.state != .empty and page.block == block) return i;
        }
        return null;
    }

    fn touch(self: *PageCache, index: usize) void {
        self.pages[index].stamp = self.nextStamp();
    }

    fn freeSlot(self: *const PageCache) ?usize {
        var i: usize = 0;
        while (i < self.pages.len) : (i += 1) {
            if (self.pages[i].state == .empty) return i;
        }
        return null;
    }

    fn oldest(self: *const PageCache, dirty_only: bool) ?usize {
        var victim: ?usize = null;
        var stamp: u64 = std.math.maxInt(u64);
        var i: usize = 0;
        while (i < self.pages.len) : (i += 1) {
            const page = &self.pages[i];
            if (page.state == .empty) continue;
            if (dirty_only and page.state != .dirty) continue;
            if (page.stamp <= stamp) {
                stamp = page.stamp;
                victim = i;
            }
        }
        return victim;
    }

    fn writeBack(self: *PageCache, index: usize) cassafs.Error!void {
        const page = &self.pages[index];
        if (page.state != .dirty) return;
        self.backing.write(page.block, &page.data) catch |err| {
            self.stats.errors += 1;
            return err;
        };
        page.state = .clean;
        page.stamp = self.nextStamp();
        if (self.stats.dirty > 0) self.stats.dirty -= 1;
        self.stats.writebacks += 1;
    }

    fn evictOne(self: *PageCache) cassafs.Error!usize {
        const index = self.oldest(false) orelse return error.NoSpace;
        const page = &self.pages[index];
        if (page.state == .dirty) {
            try self.writeBack(index);
        }
        page.state = .empty;
        if (self.stats.used > 0) self.stats.used -= 1;
        self.stats.evictions += 1;
        return index;
    }

    fn install(self: *PageCache, block: u32, data: *const [cassafs.block_size]u8, dirty: bool) cassafs.Error!usize {
        const index = self.freeSlot() orelse try self.evictOne();
        const page = &self.pages[index];
        page.block = block;
        page.state = if (dirty) .dirty else .clean;
        @memcpy(&page.data, data);
        self.touch(index);
        self.stats.used += 1;
        if (dirty) self.stats.dirty += 1;
        return index;
    }

    fn trimDirty(self: *PageCache) cassafs.Error!void {
        while (self.stats.dirty > self.max_dirty) {
            const victim = self.oldest(true) orelse return error.Io;
            try self.writeBack(victim);
        }
    }

    /// Fetch the requested page plus an advisory readahead run. Readahead
    /// failures are counted but never turn a successful primary read into an
    /// error: the requested page is already resident and valid.
    fn prefetch(self: *PageCache, base: u32) void {
        if (self.readahead == 0) return;
        var n: usize = 1;
        while (n <= self.readahead) : (n += 1) {
            const block = @as(u64, base) + n;
            if (block >= self.backing.blocks) break;
            const target: u32 = @intCast(block);
            if (self.find(target)) |_| {
                self.stats.readahead_hits += 1;
                continue;
            }
            self.backing.read(target, &self.scratch) catch {
                self.stats.readahead_errors += 1;
                break;
            };
            _ = self.install(target, &self.scratch, false) catch {
                self.stats.readahead_errors += 1;
                break;
            };
            self.stats.readahead_reads += 1;
        }
    }

    pub fn read(self: *PageCache, block: u32, out: *[cassafs.block_size]u8) cassafs.Error!void {
        if (block >= self.backing.blocks) return error.OutOfRange;
        self.stats.read_calls += 1;
        if (self.find(block)) |index| {
            self.stats.hits += 1;
            self.touch(index);
            @memcpy(out, &self.pages[index].data);
            return;
        }
        self.stats.misses += 1;
        self.backing.read(block, &self.scratch) catch |err| {
            self.stats.errors += 1;
            return err;
        };
        const index = try self.install(block, &self.scratch, false);
        @memcpy(out, &self.pages[index].data);
        self.prefetch(block);
    }

    pub fn write(self: *PageCache, block: u32, data: *const [cassafs.block_size]u8) cassafs.Error!void {
        if (block >= self.backing.blocks) return error.OutOfRange;
        self.stats.write_calls += 1;
        if (self.find(block)) |index| {
            const page = &self.pages[index];
            @memcpy(&page.data, data);
            if (page.state == .clean) {
                page.state = .dirty;
                self.stats.dirty += 1;
            }
            self.touch(index);
        } else {
            _ = try self.install(block, data, true);
        }
        try self.trimDirty();
    }

    /// Write every dirty page in LRU order, then make the backing device flush
    /// its queue. A failed writeback leaves that page dirty and stops the flush;
    /// no dirty page is ever discarded by this function.
    pub fn flush(self: *PageCache) cassafs.Error!void {
        while (true) {
            const victim = self.oldest(true) orelse break;
            try self.writeBack(victim);
        }
        self.backing.flush() catch |err| {
            self.stats.errors += 1;
            return err;
        };
        self.stats.flushes += 1;
    }

    /// Drop all resident pages. The kernel calls this only after a successful
    /// flush (unmount); tests use it to measure cold-cache behavior.
    pub fn invalidate(self: *PageCache) void {
        for (self.pages) |*page| page.* = .{};
        self.stats.used = 0;
        self.stats.dirty = 0;
    }

    /// Flush and then drop every page. Returns the flush error, if any.
    pub fn drop(self: *PageCache) cassafs.Error!void {
        try self.flush();
        self.invalidate();
    }

    fn deviceRead(ctx: *anyopaque, block: u32, out: *[cassafs.block_size]u8) cassafs.Error!void {
        const self: *PageCache = @ptrCast(@alignCast(ctx));
        return self.read(block, out);
    }

    fn deviceWrite(ctx: *anyopaque, block: u32, data: *const [cassafs.block_size]u8) cassafs.Error!void {
        const self: *PageCache = @ptrCast(@alignCast(ctx));
        return self.write(block, data);
    }

    fn deviceFlush(ctx: *anyopaque) cassafs.Error!void {
        const self: *PageCache = @ptrCast(@alignCast(ctx));
        return self.flush();
    }
};

// ---------------------------------------------------------------------------
// Host tests: real page contents, a recording backing device, and no kernel.
// ---------------------------------------------------------------------------

const FakeDisk = struct {
    storage: []u8,
    blocks: u32,
    reads: u32 = 0,
    writes: u32 = 0,
    flushes: u32 = 0,
    fail_write: bool = false,
    fail_flush: bool = false,

    fn read(ctx: *anyopaque, block: u32, out: *[cassafs.block_size]u8) cassafs.Error!void {
        const self: *FakeDisk = @ptrCast(@alignCast(ctx));
        if (block >= self.blocks) return error.OutOfRange;
        self.reads += 1;
        @memcpy(out, self.storage[@as(usize, block) * cassafs.block_size ..][0..cassafs.block_size]);
    }

    fn write(ctx: *anyopaque, block: u32, data: *const [cassafs.block_size]u8) cassafs.Error!void {
        const self: *FakeDisk = @ptrCast(@alignCast(ctx));
        if (self.fail_write) return error.Io;
        if (block >= self.blocks) return error.OutOfRange;
        self.writes += 1;
        @memcpy(self.storage[@as(usize, block) * cassafs.block_size ..][0..cassafs.block_size], data);
    }

    fn flush(ctx: *anyopaque) cassafs.Error!void {
        const self: *FakeDisk = @ptrCast(@alignCast(ctx));
        if (self.fail_flush) return error.Io;
        self.flushes += 1;
    }

    fn device(self: *FakeDisk) cassafs.Device {
        return .{
            .ctx = self,
            .blocks = self.blocks,
            .read_fn = FakeDisk.read,
            .write_fn = FakeDisk.write,
            .flush_fn = FakeDisk.flush,
        };
    }
};

fn patternedBlock(block: u32) [cassafs.block_size]u8 {
    var data: [cassafs.block_size]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) : (i += 1) data[i] = @truncate(block * 31 + @as(u32, @intCast(i)));
    return data;
}

fn fillDisk(disk: *FakeDisk) void {
    var i: u32 = 0;
    while (i < disk.blocks) : (i += 1) {
        const block = patternedBlock(i);
        @memcpy(disk.storage[@as(usize, i) * cassafs.block_size ..][0..cassafs.block_size], &block);
    }
}

test "a read miss is remembered and a second read hits" {
    var storage: [8 * cassafs.block_size]u8 = undefined;
    var disk = FakeDisk{ .storage = storage[0..], .blocks = 8 };
    fillDisk(&disk);
    var pages: [4]Page = undefined;
    var cache = try PageCache.init(disk.device(), &pages, .{ .max_dirty = 2, .readahead = 0 });
    var out: [cassafs.block_size]u8 = undefined;
    try cache.read(3, &out);
    const want = patternedBlock(3);
    try std.testing.expectEqualSlices(u8, &want, &out);
    try cache.read(3, &out);
    const stats = cache.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 2), stats.read_calls);
    try std.testing.expectEqual(@as(usize, 1), stats.used);
    try std.testing.expectEqual(@as(u64, 50), stats.hitRate());
}

test "LRU evicts the least recently used clean page" {
    var storage: [8 * cassafs.block_size]u8 = undefined;
    var disk = FakeDisk{ .storage = storage[0..], .blocks = 8 };
    fillDisk(&disk);
    var pages: [3]Page = undefined;
    var cache = try PageCache.init(disk.device(), &pages, .{ .max_dirty = 2, .readahead = 0 });
    var out: [cassafs.block_size]u8 = undefined;
    try cache.read(0, &out);
    try cache.read(1, &out);
    try cache.read(2, &out);
    const before = cache.statsSnapshot();
    try std.testing.expectEqual(@as(usize, 3), before.used);
    try cache.read(3, &out);
    const after = cache.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), after.evictions);
    try std.testing.expectEqual(@as(usize, 3), after.used);
    // Block 0 was the oldest; reading it must miss and evict block 1 now.
    try cache.read(0, &out);
    try std.testing.expectEqual(@as(u64, 2), cache.statsSnapshot().evictions);
}

test "write-back respects the dirty bound and flushes the newest bytes" {
    var storage: [8 * cassafs.block_size]u8 = undefined;
    var disk = FakeDisk{ .storage = storage[0..], .blocks = 8 };
    fillDisk(&disk);
    var pages: [4]Page = undefined;
    var cache = try PageCache.init(disk.device(), &pages, .{ .max_dirty = 2, .readahead = 0 });
    const a = patternedBlock(10);
    const b = patternedBlock(11);
    const c = patternedBlock(12);
    try cache.write(0, &a);
    try cache.write(1, &b);
    try std.testing.expectEqual(@as(usize, 2), cache.statsSnapshot().dirty);
    try cache.write(2, &c);
    try std.testing.expectEqual(@as(usize, 2), cache.statsSnapshot().dirty);
    try std.testing.expect(cache.statsSnapshot().writebacks >= 1);
    try cache.flush();
    try std.testing.expectEqualSlices(u8, &a, disk.storage[0..cassafs.block_size]);
    try std.testing.expectEqualSlices(u8, &c, disk.storage[2 * cassafs.block_size ..][0..cassafs.block_size]);
    try std.testing.expectEqual(@as(usize, 0), cache.statsSnapshot().dirty);
}

test "readahead fills consecutive pages and a later read hits" {
    var storage: [8 * cassafs.block_size]u8 = undefined;
    var disk = FakeDisk{ .storage = storage[0..], .blocks = 8 };
    fillDisk(&disk);
    var pages: [6]Page = undefined;
    var cache = try PageCache.init(disk.device(), &pages, .{ .max_dirty = 2, .readahead = 3 });
    var out: [cassafs.block_size]u8 = undefined;
    try cache.read(2, &out);
    const first = cache.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 3), first.readahead_reads);
    try std.testing.expectEqual(@as(usize, 4), first.used);
    try cache.read(3, &out);
    const second = cache.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), second.hits);
    try std.testing.expectEqual(@as(u64, 1), second.misses);
}

test "a failed writeback keeps the dirty page and reports the error" {
    var storage: [8 * cassafs.block_size]u8 = undefined;
    var disk = FakeDisk{ .storage = storage[0..], .blocks = 8 };
    fillDisk(&disk);
    var pages: [4]Page = undefined;
    var cache = try PageCache.init(disk.device(), &pages, .{ .max_dirty = 2, .readahead = 0 });
    const data = patternedBlock(20);
    try cache.write(4, &data);
    disk.fail_write = true;
    try std.testing.expectError(error.Io, cache.flush());
    try std.testing.expectEqual(@as(usize, 1), cache.statsSnapshot().dirty);
    disk.fail_write = false;
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 0), cache.statsSnapshot().dirty);
}

test "invalid block numbers are refused before the backing device" {
    var storage: [8 * cassafs.block_size]u8 = undefined;
    var disk = FakeDisk{ .storage = storage[0..], .blocks = 8 };
    fillDisk(&disk);
    var pages: [2]Page = undefined;
    var cache = try PageCache.init(disk.device(), &pages, .{ .max_dirty = 1, .readahead = 0 });
    var out: [cassafs.block_size]u8 = undefined;
    try std.testing.expectError(error.OutOfRange, cache.read(8, &out));
    try std.testing.expectError(error.OutOfRange, cache.write(8, &out));
}
