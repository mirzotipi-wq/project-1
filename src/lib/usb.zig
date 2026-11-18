//! USB protocol types and descriptor parsing (phase 39).
//!
//! Nothing here touches hardware: these are the byte layouts a host controller
//! driver feeds in, and the decisions (which interface is a keyboard, where the
//! endpoints are, how long the report descriptor is) are made on ordinary
//! slices so they can be tested without a cable.
//!
//! The parser is deliberately strict. A configuration descriptor that claims to
//! be longer than the bytes received, an interface that names an endpoint twice,
//! or a descriptor whose length is zero is an error rather than a guess: a POS
//! terminal that enumerates half a keyboard is worse than one that reports it.

const std = @import("std");

pub const max_endpoints = 8;
pub const max_interfaces = 6;
pub const max_config_bytes = 1024;

pub const descriptor_device: u8 = 0x01;
pub const descriptor_configuration: u8 = 0x02;
pub const descriptor_string: u8 = 0x03;
pub const descriptor_interface: u8 = 0x04;
pub const descriptor_endpoint: u8 = 0x05;
pub const descriptor_device_qualifier: u8 = 0x06;
pub const descriptor_other_speed: u8 = 0x07;
pub const descriptor_hid: u8 = 0x21;
pub const descriptor_report: u8 = 0x22;
pub const descriptor_hub: u8 = 0x29;

pub const class_hid: u8 = 0x03;
pub const subclass_boot: u8 = 0x01;
pub const protocol_keyboard: u8 = 0x01;
pub const protocol_mouse: u8 = 0x02;

pub const class_comm: u8 = 0x02;
pub const class_cdc_data: u8 = 0x0A;
pub const class_hub: u8 = 0x09;

pub const cdc_subclass_acm: u8 = 0x02;
pub const cdc_protocol_at: u8 = 0x01;

pub const TransferKind = enum { control, isochronous, bulk, interrupt };

fn le16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | @as(u16, bytes[at + 1]) << 8;
}

fn le32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) | @as(u32, bytes[at + 1]) << 8 |
        @as(u32, bytes[at + 2]) << 16 | @as(u32, bytes[at + 3]) << 24;
}

pub const Error = error{
    Truncated,
    BadDescriptor,
    TooManyInterfaces,
    TooManyEndpoints,
    NoConfiguration,
};

pub const Setup = struct {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,

    pub fn bytes(self: Setup) [8]u8 {
        var out: [8]u8 = undefined;
        out[0] = self.request_type;
        out[1] = self.request;
        std.mem.writeInt(u16, out[2..4], self.value, .little);
        std.mem.writeInt(u16, out[4..6], self.index, .little);
        std.mem.writeInt(u16, out[6..8], self.length, .little);
        return out;
    }
};

pub const direction_in: u8 = 0x80;
pub const type_standard: u8 = 0x00;
pub const type_class: u8 = 0x20;
pub const type_vendor: u8 = 0x40;
pub const recipient_device: u8 = 0x00;
pub const recipient_interface: u8 = 0x01;
pub const recipient_endpoint: u8 = 0x02;
pub const recipient_other: u8 = 0x03;

pub const request_get_status: u8 = 0x00;
pub const request_clear_feature: u8 = 0x01;
pub const request_set_feature: u8 = 0x03;
pub const request_set_address: u8 = 0x05;
pub const request_get_descriptor: u8 = 0x06;
pub const request_set_descriptor: u8 = 0x07;
pub const request_get_configuration: u8 = 0x08;
pub const request_set_configuration: u8 = 0x09;
pub const request_get_interface: u8 = 0x0A;
pub const request_set_interface: u8 = 0x0B;

pub fn getDescriptor(desc_type: u8, index: u16, length: u16) Setup {
    return .{
        .request_type = direction_in | type_standard | recipient_device,
        .request = request_get_descriptor,
        .value = @as(u16, desc_type) << 8 | @as(u8, @truncate(index)),
        .index = 0,
        .length = length,
    };
}

pub fn setConfiguration(value: u8) Setup {
    return .{
        .request_type = type_standard | recipient_device,
        .request = request_set_configuration,
        .value = value,
        .index = 0,
        .length = 0,
    };
}

