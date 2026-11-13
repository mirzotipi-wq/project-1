//! Cassa POS OS — kernel entry point and boot sequence.
//!
//! Boot order matters and is documented here once:
//!   1. mask interrupts, enable FP/SIMD, give SP_EL0 a valid emergency stack
//!   2. discover the machine from the device tree, bring up the console
//!   3. physical page allocator, MMU (W^X), kernel heap
//!   4. exception vectors, interrupt controller, timer, unmask IRQs
//!   5. boot self-tests, then the kernel shell
//!
//! Everything below is Zig. The entry stub uses Zig inline assembly; there is
//! no assembly file in this tree.

const std = @import("std");
const builtin = @import("builtin");

const cpu = @import("arch/aarch64/cpu.zig");
const mmu = @import("arch/aarch64/mmu.zig");
const exceptions = @import("arch/aarch64/exceptions.zig");
const gic = @import("arch/aarch64/gic.zig");
const timer = @import("arch/aarch64/timer.zig");
const uart = @import("devices/pl011.zig");
const klog = @import("kernel/klog.zig");
const machine = @import("kernel/machine.zig");
const Pmm = @import("kernel/pmm.zig");
const heap = @import("kernel/heap.zig");
const shell = @import("kernel/shell.zig");
const symbols = @import("kernel/symbols.zig");
const panicHook = @import("kernel/panic.zig");
const percpu = @import("kernel/percpu.zig");
const sched = @import("kernel/sched.zig");
const smp = @import("kernel/smp.zig");
const process = @import("kernel/process.zig");

/// Global kernel state. Single-core for now; phase 18 moves these per-CPU.
var g_machine: machine.Machine = undefined;
var g_pmm: Pmm.PageAllocator = undefined;
var g_heap: heap.Heap = undefined;
var g_shell_ctx: shell.Context = undefined;

fn shellEntry(_: ?*anyopaque) void {
    shell.run(g_shell_ctx);
}

const boot_stack_size = 32 * 1024;
var boot_stack: [boot_stack_size]u8 align(16) = undefined;
var emergency_stack: [4096]u8 align(16) = undefined;

/// 4 GiB of RAM at 4 KiB granularity: 1,048,576 pages = 16,384 bitmap words.
var pmm_bitmap: [16384]u64 align(8) = undefined;

comptime {
    @export(&boot_stack, .{ .name = "boot_stack" });
}

pub const panic = std.debug.FullPanic(panicHook.hook);

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

pub export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {
    asm volatile (
        \\msr daifset, #0xf          // mask everything while we set up
        \\mov x19, x0                // x0 = device tree pointer from firmware
        \\
        \\// Zero .bss before touching anything that lives in it.
        \\adrp x2, __bss_start
        \\add  x2, x2, :lo12:__bss_start
        \\adrp x3, __bss_end
        \\add  x3, x3, :lo12:__bss_end
        \\1:
        \\  cmp x2, x3
        \\  b.hs 2f
        \\  str xzr, [x2], #8
        \\  b 1b
        \\2:
        \\
        \\// Kernel stack lives on SP_EL1.
        \\msr spsel, #1
        \\adrp x9, boot_stack
        \\add  x9, x9, :lo12:boot_stack
        \\add  x9, x9, #32768
        \\mov  sp, x9
        \\
        \\mov x0, x19
        \\b   kmain
    );
}

