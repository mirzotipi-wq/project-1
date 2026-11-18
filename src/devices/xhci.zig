//! xHCI host controller (phase 39).
//!
//! This is the half of the USB stack that talks to hardware: PCI function to
//! mapped BAR, controller reset, command/event/transfer rings, slots and
//! endpoint contexts, port reset, and the three transfer shapes the class
//! drivers need (control, interrupt IN, bulk). Enumeration policy and class
//! decoding live above it in `kernel/usb.zig`; this file knows nothing about
//! keyboards.
//!
//! Two decisions matter for correctness on any AArch64 machine:
//!
//!   * **DMA memory is mapped non-cacheable.** All rings, contexts and packet
//!     buffers come from one 160 KiB arena whose pages are remapped
//!     `normal_nc`. The kernel identity map is cacheable, so using `.bss`
//!     directly would let the CPU hold DMA writes in a cache the controller
//!     cannot see. Mapping the arena once is cheaper than cache maintenance on
//!     every TRB and works the same on every ARMv8 implementation.
//!   * **Events are consumed by one poller.** The interrupt handler only
//!     acknowledges `USBSTS.EINT`; command completion, transfers and port
//!     changes are pumped from the shell thread. Control transfers wait on the
//!     same pump, so there is no second consumer and no lock ordering between
//!     an interrupt and a transfer in progress.
//!
//! Transfer events are routed by slot and endpoint id; the ring and context
//! arithmetic itself is in `lib/xhci.zig` where it is host-tested.

