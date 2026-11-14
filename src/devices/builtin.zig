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

const broken_driver = driver.Driver{
    .name = "selftest-fail",
    .compat = &.{"cassa,broken"},
    .probe = probeBroken,
};

pub const all = [_]*const driver.Driver{
    &console_driver,
    &gic_driver,
    &timer_driver,
    &rtc_driver,
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