fn setupSp0() void {
    // Exceptions taken from EL1 with SP_EL0 selected must not land on a null
    // stack, so SP_EL0 points at a small emergency stack.
    const top = @intFromPtr(&emergency_stack) + emergency_stack.len;
    asm volatile ("msr spsel, #0" ::: "memory");
    asm volatile ("mov sp, %[top]" :: [top] "r" (top) : "memory");
    asm volatile ("msr spsel, #1" ::: "memory");
}

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn banner() void {
    uart.writeAll("\n");
    uart.writeAll("  ┌─────────────────────────────────────────────────────┐\n");
    uart.writeAll("  │  CASSA POS OS                                       │\n");
    uart.writeAll("  │  a point-of-sale operating system · AArch64         │\n");
    uart.writeAll("  │  100% Zig · no libc · no borrowed kernel            │\n");
    uart.writeAll("  └─────────────────────────────────────────────────────┘\n");
    uart.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Boot self-tests (phase 20 groundwork): every boot proves the core works
// ---------------------------------------------------------------------------

fn runSelfTest(p: *Pmm.PageAllocator, h: *heap.Heap) bool {
    var ok = true;

    // Physical pages: allocate, touch both ends, release, accounting restored.
    const before = p.stats().free_pages;
    if (p.alloc()) |page| {
        const bytes: [*]u8 = @ptrFromInt(page);
        bytes[0] = 0x5A;
        bytes[Pmm.page_size - 1] = 0xA5;
        if (!p.allocated(page)) ok = false;
        p.free(page);
        if (p.stats().free_pages != before) ok = false;
    } else {
        ok = false;
    }

    // Heap: raw allocation, containers and formatted strings.
    const a = h.allocator();
    if (a.alloc(u8, 512)) |bytes| {
        @memset(bytes, 0xCC);
        a.free(bytes);
    } else |_| {
        ok = false;
    }

    var list = std.ArrayList(u32).init(a);
    defer list.deinit();
    for (0..64) |i| {
        list.append(@intCast(i)) catch {
            ok = false;
            break;
        };
    }
    if (list.items.len != 64) ok = false;

    const text = std.fmt.allocPrint(a, "cassa/{d}", .{list.items.len}) catch {
        ok = false;
        return reportSelfTest(ok, p, h);
    };
    a.free(text);

    if (g_machine.ram_size == 0) ok = false;
    return reportSelfTest(ok, p, h);
}

fn reportSelfTest(ok: bool, p: *Pmm.PageAllocator, h: *heap.Heap) bool {
    const ps = p.stats();
    const hs = h.stats();
    klog.info("selftest", "pmm: {d}/{d} pages free · heap: {d} KiB used in {d} blocks · result: {s}", .{
        ps.free_pages,
        ps.total_pages,
        hs.used_bytes / 1024,
        hs.blocks,
        if (ok) "PASS" else "FAIL",
    });
    return ok;
}

// ---------------------------------------------------------------------------
// kmain
// ---------------------------------------------------------------------------

pub export fn kmain(dtb: usize) callconv(.C) noreturn {
    cpu.allInterruptsDisable();
    cpu.enableFp();
    // Bind this core to its per-CPU block before anything can fault, so even
    // an early exception report knows which core it came from.
    percpu.bindSelf(0);
    percpu.cpus[0].id = 0;
    percpu.cpus[0].online = true;
    setupSp0();

    klog.setCounterFrequency(cpu.cntFrq());

    // First pass is silent: it only tells us where the console is. Firmware
    // (or the fallback defaults) hands us the UART before anything can log.
    g_machine = machine.detect(dtb);
    uart.install(uart.Pl011.init(g_machine.uart_base, g_machine.uart_clock, 115200));

    banner();
    klog.info("boot", "firmware handed over x0=0x{x}", .{dtb});
    klog.info("boot", "Cassa POS OS {s} starting", .{shell.build_version});
    klog.info("boot", "cpu: EL{d}, MPIDR 0x{x}, Zig {d}.{d}.{d}", .{
        cpu.currentEl(),
        cpu.sysRead("mpidr_el1"),
        builtin.zig_version.major,
        builtin.zig_version.minor,
        builtin.zig_version.patch,
    });
    machine.describe(&g_machine);

    const kernel = symbols.kernelRange();
    klog.info("boot", "kernel image 0x{x}..0x{x} ({d} KiB)", .{ kernel.start, kernel.end, (kernel.end - kernel.start) / 1024 });

    // ---- heap arena directly after the kernel image ------------------------
    const heap_bytes = 8 * 1024 * 1024;
    const heap_start = alignUp(kernel.end, 2 * 1024 * 1024);
    const ram_end = g_machine.ram_base + g_machine.ram_size;
    if (heap_start + heap_bytes > ram_end) {
        klog.err("boot", "not enough RAM for the kernel heap (need 0x{x}, RAM ends 0x{x})", .{ heap_start + heap_bytes, ram_end });
        cpu.halt();
    }

    // ---- physical memory ---------------------------------------------------
    g_pmm = Pmm.PageAllocator.init(&pmm_bitmap, g_machine.ram_base, g_machine.ram_size);
    g_pmm.reserveRange(kernel.start, kernel.end - kernel.start);
    g_pmm.reserveRange(heap_start, heap_bytes);
    if (g_machine.dtb != 0 and g_machine.dtb_size != 0) {
        g_pmm.reserveRange(g_machine.dtb, g_machine.dtb_size);
    }
    const ps = g_pmm.stats();
    klog.info("pmm", "{d} MiB managed, {d} pages free, {d} reserved", .{
        ps.total_bytes / (1024 * 1024),
        ps.free_pages,
        ps.used_pages,
    });

    // ---- MMU ---------------------------------------------------------------
    var regions: [4]mmu.Region = undefined;
    var region_count: usize = 0;
    if (g_machine.ram_base > 0) {
        // All MMIO below RAM: UART, GIC, virtio-mmio, PCIe window.
        regions[region_count] = .{ .base = 0, .size = g_machine.ram_base, .kind = .device };
        region_count += 1;
    }
    regions[region_count] = .{ .base = g_machine.ram_base, .size = g_machine.ram_size, .kind = .normal };
    region_count += 1;
    // PCIe ECAM window used by the virt machine (phase 32 maps BARs inside it).
    regions[region_count] = .{ .base = 0x40_0000_0000, .size = 0x1000_0000, .kind = .device };
    region_count += 1;

    // Exceptions first: the vector table is patched while text is still
    // writable, and the MMU then maps it read-only and executable.
    exceptions.init();
    klog.info("exc", "vector table installed (16 entries)", .{});

    mmu.init(regions[0..region_count]);
    mmu.enable();

    // ---- heap --------------------------------------------------------------
    const heap_slice: []u8 = @as([*]u8, @ptrFromInt(heap_start))[0..heap_bytes];
    g_heap = heap.Heap.init(heap_slice);
    klog.info("heap", "arena 0x{x}..0x{x} ({d} MiB)", .{ heap_start, heap_start + heap_bytes, heap_bytes / (1024 * 1024) });

    // ---- interrupts and time ----------------------------------------------
    gic.init(g_machine.gic_dist, g_machine.gic_second, switch (g_machine.gic_kind) {
        .v2 => .v2,
        .v3 => .v3,
    });

    timer.init(1000) catch |err| {
        klog.err("timer", "generic timer unavailable: {s}", .{@errorName(err)});
        cpu.halt();
    };

    // The scheduler must exist before the first interrupt can arrive: the tick
    // handler assumes `current` is valid on whichever core takes it. Secondary
    // cores are released here too, so every core that can take a tick already
    // has an idle thread and a bound per-CPU block.
    sched.init(&g_pmm);
    process.init(&g_pmm);
    smp.startAll(&g_machine);

    cpu.irqEnable();
    klog.info("boot", "interrupts unmasked; boot complete", .{});

    const ok = runSelfTest(&g_pmm, &g_heap);
    if (!ok) klog.warn("boot", "one or more boot self-tests failed", .{});

    g_shell_ctx = .{
        .machine = &g_machine,
        .pmm = &g_pmm,
        .heap = &g_heap,
        .selftest = runSelfTest,
    };
    if (sched.spawn("shell", shellEntry, null) == null) {
        klog.err("boot", "could not create the shell thread", .{});
        cpu.halt();
    }
    klog.info("boot", "scheduler running: {d} core(s), {d} thread(s)", .{
        percpu.onlineCount(),
        sched.threadCount(),
    });

    // The boot context retires here; this core's idle thread takes over and the
    // shell runs as an ordinary preemptible thread.
    sched.exitCurrent();
}

/// Deliberate fault used by the shell to prove the exception path works.
pub fn provokeFault() void {
    const bad: *volatile u64 = @ptrFromInt(0x10);
    bad.* = 0xdead_beef;
}
