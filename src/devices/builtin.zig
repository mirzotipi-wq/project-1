//! The drivers this kernel ships, and the probes that bind them.
//!
//! A driver is three declarations: the compatible strings it claims, the drivers
//! it needs first, and what it does when it is handed a device. The model never
//! knows a driver's name in advance, so adding one is a line in `all`.

const driver = @import("../kernel/driver.zig");
const gic = @import("../arch/aarch64/gic.zig");
const timer = @import("../arch/aarch64/timer.zig");
const uart = @import("pl011.zig");
const pl031 = @import("pl031.zig");
const pci = @import("../kernel/pci.zig");
const virtio_mmio = @import("virtio_mmio.zig");
const bochs_display = @import("bochs_display.zig");
const xhci_device = @import("xhci.zig");
const i6300esb = @import("i6300esb.zig");
const klog = @import("../kernel/klog.zig");

fn probeConsole(dev: *driver.Device) driver.ProbeError!void {
    if (dev.reg_count == 0) return error.NoRegion;
    const base: usize = @intCast(dev.regs[0].base);
    const clock: u32 = if (dev.clock_hz != 0) dev.clock_hz else 24_000_000;
    uart.install(uart.Pl011.init(base, clock, 115200));
    // A console that cannot transmit is not a console: say so by failing the
    // probe rather than pretending a dead UART was bound.
    if (uart.installed() == null) return error.Unsupported;
}

fn probeGic(dev: *driver.Device) driver.ProbeError!void {
    if (dev.reg_count < 2) return error.NoRegion;
    const kind: gic.Version = if (dev.claims("arm,gic-v3")) .v3 else .v2;
    gic.init(@intCast(dev.regs[0].base), @intCast(dev.regs[1].base), kind);
}

fn probeTimer(_: *driver.Device) driver.ProbeError!void {
    timer.init(1000) catch return error.NoCounter;
}

fn probeRtc(dev: *driver.Device) driver.ProbeError!void {
    if (dev.reg_count == 0) return error.NoRegion;
    pl031.init(@intCast(dev.regs[0].base));
    var buf: [40]u8 = undefined;
    const dt = pl031.now() orelse return error.Unsupported;
    klog.info("rtc", "pl031 wall clock {s} (loaded from {d})", .{ pl031.format(dt, &buf), pl031.epochSeconds() });
}

fn removeRtc(_: *driver.Device) void {
    pl031.remove();
}

/// The PCIe host bridge: read the root complex out of the tree, walk its buses,
/// place the BARs, connect the interrupts, and publish every function as a
/// device. The bridge driver owns the bus, not the devices on it.
fn probePciHost(dev: *driver.Device) driver.ProbeError!void {
    const m = driver.attachedMachine() orelse return error.Unsupported;
    const bus = pci.current();
    bus.* = .{};
    bus.root = try pci.parseRoot(m, dev);
    bus.count = pci.walk(&bus.root, bus.functions[0..]);
    // A root complex with no functions at all means the walk or the ECAM window
    // is wrong; failing here is the loud diagnosis, not a quiet empty bus.
    if (bus.count == 0) return error.Unsupported;
    bus.bars_placed = pci.assignBars(&bus.root, bus.functions[0..bus.count]);
    bus.decoding = pci.enableDecoding(&bus.root, bus.functions[0..bus.count]);
    pci.connectInterrupts(&bus.root, bus.functions[0..bus.count]);
    _ = pci.publishAll(bus.functions[0..bus.count]);

    klog.info("pci", "root complex 0x{x}+0x{x}: buses {d}..{d}, mmio 0x{x}+0x{x}", .{
        bus.root.ecam, bus.root.ecam_len, bus.root.bus_first, bus.root.bus_last,
        bus.root.mmio, bus.root.mmio_len,
    });
    var msi_count: usize = 0;
    var intx_count: usize = 0;
    for (bus.functions[0..bus.count]) |*f| {
        if (f.msi_on) {
            msi_count += 1;
        } else if (f.intx_routed) {
            intx_count += 1;
        }
    }
    if (bus.root.msi_fallbacks != 0) {
        klog.warn("pci", "{d} function(s) advertise MSI but are delivered by INTx: their vector table is not reachable until their transport is driven", .{bus.root.msi_fallbacks});
    }
    klog.info("pci", "{d} function(s), {d} BAR(s) placed, {d} decoding, {d} msi, {d} intx{s}", .{
        bus.count, bus.bars_placed, bus.decoding, msi_count, intx_count,
        switch (bus.root.msi) {
            .none => " (no MSI controller: INTx fallback)",
            .its => " (ITS present, not programmed: INTx fallback)",
            .v2m => " (GICv2m)",
        },
    });
}

fn removePciHost(_: *driver.Device) void {
    for (pci.current().functions[0..pci.current().count]) |*f| {
        if (f.msi_on and f.msi_vector != 0) gic.disableIrq(f.msi_vector);
        if (f.intx_routed and f.intx_spi != 0) gic.disableIrq(f.intx_spi);
    }
    const gone = driver.unpublish("pci");
    pci.current().count = 0;
    klog.info("pci", "bus removed: {d} function(s) unpublished", .{gone});
}