pub fn setInterface(interface: u8, alternate: u8) Setup {
    return .{
        .request_type = type_standard | recipient_interface,
        .request = request_set_interface,
        .value = alternate,
        .index = interface,
        .length = 0,
    };
}

pub fn setFeature(feature: u16) Setup {
    return .{
        .request_type = type_standard | recipient_device,
        .request = request_set_feature,
        .value = feature,
        .index = 0,
        .length = 0,
    };
}

pub fn clearFeature(feature: u16) Setup {
    return .{
        .request_type = type_standard | recipient_device,
        .request = request_clear_feature,
        .value = feature,
        .index = 0,
        .length = 0,
    };
}

pub fn getHubDescriptor(length: u16) Setup {
    return .{
        .request_type = direction_in | type_class | recipient_device,
        .request = request_get_descriptor,
        .value = @as(u16, descriptor_hub) << 8,
        .index = 0,
        .length = length,
    };
}

pub const DeviceDescriptor = struct {
    usb_version: u16 = 0,
    class: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,
    max_packet0: u8 = 8,
    vendor: u16 = 0,
    product: u16 = 0,
    release: u16 = 0,
    manufacturer_index: u8 = 0,
    product_index: u8 = 0,
    serial_index: u8 = 0,
    configurations: u8 = 1,

    pub fn parse(bytes: []const u8) Error!DeviceDescriptor {
        if (bytes.len < 18) return Error.Truncated;
        if (bytes[0] < 18 or bytes[1] != descriptor_device) return Error.BadDescriptor;
        return .{
            .usb_version = le16(bytes, 2),
            .class = bytes[4],
            .subclass = bytes[5],
            .protocol = bytes[6],
            .max_packet0 = bytes[7],
            .vendor = le16(bytes, 8),
            .product = le16(bytes, 10),
            .release = le16(bytes, 12),
            .manufacturer_index = bytes[14],
            .product_index = bytes[15],
            .serial_index = bytes[16],
            .configurations = bytes[17],
        };
    }
};

pub const Endpoint = struct {
    address: u8 = 0,
    attributes: u8 = 0,
    max_packet: u16 = 0,
    interval: u8 = 0,
    /// wMaxPacketSize bits 11..12: additional transactions per microframe.
    transactions: u8 = 0,

    pub fn number(self: Endpoint) u8 {
        return self.address & 0x0F;
    }

    pub fn isIn(self: Endpoint) bool {
        return self.address & 0x80 != 0;
    }

    pub fn kind(self: Endpoint) TransferKind {
        return switch (self.attributes & 0x03) {
            0 => .control,
            1 => .isochronous,
            2 => .bulk,
            else => .interrupt,
        };
    }

    pub fn maxBurst(self: Endpoint) u8 {
        return @truncate(self.attributes >> 4);
    }

    /// The endpoint context ID xHCI uses: direction bit plus endpoint number.
    pub fn dci(self: Endpoint) u5 {
        const ep_number = self.number();
        const direction: u5 = if (self.isIn()) 1 else 0;
        return @as(u5, @intCast(ep_number)) * 2 + direction;
    }
};

pub const Interface = struct {
    number: u8 = 0,
    alternate: u8 = 0,
    class: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,
    endpoints: [max_endpoints]Endpoint = [_]Endpoint{.{}} ** max_endpoints,
    endpoint_count: u8 = 0,
    /// First HID descriptor's report length and descriptor type, when present.
    hid_report_length: u16 = 0,
    hid_country: u8 = 0,

    pub fn isBootKeyboard(self: Interface) bool {
        return self.class == class_hid and self.subclass == subclass_boot and self.protocol == protocol_keyboard;
    }

    pub fn isBootMouse(self: Interface) bool {
        return self.class == class_hid and self.subclass == subclass_boot and self.protocol == protocol_mouse;
    }

    pub fn isHid(self: Interface) bool {
        return self.class == class_hid;
    }

    pub fn isCdcAcm(self: Interface) bool {
        return self.class == class_comm and self.subclass == cdc_subclass_acm;
    }

    pub fn isHub(self: Interface) bool {
        return self.class == class_hub;
    }

    pub fn endpointsSlice(self: *const Interface) []const Endpoint {
        return self.endpoints[0..self.endpoint_count];
    }

    pub fn firstOf(self: *const Interface, kind: TransferKind, in: bool) ?Endpoint {
        for (self.endpoints[0..self.endpoint_count]) |ep| {
            if (ep.kind() == kind and ep.isIn() == in) return ep;
        }
        return null;
    }
};

