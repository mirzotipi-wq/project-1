//! xHCI data structures and ring arithmetic (phase 39).
//!
//! The controller is programmed through 16-byte transfer request blocks, four
//! kinds of rings and a context table whose fields are packed into 32-bit words.
//! Every one of those layouts is defined here as pure data: the hardware driver
//! only maps registers, copies these words and rings doorbells, and the host
//! tests can therefore check the parts that are easy to get subtly wrong — the
//! cycle bit, the link TRB, endpoint context IDs, the address-device input
//! context — without a controller.
//!
//! Reference: xHCI 1.1, chapters 4 (data structures), 5 (operational model) and
//! 6 (commands and events).

const std = @import("std");

// ---------------------------------------------------------------------------
// Register offsets
// ---------------------------------------------------------------------------

pub const cap_caplength: usize = 0x00;
pub const cap_hciversion: usize = 0x02;
pub const cap_hcsparams1: usize = 0x04;
pub const cap_hcsparams2: usize = 0x08;
pub const cap_hccparams1: usize = 0x10;
pub const cap_dboff: usize = 0x14;
pub const cap_rtsoff: usize = 0x18;

pub const op_usbcmd: usize = 0x00;
pub const op_usbsts: usize = 0x04;
pub const op_pagesize: usize = 0x08;
pub const op_dnctrl: usize = 0x14;
pub const op_crcr: usize = 0x18;
pub const op_dcbaap: usize = 0x30;
pub const op_config: usize = 0x38;
pub const op_portbase: usize = 0x400;
pub const op_portstride: usize = 0x10;

pub const rt_iman: usize = 0x00;
pub const rt_imod: usize = 0x04;
pub const rt_erstsz: usize = 0x08;
pub const rt_erstba: usize = 0x10;
pub const rt_erdp: usize = 0x18;
pub const rt_interrupter_stride: usize = 0x20;

pub const cmd_rs: u32 = 1 << 0;
pub const cmd_hcreset: u32 = 1 << 1;
pub const cmd_inte: u32 = 1 << 2;
pub const cmd_ewbe: u32 = 1 << 11;

pub const sts_hch: u32 = 1 << 0;
pub const sts_eint: u32 = 1 << 3;
pub const sts_pcd: u32 = 1 << 4;
pub const sts_cnr: u32 = 1 << 11;
pub const sts_hce: u32 = 1 << 12;
pub const sts_hse: u32 = 1 << 2;

pub const portsc_ccs: u32 = 1 << 0;
pub const portsc_ped: u32 = 1 << 1;
pub const portsc_oca: u32 = 1 << 3;
pub const portsc_pr: u32 = 1 << 4;
pub const portsc_pls_shift: u5 = 5;
pub const portsc_pp: u32 = 1 << 9;
pub const portsc_speed_shift: u5 = 10;
pub const portsc_lws: u32 = 1 << 16;
pub const portsc_csc: u32 = 1 << 17;
pub const portsc_pec: u32 = 1 << 18;
pub const portsc_wrc: u32 = 1 << 19;
pub const portsc_occ: u32 = 1 << 20;
pub const portsc_prc: u32 = 1 << 21;
pub const portsc_plc: u32 = 1 << 22;
pub const portsc_cec: u32 = 1 << 23;
pub const portsc_wce: u32 = 1 << 25;
pub const portsc_wde: u32 = 1 << 26;
pub const portsc_woe: u32 = 1 << 27;

/// Write-one-to-clear bits.
pub const portsc_changes: u32 = portsc_csc | portsc_pec | portsc_wrc | portsc_occ | portsc_prc | portsc_plc | portsc_cec;

pub const pls_u0: u32 = 0;
pub const pls_disabled: u32 = 3;
pub const pls_rx_detect: u32 = 5;
pub const pls_inactive: u32 = 7;

// ---------------------------------------------------------------------------
// TRBs
// ---------------------------------------------------------------------------

