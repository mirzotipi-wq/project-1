//! ARM generic timer: monotonic time and a periodic scheduler tick (phase 12).

const std = @import("std");
const cpu = @import("cpu.zig");
const irq = @import("../../kernel/irq.zig");
const klog = @import("../../kernel/klog.zig");

/// Non-secure EL1 physical timer PPI.
pub const timer_intid: u32 = 30;

var frequency: u64 = 0;
var epoch: u64 = 0;
var ticks: u64 = 0;
var tick_hz: u64 = 1000;

fn arm() void {
    // TVAL is a 32-bit down-counter; one tick period at the counter frequency.
    const period = frequency / tick_hz;
    cpu.sysWrite("cntp_tval_el0", period & 0xFFFF_FFFF);
}

fn onTick(_: u32) void {
    arm();
    ticks +%= 1;
}

pub const InitError = error{NoCounter};

pub fn init(hz: u64) InitError!void {
    frequency = cpu.cntFrq();
    if (frequency == 0) return error.NoCounter;
    tick_hz = hz;
    epoch = cpu.cntPct();
    arm();
    cpu.sysWrite("cntp_ctl_el0", 1); // enable, unmask, IMASK=0
    irq.register(timer_intid, onTick);
    klog.info("timer", "generic timer: {d} Hz counter, {d} Hz tick, PPI {d}", .{ frequency, hz, timer_intid });
}

pub fn frequencyHz() u64 {
    return frequency;
}

pub fn tickHz() u64 {
    return tick_hz;
}

pub fn ticksCount() u64 {
    return ticks;
}

pub fn uptimeNs() u64 {
    if (frequency == 0) return 0;
    const delta = cpu.cntPct() -% epoch;
    return @intCast(@as(u128, delta) * 1_000_000_000 / frequency);
}

pub fn uptimeMs() u64 {
    return uptimeNs() / 1_000_000;
}

/// Busy-wait until an absolute counter deadline. Used before the scheduler
/// exists; afterwards sleeping goes through wait queues (phase 17).
pub fn spinUntilNs(deadline_ns: u64) void {
    while (uptimeNs() < deadline_ns) {
        cpu.wfe();
    }
}

pub fn sleepMs(ms: u64) void {
    spinUntilNs(uptimeNs() + ms * 1_000_000);
}

test "nanosecond conversion avoids 32-bit overflow" {
    const delta: u64 = 62_500_000; // one second at 62.5 MHz
    const freq: u64 = 62_500_000;
    const ns: u64 = @intCast(@as(u128, delta) * 1_000_000_000 / freq);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), ns);
}
