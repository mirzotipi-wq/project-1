//! USB device core and class drivers (phase 39).
//!
//! The controller driver below this (`devices/xhci.zig`) moves bytes; this file
//! decides what they mean. It owns the device table, enumeration (device and
//! configuration descriptors, SET_CONFIGURATION, endpoint contexts), the HID
//! class (report descriptors decoded into the phase-38 input stream), hubs and
//! port power/reset for downstream devices, CDC-ACM serial, and the FTDI bridge
//! that most retail serial peripherals actually use.
//!
//! Hotplug is a first-class path, not a boot special case: root-port connects
//! and removals arrive from the controller as port changes, and a hub is polled
//! for the same events on its downstream ports. Removing a device releases its
//! input slot; replugging reuses it, so a scanner can be cycled all day without
//! exhausting the table.
//!
//! Limits are explicit and reported: at most eight USB devices, one class
//! driver per device, hubs nested up to four tiers. A composite device with two
//! HID interfaces would enumerate, but only the first interface gets a driver;
//! the shell prints what was bound rather than pretending otherwise.

const std = @import("std");
const builtin = @import("builtin");
const xhci = @import("../devices/xhci.zig");
const usb = @import("../lib/usb.zig");
const hid = @import("../lib/hid.zig");
const keymap = @import("../lib/keymap.zig");
const input = @import("../kernel/input.zig");
const fb = @import("../kernel/fb.zig");
const timer = @import("../arch/aarch64/timer.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const klog = @import("../kernel/klog.zig");

pub const max_devices = 8;
const max_report = 512;
const max_config = 1024;

pub const Kind = enum { keyboard, pointer, tablet, hub, serial, unknown };

pub const Stats = struct {
    enumerated: u64 = 0,
    removed: u64 = 0,
    failed: u64 = 0,
    hid_reports: u64 = 0,
    key_events: u64 = 0,
    pointer_events: u64 = 0,
    hub_scans: u64 = 0,
    hub_connects: u64 = 0,
    hub_disconnects: u64 = 0,
    serial_tx: u64 = 0,
    serial_rx: u64 = 0,
    control_errors: u64 = 0,
};

const HidState = struct {
    layout: hid.Layout = .{},
    interface: u8 = 0,
    ep_in: u5 = 0,
    protocol: u8 = 0,
    keyboard: bool = false,
    pointer: bool = false,
    relative: bool = false,
    x: i32 = 640,
    y: i32 = 400,
    buttons: u8 = 0,
    mod_bits: u8 = 0,
    caps: bool = false,
    num: bool = false,
    prev_keys: [10]u16 = [_]u16{0} ** 10,
    prev_count: usize = 0,
    reports: u64 = 0,
    key_events: u64 = 0,
    pointer_events: u64 = 0,
    decode_errors: u64 = 0,
};

const CdcState = struct {
    comm_interface: u8 = 0,
    data_interface: u8 = 0,
    bulk_in: u5 = 0,
    bulk_out: u5 = 0,
    notification: u5 = 0,
    rate: u32 = 115200,
    configured: bool = false,
    cdc: bool = true,
    tx_bytes: u64 = 0,
    rx_bytes: u64 = 0,
};

const HubState = struct {
    ports: u8 = 0,
    next_poll_ms: u64 = 0,
    child_count: u8 = 0,
    polls: u64 = 0,
    connects: u64 = 0,
    disconnects: u64 = 0,
};

pub const Device = struct {
    present: bool = false,
    slot: u8 = 0,
    root_port: u8 = 1,
    route: u32 = 0,
    depth: u8 = 0,
    speed: xhci.Speed = .unknown,
    vendor: u16 = 0,
    product: u16 = 0,
    release: u16 = 0,
    device_class: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,
    config_value: u8 = 1,
    configuration: usb.Configuration = .{},
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    kind: Kind = .unknown,
    input_index: ?u8 = null,
    hid: ?HidState = null,
    cdc: ?CdcState = null,
    hub: ?HubState = null,
    reports: u64 = 0,

    pub fn nameSlice(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }
};

var devices: [max_devices]Device = [_]Device{.{}} ** max_devices;
var stats: Stats = .{};
var initialized = false;

fn nowMs() u64 {
    return timer.uptimeMs();
}

fn delayMs(ms: u64) void {
    const start = nowMs();
    while (nowMs() - start < ms) cpu.nop();
}

fn le16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | @as(u16, bytes[at + 1]) << 8;
}

fn screenSize() struct { width: i32, height: i32 } {
    if (fb.screen()) |surface| {
        return .{ .width = @intCast(surface.mode.width), .height = @intCast(surface.mode.height) };
    }
    return .{ .width = 1280, .height = 800 };
}

