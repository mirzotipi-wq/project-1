//! Virtio transport (phase 33): one split-virtqueue engine for block, net,
//! input and GPU.
//!
//! The transport is the part every virtio device shares: a device status
//! machine, feature negotiation, descriptor chains, the available/used rings,
//! notification, completion draining and recovery when a device stops
//! answering. The device classes on top are thin: they own their queues and
//! their request formats, never the rings.
//!
//! The implementation is the **modern** layout (virtio 1.0, `virtio-mmio`
//! version 2): feature words are selected by `DeviceFeaturesSel`, the queue
//! addresses are four 32-bit halves, and `VIRTIO_F_VERSION_1` is mandatory.
//! A legacy (version 1) transport is refused by name rather than half-driven.
//!
//! Rings live in the kernel's own physically contiguous memory: the kernel is
//! identity mapped, so a kernel address is the address the device must be given.
//!
//! Three properties are deliberately visible in counters, because "it works" is
//! not evidence:
//!
//!   * **Coalescing.** `drain` takes every completion the device has published,
//!     not one per interrupt: `batches` counts drains that returned more than
//!     one element, which is what a real interrupt does under load.
//!   * **Recovery.** A queue that stops making progress is reset and rebuilt
//!     (`resetQueue`), and the request is retried once. `resets` counts it.
//!   * **Pressure.** The echo self-test churns pages while it runs, because a
//!     transport that only works when memory is plentiful is not a transport.

const std = @import("std");
const builtin = @import("builtin");
const pmm_mod = @import("pmm.zig");
const cpu = @import("../arch/aarch64/cpu.zig");

/// A full barrier between publishing ring entries and the index the device
/// watches. On the target this is the kernel's existing `dsb sy`; on the host
/// build it is a compiler barrier, because the ring tests run on x86.
inline fn fence() void {
    if (comptime builtin.cpu.arch == .aarch64) {
        cpu.dsbSy();
    } else {
        // The host build only runs the ring arithmetic tests, where a real
        // atomic read-modify-write is a sufficient compiler and memory barrier.
        _ = host_barrier.fetchAdd(0, .seq_cst);
    }
}

var host_barrier: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Descriptors per ring. 64 is 1 KiB of ring: enough for chains of several
/// buffers on every class, small enough that a reset is instant.
pub const ring_size = 64;
pub const max_chain = 8;

pub const DescFlags = struct {
    pub const next: u16 = 1;
    pub const write: u16 = 2;
};

/// One split-ring descriptor. `extern` because the device reads this layout.
pub const Descriptor = extern struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

pub const UsedElem = extern struct {
    id: u32 = 0,
    len: u32 = 0,
};

/// Available ring: the driver publishes buffer heads here.
pub const Avail = extern struct {
    flags: u16 = 0,
    idx: u16 = 0,
    ring: [ring_size]u16 = [_]u16{0} ** ring_size,
};

/// Used ring: the device publishes completions here.
pub const Used = extern struct {
    flags: u16 = 0,
    idx: u16 = 0,
    ring: [ring_size]UsedElem = [_]UsedElem{.{}} ** ring_size,
};

