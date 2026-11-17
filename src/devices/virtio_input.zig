//! virtio-input class driver (phase 38).
//!
//! The first two-queue device in the tree: queue 0 carries `virtio_input_event`
//! records (type, code, value) from the device, queue 1 is the driver-to-device
//! channel used for LEDs and forced feedback. Every buffer offered on queue 0
//! holds 64 bytes, i.e. eight events; the device fills as many as fit and
//! publishes one used element, which the IRQ handler drains and immediately
//! re-posts so the device always has room.
//!
//! The device tells the driver what it is through its config space (EV_BITS and
//! ABS_INFO): a keyboard has KEY_A and no axes, a tablet has ABS_X/ABS_Y with
//! their own absolute ranges. Nothing about the terminal's hardware is compiled
//! in; a USB HID keyboard will reuse the same translation once phase 39 brings
//! up xHCI, because both paths land in `kernel/input.zig`.

const std = @import("std");
const virtio = @import("../kernel/virtio.zig");
const input = @import("../kernel/input.zig");
const keymap = @import("../lib/keymap.zig");
const irq = @import("../kernel/irq.zig");
const driver = @import("../kernel/driver.zig");
const klog = @import("../kernel/klog.zig");
const fdt = @import("../lib/fdt.zig");
const fb = @import("../kernel/fb.zig");

pub const input_device: u32 = 18;
pub const max_input_devices = 2;
pub const buffers_per_device = 16;
pub const buffer_bytes = 64;

/// Event types, as the Linux input protocol numbers them.
const ev_syn: u16 = 0;
const ev_key: u16 = 1;
const ev_rel: u16 = 2;
const ev_abs: u16 = 3;
const ev_msc: u16 = 4;

const syn_report: u16 = 0;
const abs_x: u16 = 0;
const abs_y: u16 = 1;
const rel_x: u16 = 0;
const rel_y: u16 = 1;
const rel_wheel: u16 = 8;

const btn_left: u16 = 0x110;
const btn_right: u16 = 0x111;
const btn_middle: u16 = 0x112;

/// Config space.
const cfg_select: usize = 0x100;
const cfg_subsel: usize = 0x101;
const cfg_size: usize = 0x102;
const cfg_data: usize = 0x108;

const select_id_name: u8 = 0x01;
const select_ev_bits: u8 = 0x11;
const select_abs_info: u8 = 0x12;

pub const Axis = struct {
    min: i32 = 0,
    max: i32 = 0,
    fuzz: i32 = 0,
    flat: i32 = 0,
    res: i32 = 0,

    pub fn span(self: Axis) i32 {
        return if (self.max > self.min) self.max - self.min else 0;
    }
};

pub const Stats = struct {
    devices: usize = 0,
    keyboards: usize = 0,
    pointers: usize = 0,
    events: u64 = 0,
    key_events: u64 = 0,
    pointer_events: u64 = 0,
    button_events: u64 = 0,
    scroll_events: u64 = 0,
    completions: u64 = 0,
    interrupts: u64 = 0,
    polls: u64 = 0,
    reposts: u64 = 0,
    resets: usize = 0,
    refused: usize = 0,
};

pub const InputDevice = struct {
    present: bool = false,
    transport: virtio.Mmio = .{},
    event_queue: *virtio.Queue = undefined,
    status_queue: *virtio.Queue = undefined,
    input_index: u8 = 0,
    intid: u32 = 0,
    name: [24]u8 = [_]u8{0} ** 24,
    name_len: usize = 0,
    kind: input.DeviceKind = .unknown,
    has_abs: bool = false,
    has_rel: bool = false,
    axis_x: Axis = .{},
    axis_y: Axis = .{},
    /// Raw absolute state until SYN_REPORT commits it.
    pending_x: i32 = 0,
    pending_y: i32 = 0,
    pending_abs: bool = false,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    buttons: u8 = 0,
    modifiers: keymap.Modifiers = .{},
    buffers: [buffers_per_device][buffer_bytes]u8 align(8) = undefined,
    events: u64 = 0,

    pub fn nameSlice(self: *const InputDevice) []const u8 {
        return self.name[0..self.name_len];
    }
};

