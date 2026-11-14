//! Driver model (phase 31): devices are objects, drivers declare what they
//! claim and what they need, and the model binds them in dependency order.
//!
//! Before this phase boot order *was* the policy: `kmain` called `gic.init`,
//! then `timer.init`, then whatever came next, because that happens to be the
//! order the QEMU `virt` machine needs. Nothing checked that the hardware was
//! present, nothing could express "the timer needs the interrupt controller
//! first", and a driver that could not start had no way to fail except by
//! taking the machine down.
//!
//! The model fixes the shape rather than the list:
//!
//!   * **Devices are data.** `discover` walks the device tree once and turns
//!     every node with a `compatible` property into a `Device`: its node name,
//!     its compatible strings in tree order, and its `reg` regions. Later
//!     phases add devices by touching the tree (or the machine), never by
//!     editing boot code.
//!   * **Drivers claim compatible strings.** A device binds to the first driver
//!     whose claim list contains one of the device's compatible strings,
//!     testing the device's list in order, so the most specific string wins.
//!   * **Dependencies are declared, not assumed.** A driver names the drivers it
//!     needs first; the model orders the drivers topologically and refuses a
//!     graph with a cycle instead of probing it in hash order.
//!   * **Failure is isolated.** A probe returns an error, the device is marked
//!     `failed` with the reason, a listener is told, and the rest of the boot
//!     continues. A device whose dependency did not bind is `skipped`, not
//!     half-initialised.
//!   * **Devices come and go.** Removing a device unbinds its dependents first,
//!     calls the driver's `remove` hook, and notifies listeners; adding it back
//!     runs the probe again. A driver with no remove hook is boot-critical and
//!     the model refuses to unbind it.
//!
//! The device tree is the probe order. If QEMU does not present a device, no
//! driver for it runs, and the log says so.

const std = @import("std");
const fdt = @import("../lib/fdt.zig");
const machine_mod = @import("machine.zig");
const klog = @import("klog.zig");

pub const max_devices = 96;
pub const max_drivers = 16;
pub const max_compat = 4;
pub const max_regions = 4;
pub const max_listeners = 4;
pub const max_probes = 96;
pub const max_deps = 4;

pub const State = enum {
    /// Not in this machine (never discovered, or removed).
    absent,
    /// Discovered and waiting for a driver to claim it.
    unbound,
    bound,
    /// The driver's probe returned an error. The reason is recorded.
    failed,
    /// The driver exists but something it needs did not bind.
    skipped,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .absent => "absent",
            .unbound => "unbound",
            .bound => "bound",
            .failed => "failed",
            .skipped => "skipped",
        };
    }
};

pub const Event = enum { added, removed, failed };

pub const ProbeError = error{
    NoRegion,
    NoCounter,
    Unsupported,
    DeviceBusy,
    NoMemory,
};

/// What a PCI function is, carried on the device object so the bus layer does
/// not have to keep a parallel table: `devices` and `lspci` read the same thing.
pub const PciInfo = struct {
    bus: u8 = 0,
    dev: u8 = 0,
    func: u8 = 0,
    vendor: u16 = 0,
    device: u16 = 0,
    class_code: u32 = 0,
    header_type: u8 = 0,
    intx_pin: u8 = 0,
    intx_spi: u32 = 0,
    intx_routed: bool = false,
    msi: bool = false,
    msix: bool = false,
    msi_vector: u32 = 0,
    msi_on: bool = false,
    bar_count: u8 = 0,
    bars: [6]u64 = [_]u64{0} ** 6,
    bar_sizes: [6]u64 = [_]u64{0} ** 6,
};

pub const Device = struct {
    /// Node name from the tree, e.g. `rtc@9010000`. Unique per machine.
    name: []const u8 = "",
    /// The most specific compatible string (first in the tree's list).
    compatible: []const u8 = "",
    compatibles: [max_compat][]const u8 = [_][]const u8{""} ** max_compat,
    compatible_count: u8 = 0,
    regs: [max_regions]fdt.Reg = [_]fdt.Reg{.{ .base = 0, .size = 0 }} ** max_regions,
    reg_count: u8 = 0,
    /// `clock-frequency` from the node, when it has one (the PL011 does).
    clock_hz: u32 = 0,
    state: State = .absent,
    driver: ?*const Driver = null,
    /// Why the device is not bound, when it is not.
    reason: []const u8 = "",
    /// False for devices the model synthesised (no device tree) or a self-test
    /// injected.
    from_tree: bool = true,
    /// Device-tree node offset, for drivers that need more properties than the
    /// model stores (the PCIe bridge reads `ranges`, `bus-range` and
    /// `interrupt-map`). Zero means "not from the tree".
    node_off: usize = 0,
    /// PCI identity, when the device came from a bus walk rather than the tree.
    pci: PciInfo = .{},

    pub fn claims(self: *const Device, compatible: []const u8) bool {
        for (self.compatibles[0..self.compatible_count]) |entry| {
            if (std.mem.eql(u8, entry, compatible)) return true;
        }
        return false;
    }
};