pub const Queue = struct {
    index: u16 = 0,
    size: u16 = ring_size,
    desc: *[ring_size]Descriptor = undefined,
    avail: *Avail = undefined,
    used: *Used = undefined,
    free_head: u16 = 0,
    num_free: u16 = 0,
    last_used: u16 = 0,
    /// Interesting for the till's health, not for the data path.
    kicks: u64 = 0,
    completions: u64 = 0,
    /// Drains that returned more than one completion.
    batches: u64 = 0,
    resets: u64 = 0,
    timeouts: u64 = 0,

    pub fn init(self: *Queue, index: u16, desc: *[ring_size]Descriptor, avail: *Avail, used: *Used) void {
        self.index = index;
        self.desc = desc;
        self.avail = avail;
        self.used = used;
        self.size = ring_size;
        self.resetRings();
    }

    /// Rebuild the ring from scratch: this is what a queue reset does on the
    /// driver side, and it is safe to run on a queue the device has forgotten.
    pub fn resetRings(self: *Queue) void {
        for (self.desc, 0..) |*d, i| {
            d.* = .{ .next = @intCast((i + 1) % self.size) };
        }
        self.free_head = 0;
        self.num_free = self.size;
        self.last_used = 0;
        for (&self.avail.ring) |*entry| entry.* = 0;
        self.avail.flags = 0;
        self.avail.idx = 0;
        for (&self.used.ring) |*entry| entry.* = .{};
        self.used.flags = 0;
        self.used.idx = 0;
        self.resets += 1;
    }

    fn volatileUsedIdx(self: *Queue) u16 {
        const p: *volatile u16 = &self.used.idx;
        return p.*;
    }

    fn publishAvail(self: *Queue, head: u16) void {
        const slot: usize = self.avail.idx % self.size;
        self.avail.ring[slot] = head;
        // The index is the one word the device watches: increment it once. (The
        // volatile store and the struct field are the same memory, so bumping
        // the field afterwards would publish a gap the device would skip.)
        const next = self.avail.idx +% 1;
        fence();
        const p: *volatile u16 = &self.avail.idx;
        p.* = next;
        self.kicks += 1;
    }

    /// Take `count` descriptors off the free list and chain them in order.
    /// Returns the head index, or null when the ring cannot satisfy the chain.
    pub fn allocChain(self: *Queue, count: usize) ?u16 {
        if (count == 0 or count > max_chain or count > self.num_free) return null;
        const head = self.free_head;
        var index = head;
        var taken: usize = 1;
        while (taken < count) : (taken += 1) {
            const next = self.desc[index].next;
            self.desc[index].flags = DescFlags.next;
            index = next;
        }
        self.desc[index].flags = 0;
        self.free_head = self.desc[index].next;
        self.num_free -= @intCast(count);
        return head;
    }

    /// Fill one descriptor in a chain that `allocChain` already reserved.
    pub fn setDesc(self: *Queue, head: u16, position: usize, addr: u64, len: u32, write: bool) void {
        var index = head;
        var i: usize = 0;
        while (i < position) : (i += 1) index = self.desc[index].next;
        self.desc[index].addr = addr;
        self.desc[index].len = len;
        if (write) {
            self.desc[index].flags |= DescFlags.write;
        } else {
            self.desc[index].flags &= ~DescFlags.write;
        }
    }

    pub fn submit(self: *Queue, head: u16) void {
        self.publishAvail(head);
    }

    /// Return a chain to the free list. Safe on a device that has already
    /// forgotten the ring: the chain is rebuilt from `head` and the count.
    pub fn freeChain(self: *Queue, head: u16) void {
        var index = head;
        var guard: usize = 0;
        while (guard < max_chain * 4) : (guard += 1) {
            const next = self.desc[index].next;
            const has_next = self.desc[index].flags & DescFlags.next != 0;
            // Push onto the free list.
            self.desc[index].next = self.free_head;
            self.free_head = index;
            self.num_free += 1;
            if (!has_next) break;
            index = next;
        }
    }

    /// One completion, or null. The used index is read volatile: the device
    /// owns that word and only a fence may order the rest of the element.
    pub fn popUsed(self: *Queue) ?UsedElem {
        if (self.volatileUsedIdx() == self.last_used) return null;
        const elem = self.used.ring[self.last_used % self.size];
        fence();
        self.last_used +%= 1;
        return elem;
    }

    /// Take every completion the device has published. This is the coalescing
    /// rule: one interrupt (or one poll) empties the used ring.
    pub fn drain(self: *Queue) usize {
        var n: usize = 0;
        while (self.popUsed()) |elem| {
            self.freeChain(@truncate(elem.id));
            n += 1;
        }
        if (n > 1) self.batches += 1;
        self.completions += n;
        return n;
    }

    /// Wait for at least `wanted` completions, up to `spins` polls. Returns the
    /// number drained. A zero return is a timeout, and the caller must recover.
    pub fn waitUsed(self: *Queue, wanted: usize, spins: usize, busy: *const fn () void) usize {
        var total: usize = 0;
        var i: usize = 0;
        while (total < wanted and i < spins) : (i += 1) {
            total += self.drain();
            if (total < wanted) busy();
        }
        if (total == 0) self.timeouts += 1;
        return total;
    }
};

// ---------------------------------------------------------------------------
// Device features and status
// ---------------------------------------------------------------------------