pub const Configuration = struct {
    total_length: u16 = 0,
    value: u8 = 1,
    attributes: u8 = 0,
    max_power: u8 = 0,
    interfaces: [max_interfaces]Interface = [_]Interface{.{}} ** max_interfaces,
    interface_count: u8 = 0,

    pub fn interfacesSlice(self: *const Configuration) []const Interface {
        return self.interfaces[0..self.interface_count];
    }

    /// The interface a class driver should bind: alternate setting 0 with the
    /// requested class, falling back to any alternate when 0 has no endpoints.
    pub fn findInterface(self: *const Configuration, class: u8, subclass: ?u8) ?*const Interface {
        for (self.interfaces[0..self.interface_count]) |*iface| {
            if (iface.alternate != 0) continue;
            if (iface.class != class) continue;
            if (subclass) |sub| {
                if (iface.subclass != sub) continue;
            }
            return iface;
        }
        return null;
    }
};

/// Walk a configuration descriptor and everything it contains. Endpoint
/// descriptors attach to the interface that precedes them, and a HID
/// descriptor attaches its report length to the same interface.
pub fn parseConfiguration(bytes: []const u8) Error!Configuration {
    if (bytes.len < 9) return Error.Truncated;
    if (bytes[0] < 9 or bytes[1] != descriptor_configuration) return Error.BadDescriptor;
    var config = Configuration{
        .total_length = le16(bytes, 2),
        .value = bytes[5],
        .attributes = bytes[7],
        .max_power = bytes[8],
    };
    if (config.total_length < 9) return Error.BadDescriptor;
    if (config.total_length > bytes.len) return Error.Truncated;

    var offset: usize = 0;
    while (offset + 2 <= config.total_length) {
        const length = bytes[offset];
        const desc_type = bytes[offset + 1];
        if (length < 2) return Error.BadDescriptor;
        if (offset + length > config.total_length) return Error.Truncated;

        switch (desc_type) {
            descriptor_interface => {
                if (length < 9) return Error.BadDescriptor;
                if (config.interface_count >= max_interfaces) return Error.TooManyInterfaces;
                const iface = Interface{
                    .number = bytes[offset + 2],
                    .alternate = bytes[offset + 3],
                    .class = bytes[offset + 5],
                    .subclass = bytes[offset + 6],
                    .protocol = bytes[offset + 7],
                };
                if (iface.number > 31) return Error.BadDescriptor;
                config.interfaces[config.interface_count] = iface;
                config.interface_count += 1;
            },
            descriptor_endpoint => {
                if (length < 7) return Error.BadDescriptor;
                if (config.interface_count == 0) return Error.BadDescriptor;
                const iface = &config.interfaces[config.interface_count - 1];
                if (iface.endpoint_count >= max_endpoints) return Error.TooManyEndpoints;
                const raw_packet = le16(bytes, offset + 4);
                const ep = Endpoint{
                    .address = bytes[offset + 2],
                    .attributes = bytes[offset + 3],
                    .max_packet = raw_packet & 0x07FF,
                    .transactions = @truncate((raw_packet >> 11) & 0x03),
                    .interval = bytes[offset + 6],
                };
                if (ep.number() == 0) return Error.BadDescriptor;
                for (iface.endpoints[0..iface.endpoint_count]) |seen| {
                    if (seen.address == ep.address) return Error.BadDescriptor;
                }
                iface.endpoints[iface.endpoint_count] = ep;
                iface.endpoint_count += 1;
            },
            descriptor_hid => {
                if (length < 9) return Error.BadDescriptor;
                if (config.interface_count == 0) return Error.BadDescriptor;
                const iface = &config.interfaces[config.interface_count - 1];
                iface.hid_report_length = le16(bytes, offset + 7);
                iface.hid_country = bytes[offset + 8];
            },
            else => {},
        }
        offset += length;
    }
    if (config.interface_count == 0) return Error.NoConfiguration;
    return config;
}