fn setName(dev: *Device, name: []const u8) void {
    const n = @min(name.len, dev.name.len);
    @memcpy(dev.name[0..n], name[0..n]);
    dev.name_len = n;
    // Trim trailing spaces some devices put in their product strings.
    while (dev.name_len > 0 and dev.name[dev.name_len - 1] == ' ') dev.name_len -= 1;
}

pub fn init() void {
    devices = [_]Device{.{}} ** max_devices;
    stats = .{};
    initialized = true;
    xhci.setCallbacks(.{
        .connected = onControllerConnect,
        .disconnected = onControllerDisconnect,
        .transfer = onTransfer,
    });
}

fn onControllerConnect(_: xhci.ConnectInfo) void {}
fn onControllerDisconnect(_: u8) void {}

pub fn deviceCount() usize {
    var n: usize = 0;
    for (&devices) |*d| {
        if (d.present) n += 1;
    }
    return n;
}

pub fn devicesSlice() []const Device {
    return devices[0..];
}

pub fn presentCount() usize {
    return deviceCount();
}

fn findSlot(slot: u8) ?*Device {
    for (&devices) |*d| {
        if (d.present and d.slot == slot) return d;
    }
    return null;
}

fn findFree() ?*Device {
    for (&devices) |*d| {
        if (!d.present) return d;
    }
    return null;
}