var devices: [max_input_devices]InputDevice = [_]InputDevice{.{}} ** max_input_devices;
var device_count: usize = 0;
var stats: Stats = .{};

pub fn info() []const InputDevice {
    return devices[0..device_count];
}

pub fn deviceCount() usize {
    return device_count;
}

pub fn statistics() Stats {
    return stats;
}

fn mmio8(base: usize, off: usize) *volatile u8 {
    return @ptrFromInt(base + off);
}

fn mmio32(base: usize, off: usize) *volatile u32 {
    return @ptrFromInt(base + off);
}

fn mmio16(base: usize, off: usize) *volatile u16 {
    return @ptrFromInt(base + off);
}

fn cfgSelect(t: *const virtio.Mmio, select: u8, subsel: u8) void {
    // Select and subsel are adjacent bytes and the device samples both when the
    // write lands; writing them separately can zero one with the other on a
    // transport that forwards each byte write on its own, so write both at once.
    const value: u16 = @as(u16, subsel) << 8 | select;
    mmio16(t.base, cfg_select).* = value;
}

fn cfgRead(t: *const virtio.Mmio, out: []u8) usize {
    const size = mmio8(t.base, cfg_size).*;
    const n = @min(@as(usize, size), out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = mmio8(t.base, cfg_data + i).*;
    return n;
}

fn hasEventBit(t: *const virtio.Mmio, event_type: u8, code: u16) bool {
    cfgSelect(t, select_ev_bits, event_type);
    var bitmap: [32]u8 = undefined;
    const n = cfgRead(t, &bitmap);
    const byte = code / 8;
    if (byte >= n) return false;
    return bitmap[byte] & (@as(u8, 1) << @intCast(code % 8)) != 0;
}

fn readAxis(t: *const virtio.Mmio, axis: u8) Axis {
    cfgSelect(t, select_abs_info, axis);
    var raw: [20]u8 = undefined;
    const n = cfgRead(t, &raw);
    if (n < 20) return .{};
    return .{
        .min = @bitCast(std.mem.readInt(u32, raw[0..4], .little)),
        .max = @bitCast(std.mem.readInt(u32, raw[4..8], .little)),
        .fuzz = @bitCast(std.mem.readInt(u32, raw[8..12], .little)),
        .flat = @bitCast(std.mem.readInt(u32, raw[12..16], .little)),
        .res = @bitCast(std.mem.readInt(u32, raw[16..20], .little)),
    };
}

fn readName(t: *const virtio.Mmio, out: *[24]u8) usize {
    cfgSelect(t, select_id_name, 0);
    return cfgRead(t, out[0..]);
}

fn nodeInterrupt(node_off: usize) u32 {
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
    return 0;
}

fn repost(dev: *InputDevice, addr: u64, len: u32) void {
    const head = dev.event_queue.allocChain(1) orelse return;
    dev.event_queue.setDesc(head, 0, addr, len, true);
    dev.event_queue.submit(head);
    stats.reposts += 1;
}

fn postBuffer(dev: *InputDevice, index: usize) void {
    const head = dev.event_queue.allocChain(1) orelse return;
    dev.event_queue.setDesc(head, 0, @intFromPtr(&dev.buffers[index]), buffer_bytes, true);
    dev.event_queue.submit(head);
}

fn scaleAbs(value: i32, axis: Axis, pixels: u32) i32 {
    const span = axis.span();
    if (span <= 0 or pixels == 0) return value;
    const relative = value - axis.min;
    if (relative <= 0) return 0;
    if (relative >= span) return @intCast(pixels - 1);
    const numerator = @as(i64, relative) * @as(i64, @intCast(pixels - 1));
    return @intCast(@divTrunc(numerator, @as(i64, span)));
}

fn panelSize() struct { width: u32, height: u32 } {
    if (fb.screen()) |screen| {
        return .{ .width = screen.mode.width, .height = screen.mode.height };
    }
    return .{ .width = 0, .height = 0 };
}

const Position = struct { x: i32, y: i32 };

fn pointerPixel(dev: *InputDevice, abs: bool, x: i32, y: i32) Position {
    const size = panelSize();
    if (abs) {
        if (size.width == 0) return .{ .x = x, .y = y };
        return .{
            .x = scaleAbs(x, dev.axis_x, size.width),
            .y = scaleAbs(y, dev.axis_y, size.height),
        };
    }
    return .{ .x = x, .y = y };
}

fn commitPointer(dev: *InputDevice) void {
    if (!dev.pending_abs) return;
    dev.pending_abs = false;
    var pos = Position{ .x = dev.pending_x, .y = dev.pending_y };
    if (dev.has_abs) {
        pos = pointerPixel(dev, true, dev.pending_x, dev.pending_y);
        dev.cursor_x = pos.x;
        dev.cursor_y = pos.y;
    } else {
        const size = panelSize();
        const width: i32 = if (size.width == 0) 32767 else @intCast(size.width - 1);
        const height: i32 = if (size.height == 0) 32767 else @intCast(size.height - 1);
        dev.cursor_x = std.math.clamp(dev.cursor_x + pos.x, 0, width);
        dev.cursor_y = std.math.clamp(dev.cursor_y + pos.y, 0, height);
        pos = .{ .x = dev.cursor_x, .y = dev.cursor_y };
    }
    input.pointerMove(dev.input_index, pos.x, pos.y, dev.buttons);
    stats.pointer_events += 1;
}

fn buttonNumber(code: u16) u8 {
    return switch (code) {
        btn_left => 1,
        btn_right => 2,
        btn_middle => 3,
        else => 0,
    };
}

fn applyButton(dev: *InputDevice, code: u16, pressed: bool) void {
    const button = buttonNumber(code);
    if (button == 0) return;
    const bit: u8 = @as(u8, 1) << @intCast(button - 1);
    if (pressed) {
        dev.buttons |= bit;
    } else {
        dev.buttons &= ~bit;
    }
    input.buttonEvent(dev.input_index, button, pressed);
    stats.button_events += 1;
}

fn handleEvent(dev: *InputDevice, event_type: u16, code: u16, value: i32) void {
    stats.events += 1;
    dev.events += 1;
    switch (event_type) {
        ev_syn => {
            if (code == syn_report) commitPointer(dev);
        },
        ev_key => {
            const pressed = value != 0;
            // value 2 is auto-repeat: the key is still held, so it must not
            // toggle a lock (holding caps would otherwise flash it).
            const repeat = value == 2;
            if (buttonNumber(code) != 0) {
                applyButton(dev, code, pressed);
                return;
            }
            const key = keymap.translate(code);
            if (!repeat) _ = dev.modifiers.update(key, pressed);
            input.keyEvent(dev.input_index, code, pressed, dev.modifiers.bits());
            stats.key_events += 1;
        },
        ev_rel => {
            switch (code) {
                rel_x => {
                    dev.pending_x += value;
                    dev.pending_abs = true;
                },
                rel_y => {
                    dev.pending_y += value;
                    dev.pending_abs = true;
                },
                rel_wheel => {
                    if (value != 0) {
                        input.scrollEvent(dev.input_index, 1, value);
                        stats.scroll_events += 1;
                    }
                },
                else => {},
            }
        },
        ev_abs => {
            switch (code) {
                abs_x => {
                    dev.pending_x = value;
                    dev.pending_abs = true;
                },
                abs_y => {
                    dev.pending_y = value;
                    dev.pending_abs = true;
                },
                else => {},
            }
        },
        ev_msc => {},
        else => {},
    }
}

/// Decode the events in one completed buffer. A trailing partial record is
/// ignored: a device that publishes a half event must not make the driver read
/// past the bytes it actually wrote.
fn decodeBuffer(dev: *InputDevice, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset + 8 <= bytes.len) : (offset += 8) {
        const event_type = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const code = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);
        const value: i32 = @bitCast(std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little));
        handleEvent(dev, event_type, code, value);
    }
}