pub const trb_normal: u6 = 1;
pub const trb_setup: u6 = 2;
pub const trb_data: u6 = 3;
pub const trb_status: u6 = 4;
pub const trb_link: u6 = 6;
pub const trb_noop: u6 = 8;
pub const trb_enable_slot: u6 = 9;
pub const trb_disable_slot: u6 = 10;
pub const trb_address_device: u6 = 11;
pub const trb_configure_endpoint: u6 = 12;
pub const trb_evaluate_context: u6 = 13;
pub const trb_reset_endpoint: u6 = 14;
pub const trb_stop_endpoint: u6 = 15;
pub const trb_set_tr_dequeue: u6 = 16;
pub const trb_reset_device: u6 = 17;

pub const ev_transfer: u6 = 32;
pub const ev_command_completion: u6 = 33;
pub const ev_port_status_change: u6 = 34;
pub const ev_bandwidth_request: u6 = 35;
pub const ev_doorbell: u6 = 36;
pub const ev_host_controller: u6 = 37;
pub const ev_device_notification: u6 = 38;

pub const completion_success: u8 = 1;
pub const completion_short_packet: u8 = 13;

pub const trb_size = 16;

pub const Trb = struct {
    parameter: u64 = 0,
    status: u32 = 0,
    control: u32 = 0,

    pub fn encode(self: Trb, out: *[trb_size]u8) void {
        std.mem.writeInt(u64, out[0..8], self.parameter, .little);
        std.mem.writeInt(u32, out[8..12], self.status, .little);
        std.mem.writeInt(u32, out[12..16], self.control, .little);
    }

    pub fn decode(bytes: *const [trb_size]u8) Trb {
        return .{
            .parameter = std.mem.readInt(u64, bytes[0..8], .little),
            .status = std.mem.readInt(u32, bytes[8..12], .little),
            .control = std.mem.readInt(u32, bytes[12..16], .little),
        };
    }

    pub fn trbType(self: Trb) u6 {
        return @truncate((self.control >> 10) & 0x3F);
    }

    pub fn slotId(self: Trb) u8 {
        return @truncate(self.control >> 24);
    }

    /// Transfer events carry the endpoint id in control bits 16:20 (the
    /// status dword holds residual length and completion code).
    pub fn endpointId(self: Trb) u5 {
        return @truncate((self.control >> 16) & 0x1F);
    }

    pub fn completionCode(self: Trb) u8 {
        return @truncate(self.status >> 24);
    }

    pub fn transferLength(self: Trb) u32 {
        return self.status & 0x00FF_FFFF;
    }

    pub fn cycle(self: Trb) bool {
        return self.control & 1 != 0;
    }
};

/// Normal transfer TRB: a data buffer and a length.
pub fn normalTrb(buffer: u64, length: u32, cycle: bool) Trb {
    var control: u32 = @as(u32, trb_normal) << 10 | (1 << 5); // IOC
    if (cycle) control |= 1;
    return .{ .parameter = buffer, .status = length & 0x00FF_FFFF, .control = control };
}

pub const Trt = enum(u2) { none = 0, out = 2, in = 3 };

pub fn setupTrb(packet: u64, trt: Trt, cycle: bool) Trb {
    var control: u32 = @as(u32, trb_setup) << 10 | (1 << 6); // IDT
    control |= @as(u32, @intFromEnum(trt)) << 16;
    if (cycle) control |= 1;
    return .{ .parameter = packet, .status = 8, .control = control };
}

pub fn dataTrb(buffer: u64, length: u32, in: bool, cycle: bool) Trb {
    var control: u32 = @as(u32, trb_data) << 10;
    if (in) control |= 1 << 16;
    if (cycle) control |= 1;
    return .{ .parameter = buffer, .status = length & 0x00FF_FFFF, .control = control };
}

/// Status stage. For an IN data stage the status stage is OUT; with no data it
/// is IN (xHCI 1.1, 4.11.2.2).
pub fn statusTrb(in_direction: bool, cycle: bool) Trb {
    var control: u32 = @as(u32, trb_status) << 10 | (1 << 5);
    if (in_direction) control |= 1 << 16;
    if (cycle) control |= 1;
    return .{ .parameter = 0, .status = 0, .control = control };
}

pub fn linkTrb(next_ring: u64, cycle: bool) Trb {
    var control: u32 = @as(u32, trb_link) << 10 | (1 << 1); // TC
    if (cycle) control |= 1;
    return .{ .parameter = next_ring, .status = 0, .control = control };
}

