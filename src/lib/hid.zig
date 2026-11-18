//! HID report descriptors and report decoding (phase 39).
//!
//! A USB keyboard is not "eight bytes, trust me": the device ships a report
//! descriptor that says where each usage lives, how wide it is, whether it is a
//! variable field or an array of key codes, and whether an axis is relative.
//! This module parses that descriptor into a flat field table and extracts the
//! fields from a report. It is the difference between a driver that works with
//! the one keyboard it was tested on and one that works with the scanner a shop
//! actually bought.
//!
//! Coverage is the retail set: keyboard modifier bits and key arrays, mouse and
//! tablet X/Y (relative or absolute, 8 or 16 bit), wheel, and buttons. Anything
//! else is parsed but reported as an unknown usage rather than guessed at.

const std = @import("std");

pub const max_fields = 48;
pub const max_usages = 16;
pub const max_report_bits = 4096;

pub const Error = error{
    Truncated,
    BadItem,
    TooManyFields,
    TooManyUsages,
    ReportTooLarge,
};

pub const ItemType = enum { main, global, local };

pub const Field = struct {
    report_id: u8 = 0,
    usage_page: u16 = 0,
    /// Base usage. For an array this is the lowest usage the values select.
    usage: u16 = 0,
    /// Highest usage, for a variable range or an array.
    usage_max: u16 = 0,
    bit_offset: u32 = 0,
    bit_size: u8 = 1,
    count: u8 = 1,
    is_array: bool = false,
    is_relative: bool = false,
    is_constant: bool = false,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
};

pub const Layout = struct {
    fields: [max_fields]Field = [_]Field{.{}} ** max_fields,
    count: usize = 0,
    has_report_ids: bool = false,
    /// Largest report (in bytes) the descriptor describes, including a report
    /// ID byte when the device uses them.
    max_report_bytes: u16 = 0,

    pub fn fieldsSlice(self: *const Layout) []const Field {
        return self.fields[0..self.count];
    }
};

const Global = struct {
    usage_page: u16 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    report_size: u8 = 0,
    report_count: u16 = 0,
    report_id: u8 = 0,
};

fn readItemData(bytes: []const u8, size: usize) u32 {
    var value: u32 = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        value |= @as(u32, bytes[i]) << @intCast(i * 8);
    }
    return value;
}

fn signedValue(value: u32, size: usize) i32 {
    return switch (size) {
        1 => @as(i8, @bitCast(@as(u8, @truncate(value)))),
        2 => @as(i16, @bitCast(@as(u16, @truncate(value)))),
        4 => @bitCast(value),
        else => @intCast(value),
    };
}

/// Parse a report descriptor into a field table.
pub fn parse(bytes: []const u8) Error!Layout {
    var layout = Layout{};
    var global = Global{};
    var stack: [4]Global = undefined;
    var stack_len: usize = 0;
    var usages: [max_usages]u16 = undefined;
    var usage_count: usize = 0;
    var usage_min: u16 = 0;
    var usage_max: u16 = 0;
    var has_range = false;
    var offsets: [256]u16 = [_]u16{0} ** 256;

    var offset: usize = 0;
    while (offset < bytes.len) {
        const prefix = bytes[offset];
        if (prefix == 0xFE) {
            // Long item: one-byte data size, one-byte tag, data.
            if (offset + 3 > bytes.len) return Error.Truncated;
            const data_len = bytes[offset + 1];
            if (offset + 3 + data_len > bytes.len) return Error.Truncated;
            offset += 3 + data_len;
            continue;
        }
        const size_code = prefix & 0x03;
        const size: usize = switch (size_code) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 4,
        };
        const item_type: ItemType = switch ((prefix >> 2) & 0x03) {
            0 => .main,
            1 => .global,
            2 => .local,
            else => .main, // reserved: skip it
        };
        const tag = prefix >> 4;
        if (offset + 1 + size > bytes.len) return Error.Truncated;
        const data = readItemData(bytes[offset + 1 ..], size);

        switch (item_type) {
            .global => switch (tag) {
                0x0 => global.usage_page = @truncate(data),
                0x1 => global.logical_min = signedValue(data, size),
                0x2 => global.logical_max = signedValue(data, size),
                0x7 => global.report_size = @truncate(data),
                0x8 => {
                    global.report_id = @truncate(data);
                    if (global.report_id != 0) layout.has_report_ids = true;
                },
                0x9 => global.report_count = @truncate(data),
                0xA => {
                    if (stack_len < stack.len) {
                        stack[stack_len] = global;
                        stack_len += 1;
                    }
                },
                0xB => {
                    if (stack_len > 0) {
                        stack_len -= 1;
                        global = stack[stack_len];
                    }
                },
                else => {},
            },
            .local => switch (tag) {
                0x0 => {
                    if (usage_count < max_usages) {
                        usages[usage_count] = @truncate(data);
                        usage_count += 1;
                    } else return Error.TooManyUsages;
                },
                0x1 => {
                    usage_min = @truncate(data);
                    has_range = true;
                },
                0x2 => {
                    usage_max = @truncate(data);
                    has_range = true;
                },
                else => {},
            },
            .main => {
                if (tag == 0x8) { // Input
                    try appendInput(&layout, &global, &offsets, usages[0..usage_count], usage_min, usage_max, has_range, @truncate(data));
                }
                usage_count = 0;
                usage_min = 0;
                usage_max = 0;
                has_range = false;
            },
        }
        offset += 1 + size;
    }
    return layout;
}