fn drain(dev: *InputDevice, from_irq: bool) usize {
    if (from_irq) stats.interrupts += 1;
    var drained: usize = 0;
    while (dev.event_queue.popUsed()) |elem| {
        const desc = dev.event_queue.desc[@intCast(elem.id)];
        const addr = desc.addr;
        const len: usize = @min(@as(usize, elem.len), buffer_bytes);
        if (addr != 0) {
            const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(addr)));
            decodeBuffer(dev, ptr[0..len]);
        }
        dev.event_queue.freeChain(@intCast(elem.id));
        if (addr != 0) repost(dev, addr, buffer_bytes);
        drained += 1;
    }
    stats.completions += drained;
    if (drained > 0) dev.transport.notify(dev.event_queue);
    return drained;
}

pub fn pollAll() void {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (!devices[i].present) continue;
        if (drain(&devices[i], false) > 0) stats.polls += 1;
    }
}

fn interruptHandler(_: u32) void {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const dev = &devices[i];
        if (!dev.present) continue;
        if (dev.transport.takeInterrupt() != 0) input.noteInterrupt(dev.input_index);
        _ = drain(dev, true);
    }
}

fn classify(t: *const virtio.Mmio) input.DeviceKind {
    if (hasEventBit(t, @intCast(ev_abs), abs_x)) return .tablet;
    if (hasEventBit(t, @intCast(ev_rel), rel_x)) return .pointer;
    if (hasEventBit(t, @intCast(ev_key), 30)) return .keyboard; // KEY_A
    return .unknown;
}

