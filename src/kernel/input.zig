//! Input subsystem (phase 38): one ordered event stream for every HID source.
//!
//! Three problems are solved here, and nowhere else:
//!
//!   1. **One stream, one order.** A keyboard, a scanner and a touch panel all
//!      produce events on different interrupts. They are serialised through one
//!      IRQ-safe ring with a monotonic sequence number, so a consumer sees a
//!      total order and can never read half an event.
//!   2. **Bursts are atomic.** Character keys are routed through the scanner
//!      state machine (`lib/scanner.zig`); a retail scan becomes one `barcode`
//!      event with its latency, and its individual keystrokes are suppressed.
//!      A burst that is not a scan is released keystroke by keystroke, in order.
//!   3. **Typing still works.** Printable keys are also mirrored into a small
//!      console queue that the kernel shell reads, so the panel's keyboard
//!      types into the shell without the shell knowing anything about virtio.
//!
//! The ring is bounded and never grows: when a consumer falls behind, the
//! oldest event is dropped and counted (`dropped`), because a till must not
//! stall its interrupts to preserve stale motion. Dropping is visible in `input`
//! rather than silent.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const timer = @import("../arch/aarch64/timer.zig");
const keymap = @import("../lib/keymap.zig");
const scanner = @import("../lib/scanner.zig");
const klog = @import("klog.zig");
const sched = @import("sched.zig");

pub const ring_capacity = 256;
pub const recent_capacity = 16;
pub const max_devices = 4;
pub const max_text = 64;

pub const EventKind = enum(u8) {
    key,
    pointer,
    button,
    scroll,
    barcode,
    device,
};