fn appendInput(
    layout: *Layout,
    global: *const Global,
    offsets: *[256]u16,
    usages: []const u16,
    usage_min: u16,
    usage_max: u16,
    has_range: bool,
    flags: u32,
) Error!void {
    const count: usize = if (global.report_count == 0) 1 else global.report_count;
    const bits: u32 = @as(u32, global.report_size) * @as(u32, @truncate(count));
    const id = global.report_id;
    const base_offset = offsets[id];
    const constant = flags & 0x01 != 0;
    const variable = flags & 0x02 != 0;
    const relative = flags & 0x04 != 0;

    if (!constant) {
        if (variable) {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var usage: u16 = 0;
                if (i < usages.len) {
                    usage = usages[i];
                } else if (has_range) {
                    usage = usage_min + @as(u16, @intCast(i));
                    if (usage > usage_max) usage = usage_max;
                } else if (usages.len > 0) {
                    usage = usages[usages.len - 1];
                }
                try appendField(layout, .{
                    .report_id = id,
                    .usage_page = global.usage_page,
                    .usage = usage,
                    .usage_max = usage,
                    .bit_offset = base_offset + @as(u32, global.report_size) * i,
                    .bit_size = global.report_size,
                    .count = 1,
                    .is_relative = relative,
                    .logical_min = global.logical_min,
                    .logical_max = global.logical_max,
                });
            }
        } else {
            try appendField(layout, .{
                .report_id = id,
                .usage_page = global.usage_page,
                .usage = if (has_range) usage_min else if (usages.len > 0) usages[0] else 0,
                .usage_max = if (has_range) usage_max else if (usages.len > 0) usages[usages.len - 1] else 0,
                .bit_offset = base_offset,
                .bit_size = global.report_size,
                .count = @truncate(count),
                .is_array = true,
                .logical_min = global.logical_min,
                .logical_max = global.logical_max,
            });
        }
    }

    offsets[id] = @intCast(@as(u32, base_offset) + bits);
    if (offsets[id] > max_report_bits) return Error.ReportTooLarge;
    const report_bytes: u16 = @intCast((@as(u32, offsets[id]) + 7) / 8 + @intFromBool(id != 0));
    if (report_bytes > layout.max_report_bytes) layout.max_report_bytes = report_bytes;
}

fn appendField(layout: *Layout, field: Field) Error!void {
    if (layout.count >= max_fields) return Error.TooManyFields;
    layout.fields[layout.count] = field;
    layout.count += 1;
}

/// One decoded field value.
pub const Reading = struct {
    field: *const Field,
    value: i32,
    /// Index inside a variable range or slot inside an array.
    index: u8 = 0,
};