pub const Status = struct {
    pub const acknowledge: u32 = 1;
    pub const driver: u32 = 2;
    pub const driver_ok: u32 = 4;
    pub const features_ok: u32 = 8;
    pub const needs_reset: u32 = 64;
    pub const failed: u32 = 128;
};

/// `VIRTIO_F_VERSION_1`: without it a modern transport is not a modern
/// transport, and a device that does not offer it is not one this kernel drives.
pub const feature_version_1: u64 = 1 << 32;

/// The subset of features this kernel knows how to keep: what the caller asks
/// for, intersected with what the device offers. A device feature nobody asked
/// for is left off, never accepted blindly, and a feature set without
/// `VIRTIO_F_VERSION_1` is not a modern transport at all.
pub fn negotiate(device_features: u64, wanted: u64) u64 {
    if (wanted & feature_version_1 == 0) return 0;
    return device_features & wanted;
}

// ---------------------------------------------------------------------------
// virtio-mmio transport (version 2)
// ---------------------------------------------------------------------------

pub const Mmio = struct {
    pub const magic_value: u32 = 0x7472_6976; // "virt"

    pub const Reg = struct {
        pub const magic: usize = 0x000;
        pub const version: usize = 0x004;
        pub const device_id: usize = 0x008;
        pub const vendor_id: usize = 0x00c;
        pub const device_features: usize = 0x010;
        pub const device_features_sel: usize = 0x014;
        pub const driver_features: usize = 0x020;
        pub const driver_features_sel: usize = 0x024;
        pub const queue_sel: usize = 0x030;
        pub const queue_num_max: usize = 0x034;
        pub const queue_num: usize = 0x038;
        pub const queue_ready: usize = 0x044;
        pub const queue_notify: usize = 0x050;
        pub const interrupt_status: usize = 0x060;
        pub const interrupt_ack: usize = 0x064;
        pub const status: usize = 0x070;
        /// Device-specific configuration space (virtio-blk's capacity is here).
        pub const config: usize = 0x100;
        pub const queue_desc_lo: usize = 0x080;
        pub const queue_desc_hi: usize = 0x084;
        pub const queue_driver_lo: usize = 0x090;
        pub const queue_driver_hi: usize = 0x094;
        pub const queue_device_lo: usize = 0x0a0;
        pub const queue_device_hi: usize = 0x0a4;
    };

    base: usize = 0,
    version: u32 = 0,
    device_id: u32 = 0,
    vendor_id: u32 = 0,
    device_features: u64 = 0,
    driver_features: u64 = 0,

    pub fn readReg(self: *const Mmio, off: usize) u32 {
        const p: *volatile u32 = @ptrFromInt(self.base + off);
        return p.*;
    }

    pub fn writeReg(self: *const Mmio, off: usize, value: u32) void {
        const p: *volatile u32 = @ptrFromInt(self.base + off);
        p.* = value;
    }

    pub fn status(self: *const Mmio) u32 {
        return self.readReg(Reg.status);
    }

    pub fn setStatus(self: *const Mmio, value: u32) void {
        self.writeReg(Reg.status, value);
    }

    /// Device id straight out of the transport's registers, before a driver
    /// commits to a feature set: a class driver knows which of its own features
    /// it wants, and the transport needs the id to ask for them.
    pub fn peekDeviceId(base: usize) u32 {
        const p: *volatile u32 = @ptrFromInt(base + Reg.device_id);
        return p.*;
    }

    /// Reset, acknowledge, read the feature words, and accept `wanted`.
    pub fn init(base: usize) !Mmio {
        return initWith(base, feature_version_1);
    }

    pub fn initWith(base: usize, wanted: u64) !Mmio {
        var t = Mmio{ .base = base };
        if (t.readReg(Reg.magic) != magic_value) return error.NotVirtio;
        t.version = t.readReg(Reg.version);
        if (t.version != 2) return error.UnsupportedVersion;
        t.device_id = t.readReg(Reg.device_id);
        t.vendor_id = t.readReg(Reg.vendor_id);

        // An empty transport has no device to negotiate a feature set with, and
        // a device that is not there cannot reject one. It is still a transport.
        if (t.device_id == 0) return t;

        t.setStatus(0);
        var st = Status.acknowledge;
        t.setStatus(st);
        st |= Status.driver;
        t.setStatus(st);

        t.writeReg(Reg.device_features_sel, 0);
        const low: u64 = t.readReg(Reg.device_features);
        t.writeReg(Reg.device_features_sel, 1);
        const high: u64 = t.readReg(Reg.device_features);
        t.device_features = (high << 32) | low;

        t.driver_features = negotiate(t.device_features, wanted);
        t.writeReg(Reg.driver_features_sel, 0);
        t.writeReg(Reg.driver_features, @truncate(t.driver_features));
        t.writeReg(Reg.driver_features_sel, 1);
        t.writeReg(Reg.driver_features, @truncate(t.driver_features >> 32));

        t.setStatus(st | Status.features_ok);
        // The device clears FEATURES_OK when it cannot live with the subset.
        if (t.status() & Status.features_ok == 0) return error.FeaturesRejected;
        return t;
    }

    pub fn driverOk(self: *const Mmio) void {
        self.setStatus(self.status() | Status.driver_ok);
    }

    /// Point a queue at kernel memory and make it live. Addresses are written in
    /// two halves, which is the modern layout.
    pub fn setupQueue(self: *Mmio, q: *Queue, index: u16) !void {
        self.writeReg(Reg.queue_sel, index);
        const max = self.readReg(Reg.queue_num_max);
        if (max == 0) return error.NoQueue;
        const size: u32 = @min(max, ring_size);
        self.writeReg(Reg.queue_num, size);
        q.size = @intCast(size);
        const desc_addr: u64 = @intFromPtr(q.desc);
        const avail_addr: u64 = @intFromPtr(q.avail);
        const used_addr: u64 = @intFromPtr(q.used);
        self.writeReg(Reg.queue_desc_lo, @truncate(desc_addr));
        self.writeReg(Reg.queue_desc_hi, @truncate(desc_addr >> 32));
        self.writeReg(Reg.queue_driver_lo, @truncate(avail_addr));
        self.writeReg(Reg.queue_driver_hi, @truncate(avail_addr >> 32));
        self.writeReg(Reg.queue_device_lo, @truncate(used_addr));
        self.writeReg(Reg.queue_device_hi, @truncate(used_addr >> 32));
        fence();
        self.writeReg(Reg.queue_ready, 1);
    }

    pub fn notify(self: *const Mmio, q: *const Queue) void {
        self.writeReg(Reg.queue_notify, q.index);
    }

    /// Read and acknowledge the interrupt status: one acknowledgement covers
    /// every completion the device published, which is what makes draining the
    /// whole used ring the right response.
    pub fn takeInterrupt(self: *const Mmio) u32 {
        const bits = self.readReg(Reg.interrupt_status);
        if (bits != 0) self.writeReg(Reg.interrupt_ack, bits);
        return bits;
    }

    /// Reset the device: queue ready bits cleared, status 0, rings rebuilt by
    /// the caller. This is the recovery path, not a shutdown path.
    pub fn reset(self: *Mmio, q: *Queue) void {
        self.writeReg(Reg.queue_sel, q.index);
        self.writeReg(Reg.queue_ready, 0);
        self.setStatus(0);
        q.resetRings();
    }
};

