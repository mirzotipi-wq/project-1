//! The first Cassa user program (phases 21-22).
//!
//! Compiled by the same Zig toolchain as the kernel, linked at 0x8000_0000 and
//! embedded in the kernel image as a flat blob. It runs at EL0 with no ambient
//! authority: every byte it prints and every fact it learns comes back through
//! `svc #0`, and the only memory it can address is the three regions its
//! address space maps.
//!
//! The kernel passes two words in the data page — a mode and a secret:
//!
//!   0  normal run: print, ask for pid and uptime, yield, try two bad pointers
//!   1  attempt to read a privileged system register (must fault)
//!   2  attempt to read kernel text (must fault)
//!   3  isolation run: write the secret to a fixed VA, sleep while another
//!      process does the same, and check it is still ours afterwards
//!
//! Nothing here links against std or the kernel; the whole program is this file
//! plus the syscall instruction.

/// The data page the kernel maps read/write into every process. The same
/// virtual address holds a different physical page in each address space: that
/// is precisely what the isolation mode demonstrates.
const data_base: usize = 0x8100_0000;

const SYS_WRITE = 1;
const SYS_EXIT = 2;
const SYS_GETPID = 3;
const SYS_YIELD = 4;
const SYS_SLEEP_MS = 5;
const SYS_UPTIME_MS = 6;

/// x8 carries the call number, x0..x2 the arguments, x0 the result. The kernel
/// saves and restores every general register across the trap, so nothing else
/// has to be preserved here, but the compiler must be told that x0..x2 and x8
/// are gone.
fn syscall3(n: u64, a: u64, b: u64, c: u64) u64 {
    @setRuntimeSafety(false);
    var ret: u64 = undefined;
    asm volatile (
        \\mov x8, %[n]
        \\mov x0, %[a]
        \\mov x1, %[b]
        \\mov x2, %[c]
        \\svc #0
        \\mov %[ret], x0
        : [ret] "=r" (ret),
        : [n] "r" (n),
          [a] "r" (a),
          [b] "r" (b),
          [c] "r" (c),
        : "x0", "x1", "x2", "x8", "memory"
    );
    return ret;
}

fn sys0(n: u64) u64 {
    return syscall3(n, 0, 0, 0);
}

fn writePtr(ptr: usize, len: usize) i64 {
    return @bitCast(syscall3(SYS_WRITE, ptr, len, 0));
}

fn print(s: []const u8) void {
    @setRuntimeSafety(false);
    _ = writePtr(@intFromPtr(s.ptr), s.len);
}

fn printNum(value: u64) void {
    @setRuntimeSafety(false);
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    if (v == 0) {
        print("0");
        return;
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }
    print(buf[i..]);
}

fn printSigned(value: i64) void {
    @setRuntimeSafety(false);
    if (value < 0) {
        print("-");
        printNum(@intCast(-value));
    } else {
        printNum(@intCast(value));
    }
}

fn printHex(value: u64) void {
    @setRuntimeSafety(false);
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        if (nibble != 0 or started or shift == 0) {
            buf[i] = digits[nibble];
            i += 1;
            started = true;
        }
        if (shift == 0) break;
        shift -= 4;
    }
    print("0x");
    print(buf[0..i]);
}

fn peek(offset: usize) u64 {
    @setRuntimeSafety(false);
    const p: *volatile u64 = @ptrFromInt(data_base + offset);
    return p.*;
}

fn poke(offset: usize, value: u64) void {
    @setRuntimeSafety(false);
    const p: *volatile u64 = @ptrFromInt(data_base + offset);
    p.* = value;
}

fn exit(code: u64) noreturn {
    _ = syscall3(SYS_EXIT, code, 0, 0);
    unreachable;
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------

fn normal() void {
    print("[user] hello from EL0\n");

    print("[user] pid=");
    printNum(sys0(SYS_GETPID));
    print(" uptime_ms=");
    printNum(sys0(SYS_UPTIME_MS));
    print(" (both delivered by the kernel)\n");

    print("[user] yielding to the scheduler\n");
    _ = sys0(SYS_YIELD);
    print("[user] back on the CPU\n");

    // Two pointers the kernel must refuse: kernel text, and a hole in the
    // address space. Neither is dereferenced by the kernel; both come back as
    // -EFAULT.
    print("[user] write(kernel text 0x40080000) -> ");
    printSigned(writePtr(0x4008_0000, 8));
    print(" (rejected)\n");

    print("[user] write(unmapped 0xdead0000) -> ");
    printSigned(writePtr(0x00de_ad00_00, 8));
    print(" (rejected)\n");

    print("[user] exiting with code 0\n");
}

fn tryPrivileged() void {
    print("[user] attempting MRS TCR_EL1 from EL0\n");
    // EL1 system registers are not readable at EL0: this traps to the kernel as
    // a trapped system-register access.
    asm volatile ("mrs x0, tcr_el1" ::: "x0");
    print("[user] SURVIVED a privileged register read — this is a bug\n");
}

fn tryKernelRead() void {
    print("[user] attempting to read kernel text at 0x40080000\n");
    const p: *volatile const u64 = @ptrFromInt(0x4008_0000);
    const value = p.*;
    print("[user] SURVIVED the kernel read: ");
    printHex(value);
    print("\n");
}

fn isolation(secret: u64) void {
    // The same virtual address in every process, a different physical page per
    // process. If the address-space switch were broken, the other process's
    // value would appear here.
    poke(16, secret);
    print("[user] pid=");
    printNum(sys0(SYS_GETPID));
    print(" stored ");
    printHex(secret);
    print(" at 0x81000010\n");

    var i: u32 = 0;
    while (i < 25) : (i += 1) {
        _ = syscall3(SYS_SLEEP_MS, 2, 0, 0);
        const seen = peek(16);
        if (seen != secret) {
            print("[user] ISOLATION BROKEN: read ");
            printHex(seen);
            print("\n");
            exit(9);
        }
    }
    print("[user] pid=");
    printNum(sys0(SYS_GETPID));
    print(" still reads ");
    printHex(peek(16));
    print(" after 25 switches\n");
}

export fn _start() callconv(.C) noreturn {
    const mode = peek(0);
    const secret = peek(8);
    switch (mode) {
        1 => tryPrivileged(),
        2 => tryKernelRead(),
        3 => isolation(secret),
        else => normal(),
    }
    exit(0);
}