fn extract(report: []const u8, offset: u32, bits: u8) ?u32 {
    if (bits == 0 or bits > 32) return null;
    const last_bit = offset + bits;
    if ((last_bit + 7) / 8 > report.len) return null;
    var value: u32 = 0;
    var i: u8 = 0;
    while (i < bits) : (i += 1) {
        const bit_index = offset + i;
        const byte = report[bit_index / 8];
        const bit: u8 = @intCast(bit_index % 8);
        if (byte & (@as(u8, 1) << @as(u3, @intCast(bit))) != 0) value |= @as(u32, 1) << @intCast(i);
    }
    return value;
}

fn signExtend(value: u32, bits: u8) i32 {
    if (bits >= 32) return @bitCast(value);
    const sign_bit = @as(u32, 1) << @intCast(bits - 1);
    if (value & sign_bit == 0) return @intCast(value);
    const mask = (@as(u32, 0xFFFF_FFFF) << @intCast(bits));
    return @bitCast(value | mask);
}

/// Extract every field for the report's ID. Array fields yield one reading per
/// slot, with the usage the slot selects in `field.usage_min + value`.
pub fn decode(layout: *const Layout, report: []const u8, out: *[max_fields]Reading) usize {
    if (report.len == 0) return 0;
    const id: u8 = if (layout.has_report_ids) report[0] else 0;
    const payload = if (layout.has_report_ids) report[1..] else report;
    var n: usize = 0;
    for (layout.fieldsSlice()) |*field| {
        if (field.report_id != id) continue;
        const raw = extract(payload, field.bit_offset, field.bit_size) orelse continue;
        if (field.is_array) {
            var slot: u8 = 0;
            while (slot < field.count) : (slot += 1) {
                const value = extract(payload, field.bit_offset + @as(u32, field.bit_size) * slot, field.bit_size) orelse break;
                if (n < out.len) {
                    out[n] = .{ .field = field, .value = @intCast(value), .index = slot };
                    n += 1;
                }
            }
        } else {
            const value = if (field.logical_min < 0) signExtend(raw, field.bit_size) else @as(i32, @intCast(raw));
            if (n < out.len) {
                out[n] = .{ .field = field, .value = value, .index = 0 };
                n += 1;
            }
        }
    }
    return n;
}

/// The first field on a page with a given usage. Used by class drivers that
/// want to know "is this a keyboard" before decoding a single report.
pub fn hasUsage(layout: *const Layout, page: u16, usage: u16) bool {
    for (layout.fieldsSlice()) |*field| {
        if (field.usage_page != page) continue;
        if (field.is_array) {
            if (usage >= field.usage and usage <= field.usage_max) return true;
        } else if (field.usage == usage or (field.usage_max > field.usage and usage >= field.usage and usage <= field.usage_max)) {
            return true;
        }
    }
    return false;
}

