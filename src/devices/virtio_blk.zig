//! virtio-blk class driver (phase 34).
//!
//! The first virtio *device class* on the phase-33 transport: a virtual disk.
//! Everything here is the block protocol, not the transport — the queue, the
//! feature words and the status machine come from `kernel/virtio.zig`.
//!
//! A request is the protocol's three-part chain:
//!
//!   * a 16-byte header (type, reserved, sector) the device reads,
//!   * the data buffer (device-reads for a write, device-writes for a read),
//!   * a one-byte status the device writes: 0 ok, 1 I/O error, 2 unsupported.
//!
//! Flush is the same chain without the data buffer, and it only exists if
//! `VIRTIO_BLK_F_FLUSH` was negotiated. If the device does not offer it, the
//! driver says so instead of pretending a write reached the medium.
//!
//! Failure handling is part of the driver, not the caller:
//!
//!   * a **timeout** resets and re-negotiates the transport, rebuilds the queue
//!     and retries (the chain is gone with the ring, which is why the ring is
//!     rebuilt rather than resumed),
//!   * an **I/O error status** is retried with exponential backoff,
//!   * **unsupported** is not retried: it is reported, because repeating it
//!     would only repeat the answer,
//!   * every attempt is counted, so a sick disk is visible in `blk`.

const std = @import("std");
const virtio = @import("../kernel/virtio.zig");
const block_mod = @import("../kernel/block.zig");
const klog = @import("../kernel/klog.zig");
const irq = @import("../kernel/irq.zig");
const driver = @import("../kernel/driver.zig");
const fdt = @import("../lib/fdt.zig");
const timer = @import("../arch/aarch64/timer.zig");
const storage_health = @import("../lib/storage_health.zig");

pub const sector_size = 512;
pub const block_device: u32 = 2;
/// `VIRTIO_BLK_F_FLUSH`: the device understands a flush request.
pub const feature_flush: u64 = 1 << 9;

/// Config space starts here in virtio-mmio: the disk's capacity is the first
/// 64-bit field.
const config_capacity: usize = 0x100;

const ReqType = enum(u32) { read = 0, write = 1, flush = 4 };

const status_ok: u8 = 0;
const status_io_error: u8 = 1;
const status_unsupported: u8 = 2;

const max_attempts: u8 = 3;
const completion_timeout_ms: u64 = 1_000;

pub const Stats = struct {
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    sectors_read: u64 = 0,
    sectors_written: u64 = 0,
    completed: u64 = 0,
    retries: u64 = 0,
    timeouts: u64 = 0,
    io_errors: u64 = 0,
    unsupported: u64 = 0,
    failures: u64 = 0,
    resets: u64 = 0,
    interrupts: u64 = 0,
    last_status: u8 = 0,
};

pub var stats: Stats = .{};

var transport: virtio.Mmio = .{};
var queue: ?*virtio.Queue = null;
var capacity: u64 = 0;
var features: u64 = 0;
var negotiated: u64 = 0;
var ready = false;
var intid: u32 = 0;
var interrupt_count: u64 = 0;
/// Self-test hook: the next request is submitted but the device is not told,
/// so it can only time out. The driver must then reset the transport,
/// re-negotiate and retry — the recovery path, forced on real hardware instead
/// of waiting for a sick disk. Never armed outside `selfTest`.
var inject_timeout_once = false;

/// Phase 49: operational media health and a bounded test-only fault injector.
/// The policy lives in `lib/storage_health.zig`; this driver owns the retry and
/// quarantine edges because those are part of the virtio request state machine.
var g_health: storage_health.Health = .{};
var g_warned_warnings: u32 = 0;

const Fault = struct {
    active: bool = false,
    op: storage_health.Op = .read,
    lba: u64 = 0,
    count: u32 = 0,
    remaining: u32 = 0,

    fn applies(self: *Fault, op: storage_health.Op, lba: u64, count: u32) bool {
        if (!self.active or self.remaining == 0 or self.op != op) return false;
        // A flush has no byte range: match any flush while the fault is armed.
        if (op == .flush) return true;
        if (self.count == 0) return false;
        const a_end = std.math.add(u64, self.lba, self.count) catch return true;
        const b_end = std.math.add(u64, lba, count) catch return true;
        return self.lba < b_end and lba < a_end;
    }

    fn consume(self: *Fault) void {
        if (self.remaining != 0) self.remaining -= 1;
        if (self.remaining == 0) self.active = false;
    }
};

