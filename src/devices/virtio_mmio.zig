//! The virtio-mmio transport as a driver (phase 33).
//!
//! `virt` exposes 32 virtio-mmio slots in the device tree. Each is a transport:
//! some carry a device, most are empty. An empty slot is still a real, present
//! transport, so binding it is not a failure — the record keeps it visible and
//! the kernel says how many are empty rather than hiding them.
//!
//! The driver owns the transport's life: reset, feature negotiation, one split
//! virtqueue per device we can use, and a real request for the one device class
//! this phase can exercise end to end (entropy). Block, net, input and GPU are
//! recognised and reported here; their protocols are later phases, and they say
//! so instead of pretending to work.

const std = @import("std");
const virtio = @import("../kernel/virtio.zig");
const driver = @import("../kernel/driver.zig");
const klog = @import("../kernel/klog.zig");

pub const max_slots = 32;
pub const rng_device: u32 = 4;

pub const Slot = struct {
    index: usize = 0,
    base: u64 = 0,
    device_id: u32 = 0,
    vendor_id: u32 = 0,
    version: u32 = 0,
    features: u64 = 0,
    negotiated: u64 = 0,
    queue_size: u16 = 0,
    /// A transport carrying a device (id != 0).
    live: bool = false,
    /// The device answered a real request in this boot.
    served: bool = false,
    request_bytes: u32 = 0,
};

var slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots;
var slot_count: usize = 0;
var live_count: usize = 0;
var served_count: usize = 0;
var failures: usize = 0;

// One queue per slot, in kernel memory: identity-mapped, so the addresses the
// transport is given are the addresses the device will read and write.
var queues: [max_slots]virtio.Queue = [_]virtio.Queue{.{}} ** max_slots;
var descriptors: [max_slots][virtio.ring_size]virtio.Descriptor align(16) = undefined;
var avail_rings: [max_slots]virtio.Avail align(16) = undefined;
var used_rings: [max_slots]virtio.Used align(16) = undefined;
var rng_buffer: [64]u8 align(16) = undefined;

pub fn info() []const Slot {
    return slots[0..slot_count];
}

pub fn liveSlots() usize {
    return live_count;
}

pub fn servedSlots() usize {
    return served_count;
}

pub fn failureCount() usize {
    return failures;
}

pub fn deviceName(id: u32) []const u8 {
    return switch (id) {
        0 => "empty",
        1 => "network",
        2 => "block",
        3 => "console",
        4 => "entropy",
        5 => "balloon",
        16 => "gpu",
        18 => "input",
        else => "unknown",
    };
}

fn busyWait() void {
    var i: usize = 0;
    while (i < 64) : (i += 1) std.atomic.spinLoopHint();
}

/// Drive one real request through the transport. Only the entropy device has a
/// request format this phase can complete: the device writes bytes into the
/// buffer the chain names, which is exactly a virtqueue round trip.
fn entropyRequest(t: *virtio.Mmio, q: *virtio.Queue) !u32 {
    const head = q.allocChain(1) orelse return error.NoMemory;
    q.setDesc(head, 0, @intFromPtr(&rng_buffer), rng_buffer.len, true);
    q.submit(head);
    t.notify(q);
    if (q.waitUsed(1, 1_000_000, busyWait) != 1) {
        // Recovery, not a hang: reset the transport, rebuild the ring, retry
        // once. A device that fails twice is a real failure and is reported.
        t.reset(q);
        klog.warn("virtio", "entropy: no completion, transport reset and retried", .{});
        const again = q.allocChain(1) orelse return error.NoMemory;
        q.setDesc(again, 0, @intFromPtr(&rng_buffer), rng_buffer.len, true);
        q.submit(again);
        t.notify(q);
        if (q.waitUsed(1, 1_000_000, busyWait) != 1) return error.Unsupported;
    }
    _ = t.takeInterrupt();
    return rng_buffer.len;
}

/// Probe one virtio-mmio node: reset, negotiate, set up queue 0, and for a
/// device whose protocol this phase knows, prove the queue with a request.
pub fn probe(dev: *const driver.Device) !void {
    if (dev.reg_count == 0) return error.NoRegion;
    if (slot_count >= max_slots) return error.NoMemory;
    const base: usize = @intCast(dev.regs[0].base);
    const index = slot_count;

    var t = virtio.Mmio.init(base) catch |err| {
        failures += 1;
        klog.warn("virtio", "{s}: {s} at 0x{x} — not driven", .{
            dev.name, switch (err) {
                error.NotVirtio => "no virtio magic",
                error.UnsupportedVersion => "legacy or unknown transport version",
                error.FeaturesRejected => "device rejected the feature subset",
            }, base,
        });
        return error.Unsupported;
    };

    var slot = Slot{
        .index = index,
        .base = dev.regs[0].base,
        .device_id = t.device_id,
        .vendor_id = t.vendor_id,
        .version = t.version,
        .features = t.device_features,
        .negotiated = t.driver_features,
        .live = t.device_id != 0,
    };

    if (slot.live) {
        var q = &queues[index];
        q.init(0, &descriptors[index], &avail_rings[index], &used_rings[index]);
        t.setupQueue(q, 0) catch {
            failures += 1;
            klog.warn("virtio", "{s}: {s} has no usable queue 0", .{ dev.name, deviceName(t.device_id) });
            return error.NoRegion;
        };
        t.driverOk();
        slot.queue_size = q.size;

        if (t.device_id == rng_device) {
            if (entropyRequest(&t, q)) |bytes| {
                slot.served = true;
                slot.request_bytes = bytes;
                served_count += 1;
                klog.info("virtio", "{s}: entropy device served {d} bytes through a split queue (queue {d}, {d} feature word)", .{
                    dev.name, bytes, q.index, t.device_features >> 32,
                });
            } else |err| {
                failures += 1;
                klog.warn("virtio", "{s}: entropy request failed ({s})", .{ dev.name, @errorName(err) });
                return err;
            }
        } else {
            klog.info("virtio", "{s}: {s} device (id {d}), queue 0 ready, protocol is a later phase", .{
                dev.name, deviceName(t.device_id), t.device_id,
            });
        }
        live_count += 1;
    } else {
        klog.debug("virtio", "{s}: empty transport (no device attached)", .{dev.name});
    }

    slots[index] = slot;
    slot_count += 1;
}

/// Hotplug removal: quiesce the transport, then forget the slot.
pub fn remove(dev: *const driver.Device) void {
    var i: usize = 0;
    while (i < slot_count) : (i += 1) {
        if (slots[i].base != dev.regs[0].base) continue;
        var t = virtio.Mmio{ .base = @intCast(dev.regs[0].base) };
        t.reset(&queues[i]);
        if (slots[i].live) {
            live_count -= 1;
            if (slots[i].served) served_count -= 1;
        }
        slots[i].live = false;
        slots[i].served = false;
        slots[i].device_id = 0;
    }
}

pub fn describe() void {
    var empty: usize = 0;
    for (slots[0..slot_count]) |slot| {
        if (!slot.live) empty += 1;
    }
    klog.info("virtio", "{d} transport(s): {d} with a device, {d} empty, {d} refused", .{
        slot_count, live_count, empty, failures,
    });
}