/// One input event. Fixed size, so a future syscall can hand it to a POS
/// process unchanged.
pub const Event = struct {
    seq: u64 = 0,
    time_ms: u64 = 0,
    kind: EventKind = .key,
    device: u8 = 0,
    /// Key modifiers (keymap.Modifiers.bits) or the mouse button mask.
    flags: u8 = 0,
    /// evdev key code, button number, scroll axis, or device index.
    code: u16 = 0,
    /// 1/0 for press/release, x for pointer motion, barcode latency in ms.
    value: i32 = 0,
    /// y for pointer motion, barcode length.
    aux: i32 = 0,
    text: [max_text]u8 = [_]u8{0} ** max_text,
    text_len: u8 = 0,

    pub fn textSlice(self: *const Event) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const Stats = struct {
    pushed: u64 = 0,
    popped: u64 = 0,
    dropped: u64 = 0,
    high_water: usize = 0,
    keys: u64 = 0,
    pointers: u64 = 0,
    buttons: u64 = 0,
    scrolls: u64 = 0,
    barcodes: u64 = 0,
    characters: u64 = 0,
    wait_wakes: u64 = 0,
    console_dropped: u64 = 0,
    /// Milliseconds from decoding the committing suffix to pushing the barcode
    /// event: the part the OS adds, which the POS < 20 ms budget covers.
    delivery_last_ms: u32 = 0,
    delivery_max_ms: u32 = 0,
};

pub const DeviceKind = enum { keyboard, pointer, tablet, touch, unknown };

pub const Device = struct {
    name: [24]u8 = [_]u8{0} ** 24,
    name_len: usize = 0,
    kind: DeviceKind = .unknown,
    present: bool = false,
    events: u64 = 0,
    /// Absolute axis range, for touch/tablet devices.
    abs_min_x: i32 = 0,
    abs_max_x: i32 = 0,
    abs_min_y: i32 = 0,
    abs_max_y: i32 = 0,
    intid: u32 = 0,
    /// Interrupts seen, for the health line in `input`.
    irqs: u64 = 0,

    pub fn nameSlice(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }
};

var lock: sync.IrqSpinLock = .{};
var ring: [ring_capacity]Event = undefined;
var head: usize = 0;
var tail: usize = 0;
var count: usize = 0;
var next_seq: u64 = 1;

var recent: [recent_capacity]Event = undefined;
var recent_count: usize = 0;
var recent_next: usize = 0;

var stats: Stats = .{};
var devices: [max_devices]Device = [_]Device{.{}} ** max_devices;
var device_count: usize = 0;

/// Console mirror: printable characters and editing keys, in order.
const console_capacity = 128;
var console: [console_capacity]u8 = undefined;
var console_head: usize = 0;
var console_tail: usize = 0;
var console_count: usize = 0;

/// Barcode notices for the shell: a barcode event also leaves a short line here
/// so the console can print it without stealing the event from the POS queue.
const notice_capacity = 8;
pub const Notice = struct { text: [max_text]u8 = undefined, len: u8 = 0, latency_ms: u32 = 0 };
var notices: [notice_capacity]Notice = undefined;
var notice_head: usize = 0;
var notice_tail: usize = 0;
var notice_count: usize = 0;

var scanner_state: scanner.Scanner = .{};
var pending_codes: [scanner.max_payload + 8]u16 = [_]u16{0} ** (scanner.max_payload + 8);
var pending_len: usize = 0;

/// Monotonic milliseconds. On the target this is the generic timer; the host
/// test build has no system registers, so it reads a settable counter. The
/// `if (comptime ...)` keeps the `mrs` path out of the host binary entirely.
var host_now_ms: u64 = 0;

pub fn setClockForTest(ms: u64) void {
    host_now_ms = ms;
}

fn nowMs() u64 {
    if (comptime builtin.cpu.arch == .aarch64) return timer.uptimeMs();
    return host_now_ms;
}

pub fn init() void {
    const flags = lock.acquire();
    head = 0;
    tail = 0;
    count = 0;
    next_seq = 1;
    recent_count = 0;
    recent_next = 0;
    stats = .{};
    device_count = 0;
    console_head = 0;
    console_tail = 0;
    console_count = 0;
    notice_head = 0;
    notice_tail = 0;
    notice_count = 0;
    scanner_state.reset();
    pending_len = 0;
    lock.release(flags);
}

/// Clear counters and the pending scanner candidate. Devices stay registered:
/// this is the `input reset` debug switch, not a re-initialisation.
pub fn resetCounters() void {
    const flags = lock.acquire();
    stats = .{};
    scanner_state.reset();
    scanner_state.stats = .{};
    pending_len = 0;
    next_seq = 1;
    recent_count = 0;
    recent_next = 0;
    head = 0;
    tail = 0;
    count = 0;
    console_head = 0;
    console_tail = 0;
    console_count = 0;
    notice_head = 0;
    notice_tail = 0;
    notice_count = 0;
    lock.release(flags);
}

pub fn snapshot() Stats {
    const flags = lock.acquire();
    const copy = stats;
    lock.release(flags);
    return copy;
}

pub fn pending() usize {
    const flags = lock.acquire();
    const n = count;
    lock.release(flags);
    return n;
}

pub fn scannerStats() scanner.Stats {
    const flags = lock.acquire();
    const copy = scanner_state.stats;
    lock.release(flags);
    return copy;
}

pub fn scannerConfig() scanner.Config {
    const flags = lock.acquire();
    const copy = scanner_state.config;
    lock.release(flags);
    return copy;
}

pub fn configureScanner(cfg: scanner.Config) void {
    const flags = lock.acquire();
    scanner_state.config = cfg;
    scanner_state.reset();
    lock.release(flags);
}

pub fn devicesSlice() []const Device {
    return devices[0..device_count];
}

pub fn deviceAt(index: usize) ?*Device {
    if (index >= device_count) return null;
    return &devices[index];
}

pub fn registerDevice(name: []const u8, kind: DeviceKind) ?u8 {
    const flags = lock.acquire();
    defer lock.release(flags);
    if (device_count >= max_devices) return null;
    var dev = Device{ .kind = kind, .present = true };
    const n = @min(name.len, dev.name.len);
    @memcpy(dev.name[0..n], name[0..n]);
    dev.name_len = n;
    devices[device_count] = dev;
    device_count += 1;
    return @intCast(device_count - 1);
}

pub fn setDeviceRange(index: u8, min_x: i32, max_x: i32, min_y: i32, max_y: i32) void {
    if (index >= device_count) return;
    devices[index].abs_min_x = min_x;
    devices[index].abs_max_x = max_x;
    devices[index].abs_min_y = min_y;
    devices[index].abs_max_y = max_y;
}

pub fn setDeviceIntid(index: u8, intid: u32) void {
    if (index >= device_count) return;
    devices[index].intid = intid;
}

pub fn noteInterrupt(index: u8) void {
    const flags = lock.acquire();
    if (index < device_count) devices[index].irqs += 1;
    lock.release(flags);
}

fn pushLocked(ev: Event) void {
    var event = ev;
    event.seq = next_seq;
    next_seq +%= 1;
    if (event.device < device_count) devices[event.device].events += 1;
    event.time_ms = nowMs();

    if (count == ring_capacity) {
        // Drop the oldest event: a slow consumer must not stall the device.
        tail = (tail + 1) % ring_capacity;
        count -= 1;
        stats.dropped += 1;
    }
    ring[head] = event;
    head = (head + 1) % ring_capacity;
    count += 1;
    if (count > stats.high_water) stats.high_water = count;
    stats.pushed += 1;
    switch (event.kind) {
        .key => stats.keys += 1,
        .pointer => stats.pointers += 1,
        .button => stats.buttons += 1,
        .scroll => stats.scrolls += 1,
        .barcode => stats.barcodes += 1,
        .device => {},
    }

    recent[recent_next] = event;
    recent_next = (recent_next + 1) % recent_capacity;
    if (recent_count < recent_capacity) recent_count += 1;
}

pub fn push(ev: Event) void {
    const flags = lock.acquire();
    pushLocked(ev);
    lock.release(flags);
}

pub fn pop() ?Event {
    const flags = lock.acquire();
    defer lock.release(flags);
    if (count == 0) return null;
    const ev = ring[tail];
    tail = (tail + 1) % ring_capacity;
    count -= 1;
    stats.popped += 1;
    return ev;
}

/// Copy the most recent events, newest last. Returns how many were copied.
pub fn recentEvents(out: []Event) usize {
    const flags = lock.acquire();
    defer lock.release(flags);
    const n = @min(out.len, recent_count);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const slot = (recent_next + recent_capacity - n + i) % recent_capacity;
        out[i] = recent[slot];
    }
    return n;
}

