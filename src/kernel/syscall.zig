//! System call surface. The trap plumbing is final; phase 21 replaces the
//! debug entry points with the capability-checked table when user mode lands.
//!
//! Threading calls are deliberately syscalls and not plain function calls: a
//! thread that blocks or exits must do so from an exception frame, because that
//! frame *is* its context. Going through SVC buys the scheduler a valid frame
//! for free and keeps one switching mechanism instead of two.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const trap = @import("../arch/aarch64/trap.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const klog = @import("klog.zig");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");
const sched = @import("sched.zig");
const percpu = @import("percpu.zig");

pub const Nr = enum(u64) {
    debug_write = 1,
    debug_exit = 2,
    uptime_ms = 3,
    cpu_id = 4,

    yield = 64,
    exit = 65,
    sleep_ms = 66,
    thread_id = 67,
    thread_count = 68,
};

pub const Errno = enum(i64) {
    badf = -9,
    fault = -14,
    invalid = -22,
    nosys = -38,
};

/// What the exception layer must do after the call returns.
pub const Action = enum {
    /// Resume the caller at the returned frame.
    keep,
    /// Re-enter the scheduler; a different thread may come back.
    reschedule,
};

fn errno(code: Errno) u64 {
    return @bitCast(@intFromEnum(code));
}

/// Validate a buffer against the live page tables. Anything the MMU cannot
/// translate must never be dereferenced on behalf of a caller.
fn validRange(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr + len < ptr) return false;
    if (mmu.translate(ptr) == null) return false;
    if (mmu.translate(ptr + len - 1) == null) return false;
    return true;
}

pub fn handle(number: u64, frame: *trap.Frame) Action {
    switch (number) {
        @intFromEnum(Nr.debug_write) => {
            const ptr = frame.x[0];
            const len = frame.x[1];
            if (!validRange(ptr, len)) {
                frame.x[0] = errno(.fault);
            } else {
                const bytes: [*]const u8 = @ptrFromInt(ptr);
                uart.writeAll(bytes[0..len]);
                frame.x[0] = len;
            }
            return .keep;
        },
        @intFromEnum(Nr.debug_exit) => {
            klog.info("syscall", "thread {d} exiting at pc=0x{x}", .{ sched.running().id, frame.elr });
            sched.markDead();
            return .reschedule;
        },
        @intFromEnum(Nr.uptime_ms) => {
            frame.x[0] = timer.uptimeMs();
            return .keep;
        },
        @intFromEnum(Nr.cpu_id) => {
            frame.x[0] = percpu.this().id;
            return .keep;
        },
        @intFromEnum(Nr.yield) => {
            frame.x[0] = 0;
            return .reschedule;
        },
        @intFromEnum(Nr.exit) => {
            sched.markDead();
            return .reschedule;
        },
        @intFromEnum(Nr.sleep_ms) => {
            sched.sleepCurrent(frame.x[0]);
            frame.x[0] = 0;
            return .reschedule;
        },
        @intFromEnum(Nr.thread_id) => {
            frame.x[0] = sched.running().id;
            return .keep;
        },
        @intFromEnum(Nr.thread_count) => {
            frame.x[0] = sched.threadCount();
            return .keep;
        },
        else => {
            klog.warn("syscall", "unimplemented syscall {d} from pc=0x{x}", .{ number, frame.elr });
            frame.x[0] = errno(.nosys);
            return .keep;
        },
    }
}

test "syscall numbers stay out of the signal-handler range" {
    try std.testing.expectEqual(@as(u64, 64), Nr.yield);
    try std.testing.expectEqual(@as(u64, 65), Nr.exit);
}