var g_fault: Fault = .{};

pub fn healthSnapshot() storage_health.Snapshot {
    return g_health.snapshot();
}

pub fn healthState() storage_health.State {
    return g_health.state;
}

pub fn badBlocks() []const storage_health.BadBlock {
    return g_health.badSlice();
}

/// Test-only injection: the next `failures` requests that overlap this range
/// return a simulated medium I/O error without touching the device. A caller
/// can then prove recovery or quarantine on real filesystem reads.
pub fn injectFault(op: storage_health.Op, lba: u64, count: u32, failures: u32) void {
    g_fault = .{
        .active = failures != 0 and count != 0,
        .op = op,
        .lba = lba,
        .count = count,
        .remaining = failures,
    };
}

pub fn clearFault() void {
    g_fault = .{};
}

pub fn faultActive() bool {
    return g_fault.active and g_fault.remaining != 0;
}

pub fn faultRemaining() u32 {
    return g_fault.remaining;
}

pub fn scrubRange(lba: u64, count: u32) block_mod.Error!u32 {
    if (count == 0) return 0;
    if (count > 1024) return error.NoSpace;
    var buf: [8 * sector_size]u8 align(8) = undefined;
    var done: u32 = 0;
    while (done < count) {
        const chunk: u32 = @min(@as(u32, 8), count - done);
        try request(.read, lba + done, &buf, chunk * sector_size, true);
        done += chunk;
    }
    return g_health.clearBad(lba, count);
}

fn opOf(kind: ReqType) storage_health.Op {
    return switch (kind) {
        .read => .read,
        .write => .write,
        .flush => .flush,
    };
}

fn warnIfNeeded() void {
    const s = g_health.snapshot();
    if (s.warnings == g_warned_warnings) return;
    g_warned_warnings = s.warnings;
    klog.warn("blk", "storage health {s}: {d} retry(ies), {d} recovered, {d} unrecovered, {d} bad block(s), {d} warning(s)", .{
        s.state.label(), s.retries, s.recovered, s.unrecovered, s.bad_count, s.warnings,
    });
}

pub fn present() bool {
    return ready;
}

pub fn capacitySectors() u64 {
    return capacity;
}

pub fn capacityBytes() u64 {
    return capacity * sector_size;
}

pub fn deviceFeatures() u64 {
    return features;
}

pub fn negotiatedFeatures() u64 {
    return negotiated;
}

pub fn flushSupported() bool {
    return negotiated & feature_flush != 0;
}

pub fn interruptId() u32 {
    return intid;
}

pub fn interruptCount() u64 {
    return interrupt_count;
}

fn interruptHandler(_: u32) void {
    if (!ready) return;
    // Acknowledgement only: the request path drains the ring, and this handler
    // must not touch a queue a thread is using. It still proves the line is
    // wired and that the device raises it.
    _ = transport.takeInterrupt();
    interrupt_count += 1;
}

/// The device tree's interrupt for this node, as a GIC interrupt id. GIC
/// specifiers are <type, number, flags>: type 0 is an SPI (id 32 + n), type 1 a
/// PPI (id 16 + n). A node with no `interrupts` property gets 0: polling only.
fn interruptFor(node_off: usize) u32 {
    const m = driver.attachedMachine() orelse return 0;
    if (!m.fdt_valid or m.dtb == 0 or node_off == 0) return 0;
    const bytes: [*]const u8 = @ptrFromInt(m.dtb);
    const tree = fdt.Fdt.init(bytes[0..m.dtb_size]) catch return 0;
    const raw = tree.prop(.{ .off = node_off }, "interrupts") orelse return 0;
    if (raw.len >= 12) {
        const kind = std.mem.readInt(u32, raw[0..4], .big);
        const number = std.mem.readInt(u32, raw[4..8], .big);
        return switch (kind) {
            0 => 32 + number,
            1 => 16 + number,
            else => 0,
        };
    }
    if (raw.len >= 8) {
        return 32 + std.mem.readInt(u32, raw[0..4], .big);
    }
    return 0;
}

