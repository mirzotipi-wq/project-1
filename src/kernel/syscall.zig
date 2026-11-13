//! System call surface. Phase 21 replaces the debug stubs with the real
//! capability-checked table; the trap plumbing is already the final one.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const trap = @import("../arch/aarch64/trap.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const klog = @import("klog.zig");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");

pub const Nr = enum(u64) {
    debug_write = 1,
    debug_exit = 2,
    uptime_ms = 3,
    cpu_id = 4,
};

pub const Errno = enum(i64) {
    badf = -9,
    fault = -14,
    invalid = -22,
    nosys = -38,
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

pub fn handle(number: u64, frame: *trap.Frame) void {
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
        },
        @intFromEnum(Nr.debug_exit) => {
            klog.info("syscall", "debug_exit from pc=0x{x}", .{frame.elr});
            frame.x[0] = 0;
        },
        @intFromEnum(Nr.uptime_ms) => {
            frame.x[0] = timer.uptimeMs();
        },
        @intFromEnum(Nr.cpu_id) => {
            frame.x[0] = (cpu.sysRead("mpidr_el1") & 0xFF);
        },
        else => {
            klog.warn("syscall", "unimplemented syscall {d} from pc=0x{x}", .{ number, frame.elr });
            frame.x[0] = errno(.nosys);
        },
    }
    // ELR points at the SVC itself; resume after it.
    frame.elr +%= 4;
}
