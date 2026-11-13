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
//!   4  capability suite: six cases over the handles the kernel granted
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


// ---------------------------------------------------------------------------
// Capability suite (mode 4)
//
// The kernel grants four handles at spawn: console, a shared ledger, the
// supervisor (the shell process) and a page object. Everything below is decided
// by the mask on a handle, not by anything this program says about itself.
// ---------------------------------------------------------------------------

const SYS_CAP_QUERY = 20;
const SYS_CAP_DERIVE = 21;
const SYS_CAP_REVOKE = 22;
const SYS_CAP_CLOSE = 23;
const SYS_CAP_READ = 24;
const SYS_CAP_WRITE = 25;
const SYS_CAP_CONTROL = 26;
const SYS_CAP_MAP = 27;

const E_PERM: i64 = -1;
const E_BADF: i64 = -9;
const E_MFILE: i64 = -24;

fn capQuery(h: u64) i64 {
    return @bitCast(syscall3(SYS_CAP_QUERY, h, 0, 0));
}
fn capDerive(h: u64, rights: u64) i64 {
    return @bitCast(syscall3(SYS_CAP_DERIVE, h, rights, 0));
}
fn capRevoke(h: u64) i64 {
    return @bitCast(syscall3(SYS_CAP_REVOKE, h, 0, 0));
}
fn capClose(h: u64) i64 {
    return @bitCast(syscall3(SYS_CAP_CLOSE, h, 0, 0));
}
fn capRead(h: u64, ptr: usize, len: usize) i64 {
    return @bitCast(syscall3(SYS_CAP_READ, h, ptr, len));
}
fn capWrite(h: u64, ptr: usize, len: usize) i64 {
    return @bitCast(syscall3(SYS_CAP_WRITE, h, ptr, len));
}
fn capControl(h: u64) i64 {
    return @bitCast(syscall3(SYS_CAP_CONTROL, h, 0, 0));
}
fn capMap(h: u64) i64 {
    return @bitCast(syscall3(SYS_CAP_MAP, h, 0, 0));
}

fn appendStr(buf: []u8, at: *usize, text: []const u8) void {
    @setRuntimeSafety(false);
    for (text) |ch| {
        if (at.* >= buf.len) return;
        buf[at.*] = ch;
        at.* += 1;
    }
}

fn appendNum(buf: []u8, at: *usize, value: u64) void {
    @setRuntimeSafety(false);
    var tmp: [20]u8 = undefined;
    var k: usize = tmp.len;
    var v = value;
    if (v == 0) {
        appendStr(buf, at, "0");
        return;
    }
    while (v > 0) : (v /= 10) {
        k -= 1;
        tmp[k] = '0' + @as(u8, @intCast(v % 10));
    }
    appendStr(buf, at, tmp[k..]);
}

/// One syscall per line: the console lock makes a write atomic, so two processes
/// printing at once can interleave whole lines but never split one.
fn report(n: u32, ok: bool) void {
    var buf: [32]u8 = undefined;
    var at: usize = 0;
    appendStr(&buf, &at, "[user] case ");
    appendNum(&buf, &at, n);
    appendStr(&buf, &at, if (ok) ": OK\n" else ": FAIL\n");
    _ = writePtr(@intFromPtr(&buf), at);
}

