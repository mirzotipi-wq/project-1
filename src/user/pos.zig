//! A separately built EL0 program (phase 26).
//!
//! This file is compiled by `zig build` into its own ELF64 executable — with its
//! own loadable segments, its own data and its own BSS — and embedded in the
//! kernel image as the bytes of a file. The kernel's ELF loader parses those
//! bytes at runtime, and the POS shell launches the program with
//! `exec pos ...`. It shares no code with the kernel and no mode flag with the
//! demo blob: it is a program, and the only thing it knows about the system is
//! the syscall interface.
//!
//! Startup ABI: the loader enters `_start` with x0 = argc, x1 = argv, x2 = envp
//! and SP pointing below the argument block it built on the user stack.
//!
//! What it proves, in order: it arrived through an ELF loader (not a blob), its
//! BSS really was zeroed, its initialised data survived the load, it received
//! argv and envp on the stack, it can print through the kernel, and it can
//! return an exit status the shell sees. Exits 42 when every one of those holds,
//! 9 otherwise.

const SYS_WRITE = 1;
const SYS_EXIT = 2;
const SYS_GETPID = 3;
const SYS_UPTIME_MS = 6;
const SYS_SLEEP_MS = 5;
const SYS_RESOLVE = 38;

fn syscall3(n: u64, a: u64, b: u64, c: u64) u64 {
    @setRuntimeSafety(false);
    var r: u64 = undefined;
    asm volatile ("mov x8, %[n]\nmov x0, %[a]\nmov x1, %[b]\nmov x2, %[c]\nsvc #0\nmov %[r], x0"
        : [r] "=r" (r),
        : [n] "r" (n), [a] "r" (a), [b] "r" (b), [c] "r" (c),
        : "x0", "x1", "x2", "x8", "memory"
    );
    return r;
}

/// syscall 1 is write(ptr, len) — the kernel validates the range against this
/// process before touching it, so the pointer must be a user address.
fn write(text: []const u8) void {
    _ = syscall3(SYS_WRITE, @intFromPtr(text.ptr), text.len, 0);
}

fn printNum(value: u64) void {
    var buf: [24]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v != 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    write(buf[i..]);
}

fn reasonLabel(code: u64) []const u8 {
    return switch (code) {
        0 => "ok",
        1 => "unknown name",
        2 => "not running",
        3 => "restarting",
        4 => "crash-loop parked",
        5 => "exited, restart pending",
        6 => "already registered",
        7 => "invalid name",
        8 => "name table full",
        else => "unavailable",
    };
}

fn lenOf(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

fn sliceOf(s: [*:0]const u8) []const u8 {
    return s[0..lenOf(s)];
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn startsWith(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    for (needle, 0..) |c, i| if (hay[i] != c) return false;
    return true;
}

fn exit(code: u64) noreturn {
    _ = syscall3(SYS_EXIT, code, 0, 0);
    unreachable;
}

/// .bss: the loader must hand this over as zeroes even though it occupies no
/// bytes in the file.
var bss_guard: [256]u8 = [_]u8{0} ** 256;
/// .data: an initialised value that must survive the load unchanged.
var data_word: u64 = 0xC355A_0000_0001;
var touched: u64 = 0;

export fn _start(argc: usize, argv: [*][*:0]u8, envp: [*][*:0]u8) callconv(.C) noreturn {
    var ok = true;

    // 1. BSS arrived zeroed, and it is writable.
    for (bss_guard) |b| {
        if (b != 0) ok = false;
    }
    bss_guard[0] = 7;
    bss_guard[255] = 9;
    touched = 1;
    if (bss_guard[0] != 7 or bss_guard[255] != 9 or touched != 1) ok = false;

    // 2. Initialised data arrived with its value from the file.
    if (data_word != 0xC355A_0000_0001) ok = false;

    // 3. argv arrived on the stack.
    write("[user] pos: argc ");
    printNum(argc);
    write("\n");
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        write("[user] pos: argv[");
        printNum(i);
        write("] ");
        write(sliceOf(argv[i]));
        write("\n");
    }
    const mode: []const u8 = if (argc > 1) sliceOf(argv[1]) else "";
    if (equal(mode, "alpha")) {
        if (argc != 3) ok = false;
        if (argc == 3) {
            if (!equal(sliceOf(argv[1]), "alpha")) ok = false;
            if (!equal(sliceOf(argv[2]), "beta")) ok = false;
        }
    }

    // 4. envp arrived, and it is a separate vector from argv.
    var env_count: usize = 0;
    var found_term = false;
    while (@intFromPtr(envp[env_count]) != 0) : (env_count += 1) {
        const entry = sliceOf(envp[env_count]);
        write("[user] pos: env ");
        write(entry);
        write("\n");
        if (startsWith(entry, "POS_TERM=cassa-1")) found_term = true;
    }
    if (!found_term or env_count == 0) ok = false;

    // 5. It is its own process, running on this kernel's clock.
    const pid = syscall3(SYS_GETPID, 0, 0, 0);
    const ms = syscall3(SYS_UPTIME_MS, 0, 0, 0);
    write("[user] pos: pid ");
    printNum(pid);
    write(", uptime ");
    printNum(ms);
    write(" ms\n");

    write(if (ok) "[user] pos: loaded from ELF, argv and envp intact\n" else "[user] pos: checks FAILED\n");

    // Behaviours the lifecycle probe drives. They are ordinary program choices,
    // not kernel modes: the supervisor only sees a pid, an exit status or a
    // fault, exactly as it would for any real service.
    if (equal(mode, "crash")) {
        write("[user] pos: crashing on purpose\n");
        const bad: *volatile u64 = @ptrFromInt(0x10);
        bad.* = 0xDEAD;
        exit(9);
    }
    if (equal(mode, "serve")) {
        write("[user] pos: serve ok\n");
        exit(0);
    }
    if (equal(mode, "loop")) {
        write("[user] pos: looping until killed\n");
        while (true) {
            _ = syscall3(SYS_SLEEP_MS, 20, 0, 0);
        }
    }
    if (equal(mode, "resolve")) {
        // The call site this phase exists for: ask for a service by name, and if
        // it is not usable say so and serve without it rather than fault.
        const target: []const u8 = if (argc > 2) sliceOf(argv[2]) else "pos://";
        var found_pid: u64 = 0;
        const reason = syscall3(SYS_RESOLVE, @intFromPtr(target.ptr), target.len, @intFromPtr(&found_pid));
        write("[user] pos: ");
        write(target);
        if (reason == 0) {
            write(" -> pid ");
            printNum(found_pid);
            write("\n");
        } else {
            write(" unavailable (");
            write(reasonLabel(reason));
            write("), serving without it\n");
        }
        // The exit code *is* the reason, so a caller (and the probe) can check
        // the degradation without parsing text.
        exit(reason);
    }

    exit(if (ok) 42 else 9);
}