/// Attach one virtio-input device that already has queue 0 and queue 1 set up.
pub fn attach(
    t: virtio.Mmio,
    event_queue: *virtio.Queue,
    status_queue: *virtio.Queue,
    node_off: usize,
) !void {
    if (device_count >= max_input_devices) return error.NoMemory;
    const index = device_count;
    var dev = &devices[index];
    dev.* = .{
        .present = true,
        .transport = t,
        .event_queue = event_queue,
        .status_queue = status_queue,
    };

    dev.name_len = readName(&t, &dev.name);
    if (dev.name_len > 0) {
        while (dev.name_len > 0 and (dev.name[dev.name_len - 1] == 0 or dev.name[dev.name_len - 1] == ' ')) dev.name_len -= 1;
    }
    dev.kind = classify(&t);
    dev.has_abs = hasEventBit(&t, @intCast(ev_abs), abs_x) and hasEventBit(&t, @intCast(ev_abs), abs_y);
    dev.has_rel = hasEventBit(&t, @intCast(ev_rel), rel_x) and hasEventBit(&t, @intCast(ev_rel), rel_y);
    if (dev.has_abs) {
        dev.axis_x = readAxis(&t, @intCast(abs_x));
        dev.axis_y = readAxis(&t, @intCast(abs_y));
    }

    const name_for_core = if (dev.name_len > 0) dev.nameSlice() else "virtio-input";
    const input_index = input.registerDevice(name_for_core, dev.kind) orelse return error.NoMemory;
    dev.input_index = input_index;
    if (dev.has_abs) {
        input.setDeviceRange(input_index, dev.axis_x.min, dev.axis_x.max, dev.axis_y.min, dev.axis_y.max);
    }

    for (0..buffers_per_device) |i| postBuffer(dev, i);
    t.notify(event_queue);

    dev.intid = nodeInterrupt(node_off);
    if (dev.intid != 0) {
        irq.register(dev.intid, interruptHandler);
        input.setDeviceIntid(input_index, dev.intid);
    } else {
        klog.warn("input", "{s}: no interrupt property, polling", .{dev.nameSlice()});
    }

    device_count += 1;
    stats.devices += 1;
    switch (dev.kind) {
        .keyboard => stats.keyboards += 1,
        .pointer, .tablet, .touch => stats.pointers += 1,
        .unknown => {},
    }
    klog.info("input", "{s}: {s}, {d} buffers, abs {s}, rel {s}, {s} {d}", .{
        dev.nameSlice(),
        @tagName(dev.kind),
        buffers_per_device,
        if (dev.has_abs) "yes" else "no",
        if (dev.has_rel) "yes" else "no",
        if (dev.intid != 0) "irq" else "polled",
        dev.intid,
    });
}