/// Take a transport that already negotiated features and a live queue 0.
pub fn attach(t: virtio.Mmio, q: *virtio.Queue, node_off: usize, wanted: u64) !void {
    // Health belongs to one attachment: a re-probed device must not inherit a
    // previous device's quarantine or warning count.
    g_health.reset();
    g_warned_warnings = 0;
    g_fault = .{};
    transport = t;
    queue = q;
    features = t.device_features;
    negotiated = t.driver_features;
    if (negotiated & wanted != wanted and wanted != virtio.feature_version_1) {
        // The caller asked for a feature the device did not keep; the transport
        // has already written the subset, so trust what the device confirmed.
    }
    const low: u64 = transport.readReg(config_capacity);
    const high: u64 = transport.readReg(config_capacity + 4);
    capacity = (high << 32) | low;
    if (capacity == 0) return error.NoCapacity;

    intid = interruptFor(node_off);
    if (intid != 0) {
        irq.register(intid, interruptHandler);
        klog.info("blk", "interrupt {d} routed to the GIC (acknowledged in the handler, ring drained by the caller)", .{intid});
    } else {
        klog.info("blk", "no interrupt property on the transport: completions are polled", .{});
    }

    block_mod.install(.{
        .capacity_sectors = capacity,
        .read = backendRead,
        .write = backendWrite,
        .flush = backendFlush,
    });
    ready = true;
    klog.info("blk", "virtio-blk: {d} sectors ({d} MiB), features 0x{x}, flush {s}", .{
        capacity,                                              (capacity * sector_size) / (1024 * 1024), features,
        if (flushSupported()) "negotiated" else "not offered",
    });
}

pub fn detach() void {
    if (intid != 0) irq.unregister(intid);
    if (ready) {
        if (queue) |q| {
            transport.writeReg(virtio.Mmio.Reg.queue_ready, 0);
            q.resetRings();
        }
    }
    ready = false;
    capacity = 0;
    queue = null;
    intid = 0;
    g_health.reset();
    g_warned_warnings = 0;
    g_fault = .{};
    block_mod.uninstall();
}

fn backendRead(lba: u64, buf: [*]u8, count: u32) block_mod.Error!void {
    return readSectors(lba, buf, count);
}

fn backendWrite(lba: u64, buf: [*]const u8, count: u32) block_mod.Error!void {
    return writeSectors(lba, buf, count);
}

fn backendFlush() block_mod.Error!void {
    return flush();
}

fn busyWait() void {
    var i: usize = 0;
    while (i < 256) : (i += 1) std.atomic.spinLoopHint();
}

fn backoff(attempt: u8) void {
    const ms: u64 = @as(u64, 1) << @intCast(attempt);
    const until = timer.uptimeMs() + ms;
    while (timer.uptimeMs() < until) busyWait();
}

fn waitCompletion(q: *virtio.Queue) bool {
    const deadline = timer.uptimeMs() + completion_timeout_ms;
    while (timer.uptimeMs() < deadline) {
        if (q.drain() > 0) return true;
        busyWait();
    }
    return false;
}

/// Reset, re-negotiate and rebuild queue 0 after a device that stopped
/// answering. The chain that timed out is gone with the old ring, which is why
/// recovery rebuilds instead of resuming.
fn recover() void {
    const q = queue orelse return;
    stats.resets += 1;
    // Rebuild the rings before the device is pointed at them again. A
    // transport reset makes the device forget the queue, but the driver's
    // available index and the timed-out chain are still in memory. Left there,
    // the device reads that stale entry against a rebuilt descriptor table and
    // answers "virtio-blk missing headers"; cleared, it starts from an empty
    // ring and the retried chain is the only thing it sees.
    q.resetRings();
    var fresh = virtio.Mmio.initWith(@intCast(transport.base), virtio.feature_version_1 | feature_flush) catch {
        ready = false;
        klog.warn("blk", "transport did not come back after a reset", .{});
        return;
    };
    fresh.setupQueue(q, 0) catch {
        ready = false;
        klog.warn("blk", "queue 0 could not be rebuilt after a reset", .{});
        return;
    };
    fresh.driverOk();
    transport = fresh;
    klog.warn("blk", "device reset and re-negotiated after {d} timeout(s)", .{stats.timeouts});
}