fn capSuite(profile: u64) u32 {
    // Hold the suite open for a moment so a second holder of the same ledger
    // is alive at the same time: case 5 needs two processes, not two runs.
    _ = syscall3(SYS_SLEEP_MS, 60, 0, 0);

    const h_console = peek(32);
    const h_ledger = peek(40);
    const h_supervisor = peek(48);
    const h_page = peek(56);
    var failures: u32 = 0;

    var hdr: [96]u8 = undefined;
    var at: usize = 0;
    appendStr(&hdr, &at, "[user] capability suite, profile ");
    appendNum(&hdr, &at, profile);
    appendStr(&hdr, &at, ", handles con/led/sup/pg = ");
    appendNum(&hdr, &at, h_console);
    appendStr(&hdr, &at, "/");
    appendNum(&hdr, &at, h_ledger);
    appendStr(&hdr, &at, "/");
    appendNum(&hdr, &at, h_supervisor);
    appendStr(&hdr, &at, "/");
    appendNum(&hdr, &at, h_page);
    appendStr(&hdr, &at, "\n");
    _ = writePtr(@intFromPtr(&hdr), at);

    // 1 -- the authority that was granted actually works.
    if (profile == 0) {
        const wrote = capWrite(h_ledger, @intFromPtr("cap-ok"), 6);
        const mask = capQuery(h_ledger);
        const ok = wrote == 6 and mask >= 0 and (mask & 3) == 3;
        if (!ok) failures += 1;
        report(1, ok);
    } else {
        var buf: [8]u8 = undefined;
        const read = capRead(h_ledger, @intFromPtr(&buf), 8);
        const mask = capQuery(h_ledger);
        // Exactly READ: no WRITE, no CONTROL. Same object, narrower authority.
        const ok = read >= 0 and mask == 1;
        if (!ok) failures += 1;
        report(1, ok);
    }

    // 2 -- an operation that needs a right the handle does not carry.
    {
        const map_ledger = capMap(h_ledger); // the ledger carries no EXEC
        const control_sup = capControl(h_supervisor); // the supervisor is read-only
        const ok = map_ledger == E_PERM and control_sup == E_PERM;
        if (!ok) failures += 1;
        report(2, ok);
    }

    // 3 -- numbers that never named anything, and numbers past the table.
    {
        const unallocated = capQuery(11); // slot 10 was never granted
        const out_of_range = capQuery(0x100C8); // slot 200: past max_handles
        const zero = capQuery(0); // zero is never a handle
        const ok = unallocated == E_BADF and out_of_range == E_BADF and zero == E_BADF;
        if (!ok) failures += 1;
        report(3, ok);
    }

    // 4 -- use after revoke.
    if (profile == 0) {
        const derived = capDerive(h_ledger, 8); // CONTROL only
        var ok = derived > 0;
        if (ok) {
            const before = capControl(@intCast(derived));
            _ = capRevoke(@intCast(derived));
            const after = capControl(@intCast(derived));
            const parent_alive = (capQuery(h_ledger) & 8) != 0;
            ok = before >= 1 and after == E_BADF and parent_alive;
        }
        if (!ok) failures += 1;
        report(4, ok);
    }

    // 5 -- two holders of one object, each bounded by its own mask.
    if (profile == 0) {
        const wrote = capWrite(h_ledger, @intFromPtr("shared!"), 7);
        const ok = wrote == 7;
        if (!ok) failures += 1;
        report(5, ok);
    } else {
        const denied = capWrite(h_ledger, @intFromPtr("nope"), 4);
        var buf: [16]u8 = undefined;
        const read = capRead(h_ledger, @intFromPtr(&buf), 16);
        const ok = denied == E_PERM and read >= 0;
        if (!ok) failures += 1;
        report(5, ok);
    }

    // 6 -- a full table fails cleanly, then recovers.
    if (profile == 0) {
        var first: i64 = 0;
        var last: i64 = 0;
        var i: u32 = 0;
        while (i < 40) : (i += 1) {
            last = capDerive(h_ledger, 1);
            if (last < 0) break;
            if (first == 0) first = last;
        }
        var ok = last == E_MFILE;
        if (first > 0) {
            _ = capClose(@intCast(first));
            ok = ok and capDerive(h_ledger, 1) > 0;
        }
        if (!ok) failures += 1;
        report(6, ok);
    }

    return failures;
}

export fn _start() callconv(.C) noreturn {
    const mode = peek(0);
    const secret = peek(8);
    switch (mode) {
        1 => tryPrivileged(),
        2 => tryKernelRead(),
        3 => isolation(secret),
        4 => {
            const failures = capSuite(secret);
            if (failures != 0) exit(9);
        },
        else => normal(),
    }
    exit(0);
}
