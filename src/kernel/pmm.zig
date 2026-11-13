//! Physical page allocator — phase 7.
//!
//! A bitmap over discovered RAM with a rover for first-fit allocation. Pure
//! integer logic, so the whole thing is unit-tested on the host.

const std = @import("std");
const builtin = @import("builtin");

pub const page_size: usize = 4096;

// ---------------------------------------------------------------------------
// Mutual exclusion
//
// The bitmap is shared by every core and is mutated from two very different
// places: threads asking for memory, and the scheduler's reaper running in
// interrupt context. Without a lock two cores can read the same free bit and
// both mark it used, handing out the same physical frame twice — the symptom is
// a thread stack that another thread is already using, which surfaces later as
// a corrupted trap frame.
//
// The lock therefore also masks interrupts. A plain spinlock would deadlock
// against itself: a core could take a tick while holding it, and the reaper it
// runs would wait for the same lock forever. On the host (where the allocator is
// unit-tested) interrupt masking compiles out and only the atomic remains.
// ---------------------------------------------------------------------------

var lock: u32 = 0;

inline fn interruptsSave() u64 {
    if (comptime builtin.cpu.arch == .aarch64) {
        var flags: u64 = undefined;
        asm volatile ("mrs %[f], daif" : [f] "=r" (flags) :: "memory");
        asm volatile ("msr daifset, #2" ::: "memory");
        return flags;
    }
    return 0;
}

inline fn interruptsRestore(flags: u64) void {
    if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("msr daif, %[f]" :: [f] "r" (flags) : "memory");
    }
}

fn acquire() u64 {
    const flags = interruptsSave();
    while (@atomicRmw(u32, &lock, .Xchg, 1, .acquire) != 0) {
        while (@atomicLoad(u32, &lock, .monotonic) != 0) std.atomic.spinLoopHint();
    }
    return flags;
}

fn release(flags: u64) void {
    @atomicStore(u32, &lock, 0, .release);
    interruptsRestore(flags);
}

pub const Stats = struct {
    total_pages: usize,
    free_pages: usize,
    used_pages: usize,
    total_bytes: usize,
    free_bytes: usize,
};

pub const PageAllocator = struct {
    bitmap: []u64,
    base: usize,
    pages: usize,
    free_pages: usize,
    rover: usize,

    pub fn init(bitmap: []u64, base: usize, size: usize) PageAllocator {
        std.debug.assert(base % page_size == 0);
        const pages = size / page_size;
        const needed_words = (pages + 63) / 64;
        std.debug.assert(bitmap.len >= needed_words);

        const words = bitmap[0..needed_words];
        @memset(words, ~@as(u64, 0)); // start fully reserved

        var self = PageAllocator{
            .bitmap = words,
            .base = base,
            .pages = pages,
            .free_pages = 0,
            .rover = 0,
        };
        self.markFree(0, pages);
        return self;
    }

    fn isFree(self: *const PageAllocator, index: usize) bool {
        return (self.bitmap[index / 64] & (@as(u64, 1) << @intCast(index % 64))) == 0;
    }

    fn setUsed(self: *PageAllocator, index: usize, used: bool) void {
        const mask = @as(u64, 1) << @intCast(index % 64);
        const word = &self.bitmap[index / 64];
        const was_used = (word.* & mask) != 0;
        if (used and !was_used) {
            word.* |= mask;
            if (self.free_pages > 0) self.free_pages -= 1;
        } else if (!used and was_used) {
            word.* &= ~mask;
            self.free_pages += 1;
        }
    }

    fn markFree(self: *PageAllocator, start: usize, count: usize) void {
        var i = start;
        const end = @min(start + count, self.pages);
        while (i < end) : (i += 1) self.setUsed(i, false);
    }

    fn markUsed(self: *PageAllocator, start: usize, count: usize) void {
        var i = start;
        const end = @min(start + count, self.pages);
        while (i < end) : (i += 1) self.setUsed(i, true);
    }

    /// Reserve a physical range (kernel image, device tree, heap arena...).
    pub fn reserveRange(self: *PageAllocator, addr: usize, len: usize) void {
        if (len == 0) return;
        const flags = acquire();
        defer release(flags);
        self.reserveRangeUnlocked(addr, len);
    }

    fn reserveRangeUnlocked(self: *PageAllocator, addr: usize, len: usize) void {
        if (len == 0) return;
        if (addr < self.base) return;
        const off = addr - self.base;
        const first = off / page_size;
        const last = (off + len + page_size - 1) / page_size;
        self.markUsed(first, last - first);
    }

    /// Allocate one page; returns its physical address.
    pub fn alloc(self: *PageAllocator) ?usize {
        const flags = acquire();
        defer release(flags);
        return self.allocUnlocked();
    }

    fn allocUnlocked(self: *PageAllocator) ?usize {
        if (self.free_pages == 0) return null;
        var scanned: usize = 0;
        var i = self.rover;
        while (scanned < self.pages) : (scanned += 1) {
            if (i >= self.pages) i = 0;
            if (self.isFree(i)) {
                self.setUsed(i, true);
                self.rover = i + 1;
                return self.base + i * page_size;
            }
            i += 1;
        }
        return null;
    }

    /// Allocate `count` physically contiguous pages.
    pub fn allocContiguous(self: *PageAllocator, count: usize) ?usize {
        const flags = acquire();
        defer release(flags);
        return self.allocContiguousUnlocked(count);
    }

    fn allocContiguousUnlocked(self: *PageAllocator, count: usize) ?usize {
        if (count == 0 or count > self.free_pages) return null;
        var run_start: usize = 0;
        var run_len: usize = 0;
        var i: usize = 0;
        while (i < self.pages) : (i += 1) {
            if (self.isFree(i)) {
                if (run_len == 0) run_start = i;
                run_len += 1;
                if (run_len == count) {
                    self.markUsed(run_start, count);
                    return self.base + run_start * page_size;
                }
            } else {
                run_len = 0;
            }
        }
        return null;
    }

    pub fn free(self: *PageAllocator, addr: usize) void {
        const flags = acquire();
        defer release(flags);
        self.freeUnlocked(addr);
    }

    fn freeUnlocked(self: *PageAllocator, addr: usize) void {
        if (addr < self.base) return;
        const index = (addr - self.base) / page_size;
        if (index >= self.pages) return;
        self.setUsed(index, false);
        if (index < self.rover) self.rover = index;
    }

    pub fn freeRange(self: *PageAllocator, addr: usize, count: usize) void {
        const flags = acquire();
        defer release(flags);
        self.freeRangeUnlocked(addr, count);
    }

    fn freeRangeUnlocked(self: *PageAllocator, addr: usize, count: usize) void {
        if (addr < self.base) return;
        const index = (addr - self.base) / page_size;
        self.markFree(index, count);
        if (index < self.rover) self.rover = index;
    }

    pub fn allocated(self: *const PageAllocator, addr: usize) bool {
        const flags = acquire();
        defer release(flags);
        if (addr < self.base) return false;
        const index = (addr - self.base) / page_size;
        if (index >= self.pages) return false;
        return !self.isFree(index);
    }

    pub fn stats(self: *const PageAllocator) Stats {
        const flags = acquire();
        defer release(flags);
        return .{
            .total_pages = self.pages,
            .free_pages = self.free_pages,
            .used_pages = self.pages - self.free_pages,
            .total_bytes = self.pages * page_size,
            .free_bytes = self.free_pages * page_size,
        };
    }

    /// Largest contiguous free run, in pages. Used by the OOM path later.
    pub fn largestFreeRun(self: *const PageAllocator) usize {
        const flags = acquire();
        defer release(flags);
        var best: usize = 0;
        var run: usize = 0;
        var i: usize = 0;
        while (i < self.pages) : (i += 1) {
            if (self.isFree(i)) {
                run += 1;
                if (run > best) best = run;
            } else run = 0;
        }
        return best;
    }

    /// Zero a freshly allocated page (the allocator never hands out stale data
    /// to user space without a scrub).
    pub fn allocZeroed(self: *PageAllocator) ?usize {
        const flags = acquire();
        defer release(flags);
        const page = self.allocUnlocked() orelse return null;
        const bytes: [*]u8 = @ptrFromInt(page);
        @memset(bytes[0..page_size], 0);
        return page;
    }
};

