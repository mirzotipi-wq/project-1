//! Thermal zones and throttling (phase 40).
//!
//! A shop terminal is fanless and often sits under a counter, so the kernel
//! needs a policy before it has a board-specific PMIC driver. The policy is in
//! `lib/power.zig` and host-tested; this file owns the current zone, the sensor
//! seam, and the per-core tick counters that turn the policy into idle time.
//!
//! QEMU's `virt` machine has no thermal zone, so the default source is the
//! explicitly-labelled virtual sensor. A board driver can register a real one
//! with `registerSensor`; the policy and the scheduler path do not change. The
//! shell's `thermal set` drives the virtual source, which is what the phase 40
//! harness uses to prove that the ladder actually changes scheduling.
//!
//! Throttling is a duty cycle, not a fake frequency: on a throttled tick the
//! scheduler switches that core to its idle thread, which executes `wfi` until
//! the next timer interrupt. The counters below are the evidence that idle time
//! was actually injected, not merely reported.

const std = @import("std");
const klog = @import("klog.zig");
const power_lib = @import("../lib/power.zig");

pub const Stats = struct {
    temp_mc: i32 = 42_000,
    state: power_lib.ThermalState = .normal,
    throttle_percent: u8 = 0,
    transitions: u32 = 0,
    idle_ticks: u64 = 0,
    samples: u64 = 0,
    sensor_name: []const u8 = "virtual",
};

var policy: power_lib.ThermalPolicy = .{};
var virtual_mc: i32 = 42_000;
var sensor: ?*const fn () ?i32 = null;
var core_ticks: [8]u64 = [_]u64{0} ** 8;
var idle_ticks: u64 = 0;
var samples: u64 = 0;

pub fn init() void {
    policy = .{};
    virtual_mc = 42_000;
    sensor = null;
    core_ticks = [_]u64{0} ** 8;
    idle_ticks = 0;
    samples = 0;
    klog.info("thermal", "zone 0: {d} mC, normal, virtual sensor (QEMU/board fallback)", .{virtual_mc});
}

/// A board's thermal driver can replace the virtual source. It returns
/// milli-degrees Celsius, or null when the sensor is temporarily unreadable.
pub fn registerSensor(read: *const fn () ?i32) void {
    sensor = read;
    klog.info("thermal", "zone 0: hardware sensor registered", .{});
}

fn publish(mc: i32) void {
    const before = policy.state;
    const now = policy.sample(mc);
    samples += 1;
    if (now != before) {
        klog.warn("thermal", "zone 0: {d}.{d} C, {s} -> {s}, idle {d}/4 of scheduler ticks", .{
            @divTrunc(mc, 1000), @as(u32, @intCast(@mod(mc, 1000))), power_lib.thermalLabel(before), power_lib.thermalLabel(now), power_lib.idleQuarters(now),
        });
    }
}

pub fn setTemperature(mc: i32) void {
    virtual_mc = mc;
    publish(mc);
}

pub fn sampleNow() void {
    if (sensor) |read| {
        if (read()) |mc| publish(mc);
    } else {
        publish(virtual_mc);
    }
}

pub fn temperatureMc() i32 {
    return policy.temp_mc;
}

pub fn state() power_lib.ThermalState {
    return policy.state;
}

pub fn throttlePercent() u8 {
    return policy.throttle();
}

pub fn idleQuarters() u8 {
    return power_lib.idleQuarters(policy.state);
}

/// Called once per scheduler tick on this core. The return value is the
/// scheduler's instruction to run the idle thread for this tick.
pub fn tick(core: u32) bool {
    if (core >= core_ticks.len) return false;
    core_ticks[core] +%= 1;
    const idle = policy.shouldIdle(core_ticks[core]);
    if (idle) idle_ticks += 1;
    return idle;
}

pub fn stats() Stats {
    return .{
        .temp_mc = policy.temp_mc,
        .state = policy.state,
        .throttle_percent = policy.throttle(),
        .transitions = policy.transitions,
        .idle_ticks = idle_ticks,
        .samples = samples,
        .sensor_name = if (sensor != null) "hardware" else "virtual",
    };
}

pub fn clear() void {
    virtual_mc = 42_000;
    policy = .{};
    klog.info("thermal", "zone 0: reset to normal, virtual sensor 42.000 C", .{});
}

/// Run the ladder on a private policy so the shell can prove the thresholds
/// without changing the live zone. This is the same function the live path
/// uses; there is no second implementation to drift.
pub fn selfTest(write: anytype) bool {
    var p = power_lib.ThermalPolicy{};
    var ok = true;
    const cases = [_]struct { mc: i32, want: power_lib.ThermalState }{
        .{ .mc = 42_000, .want = .normal },
        .{ .mc = 70_000, .want = .warm },
        .{ .mc = 82_000, .want = .hot },
        .{ .mc = 92_000, .want = .critical },
    };
    for (cases) |case| {
        const got = p.sample(case.mc);
        if (got != case.want) ok = false;
        write("      {d}.{d:0>3} C -> {s}, throttle {d}%  {s}\n", .{
            @divTrunc(case.mc, 1000),               @as(u32, @intCast(@mod(case.mc, 1000))), power_lib.thermalLabel(got), power_lib.throttlePercent(got),
            if (got == case.want) "OK" else "FAIL",
        });
    }
    const idle_ok = p.shouldIdle(0) and p.shouldIdle(1) and p.shouldIdle(2) and !p.shouldIdle(3);
    write("      idle pattern at critical: 3/4 ticks, counter sample  {s}\n", .{if (idle_ok) "OK" else "FAIL"});
    return ok and idle_ok;
}