/// Blocking form for kernel consumers: poll at 1 ms until an event arrives or
/// the deadline passes. POS processes get a real wait queue with the UI phase;
/// this is the kernel's own consumer contract until then.
pub fn waitPop(timeout_ms: u64) ?Event {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        if (pop()) |ev| {
            const flags = lock.acquire();
            stats.wait_wakes += 1;
            lock.release(flags);
            return ev;
        }
        if (nowMs() >= deadline) return null;
        if (comptime builtin.cpu.arch == .aarch64) {
            sched.sleepCurrent(1);
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

// ---------------------------------------------------------------------------
// Console mirror
// ---------------------------------------------------------------------------

fn consolePushLocked(ch: u8) void {
    if (console_count == console_capacity) {
        console_tail = (console_tail + 1) % console_capacity;
        console_count -= 1;
        stats.console_dropped += 1;
    }
    console[console_head] = ch;
    console_head = (console_head + 1) % console_capacity;
    console_count += 1;
}

pub fn consoleGetc() ?u8 {
    const flags = lock.acquire();
    defer lock.release(flags);
    if (console_count == 0) return null;
    const ch = console[console_tail];
    console_tail = (console_tail + 1) % console_capacity;
    console_count -= 1;
    return ch;
}

pub fn consolePending() usize {
    const flags = lock.acquire();
    defer lock.release(flags);
    return console_count;
}

pub fn takeNotice() ?Notice {
    const flags = lock.acquire();
    defer lock.release(flags);
    if (notice_count == 0) return null;
    const n = notices[notice_tail];
    notice_tail = (notice_tail + 1) % notice_capacity;
    notice_count -= 1;
    return n;
}

// ---------------------------------------------------------------------------
// Key and character input
// ---------------------------------------------------------------------------

/// Emit one typed character as a key press/release pair, and mirror it to the
/// console. `code` is the physical evdev code that produced it.
fn emitCharacterLocked(dev: u8, code: u16, ch: u8, mods: u8) void {
    var press = Event{
        .kind = .key,
        .device = dev,
        .flags = mods,
        .code = code,
        .value = 1,
        .text_len = 1,
    };
    press.text[0] = ch;
    pushLocked(press);

    var release = Event{
        .kind = .key,
        .device = dev,
        .flags = mods,
        .code = code,
        .value = 0,
    };
    release.text_len = 0;
    pushLocked(release);

    stats.characters += 1;
    consolePushLocked(ch);
}

fn emitCharacter(dev: u8, code: u16, ch: u8, mods: u8) void {
    const flags = lock.acquire();
    emitCharacterLocked(dev, code, ch, mods);
    lock.release(flags);
}

/// Feed a decoded key. Character keys go through the scanner so a scan is one
/// atomic event; everything else is published immediately.
pub fn keyEvent(dev: u8, code: u16, pressed: bool, mods: u8) void {
    const key = keymap.translate(code);
    if (!key.isCharacter()) {
        const ev = Event{ .kind = .key, .device = dev, .flags = mods, .code = code, .value = if (pressed) 1 else 0 };
        push(ev);
        return;
    }
    if (!pressed) return; // character pairs are emitted together on commit

    const modifier_state = keymap.Modifiers{
        .shift = mods & 1 != 0,
        .ctrl = mods & 2 != 0,
        .alt = mods & 4 != 0,
        .meta = mods & 8 != 0,
        .caps = mods & 16 != 0,
        .num = mods & 32 != 0,
    };
    const ch = modifier_state.text(key);
    if (ch == 0) return;

    const flags = lock.acquire();
    defer lock.release(flags);

    const now = nowMs();
    const started = now;
    switch (scanner_state.feed(ch, now)) {
        .held, .swallowed => {
            if (pending_len < pending_codes.len) {
                pending_codes[pending_len] = code;
                pending_len += 1;
            }
        },
        .barcode => |b| {
            pending_len = 0;
            const delivered: u32 = @intCast(nowMs() -| started);
            stats.delivery_last_ms = delivered;
            if (delivered > stats.delivery_max_ms) stats.delivery_max_ms = delivered;
            const ev = Event{
                .kind = .barcode,
                .device = dev,
                .code = @intCast(b.len),
                .value = @intCast(b.latency_ms),
                .aux = @intCast(b.len),
                .text = b.text,
                .text_len = @intCast(b.len),
            };
            pushLocked(ev);
            const slot = notice_head;
            notices[slot] = .{ .text = b.text, .len = @intCast(b.len), .latency_ms = b.latency_ms };
            notice_head = (notice_head + 1) % notice_capacity;
            if (notice_count < notice_capacity) notice_count += 1 else notice_tail = (notice_tail + 1) % notice_capacity;
        },
        .release => |bytes| {
            for (bytes, 0..) |byte, i| {
                const held_code = if (i < pending_len) pending_codes[i] else code;
                emitCharacterLocked(dev, if (held_code == 0) code else held_code, byte, mods);
            }
            pending_len = 0;
        },
    }
}

/// Feed text directly (the shell's `input scan` self-test and the USB HID path
/// both use this). Returns the latency when the text completed a scan.
pub fn feedText(dev: u8, text: []const u8) ?u32 {
    var latency: ?u32 = null;
    for (text) |ch| {
        const flags = lock.acquire();
        const now = nowMs();
        switch (scanner_state.feed(ch, now)) {
            .barcode => |b| {
                const delivered: u32 = @intCast(nowMs() -| now);
                stats.delivery_last_ms = delivered;
                if (delivered > stats.delivery_max_ms) stats.delivery_max_ms = delivered;
                const ev = Event{
                    .kind = .barcode,
                    .device = dev,
                    .code = @intCast(b.len),
                    .value = @intCast(b.latency_ms),
                    .aux = @intCast(b.len),
                    .text = b.text,
                    .text_len = @intCast(b.len),
                };
                pushLocked(ev);
                const slot = notice_head;
                notices[slot] = .{ .text = b.text, .len = @intCast(b.len), .latency_ms = b.latency_ms };
                notice_head = (notice_head + 1) % notice_capacity;
                if (notice_count < notice_capacity) notice_count += 1 else notice_tail = (notice_tail + 1) % notice_capacity;
                latency = b.latency_ms;
                pending_len = 0;
            },
            .release => |bytes| {
                for (bytes) |byte| emitCharacterLocked(dev, 0, byte, 0);
                pending_len = 0;
            },
            else => {},
        }
        lock.release(flags);
    }
    return latency;
}

// ---------------------------------------------------------------------------
// Pointer input
// ---------------------------------------------------------------------------

pub fn pointerMove(dev: u8, x: i32, y: i32, buttons: u8) void {
    const ev = Event{
        .kind = .pointer,
        .device = dev,
        .flags = buttons,
        .value = x,
        .aux = y,
    };
    push(ev);
}

pub fn buttonEvent(dev: u8, button: u8, pressed: bool) void {
    const ev = Event{
        .kind = .button,
        .device = dev,
        .code = button,
        .value = if (pressed) 1 else 0,
    };
    push(ev);
}

pub fn scrollEvent(dev: u8, axis: u8, amount: i32) void {
    const ev = Event{ .kind = .scroll, .device = dev, .code = axis, .value = amount };
    push(ev);
}

/// Human-readable event description for `input`, `input dump` and the live
/// view. Writes into `buf` and returns the slice.
pub fn describe(event: *const Event, buf: []u8) []const u8 {
    var s = std.io.fixedBufferStream(buf);
    const w = s.writer();
    switch (event.kind) {
        .key => {
            const key = keymap.evdev(event.code);
            if (event.text_len == 1 and event.text[0] >= 0x20 and event.text[0] < 0x7f) {
                w.print("key {s:<10} {s} '{c}'", .{ key.name, if (event.value == 1) "down" else "up", event.text[0] }) catch {};
            } else if (event.text_len == 1) {
                w.print("key {s:<10} {s} 0x{x:0>2}", .{ key.name, if (event.value == 1) "down" else "up", event.text[0] }) catch {};
            } else {
                w.print("key {s:<10} {s}", .{ key.name, if (event.value == 1) "down" else "up" }) catch {};
            }
        },
        .pointer => w.print("pointer {d},{d} buttons 0x{x:0>2}", .{ event.value, event.aux, event.flags }) catch {},
        .button => w.print("button {d} {s}", .{ event.code, if (event.value == 1) "down" else "up" }) catch {},
        .scroll => w.print("scroll axis {d} {d}", .{ event.code, event.value }) catch {},
        .barcode => w.print("barcode '{s}' {d} chars, {d} ms", .{ event.textSlice(), event.aux, event.value }) catch {},
        .device => w.print("device {d} {s}", .{
            event.code,
            if (event.value == 1) "added" else "removed",
        }) catch {},
    }
    return s.getWritten();
}

pub fn describeDevice(dev: *const Device, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s} events {d} irqs {d}", .{
        dev.nameSlice(), @tagName(dev.kind), dev.events, dev.irqs,
    }) catch "?";
}