fn onTransfer(info: xhci.TransferInfo) void {
    const dev = findSlot(info.slot) orelse return;
    if (dev.hid) |*h| {
        h.reports += 1;
        dev.reports += 1;
        stats.hid_reports += 1;
        handleHidReport(dev, h, info.data);
    }
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

fn control(slot: u8, setup: usb.Setup, buffer: []u8) !usize {
    return xhci.control(slot, setup, buffer) catch |err| {
        stats.control_errors += 1;
        return err;
    };
}

fn readDeviceDescriptor(slot: u8) !usb.DeviceDescriptor {
    var buf: [18]u8 = undefined;
    const n = try control(slot, usb.getDescriptor(usb.descriptor_device, 0, 18), buf[0..]);
    if (n < 18) return error.ShortDescriptor;
    return usb.DeviceDescriptor.parse(buf[0..18]);
}

fn readConfiguration(slot: u8) !usb.Configuration {
    var header: [9]u8 = undefined;
    const n = try control(slot, usb.getDescriptor(usb.descriptor_configuration, 0, 9), header[0..]);
    if (n < 9) return error.ShortDescriptor;
    const total = le16(header[0..], 2);
    if (total < 9 or total > max_config) return error.BadDescriptor;
    var buf: [max_config]u8 = undefined;
    const got = try control(slot, usb.getDescriptor(usb.descriptor_configuration, 0, total), buf[0..total]);
    return usb.parseConfiguration(buf[0..got]);
}

fn readString(slot: u8, index: u8, out: []u8) usize {
    if (index == 0) return 0;
    var lang: [4]u8 = undefined;
    const n = control(slot, usb.getDescriptor(usb.descriptor_string, 0, 4), lang[0..]) catch return 0;
    if (n < 4) return 0;
    const langid = le16(lang[0..], 2);
    var buf: [128]u8 = undefined;
    const setup = usb.Setup{
        .request_type = usb.direction_in | usb.type_standard | usb.recipient_device,
        .request = usb.request_get_descriptor,
        .value = @as(u16, usb.descriptor_string) << 8 | @as(u16, index),
        .index = langid,
        .length = buf.len,
    };
    const got = control(slot, setup, buf[0..]) catch return 0;
    const text = usb.parseString(buf[0..got], out) catch return 0;
    return text.len;
}

fn endpointSpecs(config: *const usb.Configuration, out: *[16]xhci.EndpointSpec) usize {
    var n: usize = 0;
    for (config.interfacesSlice()) |*iface| {
        if (iface.alternate != 0) continue;
        for (iface.endpointsSlice()) |*ep| {
            if (n >= out.len) break;
            var duplicate = false;
            for (out[0..n]) |seen| {
                if (seen.dci == ep.dci()) duplicate = true;
            }
            if (duplicate) continue;
            out[n] = .{
                .dci = ep.dci(),
                .kind = ep.kind(),
                .max_packet = ep.max_packet,
                .interval = ep.interval,
                .in = ep.isIn(),
            };
            n += 1;
        }
    }
    return n;
}

fn findHidInterface(config: *const usb.Configuration) ?*const usb.Interface {
    var fallback: ?*const usb.Interface = null;
    for (config.interfacesSlice()) |*iface| {
        if (iface.alternate != 0 or !iface.isHid()) continue;
        if (iface.endpoint_count == 0) continue;
        if (iface.isBootKeyboard() or iface.isBootMouse()) return iface;
        if (fallback == null) fallback = iface;
    }
    return fallback;
}

fn setupHid(dev: *Device, slot: u8, iface: *const usb.Interface) void {
    var report_buf: [max_report]u8 = undefined;
    const want: u16 = if (iface.hid_report_length != 0)
        @intCast(@min(@as(usize, iface.hid_report_length), report_buf.len))
    else
        256;
    const got = control(slot, usb.getReportDescriptor(iface.number, want), report_buf[0..want]) catch |err| {
        klog.warn("usb", "slot {d}: HID report descriptor failed: {s}", .{ slot, @errorName(err) });
        return;
    };
    const layout = hid.parse(report_buf[0..got]) catch |err| {
        klog.warn("usb", "slot {d}: report descriptor did not parse: {s}", .{ slot, @errorName(err) });
        return;
    };
    const ep = iface.firstOf(.interrupt, true) orelse return;

    var h = HidState{ .layout = layout, .interface = iface.number, .ep_in = ep.dci(), .protocol = iface.protocol };
    h.keyboard = hid.hasPage(&layout, 0x07) and
        (hid.hasUsage(&layout, 0x07, 0x04) or hid.hasUsage(&layout, 0x07, 0xE0));
    h.pointer = hid.hasUsage(&layout, 0x01, 0x30) and hid.hasUsage(&layout, 0x01, 0x31);
    h.relative = iface.isBootMouse();
    if (h.pointer) {
        for (layout.fieldsSlice()) |*field| {
            if (field.usage_page == 0x01 and field.usage == 0x30) h.relative = field.is_relative;
        }
    }

    if (h.pointer and h.relative) {
        const size = screenSize();
        h.x = @divTrunc(size.width, 2);
        h.y = @divTrunc(size.height, 2);
    }
    if (!h.keyboard and !h.pointer) {
        klog.warn("usb", "slot {d}: HID interface {d} has neither keyboard nor pointer usages", .{ slot, iface.number });
        return;
    }

    // Boot devices get the boot protocol, which guarantees the eight-byte
    // keyboard / five-byte pointer report even if the report descriptor is
    // unusual. Generic HID keeps report protocol.
    if (iface.subclass == usb.subclass_boot) {
        var empty: [0]u8 = .{};
        _ = control(slot, usb.hidSetProtocol(iface.number, iface.protocol), empty[0..]) catch {};
        _ = control(slot, usb.hidSetIdle(iface.number, 0), empty[0..]) catch {};
    }

    dev.hid = h;
    dev.kind = if (h.keyboard) .keyboard else if (h.relative) .pointer else .tablet;
}

fn setupCdc(dev: *Device, slot: u8, comm: *const usb.Interface, config: *const usb.Configuration) void {
    var data: ?*const usb.Interface = null;
    for (config.interfacesSlice()) |*iface| {
        if (iface.alternate == 0 and iface.class == usb.class_cdc_data) {
            data = iface;
            break;
        }
    }
    const data_iface = data orelse return;
    const bulk_in = data_iface.firstOf(.bulk, true) orelse return;
    const bulk_out = data_iface.firstOf(.bulk, false) orelse return;
    const note = comm.firstOf(.interrupt, true);
    var c = CdcState{
        .comm_interface = comm.number,
        .data_interface = data_iface.number,
        .bulk_in = bulk_in.dci(),
        .bulk_out = bulk_out.dci(),
        .notification = if (note) |ep| ep.dci() else 0,
    };

    const line = usb.cdcSetLineCoding(comm.number, 115200, 0, 0, 8);
    var line_data = line.data;
    _ = control(slot, line.setup, line_data[0..]) catch {};
    var empty: [0]u8 = .{};
    _ = control(slot, usb.cdcSetControlLineState(comm.number, 0x0003), empty[0..]) catch {};
    c.configured = true;
    dev.cdc = c;
    dev.kind = .serial;
}

fn ftdiInit(slot: u8) void {
    // FTDI vendor requests: reset, set baud (24 MHz / 115200 = 208), set flow,
    // set modem control, set 8N1 line control. A terminal bridge usually
    // ignores what it does not need; failure is not fatal because the bulk
    // endpoints still carry bytes.
    const requests = [_]struct { request: u8, value: u16, index: u16 }{
        .{ .request = 0x00, .value = 0, .index = 0 },
        .{ .request = 0x01, .value = 208, .index = 0 },
        .{ .request = 0x02, .value = 0x0008, .index = 0 },
        .{ .request = 0x03, .value = 0, .index = 0 },
        .{ .request = 0x04, .value = 0x0303, .index = 0 },
    };
    for (requests) |r| {
        const setup = usb.Setup{
            .request_type = usb.type_vendor | usb.recipient_device,
            .request = r.request,
            .value = r.value,
            .index = r.index,
            .length = 0,
        };
        var empty: [0]u8 = .{};
        _ = control(slot, setup, empty[0..]) catch {};
    }
}

fn setupSerialVendor(dev: *Device, slot: u8, iface: *const usb.Interface) void {
    const bulk_in = iface.firstOf(.bulk, true) orelse return;
    const bulk_out = iface.firstOf(.bulk, false) orelse return;
    ftdiInit(slot);
    dev.cdc = .{
        .comm_interface = iface.number,
        .data_interface = iface.number,
        .bulk_in = bulk_in.dci(),
        .bulk_out = bulk_out.dci(),
        .configured = true,
        .cdc = false,
    };
    dev.kind = .serial;
}

fn setupHub(dev: *Device, slot: u8) void {
    var buf: [16]u8 = undefined;
    const got = control(slot, usb.getHubDescriptor(9), buf[0..]) catch |err| {
        klog.warn("usb", "slot {d}: hub descriptor failed: {s}", .{ slot, @errorName(err) });
        return;
    };
    const desc = usb.HubDescriptor.parse(buf[0..got]) catch return;
    var empty: [0]u8 = .{};
    var p: u8 = 1;
    while (p <= desc.ports) : (p += 1) {
        _ = control(slot, usb.portFeatureRequest(usb.port_feature_power, p, true), empty[0..]) catch {};
    }
    dev.hub = .{ .ports = desc.ports, .next_poll_ms = nowMs() + 200 };
    dev.kind = .hub;
    if (desc.power_on_delay_ms > 0 and desc.power_on_delay_ms < 250) delayMs(desc.power_on_delay_ms);
}

fn enumerateSlot(slot: u8, cfg: xhci.AddressConfig, port: u8) !void {
    var dd: usb.DeviceDescriptor = undefined;
    var config: usb.Configuration = undefined;
    dd = readDeviceDescriptor(slot) catch |err| {
        klog.warn("usb", "slot {d}: device descriptor: {s}", .{ slot, @errorName(err) });
        return err;
    };
    config = readConfiguration(slot) catch |err| {
        klog.warn("usb", "slot {d}: configuration descriptor: {s}", .{ slot, @errorName(err) });
        return err;
    };

    var empty: [0]u8 = .{};
    _ = control(slot, usb.setConfiguration(config.value), empty[0..]) catch |err| {
        klog.warn("usb", "slot {d}: SET_CONFIGURATION {d}: {s}", .{ slot, config.value, @errorName(err) });
        return err;
    };

    var specs: [16]xhci.EndpointSpec = undefined;
    const spec_count = endpointSpecs(&config, &specs);
    xhci.configure(slot, specs[0..spec_count]) catch |err| {
        klog.warn("usb", "slot {d}: endpoint configuration: {s}", .{ slot, @errorName(err) });
        return err;
    };

    var dev = Device{
        .present = true,
        .slot = slot,
        .root_port = cfg.root_port,
        .route = cfg.route,
        .depth = cfg.depth,
        .speed = cfg.speed,
        .vendor = dd.vendor,
        .product = dd.product,
        .release = dd.release,
        .device_class = dd.class,
        .subclass = dd.subclass,
        .protocol = dd.protocol,
        .config_value = config.value,
        .configuration = config,
    };
    var name_buf: [32]u8 = undefined;
    var name_len = readString(slot, dd.product_index, &name_buf);
    if (name_len == 0) {
        const text = std.fmt.bufPrint(&name_buf, "USB {x:0>4}:{x:0>4}", .{ dd.vendor, dd.product }) catch "USB device";
        name_len = text.len;
    }
    setName(&dev, name_buf[0..name_len]);

    if (findHidInterface(&config)) |iface| {
        setupHid(&dev, slot, iface);
    } else if (config.findInterface(usb.class_comm, usb.cdc_subclass_acm)) |comm| {
        setupCdc(&dev, slot, comm, &config);
    } else if (config.findInterface(usb.class_hub, null)) |hub_iface| {
        _ = hub_iface;
        setupHub(&dev, slot);
    } else if (dd.vendor == 0x0403 and dd.product == 0x6001) {
        if (config.findInterface(0xFF, null)) |iface| setupSerialVendor(&dev, slot, iface);
    } else if (config.findInterface(0xFF, null)) |iface| {
        // A vendor-specific device with a bulk pair is treated as a serial
        // bridge only when it identifies as FTDI; otherwise it is reported but
        // left alone rather than guessed at.
        if (iface.firstOf(.bulk, true) != null and iface.firstOf(.bulk, false) != null) {
            klog.info("usb", "slot {d}: vendor interface {d} has a bulk pair but is not a known bridge", .{ slot, iface.number });
        }
    }

    const free = findFree() orelse {
        klog.warn("usb", "device table full: slot {d} enumerated but not registered", .{slot});
        return error.NoSpace;
    };
    free.* = dev;

    if (free.hid) |*h| {
        const kind: input.DeviceKind = if (h.keyboard) .keyboard else if (h.relative) .pointer else .tablet;
        free.input_index = input.registerDevice(free.nameSlice(), kind);
        if (free.input_index) |index| {
            if (h.pointer and !h.relative) {
                const size = screenSize();
                input.setDeviceRange(index, 0, size.width - 1, 0, size.height - 1);
            }
            xhci.submitInterrupt(slot, h.ep_in) catch |err| {
                klog.warn("usb", "slot {d}: interrupt endpoint did not arm: {s}", .{ slot, @errorName(err) });
            };
        }
    }

    stats.enumerated += 1;
    klog.info("usb", "slot {d} port {d}: {s} ({s}, {x:0>4}:{x:0>4}, {s}, {d} interface(s))", .{
        slot,                port,                   free.nameSlice(), @tagName(free.kind), dd.vendor, dd.product,
        @tagName(cfg.speed), config.interface_count,
    });
}

fn enumerateRoot(port: u8, speed: xhci.Speed) void {
    const slot = xhci.enableSlot() catch |err| {
        stats.failed += 1;
        klog.warn("usb", "port {d}: no slot: {s}", .{ port, @errorName(err) });
        return;
    };
    const cfg = xhci.AddressConfig{ .route = 0, .root_port = port, .speed = speed, .depth = 0 };
    xhci.addressDevice(slot, cfg) catch |err| {
        stats.failed += 1;
        klog.warn("usb", "slot {d}: address device failed: {s}", .{ slot, @errorName(err) });
        xhci.disableSlot(slot);
        return;
    };
    enumerateSlot(slot, cfg, port) catch {
        stats.failed += 1;
        xhci.disableSlot(slot);
    };
}

fn removeDeviceAt(index: usize) void {
    if (index >= devices.len or !devices[index].present) return;
    const dev = &devices[index];
    if (dev.input_index) |input_index| input.releaseDevice(input_index);
    if (dev.hub != null) {
        // Children of a removed hub are gone too; each holds a slot.
        var i: usize = 0;
        while (i < devices.len) : (i += 1) {
            if (i == index or !devices[i].present) continue;
            if (devices[i].depth <= dev.depth) continue;
            if (devices[i].root_port != dev.root_port) continue;
            if (isDescendant(dev, &devices[i])) removeDeviceAt(i);
        }
    }
    klog.info("usb", "slot {d} removed: {s}", .{ dev.slot, dev.nameSlice() });
    xhci.disableSlot(dev.slot);
    dev.* = .{};
    stats.removed += 1;
}

fn isDescendant(parent: *const Device, child: *const Device) bool {
    if (child.depth != parent.depth + 1) return false;
    const shift: u5 = @intCast(4 * parent.depth);
    if (shift >= 32) return false;
    const mask = (@as(u32, 1) << shift) - 1;
    return (child.route & mask) == parent.route;
}

fn removeBySlot(slot: u8) void {
    for (&devices, 0..) |*d, i| {
        if (d.present and d.slot == slot) {
            removeDeviceAt(i);
            return;
        }
    }
}

fn removeByRootPort(port: u8) void {
    var i: usize = 0;
    while (i < devices.len) : (i += 1) {
        if (devices[i].present and devices[i].root_port == port and devices[i].depth == 0) removeDeviceAt(i);
    }
}

// ---------------------------------------------------------------------------
// HID reports
// ---------------------------------------------------------------------------

fn handleHidReport(dev: *Device, h: *HidState, report: []const u8) void {
    var readings: [hid.max_fields]hid.Reading = undefined;
    const n = hid.decode(&h.layout, report, &readings);
    if (n == 0) return;
    if (h.keyboard) decodeKeyboard(dev, h, readings[0..n]);
    if (h.pointer) decodePointer(dev, h, readings[0..n]);
}

fn containsKey(list: []const u16, usage: u16) bool {
    for (list) |entry| {
        if (entry == usage) return true;
    }
    return false;
}

fn decodeKeyboard(dev: *Device, h: *HidState, readings: []const hid.Reading) void {
    const index = dev.input_index orelse return;
    var keys: [10]u16 = [_]u16{0} ** 10;
    var key_count: usize = 0;
    var mods: u8 = 0;

    for (readings) |r| {
        if (r.field.usage_page != 0x07) continue;
        if (r.field.is_array) {
            if (r.value <= 0 or r.value > 0xFF) continue;
            const usage: u16 = @intCast(r.value);
            if (usage >= 0xE0 and usage <= 0xE7) {
                mods |= @as(u8, 1) << @intCast(usage - 0xE0);
                continue;
            }
            if (usage < 0x04) continue;
            if (key_count < keys.len and !containsKey(keys[0..key_count], usage)) {
                keys[key_count] = usage;
                key_count += 1;
            }
        } else {
            if (r.field.usage >= 0xE0 and r.field.usage <= 0xE7) {
                if (r.value != 0) mods |= @as(u8, 1) << @intCast(r.field.usage - 0xE0);
            } else if (r.value != 0 and r.field.usage >= 0x04) {
                if (key_count < keys.len and !containsKey(keys[0..key_count], r.field.usage)) {
                    keys[key_count] = r.field.usage;
                    key_count += 1;
                }
            }
        }
    }

    // Caps/num lock are ordinary keys in the array, but the input core needs
    // their state folded into every following character.
    if (containsKey(keys[0..key_count], 0x39) and !containsKey(h.prev_keys[0..h.prev_count], 0x39)) h.caps = !h.caps;
    if (containsKey(keys[0..key_count], 0x53) and !containsKey(h.prev_keys[0..h.prev_count], 0x53)) h.num = !h.num;

    var bits: u8 = 0;
    if (mods & 0x22 != 0) bits |= 1; // shift
    if (mods & 0x11 != 0) bits |= 2; // control
    if (mods & 0x44 != 0) bits |= 4; // alt
    if (mods & 0x88 != 0) bits |= 8; // meta
    if (h.caps) bits |= 16;
    if (h.num) bits |= 32;

    // Modifier transitions first (so a release is seen before the letter it
    // modified is released), then key releases, then presses.
    const changed_mods = bits ^ h.mod_bits;
    if (changed_mods != 0) {
        var bit: u3 = 0;
        while (bit < 8) : (bit += 1) {
            const mask = @as(u8, 1) << bit;
            if (changed_mods & mask == 0) continue;
            const usage: u8 = 0xE0 + @as(u8, bit);
            const evdev = keymap.hidUsageToEvdev(usage);
            if (evdev != 0) {
                input.keyEvent(index, evdev, bits & mask != 0, bits);
                h.key_events += 1;
                stats.key_events += 1;
            }
        }
    }
    h.mod_bits = bits;

    for (h.prev_keys[0..h.prev_count]) |usage| {
        if (usage == 0 or containsKey(keys[0..key_count], usage)) continue;
        if (usage >= 0xE0 and usage <= 0xE7) continue;
        const evdev = keymap.hidUsageToEvdev(@truncate(usage));
        if (evdev != 0) {
            input.keyEvent(index, evdev, false, bits);
            h.key_events += 1;
            stats.key_events += 1;
        }
    }
    for (keys[0..key_count]) |usage| {
        if (usage == 0 or containsKey(h.prev_keys[0..h.prev_count], usage)) continue;
        if (usage >= 0xE0 and usage <= 0xE7) continue;
        const evdev = keymap.hidUsageToEvdev(@truncate(usage));
        if (evdev != 0) {
            input.keyEvent(index, evdev, true, bits);
            h.key_events += 1;
            stats.key_events += 1;
        }
    }

    h.prev_keys = [_]u16{0} ** 10;
    for (keys[0..key_count], 0..) |usage, i| h.prev_keys[i] = usage;
    h.prev_count = key_count;
}

fn scaleAxis(value: i32, min: i32, max: i32, target: i32) i32 {
    if (max <= min or target <= 0) return 0;
    const span = @as(i64, max) - @as(i64, min);
    const scaled = @divTrunc((@as(i64, value) - @as(i64, min)) * @as(i64, target), span);
    return @intCast(std.math.clamp(scaled, 0, target));
}

fn decodePointer(dev: *Device, h: *HidState, readings: []const hid.Reading) void {
    const index = dev.input_index orelse return;
    const size = screenSize();
    var have_axis = false;
    var have_buttons = false;
    var buttons: u8 = h.buttons;
    var wheel: i32 = 0;

    for (readings) |r| {
        if (r.field.usage_page == 0x09 and r.field.usage >= 1 and r.field.usage <= 8) {
            const mask = @as(u8, 1) << @intCast(r.field.usage - 1);
            if (r.value != 0) buttons |= mask else buttons &= ~mask;
            have_buttons = true;
        } else if (r.field.usage_page == 0x01 and r.field.usage == 0x30) {
            if (r.field.is_relative) {
                h.x += r.value;
            } else {
                h.x = scaleAxis(r.value, r.field.logical_min, r.field.logical_max, size.width - 1);
            }
            have_axis = true;
        } else if (r.field.usage_page == 0x01 and r.field.usage == 0x31) {
            if (r.field.is_relative) {
                h.y += r.value;
            } else {
                h.y = scaleAxis(r.value, r.field.logical_min, r.field.logical_max, size.height - 1);
            }
            have_axis = true;
        } else if (r.field.usage_page == 0x01 and r.field.usage == 0x38) {
            wheel += r.value;
        }
    }

    h.x = std.math.clamp(h.x, 0, size.width - 1);
    h.y = std.math.clamp(h.y, 0, size.height - 1);

    if (have_buttons) {
        const changed = buttons ^ h.buttons;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask = @as(u8, 1) << @intCast(bit);
            if (changed & mask == 0) continue;
            input.buttonEvent(index, bit + 1, buttons & mask != 0);
            h.key_events += 0;
        }
        h.buttons = buttons;
        h.pointer_events += 1;
        stats.pointer_events += 1;
    }
    if (have_axis or have_buttons) {
        input.pointerMove(index, h.x, h.y, h.buttons);
        h.pointer_events += 1;
        stats.pointer_events += 1;
    }
    if (wheel != 0) {
        input.scrollEvent(index, 0, wheel);
        stats.pointer_events += 1;
        h.pointer_events += 1;
    }
}