/// A driver whose probe always fails. It binds to nothing QEMU produces; the
/// boot self-test injects a `cassa,broken` device to prove the model isolates a
/// failing probe instead of taking the machine down.
fn probeBroken(_: *driver.Device) driver.ProbeError!void {
    return error.Unsupported;
}

const console_driver = driver.Driver{
    .name = "console",
    .compat = &.{"arm,pl011"},
    .probe = probeConsole,
};

const gic_driver = driver.Driver{
    .name = "gic",
    .compat = &.{ "arm,gic-v3", "arm,cortex-a15-gic", "arm,gic-400" },
    .probe = probeGic,
};

const timer_driver = driver.Driver{
    .name = "timer",
    // The generic timer's node lists both: an ARMv7 board drives the same
    // CNTP_* registers under the older compatible string.
    .compat = &.{ "arm,armv8-timer", "arm,armv7-timer" },
    .deps = &.{"gic"},
    .probe = probeTimer,
};

const rtc_driver = driver.Driver{
    .name = "rtc",
    .compat = &.{"arm,pl031"},
    .probe = probeRtc,
    .remove = removeRtc,
};

fn probeVirtioMmio(dev: *driver.Device) driver.ProbeError!void {
    virtio_mmio.probe(dev) catch |err| return switch (err) {
        error.NoRegion => error.NoRegion,
        error.NoMemory => error.NoMemory,
        else => error.Unsupported,
    };
}

fn removeVirtioMmio(dev: *driver.Device) void {
    virtio_mmio.remove(dev);
}

const pci_host_driver = driver.Driver{
    .name = "pci-host",
    .compat = &.{"pci-host-ecam-generic"},
    // The bridge enables INTx lines and MSI vectors, so the controller must be
    // up before it probes. This is the first device whose dependency is real
    // hardware rather than another driver's bookkeeping.
    .deps = &.{"gic"},
    .probe = probePciHost,
    .remove = removePciHost,
};

const virtio_driver = driver.Driver{
    .name = "virtio",
    // One transport for block, net, input and GPU: the device tree's virtio
    // transports, not the PCI functions (those need the modern PCI layout).
    .compat = &.{"virtio,mmio"},
    .probe = probeVirtioMmio,
    .remove = removeVirtioMmio,
};

const broken_driver = driver.Driver{
    .name = "selftest-fail",
    .compat = &.{"cassa,broken"},
    .probe = probeBroken,
};

/// The panel. Patch 37: the first driver on a PCI function, and the first one
/// that publishes a framebuffer to the rest of the system. It depends on the
/// host bridge because it needs its BARs placed before it can program a mode.
fn probeDisplay(dev: *driver.Device) driver.ProbeError!void {
    return bochs_display.probe(dev);
}

fn removeDisplay(dev: *driver.Device) void {
    bochs_display.remove(dev);
}

const display_driver = driver.Driver{
    .name = "display",
    .compat = &.{"pci,1234:1111"},
    .deps = &.{"pci-host"},
    .probe = probeDisplay,
    .remove = removeDisplay,
};

/// The USB host controller. QEMU's `qemu-xhci` and the NEC/Renesas part are the
/// same programming model; both are claimed so a physical card enumerates too.
/// The controller needs the PCI bus to have placed its BAR and routed its
/// interrupt, so it depends on the host bridge.
fn probeUsb(dev: *driver.Device) driver.ProbeError!void {
    try xhci_device.probe(dev);
}

const usb_driver = driver.Driver{
    .name = "xhci",
    .compat = &.{ "pci,1b36:000d", "pci,1033:0194" },
    .deps = &.{ "pci-host", "gic" },
    .probe = probeUsb,
};

/// The i6300ESB is QEMU's PCI watchdog and the same programming model as the
/// Intel 6300ESB south bridge. It depends only on the PCI bus having placed and
/// enabled its BAR; no interrupt is used.
fn probeWatchdog(dev: *driver.Device) driver.ProbeError!void {
    try i6300esb.probe(dev);
}

const wdt_driver = driver.Driver{
    .name = "wdt",
    .compat = &.{"pci,8086:25ab"},
    .deps = &.{"pci-host"},
    .probe = probeWatchdog,
};

pub const all = [_]*const driver.Driver{
    &console_driver,
    &gic_driver,
    &timer_driver,
    &rtc_driver,
    &pci_host_driver,
    &virtio_driver,
    &display_driver,
    &usb_driver,
    &wdt_driver,
    &broken_driver,
};

fn onDeviceEvent(dev: *driver.Device, event: driver.Event) void {
    if (event == .removed or event == .added) {
        klog.info("hotplug", "{s} {s} ({s})", .{ @tagName(event), dev.name, dev.compatible });
    }
}

/// Register the drivers and the hotplug listener. Called once, before discovery.
pub fn installAll() void {
    for (all) |drv| _ = driver.installDriver(drv);
    driver.subscribe(onDeviceEvent);
}
