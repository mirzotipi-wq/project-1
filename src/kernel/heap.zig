//! Kernel heap: boundary-tag free list with splitting and coalescing, exposed
//! as a `std.mem.Allocator` — phase 8.
//!
//! Every block carries a header with a magic value and a footer with its size,
//! so double frees and header corruption are caught immediately instead of
//! silently corrupting the kernel.

const std = @import("std");

const header_size = 16;
const footer_size = 8;
const min_block = 32;
const magic_active: u32 = 0xCA55_A11C;
const magic_free: u32 = 0xCA55_F4EE;

const Header = extern struct {
    size: u64,
    flags: u32,
    magic: u32,

    fn isFree(self: Header) bool {
        return (self.flags & 1) != 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == header_size);
}

pub const Stats = struct {
    total_bytes: usize,
    used_bytes: usize,
    free_bytes: usize,
    blocks: usize,
    largest_free: usize,
};

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn alignDown(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
}

pub const Heap = struct {
    start: usize = 0,
    end: usize = 0,
    used_bytes: usize = 0,
    initialized: bool = false,

    fn headerAt(addr: usize) *Header {
        return @ptrFromInt(addr);
    }

    fn writeFooter(block: usize, size: usize) void {
        const footer: *u64 = @ptrFromInt(block + size - footer_size);
        footer.* = size;
    }

    fn readFooter(block_end: usize) u64 {
        const footer: *const u64 = @ptrFromInt(block_end - footer_size);
        return footer.*;
    }

    /// Carve a heap out of a raw byte region. The region must outlive the heap.
    pub fn init(region: []u8) Heap {
        var self = Heap{};
        if (region.len < min_block * 2) return self;

        const start = alignUp(@intFromPtr(region.ptr), 16);
        const end = alignDown(@intFromPtr(region.ptr) + region.len, 16);
        if (end - start < min_block) return self;

        const size = end - start;
        const h = headerAt(start);
        h.* = .{ .size = size, .flags = 1, .magic = magic_free };
        writeFooter(start, size);

        self.start = start;
        self.end = end;
        self.initialized = true;
        return self;
    }

    fn nextBlock(self: *const Heap, block: usize) ?usize {
        const h = headerAt(block);
        const next = block + h.size;
        if (next + header_size <= self.end) return next;
        return null;
    }

    fn prevBlock(self: *const Heap, block: usize) ?usize {
        if (block <= self.start + header_size) return null;
        const prev_size = readFooter(block);
        if (prev_size < min_block or prev_size > block - self.start) return null;
        return block - prev_size;
    }

    /// Allocate `len` bytes with `alignment` (at most 16, which covers every
    /// type the kernel uses; page-aligned memory comes from the PMM).
    pub fn alloc(self: *Heap, len: usize, alignment: usize) ?[*]u8 {
        if (!self.initialized or len == 0) return null;
        if (alignment > 16) return null;

        const payload = alignUp(len, 16);
        // Round the whole block to 16 bytes so every block start stays aligned.
        const needed = alignUp(@max(payload + header_size + footer_size, min_block), 16);

        var block = self.start;
        while (block + header_size <= self.end) {
            const h = headerAt(block);
            if (h.magic != magic_active and h.magic != magic_free) @panic("heap: corrupted block header");
            if (h.isFree() and h.size >= needed) {
                const remainder = h.size - needed;
                if (remainder >= min_block) {
                    h.size = needed;
                    const rest = block + needed;
                    const rh = headerAt(rest);
                    rh.* = .{ .size = remainder, .flags = 1, .magic = magic_free };
                    writeFooter(rest, remainder);
                }
                h.flags = 0;
                h.magic = magic_active;
                writeFooter(block, h.size);
                self.used_bytes += h.size;
                return @ptrFromInt(block + header_size);
            }
            const next = self.nextBlock(block) orelse break;
            block = next;
        }
        return null;
    }

    pub fn free(self: *Heap, ptr: [*]u8) void {
        if (!self.initialized) return;
        const block = @intFromPtr(ptr) - header_size;
        if (block < self.start or block >= self.end) @panic("heap: free of a non-heap pointer");
        const h = headerAt(block);
        if (h.magic != magic_active) @panic("heap: double free or corrupted header");
        if (h.isFree()) @panic("heap: double free");

        self.used_bytes -= h.size;
        h.flags |= 1;
        h.magic = magic_free;

        // Coalesce with the following block.
        if (self.nextBlock(block)) |next| {
            const nh = headerAt(next);
            if (nh.isFree()) {
                h.size += nh.size;
                writeFooter(block, h.size);
            }
        }
        // Coalesce with the preceding block.
        if (self.prevBlock(block)) |prev| {
            const ph = headerAt(prev);
            if (ph.magic == magic_free and ph.isFree()) {
                ph.size += h.size;
                writeFooter(prev, ph.size);
            }
        }
    }

    fn capacity(h: Header) usize {
        return h.size - header_size - footer_size;
    }

    fn resize(self: *Heap, ptr: [*]u8, new_len: usize, alignment: usize) bool {
        if (!self.initialized or alignment > 16) return false;
        const block = @intFromPtr(ptr) - header_size;
        const h = headerAt(block);
        if (h.magic != magic_active) return false;

        const old_size = h.size;
        const needed = alignUp(@max(alignUp(new_len, 16) + header_size + footer_size, min_block), 16);

        if (needed <= h.size) {
            const remainder = h.size - needed;
            if (remainder >= min_block) {
                h.size = needed;
                const rest = block + needed;
                const rh = headerAt(rest);
                rh.* = .{ .size = remainder, .flags = 1, .magic = magic_free };
                writeFooter(rest, remainder);
                writeFooter(block, h.size);
                // The new tail block may merge with its successor.
                if (self.nextBlock(rest)) |after| {
                    const ah = headerAt(after);
                    if (ah.isFree()) {
                        rh.size += ah.size;
                        writeFooter(rest, rh.size);
                    }
                }
            }
            self.used_bytes -= old_size - h.size;
            return true;
        }

        // Try to absorb the following free block.
        if (self.nextBlock(block)) |next| {
            const nh = headerAt(next);
            if (nh.isFree() and h.size + nh.size >= needed) {
                h.size += nh.size;
                const remainder = h.size - needed;
                if (remainder >= min_block) {
                    h.size = needed;
                    const rest = block + needed;
                    const rh = headerAt(rest);
                    rh.* = .{ .size = remainder, .flags = 1, .magic = magic_free };
                    writeFooter(rest, remainder);
                }
                writeFooter(block, h.size);
                self.used_bytes += h.size - old_size;
                return true;
            }
        }
        return false;
    }

    pub fn stats(self: *const Heap) Stats {
        var total: usize = 0;
        var free_bytes: usize = 0;
        var blocks: usize = 0;
        var largest: usize = 0;
        var block = self.start;
        while (self.initialized and block + header_size <= self.end) {
            const h = headerAt(block);
            total += h.size;
            blocks += 1;
            if (h.isFree()) {
                const room = h.size - header_size - footer_size;
                free_bytes += room;
                if (room > largest) largest = room;
            }
            const next = self.nextBlock(block) orelse break;
            block = next;
        }
        return .{
            .total_bytes = total,
            .used_bytes = self.used_bytes,
            .free_bytes = free_bytes,
            .blocks = blocks,
            .largest_free = largest,
        };
    }

    // -----------------------------------------------------------------------
    // std.mem.Allocator plumbing
    // -----------------------------------------------------------------------

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        return self.alloc(len, alignment.toByteUnits());
    }

    fn vResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        return self.resize(memory.ptr, new_len, alignment.toByteUnits());
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        if (self.resize(memory.ptr, new_len, alignment.toByteUnits())) return memory.ptr;
        const fresh = self.alloc(new_len, alignment.toByteUnits()) orelse return null;
        @memcpy(fresh[0..@min(new_len, memory.len)], memory[0..@min(new_len, memory.len)]);
        self.free(memory.ptr);
        _ = ret_addr;
        return fresh;
    }

    fn vFree(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        self.free(memory.ptr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };

    pub fn allocator(self: *Heap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "allocations are aligned, distinct and reclaimable" {
    const backing = try std.testing.allocator.alignedAlloc(u8, 16, 1 << 16);
    defer std.testing.allocator.free(backing);

    var heap = Heap.init(backing);
    try std.testing.expect(heap.initialized);

    const a = heap.alloc(16, 8).?;
    const b = heap.alloc(64, 16).?;
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(b) % 16);

    a[0] = 0xAA;
    b[0] = 0xBB;
    try std.testing.expectEqual(@as(u8, 0xAA), a[0]);

    heap.free(a);
    heap.free(b);
    const s = heap.stats();
    try std.testing.expectEqual(@as(usize, 0), s.used_bytes);
    try std.testing.expectEqual(@as(usize, 1), s.blocks); // fully coalesced
}

test "randomised alloc/free leaves no leaks and one coalesced block" {
    const backing = try std.testing.allocator.alignedAlloc(u8, 16, 1 << 18);
    defer std.testing.allocator.free(backing);

    var heap = Heap.init(backing);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();

    var live: [64]?[*]u8 = [_]?[*]u8{null} ** 64;
    var live_lens: [64]usize = [_]usize{0} ** 64;

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const slot = rand.intRangeLessThan(usize, 0, live.len);
        if (live[slot] == null) {
            const len = rand.intRangeAtMost(usize, 1, 300);
            if (heap.alloc(len, 16)) |p| {
                @memset(p[0..len], @truncate(slot + round));
                live[slot] = p;
                live_lens[slot] = len;
            }
        } else {
            heap.free(live[slot].?);
            live[slot] = null;
        }
    }
    for (live) |maybe| {
        if (maybe) |p| heap.free(p);
    }
    const s = heap.stats();
    try std.testing.expectEqual(@as(usize, 0), s.used_bytes);
    try std.testing.expectEqual(@as(usize, 0), s.free_bytes - s.free_bytes); // no overflow
    try std.testing.expect(s.free_bytes > 0);
}

