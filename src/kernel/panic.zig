//! Panic and fatal-error reporting (phase 5).
//!
//! A crash must produce a diagnosis: what failed, where, and what the CPU was
//! doing. In a release build the watchdog eventually takes the terminal back to
//! a known-good state; during development the kernel halts so the report can be
//! read off the serial console.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const uart = @import("../devices/pl011.zig");
const klog = @import("klog.zig");
const symbols = @import("symbols.zig");
const sched = @import("sched.zig");
const smp = @import("smp.zig");

fn readSp() usize {
    return asm volatile ("mov %[out], sp"
        : [out] "=r" (-> usize),
    );
}

fn hexLine(label: []const u8, value: u64) void {
    uart.print("  {s: <12} 0x{x:0>16}\n", .{ label, value });
}

fn dumpCapturedLog() void {
    var buf: [4096]u8 = undefined;
    const captured = klog.ringDump(&buf);
    if (captured.len == 0) return;
    uart.writeAll("--- captured kernel log ---\n");
    uart.writeAll(captured);
    uart.writeAll("--- end of log ---\n");
}

fn dumpSchedulerTrace() void {
    var buf: [8192]u8 = undefined;
    const text = sched.traceDump(&buf);
    if (text.len == 0) return;
    uart.writeAllRaw("--- ");
    uart.writeAllRaw(text);
    uart.writeAllRaw("--- end of trace ---\n");
}

/// Entry point for Zig's panic interface (`std.debug.FullPanic`).
pub fn hook(msg: []const u8, first_trace_addr: ?usize) noreturn {
    cpu.allInterruptsDisable();
    smp.stopOtherCores();
    uart.writeAll("\n\n");
    uart.writeAll("==================== CASSA KERNEL PANIC ====================\n");
    uart.writeAll("  message     : ");
    uart.writeAll(msg);
    uart.writeAll("\n");
    hexLine("current EL", cpu.currentEl());
    hexLine("ELR_EL1", cpu.sysRead("elr_el1"));
    hexLine("SP", readSp());
    hexLine("SPSR_EL1", cpu.sysRead("spsr_el1"));
    hexLine("kernel base", @intFromPtr(&symbols.__kernel_start));
    if (first_trace_addr) |addr|     hexLine("first frame", addr);
    uart.writeAll("===========================================================\n");
    dumpSchedulerTrace();
    dumpCapturedLog();
    uart.writeAll("*** CPU halted ***\n");
    uart.flush();
    cpu.halt();
}

/// Print a structured fault report, then halt. Used by the exception layer.
pub fn faultReport(header: []const u8, body: []const u8) noreturn {
    cpu.allInterruptsDisable();
    smp.stopOtherCores();
    uart.writeAll("\n\n");
    uart.writeAll("=================== CASSA KERNEL FAULT =====================\n");
    uart.writeAll("  ");
    uart.writeAll(header);
    uart.writeAll("\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        uart.writeAll("  ");
        uart.writeAll(line);
        uart.writeAll("\n");
    }
    uart.writeAll("===========================================================\n");
    dumpSchedulerTrace();
    dumpCapturedLog();
    uart.writeAll("*** CPU halted ***\n");
    uart.flush();
    cpu.halt();
}