pub fn commandTrb(kind: u6, parameter: u64, slot: u8, cycle: bool) Trb {
    var control: u32 = @as(u32, kind) << 10;
    control |= @as(u32, slot) << 24;
    if (cycle) control |= 1;
    return .{ .parameter = parameter, .status = 0, .control = control };
}

pub fn enableSlotTrb(cycle: bool) Trb {
    return commandTrb(trb_enable_slot, 0, 0, cycle);
}

/// Wait for a transfer event in a driver poll loop.
pub fn transferEventMatches(event: Trb, slot: u8, dci: u5, trb_pointer: u64) bool {
    return event.trbType() == ev_transfer and event.slotId() == slot and event.endpointId() == dci and event.parameter == trb_pointer;
}

/// A ring of TRBs. The last slot is a link TRB back to the start, as xHCI
/// requires; when the producer wraps, the link's cycle bit must toggle so the
/// controller can tell new entries from stale ones.
pub const Ring = struct {
    size: u16,
    index: u16 = 0,
    cycle: bool = true,
    wraps: u32 = 0,

    pub const Entry = struct { index: u16, cycle: bool, wrapped: bool };

    pub fn take(self: *Ring) Entry {
        if (self.size < 2) return .{ .index = 0, .cycle = self.cycle, .wrapped = false };
        const index = self.index;
        const cycle = self.cycle;
        self.index += 1;
        var wrapped = false;
        if (self.index >= self.size - 1) {
            // Leave the last slot for the link TRB and wrap.
            self.index = 0;
            self.cycle = !self.cycle;
            self.wraps += 1;
            wrapped = true;
        }
        return .{ .index = index, .cycle = cycle, .wrapped = wrapped };
    }

    pub fn linkIndex(self: *const Ring) u16 {
        return self.size - 1;
    }
};

pub const ErstEntry = struct {
    base: u64 = 0,
    size: u32 = 0,

    pub fn encode(self: ErstEntry, out: *[16]u8) void {
        std.mem.writeInt(u64, out[0..8], self.base, .little);
        std.mem.writeInt(u32, out[8..12], self.size, .little);
        std.mem.writeInt(u32, out[12..16], 0, .little);
    }
};

// ---------------------------------------------------------------------------
// Contexts
// ---------------------------------------------------------------------------

pub const SlotState = enum(u5) { disabled = 0, default_state = 1, addressed = 2, configured = 3 };

pub const SlotContext = struct {
    route: u32 = 0,
    speed: u8 = 3,
    hub: bool = false,
    context_entries: u5 = 1,
    hub_ports: u8 = 0,
    root_port: u8 = 1,
    tier: u8 = 0,
    address: u8 = 0,
    state: SlotState = .default_state,
    max_exit_latency: u16 = 0,
    tt_hub_slot: u8 = 0,
    tt_port: u8 = 0,
    interrupter: u8 = 0,

    pub fn write(self: SlotContext, out: *[8]u32) void {
        out[0] = (self.route & 0xFFFFF) |
            (@as(u32, self.speed) << 20) |
            (@as(u32, @intFromBool(self.hub)) << 26) |
            (@as(u32, self.context_entries) << 27);
        // Dword 1: max exit latency 0:15, root hub port number 16:23,
        // hub port count 24:31 (xHCI 1.1 table 6-5).
        out[1] = @as(u32, self.max_exit_latency) |
            (@as(u32, self.root_port) << 16) |
            (@as(u32, self.hub_ports) << 24);
        out[2] = @as(u32, self.tt_hub_slot) |
            (@as(u32, self.tt_port) << 8) |
            (@as(u32, self.interrupter) << 22);
        out[3] = @as(u32, self.address) |
            (@as(u32, @intFromEnum(self.state)) << 27);
        out[4] = 0;
        out[5] = 0;
        out[6] = 0;
        out[7] = 0;
    }
};

pub const EndpointType = enum(u3) {
    isoch_out = 1,
    bulk_out = 2,
    interrupt_out = 3,
    control = 4,
    isoch_in = 5,
    bulk_in = 6,
    interrupt_in = 7,
};