pub const Driver = struct {
    name: []const u8,
    /// Compatible strings this driver claims, most specific first.
    compat: []const []const u8,
    /// Drivers that must have a bound device before this one probes.
    deps: []const []const u8 = &.{},
    probe: *const fn (*Device) ProbeError!void,
    /// Absent means boot-critical: the model will not unbind it.
    remove: ?*const fn (*Device) void = null,
};

pub const Listener = *const fn (*Device, Event) void;

pub const ProbeEntry = struct {
    driver: []const u8 = "",
    device: []const u8 = "",
    state: State = .absent,
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

var devices: [max_devices]Device = [_]Device{.{}} ** max_devices;
var device_count: usize = 0;
/// Devices the tree described but the table had no room for.
var overflowed: usize = 0;

var drivers: [max_drivers]*const Driver = undefined;
var driver_count: usize = 0;

var listeners: [max_listeners]Listener = undefined;
var listener_count: usize = 0;

var probes: [max_probes]ProbeEntry = [_]ProbeEntry{.{}} ** max_probes;
var probe_count: usize = 0;

pub var failed_probes: u64 = 0;
pub var removals: u64 = 0;
pub var additions: u64 = 0;
/// Events delivered to listeners, by kind.
pub var events_added: u64 = 0;
pub var events_removed: u64 = 0;
pub var events_failed: u64 = 0;

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// The machine the current boot discovered. Probes that need more than the
/// device's own properties (the PCIe bridge reads the node's `ranges`) look here
/// instead of growing a parameter every phase.
var attached_machine: ?*const machine_mod.Machine = null;

pub fn attachMachine(m: *const machine_mod.Machine) void {
    attached_machine = m;
}

pub fn attachedMachine() ?*const machine_mod.Machine {
    return attached_machine;
}

/// Publish a device the model did not discover itself: a bus function, or a
/// device a driver found behind another one. It enters the same table, so it is
/// matched, described and counted like any tree device.
pub fn publish(dev: Device) ?*Device {
    if (device_count >= max_devices) {
        overflowed += 1;
        return null;
    }
    devices[device_count] = dev;
    device_count += 1;
    return &devices[device_count - 1];
}

/// Drop every published device whose name starts with `prefix` (the PCIe bridge
/// removing itself removes its functions). Returns how many went.
pub fn unpublish(prefix: []const u8) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < device_count) {
        if (!std.mem.startsWith(u8, devices[i].name, prefix)) {
            i += 1;
            continue;
        }
        var j = i;
        while (j + 1 < device_count) : (j += 1) devices[j] = devices[j + 1];
        device_count -= 1;
        removed += 1;
    }
    return removed;
}

/// Functions published by the PCIe bus: a tree node called `pcie@...` must not
/// be mistaken for one, so this counts the devices that carry PCI identity.
pub fn countPci() usize {
    var n: usize = 0;
    for (devices[0..device_count]) |*dev| {
        if (dev.pci.vendor != 0) n += 1;
    }
    return n;
}

pub fn countPrefix(prefix: []const u8) usize {
    var n: usize = 0;
    for (devices[0..device_count]) |*dev| {
        if (std.mem.startsWith(u8, dev.name, prefix)) n += 1;
    }
    return n;
}

pub fn installDriver(driver: *const Driver) bool {
    if (driver_count >= max_drivers) {
        klog.warn("driver", "driver table full: '{s}' not registered", .{driver.name});
        return false;
    }
    for (drivers[0..driver_count]) |existing| {
        if (std.mem.eql(u8, existing.name, driver.name)) {
            klog.warn("driver", "duplicate driver '{s}' ignored", .{driver.name});
            return false;
        }
    }
    drivers[driver_count] = driver;
    driver_count += 1;
    return true;
}

pub fn subscribe(listener: Listener) void {
    if (listener_count >= max_listeners) return;
    listeners[listener_count] = listener;
    listener_count += 1;
}