const std = @import("std");
const driver = @import("../kernel/driver.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const irq = @import("../kernel/irq.zig");
const timer = @import("../arch/aarch64/timer.zig");
const klog = @import("../kernel/klog.zig");
const usb = @import("../lib/usb.zig");
const xhci = @import("../lib/xhci.zig");

pub const Speed = xhci.Speed;

pub const Error = error{
    NoController,
    NoSlot,
    NoEndpoint,
    Timeout,
    Stall,
    Transaction,
    BadState,
    Busy,
    TooLarge,
    Unsupported,
};

pub const vendor_qemu: u16 = 0x1b36;
pub const device_qemu: u16 = 0x000d;
pub const vendor_nec: u16 = 0x1033;
pub const device_nec: u16 = 0x0194;

const max_slots = 8;
const max_eps = 16; // DCI 1..15
const ep_ring_size = 32;
const event_ring_size = 256;
const max_ports = 64;
const buffers_per_ep = 4;
const buffer_size = 64;
const scratch_size = 4096;
const arena_size = 160 * 1024;

/// One DMA arena, page aligned so it can be remapped wholesale. Everything the
/// controller reads or writes points into it.
var dma_arena: [arena_size]u8 align(mmu.page_size) = undefined;
var arena_used: usize = 0;
var arena_mapped = false;

var cmd_trbs: [*]xhci.Trb = undefined;
var cmd_base_phys: u64 = 0;
var ev_trbs: [*]xhci.Trb = undefined;
var ev_base_phys: u64 = 0;
var erst: [*]u8 = undefined;
var erst_phys: u64 = 0;
var dcbaa: [*]u64 = undefined;
var dcbaa_phys: u64 = 0;
var input_ctx: [*][xhci.context_words]u32 = undefined;
var input_phys: u64 = 0;
var contexts: [*]u8 = undefined;
var contexts_phys: u64 = 0;
var ep_rings: [*]u8 = undefined;
var ep_rings_phys: u64 = 0;
var ep_buffers: [*]u8 = undefined;
var ep_buffers_phys: u64 = 0;
var scratch: [*]u8 = undefined;
var scratch_phys: u64 = 0;

const Endpoint = struct {
    present: bool = false,
    dci: u5 = 0,
    ring: xhci.Ring = .{ .size = ep_ring_size },
    trbs: [*]xhci.Trb = undefined,
    base_phys: u64 = 0,
    buffers: [*]u8 = undefined,
    buffers_phys: u64 = 0,
    max_packet: u16 = 0,
    /// Posted interrupt buffers, in completion order.
    queue: [buffers_per_ep]u8 = [_]u8{0} ** buffers_per_ep,
    qhead: usize = 0,
    qtail: usize = 0,
    qcount: usize = 0,
    transfers: u64 = 0,
    errors: u64 = 0,
};

const Slot = struct {
    used: bool = false,
    id: u8 = 0,
    port: u8 = 0,
    root_port: u8 = 0,
    route: u32 = 0,
    depth: u8 = 0,
    speed: xhci.Speed = .unknown,
    hub: bool = false,
    hub_ports: u8 = 0,
    configured: bool = false,
    ep0_ready: bool = false,
    eps: [max_eps]Endpoint = [_]Endpoint{.{}} ** max_eps,
};

pub const ConnectInfo = struct { port: u8, speed: xhci.Speed };
pub const TransferInfo = struct { slot: u8, dci: u5, code: u8, data: []const u8, requested: u16 };
pub const Callbacks = struct {
    connected: *const fn (ConnectInfo) void,
    disconnected: *const fn (slot: u8) void,
    transfer: *const fn (TransferInfo) void,
};

pub const PortChange = struct {
    port: u8 = 0,
    connected: bool = false,
    speed: xhci.Speed = .unknown,
    slot: u8 = 0,
};

pub const Stats = struct {
    commands: u64 = 0,
    command_errors: u64 = 0,
    controls: u64 = 0,
    control_errors: u64 = 0,
    interrupts: u64 = 0,
    interrupt_bytes: u64 = 0,
    port_resets: u64 = 0,
    connects: u64 = 0,
    disconnects: u64 = 0,
    events: u64 = 0,
    irqs: u64 = 0,
    timeouts: u64 = 0,
};

const Port = struct { pending: bool = false, settle_ms: u64 = 0, connected: bool = false };

var present: bool = false;
var bar_phys: u64 = 0;
var bar_size: u64 = 0;
var op_base: usize = 0;
var rt_base: usize = 0;
var db_base: usize = 0;
var cap_length: u8 = 0;
var version: u16 = 0;
var max_slots_hw: u8 = 0;
var max_ports_hw: u8 = 0;
var irq_intid: u32 = 0;
var slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots;
var ports: [max_ports]Port = [_]Port{.{}} ** max_ports;
var cmd_ring: xhci.Ring = .{ .size = 256 };
var ev_ring_state = struct { index: usize = 0, cycle: bool = true }{};
var cmd_expected: u64 = 0;
var cmd_done = false;
var cmd_code: u8 = 0;
var cmd_slot: u8 = 0;
var control_active = false;
var control_done = false;
var control_code: u8 = 0;
var control_slot: u8 = 0;
var control_residual: u32 = 0;
var control_expected: u64 = 0;
var bulk_active = false;
var bulk_done = false;
var bulk_code: u8 = 0;
var bulk_slot: u8 = 0;
var bulk_dci: u5 = 0;
var bulk_residual: u32 = 0;
var bulk_requested: u32 = 0;
var bulk_expected: u64 = 0;
var bulk_in = false;
var callbacks: ?Callbacks = null;

var changes: [32]PortChange = [_]PortChange{.{}} ** 32;
var change_head: usize = 0;
var change_tail: usize = 0;
var change_count: usize = 0;

var stats: Stats = .{};

fn allocArena(bytes: usize, alignment: usize) []u8 {
    arena_used = (arena_used + alignment - 1) & ~(alignment - 1);
    const start = arena_used;
    arena_used += bytes;
    if (arena_used > dma_arena.len) @panic("xhci DMA arena exhausted");
    return dma_arena[start..arena_used];
}

fn arenaPhys(slice: []const u8) u64 {
    return @intFromPtr(slice.ptr);
}

fn zero(slice: []u8) void {
    @memset(slice, 0);
}

fn read32(off: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(op_base + off);
    return p.*;
}

fn write32(off: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(op_base + off);
    p.* = value;
}

fn read64(off: usize) u64 {
    const p: *volatile u64 = @ptrFromInt(op_base + off);
    return p.*;
}

fn readRt32(off: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(rt_base + off);
    return p.*;
}

fn readRt64(off: usize) u64 {
    const p: *volatile u64 = @ptrFromInt(rt_base + off);
    return p.*;
}

fn write64(off: usize, value: u64) void {
    const p: *volatile u64 = @ptrFromInt(op_base + off);
    p.* = value;
}

fn readCap8(off: usize) u8 {
    const p: *volatile u8 = @ptrFromInt(@as(usize, @intCast(bar_phys)) + off);
    return p.*;
}

fn readCap16(off: usize) u16 {
    const p: *volatile u16 = @ptrFromInt(@as(usize, @intCast(bar_phys)) + off);
    return p.*;
}

fn readCap32(off: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(@as(usize, @intCast(bar_phys)) + off);
    return p.*;
}

fn nowMs() u64 {
    return timer.uptimeMs();
}

fn delayUs(us: u64) void {
    const hz = cpu.cntFrq();
    if (hz == 0) return;
    const ticks = us * hz / 1_000_000 + 1;
    const start = cpu.cntPct();
    while (cpu.cntPct() - start < ticks) cpu.nop();
}

fn ringDoorbell(slot: u8, target: u8) void {
    const p: *volatile u32 = @ptrFromInt(db_base + @as(u64, slot) * 4);
    p.* = target;
}

fn portsc(p: u8) u32 {
    const ptr: *volatile u32 = @ptrFromInt(op_base + xhci.op_portbase + (@as(u64, p) - 1) * xhci.op_portstride);
    return ptr.*;
}

fn writePortsc(p: u8, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(op_base + xhci.op_portbase + (@as(u64, p) - 1) * xhci.op_portstride);
    ptr.* = value;
}

fn slotPtr(id: u8) ?*Slot {
    if (id == 0 or id > max_slots) return null;
    const s = &slots[id - 1];
    if (!s.used) return null;
    return s;
}

fn slotByPort(port: u8) ?*Slot {
    for (&slots) |*s| {
        if (s.used and s.root_port == port) return s;
    }
    return null;
}

fn endpointRingBase(slot_index: usize, ep_index: usize) []u8 {
    const stride = ep_ring_size * @sizeOf(xhci.Trb);
    const off = (slot_index * max_eps + ep_index) * stride;
    return ep_rings[off .. off + stride];
}

fn endpointBufferBase(slot_index: usize, ep_index: usize) []u8 {
    const stride = buffers_per_ep * buffer_size;
    const off = (slot_index * max_eps + ep_index) * stride;
    return ep_buffers[off .. off + stride];
}

fn initEndpoint(slot_index: usize, ep_index: usize) void {
    const s = &slots[slot_index];
    const ep = &s.eps[ep_index];
    const ring_slice = endpointRingBase(slot_index, ep_index);
    zero(ring_slice);
    ep.trbs = @ptrCast(@alignCast(ring_slice.ptr));
    ep.base_phys = arenaPhys(ring_slice);
    ep.ring = .{ .size = ep_ring_size };
    ep.trbs[ep_ring_size - 1] = xhci.linkTrb(ep.base_phys, true);

    const buf_slice = endpointBufferBase(slot_index, ep_index);
    zero(buf_slice);
    ep.buffers = buf_slice.ptr;
    ep.buffers_phys = arenaPhys(buf_slice);
    ep.qhead = 0;
    ep.qtail = 0;
    ep.qcount = 0;
}

fn initSlotMemory(index: usize) void {
    slots[index] = .{};
    var i: usize = 0;
    while (i < max_eps) : (i += 1) initEndpoint(index, i);
    slots[index].eps[0].present = false;
}

fn slotContextPointer(id: u8) [*][xhci.context_words]u32 {
    const off = @as(usize, id - 1) * 1024;
    return @ptrCast(@alignCast(contexts + off));
}

fn resetSlotContext(id: u8) void {
    const off = @as(usize, id - 1) * 1024;
    zero(contexts[off..][0..1024]);
}

fn command(trb: xhci.Trb) Error!u8 {
    if (!present) return Error.NoController;
    const entry = cmd_ring.take();
    var t = trb;
    if (entry.cycle) t.control |= 1 else t.control &= ~@as(u32, 1);
    cmd_trbs[entry.index] = t;
    if (entry.wrapped) cmd_trbs[cmd_ring.linkIndex()] = xhci.linkTrb(cmd_base_phys, entry.cycle);
    cmd_expected = cmd_base_phys + @as(u64, entry.index) * xhci.trb_size;
    cmd_done = false;
    cmd_code = 0;
    cmd_slot = 0;
    stats.commands += 1;
    cpu.dsbSy();
    ringDoorbell(0, 0);

    const deadline = nowMs() + 1000;
    while (!cmd_done) {
        pump();
        if (nowMs() > deadline) {
            stats.timeouts += 1;
            return Error.Timeout;
        }
        cpu.nop();
    }
    if (cmd_code != xhci.completion_success) {
        stats.command_errors += 1;
        return mapCompletion(cmd_code);
    }
    return cmd_slot;
}

fn mapCompletion(code: u8) Error {
    return switch (code) {
        1, 13 => Error.BadState, // success is handled before this
        6 => Error.Stall,
        4, 5, 7, 8, 9, 10, 11, 12 => Error.Transaction,
        else => Error.Transaction,
    };
}

fn mapTransfer(code: u8) Error!void {
    switch (code) {
        xhci.completion_success, xhci.completion_short_packet => {},
        6 => return Error.Stall,
        else => return Error.Transaction,
    }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

fn pump() void {
    if (!present) return;
    var guard: usize = 0;
    while (guard < event_ring_size) : (guard += 1) {
        const trb = ev_trbs[ev_ring_state.index];
        const cycle = trb.control & 1 != 0;
        if (cycle != ev_ring_state.cycle) break;
        stats.events += 1;
        handleEvent(trb);
        ev_ring_state.index = (ev_ring_state.index + 1) % event_ring_size;
        if (ev_ring_state.index == 0) ev_ring_state.cycle = !ev_ring_state.cycle;
        // ERDP points at the next event; EHB acknowledges the interrupt.
        const erdp: *volatile u64 = @ptrFromInt(rt_base + xhci.rt_erdp);
        erdp.* = (ev_base_phys + @as(u64, ev_ring_state.index) * xhci.trb_size) | 0x8;
    }
}

fn handleEvent(trb: xhci.Trb) void {
    switch (trb.trbType()) {
        xhci.ev_command_completion => {
            if (cmd_done) return;
            if (trb.parameter == cmd_expected) {
                cmd_done = true;
                cmd_code = trb.completionCode();
                cmd_slot = trb.slotId();
            }
        },
        xhci.ev_transfer => {
            const slot = trb.slotId();
            const dci = trb.endpointId();
            const code = trb.completionCode();
            const residual = trb.transferLength();
            if (dci == 1 and control_active and slot == control_slot) {
                control_done = true;
                control_code = code;
                control_residual = residual;
                return;
            }
            if (bulk_active and slot == bulk_slot and dci == bulk_dci) {
                bulk_done = true;
                bulk_code = code;
                bulk_residual = residual;
                return;
            }
            if (slot == 0 or slot > max_slots) return;
            const s = &slots[slot - 1];
            if (!s.used or dci == 0 or dci >= max_eps) return;
            const ep = &s.eps[dci - 1];
            if (!ep.present) return;
            const requested: u32 = ep.max_packet;
            const actual: u32 = if (residual >= requested) 0 else requested - residual;
            ep.transfers += 1;
            if (code != xhci.completion_success and code != xhci.completion_short_packet) {
                ep.errors += 1;
                return;
            }
            if (ep.qcount == 0) return;
            const index = ep.queue[ep.qhead];
            ep.qhead = (ep.qhead + 1) % buffers_per_ep;
            ep.qcount -= 1;
            stats.interrupts += 1;
            stats.interrupt_bytes += actual;
            if (callbacks) |cb| {
                const data = ep.buffers[@as(usize, index) * buffer_size ..][0..actual];
                cb.transfer(.{ .slot = slot, .dci = dci, .code = code, .data = data, .requested = @intCast(requested) });
            }
            // Re-arm the same buffer immediately: a HID device that reports once
            // and then goes quiet must stay armed for the next key.
            postInterruptTrb(ep, index);
        },
        xhci.ev_port_status_change => {
            // PORTSC is the authoritative state; the event only tells us to look.
            // Polling is done separately so a burst of events cannot recurse into
            // enumeration.
        },
        else => {},
    }
}

fn postInterruptTrb(ep: *Endpoint, index: u8) void {
    const addr = ep.buffers_phys + @as(u64, index) * buffer_size;
    const entry = ep.ring.take();
    var trb = xhci.normalTrb(addr, ep.max_packet, false);
    if (entry.cycle) trb.control |= 1 else trb.control &= ~@as(u32, 1);
    ep.trbs[entry.index] = trb;
    // The link TRB belongs to the cycle being closed, not the new one: the
    // controller matches it with its current CCS and toggles after following.
    if (entry.wrapped) ep.trbs[ep.ring.linkIndex()] = xhci.linkTrb(ep.base_phys, entry.cycle);
    ep.queue[ep.qtail] = index;
    ep.qtail = (ep.qtail + 1) % buffers_per_ep;
    if (ep.qcount < buffers_per_ep) ep.qcount += 1;
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

fn resetPort(port: u8) ?xhci.Speed {
    var v = portsc(port);
    if (v & xhci.portsc_ccs == 0) return null;
    // Power the port if the controller exposes power control and it is off.
    if (v & xhci.portsc_pp == 0) {
        writePortsc(port, (v & ~xhci.portsc_changes) | xhci.portsc_pp);
        delayUs(20_000);
        v = portsc(port);
    }
    // Keep power and speed, drop stale change bits, then assert reset. Writing a
    // one to a change bit clears it; PR must not be left set from the read.
    var request = (v & ~(xhci.portsc_changes | xhci.portsc_pr)) | xhci.portsc_pp;
    request |= xhci.portsc_pr;
    writePortsc(port, request);
    stats.port_resets += 1;

    const deadline = nowMs() + 1000;
    while (nowMs() < deadline) {
        const s = portsc(port);
        if (s & xhci.portsc_prc != 0) {
            writePortsc(port, (s & ~xhci.portsc_pr) | xhci.portsc_prc | xhci.portsc_csc | xhci.portsc_pec);
            const state = xhci.parsePortSc(s);
            return if (state.speed == .unknown) .high else state.speed;
        }
        if (s & xhci.portsc_pr == 0 and s & xhci.portsc_ped != 0) {
            return xhci.parsePortSc(s).speed;
        }
        delayUs(1_000);
    }
    stats.timeouts += 1;
    return null;
}

fn pollPorts() void {
    if (!present) return;
    const now = nowMs();
    var p: u8 = 1;
    while (p <= max_ports_hw and p <= max_ports) : (p += 1) {
        const v = portsc(p);
        if (v == 0xFFFF_FFFF) continue;
        if (v & xhci.portsc_changes != 0) {
            if (v & xhci.portsc_csc != 0) {
                if (v & xhci.portsc_ccs != 0) {
                    ports[p - 1].pending = true;
                    ports[p - 1].settle_ms = now + 100;
                    klog.info("usb", "port {d}: device connected, settling", .{p});
                } else if (ports[p - 1].connected) {
                    ports[p - 1].connected = false;
                    stats.disconnects += 1;
                    const slot = slotByPort(p);
                    pushChange(.{ .port = p, .connected = false, .slot = if (slot) |s| s.id else 0 });
                    klog.info("usb", "port {d}: device removed", .{p});
                }
            }
            // Clear every change bit except a reset still in progress. Do not
            // write PR back: that would start another reset.
            var clear = (v & ~xhci.portsc_pr) | xhci.portsc_changes;
            if (v & xhci.portsc_pr != 0) clear &= ~xhci.portsc_prc;
            writePortsc(p, clear);
        }
        if (ports[p - 1].pending and now >= ports[p - 1].settle_ms) {
            ports[p - 1].pending = false;
            if (resetPort(p)) |speed| {
                ports[p - 1].connected = true;
                stats.connects += 1;
                pushChange(.{ .port = p, .connected = true, .speed = speed });
                klog.info("usb", "port {d}: reset complete, {s}-speed", .{ p, @tagName(speed) });
            } else {
                klog.warn("usb", "port {d}: reset did not complete", .{p});
            }
        }
    }
}

fn pushChange(c: PortChange) void {
    if (change_count == changes.len) {
        // A full queue would lose a removal; drop the oldest connect instead.
        change_head = (change_head + 1) % changes.len;
        change_count -= 1;
    }
    changes[change_tail] = c;
    change_tail = (change_tail + 1) % changes.len;
    change_count += 1;
}

pub fn takePortChange() ?PortChange {
    if (change_count == 0) return null;
    const c = changes[change_head];
    change_head = (change_head + 1) % changes.len;
    change_count -= 1;
    return c;
}

pub fn portCount() u8 {
    return max_ports_hw;
}

pub fn portState(port: u8) xhci.PortState {
    if (!present or port == 0 or port > max_ports_hw) return .{};
    return xhci.parsePortSc(portsc(port));
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

pub fn presentController() bool {
    return present;
}

pub fn setCallbacks(cb: Callbacks) void {
    callbacks = cb;
}

pub fn info() struct { present: bool, version: u16, ports: u8, slots: u8, bar: u64, size: u64, irq: u32, stats: Stats } {
    return .{
        .present = present,
        .version = version,
        .ports = max_ports_hw,
        .slots = max_slots_hw,
        .bar = bar_phys,
        .size = bar_size,
        .irq = irq_intid,
        .stats = stats,
    };
}

fn controllerIrq(_: u32) void {
    const sts = read32(xhci.op_usbsts);
    if (sts & xhci.sts_eint != 0) {
        write32(xhci.op_usbsts, xhci.sts_eint);
        stats.irqs += 1;
    }
}

fn waitStatus(mask: u32, set: bool, timeout_ms: u64) bool {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const sts = read32(xhci.op_usbsts);
        if ((sts & mask != 0) == set) return true;
        delayUs(100);
    }
    return false;
}

pub fn probe(dev: *driver.Device) driver.ProbeError!void {
    init(dev) catch |err| {
        klog.warn("usb", "xHCI at {s} did not start: {s}", .{ dev.name, @errorName(err) });
        return switch (err) {
            error.NoController, error.Unsupported => error.Unsupported,
            error.NoSlot => error.NoMemory,
            else => error.Unsupported,
        };
    };
}

fn init(dev: *driver.Device) Error!void {
    if (dev.reg_count == 0) return Error.NoController;
    bar_phys = dev.regs[0].base;
    bar_size = dev.regs[0].size;
    if (bar_phys == 0 or bar_size < 0x100) return Error.NoController;

    // The BAR may sit above the identity-mapped RAM window on a non-QEMU
    // machine; map it as Device memory explicitly either way.
    const page = mmu.page_size;
    const map_size = @as(usize, @intCast((bar_size + page - 1) & ~(page - 1)));
    mmu.mapRegion(.{ .base = @intCast(bar_phys), .size = map_size, .kind = .device });
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();

    const magic = readCap32(xhci.cap_hcsparams1);
    const cap_len = readCap8(xhci.cap_caplength);
    if (cap_len < 0x40 or cap_len > 0x100) return Error.Unsupported;
    cap_length = cap_len;
    version = @truncate(readCap32(0) >> 16);
    max_slots_hw = @truncate(magic & 0xFF);
    max_ports_hw = @truncate((magic >> 24) & 0xFF);
    if (max_slots_hw == 0 or max_ports_hw == 0) return Error.Unsupported;

    const dboff = readCap32(xhci.cap_dboff) & ~@as(u32, 3);
    const rtsoff = readCap32(xhci.cap_rtsoff) & ~@as(u32, 3);
    if (dboff == 0 or rtsoff == 0) return Error.Unsupported;
    op_base = @intCast(bar_phys + cap_len);
    // The runtime block begins with MFINDEX (0x00..0x1F); interrupter 0 starts at +0x20.
    rt_base = @intCast(bar_phys + rtsoff + 0x20);
    db_base = @intCast(bar_phys + dboff);

    if (!arena_mapped) {
        mmu.mapRegion(.{ .base = @intFromPtr(&dma_arena), .size = dma_arena.len, .kind = .normal_nc });
        cpu.tlbiVmalle1();
        cpu.dsbSy();
        cpu.isb();
        arena_mapped = true;
    }

    // Carve the controller-visible arena. Alignment matters: rings and contexts
    // are 64-byte aligned by contract. Every allocation is zeroed as it is taken,
    // so the arena starts from a known state without a second pass that would
    // also wipe the link TRBs written below.
    arena_used = 0;
    var slice = allocArena(event_ring_size * xhci.trb_size, 64);
    zero(slice);
    ev_trbs = @ptrCast(@alignCast(slice.ptr));
    ev_base_phys = arenaPhys(slice);

    slice = allocArena(xhci.trb_size * 2, 64); // one ERST entry, padded
    zero(slice);
    erst = slice.ptr;
    erst_phys = arenaPhys(slice);

    slice = allocArena(64 * 8, 64);
    zero(slice);
    dcbaa = @ptrCast(@alignCast(slice.ptr));
    dcbaa_phys = arenaPhys(slice);

    slice = allocArena(xhci.max_input_contexts * 32, 64);
    zero(slice);
    input_ctx = @ptrCast(@alignCast(slice.ptr));
    input_phys = arenaPhys(slice);

    slice = allocArena(max_slots * 1024, 64);
    zero(slice);
    contexts = slice.ptr;
    contexts_phys = arenaPhys(slice);

    slice = allocArena(max_slots * max_eps * ep_ring_size * xhci.trb_size, 64);
    zero(slice);
    ep_rings = slice.ptr;
    ep_rings_phys = arenaPhys(slice);

    slice = allocArena(max_slots * max_eps * buffers_per_ep * buffer_size, 64);
    zero(slice);
    ep_buffers = slice.ptr;
    ep_buffers_phys = arenaPhys(slice);

    slice = allocArena(scratch_size, 64);
    zero(slice);
    scratch = slice.ptr;
    scratch_phys = arenaPhys(slice);

    // Command ring: link TRB at the end points back to itself.
    slice = allocArena(256 * xhci.trb_size, 64);
    zero(slice);
    cmd_trbs = @ptrCast(@alignCast(slice.ptr));
    cmd_base_phys = arenaPhys(slice);
    cmd_ring = .{ .size = 256 };
    cmd_trbs[255] = xhci.linkTrb(cmd_base_phys, true);

    // ---- reset -------------------------------------------------------------
    present = true;
    var cmd = read32(xhci.op_usbcmd);
    cmd &= ~xhci.cmd_rs;
    write32(xhci.op_usbcmd, cmd);
    _ = waitStatus(xhci.sts_hch, true, 100);

    write32(xhci.op_usbcmd, cmd | xhci.cmd_hcreset);
    delayUs(1_000);
    if (!waitStatus(xhci.sts_cnr, false, 500)) return Error.Timeout;
    _ = waitStatus(xhci.sts_hch, true, 500);
    // After a reset the controller clears RS, INTE and the interrupter state.
    write32(xhci.op_usbcmd, 0);

    // ---- program rings -----------------------------------------------------
    // Clear stale error/change bits before starting. HCE in particular means
    // the controller has ceased activity; clearing it without a reset does not
    // recover, but a stale bit must not be mistaken for a new failure.
    write32(xhci.op_usbsts, 0xFFFF_FFFF);
    write32(xhci.op_config, @min(max_slots_hw, max_slots));
    write64(xhci.op_dcbaap, dcbaa_phys);
    write64(xhci.op_crcr, cmd_base_phys | 1);

    const entry: *xhci.ErstEntry = @ptrCast(@alignCast(erst));
    entry.* = .{ .base = ev_base_phys, .size = event_ring_size };
    const erstsz: *volatile u32 = @ptrFromInt(rt_base + xhci.rt_erstsz);
    erstsz.* = 1;
    const erstba: *volatile u64 = @ptrFromInt(rt_base + xhci.rt_erstba);
    erstba.* = erst_phys;
    const erdp: *volatile u64 = @ptrFromInt(rt_base + xhci.rt_erdp);
    erdp.* = ev_base_phys;
    const iman: *volatile u32 = @ptrFromInt(rt_base + xhci.rt_iman);
    iman.* = 2; // interrupt enable
    const imod: *volatile u32 = @ptrFromInt(rt_base + xhci.rt_imod);
    imod.* = 0;

    // ---- run ---------------------------------------------------------------
    cpu.dsbSy();
    write32(xhci.op_usbcmd, xhci.cmd_rs | xhci.cmd_inte);
    if (!waitStatus(xhci.sts_cnr, false, 500)) return Error.Timeout;
    if (!waitStatus(xhci.sts_hch, false, 500)) return Error.Timeout;
    const started_sts = read32(xhci.op_usbsts);
    if (started_sts & xhci.sts_hce != 0) {
        klog.err("usb", "xHCI asserted HCE during start (USBSTS 0x{x})", .{started_sts});
        return Error.Unsupported;
    }

    // ---- ports -------------------------------------------------------------
    var p: u8 = 1;
    while (p <= max_ports_hw and p <= max_ports) : (p += 1) {
        const v = portsc(p);
        if (v == 0xFFFF_FFFF) continue;
        if (v & xhci.portsc_pp == 0) {
            writePortsc(p, (v & ~xhci.portsc_changes & ~xhci.portsc_pr) | xhci.portsc_pp);
            delayUs(20_000);
        }
        const after = portsc(p);
        const state = xhci.parsePortSc(after);
        ports[p - 1].connected = state.connected;
        if (state.connected) {
            // A device already present at boot gets the same debounce + reset as
            // a hotplugged one.
            ports[p - 1].pending = true;
            ports[p - 1].settle_ms = nowMs() + 100;
        }
        writePortsc(p, (after & ~xhci.portsc_pr) | xhci.portsc_changes);
    }

    // ---- interrupts --------------------------------------------------------
    if (dev.pci.intx_routed and dev.pci.intx_spi != 0) {
        irq_intid = dev.pci.intx_spi;
    } else if (dev.pci.msi_on and dev.pci.msi_vector != 0) {
        irq_intid = dev.pci.msi_vector;
    }
    if (irq_intid != 0) irq.register(irq_intid, controllerIrq);

    klog.info("usb", "xHCI {d}.{d} at 0x{x}+0x{x}: {d} ports, {d} slots, irq {s}{d}", .{
        version >> 8,                                                                         version & 0xFF, bar_phys, bar_size, max_ports_hw, max_slots_hw,
        if (dev.pci.intx_routed) "SPI " else if (dev.pci.msi_on) "MSI " else "none (polled)", irq_intid,
    });
}

// ---------------------------------------------------------------------------
// Slots and transfers
// ---------------------------------------------------------------------------

pub fn enableSlot() Error!u8 {
    const slot = try command(xhci.enableSlotTrb(false));
    if (slot == 0 or slot > max_slots) return Error.NoSlot;
    const index = slot - 1;
    if (slots[index].used) return Error.NoSlot;
    initSlotMemory(index);
    resetSlotContext(slot);
    dcbaa[slot] = @intFromPtr(slotContextPointer(slot));
    slots[index].used = true;
    slots[index].id = slot;
    cpu.dsbSy();
    return slot;
}

pub const AddressConfig = struct {
    route: u32 = 0,
    root_port: u8 = 1,
    speed: xhci.Speed,
    hub: bool = false,
    hub_ports: u8 = 0,
    depth: u8 = 0,
};

pub fn addressDevice(slot: u8, cfg: AddressConfig) Error!void {
    const s = slotPtr(slot) orelse return Error.NoSlot;
    s.root_port = cfg.root_port;
    s.route = cfg.route;
    s.speed = cfg.speed;
    s.hub = cfg.hub;
    s.hub_ports = cfg.hub_ports;
    s.depth = cfg.depth;

    var ictx = xhci.InputContext{};
    ictx.control.add = xhci.InputControl.add_slot | xhci.InputControl.add_ep0;
    ictx.slot = .{
        .route = cfg.route,
        .speed = @intFromEnum(cfg.speed),
        .hub = cfg.hub,
        .hub_ports = cfg.hub_ports,
        .root_port = cfg.root_port,
        .context_entries = 1,
        .state = .default_state,
    };
    ictx.endpoints[1] = .{
        .endpoint_type = .control,
        .max_packet = xhci.speedMaxPacket(cfg.speed),
        .dequeue = s.eps[0].base_phys,
        .dcs = true,
        .interval = 0,
        .avg_trb_length = 8,
    };
    ictx.write(@ptrCast(input_ctx));
    cpu.dsbSy();

    const result = command(xhci.commandTrb(xhci.trb_address_device, input_phys, slot, false)) catch |err| {
        slots[slot - 1].used = false;
        return err;
    };
    if (result != slot) {
        slots[slot - 1].used = false;
        return Error.NoSlot;
    }
    s.ep0_ready = true;
    s.eps[0].present = true;
    s.eps[0].dci = 1;
    s.eps[0].max_packet = xhci.speedMaxPacket(cfg.speed);
}

pub const EndpointSpec = struct {
    dci: u5,
    kind: usb.TransferKind,
    max_packet: u16,
    interval: u8,
    in: bool,
};

pub fn configure(slot: u8, specs: []const EndpointSpec) Error!void {
    const s = slotPtr(slot) orelse return Error.NoSlot;
    var ictx = xhci.InputContext{};
    ictx.control.add = xhci.InputControl.add_slot;
    var highest: u5 = 1;
    for (specs) |spec| {
        if (spec.dci == 0 or spec.dci >= max_eps) return Error.NoEndpoint;
        ictx.control.addEndpoint(spec.dci);
        const ep = &s.eps[spec.dci - 1];
        if (!ep.present) {
            initEndpoint(slot - 1, spec.dci - 1);
        }
        ep.present = true;
        ep.dci = spec.dci;
        ep.max_packet = spec.max_packet;
        if (spec.dci > highest) highest = spec.dci;
        ictx.endpoints[spec.dci] = .{
            .endpoint_type = xhci.endpointTypeFor(spec.kind, spec.in),
            .max_packet = spec.max_packet,
            .interval = if (spec.interval > 0) spec.interval - 1 else 0,
            .dequeue = ep.base_phys,
            .dcs = true,
            .avg_trb_length = @intCast(@min(spec.max_packet, 1024)),
        };
    }
    ictx.slot = .{
        .route = s.route,
        .speed = @intFromEnum(s.speed),
        .hub = s.hub,
        .hub_ports = s.hub_ports,
        .root_port = s.root_port,
        .context_entries = highest + 1,
        .state = .configured,
    };
    ictx.write(@ptrCast(input_ctx));
    cpu.dsbSy();
    _ = try command(xhci.commandTrb(xhci.trb_configure_endpoint, input_phys, slot, false));
    s.configured = true;
}

pub fn disableSlot(slot: u8) void {
    if (slot == 0 or slot > max_slots) return;
    if (slots[slot - 1].used) {
        _ = command(xhci.commandTrb(xhci.trb_disable_slot, 0, slot, false)) catch {};
    }
    slots[slot - 1] = .{};
    dcbaa[slot] = 0;
    cpu.dsbSy();
}

/// Issue a control transfer. The data buffer is ordinary kernel memory; the
/// controller sees the non-cacheable scratch copy.
pub fn control(slot: u8, setup: usb.Setup, buffer: []u8) Error!usize {
    const s = slotPtr(slot) orelse return Error.NoSlot;
    if (!s.ep0_ready) return Error.BadState;
    if (control_active) return Error.Busy;
    const len: usize = setup.length;
    if (len > scratch_size) return Error.TooLarge;
    const in = setup.request_type & usb.direction_in != 0;
    if (!in and len > 0) {
        if (buffer.len < len) return Error.TooLarge;
        @memcpy(scratch[0..len], buffer[0..len]);
    }
    control_active = true;
    control_slot = slot;
    control_done = false;
    control_code = 0;
    control_residual = 0;
    stats.controls += 1;

    var packet: [8]u8 = setup.bytes();
    const packet64 = std.mem.readInt(u64, &packet, .little);
    const trt: xhci.Trt = if (len == 0) .none else if (in) .in else .out;
    _ = enqueue(&s.eps[0], xhci.setupTrb(packet64, trt, false));
    if (len > 0) _ = enqueue(&s.eps[0], xhci.dataTrb(scratch_phys, @intCast(len), in, false));
    const status_in = len == 0 or !in;
    const status_addr = enqueue(&s.eps[0], xhci.statusTrb(status_in, false));
    control_expected = status_addr;
    cpu.dsbSy();
    ringDoorbell(slot, 1);

    const deadline = nowMs() + 1000;
    while (!control_done) {
        pump();
        if (nowMs() > deadline) {
            control_active = false;
            stats.timeouts += 1;
            stats.control_errors += 1;
            return Error.Timeout;
        }
        cpu.nop();
    }
    control_active = false;
    const code = control_code;
    const residual = control_residual;
    mapTransfer(code) catch |err| {
        stats.control_errors += 1;
        return err;
    };
    const actual: usize = if (len == 0) 0 else if (residual >= len) 0 else len - residual;
    if (in and actual > 0 and buffer.len >= actual) {
        @memcpy(buffer[0..actual], scratch[0..actual]);
    }
    return actual;
}

fn enqueue(ep: *Endpoint, trb: xhci.Trb) u64 {
    const entry = ep.ring.take();
    var t = trb;
    if (entry.cycle) t.control |= 1 else t.control &= ~@as(u32, 1);
    ep.trbs[entry.index] = t;
    // The link TRB belongs to the cycle being closed, not the new one: the
    // controller matches it with its current CCS and toggles after following.
    if (entry.wrapped) ep.trbs[ep.ring.linkIndex()] = xhci.linkTrb(ep.base_phys, entry.cycle);
    return ep.base_phys + @as(u64, entry.index) * xhci.trb_size;
}

pub fn submitInterrupt(slot: u8, dci: u5) Error!void {
    const s = slotPtr(slot) orelse return Error.NoSlot;
    if (dci == 0 or dci >= max_eps) return Error.NoEndpoint;
    const ep = &s.eps[dci - 1];
    if (!ep.present or ep.max_packet == 0) return Error.NoEndpoint;
    if (ep.qcount >= buffers_per_ep) return;
    while (ep.qcount < buffers_per_ep) {
        postInterruptTrb(ep, @intCast(ep.qtail));
    }
    cpu.dsbSy();
    ringDoorbell(slot, dci);
}

/// Synchronous bulk transfer, used by the serial class drivers.
pub fn bulkTransfer(slot: u8, dci: u5, buffer: []u8, in: bool) Error!usize {
    return bulkTransferTimeout(slot, dci, buffer, in, 1000);
}

pub fn bulkTransferTimeout(slot: u8, dci: u5, buffer: []u8, in: bool, timeout_ms: u64) Error!usize {
    const s = slotPtr(slot) orelse return Error.NoSlot;
    if (dci == 0 or dci >= max_eps) return Error.NoEndpoint;
    const ep = &s.eps[dci - 1];
    if (!ep.present) return Error.NoEndpoint;
    if (bulk_active) return Error.Busy;
    const len = buffer.len;
    if (len == 0 or len > scratch_size) return Error.TooLarge;
    if (!in) @memcpy(scratch[0..len], buffer[0..len]);

    bulk_active = true;
    bulk_slot = slot;
    bulk_dci = dci;
    bulk_done = false;
    bulk_code = 0;
    bulk_residual = 0;
    bulk_requested = @intCast(len);
    bulk_in = in;
    const trb = xhci.normalTrb(scratch_phys, @intCast(len), false);
    bulk_expected = enqueue(ep, trb);
    cpu.dsbSy();
    ringDoorbell(slot, dci);

    const deadline = nowMs() + timeout_ms;
    while (!bulk_done) {
        pump();
        if (nowMs() > deadline) {
            bulk_active = false;
            stats.timeouts += 1;
            return Error.Timeout;
        }
        cpu.nop();
    }
    bulk_active = false;
    mapTransfer(bulk_code) catch return Error.Transaction;
    const actual: usize = if (bulk_residual >= len) 0 else len - bulk_residual;
    if (in and actual > 0 and buffer.len >= actual) @memcpy(buffer[0..actual], scratch[0..actual]);
    return actual;
}

/// Pump events and port state; called by the USB core from the shell loop.
pub fn poll() void {
    if (!present) return;
    pump();
    pollPorts();
    const sts = read32(xhci.op_usbsts);
    if (sts & xhci.sts_eint != 0) write32(xhci.op_usbsts, xhci.sts_eint);
}

pub fn slotSnapshot(index: usize) ?struct { id: u8, port: u8, route: u32, speed: xhci.Speed, hub: bool, configured: bool } {
    if (index >= max_slots or !slots[index].used) return null;
    return .{
        .id = slots[index].id,
        .port = slots[index].root_port,
        .route = slots[index].route,
        .speed = slots[index].speed,
        .hub = slots[index].hub,
        .configured = slots[index].configured,
    };
}

pub fn describe(write: anytype) void {
    const inf = info();
    if (!inf.present) {
        write("  usb          : xHCI not present\n", .{});
        return;
    }
    write("  usb          : xHCI {d}.{d}, {d} ports, {d} slots, BAR 0x{x}+0x{x}\n", .{
        inf.version >> 8, inf.version & 0xFF, inf.ports, inf.slots, inf.bar, inf.size,
    });
    write("  usb caps     : raw0 0x{x} raw4 0x{x} raw8 0x{x} hcc 0x{x} dboff 0x{x} rtsoff 0x{x} caplen 0x{x}\n", .{
        readCap32(0), readCap32(4), readCap32(8), readCap32(0x10), readCap32(0x14), readCap32(0x18), cap_length,
    });
    write("  usb regs     : cmd 0x{x} sts 0x{x} crcr 0x{x} dcbaap 0x{x} config 0x{x}\n", .{
        read32(xhci.op_usbcmd), read32(xhci.op_usbsts), read64(xhci.op_crcr), read64(xhci.op_dcbaap), read32(xhci.op_config),
    });
    const seg: *xhci.ErstEntry = @ptrCast(@alignCast(erst));
    write("  usb erst     : sz {d} ba 0x{x} base 0x{x} size {d} erdp 0x{x} iman 0x{x}\n", .{
        readRt32(xhci.rt_erstsz), readRt64(xhci.rt_erstba), seg.base, seg.size, readRt64(xhci.rt_erdp), readRt32(xhci.rt_iman),
    });
    write("  usb rings    : cmd 0x{x} ev 0x{x} dcbaa 0x{x} input 0x{x} ctx 0x{x}\n", .{
        cmd_base_phys, ev_base_phys, dcbaa_phys, input_phys, contexts_phys,
    });
    write("  usb irq      : {d} ({d} interrupts), {d} events, {d} commands ({d} errors)\n", .{
        inf.irq, inf.stats.irqs, inf.stats.events, inf.stats.commands, inf.stats.command_errors,
    });
    write("  usb xfers    : {d} control ({d} errors), {d} HID reports, {d} bytes\n", .{
        inf.stats.controls, inf.stats.control_errors, inf.stats.interrupts, inf.stats.interrupt_bytes,
    });
    write("  usb ports    : {d} reset(s), {d} connect(s), {d} disconnect(s), {d} timeout(s)\n", .{
        inf.stats.port_resets, inf.stats.connects, inf.stats.disconnects, inf.stats.timeouts,
    });
    var p: u8 = 1;
    while (p <= max_ports_hw and p <= max_ports) : (p += 1) {
        const state = portState(p);
        if (!state.connected) continue;
        const slot = slotByPort(p);
        write("  usb port {d}   : {s}-speed, slot {d}, {s}\n", .{
            p, @tagName(state.speed), if (slot) |s| s.id else 0, if (slot) |s| if (s.configured) "configured" else "addressed" else "enumerating",
        });
    }
}