pub const EndpointContext = struct {
    state: u3 = 1,
    interval: u8 = 0,
    endpoint_type: EndpointType = .control,
    max_packet: u16 = 64,
    cerr: u2 = 3,
    max_burst: u8 = 0,
    dequeue: u64 = 0,
    dcs: bool = true,
    avg_trb_length: u16 = 8,
    max_esit_payload: u16 = 0,

    pub fn write(self: EndpointContext, out: *[8]u32) void {
        out[0] = @as(u32, self.state) | (@as(u32, self.interval) << 16);
        out[1] = (@as(u32, self.cerr) << 1) |
            (@as(u32, @intFromEnum(self.endpoint_type)) << 3) |
            (@as(u32, self.max_burst) << 8) |
            (@as(u32, self.max_packet) << 16);
        const dequeue = (self.dequeue & ~@as(u64, 0xF)) | @as(u64, @intFromBool(self.dcs));
        out[2] = @truncate(dequeue);
        out[3] = @truncate(dequeue >> 32);
        out[4] = @as(u32, self.avg_trb_length) | (@as(u32, self.max_esit_payload) << 16);
        out[5] = 0;
        out[6] = 0;
        out[7] = 0;
    }
};

pub const max_device_contexts = 32;
/// Control context + slot context + 31 endpoint contexts (EP0..EP30).
pub const max_input_contexts = 33;
pub const context_words = 8;

pub const DeviceContext = struct {
    /// Index 0 is the slot context; endpoint DCI d lives at index d.
    words: [max_device_contexts][context_words]u32 = [_][context_words]u32{[_]u32{0} ** context_words} ** max_device_contexts,

    pub fn setSlot(self: *DeviceContext, slot: SlotContext) void {
        slot.write(&self.words[0]);
    }

    pub fn setEndpoint(self: *DeviceContext, dci: u5, endpoint: EndpointContext) void {
        if (dci == 0 or dci >= max_device_contexts) return;
        endpoint.write(&self.words[dci]);
    }
};

pub const InputControl = struct {
    add: u32 = 0,
    drop: u32 = 0,

    pub const add_slot: u32 = 1 << 0;
    pub const add_ep0: u32 = 1 << 1;

    pub fn addEndpoint(self: *InputControl, dci: u5) void {
        self.add |= @as(u32, 1) << dci;
    }
};

pub const InputContext = struct {
    control: InputControl = .{},
    slot: SlotContext = .{},
    endpoints: [max_device_contexts]EndpointContext = [_]EndpointContext{.{}} ** max_device_contexts,

    /// Layout: input control context, slot context, then endpoint contexts in
    /// DCI order. The controller reads exactly 33 contexts for a 64-byte device
    /// context (xHCI 6.2.5).
    pub fn write(self: *const InputContext, out: *[max_input_contexts][context_words]u32) void {
        for (out) |*words| words.* = [_]u32{0} ** context_words;
        out[0][0] = self.control.drop;
        out[0][1] = self.control.add;
        self.slot.write(&out[1]);
        var i: u6 = 1;
        while (i < max_device_contexts) : (i += 1) {
            const dci: u5 = @intCast(i);
            self.endpoints[dci].write(&out[i + 1]);
        }
    }
};

pub fn endpointTypeFor(kind: @import("usb.zig").TransferKind, in: bool) EndpointType {
    return switch (kind) {
        .control => .control,
        .bulk => if (in) .bulk_in else .bulk_out,
        .interrupt => if (in) .interrupt_in else .interrupt_out,
        .isochronous => if (in) .isoch_in else .isoch_out,
    };
}

// ---------------------------------------------------------------------------
// Ports and speeds
// ---------------------------------------------------------------------------

pub const Speed = enum(u4) {
    full = 1,
    low = 2,
    high = 3,
    super = 4,
    super_plus = 5,
    unknown = 0,
};

pub const PortState = struct {
    connected: bool = false,
    enabled: bool = false,
    reset: bool = false,
    powered: bool = false,
    connect_change: bool = false,
    reset_change: bool = false,
    over_current: bool = false,
    link_state: u4 = 0,
    speed: Speed = .unknown,
};