// ---------------------------------------------------------------------------
// Hubs
// ---------------------------------------------------------------------------

fn clearPortChange(hub: *Device, port: u8, feature: u16) void {
    var empty: [0]u8 = .{};
    _ = control(hub.slot, usb.portFeatureRequest(feature, port, false), empty[0..]) catch {};
}

fn pollHub(hub: *Device) void {
    const h = if (hub.hub) |*state| state else return;
    if (nowMs() < h.next_poll_ms) return;
    h.next_poll_ms = nowMs() + 200;
    h.polls += 1;
    stats.hub_scans += 1;

    var port: u8 = 1;
    while (port <= h.ports) : (port += 1) {
        var buf: [4]u8 = undefined;
        const got = control(hub.slot, usb.getPortStatus(port), buf[0..]) catch continue;
        if (got < 4) continue;
        const status = usb.PortStatus.parse(buf[0..got]) catch continue;

        if (status.change_connection) {
            clearPortChange(hub, port, usb.port_feature_c_port_connection);
            if (!status.connected) {
                h.disconnects += 1;
                stats.hub_disconnects += 1;
                var i: usize = 0;
                while (i < devices.len) : (i += 1) {
                    if (!devices[i].present) continue;
                    if (devices[i].depth != hub.depth + 1) continue;
                    if (devices[i].root_port != hub.root_port) continue;
                    if (!isDescendant(hub, &devices[i])) continue;
                    // Only the port this change is about.
                    const shift: u5 = @intCast(4 * hub.depth);
                    if (((devices[i].route >> shift) & 0xF) == port) {
                        removeDeviceAt(i);
                        break;
                    }
                }
                continue;
            }

            // Reset the downstream port, then let it settle at U0.
            var empty: [0]u8 = .{};
            _ = control(hub.slot, usb.portFeatureRequest(usb.port_feature_reset, port, true), empty[0..]) catch continue;
            delayMs(50);
            var reset_done = false;
            var tries: usize = 0;
            while (tries < 20) : (tries += 1) {
                var s_buf: [4]u8 = undefined;
                const n = control(hub.slot, usb.getPortStatus(port), s_buf[0..]) catch break;
                if (n < 4) break;
                const s = usb.PortStatus.parse(s_buf[0..n]) catch break;
                if (!s.reset) {
                    reset_done = true;
                    break;
                }
                delayMs(10);
            }
            clearPortChange(hub, port, usb.port_feature_c_port_reset);
            if (!reset_done) {
                klog.warn("usb", "hub slot {d} port {d}: reset did not finish", .{ hub.slot, port });
                continue;
            }

            var final_buf: [4]u8 = undefined;
            const n = control(hub.slot, usb.getPortStatus(port), final_buf[0..]) catch continue;
            if (n < 4) continue;
            const final = usb.PortStatus.parse(final_buf[0..n]) catch continue;
            if (!final.connected or !final.enabled) continue;
            const speed: xhci.Speed = if (final.low_speed) .low else if (final.high_speed) .high else .full;

            const depth = hub.depth + 1;
            if (depth > 4) continue;
            const shift: u5 = @intCast(4 * hub.depth);
            const route = hub.route | (@as(u32, port) << shift);
            const slot = xhci.enableSlot() catch continue;
            const cfg = xhci.AddressConfig{
                .route = route,
                .root_port = hub.root_port,
                .speed = speed,
                .depth = depth,
            };
            xhci.addressDevice(slot, cfg) catch {
                xhci.disableSlot(slot);
                continue;
            };
            enumerateSlot(slot, cfg, hub.root_port) catch {
                xhci.disableSlot(slot);
                continue;
            };
            h.connects += 1;
            h.child_count += 1;
            stats.hub_connects += 1;
        }
    }
}