/// String descriptors are UTF-16LE after the two-byte header. Control
/// characters and anything outside ASCII are replaced with '?': the console is
/// a 5x7 font, and a terminal name is not the place to invent glyphs.
pub fn parseString(bytes: []const u8, out: []u8) Error![]const u8 {
    if (bytes.len < 2) return Error.Truncated;
    if (bytes[0] < 2 or bytes[1] != descriptor_string) return Error.BadDescriptor;
    const count = @min((bytes[0] - 2) / 2, out.len);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const code = le16(bytes, 2 + i * 2);
        out[i] = if (code >= 0x20 and code < 0x7F) @truncate(code) else '?';
    }
    return out[0..count];
}

/// FTDI bulk-IN packets may carry a two-byte modem-status header before the
/// UART payload. Strip it only when those bytes really are the status header:
/// a zero-length packet has nothing to strip.
pub fn ftdiPayload(bytes: []const u8) []const u8 {
    if (bytes.len < 2) return bytes[0..0];
    return bytes[2..];
}

pub const HubDescriptor = struct {
    ports: u8 = 0,
    characteristics: u16 = 0,
    power_on_delay_ms: u8 = 0,
    current_ma: u8 = 0,

    pub fn parse(bytes: []const u8) Error!HubDescriptor {
        if (bytes.len < 9) return Error.Truncated;
        if (bytes[1] != descriptor_hub) return Error.BadDescriptor;
        if (bytes[0] < 9) return Error.BadDescriptor;
        return .{
            .ports = bytes[2],
            .characteristics = le16(bytes, 3),
            .power_on_delay_ms = bytes[5],
            .current_ma = bytes[6],
        };
    }
};

/// Hub port status as the hub class reports it (USB 2.0, 11.24.2).
pub const PortStatus = struct {
    connected: bool = false,
    enabled: bool = false,
    suspended: bool = false,
    over_current: bool = false,
    reset: bool = false,
    powered: bool = false,
    low_speed: bool = false,
    high_speed: bool = false,
    change_connection: bool = false,
    change_enable: bool = false,
    change_suspend: bool = false,
    change_over_current: bool = false,
    change_reset: bool = false,

    pub fn parse(bytes: []const u8) Error!PortStatus {
        if (bytes.len < 4) return Error.Truncated;
        const status = le16(bytes, 0);
        const change = le16(bytes, 2);
        return .{
            .connected = status & 0x0001 != 0,
            .enabled = status & 0x0002 != 0,
            .suspended = status & 0x0004 != 0,
            .over_current = status & 0x0008 != 0,
            .reset = status & 0x0010 != 0,
            .powered = status & 0x0100 != 0,
            .low_speed = status & 0x0200 != 0,
            .high_speed = status & 0x0400 != 0,
            .change_connection = change & 0x0001 != 0,
            .change_enable = change & 0x0002 != 0,
            .change_suspend = change & 0x0004 != 0,
            .change_over_current = change & 0x0008 != 0,
            .change_reset = change & 0x0010 != 0,
        };
    }
};

pub const port_feature_connection: u16 = 0;
pub const port_feature_enable: u16 = 1;
pub const port_feature_suspend: u16 = 2;
pub const port_feature_reset: u16 = 4;
pub const port_feature_power: u16 = 8;
pub const port_feature_low_speed: u16 = 9;
pub const port_feature_c_port_connection: u16 = 16;
pub const port_feature_c_port_enable: u16 = 17;
pub const port_feature_c_port_suspend: u16 = 18;
pub const port_feature_c_port_over_current: u16 = 19;
pub const port_feature_c_port_reset: u16 = 20;