pub fn parsePortSc(value: u32) PortState {
    const speed_bits: u4 = @truncate((value >> portsc_speed_shift) & 0x0F);
    return .{
        .connected = value & portsc_ccs != 0,
        .enabled = value & portsc_ped != 0,
        .reset = value & portsc_pr != 0,
        .powered = value & portsc_pp != 0,
        .connect_change = value & portsc_csc != 0,
        .reset_change = value & portsc_prc != 0,
        .over_current = value & portsc_oca != 0,
        .link_state = @truncate((value >> portsc_pls_shift) & 0x0F),
        .speed = switch (speed_bits) {
            1 => .full,
            2 => .low,
            3 => .high,
            4 => .super,
            5 => .super_plus,
            else => .unknown,
        },
    };
}

pub fn speedMaxPacket(speed: Speed) u16 {
    return switch (speed) {
        .low, .full => 8,
        .high => 64,
        .super, .super_plus => 512,
        .unknown => 8,
    };
}

/// Root hub port numbers are one-based and appear as the high byte of a port
/// status change event's parameter (xHCI 6.4.5).
pub fn portChangeNumber(parameter: u64) u8 {
    return @truncate(parameter >> 24);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a normal TRB carries its buffer, length, IOC and cycle" {
    const trb = normalTrb(0x1234_5678, 64, true);
    try testing.expectEqual(trb_normal, trb.trbType());
    try testing.expectEqual(@as(u64, 0x1234_5678), trb.parameter);
    try testing.expectEqual(@as(u32, 64), trb.transferLength());
    try testing.expect(trb.cycle());
    try testing.expect(trb.control & (1 << 5) != 0);
}

test "a control transfer's three stages point the right direction" {
    const setup = setupTrb(0x1122_3344_5566_7788, .in, true);
    try testing.expectEqual(trb_setup, setup.trbType());
    try testing.expectEqual(@as(u32, 3), (setup.control >> 16) & 3); // TRT IN
    try testing.expect(setup.control & (1 << 6) != 0); // IDT

    const data = dataTrb(0x9000, 18, true, true);
    try testing.expectEqual(trb_data, data.trbType());
    try testing.expect(data.control & (1 << 16) != 0);

    const status_in = statusTrb(true, true);
    try testing.expectEqual(trb_status, status_in.trbType());
    try testing.expect(status_in.control & (1 << 16) != 0);
    const status_out = statusTrb(false, true);
    try testing.expect(status_out.control & (1 << 16) == 0);
}

test "a TRB survives the byte round trip" {
    var bytes: [trb_size]u8 = undefined;
    const original = Trb{ .parameter = 0xDEAD_BEEF_CAFE_1234, .status = 0x0102_0304, .control = 0xA5A5_5A5A };
    original.encode(&bytes);
    const decoded = Trb.decode(&bytes);
    try testing.expectEqual(original.parameter, decoded.parameter);
    try testing.expectEqual(original.status, decoded.status);
    try testing.expectEqual(original.control, decoded.control);
}

test "a ring leaves the last slot for its link TRB and toggles the cycle on wrap" {
    var ring = Ring{ .size = 4 };
    const first = ring.take();
    try testing.expectEqual(@as(u16, 0), first.index);
    try testing.expect(first.cycle);
    _ = ring.take();
    const last = ring.take();
    try testing.expectEqual(@as(u16, 2), last.index);
    try testing.expect(last.wrapped); // link TRB at index 3 must now carry the new cycle
    const next = ring.take();
    try testing.expectEqual(@as(u16, 0), next.index);
    try testing.expect(!next.cycle);
    try testing.expectEqual(@as(u16, 3), ring.linkIndex());
}

test "command TRBs carry the slot id and type" {
    const cmd = commandTrb(trb_address_device, 0x8000, 3, true);
    try testing.expectEqual(trb_address_device, cmd.trbType());
    try testing.expectEqual(@as(u8, 3), cmd.slotId());
    try testing.expect(cmd.cycle());
    try testing.expectEqual(@as(u64, 0x8000), cmd.parameter);
}

