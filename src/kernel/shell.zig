//! Kernel shell over the serial console (phase 12).
//!
//! Deliberately small: it is the debugging surface for the kernel until the
//! real POS shell exists in user space (phase 59). Commands never allocate.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const timer = @import("../arch/aarch64/timer.zig");
const gic = @import("../arch/aarch64/gic.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const uart = @import("../devices/pl011.zig");
const klog = @import("klog.zig");
const irq = @import("irq.zig");
const machine = @import("machine.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const symbols = @import("symbols.zig");

pub const Context = struct {
    machine: *const machine.Machine,
    pmm: *pmm.PageAllocator,
    heap: *heap.Heap,
    selftest: *const fn (*pmm.PageAllocator, *heap.Heap) bool,
};

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

fn prompt() void {
    out("cassa> ", .{});
}

fn printHelp() void {
    out(
        \\
        \\  help                 this list
        \\  info                 machine and build information
        \\  mem                  physical page allocator statistics
        \\  heap                 kernel heap statistics
        \\  time                 uptime, tick count, counter frequency
        \\  irq                  interrupt controller state
        \\  map <addr>           translate a virtual address
        \\  selftest             run the boot self-tests
        \\  mark <text>          print a timestamped marker
        \\  echo <text>          echo arguments
        \\  svc                  exercise the SVC trap path
        \\  textwrite            attempt to write kernel text (W^X proof)
        \\  fault                trigger a deliberate data abort (halts)
        \\  panic                trigger a deliberate kernel panic (halts)
        \\  reboot               warm reset via PSCI
        \\  halt                 stop the CPU
        \\
    , .{});
}

fn cmdInfo(ctx: Context) void {
    const ks = symbols.kernelRange();
    out("  build        : Cassa {s} ({s}, {s})\n", .{ build_version, @tagName(@import("builtin").mode), @tagName(@import("builtin").cpu.arch) });
    out("  kernel image : 0x{x} .. 0x{x} ({d} KiB)\n", .{ ks.start, ks.end, (ks.end - ks.start) / 1024 });
    out("  machine      : {s}\n", .{ctx.machine.model});
    out("  cpus         : 1 online (SMP in phase 18)\n", .{});
    out("  boot dtb     : 0x{x} ({d} bytes, {s})\n", .{ ctx.machine.dtb, ctx.machine.dtb_size, if (ctx.machine.fdt_valid) "parsed" else "invalid" });
    out("  current EL   : EL{d}\n", .{cpu.currentEl()});
}

fn cmdMem(ctx: Context) void {
    const s = ctx.pmm.stats();
    out("  total   : {d} MiB in {d} pages\n", .{ s.total_bytes / (1024 * 1024), s.total_pages });
    out("  free    : {d} MiB in {d} pages\n", .{ s.free_bytes / (1024 * 1024), s.free_pages });
    out("  used    : {d} MiB\n", .{s.used_pages * pmm.page_size / (1024 * 1024)});
    out("  largest : {d} pages contiguous\n", .{ctx.pmm.largestFreeRun()});
    out("  base    : 0x{x}\n", .{ctx.pmm.base});
}

fn cmdHeap(ctx: Context) void {
    const s = ctx.heap.stats();
    out("  arena   : {d} KiB\n", .{s.total_bytes / 1024});
    out("  used    : {d} KiB\n", .{s.used_bytes / 1024});
    out("  free    : {d} KiB\n", .{s.free_bytes / 1024});
    out("  blocks  : {d} (largest free {d} KiB)\n", .{ s.blocks, s.largest_free / 1024 });
}

fn cmdTime(_: Context) void {
    out("  uptime  : {d}.{d:0>3} s\n", .{ timer.uptimeMs() / 1000, timer.uptimeMs() % 1000 });
    out("  ticks   : {d} @ {d} Hz\n", .{ timer.ticksCount(), timer.tickHz() });
    out("  counter : {d} Hz\n", .{timer.frequencyHz()});
    out("  now ns  : {d}\n", .{timer.uptimeNs()});
}

fn cmdIrq(_: Context) void {
    const s = irq.stats();
    out("  gic     : {s} ({s})\n", .{ @tagName(gic.getVersion()), if (gic.isReady()) "ready" else "not initialised" });
    out("  timer   : PPI {d}, {d} interrupts\n", .{ timer.timer_intid, irq.countFor(timer.timer_intid) });
    out("  spurious: {d}\n", .{s.spurious});
    out("  unhandled: {d}\n", .{s.unhandled});
    out("  irq mask: {s}\n", .{if (cpu.irqsEnabled()) "open" else "closed"});
}

fn cmdMap(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const arg = tokens.next() orelse {
        out("usage: map <hex-address>\n", .{});
        return;
    };
    const addr = std.fmt.parseInt(usize, arg, 16) catch {
        out("invalid address: {s}\n", .{arg});
        return;
    };
    if (mmu.translate(addr)) |pa| {
        out("  0x{x} -> 0x{x}\n", .{ addr, pa });
    } else {
        out("  0x{x} -> unmapped\n", .{addr});
    }
}

/// Prove the SVC/syscall path: x0 = buffer, x1 = length, syscall 1 = debug_write.
fn cmdSvc() void {
    const msg = "hello from the kernel via SVC\n";
    var result: u64 = undefined;
    asm volatile ("svc #1"
        : [ret] "={x0}" (result),
        : [ptr] "{x0}" (@intFromPtr(msg.ptr)),
          [len] "{x1}" (msg.len),
        : "memory"
    );
    out("  svc wrote {d} bytes\n", .{result});
}

/// Prove W^X: kernel text is mapped read-only, so this must fault.
fn cmdTextWrite() void {
    out("  writing to kernel text at 0x{x}...\n", .{@intFromPtr(&symbols.__text_start)});
    const p: *volatile u8 = @ptrFromInt(@intFromPtr(&symbols.__text_start));
    p.* = 0;
}

fn cmdFsFault() void {
    out("  provoking an unaligned/invalid access at 0x10...\n", .{});
    const bad: *volatile u64 = @ptrFromInt(0x10);
    bad.* = 0xdead_beef;
}

pub const build_version = "0.1.0-dev";

fn execute(ctx: Context, line: []const u8) void {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const command = tokens.next() orelse return;

    if (std.mem.eql(u8, command, "help")) {
        printHelp();
    } else if (std.mem.eql(u8, command, "info")) {
        cmdInfo(ctx);
    } else if (std.mem.eql(u8, command, "mem")) {
        cmdMem(ctx);
    } else if (std.mem.eql(u8, command, "heap")) {
        cmdHeap(ctx);
    } else if (std.mem.eql(u8, command, "time") or std.mem.eql(u8, command, "uptime")) {
        cmdTime(ctx);
    } else if (std.mem.eql(u8, command, "irq")) {
        cmdIrq(ctx);
    } else if (std.mem.eql(u8, command, "map")) {
        cmdMap(&tokens);
    } else if (std.mem.eql(u8, command, "selftest")) {
        if (ctx.selftest(ctx.pmm, ctx.heap)) {
            out("  self-tests: PASS\n", .{});
        } else {
            out("  self-tests: FAIL\n", .{});
        }
    } else if (std.mem.eql(u8, command, "mark")) {
        const text = tokens.rest();
        out("  [{d}.{d:0>3}] {s}\n", .{ timer.uptimeMs() / 1000, timer.uptimeMs() % 1000, text });
    } else if (std.mem.eql(u8, command, "echo")) {
        out("  {s}\n", .{tokens.rest()});
    } else if (std.mem.eql(u8, command, "svc")) {
        cmdSvc();
    } else if (std.mem.eql(u8, command, "textwrite")) {
        cmdTextWrite();
    } else if (std.mem.eql(u8, command, "fault")) {
        cmdFsFault();
    } else if (std.mem.eql(u8, command, "panic")) {
        @panic("panic requested from the kernel shell");
    } else if (std.mem.eql(u8, command, "reboot")) {
        out("  resetting...\n", .{});
        cpu.systemReset();
    } else if (std.mem.eql(u8, command, "halt")) {
        out("  halted\n", .{});
        cpu.halt();
    } else {
        out("  unknown command: {s} (try 'help')\n", .{command});
    }
}

pub fn run(ctx: Context) noreturn {
    var line: [160]u8 = undefined;
    var len: usize = 0;
    prompt();

    while (true) {
        if (uart.tryGetc()) |c| {
            switch (c) {
                '\r', '\n' => {
                    out("\n", .{});
                    execute(ctx, line[0..len]);
                    len = 0;
                    prompt();
                },
                0x7f, 0x08 => {
                    if (len > 0) {
                        len -= 1;
                        out("\x08 \x08", .{});
                    }
                },
                0x03 => {
                    len = 0;
                    out("^C\n", .{});
                    prompt();
                },
                0x15 => {
                    len = 0;
                    out("\n", .{});
                    prompt();
                },
                else => {
                    if (c >= 0x20 and c < 0x7f and len < line.len) {
                        line[len] = c;
                        len += 1;
                        uart.putc(c);
                    }
                },
            }
        } else {
            cpu.wfe();
        }
    }
}