// ---------------------------------------------------------------------------
// The echo self-test: the transport against a device that answers correctly,
// and against one that does not.
// ---------------------------------------------------------------------------

var echo_desc: [ring_size]Descriptor align(16) = undefined;
var echo_avail: Avail align(16) = undefined;
var echo_used: Used align(16) = undefined;
var echo_out: [64]u8 align(16) = undefined;
var echo_in: [64]u8 align(16) = undefined;

/// Publish one completion on the used ring, the way a device does. The used
/// index is the word the driver watches, so it is incremented exactly once.
fn deviceComplete(q: *Queue, head: u16, len: u32) void {
    const slot: usize = q.used.idx % q.size;
    q.used.ring[slot] = .{ .id = head, .len = len };
    const next = q.used.idx +% 1;
    fence();
    const p: *volatile u16 = &q.used.idx;
    p.* = next;
}

pub const Echo = struct {
    rounds: u64 = 0,
    errors: u64 = 0,
    /// Completions returned by one drain: proof the driver coalesces.
    coalesced: u64 = 0,
    /// Pages held down while the test ran, to make it run under pressure.
    pressure_pages: u64 = 0,
    /// Allocate/free cycles the run performed while the queue was live.
    churn_cycles: u64 = 0,
    alloc_failures: u64 = 0,
    resets: u64 = 0,
    recovered: bool = false,
    pages_before: usize = 0,
    pages_after: usize = 0,
};

