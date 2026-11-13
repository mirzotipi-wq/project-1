//! Crash records (phase 27).
//!
//! When a user program faults the kernel must be able to say what happened
//! after the process is gone. The record kept here is the part of a core dump
//! that a service supervisor actually needs: who died, why, where, the eight
//! argument registers and the top of the user stack. It lives in kernel memory
//! in a small ring, because the filesystem is not here yet; `dumps` prints it.

const std = @import("std");
const timer = @import("../arch/aarch64/timer.zig");

pub const max_dumps = 4;

pub const Dump = struct {
    used: bool = false,
    pid: u32 = 0,
    kind: []const u8 = "",
    addr: u64 = 0,
    pc: u64 = 0,
    esr: u64 = 0,
    regs: [8]u64 = [_]u64{0} ** 8,
    stack: [8]u64 = [_]u64{0} ** 8,
    ms: u64 = 0,
};

var ring: [max_dumps]Dump = [_]Dump{.{}} ** max_dumps;
var next: usize = 0;

pub var total: u64 = 0;

pub fn record(
    pid: u32,
    kind: []const u8,
    addr: u64,
    pc: u64,
    esr: u64,
    regs: [8]u64,
    stack: [8]u64,
) void {
    ring[next] = .{
        .used = true,
        .pid = pid,
        .kind = kind,
        .addr = addr,
        .pc = pc,
        .esr = esr,
        .regs = regs,
        .stack = stack,
        .ms = timer.uptimeMs(),
    };
    next = (next + 1) % max_dumps;
    total += 1;
}

/// Most recent first: slot 0 is the newest record still held.
pub fn at(index: usize) ?*const Dump {
    if (index >= max_dumps) return null;
    const slot = (next + max_dumps - 1 - index) % max_dumps;
    const d = &ring[slot];
    if (!d.used) return null;
    return d;
}

pub fn stored() usize {
    return @intCast(@min(total, max_dumps));
}