// ---------------------------------------------------------------------------
// Tests: the queue contract, with no hardware involved.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn resetForTest() void {
    init();
    keymap.resetRemaps();
}

test "events keep insertion order and strictly increasing sequence numbers" {
    resetForTest();
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        push(.{ .kind = .pointer, .value = @intCast(i), .aux = @intCast(i * 2) });
    }
    var last_seq: u64 = 0;
    i = 0;
    while (i < 10) : (i += 1) {
        const ev = pop().?;
        try testing.expectEqual(@as(i32, @intCast(i)), ev.value);
        try testing.expect(ev.seq > last_seq);
        last_seq = ev.seq;
    }
    try testing.expect(pop() == null);
}

test "the ring drops the oldest event and says so" {
    resetForTest();
    var i: usize = 0;
    while (i < ring_capacity + 5) : (i += 1) {
        push(.{ .kind = .scroll, .value = @intCast(i) });
    }
    const s = snapshot();
    try testing.expectEqual(@as(u64, 5), s.dropped);
    try testing.expectEqual(ring_capacity, pending());
    const first = pop().?;
    try testing.expectEqual(@as(i32, 5), first.value);
}

test "a scan is one event and its keystrokes never reach the stream" {
    resetForTest();
    const dev = registerDevice("test-kbd", .keyboard).?;
    const latency = feedText(dev, "4006381333931\r");
    try testing.expect(latency != null);

    var keys: usize = 0;
    var barcodes: usize = 0;
    var barcode_text: []const u8 = "";
    while (pop()) |ev| {
        switch (ev.kind) {
            .key => keys += 1,
            .barcode => {
                barcodes += 1;
                barcode_text = ev.textSlice();
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), keys);
    try testing.expectEqual(@as(usize, 1), barcodes);
    try testing.expectEqualStrings("4006381333931", barcode_text);
}

test "typing releases ordered character pairs and fills the console" {
    resetForTest();
    const dev = registerDevice("test-kbd", .keyboard).?;
    // "hi" at human speed: released immediately because letters are not scans.
    keyEvent(dev, 35, true, 0);
    keyEvent(dev, 35, false, 0);
    keyEvent(dev, 23, true, 0);
    keyEvent(dev, 23, false, 0);

    var downs: usize = 0;
    while (pop()) |ev| {
        if (ev.kind == .key and ev.value == 1) downs += 1;
    }
    try testing.expectEqual(@as(usize, 2), downs);
    try testing.expectEqual(@as(?u8, 'h'), consoleGetc());
    try testing.expectEqual(@as(?u8, 'i'), consoleGetc());
    try testing.expectEqual(@as(?u8, null), consoleGetc());
}

test "shift and caps produce the same text a desktop would" {
    resetForTest();
    const dev = registerDevice("test-kbd", .keyboard).?;
    keyEvent(dev, 42, true, 0); // shift down
    keyEvent(dev, 30, true, 1); // A with shift
    keyEvent(dev, 30, false, 1);
    keyEvent(dev, 42, false, 0);
    try testing.expectEqual(@as(?u8, 'A'), consoleGetc());
}

test "a short digit run is typed, not scanned" {
    resetForTest();
    const dev = registerDevice("test-kbd", .keyboard).?;
    _ = feedText(dev, "12\r");
    var barcodes: usize = 0;
    while (pop()) |ev| {
        if (ev.kind == .barcode) barcodes += 1;
    }
    try testing.expectEqual(@as(usize, 0), barcodes);
    // The console saw exactly what was typed.
    try testing.expectEqual(@as(?u8, '1'), consoleGetc());
    try testing.expectEqual(@as(?u8, '2'), consoleGetc());
    try testing.expectEqual(@as(?u8, '\r'), consoleGetc());
}

test "a barcode also leaves one notice for the console" {
    resetForTest();
    const dev = registerDevice("test-kbd", .keyboard).?;
    _ = feedText(dev, "9780201379624\r");
    const notice = takeNotice().?;
    try testing.expectEqualStrings("9780201379624", notice.text[0..notice.len]);
    try testing.expect(takeNotice() == null);
}

test "pointer and button events are distinct and ordered" {
    resetForTest();
    pointerMove(1, 100, 200, 1);
    buttonEvent(1, 1, true);
    buttonEvent(1, 1, false);
    const a = pop().?;
    const b = pop().?;
    const c = pop().?;
    try testing.expect(a.kind == .pointer);
    try testing.expectEqual(@as(i32, 100), a.value);
    try testing.expectEqual(@as(i32, 200), a.aux);
    try testing.expect(b.kind == .button and b.value == 1);
    try testing.expect(c.kind == .button and c.value == 0);
}

test "recent events survive consumption for diagnostics" {
    resetForTest();
    push(.{ .kind = .scroll, .value = 7 });
    push(.{ .kind = .scroll, .value = 8 });
    _ = pop();
    _ = pop();
    var buf: [4]Event = undefined;
    const n = recentEvents(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i32, 7), buf[0].value);
    try testing.expectEqual(@as(i32, 8), buf[1].value);
}