fn request(kind: ReqType, lba: u64, buf: ?[*]u8, len: u32, bypass_bad: bool) block_mod.Error!void {
    if (!ready) return error.NoDevice;
    const q = queue orelse return error.NoDevice;
    const sectors: u32 = if (kind == .flush) 0 else len / sector_size;
    if (kind != .flush) {
        if (!block_mod.fits(capacity, lba, len)) return error.NoSpace;
        if (!bypass_bad and g_health.isBad(lba, sectors)) {
            g_health.noteBadRefusal();
            return error.BadBlock;
        }
    } else if (!flushSupported()) {
        return error.Unsupported;
    }

    var header: [16]u8 align(8) = undefined;
    std.mem.writeInt(u32, header[0..4], @intFromEnum(kind), .little);
    std.mem.writeInt(u32, header[4..8], 0, .little);
    std.mem.writeInt(u64, header[8..16], lba, .little);
    var status_byte: [1]u8 align(1) = .{0xFF};

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const op = opOf(kind);

        // A simulated medium error follows the same retry path as a real I/O
        // status: it is never a silent success and it never reaches the device
        // with a half-built descriptor chain.
        if (g_fault.applies(op, lba, sectors)) {
            g_fault.consume();
            stats.io_errors += 1;
            stats.retries += 1;
            g_health.noteRetry(op, .io, lba, sectors);
            warnIfNeeded();
            backoff(attempt);
            continue;
        }

        const chain_len: usize = if (kind == .flush) 2 else 3;
        const head = q.allocChain(chain_len) orelse return error.NoMemory;
        q.setDesc(head, 0, @intFromPtr(&header), header.len, false);
        if (kind != .flush) {
            q.setDesc(head, 1, @intFromPtr(buf.?), len, kind == .read);
        }
        q.setDesc(head, chain_len - 1, @intFromPtr(&status_byte), 1, true);
        status_byte[0] = 0xFF;

        // The phase-34 self-test forces one timeout; that test fault is not a
        // production media warning and must not degrade the health surface on
        // every clean boot. Operational timeouts still do.
        const forced_timeout = inject_timeout_once;
        q.submit(head);
        if (forced_timeout) {
            inject_timeout_once = false;
            // Deliberately no notify: this request is invisible to the device.
        } else {
            transport.notify(q);
        }

        if (!waitCompletion(q)) {
            stats.timeouts += 1;
            stats.retries += 1;
            if (!forced_timeout) {
                g_health.noteRetry(op, .timeout, lba, sectors);
                warnIfNeeded();
            }
            recover();
            if (!ready) {
                g_health.noteFailure(op, .timeout, lba, sectors);
                warnIfNeeded();
                return error.IoError;
            }
            backoff(attempt);
            continue;
        }

        const status = status_byte[0];
        stats.last_status = status;
        if (status == status_ok) {
            stats.completed += 1;
            switch (kind) {
                .read => stats.reads += 1,
                .write => stats.writes += 1,
                .flush => stats.flushes += 1,
            }
            if (kind == .read) stats.sectors_read += len else if (kind == .write) stats.sectors_written += len;
            g_health.complete(op, sectors);
            if (attempt != 0 and !forced_timeout) {
                g_health.noteRecovered(op, lba);
                warnIfNeeded();
            }
            return;
        }
        if (status == status_unsupported) {
            stats.unsupported += 1;
            g_health.noteFailure(op, .unsupported, lba, sectors);
            warnIfNeeded();
            return error.Unsupported;
        }
        stats.io_errors += 1;
        stats.retries += 1;
        g_health.noteRetry(op, .io, lba, sectors);
        warnIfNeeded();
        backoff(attempt);
    }
    stats.failures += 1;
    g_health.noteFailure(opOf(kind), .io, lba, sectors);
    if (kind != .flush) _ = g_health.addBad(lba, sectors);
    warnIfNeeded();
    return error.IoError;
}

pub fn readSectors(lba: u64, buf: [*]u8, count: u32) block_mod.Error!void {
    if (count == 0) return;
    return request(.read, lba, buf, count * sector_size, false);
}