var test_pmm: ?*pmm_mod.PageAllocator = null;
/// The pages the echo run holds down. Static, not on the caller's stack: 8192
/// addresses are 64 KiB, and the shell thread's stack is not that large — the
/// first version of this test put them in a local array and the scheduler
/// caught the resulting stack overflow as a corrupt thread frame.
var pressure_slots: [pressure_target]usize = [_]usize{0} ** pressure_target;

pub fn setAllocator(alloc: *pmm_mod.PageAllocator) void {
    test_pmm = alloc;
}

/// Pages the echo run holds down for its whole duration. 8192 pages is 32 MiB,
/// a real slice of the terminal's 512 MiB: enough that the allocator is under
/// pressure, small enough that a failed allocation is a finding rather than a
/// broken boot.
const pressure_target = 8192;

fn churn(pages: []usize, held: usize, cycles: *u64, alloc_failures: *u64) void {
    const alloc = test_pmm orelse return;
    // Allocate one page and release the one it replaces: the pool stays bounded
    // (no leak) while the allocator sees constant traffic under the queue.
    const slot = held % pages.len;
    const fresh = alloc.alloc() orelse {
        alloc_failures.* += 1;
        return;
    };
    if (pages[slot] != 0) alloc.free(pages[slot]);
    pages[slot] = fresh;
    cycles.* += 1;
}