pub fn detach(base: u64) void {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const dev = &devices[i];
        if (!dev.present or dev.transport.base != base) continue;
        if (dev.intid != 0) irq.unregister(dev.intid);
        dev.present = false;
        if (input.deviceAt(dev.input_index)) |core| core.present = false;
    }
}

pub fn describe(write: anytype) void {
    if (device_count == 0) {
        write("  input devices: none (no virtio-input transport carries a device)\n", .{});
        return;
    }
    for (devices[0..device_count]) |*dev| {
        write("  {s:<20} {s:<8} raw {d} irq {d} abs [{d}..{d}, {d}..{d}]\n", .{
            dev.nameSlice(),
            @tagName(dev.kind),
            dev.events,
            dev.intid,
            dev.axis_x.min,
            dev.axis_x.max,
            dev.axis_y.min,
            dev.axis_y.max,
        });
    }
    write("  completions {d}, interrupts {d}, reposts {d}, refused {d}\n", .{
        stats.completions, stats.interrupts, stats.reposts, stats.refused,
    });
}

// ---------------------------------------------------------------------------
// Tests: the pure parts of the decode path.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "absolute values scale from the device range into panel pixels" {
    const axis = Axis{ .min = 0, .max = 32767 };
    try testing.expectEqual(@as(i32, 0), scaleAbs(-5, axis, 1280));
    try testing.expectEqual(@as(i32, 0), scaleAbs(0, axis, 1280));
    try testing.expectEqual(@as(i32, 1279), scaleAbs(32767, axis, 1280));
    try testing.expectEqual(@as(i32, 1279), scaleAbs(99999, axis, 1280));
    try testing.expectEqual(@as(i32, 639), scaleAbs(16384, axis, 1280));
}

test "button codes map to the three buttons the POS uses" {
    try testing.expectEqual(@as(u8, 1), buttonNumber(btn_left));
    try testing.expectEqual(@as(u8, 2), buttonNumber(btn_right));
    try testing.expectEqual(@as(u8, 3), buttonNumber(btn_middle));
    try testing.expectEqual(@as(u8, 0), buttonNumber(0x100));
}

test "an event buffer decodes whole records and ignores a partial tail" {
    input.init();
    var dev = InputDevice{};
    dev.input_index = 0;
    var buf: [18]u8 = undefined;
    // EV_KEY KEY_A press, then EV_SYN, then a 2-byte partial record.
    std.mem.writeInt(u16, buf[0..2], ev_key, .little);
    std.mem.writeInt(u16, buf[2..4], 30, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u16, buf[8..10], ev_syn, .little);
    std.mem.writeInt(u16, buf[10..12], 0, .little);
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    buf[16] = 0xff;
    buf[17] = 0xff;

    const before = input.pending();
    decodeBuffer(&dev, &buf);
    const after = input.pending();
    // One key press, one key release (character pairs), nothing for the tail.
    try testing.expectEqual(before + 2, after);
    try testing.expectEqual(@as(u64, 2), dev.events);
}

test "a relative mouse accumulates and clamps inside the panel" {
    var dev = InputDevice{};
    dev.has_rel = true;
    dev.cursor_x = 5;
    dev.cursor_y = 5;
    dev.pending_x = 100000;
    dev.pending_y = -100000;
    dev.pending_abs = true;
    commitPointer(&dev);
    try testing.expectEqual(@as(i32, 32767), dev.cursor_x);
    try testing.expectEqual(@as(i32, 0), dev.cursor_y);
}