fn pollHubs() void {
    for (&devices) |*d| {
        if (d.present and d.hub != null) pollHub(d);
    }
}

// ---------------------------------------------------------------------------
// Public polling / reporting
// ---------------------------------------------------------------------------

pub fn poll() void {
    if (!initialized) return;
    xhci.poll();
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const change = xhci.takePortChange() orelse break;
        if (change.connected) {
            enumerateRoot(change.port, change.speed);
        } else if (change.slot != 0) {
            removeBySlot(change.slot);
        } else {
            removeByRootPort(change.port);
        }
    }
    pollHubs();
}

pub fn describe(write: anytype) void {
    xhci.describe(write);
    write("  usb devices  : {d}/{d} attached\n", .{ deviceCount(), max_devices });
    for (&devices, 0..) |*d, i| {
        if (!d.present) continue;
        write("  usb {d}        : {s} [{s}] {x:0>4}:{x:0>4} slot {d} port {d} {s}", .{
            i, d.nameSlice(), @tagName(d.kind), d.vendor, d.product, d.slot, d.root_port, @tagName(d.speed),
        });
        if (d.hid) |*h| {
            write(", iface {d}, ep {d}, {d} field(s), {d} reports", .{
                h.interface, h.ep_in, h.layout.count, h.reports,
            });
        }
        if (d.cdc) |*c| {
            write(", {s} bulk in {d} out {d}, {d} tx, {d} rx", .{
                if (c.cdc) "CDC-ACM" else "FTDI", c.bulk_in, c.bulk_out, c.tx_bytes, c.rx_bytes,
            });
        }
        if (d.hub) |*h| {
            write(", hub {d} ports, {d} child(ren)", .{ h.ports, h.child_count });
        }
        write("\n", .{});
    }
    if (deviceCount() == 0) write("  usb devices  : none (controller {s})\n", .{if (xhci.presentController()) "present" else "absent"});
}