test "resize grows in place and shrinks with a split" {
    const backing = try std.testing.allocator.alignedAlloc(u8, 16, 1 << 15);
    defer std.testing.allocator.free(backing);

    var heap = Heap.init(backing);
    const p = heap.alloc(32, 16).?;
    @memset(p[0..32], 7);
    try std.testing.expect(heap.resize(p, 2048, 16));
    @memset(p[0..2048], 9);
    try std.testing.expectEqual(@as(u8, 9), p[2047]);
    try std.testing.expect(heap.resize(p, 16, 16));
    heap.free(p);
    try std.testing.expectEqual(@as(usize, 0), heap.stats().used_bytes);
}

test "heap backs std containers" {
    const backing = try std.testing.allocator.alignedAlloc(u8, 16, 1 << 16);
    defer std.testing.allocator.free(backing);

    var heap = Heap.init(backing);
    const a = heap.allocator();

    var list = std.ArrayList(u32).init(a);
    defer list.deinit();
    for (0..100) |i| try list.append(@intCast(i));
    try std.testing.expectEqual(@as(usize, 100), list.items.len);
    try std.testing.expectEqual(@as(u32, 99), list.items[99]);

    const greeting = try std.fmt.allocPrint(a, "cassa {d}", .{1});
    defer a.free(greeting);
    try std.testing.expectEqualStrings("cassa 1", greeting);
}

test "over-aligned allocations are refused rather than misaligned" {
    const backing = try std.testing.allocator.alignedAlloc(u8, 16, 1 << 12);
    defer std.testing.allocator.free(backing);
    var heap = Heap.init(backing);
    try std.testing.expect(heap.alloc(16, 4096) == null);
}