/// Hub port features are addressed to the hub as a device (recipient other).
pub fn portFeatureRequest(feature: u16, port: u8, set: bool) Setup {
    return .{
        .request_type = type_class | recipient_other,
        .request = if (set) request_set_feature else request_clear_feature,
        .value = feature,
        .index = port,
        .length = 0,
    };
}

pub fn getPortStatus(port: u8) Setup {
    return .{
        .request_type = direction_in | type_class | recipient_other,
        .request = request_get_status,
        .value = 0,
        .index = port,
        .length = 4,
    };
}

pub const hid_set_idle: u8 = 0x0A;
pub const hid_set_protocol: u8 = 0x0B;

pub fn hidSetIdle(interface: u8, duration: u8) Setup {
    return .{
        .request_type = type_class | recipient_interface,
        .request = hid_set_idle,
        .value = @as(u16, duration) << 8,
        .index = interface,
        .length = 0,
    };
}

pub fn hidSetProtocol(interface: u8, protocol: u8) Setup {
    return .{
        .request_type = type_class | recipient_interface,
        .request = hid_set_protocol,
        .value = protocol,
        .index = interface,
        .length = 0,
    };
}

/// GET_DESCRIPTOR(report) is addressed to the HID interface, not the device.
pub fn getReportDescriptor(interface: u8, length: u16) Setup {
    return .{
        .request_type = direction_in | type_standard | recipient_interface,
        .request = request_get_descriptor,
        .value = @as(u16, descriptor_report) << 8,
        .index = interface,
        .length = length,
    };
}

pub const cdc_set_line_coding: u8 = 0x20;
pub const cdc_set_control_line_state: u8 = 0x22;

/// CDC-ACM class request: 115200 8N1 by default, in the terminal's own order.
pub fn cdcSetLineCoding(interface: u8, rate: u32, stop_bits: u8, parity: u8, data_bits: u8) struct { setup: Setup, data: [7]u8 } {
    var data: [7]u8 = undefined;
    data[0] = @truncate(rate);
    data[1] = @truncate(rate >> 8);
    data[2] = @truncate(rate >> 16);
    data[3] = @truncate(rate >> 24);
    data[4] = stop_bits;
    data[5] = parity;
    data[6] = data_bits;
    return .{
        .setup = .{
            .request_type = type_class | recipient_interface,
            .request = cdc_set_line_coding,
            .value = 0,
            .index = interface,
            .length = 7,
        },
        .data = data,
    };
}