fn notify(dev: *Device, event: Event) void {
    switch (event) {
        .added => events_added += 1,
        .removed => events_removed += 1,
        .failed => events_failed += 1,
    }
    for (listeners[0..listener_count]) |listener| listener(dev, event);
}

pub fn driverNames() []const *const Driver {
    return drivers[0..driver_count];
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

fn isSkippedName(name: []const u8) bool {
    const prefixes = [_][]const u8{
        "cpus", "memory@", "psci", "chosen", "aliases", "firmware",
        "reserved-memory", "cpu-map", "pmu",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

fn addFromNode(tree: fdt.Fdt, node: fdt.Node) void {
    if (device_count >= max_devices) {
        overflowed += 1;
        return;
    }
    const name = tree.name(node);
    if (isSkippedName(name)) return;
    const compat = tree.prop(node, "compatible") orelse return;

    var dev = Device{ .name = name, .from_tree = true, .state = .unbound, .node_off = node.off };
    var it = std.mem.splitScalar(u8, compat, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (dev.compatible_count >= max_compat) break;
        if (dev.compatible_count == 0) dev.compatible = entry;
        dev.compatibles[dev.compatible_count] = entry;
        dev.compatible_count += 1;
    }
    if (dev.compatible_count == 0) return;
    const regs = tree.regs(node, &dev.regs);
    dev.reg_count = @intCast(regs.len);
    if (tree.prop(node, "clock-frequency")) |raw| {
        if (raw.len >= 4) dev.clock_hz = std.mem.readInt(u32, raw[0..4], .big);
    }
    devices[device_count] = dev;
    device_count += 1;
}

fn walk(tree: fdt.Fdt, node: fdt.Node, depth: usize) void {
    if (depth > 16) return;
    var child = tree.firstChild(node);
    while (child) |c| : (child = tree.nextSibling(c)) {
        addFromNode(tree, c);
        walk(tree, c, depth + 1);
    }
}

/// A device the model invents rather than reads: used for the no-device-tree
/// fallback and by the boot self-test to prove probe failure is isolated.
pub fn inject(name: []const u8, compatible: []const u8, base: u64, size: u64) ?*Device {
    if (device_count >= max_devices) return null;
    var dev = Device{ .name = name, .state = .unbound, .from_tree = false };
    dev.compatibles[0] = compatible;
    dev.compatible_count = 1;
    dev.compatible = compatible;
    if (size != 0) {
        dev.regs[0] = .{ .base = base, .size = size };
        dev.reg_count = 1;
    }
    devices[device_count] = dev;
    device_count += 1;
    return &devices[device_count - 1];
}

/// Turn the machine's device tree into device objects. Returns how many were
/// created; `overflowed` says whether the table ran out.
pub fn discover(m: *const machine_mod.Machine) usize {
    device_count = 0;
    overflowed = 0;
    if (m.fdt_valid and m.dtb != 0) {
        const bytes: [*]const u8 = @ptrFromInt(m.dtb);
        const tree = fdt.Fdt.init(bytes[0..m.dtb_size]) catch {
            klog.warn("driver", "device tree at 0x{x} did not parse; no devices", .{m.dtb});
            return 0;
        };
        walk(tree, tree.root(), 0);
    } else {
        // Degraded path: firmware gave us no tree. The QEMU `virt` defaults the
        // machine layer already assumed become devices, and the log says so.
        klog.warn("driver", "no device tree: discovering the QEMU virt default set", .{});
        _ = inject("pl011", "arm,pl011", m.uart_base, 0x1000);
        if (m.gic_kind == .v3) {
            if (inject("gic-v3", "arm,gic-v3", m.gic_dist, 0x10000)) |d| {
                d.regs[1] = .{ .base = m.gic_second, .size = 0x20000 };
                d.reg_count = 2;
            }
        } else {
            if (inject("gic-v2", "arm,cortex-a15-gic", m.gic_dist, 0x1000)) |d| {
                d.regs[1] = .{ .base = m.gic_second, .size = 0x2000 };
                d.reg_count = 2;
            }
        }
        _ = inject("timer", "arm,armv8-timer", 0, 0);
    }
    klog.info("driver", "{d} device(s) in the tree, {d} driver(s) registered{s}", .{
        device_count,
        driver_count,
        if (overflowed != 0) " (table full: some devices ignored)" else "",
    });
    return device_count;
}

// ---------------------------------------------------------------------------
// Matching and ordering (pure: these are what the host tests exercise)
// ---------------------------------------------------------------------------

/// The driver a device binds to: the device's compatible strings are tried in
/// tree order (most specific first), and for each one the drivers are tried in
/// registration order. Pure: no globals, so it is host-tested directly.
pub fn matchCompat(dev: *const Device, list: []const *const Driver) ?*const Driver {
    for (dev.compatibles[0..dev.compatible_count]) |compatible| {
        if (compatible.len == 0) continue;
        for (list) |driver| {
            for (driver.compat) |claim| {
                if (std.mem.eql(u8, claim, compatible)) return driver;
            }
        }
    }
    return null;
}

pub fn matchDriver(dev: *const Device) ?*const Driver {
    return matchCompat(dev, drivers[0..driver_count]);
}

pub const Order = struct {
    names: [max_drivers][]const u8 = [_][]const u8{""} ** max_drivers,
    count: usize = 0,
    /// A dependency cycle exists. The order is then registration order and the
    /// caller must refuse to bind rather than guess.
    cycle: bool = false,
};

fn indexOfDriver(list: []const *const Driver, name: []const u8) ?usize {
    for (list, 0..) |driver, i| {
        if (std.mem.eql(u8, driver.name, name)) return i;
    }
    return null;
}

/// Topological order over the driver set, dependencies first. Kahn's algorithm
/// with a deterministic tie-break (registration order) so the boot log is
/// stable, plus cycle detection.
pub fn orderDrivers(list: []const *const Driver, out: *Order) void {
    out.* = .{};
    const n = list.len;
    if (n == 0) return;
    var emitted = [_]bool{false} ** max_drivers;
    var remaining = n;
    var guard: usize = 0;
    while (remaining > 0 and guard <= n * n) : (guard += 1) {
        var progress = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (emitted[i]) continue;
            const driver = list[i];
            var ready = true;
            for (driver.deps) |dep| {
                const di = indexOfDriver(list, dep) orelse continue; // unknown dep: not a blocker
                if (!emitted[di]) {
                    ready = false;
                    break;
                }
            }
            if (!ready) continue;
            emitted[i] = true;
            if (out.count < max_drivers) {
                out.names[out.count] = driver.name;
                out.count += 1;
            }
            remaining -= 1;
            progress = true;
        }
        if (!progress) break;
    }
    if (remaining != 0) {
        // A cycle (or a dependency on a driver that is not registered). Fall
        // back to registration order and say so; the caller must not bind.
        out.cycle = true;
        out.count = 0;
        for (list) |driver| {
            if (out.count >= max_drivers) break;
            out.names[out.count] = driver.name;
            out.count += 1;
        }
    }
}

pub fn orderIndex(order: *const Order, name: []const u8) ?usize {
    for (order.names[0..order.count], 0..) |entry, i| {
        if (std.mem.eql(u8, entry, name)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Binding
// ---------------------------------------------------------------------------

fn findDevice(name: []const u8) ?*Device {
    for (devices[0..device_count]) |*dev| {
        if (std.mem.eql(u8, dev.name, name)) return dev;
    }
    return null;
}

pub fn findByCompat(compatible: []const u8) ?*Device {
    for (devices[0..device_count]) |*dev| {
        if (dev.claims(compatible)) return dev;
    }
    return null;
}

pub fn findByNamePrefix(prefix: []const u8) ?*Device {
    for (devices[0..device_count]) |*dev| {
        if (std.mem.startsWith(u8, dev.name, prefix)) return dev;
    }
    return null;
}

pub fn allDevices() []Device {
    return devices[0..device_count];
}

pub fn probeLog() []const ProbeEntry {
    return probes[0..probe_count];
}

pub fn driverOf(name: []const u8) ?*const Driver {
    for (drivers[0..driver_count]) |driver| {
        if (std.mem.eql(u8, driver.name, name)) return driver;
    }
    return null;
}

pub fn isBound(name: []const u8) bool {
    for (devices[0..device_count]) |dev| {
        if (dev.state != .bound) continue;
        if (dev.driver) |driver| {
            if (std.mem.eql(u8, driver.name, name)) return true;
        }
    }
    return false;
}

fn depsBound(driver: *const Driver) bool {
    for (driver.deps) |dep| {
        if (!isBound(dep)) return false;
    }
    return true;
}

fn recordProbe(driver: []const u8, device: []const u8, state: State) void {
    if (probe_count >= max_probes) return;
    probes[probe_count] = .{ .driver = driver, .device = device, .state = state };
    probe_count += 1;
}

fn probeDevice(dev: *Device, driver: *const Driver) void {
    dev.driver = driver;
    driver.probe(dev) catch |err| {
        dev.state = .failed;
        dev.reason = @errorName(err);
        failed_probes += 1;
        recordProbe(driver.name, dev.name, .failed);
        klog.warn("driver", "'{s}' failed on {s}: {s} — isolated, boot continues", .{ driver.name, dev.name, @errorName(err) });
        notify(dev, .failed);
        return;
    };
    dev.state = .bound;
    dev.reason = "";
    recordProbe(driver.name, dev.name, .bound);
    klog.info("driver", "'{s}' bound {s} ({s})", .{ driver.name, dev.name, dev.compatible });
    notify(dev, .added);
}

/// Bind every discovered device whose driver is ready, in dependency order.
/// Idempotent: already-bound devices are left alone, so it can be called again
/// after an injection or a re-add.
pub fn bindAll() void {
    var order: Order = .{};
    orderDrivers(drivers[0..driver_count], &order);
    if (order.cycle) {
        klog.warn("driver", "dependency cycle among drivers: refusing to bind", .{});
        return;
    }
    for (order.names[0..order.count]) |name| {
        const driver = driverOf(name) orelse continue;
        const ready = depsBound(driver);
        for (devices[0..device_count]) |*dev| {
            if (dev.state != .unbound) continue;
            const matched = matchDriver(dev) orelse continue;
            if (matched != driver) continue;
            if (!ready) {
                dev.state = .skipped;
                dev.reason = "dependency not bound";
                recordProbe(driver.name, dev.name, .skipped);
                klog.warn("driver", "'{s}' skipped {s}: a driver it depends on is not bound", .{ driver.name, dev.name });
                continue;
            }
            probeDevice(dev, driver);
        }
    }
}

fn dependsOn(driver: *const Driver, name: []const u8) bool {
    for (driver.deps) |dep| {
        if (std.mem.eql(u8, dep, name)) return true;
    }
    return false;
}

fn unbind(dev: *Device, reason: []const u8) void {
    const driver = dev.driver orelse return;
    if (driver.remove) |remove| remove(dev);
    dev.state = .absent;
    dev.reason = reason;
    klog.info("driver", "'{s}' unbound from {s}: {s}", .{ driver.name, dev.name, reason });
    notify(dev, .removed);
}

/// Remove a device from the running machine: dependents first, then the driver's
/// remove hook, then the listeners. Refuses a boot-critical driver (no hook).
pub fn removeDevice(name: []const u8) ?*Device {
    const dev = findDevice(name) orelse return null;
    if (dev.state != .bound) return null;
    const driver = dev.driver orelse return null;
    if (driver.remove == null) {
        klog.warn("driver", "cannot unbind '{s}' from {s}: boot-critical (no remove hook)", .{ driver.name, dev.name });
        return null;
    }
    // Dependents before their dependency, so nothing is left half-alive.
    var i = device_count;
    while (i > 0) {
        i -= 1;
        const other = &devices[i];
        if (other == dev or other.state != .bound) continue;
        const other_driver = other.driver orelse continue;
        if (dependsOn(other_driver, driver.name)) {
            unbind(other, "dependency removed");
        }
    }
    unbind(dev, "device removed");
    removals += 1;
    return dev;
}

/// Put a removed device back: unbound, re-probed, listeners told.
pub fn readdDevice(name: []const u8) ?*Device {
    const dev = findDevice(name) orelse return null;
    if (dev.state != .absent) return null;
    dev.state = .unbound;
    dev.reason = "";
    const driver = matchDriver(dev) orelse {
        dev.state = .unbound;
        dev.reason = "no driver claims it";
        return dev;
    };
    if (!depsBound(driver)) {
        dev.state = .skipped;
        dev.reason = "dependency not bound";
        return dev;
    }
    probeDevice(dev, driver);
    additions += 1;
    return dev;
}

/// One line for what the machine has, one for what it does not have yet. The
/// unbound devices are grouped by compatible string: a machine with 32
/// virtio-mmio slots should not produce 32 log lines every boot.
pub fn describe() void {
    const Group = struct { compatible: []const u8, count: usize, failed: bool };
    var groups: [max_drivers]Group = undefined;
    var group_count: usize = 0;
    var bound: usize = 0;
    var failed: usize = 0;
    for (devices[0..device_count]) |*dev| {
        if (dev.state == .bound) {
            bound += 1;
            continue;
        }
        if (dev.state == .failed) failed += 1;
        var found: ?*Group = null;
        for (groups[0..group_count]) |*group| {
            if (std.mem.eql(u8, group.compatible, dev.compatible)) found = group;
        }
        if (found) |group| {
            group.count += 1;
            group.failed = group.failed or dev.state == .failed;
        } else if (group_count < groups.len) {
            groups[group_count] = .{ .compatible = dev.compatible, .count = 1, .failed = dev.state == .failed };
            group_count += 1;
        }
    }
    klog.info("driver", "{d} bound, {d} waiting for a driver, {d} failed", .{ bound, device_count - bound, failed });
    // A driver whose devices are all absent is not a failure, but it must be
    // visible: "the machine does not have it" is different from "it broke".
    for (drivers[0..driver_count]) |entry| {
        var any = false;
        for (devices[0..device_count]) |*dev| {
            if (dev.driver == entry and dev.state == .bound) any = true;
        }
        if (!any) klog.info("driver", "idle: '{s}' — no device it claims is in this machine", .{entry.name});
    }
    for (groups[0..group_count]) |group| {
        if (group.failed) {
            klog.warn("driver", "  no driver: {s} x{d} (at least one probe failed)", .{ group.compatible, group.count });
        } else {
            klog.debug("driver", "  no driver: {s} x{d}", .{ group.compatible, group.count });
        }
    }
}

// ---------------------------------------------------------------------------
// Tests: the matching and ordering policy, with no hardware in sight.
// ---------------------------------------------------------------------------

fn probeNoop(_: *Device) ProbeError!void {}

fn deviceWith(compatibles: []const []const u8) Device {
    var dev = Device{};
    for (compatibles, 0..) |entry, i| {
        if (i >= max_compat) break;
        dev.compatibles[i] = entry;
        dev.compatible_count += 1;
    }
    if (dev.compatible_count > 0) dev.compatible = dev.compatibles[0];
    return dev;
}

test "matching prefers the device's most specific compatible string" {
    const console = Driver{ .name = "console", .compat = &[_][]const u8{"arm,pl011"}, .probe = probeNoop };
    const primecell = Driver{ .name = "primecell", .compat = &[_][]const u8{"arm,primecell"}, .probe = probeNoop };
    // Registration order must not decide: the device's own list does.
    const list = [_]*const Driver{ &primecell, &console };
    const dev = deviceWith(&[_][]const u8{ "arm,pl011", "arm,primecell" });
    try std.testing.expectEqualStrings("console", matchCompat(&dev, &list).?.name);
}

test "matching falls back to the generic string and refuses a stranger" {
    const primecell = Driver{ .name = "primecell", .compat = &[_][]const u8{"arm,primecell"}, .probe = probeNoop };
    const list = [_]*const Driver{&primecell};
    const dev = deviceWith(&[_][]const u8{ "arm,pl031", "arm,primecell" });
    try std.testing.expectEqualStrings("primecell", matchCompat(&dev, &list).?.name);
    const stranger = deviceWith(&[_][]const u8{"qemu,unknown"});
    try std.testing.expect(matchCompat(&stranger, &list) == null);
}

test "dependency order is topological, not registration order" {
    const gic_driver = Driver{ .name = "gic", .compat = &[_][]const u8{}, .probe = probeNoop };
    const timer_driver = Driver{ .name = "timer", .compat = &[_][]const u8{}, .deps = &[_][]const u8{"gic"}, .probe = probeNoop };
    const rtc_driver = Driver{ .name = "rtc", .compat = &[_][]const u8{}, .probe = probeNoop };
    // Deliberately registered with the dependent first.
    const list = [_]*const Driver{ &timer_driver, &rtc_driver, &gic_driver };
    var order: Order = .{};
    orderDrivers(&list, &order);
    try std.testing.expect(!order.cycle);
    try std.testing.expectEqual(@as(usize, 3), order.count);
    try std.testing.expect(orderIndex(&order, "gic").? < orderIndex(&order, "timer").?);
}

test "a dependency cycle is reported instead of silently ordered" {
    const x = Driver{ .name = "x", .compat = &[_][]const u8{}, .deps = &[_][]const u8{"y"}, .probe = probeNoop };
    const y = Driver{ .name = "y", .compat = &[_][]const u8{}, .deps = &[_][]const u8{"x"}, .probe = probeNoop };
    const list = [_]*const Driver{ &x, &y };
    var order: Order = .{};
    orderDrivers(&list, &order);
    try std.testing.expect(order.cycle);
}