test "an address-device input context sets the slot and EP0 bits" {
    var control = InputControl{};
    control.add = InputControl.add_slot | InputControl.add_ep0;
    const slot = SlotContext{ .speed = 3, .root_port = 1, .context_entries = 1, .state = .default_state };
    var ep0 = EndpointContext{ .endpoint_type = .control, .max_packet = 64, .dequeue = 0x9000 };
    ep0.dcs = true;
    var input = InputContext{ .control = control, .slot = slot };
    input.endpoints[1] = ep0;

    var words: [max_input_contexts][context_words]u32 = undefined;
    input.write(&words);
    try testing.expectEqual(@as(u32, 3), words[0][1]);
    try testing.expectEqual(@as(u32, 3), (words[1][0] >> 20) & 0xF);
    try testing.expectEqual(@as(u32, 1), (words[1][1] >> 16) & 0xFF);
    var routed = SlotContext{ .speed = 3, .root_port = 5, .hub_ports = 2, .context_entries = 2 };
    routed.write(&words[1]);
    try testing.expectEqual(@as(u32, 5), (words[1][1] >> 16) & 0xFF);
    try testing.expectEqual(@as(u32, 2), (words[1][1] >> 24) & 0xFF);
    try testing.expectEqual(@as(u32, 64), (words[2][1] >> 16) & 0xFFFF);
    try testing.expectEqual(@as(u32, 4), (words[2][1] >> 3) & 0x7);
    try testing.expectEqual(@as(u32, 0x9001), words[2][2]); // DCS in bit 0
}

test "endpoint context types follow direction and transfer kind" {
    try testing.expectEqual(EndpointType.interrupt_in, endpointTypeFor(.interrupt, true));
    try testing.expectEqual(EndpointType.bulk_out, endpointTypeFor(.bulk, false));
    try testing.expectEqual(EndpointType.control, endpointTypeFor(.control, true));
}

test "ring wrap leaves the link in the old cycle and toggles for the next pass" {
    var ring = Ring{ .size = 4 };
    const a = ring.take();
    try testing.expectEqual(@as(u16, 0), a.index);
    try testing.expect(a.cycle);
    try testing.expect(!a.wrapped);
    _ = ring.take();
    const last = ring.take();
    try testing.expectEqual(@as(u16, 2), last.index);
    try testing.expect(last.wrapped);
    try testing.expect(last.cycle); // link TRB must carry the cycle it closes
    try testing.expect(!ring.cycle);
    const next = ring.take();
    try testing.expectEqual(@as(u16, 0), next.index);
    try testing.expect(!next.cycle);
}

test "transfer events decode slot and endpoint from control" {
    const trb = Trb{ .parameter = 0x1234, .status = 0x0100_0002, .control = (3 << 24) | (2 << 16) | (32 << 10) | 1 };
    try testing.expectEqual(@as(u8, 3), trb.slotId());
    try testing.expectEqual(@as(u5, 2), trb.endpointId());
    try testing.expectEqual(@as(u8, 1), trb.completionCode());
    try testing.expectEqual(@as(u32, 2), trb.transferLength());
}

test "port status decodes connection, reset and speed" {
    const value = portsc_ccs | portsc_ped | portsc_pp | portsc_csc | portsc_prc | (@as(u32, 3) << portsc_speed_shift);
    const state = parsePortSc(value);
    try testing.expect(state.connected and state.enabled and state.powered);
    try testing.expect(state.connect_change and state.reset_change);
    try testing.expectEqual(Speed.high, state.speed);
    try testing.expectEqual(@as(u16, 64), speedMaxPacket(state.speed));
}

test "transfer events match only the expected slot, endpoint and TRB" {
    var event = Trb{ .parameter = 0x7000, .status = 1 << 24, .control = @as(u32, ev_transfer) << 10 | 3 << 16 | 2 << 24 };
    try testing.expect(event.trbType() == ev_transfer);
    try testing.expect(transferEventMatches(event, 2, 3, 0x7000));
    try testing.expect(!transferEventMatches(event, 2, 1, 0x7000));
    event.status = 13 << 24;
    try testing.expectEqual(completion_short_packet, event.completionCode());
}