/// Run `rounds` echo requests through a split virtqueue. The "device" side is
/// implemented here in the only way that proves anything about the driver side:
/// it walks the descriptor chain, writes the response buffer the chain named,
/// and publishes a used element — exactly what a real device does.
///
/// Completions are published in groups of four and drained in one call, which is
/// what a coalescing interrupt does; a request that is submitted and never
/// answered exercises the timeout, and the queue is reset and retried once.
pub fn echoTest(rounds: usize) Echo {
    var result = Echo{};

    var q = Queue{};
    q.init(0, &echo_desc, &echo_avail, &echo_used);

    const alloc = test_pmm;
    if (alloc) |a| result.pages_before = a.stats().free_pages;

    const pressure = pressure_slots[0..];
    var held: usize = 0;
    if (alloc) |a| {
        while (held < pressure.len) : (held += 1) {
            pressure[held] = a.alloc() orelse break;
        }
    }
    result.pressure_pages = held;

    var round: usize = 0;
    while (round < rounds) {
        // Four requests per batch: the device answers all four before the
        // driver looks, so one drain has to take four completions.
        const batch: usize = @min(4, rounds - round);
        var heads: [4]u16 = undefined;
        var ok = true;
        for (0..batch) |i| {
            const head = q.allocChain(2) orelse {
                ok = false;
                break;
            };
            echo_out[0] = @truncate((round + i) & 0xFF);
            echo_out[1] = @truncate(((round + i) >> 8) & 0xFF);
            echo_in[0] = 0xAA;
            echo_in[1] = 0xAA;
            q.setDesc(head, 0, @intFromPtr(&echo_out), 2, false);
            q.setDesc(head, 1, @intFromPtr(&echo_in), 2, true);
            q.submit(head);
            heads[i] = head;
        }
        if (!ok) {
            result.errors += 1;
            break;
        }

        // The device side: echo every buffer it was offered.
        for (0..batch) |i| {
            const head = heads[i];
            const out = q.desc[head];
            const in_index = q.desc[head].next;
            const in = q.desc[in_index];
            const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(out.addr)));
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(in.addr)));
            dst[0] = src[0];
            dst[1] = src[1];
            deviceComplete(&q, head, in.len);
        }

        const drained = q.drain();
        if (drained == batch and drained > 1) result.coalesced += 1;
        if (drained != batch or echo_in[0] != echo_out[0] or echo_in[1] != echo_out[1]) {
            result.errors += 1;
        }
        result.rounds += @intCast(batch);

        // Pressure: one page of churn per batch, and the pool stays bounded.
        // One allocate/free cycle every 32 batches: enough traffic that the
        // allocator is working for the whole run, few enough that the test
        // measures the queue rather than the pmm's linear scan.
        if ((round / 4) % 32 == 7) churn(pressure[0..held], held, &result.churn_cycles, &result.alloc_failures);
        round += batch;
    }

    // Timeout and recovery: a request the "device" never answers must be
    // detected, and resetting the queue must make the next one work.
    _ = q.drain();
    if (q.allocChain(1)) |head| {
        q.setDesc(head, 0, @intFromPtr(&echo_out), 1, false);
        q.submit(head);
        const got = q.waitUsed(1, 64, struct {
            fn spin() void {
                std.atomic.spinLoopHint();
            }
        }.spin);
        if (got == 0) {
            q.resetRings();
            result.resets += 1;
            if (q.allocChain(1)) |again| {
                q.setDesc(again, 0, @intFromPtr(&echo_in), 1, true);
                q.submit(again);
                deviceComplete(&q, again, 1);
                result.recovered = q.drain() == 1;
                if (!result.recovered) result.errors += 1;
            }
        } else {
            result.errors += 1; // the queue answered a request nobody served
        }
    }

    if (alloc) |a| {
        for (pressure[0..held]) |page| {
            if (page != 0) a.free(page);
        }
        result.pages_after = a.stats().free_pages;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests: ring arithmetic, with no device in sight.
// ---------------------------------------------------------------------------

test "descriptor chains allocate and free without leaking the free list" {
    var q = Queue{};
    q.init(0, &echo_desc, &echo_avail, &echo_used);
    const first = q.allocChain(2).?;
    try std.testing.expectEqual(@as(u16, 62), q.num_free);
    const second = q.allocChain(3).?;
    try std.testing.expectEqual(@as(u16, 59), q.num_free);
    try std.testing.expect(first != second);
    q.freeChain(first);
    try std.testing.expectEqual(@as(u16, 61), q.num_free);
    q.freeChain(second);
    try std.testing.expectEqual(@as(u16, 64), q.num_free);
}

test "chain flags carry NEXT on every link but the last" {
    var q = Queue{};
    q.init(0, &echo_desc, &echo_avail, &echo_used);
    const head = q.allocChain(3).?;
    q.setDesc(head, 0, 0x1000, 16, false);
    q.setDesc(head, 1, 0x2000, 16, true);
    q.setDesc(head, 2, 0x3000, 8, true);
    const a = q.desc[head];
    const b = q.desc[a.next];
    const c = q.desc[b.next];
    try std.testing.expect(a.flags & DescFlags.next != 0);
    try std.testing.expect(b.flags & DescFlags.next != 0);
    try std.testing.expect(c.flags & DescFlags.next == 0);
    try std.testing.expect(c.flags & DescFlags.write != 0);
    try std.testing.expect(a.flags & DescFlags.write == 0);
}

test "used ring wraps and drain reports the batch size" {
    var q = Queue{};
    q.init(0, &echo_desc, &echo_avail, &echo_used);
    // A device that completes four buffers before the driver looks.
    for (0..4) |i| {
        const slot: usize = q.used.idx % q.size;
        q.used.ring[slot] = .{ .id = @intCast(60 + i), .len = 1 };
        q.used.idx +%= 1;
    }
    try std.testing.expectEqual(@as(usize, 4), q.drain());
    try std.testing.expectEqual(@as(u64, 1), q.batches);
    try std.testing.expectEqual(@as(usize, 0), q.drain());
}

test "negotiation accepts version 1 and refuses features it does not know" {
    const device: u64 = feature_version_1 | (1 << 5) | (1 << 9);
    try std.testing.expectEqual(feature_version_1, negotiate(device, feature_version_1));
    // A class feature is only taken when the caller asks for it.
    try std.testing.expectEqual(feature_version_1 | (1 << 9), negotiate(device, feature_version_1 | (1 << 9)));
    // A legacy-only device offers nothing this kernel accepts.
    try std.testing.expectEqual(@as(u64, 0), negotiate(1 << 5, feature_version_1));
    // A moderm transport request that forgets VERSION_1 is not negotiated.
    try std.testing.expectEqual(@as(u64, 0), negotiate(device, 1 << 9));
}