pub fn statsSnapshot() Stats {
    return stats;
}

pub fn hidDeviceCount() usize {
    var n: usize = 0;
    for (&devices) |*d| {
        if (d.present and d.hid != null) n += 1;
    }
    return n;
}

pub fn serialCount() usize {
    var n: usize = 0;
    for (&devices) |*d| {
        if (d.present and d.cdc != null) n += 1;
    }
    return n;
}

pub fn serialAt(n: usize) ?*Device {
    var seen: usize = 0;
    for (&devices) |*d| {
        if (!d.present or d.cdc == null) continue;
        if (seen == n) return d;
        seen += 1;
    }
    return null;
}

pub fn serialSend(dev: *Device, bytes: []const u8) !usize {
    if (!dev.present) return error.NoDevice;
    const c = if (dev.cdc) |*state| state else return error.NoDevice;
    if (!c.configured) return error.NotConfigured;
    const sent = try xhci.bulkTransfer(dev.slot, c.bulk_out, @constCast(bytes), false);
    c.tx_bytes += sent;
    stats.serial_tx += sent;
    return sent;
}

pub fn serialRead(dev: *Device, out: []u8) !usize {
    if (!dev.present) return error.NoDevice;
    const c = if (dev.cdc) |*state| state else return error.NoDevice;
    if (!c.configured) return error.NotConfigured;
    var raw: [256]u8 = undefined;
    const want = @min(out.len + 2, raw.len);
    const got = try xhci.bulkTransferTimeout(dev.slot, c.bulk_in, raw[0..want], true, 200);
    // QEMU's and real FTDI bridges prepend two modem-status bytes to bulk-IN
    // data; CDC-ACM endpoints do not. Return only UART payload to the caller.
    const payload = if (c.cdc) raw[0..got] else usb.ftdiPayload(raw[0..got]);
    const n = @min(payload.len, out.len);
    @memcpy(out[0..n], payload[0..n]);
    c.rx_bytes += n;
    stats.serial_rx += n;
    return n;
}