pub fn writeSectors(lba: u64, buf: [*]const u8, count: u32) block_mod.Error!void {
    if (count == 0) return;
    return request(.write, lba, @constCast(buf), count * sector_size, false);
}

pub fn flush() block_mod.Error!void {
    return request(.flush, 0, null, 0, false);
}

// ---------------------------------------------------------------------------
// The phase's own test: 10 000 scattered writes, a flush, and a digest that a
// later boot can check after the machine was killed without a clean shutdown.
//
// There is no filesystem yet (partitions and the filesystem are later phases),
// so the "no corruption" check is the strongest one available at this layer:
// every sector's bytes are a function of its LBA and a generation seed, and the
// generation's digest is written to LBA 0 only after the data was flushed. A
// boot that comes up after an unclean quit recomputes the digest from the disk
// and compares it with the marker.
// ---------------------------------------------------------------------------

pub const marker_lba: u64 = 0;
pub const data_base: u64 = 8;
/// A sector outside the generation's data region, for the forced-fault write:
/// it must not disturb the digest the marker records.
pub const scratch_lba: u64 = 4;
pub const data_count: u32 = 10_000;
const read_chunk: u32 = 8;

const fnv_offset: u64 = 0xcbf2_9ce4_8422_2325;
const fnv_prime: u64 = 0x0000_0100_0000_01b3;

fn fnvBytes(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return h;
}

/// A sector's contents: deterministic in (LBA, seed), so the writer and the
/// verifier agree without storing 5 MiB of expected data anywhere.
fn fillSector(buf: []u8, lba: u64, seed: u64) void {
    var state = lba *% 0x9E37_79B9_7F4A_7C15 ^ seed;
    var i: usize = 0;
    while (i < sector_size) : (i += 8) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        std.mem.writeInt(u64, buf[i..][0..8], state, .little);
    }
}

fn fillExpected(buf: []u8, lba: u64, seed: u64) void {
    fillSector(buf, lba, seed);
}

/// Compare two sector-sized buffers byte by byte. Written out rather than
/// `std.mem.eql`: in this build the library call returned false for buffers
/// that were byte-identical (the diagnostic below found the first difference at
/// byte 512, i.e. there was none), and a verification gate that can lie about
/// equality is worse than no gate. This loop has no such ambiguity.
fn sameSector(a: []const u8, b: []const u8) bool {
    if (a.len < sector_size or b.len < sector_size) return false;
    var i: usize = 0;
    while (i < sector_size) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

const Marker = struct {
    valid: bool = false,
    seed: u64 = 0,
    base: u64 = 0,
    count: u32 = 0,
    digest: u64 = 0,
};

const marker_magic = "CASSA-BLK-34\x00\x00\x00\x00";
const marker_version: u32 = 1;

fn encodeMarker(raw: *[sector_size]u8, marker: Marker) void {
    @memset(raw, 0);
    @memcpy(raw[0..16], marker_magic);
    std.mem.writeInt(u32, raw[16..20], marker_version, .little);
    std.mem.writeInt(u64, raw[24..32], marker.seed, .little);
    std.mem.writeInt(u64, raw[32..40], marker.base, .little);
    std.mem.writeInt(u32, raw[40..44], marker.count, .little);
    std.mem.writeInt(u64, raw[48..56], marker.digest, .little);
    const sum = fnvBytes(fnv_offset, raw[0..56]);
    std.mem.writeInt(u64, raw[56..64], sum, .little);
}

fn decodeMarker(raw: *const [sector_size]u8) Marker {
    if (!std.mem.eql(u8, raw[0..16], marker_magic)) return .{};
    const version = std.mem.readInt(u32, raw[16..20], .little);
    if (version != marker_version) return .{};
    const sum = std.mem.readInt(u64, raw[56..64], .little);
    if (fnvBytes(fnv_offset, raw[0..56]) != sum) return .{};
    return .{
        .valid = true,
        .seed = std.mem.readInt(u64, raw[24..32], .little),
        .base = std.mem.readInt(u64, raw[32..40], .little),
        .count = std.mem.readInt(u32, raw[40..44], .little),
        .digest = std.mem.readInt(u64, raw[48..56], .little),
    };
}

var order: [data_count]u16 = [_]u16{0} ** data_count;
/// One sector buffer per elevator slot. The scheduler holds up to
/// `max_batch` writes and dispatches them later, so they cannot all point at
/// one buffer: the first version did, and every sector in a batch was written
/// with the last sector's payload.
var write_buffers: [block_mod.max_batch][sector_size]u8 align(8) = undefined;

/// Every LBA in the test region exactly once, in a shuffled order: "10k random
/// writes" that still lets the verifier know every sector's final contents.
fn shuffleOrder(seed: u64) void {
    for (&order, 0..) |*slot, i| slot.* = @intCast(i);
    var state = seed ^ 0xD1B5_4A32_D192_ED03;
    var i: usize = order.len;
    while (i > 1) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        i -= 1;
        const j: usize = @intCast(state % (i + 1));
        const tmp = order[i];
        order[i] = order[j];
        order[j] = tmp;
    }
}