pub fn hasPage(layout: *const Layout, page: u16) bool {
    for (layout.fieldsSlice()) |*field| {
        if (field.usage_page == page) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn keyboardDescriptor() [45]u8 {
    return [_]u8{
        0x05, 0x01, // usage page (generic desktop)
        0x09, 0x06, // usage (keyboard)
        0xA1, 0x01, // collection (application)
        0x05, 0x07, // usage page (keyboard)
        0x19, 0xE0, // usage min (left ctrl)
        0x29, 0xE7, // usage max (right gui)
        0x15, 0x00, // logical min 0
        0x25, 0x01, // logical max 1
        0x75, 0x01, // report size 1
        0x95, 0x08, // report count 8
        0x81, 0x02, // input (data, variable, absolute)
        0x95, 0x01, // report count 1
        0x75, 0x08, // report size 8
        0x81, 0x01, // input (constant)
        0x95, 0x06, // report count 6
        0x75, 0x08, // report size 8
        0x15, 0x00, // logical min 0
        0x25, 0x65, // logical max 101
        0x05, 0x07, // usage page (keyboard)
        0x19, 0x00, // usage min 0
        0x29, 0x65, // usage max 101
        0x81, 0x00, // input (data, array)
        0xC0, // end collection
    };
}

test "a boot keyboard descriptor parses into modifiers and a key array" {
    const bytes = keyboardDescriptor();
    const layout = try parse(&bytes);
    try testing.expect(hasUsage(&layout, 0x07, 0x04));
    try testing.expectEqual(@as(u16, 8), layout.max_report_bytes);

    var report = [_]u8{0} ** 8;
    report[0] = 0x02; // left shift
    report[2] = 0x04; // 'a'
    report[3] = 0x05; // 'b'
    var readings: [max_fields]Reading = undefined;
    const n = decode(&layout, &report, &readings);
    try testing.expect(n >= 3);
    var saw_a = false;
    var saw_shift = false;
    for (readings[0..n]) |r| {
        if (r.field.is_array and r.value == 0x04) saw_a = true;
        if (!r.field.is_array and r.field.usage == 0xE1 and r.value == 1) saw_shift = true;
    }
    try testing.expect(saw_a);
    try testing.expect(saw_shift);
}

test "a relative mouse descriptor keeps signed motion and buttons" {
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x09, 0x01, 0xA1, 0x00, 0x05, 0x09,
        0x19, 0x01, 0x29, 0x03, 0x15, 0x00,
        0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
        0x81, 0x02, 0x95, 0x01, 0x75, 0x05,
        0x81, 0x01, 0x05, 0x01, 0x09, 0x30,
        0x09, 0x31, 0x09, 0x38, 0x15, 0x81,
        0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
        0x81, 0x06, 0xC0, 0xC0,
    };
    const layout = try parse(&bytes);
    var report = [_]u8{ 0x05, 0xFE, 0x02, 0xFF };
    var readings: [max_fields]Reading = undefined;
    const n = decode(&layout, &report, &readings);
    var x: ?i32 = null;
    var y: ?i32 = null;
    var buttons: u32 = 0;
    for (readings[0..n]) |r| {
        if (r.field.usage_page == 0x01 and r.field.usage == 0x30) x = r.value;
        if (r.field.usage_page == 0x01 and r.field.usage == 0x31) y = r.value;
        if (r.field.usage_page == 0x09 and r.value != 0) buttons |= @as(u32, 1) << @intCast(r.field.usage - 1);
    }
    try testing.expectEqual(@as(?i32, -2), x);
    try testing.expectEqual(@as(?i32, 2), y);
    try testing.expectEqual(@as(u32, 0x5), buttons);
}

test "absolute 16-bit axes keep their logical range" {
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x09, 0x01, 0xA1, 0x00, 0x05, 0x09,
        0x19, 0x01, 0x29, 0x01, 0x15, 0x00,
        0x25, 0x01, 0x95, 0x01, 0x75, 0x01,
        0x81, 0x02, 0x95, 0x07, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
        0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0xC0, 0xC0,
    };
    const layout = try parse(&bytes);
    var report = [_]u8{ 0x00, 0x00, 0x01, 0x00, 0x02 };
    var readings: [max_fields]Reading = undefined;
    const n = decode(&layout, &report, &readings);
    var x: ?i32 = null;
    var y: ?i32 = null;
    for (readings[0..n]) |r| {
        if (r.field.usage == 0x30) x = r.value;
        if (r.field.usage == 0x31) y = r.value;
    }
    try testing.expectEqual(@as(?i32, 256), x);
    try testing.expectEqual(@as(?i32, 512), y);
}

test "report IDs select their own field set and skip the ID byte" {
    const bytes = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, 0x01, // report id 1
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x01,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x01,
        0x81, 0x02,
        0x85, 0x02,
        0x05, 0x01,
        0x09, 0x30,
        0x15, 0x81,
        0x25, 0x7F,
        0x75, 0x08,
        0x95, 0x01,
        0x81, 0x06,
        0xC0,
    };
    const layout = try parse(&bytes);
    var readings: [max_fields]Reading = undefined;

    var button_report = [_]u8{ 0x01, 0x01 };
    var n = decode(&layout, &button_report, &readings);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 0x09), readings[0].field.usage_page);

    var axis_report = [_]u8{ 0x02, 0xFB };
    n = decode(&layout, &axis_report, &readings);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, -5), readings[0].value);
}

test "a truncated item is an error, not a short parse" {
    const bytes = [_]u8{ 0x05, 0x01, 0x09 };
    try testing.expectError(Error.Truncated, parse(&bytes));
}