test "fresh allocator reports every page free" {
    var bitmap = [_]u64{0} ** 64;
    var pmm = PageAllocator.init(&bitmap, 0x4000_0000, 4096 * page_size);
    const s = pmm.stats();
    try std.testing.expectEqual(@as(usize, 4096), s.total_pages);
    try std.testing.expectEqual(@as(usize, 4096), s.free_pages);
}

test "alloc returns distinct aligned pages and free restores them" {
    var bitmap = [_]u64{0} ** 64;
    var pmm = PageAllocator.init(&bitmap, 0x4000_0000, 4096 * page_size);
    const a = pmm.alloc().?;
    const b = pmm.alloc().?;
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 0), a % page_size);
    try std.testing.expect(pmm.allocated(a));
    try std.testing.expectEqual(@as(usize, 4094), pmm.stats().free_pages);
    pmm.free(a);
    pmm.free(b);
    try std.testing.expectEqual(@as(usize, 4096), pmm.stats().free_pages);
}

test "reserveRange removes pages from circulation" {
    var bitmap = [_]u64{0} ** 64;
    var pmm = PageAllocator.init(&bitmap, 0x4000_0000, 4096 * page_size);
    pmm.reserveRange(0x4008_0000, 0x20_0000); // 2 MiB
    try std.testing.expectEqual(@as(usize, 4096 - 512), pmm.stats().free_pages);
    try std.testing.expect(pmm.allocated(0x4008_0000));
    try std.testing.expect(!pmm.allocated(0x4028_0000));
}

test "allocContiguous honours the run requirement" {
    var bitmap = [_]u64{0} ** 64;
    var pmm = PageAllocator.init(&bitmap, 0x4000_0000, 4096 * page_size);
    const run = pmm.allocContiguous(16).?;
    try std.testing.expectEqual(@as(usize, 0), run % page_size);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expect(pmm.allocated(run + i * page_size));
    }
    try std.testing.expect(pmm.allocContiguous(0) == null);
    try std.testing.expect(pmm.allocContiguous(1_000_000) == null);
}

test "largest free run reflects fragmentation" {
    var bitmap = [_]u64{0} ** 64;
    var pmm = PageAllocator.init(&bitmap, 0x4000_0000, 4096 * page_size);
    _ = pmm.alloc().?;
    _ = pmm.alloc().?;
    try std.testing.expectEqual(@as(usize, 4094), pmm.largestFreeRun());
}