pub const SelfTest = struct {
    present: bool = false,
    capacity: u64 = 0,
    flush_offered: bool = false,
    flush_negotiated: bool = false,
    /// A marker from an earlier generation was found and its digest matched.
    restart_verified: bool = false,
    restart_seed: u64 = 0,
    restart_digest: u64 = 0,
    /// The marker existed but its digest did not match the data on the disk.
    restart_mismatch: bool = false,
    seed: u64 = 0,
    digest: u64 = 0,
    written: u32 = 0,
    verified: u32 = 0,
    mismatches: u32 = 0,
    errors: u32 = 0,
    batches: u32 = 0,
    reordered: u64 = 0,
    /// The forced-timeout request: the retry after a transport reset worked.
    fault_injected: bool = false,
    fault_recovered: bool = false,
    fault_retries: u64 = 0,
    fault_resets: u64 = 0,
    device: Stats = .{},
    scheduler: block_mod.Stats = .{},
};

pub fn selfTest() SelfTest {
    var result = SelfTest{};
    if (!ready) return result;
    result.present = true;
    result.capacity = capacity;
    result.flush_offered = features & feature_flush != 0;
    result.flush_negotiated = flushSupported();
    if (capacity < data_base + data_count + 8) {
        result.errors += 1;
        return result;
    }

    var buffer: [read_chunk * sector_size]u8 align(8) = undefined;
    var expected: [sector_size]u8 align(8) = undefined;
    var marker_raw: [sector_size]u8 align(8) = undefined;

    var previous = Marker{};
    if (readSectors(marker_lba, &marker_raw, 1)) |_| {
        previous = decodeMarker(&marker_raw);
    } else |_| {
        result.errors += 1;
    }

    // 1. If an earlier boot left a flushed generation behind, verify it before
    //    overwriting anything. This is the check that an unclean quit gets.
    result.restart_verified = previous.valid and previous.base == data_base and
        previous.count == data_count and previous.seed != 0;
    if (result.restart_verified) {
        result.restart_seed = previous.seed;
        var digest: u64 = fnv_offset;
        var mismatches: u32 = 0;
        var verified: u32 = 0;
        var lba: u64 = data_base;
        while (lba < data_base + data_count) {
            const remaining: u32 = @intCast(data_base + data_count - lba);
            const count: u32 = @min(read_chunk, remaining);
            if (readSectors(lba, &buffer, count)) |_| {
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    fillExpected(&expected, lba + k, previous.seed);
                    const got = buffer[k * sector_size ..][0..sector_size];
                    if (!sameSector(got, &expected)) mismatches += 1;
                    digest = fnvBytes(digest, got);
                }
                verified += count;
            } else |_| {
                mismatches += count;
                result.errors += 1;
            }
            lba += count;
        }
        result.restart_digest = digest;
        result.verified += verified;
        result.mismatches += mismatches;
        result.restart_mismatch = mismatches != 0 or digest != previous.digest;
        if (!result.restart_mismatch) {
            klog.info("blk", "generation {d} verified from disk: {d} sector(s), digest 0x{x:0>16}", .{
                previous.seed, verified, digest,
            });
        }
    }

    // 2. Write a new generation: every sector of the region once, shuffled,
    //    through the block layer's elevator, then a flush.
    const seed: u64 = if (previous.valid and previous.seed != 0) previous.seed + 1 else 1;
    result.seed = seed;
    shuffleOrder(seed);

    var batch = block_mod.Scheduler{};
    var index: u32 = 0;
    while (index < data_count) {
        batch.reset();
        const start = index;
        while (index < data_count and index - start < block_mod.max_batch) : (index += 1) {
            const lba = data_base + order[index];
            const slot: usize = index - start;
            fillSector(write_buffers[slot][0..], lba, seed);
            batch.addWrite(lba, &write_buffers[slot], 1) catch {
                result.errors += 1;
                break;
            };
        }
        if (batch.count == 0) continue;
        const count = batch.count;
        batch.dispatch() catch {
            result.errors += 1;
            return result;
        };
        result.written += @intCast(count);
        result.batches += 1;
    }
    result.reordered += block_mod.stats.reordered;
    if (flush()) |_| {} else |_| result.errors += 1;

    // 3. Read the generation back and compare every byte.
    var digest: u64 = fnv_offset;
    var lba: u64 = data_base;
    while (lba < data_base + data_count) {
        const remaining: u32 = @intCast(data_base + data_count - lba);
        const count: u32 = @min(read_chunk, remaining);
        if (readSectors(lba, &buffer, count)) |_| {
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                fillExpected(&expected, lba + k, seed);
                const got = buffer[k * sector_size ..][0..sector_size];
                if (!sameSector(got, &expected)) {
                    result.mismatches += 1;
                    if (result.mismatches <= 4) {
                        var at: usize = 0;
                        while (at < sector_size and got[at] == expected[at]) : (at += 1) {}
                        klog.warn("blk", "readback mismatch: lba {d} (chunk {d} sector {d}) lens {d}/{d} first differing byte {d}: got 0x{x:0>2} want 0x{x:0>2}", .{
                            lba + k,                          lba,                                        k, got.len, expected.len, at,
                            if (at < got.len) got[at] else 0, if (at < expected.len) expected[at] else 0,
                        });
                    }
                }
                digest = fnvBytes(digest, got);
            }
            result.verified += count;
        } else |_| {
            result.mismatches += count;
            result.errors += 1;
        }
        lba += count;
    }
    result.digest = digest;
    if (digest != generatedDigest(seed)) result.mismatches += 1;

    // 4. Forced fault: one request the device is never told about. A timeout
    //    must become a transport reset, a re-negotiation and a successful
    //    retry — not a hang, and not a silent success.
    const retries_before = stats.retries;
    const resets_before = stats.resets;
    var scratch: [sector_size]u8 align(8) = undefined;
    fillSector(scratch[0..], scratch_lba, seed ^ 0xA5A5);
    inject_timeout_once = true;
    const fault_result = writeSectors(scratch_lba, &scratch, 1);
    inject_timeout_once = false;
    result.fault_injected = true;
    result.fault_retries = stats.retries - retries_before;
    result.fault_resets = stats.resets - resets_before;
    if (fault_result) |_| {
        var reread: [sector_size]u8 align(8) = undefined;
        if (readSectors(scratch_lba, &reread, 1)) |_| {
            result.fault_recovered = sameSector(&reread, &scratch) and
                result.fault_retries != 0 and result.fault_resets != 0;
        } else |_| {}
    } else |_| {}

    // 5. Only now, with the data flushed, publish the marker that a later boot
    //    will compare against.
    const marker = Marker{
        .valid = true,
        .seed = seed,
        .base = data_base,
        .count = data_count,
        .digest = digest,
    };
    encodeMarker(&marker_raw, marker);
    if (writeSectors(marker_lba, &marker_raw, 1)) |_| {} else |_| result.errors += 1;
    if (flush()) |_| {} else |_| result.errors += 1;

    result.device = stats;
    result.scheduler = block_mod.stats;
    return result;
}

/// The digest the generation *should* have, computed from the generator in LBA
/// order. Comparing it with the digest of the bytes read back is what makes a
/// mismatch a corruption rather than a bug in the comparison.
fn generatedDigest(seed: u64) u64 {
    var sector: [sector_size]u8 align(8) = undefined;
    var digest: u64 = fnv_offset;
    var i: u32 = 0;
    while (i < data_count) : (i += 1) {
        fillSector(&sector, data_base + i, seed);
        digest = fnvBytes(digest, &sector);
    }
    return digest;
}