pub fn cdcSetControlLineState(interface: u8, state: u16) Setup {
    return .{
        .request_type = type_class | recipient_interface,
        .request = cdc_set_control_line_state,
        .value = state,
        .index = interface,
        .length = 0,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleConfiguration() [34]u8 {
    var b: [34]u8 = [_]u8{0} ** 34;
    b[0] = 9;
    b[1] = descriptor_configuration;
    std.mem.writeInt(u16, b[2..4], 34, .little);
    b[5] = 1;
    b[7] = 0x80;
    b[8] = 50;

    b[9] = 9;
    b[10] = descriptor_interface;
    b[11] = 0; // interface 0
    b[13] = 1; // endpoints
    b[14] = class_hid;
    b[15] = subclass_boot;
    b[16] = protocol_keyboard;

    b[18] = 9;
    b[19] = descriptor_hid;
    var hid: [9]u8 = [_]u8{0} ** 9;
    hid[0] = 9;
    hid[1] = descriptor_hid;
    hid[5] = 1;
    hid[7] = 63; // report length
    @memcpy(b[18..27], &hid);

    b[27] = 7;
    b[28] = descriptor_endpoint;
    b[29] = 0x81; // IN 1
    b[30] = 0x03; // interrupt
    std.mem.writeInt(u16, b[31..33], 8, .little);
    b[33] = 10;
    return b;
}

test "a configuration walks interfaces, HID and endpoints" {
    const bytes = sampleConfiguration();
    const config = try parseConfiguration(&bytes);
    try testing.expectEqual(@as(u8, 1), config.interface_count);
    const iface = &config.interfaces[0];
    try testing.expect(iface.isBootKeyboard());
    try testing.expectEqual(@as(u16, 63), iface.hid_report_length);
    try testing.expectEqual(@as(u8, 1), iface.endpoint_count);
    const ep = iface.endpoints[0];
    try testing.expect(ep.isIn());
    try testing.expectEqual(@as(u5, 3), ep.dci());
    try testing.expectEqual(TransferKind.interrupt, ep.kind());
    try testing.expectEqual(@as(u16, 8), ep.max_packet);
}

test "a descriptor longer than the bytes received is refused" {
    var bytes = sampleConfiguration();
    std.mem.writeInt(u16, bytes[2..4], 60, .little);
    try testing.expectError(Error.Truncated, parseConfiguration(&bytes));
}

test "endpoint numbers are unique inside an interface" {
    var bytes = sampleConfiguration();
    // Second endpoint descriptor would have to fit; replace the first's address
    // with zero, which is not a valid endpoint descriptor.
    bytes[29] = 0x00;
    try testing.expectError(Error.BadDescriptor, parseConfiguration(&bytes));
}

test "a string descriptor is converted from UTF-16 little-endian" {
    var bytes = [_]u8{ 8, descriptor_string, 'A', 0, 'C', 0, 'M', 0 };
    var out: [8]u8 = undefined;
    const text = try parseString(&bytes, &out);
    try testing.expectEqualStrings("ACM", text);
}

test "a non-ASCII code point becomes a placeholder, not a stray byte" {
    var bytes = [_]u8{ 4, descriptor_string, 0x00, 0x30 };
    var out: [4]u8 = undefined;
    const text = try parseString(&bytes, &out);
    try testing.expectEqualStrings("?", text);
}

test "setup packets are little-endian on the wire" {
    const s = getDescriptor(descriptor_configuration, 0, 255);
    const b = s.bytes();
    try testing.expectEqual(@as(u8, 0x80), b[0]);
    try testing.expectEqual(@as(u8, 0x06), b[1]);
    try testing.expectEqual(@as(u8, 0x00), b[2]);
    try testing.expectEqual(@as(u8, 0x02), b[3]);
    try testing.expectEqual(@as(u8, 0xFF), b[6]);
    try testing.expectEqual(@as(u8, 0x00), b[7]);
}

test "hub descriptors and port status decode the class bits" {
    const hub = [_]u8{ 9, descriptor_hub, 8, 0, 0, 50, 0, 0, 0 };
    const h = try HubDescriptor.parse(&hub);
    try testing.expectEqual(@as(u8, 8), h.ports);
    try testing.expectEqual(@as(u8, 50), h.power_on_delay_ms);

    var status: [4]u8 = undefined;
    std.mem.writeInt(u16, status[0..2], 0x0103, .little); // connected, enabled, powered
    std.mem.writeInt(u16, status[2..4], 0x0001, .little); // connect change
    const port = try PortStatus.parse(&status);
    try testing.expect(port.connected and port.enabled and port.powered);
    try testing.expect(port.change_connection);
    try testing.expect(!port.high_speed);
}

test "an interface with no endpoints is still a valid interface" {
    var bytes: [18]u8 = [_]u8{0} ** 18;
    bytes[0] = 9;
    bytes[1] = descriptor_configuration;
    std.mem.writeInt(u16, bytes[2..4], 18, .little);
    bytes[5] = 1;
    bytes[9] = 9;
    bytes[10] = descriptor_interface;
    bytes[14] = 0xFF;
    const config = try parseConfiguration(&bytes);
    try testing.expectEqual(@as(u8, 1), config.interface_count);
    try testing.expectEqual(@as(u8, 0), config.interfaces[0].endpoint_count);
}

test "FTDI modem status header is stripped from serial payload" {
    const packet = [_]u8{ 0xb1, 0x00, 'h', 'i' };
    try testing.expectEqualStrings("hi", ftdiPayload(&packet));
    const short = [_]u8{ 0xb1, 0x00 };
    try testing.expectEqual(@as(usize, 0), ftdiPayload(&short).len);
    try testing.expectEqual(@as(usize, 0), ftdiPayload(&[_]u8{0x01}).len);
}