/// Boot/self-test: with no controller this is a pass (a till without USB is a
/// valid configuration); with one, every enumerated device is checked for the
/// pieces its class driver needs.
pub fn selfTest(write: anytype) bool {
    var ok = true;
    if (!xhci.presentController()) {
        write("  usb selftest : no xHCI controller in this machine (expected on the no-USB boot)\n", .{});
        return true;
    }
    write("  usb selftest : controller present, {d} device(s)\n", .{deviceCount()});
    for (&devices, 0..) |*d, i| {
        if (!d.present) continue;
        var healthy = true;
        if (d.hid) |*h| {
            if (h.layout.count == 0) healthy = false;
            if (h.keyboard and !hid.hasPage(&h.layout, 0x07)) healthy = false;
            if (h.pointer and !hid.hasUsage(&h.layout, 0x01, 0x30)) healthy = false;
            if (h.ep_in == 0) healthy = false;
        } else if (d.cdc) |*c| {
            if (c.bulk_in == 0 or c.bulk_out == 0) healthy = false;
        } else if (d.hub) |*h| {
            if (h.ports == 0) healthy = false;
        } else {
            healthy = false; // enumerated but no class driver bound
        }
        write("  usb device {d}  : {s} [{s}] {s}\n", .{ i, d.nameSlice(), @tagName(d.kind), if (healthy) "PASS" else "FAIL" });
        if (!healthy) ok = false;
    }
    write("  usb selftest : {s}\n", .{if (ok) "PASS" else "FAIL"});
    return ok;
}

pub fn dumpInputBinding(write: anytype) void {
    for (&devices, 0..) |*d, i| {
        if (!d.present) continue;
        if (d.input_index) |index| {
            write("  usb {d} -> input {d}: {s}\n", .{ i, index, d.nameSlice() });
        }
    }
}
