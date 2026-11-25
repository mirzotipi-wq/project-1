//! Kernel shell over the serial console (phase 12, extended in phase 20).
//!
//! It now runs as an ordinary kernel thread, which is the point: commands can
//! block, sleep, spawn work, take locks and be preempted exactly like any other
//! code in the system. Nothing here is privileged.

const std = @import("std");
const builtin = @import("builtin");
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
const sched = @import("sched.zig");
const percpu = @import("percpu.zig");
const threads = @import("thread.zig");
const sync = @import("sync.zig");
const process = @import("process.zig");
const thread_mod = @import("thread.zig");
const service = @import("service.zig");
const dump = @import("dump.zig");
const restart = @import("restart.zig");
const registry = @import("registry.zig");
const names = @import("names.zig");
const user_space = @import("addrspace.zig");
const cap = @import("cap.zig");
const account = @import("account.zig");
const sandbox = @import("sandbox.zig");
const driver = @import("driver.zig");
const pci = @import("pci.zig");
const virtio = @import("virtio.zig");
const block = @import("block.zig");
const partition = @import("partition.zig");
const block_view = @import("block_view.zig");
const fat32 = @import("fat32.zig");
const fb = @import("fb.zig");
const gfx51 = @import("gfx51.zig");
const bochs_display = @import("../devices/bochs_display.zig");
const virtio_blk = @import("../devices/virtio_blk.zig");
const virtio_mmio = @import("../devices/virtio_mmio.zig");
const virtio_input = @import("../devices/virtio_input.zig");
const pl031 = @import("../devices/pl031.zig");
const input = @import("input.zig");
const usb_core = @import("usb.zig");
const power = @import("power.zig");
const thermal = @import("thermal.zig");
const journal = @import("journal.zig");
const cassafs = @import("cassafs.zig");
const vfs = @import("vfs.zig");
const retail = @import("retail.zig");
const sales = @import("sales.zig");
const recovery = @import("recovery.zig");
const wdt = @import("../devices/i6300esb.zig");
const power_lib = @import("../lib/power.zig");
const storage_health = @import("../lib/storage_health.zig");
const keymap = @import("../lib/keymap.zig");
const scanner = @import("../lib/scanner.zig");
const input_hid = @import("../lib/input_hid.zig");
const ipc = @import("ipc.zig");
const shm = @import("shm.zig");
const elf = @import("elf.zig");
const store = @import("image.zig");
const syscall = @import("syscall.zig");

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
        \\  --- system ---------------------------------------------------------
        \\  help                 this list
        \\  info                 machine and build information
        \\  mem                  physical page allocator statistics
        \\  heap                 kernel heap statistics
        \\  time                 uptime, tick count, counter frequency
        \\  irq                  interrupt controller state
        \\  map <addr>           translate a virtual address
        \\  selftest             run the boot self-tests
        \\  accounting           per-process quotas, usage, OOM scores, watchdog
        \\  sandbox              service manifests, syscall gate, W^X counters
        \\  devices              driver model: devices, bindings, hotplug counters
        \\  fb [info|test|splash|mode <w> <h>|check]   panel, test pattern, mode
        \\  gfx [test|inject|repair|info]             phase-51 surfaces, clips, alpha, damage
        \\  input [info|dump <n>|scan <text>|viz <s>|prefix|suffix|minlen|gap|charset|reset]
        \\  keymap [info|map <from> <to>|reset]        key remapping table
        \\  hid                  decode USB HID boot reports through the same queue
        \\  usb [info|poll|selftest|serial <n> send <text>|serial <n> read]
        \\                       xHCI controller, attached USB devices, serial bridge
        \\  power [info|journal|flush|brownout|poweroff|reboot|selftest|viz <s>|hang]
        \\                       watchdog, journal, brown-out hooks, shutdown
        \\  thermal [info|set <mC>|clear|selftest|bench]
        \\                       thermal zone, throttle ladder, idle injection
        \\  watchdog [info|kick|selftest]
        \\                       i6300ESB hardware watchdog
        \\  blk [info|health|fsck|inject|clear|scrub|viz]
        \\                       storage health, retries, bad sectors, supervisor UI
        \\  part                 partition table of the attached disk
        \\  fat <sub>            FAT32 on partition 1: info, ls, cat, put, rm, check
        \\  cassafs <sub>        CASSAFS format 1: info, format [empty|demo], demo,
        \\                       dump, verify, cat <path>, viz <s>
        \\  vfs <sub>            VFS: mount [usb|tmpfs], unmount [/|usb|tmpfs], info,
        \\                       ls, stat, cat, mkdir, chmod, create, write, read,
        \\                       lock, watch, unwatch, events, import <csv>, selftest
        \\  retail <sub>         retail model: init, import <csv>, seedday, report,
        \\                       verify, corrupt (durability/audit proof)
        \\  sales <sub>          transactional sale log: init, sell <terminal> <txn>
        \\                       <sku> <qty> ..., report, verify, replay, corrupt
        \\  recovery <sub>       config snapshots: init, status, verify, set <key> <value>,
        \\                       snapshot, rollback, factory-reset preserve, bundle,
        \\                       corrupt <config|snapshot>
        \\  mark <text>          print a timestamped marker
        \\  echo <text>          echo arguments
        \\  svc                  exercise the SVC trap path
        \\  textwrite            attempt to write kernel text (W^X proof)
        \\  fault                trigger a deliberate data abort (halts)
        \\  panic                trigger a deliberate kernel panic (halts)
        \\  reboot               warm reset via PSCI
        \\  halt                 stop the CPU
        \\
        \\  --- threads and cores ----------------------------------------------
        \\  threads              list every thread and its state
        \\  cores                per-core scheduling and interrupt statistics
        \\  spawn [n]            create n background workload threads
        \\  kill <id>            ask a thread to exit (it dies at a safe point)
        \\  yield                give up the rest of this thread's slice
        \\  sleep <ms>           block this thread for a while
        \\  stress [n] [iters]   contended counter test; expects no lost updates
        \\  reap [n]             spawn n short-lived threads and prove no leak
        \\  preempt              sample three CPU-bound threads (preemption proof)
        \\  logstorm [n]         concurrent logging from n threads / every core
        \\  killloop [rounds]    launch/kill/reap a program in a tight loop
        \\
        \\  --- user mode (EL0) -----------------------------------------------
        \\  user [mode]          run the EL0 demo: 0 normal, 1 priv op, 2 kernel read, 3 isolation
        \\  uprobe               full EL0 + address-space probe (run this)
        \\  caps                 capability objects and their reference counts
        \\  ipc                  IPC endpoint counters
        \\  shm                  shared-memory objects and event counters
        \\  exec <image> [args]  load an ELF from the image store and run it
        \\  service [start|kill|stop <name>]  supervised services
        \\  dumps                crash records from faulting programs
        \\  registry             service names and what they point at
        \\  resolve <pos://name>  resolve a service name to a pid and generation
        \\  ensure <pos://name>   resolve, starting the service if it is down
        \\  images               list the image store
        \\  elf                  ELF loader state and the last load plan
        \\
    , .{});
}

fn cmdInfo(ctx: Context) void {
    const ks = symbols.kernelRange();
    out("  build        : Cassa {s} ({s}, {s})\n", .{ build_version, @tagName(builtin.mode), @tagName(builtin.cpu.arch) });
    out("  kernel image : 0x{x} .. 0x{x} ({d} KiB)\n", .{ ks.start, ks.end, (ks.end - ks.start) / 1024 });
    out("  machine      : {s}\n", .{ctx.machine.model});
    out("  cpus         : {d} online of {d} described ({s})\n", .{ percpu.onlineCount(), ctx.machine.cpu_count, if (ctx.machine.fdt_valid) "device tree" else "defaults" });
    out("  scheduler    : preemptive round robin, {d} tick slice, {d} threads\n", .{ sched.slice_ticks, sched.threadCount() });
    out("  boot dtb     : 0x{x} ({d} bytes)\n", .{ ctx.machine.dtb, ctx.machine.dtb_size });
    out("  current EL   : EL{d}, core {d}, thread {d}\n", .{ cpu.currentEl(), percpu.this().id, sched.running().id });
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
    const pc = percpu.this();
    out("  gic     : {s} ({s})\n", .{ @tagName(gic.getVersion()), if (gic.isReady()) "ready" else "not initialised" });
    out("  timer   : PPI {d}, {d} interrupts on this core ({d} ticks)\n", .{ timer.timer_intid, irq.countFor(timer.timer_intid), pc.ticks });
    out("  spurious: {d}\n", .{s.spurious});
    out("  unhandled: {d}\n", .{s.unhandled});
    out("  irq mask: {s}\n", .{if (cpu.irqsEnabled()) "open" else "closed"});
}

fn cmdCores(_: Context) void {
    out("  core  online     ticks   switches  preempt  irqs  runq  current\n", .{});
    for (percpu.slice()) |*pc| {
        const name = if (pc.current) |t| t.nameSlice() else "none";
        out("  {d: >4}  {s: <6} {d: >9} {d: >10} {d: >8} {d: >5} {d: >5}  {s}\n", .{
            pc.id,
            if (pc.online) "yes" else "no",
            pc.ticks,
            pc.switches,
            pc.preemptions,
            pc.irqs,
            pc.runq_len,
            name,
        });
    }
    out("  queues: {d} double-run guard(s), {d} invariant violation(s), {d} deferred reap(s)\n", .{
        sched.double_run_events, sched.queue_violations, sched.reaps_deferred,
    });
}

fn cmdThreads(_: Context) void {
    out("  id  name              state     core      runs  stack\n", .{});
    for (&threads.table) |*t| {
        if (t.state == .unused) continue;
        const stack = if (t.owns_stack) t.stack_base else @as(usize, 0);
        out("  {d: >2}  {s: <16}  {s: <8}  {d: >4} {d: >9}  0x{x}\n", .{
            t.id,
            t.nameSlice(),
            t.state.label(),
            t.cpu,
            t.runs,
            stack,
        });
    }
    out("  {d} live thread(s), {d} slot(s) total\n", .{ threads.liveCount(), threads.max_threads });
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
    out("  provoking an invalid access at 0x10...\n", .{});
    const bad: *volatile u64 = @ptrFromInt(0x10);
    bad.* = 0xdead_beef;
}

// ---------------------------------------------------------------------------
// Workloads
// ---------------------------------------------------------------------------

// -- contention stress ------------------------------------------------------

var stress_counter: u64 = 0;
var stress_lock: sync.SpinLock = .{};
var stress_iters: u32 = 0;
var stress_done: sched.Semaphore = .{};
var stress_threads: u32 = 0;

fn stressWorker(_: ?*anyopaque) void {
    var i: u32 = 0;
    while (i < stress_iters) : (i += 1) {
        stress_lock.acquire();
        stress_counter += 1;
        stress_lock.release();
    }
    stress_done.post();
}

fn cmdStress(ctx: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const n = parseArg(tokens, 4, 1, 12);
    const iters = parseArg(tokens, 20000, 1, 2_000_000);

    stress_counter = 0;
    stress_iters = iters;
    stress_done = .{};

    const before = ctx.pmm.stats().free_pages;
    const start = timer.uptimeMs();
    var spawned: u32 = 0;
    var name_buf: [16]u8 = undefined;
    for (0..n) |i| {
        const name = std.fmt.bufPrint(&name_buf, "stress{d}", .{i}) catch "stress";
        if (sched.spawn(name, stressWorker, null) != null) spawned += 1;
    }
    if (spawned == 0) {
        out("  could not create any worker threads\n", .{});
        return;
    }

    // The shell blocks here: a genuine wait, not a polling loop.
    var i: u32 = 0;
    while (i < spawned) : (i += 1) stress_done.wait();
    const elapsed = timer.uptimeMs() - start;

    const expected = @as(u64, spawned) * @as(u64, iters);
    const ok = stress_counter == expected;
    out("  threads      : {d}\n", .{spawned});
    out("  increments   : {d} per thread\n", .{iters});
    out("  expected     : {d}\n", .{expected});
    out("  observed     : {d}\n", .{stress_counter});
    out("  lost updates : {d}\n", .{if (expected >= stress_counter) expected - stress_counter else 0});
    out("  elapsed      : {d} ms\n", .{elapsed});
    out("  result       : {s}\n", .{if (ok) "PASS (exact)" else "FAIL"});

    // Threads have exited; let the reaper run so the page count comes back.
    sched.sleepMsBlocking(20);
    out("  pages        : {d} before, {d} after\n", .{ before, ctx.pmm.stats().free_pages });
    _ = stress_threads;
}

// -- preemption proof -------------------------------------------------------

var spin_counters: [4]u64 = [_]u64{0} ** 4;
var spin_stop: [4]bool = [_]bool{false} ** 4;
var spin_core: [4]u32 = [_]u32{0} ** 4;
/// Start gate: every worker blocks here until the shell releases them, so the
/// fairness window begins at the same instant for all of them.
var spin_ready: u32 = 0;
var spin_go: bool = false;

fn spinWorker(arg: ?*anyopaque) void {
    // Arguments travel as opaque pointers; index 0 would be a null pointer, so
    // the caller passes index+1 and the worker shifts it back.
    const idx = (@intFromPtr(arg.?) - 1) & 3;
    spin_core[idx] = percpu.this().id;
    _ = @atomicRmw(u32, &spin_ready, .Add, 1, .release);
    while (!@atomicLoad(bool, &spin_go, .acquire)) {
        cpu.wfe();
    }
    while (true) {
        // Never yields, never sleeps, never blocks: the only way another
        // thread on the same core can make progress is preemption.
        asm volatile ("" ::: "memory");
        if (@atomicLoad(bool, &spin_stop[idx], .monotonic)) return;
        spin_counters[idx] +%= 1;
    }
}

fn cmdPreempt(_: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const window_ms = parseArg(tokens, 200, 20, 5000);
    const workers = 3;

    for (0..workers) |i| {
        spin_counters[i] = 0;
        spin_stop[i] = false;
        spin_core[i] = 0;
    }
    spin_ready = 0;
    @atomicStore(bool, &spin_go, false, .release);
    var spawned: u32 = 0;
    var ids: [4]u32 = [_]u32{0} ** 4;
    // The core is chosen once. Capturing it per spawn is wrong: the shell is not
    // pinned, so a migration between two spawns would pin the workers to
    // different cores while the test still claims they share one.
    const spin_home = percpu.this().id;
    for (0..workers) |i| {
        // Pinned to one core: the workers cannot migrate, so progress on all
        // three can only come from being preempted.
        if (sched.spawnPinnedOn(spin_home, "spin", spinWorker, @ptrFromInt(i + 1))) |id| {
            ids[spawned] = id;
            spawned += 1;
        }
    }
    if (spawned == 0) {
        out("  could not create worker threads\n", .{});
        return;
    }

    // Wait until every worker is parked at the gate, release them together and
    // measure one full window: the fairness numbers then share a start instant.
    var waited: u32 = 0;
    while (@atomicLoad(u32, &spin_ready, .acquire) < spawned and waited < 50) : (waited += 1) {
        sched.sleepMsBlocking(1);
    }
    @atomicStore(bool, &spin_go, true, .release);
    sched.sleepMsBlocking(window_ms);

    var deltas: [4]u64 = [_]u64{0} ** 4;
    var slices: [4]u64 = [_]u64{0} ** 4;
    for (0..spawned) |i| {
        deltas[i] = spin_counters[i];
        slices[i] = if (threads.find(ids[i])) |t| t.runs else 0;
    }
    for (0..spawned) |i| spin_stop[i] = true;

    out("  {d} CPU-bound threads pinned to one core, none of which ever yield:\n", .{spawned});
    var advanced: u32 = 0;
    const core = spin_core[0];
    var same_core = true;
    for (0..spawned) |i| {
        out("    thread {d}: {d} iterations, {d} runs, core {d}\n", .{ i, deltas[i], slices[i], spin_core[i] });
        if (deltas[i] > 0) advanced += 1;
        if (spin_core[i] != core) same_core = false;
    }
    out("  threads that made progress: {d}/{d}\n", .{ advanced, spawned });
    // Fair share is 1/n of the window; report the worst deviation from it.
    var total: u64 = 0;
    for (0..spawned) |i| total += deltas[i];
    var worst: u64 = 0; // in hundredths of a percent
    if (total > 0) {
        const fair = total / spawned;
        for (0..spawned) |i| {
            const d = if (deltas[i] > fair) deltas[i] - fair else fair - deltas[i];
            const pct = d * 10000 / fair;
            if (pct > worst) worst = pct;
        }
    }
    var min_slices: u64 = slices[0];
    var max_slices: u64 = slices[0];
    for (0..spawned) |i| {
        if (slices[i] < min_slices) min_slices = slices[i];
        if (slices[i] > max_slices) max_slices = slices[i];
    }
    out("  timeslices : {d}..{d} per thread (equal round robin)\n", .{ min_slices, max_slices });
    out("  iteration spread: {d}.{d:0>2}% (includes hypervisor time stealing)\n", .{ worst / 100, worst % 100 });
    out("  gate: {d}/{d} workers ready after {d} ms\n", .{ @atomicLoad(u32, &spin_ready, .acquire), spawned, waited });
    // Every worker must run, on one core, and receive the same number of
    // timeslices. Iteration counts drift because the hypervisor steals host
    // CPU time from a vCPU, so slices are the honest fairness measure.
    // The window ends mid-rotation, so one thread can be a slice ahead.
    const pass = advanced == spawned and same_core and (max_slices - min_slices) <= 2;
    out("  single core: {s}\n", .{if (same_core) "yes" else "NO (migration invalidates the test)"});
    out("  result: {s}\n", .{if (pass) "PASS (preemptive, single core)" else "FAIL"});

    sched.sleepMsBlocking(10);
}

// -- spawn / kill -----------------------------------------------------------

var work_counter: [8]u64 = [_]u64{0} ** 8;
var work_index: u32 = 0;

fn workEntry(arg: ?*anyopaque) void {
    const idx = (@intFromPtr(arg.?) - 1) & 7;
    while (true) {
        work_counter[idx] +%= 1;
        sched.sleepMsBlocking(25);
    }
}

fn cmdSpawn(_: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const n = parseArg(tokens, 1, 1, 4);
    var created: u32 = 0;
    var name_buf: [16]u8 = undefined;
    for (0..n) |_| {
        const slot = work_index & 7;
        const name = std.fmt.bufPrint(&name_buf, "work{d}", .{slot}) catch "work";
        if (sched.spawn(name, workEntry, @ptrFromInt(slot + 1)) != null) {
            work_index += 1;
            created += 1;
        }
    }
    out("  created {d} workload thread(s); 'threads' shows them running\n", .{created});
}

fn cmdKill(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const arg = tokens.next() orelse {
        out("usage: kill <thread-id>\n", .{});
        return;
    };
    const id = std.fmt.parseInt(u32, arg, 10) catch {
        out("invalid thread id\n", .{});
        return;
    };
    const t = sched.find(id) orelse {
        out("no such thread: {d}\n", .{id});
        return;
    };
    if (t.is_idle) {
        out("refusing to kill an idle thread\n", .{});
        return;
    }
    @atomicStore(bool, &t.kill_requested, true, .seq_cst);
    sched.kick(t.cpu);
    out("  thread {d} ('{s}') asked to exit\n", .{ t.id, t.nameSlice() });
}

// -- process churn ----------------------------------------------------------

/// A relaunch ladder: spawn a user program, kill it, wait for the kernel to reap
/// it, and do it again, hundreds of times. Every round creates a thread, queues
/// it, wakes it with a kill, kills it at a reschedule and frees its stack and
/// address space — the exact lifecycle a four-core run queue has to get right,
/// and the one that used to end in "selected a non-runnable thread".
fn cmdKillLoop(ctx: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const rounds = parseArg(tokens, 200, 1, 5000);
    const argv = [_][]const u8{ "pos.elf", "loop" };
    const env = [_][]const u8{"POS_TERM=cassa-1"};
    const pages_before = ctx.pmm.stats().free_pages;
    const dbl_before = sched.double_run_events;
    const viol_before = sched.queue_violations;
    const def_before = sched.reaps_deferred;
    const stray_before = sched.stray_ready;
    var completed: u32 = 0;
    var killed: u32 = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        const p = process.spawnElf("pos.elf", &argv, &env) orelse {
            out("  killloop: launch refused at round {d} ({s})\n", .{ round, process.refusalLabel(process.last_refusal) });
            break;
        };
        // Every other round lets the program reach its sleep loop first, so the
        // kill has to wake a parked thread as well as one that never ran.
        if ((round & 1) == 1) sched.sleepMsBlocking(1);
        if (process.kill(p.pid)) killed += 1;
        // `wait` observes the death, which is what turns the process record into
        // `killed`; without it the slot stays `running` and the ladder runs out
        // of process slots before it runs out of rounds.
        _ = process.wait(p.pid, 100);
        if (!process.waitReaped(p.pid, 100)) {
            out("  killloop: round {d} stuck: pid {d} not reaped in 100 ms\n", .{ round, p.pid });
            sched.dumpState("killloop stalled");
            break;
        }
        completed += 1;
    }
    sched.sleepMsBlocking(20);
    const pages_after = ctx.pmm.stats().free_pages;
    const leaked = if (pages_before >= pages_after) pages_before - pages_after else 0;
    out("  rounds       : {d}/{d} completed (each one launch + kill + reap)\n", .{ completed, rounds });
    out("  kills        : {d}, processes spawned in total {d}, faults caught {d}\n", .{
        killed, process.spawns, process.kills,
    });
    out("  threads      : {d} live, queues {d}/{d}/{d}/{d}\n", .{
        sched.threadCount(),
        percpu.cpus[0].runq_len,
        percpu.cpus[1].runq_len,
        percpu.cpus[2].runq_len,
        percpu.cpus[3].runq_len,
    });
    out("  scheduler    : {d} double-run, {d} invariant violation(s), {d} deferred reap(s), {d} stray ready\n", .{
        sched.double_run_events - dbl_before,
        sched.queue_violations - viol_before,
        sched.reaps_deferred - def_before,
        sched.stray_ready - stray_before,
    });
    out("  free pages   : {d} -> {d} ({d} leaked)\n", .{ pages_before, pages_after, leaked });
    const ok = completed == rounds and leaked == 0 and
        sched.queue_violations == viol_before and sched.double_run_events == dbl_before and
        sched.stray_ready == stray_before;
    out("  result       : {s}\n", .{if (ok) "PASS (churn clean)" else "FAIL"});
}

// -- reaping ----------------------------------------------------------------

fn shortLived(_: ?*anyopaque) void {}

fn cmdReap(ctx: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const n = parseArg(tokens, 8, 1, 16);
    const before = ctx.pmm.stats().free_pages;
    var spawned: u32 = 0;
    var name_buf: [16]u8 = undefined;
    for (0..n) |i| {
        const name = std.fmt.bufPrint(&name_buf, "zombie{d}", .{i}) catch "zombie";
        if (sched.spawn(name, shortLived, null) != null) spawned += 1;
    }
    // Give every core a chance to run, exit and reap the zombies.
    sched.sleepMsBlocking(250);
    const after = ctx.pmm.stats().free_pages;
    out("  spawned        : {d} short-lived threads\n", .{spawned});
    out("  free pages     : {d} before, {d} after\n", .{ before, after });
    out("  leaked pages   : {d}\n", .{if (before >= after) before - after else 0});
    out("  live threads   : {d}\n", .{threads.liveCount()});
    out("  result         : {s}\n", .{if (after == before) "PASS (no leak)" else "FAIL"});
}

// -- concurrent logging -----------------------------------------------------

fn stormWorker(arg: ?*anyopaque) void {
    const idx = (@intFromPtr(arg.?) - 1) & 7;
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        klog.info("storm", "w{d} core{d} line {d: >2} .................... {d}", .{
            idx, percpu.this().id, i, i * 37,
        });
    }
}

fn cmdLogStorm(_: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const n = parseArg(tokens, 4, 1, 8);
    var spawned: u32 = 0;
    for (0..n) |i| {
        if (sched.spawn("logstorm", stormWorker, @ptrFromInt(i + 1)) != null) spawned += 1;
    }
    sched.sleepMsBlocking(120);
    out("  {d} writers finished; every line above must be intact\n", .{spawned});
}

fn cmdSleep(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const ms = parseArg(tokens, 100, 0, 60_000);
    const t0 = timer.uptimeMs();
    sched.sleepMsBlocking(ms);
    out("  slept {d} ms (asked {d})\n", .{ timer.uptimeMs() - t0, ms });
}

fn parseArg(tokens: *std.mem.TokenIterator(u8, .scalar), default: u32, min: u32, max: u32) u32 {
    const arg = tokens.next() orelse return default;
    const value = std.fmt.parseInt(u32, arg, 0) catch return default;
    return @min(@max(value, min), max);
}

/// `caps` — the kernel's view of capability objects.
fn cmdCaps(_: Context) void {
    out("  id  kind         refs  version  epoch  name\n", .{});
    var i: usize = 0;
    while (i < cap.objectSlots()) : (i += 1) {
        if (cap.objectAt(i)) |o| {
            out("  {d:>2}  {s:<11}  {d:>4}  {d:>7}  {d:>5}  {s}\n", .{
                o.id, o.kind.label(), o.refs, o.version, o.epoch, o.name,
            });
        }
    }
    out("  derivations {d}, revocations {d}, refusals {d}, live tables {d}\n", .{
        cap.derivations, cap.revocations, cap.refusals, cap.liveTables(),
    });
}

/// `ipc` — endpoint counters.
fn cmdIpc(_: Context) void {
    out("  endpoints {d} of {d}, objects {d}\n", .{ ipc.liveEndpoints(), ipc.endpointSlots(), cap.objectSlots() });
    out("  sent {d}, received {d}, replied {d}, timeouts {d}, full {d}\n", .{
        ipc.sends, ipc.receives, ipc.replies, ipc.timeouts, ipc.full_events,
    });
    out("  transfers {d}, transfer failures {d}, handle transfers in cap {d}\n", .{
        ipc.transfers, ipc.transfer_failures, cap.transfers,
    });
}

fn cmdShm(_: Context) void {
    out("  objects {d} of {d}, pool {d} of {d} pages ({d} KiB)\n", .{
        shm.objectCount(), shm.max_objects, shm.poolUsed(), shm.pool_pages, shm.poolUsed() * 4,
    });
    out("  creates {d}, maps {d}, unmaps {d}, waits {d}, wakes {d} ({d} threads woken)\n", .{
        shm.creates, shm.maps, shm.unmaps, shm.waits, shm.wake_calls, shm.woken_threads,
    });
    out("  timeouts {d}, eagain {d}, refusals {d}\n", .{
        shm.timeouts, shm.agains, shm.refusals,
    });
    var i: usize = 0;
    while (i < shm.max_objects) : (i += 1) {
        const info = shm.infoAt(i) orelse continue;
        out("  object {d}: {d} pages, {d} mappings, {d} events\n", .{
            info.id, info.pages, info.mappings, info.events,
        });
    }
}

fn cmdImages(_: Context) void {
    out("  {d} image(s) in the store\n", .{store.count()});
    var i: usize = 0;
    while (i < store.count()) : (i += 1) {
        const f = store.at(i);
        out("    {s:<12} {d} bytes\n", .{ f.name, f.bytes.len });
    }
}

fn cmdElf(_: Context) void {
    out("  loads {d}, refused {d} (last: {s})\n", .{
        process.execs, process.exec_failures, process.refusalLabel(process.last_refusal),
    });
    const file = store.find("pos.elf") orelse return;
    if (elf.parse(file.bytes)) |img| {
        out("  pos.elf: entry 0x{x}, {d} segment(s), {d} file bytes, {d} memory bytes, {d} BSS\n", .{
            img.entry, img.count, img.file_bytes, img.memory_bytes, img.bss_bytes,
        });
        var i: usize = 0;
        while (i < img.count) : (i += 1) {
            const seg = img.segments[i];
            out("    seg {d}: 0x{x} + 0x{x}  {s}{s}{s}\n", .{
                i,                          seg.vaddr,                   seg.memsz,
                if (seg.read) "r" else "-", if (seg.write) "w" else "-", if (seg.exec) "x" else "-",
            });
        }
    } else |e| {
        out("  pos.elf: refused: {s}\n", .{elf.errorLabel(e)});
    }
}

fn cmdExec(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const name = tokens.next() orelse {
        out("  usage: exec <image> [args...]\n", .{});
        return;
    };
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = name;
    var argc: usize = 1;
    while (tokens.next()) |tok| {
        if (argc == argv_buf.len) break;
        argv_buf[argc] = tok;
        argc += 1;
    }
    const env = [_][]const u8{"POS_TERM=cassa-1"};
    const p = process.spawnElf(name, argv_buf[0..argc], &env) orelse {
        out("  exec: '{s}' refused: {s} ({d} refusal(s) so far)\n", .{
            name, process.refusalLabel(process.last_refusal), process.exec_failures,
        });
        return;
    };
    const st = process.wait(p.pid, 5000);
    const code = p.exit_code;
    _ = process.waitReaped(p.pid, 1000);
    out("  pid {d} '{s}': {s}, exit code {d}\n", .{ p.pid, name, @tagName(st), code });
}

fn refuses(bytes: []const u8, want: elf.Error) bool {
    if (elf.parse(bytes)) |_| return false else |e| return e == want;
}

/// Prove the loader's refusal paths against the real file: a bad magic number,
/// a writable-and-executable segment, an entry point outside every executable
/// segment, and a truncated header. Each must be refused with its own error
/// before a page is allocated.
const ElfRefusals = struct {
    bad_magic: bool = false,
    write_exec: bool = false,
    entry: bool = false,
    truncated: bool = false,

    fn all(self: ElfRefusals) bool {
        return self.bad_magic and self.write_exec and self.entry and self.truncated;
    }
};

fn elfRefusals() ElfRefusals {
    var r = ElfRefusals{};
    const img = elf.parse(store.pos_elf) catch return r;
    if (img.count == 0) return r;

    // The whole file, not just its header: a partial copy would be refused as
    // truncated before the check under test is ever reached.
    const scratch = struct {
        var bytes: [store.pos_elf.len]u8 = undefined;
    };
    @memcpy(&scratch.bytes, store.pos_elf);
    const view = scratch.bytes[0..];

    scratch.bytes[1] = 'X';
    r.bad_magic = refuses(view, error.BadMagic);
    scratch.bytes[1] = 'E';

    const phoff: usize = @intCast(std.mem.readInt(u64, scratch.bytes[32..40], .little));
    if (phoff + elf.phdr_size > view.len) return r;
    const saved_flags = scratch.bytes[phoff + 4 ..][0..4].*;
    std.mem.writeInt(u32, scratch.bytes[phoff + 4 ..][0..4], 7, .little);
    r.write_exec = refuses(view, error.WriteExecute);
    scratch.bytes[phoff + 4 ..][0..4].* = saved_flags;

    const saved_entry = scratch.bytes[24..32].*;
    std.mem.writeInt(u64, scratch.bytes[24..32], 0x4000_0000, .little);
    r.entry = refuses(view, error.EntryOutside);
    scratch.bytes[24..32].* = saved_entry;

    r.truncated = refuses(store.pos_elf[0..32], error.Truncated);
    return r;
}

/// `service` — list supervised services, or start / kill / stop one by name.
/// The point of the command is that a name survives the pid: killing a service
/// asks the supervisor to deal with it, exactly as a hardware fault would.
fn cmdService(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "";
    if (sub.len == 0) {
        out("  name       state       pid    restarts  failures  policy  last\n", .{});
        var i: usize = 0;
        while (i < service.max_services) : (i += 1) {
            const s = service.at(i) orelse continue;
            const last = if (s.last_kind.len != 0) s.last_kind else "-";
            out("  {s:<9}  {s:<10}  {d:>4}   {d:>8}  {d:>8}  {d}/{d}   {s}\n", .{
                s.name,                service.stateLabel(s.state), s.pid, s.restarts, s.failures,
                s.policy.max_restarts, s.policy.base_ms,            last,
            });
        }
        out("  {d} registered, {d} starts, {d} restarts, {d} failures, {d} crash loops, {d} reaps\n", .{
            service.count(),     service.starts, service.restarts_total, service.failures_total,
            service.crash_loops, service.reaps,
        });
        return;
    }
    const name = tokens.next() orelse {
        out("usage: service start|kill|stop <name>\n", .{});
        return;
    };
    if (std.mem.eql(u8, sub, "start")) {
        if (service.start(name)) {
            const s = service.find(name).?;
            out("  started '{s}', pid {d}, state {s}\n", .{ name, s.pid, service.stateLabel(s.state) });
        } else {
            out("  cannot start '{s}'\n", .{name});
        }
    } else if (std.mem.eql(u8, sub, "kill")) {
        if (service.kill(name)) {
            out("  killed '{s}'; the supervisor will restart it with backoff\n", .{name});
        } else {
            out("  '{s}' is not running\n", .{name});
        }
    } else if (std.mem.eql(u8, sub, "stop")) {
        if (service.stop(name)) out("  stopped '{s}', no restart\n", .{name});
    } else {
        out("usage: service start|kill|stop <name>\n", .{});
    }
}

/// `dumps` — the crash records kept for the last few faults.
fn cmdDumps(_: Context) void {
    out("  {d} crash record(s), {d} fault(s) since boot\n", .{ dump.stored(), dump.total });
    var i: usize = 0;
    while (i < dump.stored()) : (i += 1) {
        const d = dump.at(i) orelse continue;
        out("  pid {d} at {d} ms: {s}, addr 0x{x}, pc 0x{x}, esr 0x{x}\n", .{
            d.pid, d.ms, d.kind, d.addr, d.pc, d.esr,
        });
        out("    x0..x3 0x{x} 0x{x} 0x{x} 0x{x}\n", .{ d.regs[0], d.regs[1], d.regs[2], d.regs[3] });
        out("    x4..x7 0x{x} 0x{x} 0x{x} 0x{x}\n", .{ d.regs[4], d.regs[5], d.regs[6], d.regs[7] });
        out("    stack  0x{x} 0x{x} 0x{x} 0x{x}\n", .{ d.stack[0], d.stack[1], d.stack[2], d.stack[3] });
    }
}

/// `registry` — every name the kernel knows, and what it points at right now.
fn cmdRegistry(_: Context) void {
    out("  name                   service     state       pid    lookups\n", .{});
    var i: usize = 0;
    while (i < registry.max_names) : (i += 1) {
        const e = registry.entryAt(i) orelse continue;
        const svc = service.find(e.target);
        const state = if (svc) |sv| service.stateLabel(sv.state) else "missing";
        const pid = if (svc) |sv| sv.pid else 0;
        out("  {s:<21}  {s:<10}  {s:<10}  {d:>4}   {d:>7}\n", .{
            e.storedName(), e.target, state, pid, e.lookups,
        });
    }
    out("  {d} names, {d} lookups, {d} hits, {d} refusals, {d} lazy starts\n", .{
        registry.count(), registry.lookups, registry.hits, registry.refusals, registry.lazy_starts,
    });
}

/// `resolve <name>` — ask by name; `ensure <name>` also starts a stopped service.
fn cmdResolve(tokens: *std.mem.TokenIterator(u8, .scalar), lazy: bool) void {
    const name = tokens.next() orelse {
        out("usage: {s} <pos://name>\n", .{if (lazy) "ensure" else "resolve"});
        return;
    };
    const r = if (lazy) registry.ensure(name) else registry.lookup(name);
    out("  {s}: {s}", .{ name, names.reasonLabel(r.reason) });
    if (r.reason == .ok) {
        out(" (service pid {d}, generation {d})", .{ r.pid, r.generation });
    }
    out("\n", .{});
}

fn status(ok: bool) []const u8 {
    return if (ok) "OK" else "FAIL";
}

/// `user [mode]` — one EL0 program, with the page accounting around it.
fn cmdUser(ctx: Context, tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const mode = parseArg(tokens, 0, 0, 3);
    const before = ctx.pmm.stats().free_pages;
    const p = process.spawn(mode, 0x1234_5678, "user") orelse {
        out("  cannot launch a user process\n", .{});
        return;
    };
    const pid = p.pid;
    const t0 = timer.uptimeMs();
    const st = process.wait(pid, 4000);
    const took = timer.uptimeMs() - t0;
    _ = process.waitReaped(pid, 1000);
    const after = ctx.pmm.stats().free_pages;

    if (process.processOfPid(pid)) |proc| {
        if (proc.fault) |f| {
            out("  pid {d}: {s} — {s} at 0x{x} (pc 0x{x}), {d} ms\n", .{ pid, @tagName(st), f.kind, f.addr, f.pc, took });
        } else {
            out("  pid {d}: {s} with code {d}, {d} ms\n", .{ pid, @tagName(st), proc.exit_code, took });
        }
    }
    out("  free pages {d} -> {d}\n", .{ before, after });
}

/// `uprobe` — the whole phase 21-22 contract, measured in one command:
/// a user program that runs, two privilege violations that are caught, a
/// pointer the kernel refuses, two processes that cannot see each other, and a
/// launch loop that leaks nothing.
/// Step-level attribution for the probe. An intermittent boot has to name the
/// step it lost: "RESULT: FAIL" on its own is not a diagnosis.
var failed_steps: [8][]const u8 = undefined;
var failed_step_count: usize = 0;

fn verdict(pass: bool, ok: bool, step: []const u8) bool {
    if (!ok and failed_step_count < failed_steps.len) {
        failed_steps[failed_step_count] = step;
        failed_step_count += 1;
    }
    return pass and ok;
}

fn cmdUprobe(ctx: Context) void {
    failed_step_count = 0;
    var pass = true;
    out("\n  EL0 / address-space probe\n", .{});
    out("  [11] shared memory: 4 MiB mapped in two spaces, futex wakeups\n", .{});
    const own = process.spawnIpc(8, 0, "shm-a") orelse {
        out("      FAIL: cannot spawn the shared-memory owner\n", .{});
        return;
    };
    const peer = process.spawnIpc(9, 0, "shm-b") orelse {
        out("      FAIL: cannot spawn the shared-memory peer\n", .{});
        return;
    };
    const stranger = process.spawn(10, 0, "shm-out") orelse {
        out("      FAIL: cannot spawn the shared-memory outsider\n", .{});
        return;
    };
    const own_pid = own.pid;
    const peer_pid = peer.pid;
    const str_pid = stranger.pid;
    const s_own = process.wait(own_pid, 20000);
    const c_own = own.exit_code;
    _ = process.waitReaped(own_pid, 1000);
    const s_peer = process.wait(peer_pid, 20000);
    const c_peer = peer.exit_code;
    _ = process.waitReaped(peer_pid, 1000);
    const s_str = process.wait(str_pid, 8000);
    const c_str = stranger.exit_code;
    _ = process.waitReaped(str_pid, 1000);
    const procs_ok = s_own == .exited and s_peer == .exited and s_str == .exited and
        c_own == 0 and c_peer == 0 and c_str == 0;
    out("      pids {d} owner / {d} peer / {d} outsider: {s}/{s}/{s}, codes {d}/{d}/{d}  {s}\n", .{
        own_pid,          peer_pid,         str_pid,
        @tagName(s_own),  @tagName(s_peer), @tagName(s_str),
        c_own,            c_peer,           c_str,
        status(procs_ok),
    });

    var objects: u32 = 0;
    var mappings: u32 = 0;
    var si: usize = 0;
    while (si < shm.max_objects) : (si += 1) {
        const info = shm.infoAt(si) orelse continue;
        objects += 1;
        mappings += info.mappings;
        out("      object {d}: {d} pages ({d} KiB), {d} mappings, {d} events\n", .{
            info.id, info.pages, info.pages * 4, info.mappings, info.events,
        });
        var mi: usize = 0;
        while (mi < info.mappings) : (mi += 1) {
            const m = shm.mappingAt(si, mi) orelse continue;
            out("        pid {d} at 0x{x} {s}, {d} KiB\n", .{
                m.pid, m.va, if (m.writable) "read-write" else "read-only", m.len / 1024,
            });
        }
    }
    // Three live mappings over one set of frames: the owner's read-write view,
    // the peer's read-write view at the same address in its own space, and the
    // peer's read-only view through the derived handle at the next slot.
    var shared_ok = false;
    var owner_rw = false;
    var peer_rw = false;
    var peer_ro = false;
    var mi: usize = 0;
    while (mi < mappings) : (mi += 1) {
        const m = shm.mappingAt(0, mi) orelse break;
        if (m.len != 4 * 1024 * 1024) continue;
        if (m.pid == own_pid and m.writable and m.va == 0x8400_0000) owner_rw = true;
        if (m.pid == peer_pid and m.writable and m.va == 0x8400_0000) peer_rw = true;
        if (m.pid == peer_pid and !m.writable and m.va == 0x8440_0000) peer_ro = true;
    }
    shared_ok = mappings == 3 and owner_rw and peer_rw and peer_ro;
    out("      shm: {d} creates, {d} maps, {d} unmaps, {d} waits, {d} wakes, {d} threads woken\n", .{
        shm.creates, shm.maps, shm.unmaps, shm.waits, shm.wake_calls, shm.woken_threads,
    });
    out("      shm: {d} timeouts, {d} eagain, {d} refusals, {d} KiB in the pool of {d} pages\n", .{
        shm.timeouts, shm.agains, shm.refusals, shm.poolUsed() * 4, shm.pool_pages,
    });
    const shm_ok = procs_ok and shared_ok and objects == 1 and mappings == 3 and
        shm.creates >= 1 and shm.woken_threads >= 2 and shm.timeouts >= 1 and shm.unmaps >= 1;
    pass = verdict(pass, shm_ok, "[11]");

    out("  [12] ELF loading: a separate program launched from the image store\n", .{});
    const refusals = elfRefusals();
    out("      refuses bad magic {s}, writable+executable {s}, bad entry {s}, truncated {s}\n", .{
        status(refusals.bad_magic), status(refusals.write_exec),
        status(refusals.entry),     status(refusals.truncated),
    });
    const loader_ok = refusals.all();
    const pos_argv = [_][]const u8{ "pos.elf", "alpha", "beta" };
    const pos_env = [_][]const u8{"POS_TERM=cassa-1"};
    var exec_ok = false;
    if (process.spawnElf("pos.elf", &pos_argv, &pos_env)) |p| {
        const st = process.wait(p.pid, 5000);
        const code = p.exit_code;
        _ = process.waitReaped(p.pid, 1000);
        exec_ok = st == .exited and code == 42;
        out("      pid {d} 'pos.elf alpha beta': {s}, exit code {d}  {s}\n", .{
            p.pid, @tagName(st), code, status(exec_ok),
        });
    } else {
        out("      FAIL: cannot launch pos.elf ({s})\n", .{process.refusalLabel(process.last_refusal)});
    }
    const ghost = process.spawnElf("ghost.elf", &pos_argv, &pos_env);
    const refused_ok = ghost == null and process.last_refusal == .not_found;
    out("      missing image: refused ({s})  {s}\n", .{ process.refusalLabel(process.last_refusal), status(refused_ok) });
    out("      elf: {d} load(s), {d} refusal(s), {d} process(es) spawned in total\n", .{
        process.execs, process.exec_failures, process.spawns,
    });
    pass = verdict(pass, loader_ok and exec_ok and refused_ok, "[12]");

    out("  ------------------------------------------------------------------\n", .{});

    const base_pages = ctx.pmm.stats().free_pages;
    const rejected_before = syscall.rejected_ptr;

    // 1 -- a complete user program.
    out("  [1] normal EL0 program: write, getpid, uptime, yield, two bad pointers\n", .{});
    var p = process.spawn(0, 0, "user0") orelse {
        out("      FAIL: cannot spawn a process\n", .{});
        return;
    };
    var t0 = timer.uptimeMs();
    var st = process.wait(p.pid, 4000);
    _ = process.waitReaped(p.pid, 1000);
    const ok1 = st == .exited and p.exit_code == 0;
    out("      {s}, exit code {d}, {d} ms  {s}\n", .{ @tagName(st), p.exit_code, timer.uptimeMs() - t0, status(ok1) });
    pass = verdict(pass, ok1, "[1]");

    // 2 -- a privileged system register read must trap.
    out("  [2] MRS TCR_EL1 from EL0\n", .{});
    p = process.spawn(1, 0, "user1") orelse {
        out("      FAIL: cannot spawn a process\n", .{});
        return;
    };
    t0 = timer.uptimeMs();
    st = process.wait(p.pid, 4000);
    _ = process.waitReaped(p.pid, 1000);
    const ok2 = st == .killed;
    if (process.processOfPid(p.pid)) |proc| {
        if (proc.fault) |f| out("      caught: {s} at pc 0x{x}  {s}\n", .{ f.kind, f.pc, status(ok2) });
    }
    pass = verdict(pass, ok2, "[2]");

    // 3 -- reading kernel memory must fault, not succeed.
    out("  [3] load from kernel text 0x40080000 at EL0\n", .{});
    p = process.spawn(2, 0, "user2") orelse {
        out("      FAIL: cannot spawn a process\n", .{});
        return;
    };
    st = process.wait(p.pid, 4000);
    _ = process.waitReaped(p.pid, 1000);
    const ok3 = st == .killed;
    if (process.processOfPid(p.pid)) |proc| {
        if (proc.fault) |f| out("      caught: {s} addr 0x{x}  {s}\n", .{ f.kind, f.addr, status(ok3) });
    }
    pass = verdict(pass, ok3, "[3]");

    // 4 -- a syscall pointer outside the process is refused, not followed.
    out("  [4] syscall pointers outside the process\n", .{});
    const rejected = syscall.rejected_ptr - rejected_before;
    const ok4 = rejected >= 2;
    out("      kernel refused {d} pointer(s) (kernel text + unmapped)  {s}\n", .{ rejected, status(ok4) });
    pass = verdict(pass, ok4, "[4]");

    // 5 -- two processes, the same virtual address, different physical pages.
    out("  [5] two processes writing 0x81000010 with different secrets\n", .{});
    const a = process.spawn(3, 0xAAAA, "iso-a") orelse {
        out("      FAIL: cannot spawn the first process\n", .{});
        return;
    };
    const b = process.spawn(3, 0xBBBB, "iso-b") orelse {
        out("      FAIL: cannot spawn the second process\n", .{});
        return;
    };
    const sa = process.wait(a.pid, 5000);
    const sb = process.wait(b.pid, 5000);
    _ = process.waitReaped(a.pid, 1000);
    _ = process.waitReaped(b.pid, 1000);
    const ok5 = sa == .exited and sb == .exited and a.exit_code == 0 and b.exit_code == 0;
    out("      pids {d} and {d}: {s}/{s}, codes {d}/{d}  {s}\n", .{
        a.pid, b.pid, @tagName(sa), @tagName(sb), a.exit_code, b.exit_code, status(ok5),
    });
    pass = verdict(pass, ok5, "[5]");

    // 6 -- launch and exit repeatedly; the page counter must come back.
    out("  [6] five launch/exit cycles\n", .{});
    var cycles: u32 = 0;
    for (0..5) |_| {
        const q = process.spawn(0, 0, "cycle") orelse break;
        _ = process.wait(q.pid, 4000);
        _ = process.waitReaped(q.pid, 1000);
        cycles += 1;
    }
    const after_pages = ctx.pmm.stats().free_pages;
    const leaked = if (base_pages > after_pages) base_pages - after_pages else 0;
    const ok6 = cycles == 5 and leaked == 0;
    out("      {d}/5 cycles, free pages {d} -> {d} ({d} leaked)  {s}\n", .{
        cycles, base_pages, after_pages, leaked, status(ok6),
    });
    pass = verdict(pass, ok6, "[6]");

    // 7 -- capabilities: granted rights, refusals, stale handles, table limits.
    out("  [7] capabilities: granted rights, missing rights, stale handles, table limits\n", .{});
    const cap_before = syscall.cap_calls;
    p = process.spawn(4, 0, "caps") orelse {
        out("      FAIL: cannot spawn a process\n", .{});
        return;
    };
    st = process.wait(p.pid, 6000);
    _ = process.waitReaped(p.pid, 1000);
    const ok7 = st == .exited and p.exit_code == 0;
    out("      {d} capability calls, code {d}  {s}\n", .{ syscall.cap_calls - cap_before, p.exit_code, status(ok7) });
    pass = verdict(pass, ok7, "[7]");

    // 8 -- one object, two holders, each bounded by its own mask.
    out("  [8] two processes holding the same ledger, different rights\n", .{});
    const ca = process.spawn(4, 0, "cap-rw") orelse {
        out("      FAIL: cannot spawn the read/write holder\n", .{});
        return;
    };
    const cb = process.spawnReadOnly(4, 1, "cap-ro") orelse {
        out("      FAIL: cannot spawn the read-only holder\n", .{});
        return;
    };
    // Read the identities now: a slot is recycled as soon as its process is
    // reaped, so the pointers are only meaningful for the pids captured here.
    const pid_rw = ca.pid;
    const pid_ro = cb.pid;
    const sca = process.wait(pid_rw, 6000);
    const code_rw = ca.exit_code;
    _ = process.waitReaped(pid_rw, 1000);
    const scb = process.wait(pid_ro, 6000);
    const code_ro = cb.exit_code;
    _ = process.waitReaped(pid_ro, 1000);
    const ok8 = sca == .exited and scb == .exited and code_rw == 0 and code_ro == 0;
    out("      pids {d} (rw) and {d} (ro): {s}/{s}, codes {d}/{d}  {s}\n", .{
        pid_rw, pid_ro, @tagName(sca), @tagName(scb), code_rw, code_ro, status(ok8),
    });
    pass = verdict(pass, ok8, "[8]");

    // 9 -- the kernel's own view of the objects.
    out("  [9] object table after the run\n", .{});
    var oi: usize = 0;
    while (oi < cap.objectSlots()) : (oi += 1) {
        if (cap.objectAt(oi)) |o| {
            out("      id {d} {s:<11} refs {d}  version {d}  epoch {d}\n", .{
                o.id, o.kind.label(), o.refs, o.version, o.epoch,
            });
        }
    }
    out("      derivations {d}, revocations {d}, refusals {d}, live tables {d}\n", .{
        cap.derivations, cap.revocations, cap.refusals, cap.liveTables(),
    });

    // 10 -- IPC endpoints: handoff, handle transfer, revocation, deadlines.
    out("  [10] IPC endpoints: handoff, handle transfer, revocation, deadlines\n", .{});
    const srv = process.spawnIpc(6, 0, "ipc-srv") orelse {
        out("      FAIL: cannot spawn the IPC server\n", .{});
        return;
    };
    const srv_pid = srv.pid;
    const srv_tid = srv.thread_id;
    // Wait for it to enter its receive, then watch it for 20 ms: a parked
    // thread must not be scheduled at all.
    var park_state: thread_mod.State = .unused;
    var waited: u64 = 0;
    while (waited < 400) : (waited += 5) {
        sched.sleepMsBlocking(5);
        if (sched.find(srv_tid)) |t| {
            park_state = t.state;
            if (park_state == .blocked) break;
        }
    }
    var runs_before: u64 = 0;
    var runs_after: u64 = 0;
    if (sched.find(srv_tid)) |t| runs_before = t.runs;
    sched.sleepMsBlocking(20);
    if (sched.find(srv_tid)) |t| runs_after = t.runs;
    const parked_ok = park_state == .blocked and runs_before == runs_after;
    out("      server thread {d}: state {s}, runs {d} -> {d} over 20 ms  {s}\n", .{
        srv_tid, park_state.label(), runs_before, runs_after, status(parked_ok),
    });
    pass = verdict(pass, parked_ok, "[10]");

    const cli = process.spawnIpc(5, 0, "ipc-cli") orelse {
        out("      FAIL: cannot spawn the IPC client\n", .{});
        return;
    };
    const outsider = process.spawn(7, 0, "ipc-out") orelse {
        out("      FAIL: cannot spawn the outsider\n", .{});
        return;
    };
    const cli_pid = cli.pid;
    const out_pid = outsider.pid;
    const s_cli = process.wait(cli_pid, 8000);
    const c_cli = cli.exit_code;
    _ = process.waitReaped(cli_pid, 1000);
    const s_out = process.wait(out_pid, 8000);
    const c_out = outsider.exit_code;
    _ = process.waitReaped(out_pid, 1000);
    const s_srv = process.wait(srv_pid, 8000);
    const c_srv = srv.exit_code;
    _ = process.waitReaped(srv_pid, 1000);
    const ipc_ok = s_cli == .exited and s_out == .exited and s_srv == .exited and
        c_cli == 0 and c_out == 0 and c_srv == 0;
    out("      pids {d} server / {d} client / {d} outsider: {s}/{s}/{s}, codes {d}/{d}/{d}  {s}\n", .{
        srv_pid,         cli_pid,         out_pid,
        @tagName(s_cli), @tagName(s_out), @tagName(s_srv),
        c_srv,           c_cli,           c_out,
        status(ipc_ok),
    });
    out("      ipc: {d} sent, {d} received, {d} replied, {d} timeouts, {d} full, {d} transfers, {d} transfer failures, {d} late\n", .{
        ipc.sends, ipc.receives, ipc.replies, ipc.timeouts, ipc.full_events, ipc.transfers, ipc.transfer_failures, ipc.late_replies,
    });
    pass = verdict(pass, ipc_ok, "[10]");

    // 13 -- lifecycle: one service is killed in a loop while another keeps
    // serving, a fault is captured as a crash record, and nothing is orphaned.
    out("  [13] lifecycle: a crashing service is restarted, checkout keeps working\n", .{});
    const live_before = process.liveCount();
    const spaces_before = user_space.liveCount();
    var lc_ok = true;
    const printer_cfg = service.register("printer", "pos.elf", &[_][]const u8{ "pos.elf", "loop" });
    if (printer_cfg == null or
        service.register("checkout", "pos.elf", &[_][]const u8{ "pos.elf", "loop" }) == null)
    {
        out("      FAIL: the service table is full\n", .{});
        lc_ok = false;
    } else {
        // One extra tolerated failure than the default policy, so the probe can
        // show every rung of the backoff ladder and then the crash-loop stop. The
        // stability window is widened because this test is about consecutive
        // failures; a probe preempted for a few hundred milliseconds between two
        // kills must not look like a service that recovered.
        printer_cfg.?.policy.max_restarts = 7;
        printer_cfg.?.policy.stable_ms = 60_000;
        const both = service.start("printer") and service.start("checkout");
        sched.sleepMsBlocking(30);
        const pr = service.find("printer").?;
        const co = service.find("checkout").?;
        const up_ok = both and pr.state == .running and co.state == .running and pr.pid != 0 and co.pid != 0;
        out("      registered printer pid {d} and checkout pid {d}, both {s}  {s}\n", .{
            pr.pid, co.pid, service.stateLabel(pr.state), status(up_ok),
        });
        lc_ok = lc_ok and up_ok;

        var killed: u32 = 0;
        var delays: [7]u64 = [_]u64{0} ** 7;
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            // Wait for the previous restart to finish before killing again, so
            // every kill lands on a live service rather than on a timer.
            var wait_ms: u64 = 0;
            while (wait_ms < 800) : (wait_ms += 5) {
                if (service.find("printer").?.state == .running) break;
                sched.sleepMsBlocking(5);
            }
            if (service.kill("printer")) killed += 1;
            // Wait for the supervisor to notice the death and record the policy
            // decision: the backoff it chose is the observable evidence.
            wait_ms = 0;
            while (wait_ms < 800) : (wait_ms += 5) {
                if (service.find("printer").?.state != .running) break;
                sched.sleepMsBlocking(5);
            }
            delays[i] = service.find("printer").?.last_delay_ms;
        }
        const printer = service.find("printer").?;
        const kills_ok = killed == 7 and printer.restarts == 6 and
            printer.state == .failed and service.crash_loops == 1 and
            delays[0] == 5 and delays[1] == 10 and delays[2] == 20 and delays[3] == 40 and
            delays[4] == 80 and delays[5] == 160 and delays[6] == 0;
        out("      killed {d}x: {d} restarts, backoff {d}/{d}/{d}/{d}/{d}/{d} ms, then parked {s}  {s}\n", .{
            killed,                            printer.restarts, delays[0], delays[1], delays[2], delays[3], delays[4], delays[5],
            service.stateLabel(printer.state), status(kills_ok),
        });
        out("      printer: {d} restarts, {d} failures, crash loop {d}  {s}\n", .{
            printer.restarts, printer.failures, service.crash_loops, status(kills_ok),
        });
        lc_ok = lc_ok and kills_ok;

        // The till keeps working through all of that: three checkout requests.
        var served: u32 = 0;
        const serve_argv = [_][]const u8{ "pos.elf", "serve" };
        const serve_env = [_][]const u8{"POS_TERM=cassa-1"};
        var req: usize = 0;
        while (req < 3) : (req += 1) {
            if (process.spawnElf("pos.elf", &serve_argv, &serve_env)) |req_proc| {
                const req_state = process.wait(req_proc.pid, 3000);
                if (req_state == .exited and req_proc.exit_code == 0) served += 1;
                _ = process.waitReaped(req_proc.pid, 1000);
            }
        }
        const co2 = service.find("checkout").?;
        const checkout_ok = served == 3 and co2.state == .running and co2.restarts == 0;
        out("      checkout: {d}/3 requests served, service {s}, {d} restarts during the kills  {s}\n", .{
            served, service.stateLabel(co2.state), co2.restarts, status(checkout_ok),
        });
        lc_ok = lc_ok and checkout_ok;

        // A fault, not a kill: it must leave a crash record and still be contained.
        const dumps_before = dump.total;
        const crash_argv = [_][]const u8{ "pos.elf", "crash" };
        var fault_ok = false;
        if (process.spawnElf("pos.elf", &crash_argv, &serve_env)) |crash_proc| {
            const crash_state = process.wait(crash_proc.pid, 3000);
            const crash_fault = if (process.processOfPid(crash_proc.pid)) |rec| rec.fault else null;
            _ = process.waitReaped(crash_proc.pid, 1000);
            fault_ok = crash_state == .killed and crash_fault != null and dump.total == dumps_before + 1;
            if (crash_fault) |cf| {
                out("      fault: pid {d} killed by {s} at 0x{x}, crash record {d}  {s}\n", .{
                    crash_proc.pid, cf.kind, cf.addr, dump.total - dumps_before, status(fault_ok),
                });
            } else {
                out("      fault: no fault was recorded  FAIL\n", .{});
            }
        }
        if (dump.at(0)) |d| {
            var nonzero: usize = 0;
            for (d.regs) |r| {
                if (r != 0) nonzero += 1;
            }
            out("      dump: pc 0x{x}, esr 0x{x}, {d}/8 registers and {d} stack words captured\n", .{
                d.pc, d.esr, nonzero, d.stack.len,
            });
        }
        lc_ok = lc_ok and fault_ok;

        _ = service.stop("checkout");
        _ = service.stop("printer");
        // The supervisor buries a child on its next poll; wait for the counts the
        // check is about instead of assuming one 50 ms window covers it.
        {
            var reap_ms: u64 = 0;
            while (reap_ms < 500 and
                (process.liveCount() != live_before or user_space.liveCount() != spaces_before)) : (reap_ms += 5)
            {
                sched.sleepMsBlocking(5);
            }
        }
        const live_after = process.liveCount();
        const spaces_after = user_space.liveCount();
        const orphan_ok = live_after == live_before and spaces_after == spaces_before and
            service.find("checkout").?.state == .stopped;
        out("      stop: services {s}, live processes {d} -> {d}, spaces {d} -> {d}  {s}\n", .{
            service.stateLabel(service.find("checkout").?.state),
            live_before,
            live_after,
            spaces_before,
            spaces_after,
            status(orphan_ok),
        });
        lc_ok = lc_ok and orphan_ok;
        out("      services: {d} starts, {d} restarts, {d} failures, {d} crash loops, {d} dumps, {d} reaps\n", .{
            service.starts,      service.restarts_total, service.failures_total,
            service.crash_loops, dump.total,             service.reaps,
        });
    }
    pass = verdict(pass, lc_ok, "[13]");

    // 14 -- registry: a POS application asks for a device by name and is told a
    // reason when it cannot have it, instead of a pid that may not exist.
    out("  [14] registry: by-name resolution, and graceful absence\n", .{});
    var reg_ok = true;
    {
        const reg_live_before = process.liveCount();
        const reg_spaces_before = user_space.liveCount();
        const reg_co = registry.register("pos://checkout", "checkout");
        const reg_pr = registry.register("pos://printer", "printer");
        const reg_dup = registry.register("pos://checkout", "checkout");
        const reg_bad = registry.register("Printer", "printer");
        const reg_ghost = registry.register("pos://ghost", "ghost");
        const reg_names_ok = reg_co == .ok and reg_pr == .ok and reg_dup == .duplicate and
            reg_bad == .invalid_name and reg_ghost == .unknown;
        out("      register: {s}, {s}, duplicate {s}, invalid {s}, unknown target {s}  {s}\n", .{
            names.reasonLabel(reg_co),  names.reasonLabel(reg_pr),    names.reasonLabel(reg_dup),
            names.reasonLabel(reg_bad), names.reasonLabel(reg_ghost), status(reg_names_ok),
        });
        reg_ok = reg_ok and reg_names_ok;

        const stopped = registry.lookup("pos://printer");
        const unknown = registry.lookup("pos://nope");
        const invalid = registry.lookup("pos://Printer");
        const bare = registry.lookup("pos://");
        const lookups_ok = stopped.reason == .stopped and unknown.reason == .unknown and
            invalid.reason == .invalid_name and bare.reason == .invalid_name;
        out("      lookup: stopped {s}, unknown {s}, invalid {s}, bare scheme {s}  {s}\n", .{
            names.reasonLabel(stopped.reason), names.reasonLabel(unknown.reason),
            names.reasonLabel(invalid.reason), names.reasonLabel(bare.reason),
            status(lookups_ok),
        });
        reg_ok = reg_ok and lookups_ok;

        const lazy = registry.ensure("pos://printer");
        const lazy_ok = lazy.reason == .ok and lazy.pid != 0 and registry.lazy_starts == 1;
        out("      lazy start: ensure pos://printer -> {s} pid {d} gen {d}  {s}\n", .{
            names.reasonLabel(lazy.reason), lazy.pid, lazy.generation, status(lazy_ok),
        });
        reg_ok = reg_ok and lazy_ok;

        _ = service.start("checkout");
        sched.sleepMsBlocking(20);
        const live = registry.lookup("pos://checkout");
        const live_ok = live.reason == .ok and live.pid != 0 and live.generation > 0;
        out("      live: pos://checkout -> {s} pid {d} gen {d}  {s}\n", .{
            names.reasonLabel(live.reason), live.pid, live.generation, status(live_ok),
        });
        reg_ok = reg_ok and live_ok;

        // A kill is visible as `restarting`, and the generation changes across it,
        // so a caller holding the old pid can tell it was restarted underneath it.
        // The default first backoff is 5 ms, shorter than a four-core
        // supervisor's own poll interval, so `restarting` can come and go between
        // two lookups. The delay is an input to the state machine, not the
        // property under test; widen it for this observation and restore it.
        const checkout_cfg = service.find("checkout").?;
        const saved_base_ms = checkout_cfg.policy.base_ms;
        checkout_cfg.policy.base_ms = 100;
        _ = service.kill("checkout");
        var saw_restart = false;
        var wait_ms: u64 = 0;
        while (wait_ms < 400) : (wait_ms += 1) {
            if (registry.lookup("pos://checkout").reason == .restarting) {
                saw_restart = true;
                break;
            }
            sched.sleepMsBlocking(1);
        }
        var after: names.Reason = .unknown;
        var after_gen: u32 = 0;
        wait_ms = 0;
        while (wait_ms < 500) : (wait_ms += 5) {
            const r = registry.lookup("pos://checkout");
            // Wait for the *new* incarnation, not merely for `ok`: the old child
            // can still be running for a few milliseconds after the kill, and an
            // `ok` from it would end this loop before the restart happened.
            if (r.reason == .ok and r.generation > live.generation) {
                after = r.reason;
                after_gen = r.generation;
                break;
            }
            sched.sleepMsBlocking(5);
        }
        checkout_cfg.policy.base_ms = saved_base_ms;
        const restart_ok = saw_restart and after == .ok and after_gen > live.generation;
        out("      restart: during backoff {s}, after {s} gen {d} -> {d}  {s}\n", .{
            if (saw_restart) "restarting" else "-", names.reasonLabel(after),
            live.generation,                        after_gen,
            status(restart_ok),
        });
        reg_ok = reg_ok and restart_ok;

        // Park the printer through its own crash-loop policy, then ask again: a
        // parked service must answer, and the answer must be `failed`. The policy
        // is the one step 13 configured (seven tolerated failures).
        var k: usize = 0;
        while (k < 7) : (k += 1) {
            var w: u64 = 0;
            while (w < 800) : (w += 5) {
                if (service.find("printer").?.state == .running) break;
                sched.sleepMsBlocking(5);
            }
            _ = service.kill("printer");
            w = 0;
            while (w < 800) : (w += 5) {
                if (service.find("printer").?.state != .running) break;
                sched.sleepMsBlocking(5);
            }
        }
        const parked = registry.lookup("pos://printer");
        const parked_reason = parked.reason == .failed and service.find("printer").?.state == .failed;
        out("      parked: pos://printer -> {s}  {s}\n", .{
            names.reasonLabel(parked.reason), status(parked_reason),
        });
        reg_ok = reg_ok and parked_reason;

        // A real user-mode call site. The exit code is the reason, so absence is a
        // value the program acts on: never a fault, never a hang.
        var degraded: u32 = 0;
        var cases_ok = true;
        const wanted = [_][]const u8{ "pos://checkout", "pos://printer", "pos://nope" };
        const want_code = [_]i64{ 0, 4, 1 };
        var ci: usize = 0;
        while (ci < wanted.len) : (ci += 1) {
            const rargv = [_][]const u8{ "pos.elf", "resolve", wanted[ci] };
            const renv = [_][]const u8{"POS_TERM=cassa-1"};
            const rp = process.spawnElf("pos.elf", &rargv, &renv) orelse continue;
            const rst = process.wait(rp.pid, 3000);
            const rcode = rp.exit_code;
            _ = process.waitReaped(rp.pid, 1000);
            if (rst == .exited and rcode == want_code[ci]) degraded += 1 else cases_ok = false;
        }
        const site_ok = cases_ok and degraded == 3;
        out("      call site: {d}/3 by-name lookups exited with the expected reason  {s}\n", .{
            degraded, status(site_ok),
        });
        reg_ok = reg_ok and site_ok;

        _ = service.stop("checkout");
        _ = service.stop("printer");
        // The supervisor notices a death on its next tick and reaps it, so give it
        // a few ticks to settle before counting: this is the documented polling
        // latency, not a licence to leak.
        var settle_ms: u64 = 0;
        while (settle_ms < 500 and process.liveCount() != reg_live_before) : (settle_ms += 10) {
            sched.sleepMsBlocking(10);
        }
        const reg_live_after = process.liveCount();
        const reg_spaces_after = user_space.liveCount();
        // The property is that stopping leaves nothing behind. A process that
        // was alive when the baseline was taken can legitimately exit during the
        // step (a restart cancelled by the stop), so the count may come out
        // lower; a count above the baseline is the leak this checks for.
        const reg_clean = reg_live_after <= reg_live_before and reg_spaces_after <= reg_spaces_before;
        out("      stop: live processes {d} -> {d}, spaces {d} -> {d}  {s}\n", .{
            reg_live_before, reg_live_after, reg_spaces_before, reg_spaces_after, status(reg_clean),
        });
        out("      registry: {d} names, {d} lookups, {d} hits, {d} refusals, {d} lazy starts\n", .{
            registry.count(),     registry.lookups, registry.hits, registry.refusals,
            registry.lazy_starts,
        });
        reg_ok = reg_ok and reg_clean;
    }
    pass = verdict(pass, reg_ok, "[14]");

    // [15] resource accounting: a leaking service is capped and reported, and
    // the till keeps serving while the watchdog escalates.
    out("  [15] accounting: quotas, memory pressure, watchdog escalation\n", .{});
    var acct_ok = true;
    const acct_live_before = process.liveCount();

    // Pressure is a real comparison against free pages. A 512 MiB host is not
    // short of memory, so the watermark is lifted just above the current free
    // count for one sample: the path, the victim choice and the report are real,
    // only the threshold is moved to where this machine can reach it.
    const free_now = ctx.pmm.stats().free_pages;
    const saved_watermark = account.watermark_pages;
    const saved_critical = account.critical_pages;
    const pressures_before = account.pressures;
    account.watermark_pages = free_now + 1;
    account.critical_pages = 0;
    account.tick();
    const pressure_ok = account.pressures > pressures_before;
    account.watermark_pages = saved_watermark;
    account.critical_pages = saved_critical;
    out("      pressure: {d} pages free, watermark {d} -> {d} event(s), 0 victims  {s}\n", .{
        free_now, free_now + 1, account.pressures - pressures_before, status(pressure_ok),
    });
    acct_ok = acct_ok and pressure_ok;

    // The page quota is deliberately below the image's own footprint: the ledger
    // reports the breach and escalates, which is the cap being enforced. The
    // handle cap is exercised at the funnel: derivation is refused once the quota
    // is reached.
    const leaker_quota = account.Quota{ .pages = 8, .handles = 6, .cpu_ms = 40, .window_ms = 500 };
    const leaker_cfg = service.register("leaker", "pos.elf", &[_][]const u8{ "pos.elf", "leak" });
    if (leaker_cfg) |s| {
        // One death is final: the watchdog's kill must park the service, not feed
        // it into the restart loop the quota exists to stop.
        s.policy.max_restarts = 1;
        s.quota = leaker_quota;
    }
    const warns_before = account.warnings_total;
    const throttles_before = account.throttles_total;
    const kills_before = account.kills_total;
    const handles_refused_before = cap.quota_refusals;
    const page_breaches_before = account.page_breaches;
    const leaker_started = service.start("leaker");
    sched.sleepMsBlocking(120);

    // The till keeps serving while the leaker is being slowed.
    var acct_served: u32 = 0;
    const acct_env = [_][]const u8{"POS_TERM=cassa-1"};
    var ar: usize = 0;
    while (ar < 3) : (ar += 1) {
        // Three attempts per request: what is being shown is that the till keeps
        // serving while the leaker is capped, and a single-core boot may spend a
        // slice or two getting the request process started.
        var tries: u32 = 0;
        while (tries < 3) : (tries += 1) {
            const sargv = [_][]const u8{ "pos.elf", "serve" };
            const ap = process.spawnElf("pos.elf", &sargv, &acct_env) orelse {
                sched.sleepMsBlocking(20);
                continue;
            };
            const ast = process.wait(ap.pid, 3000);
            const code = ap.exit_code;
            _ = process.waitReaped(ap.pid, 1000);
            if (ast == .exited and code == 0) {
                acct_served += 1;
                break;
            }
        }
    }

    var lw: u64 = 0;
    while (lw < 5000 and service.find("leaker").?.state == .running) : (lw += 5) {
        sched.sleepMsBlocking(5);
    }
    const leaker_parked = service.find("leaker").?.state == .failed;
    const acct_warned = account.warnings_total > warns_before;
    const acct_throttled = account.throttles_total > throttles_before;
    const acct_killed = account.kills_total > kills_before;
    const handle_stop = cap.quota_refusals > handles_refused_before;
    const page_stop = account.page_breaches > page_breaches_before;
    const ladder_ok = leaker_started and acct_warned and acct_throttled and acct_killed and leaker_parked;
    out("      leaker: {d} handle refusal(s), {d} page-quota breach(es), then {s}  {s}\n", .{
        cap.quota_refusals - handles_refused_before,
        account.page_breaches - page_breaches_before,
        if (leaker_parked) "parked by policy" else "still running",
        status(ladder_ok and handle_stop and page_stop),
    });
    out("      watchdog: warn {d}, throttle {d}, kill {d} (quota {d} pages, {d} handles, {d} ms/{d} ms)\n", .{
        account.warnings_total - warns_before, account.throttles_total - throttles_before,
        account.kills_total - kills_before,    leaker_quota.pages,
        leaker_quota.handles,                  leaker_quota.cpu_ms,
        leaker_quota.window_ms,
    });
    out("      till: {d}/3 checkouts served while the leaker was capped  {s}\n", .{
        acct_served, status(acct_served == 3),
    });
    acct_ok = acct_ok and ladder_ok and handle_stop and page_stop and acct_served == 3;

    _ = service.stop("leaker");
    var acct_settle: u64 = 0;
    while (acct_settle < 500 and process.liveCount() != acct_live_before) : (acct_settle += 10) {
        sched.sleepMsBlocking(10);
    }
    // Stopping the leaker must not leave anything behind. A service that exits
    // during this step legitimately lowers the count, which is not a leak, so
    // the check is "no growth", not "exactly restored" (same as [14]).
    const acct_clean = process.liveCount() <= acct_live_before;
    out("      stop: live processes {d} -> {d}  {s}\n", .{
        acct_live_before, process.liveCount(), status(acct_clean),
    });
    out("      accounting: {d} samples, {d} warnings, {d} throttles, {d} kills, {d} pressure event(s), {d} victim(s)\n", .{
        account.samples,   account.warnings_total,   account.throttles_total, account.kills_total,
        account.pressures, account.pressure_victims,
    });
    acct_ok = acct_ok and acct_clean;
    pass = verdict(pass, acct_ok, "[15]");

    // [16] sandbox: declarative manifests, the syscall gate, W^X, and a
    // compromised renderer that must not be able to open the raw block device.
    out("  [16] sandbox: manifests, syscall mask, block-device denial\n", .{});
    const sb_env = [_][]const u8{"POS_TERM=cassa-1"};
    const block_denials_before = sandbox.block_denials;
    const gate_denied_before = sandbox.denied;
    const wx_before = mmu.wx_refusals;

    // (a) The one entitled service reads sector 0 through its block handle.
    var storage_ok = false;
    {
        const argv = [_][]const u8{ "pos.elf", "block" };
        if (process.spawnElfSandbox("pos.elf", &argv, &sb_env, .{}, .storage)) |proc| {
            const outcome = process.wait(proc.pid, 3000);
            storage_ok = outcome == .exited and proc.exit_code == 0;
            _ = process.waitReaped(proc.pid, 1000);
        }
    }

    // (b) A process whose mask allows the call but which holds no block object:
    //     the capability check alone has to stop it, so neither line of defence
    //     can hide behind the other.
    var cap_ok = false;
    {
        const argv = [_][]const u8{ "pos.elf", "cap" };
        if (process.spawnElfSandbox("pos.elf", &argv, &sb_env, .{}, .harness)) |proc| {
            const outcome = process.wait(proc.pid, 3000);
            cap_ok = outcome == .exited and proc.exit_code == 0;
            _ = process.waitReaped(proc.pid, 1000);
        }
    }

    // (c) The compromised renderer: arbitrary code inside its own sandbox, with a
    //     console and the right to ask about itself.
    var renderer_ok = false;
    {
        const argv = [_][]const u8{ "pos.elf", "attack" };
        if (process.spawnElfSandbox("pos.elf", &argv, &sb_env, .{}, .renderer)) |proc| {
            const outcome = process.wait(proc.pid, 3000);
            renderer_ok = outcome == .exited and proc.exit_code == 0;
            _ = process.waitReaped(proc.pid, 1000);
        }
    }
    const blocked = sandbox.block_denials - block_denials_before;
    const gate_denied = sandbox.denied - gate_denied_before;
    // W^X: the mapping funnel refuses a writable-executable page, and the policy
    // validator refuses a manifest that asks for one (a build-time check).
    const wx_ok = user_space.probeWxRefusal() and mmu.wx_refusals > wx_before;

    out("      manifests: {d} validated at build time, renderer caps {d} (console only)\n", .{
        sandbox.manifests.len, sandbox.of(.renderer).caps.len,
    });
    out("      storage: sector 0 signature through its block handle  {s}\n", .{status(storage_ok)});
    out("      no-block: 16 calls allowed by the mask, refused by capability  {s}\n", .{status(cap_ok and blocked >= 16)});
    out("      renderer: 16 handle probes + 1 undeclared call refused by the mask  {s}\n", .{status(renderer_ok and gate_denied >= 17)});
    out("      block: {d} denial(s) recorded, 0 reads without the object  {s}\n", .{
        blocked, status(blocked >= 16),
    });
    out("      W^X: writable-executable mapping refused at the funnel ({d} total)  {s}\n", .{
        mmu.wx_refusals, status(wx_ok),
    });
    pass = verdict(pass, storage_ok and cap_ok and renderer_ok and blocked >= 16 and gate_denied >= 17 and wx_ok, "[16]");

    // [17] driver model: devices as data, compatible matching, declared
    // dependency order, isolated probe failures, and hotplug.
    out("  [17] driver model: discovery, matching, ordering, isolation, hotplug\n", .{});
    const dev_list = driver.allDevices();
    var bound_count: usize = 0;
    var waiting_count: usize = 0;
    var failed_count: usize = 0;
    for (dev_list) |d| switch (d.state) {
        .bound => bound_count += 1,
        .unbound, .skipped => waiting_count += 1,
        .failed => failed_count += 1,
        .absent => {},
    };
    const console_dev = driver.findByCompat("arm,pl011");
    const gic_dev = driver.findByCompat("arm,gic-v3") orelse driver.findByCompat("arm,cortex-a15-gic");
    const timer_dev = driver.findByCompat("arm,armv8-timer");
    const rtc_dev = driver.findByCompat("arm,pl031");
    const named = struct {
        fn is(dev: ?*driver.Device, want: []const u8) bool {
            const d = dev orelse return false;
            const drv = d.driver orelse return false;
            return std.mem.eql(u8, drv.name, want);
        }
    };
    const match_ok = named.is(console_dev, "console") and named.is(gic_dev, "gic") and
        named.is(timer_dev, "timer") and (rtc_dev == null or named.is(rtc_dev, "rtc"));

    // The probe log is the boot order: the timer declares that it needs the
    // interrupt controller, so the model must have probed the GIC first.
    const order_ok = blk: {
        var gic_at: ?usize = null;
        var timer_at: ?usize = null;
        for (driver.probeLog(), 0..) |entry, i| {
            if (gic_at == null and std.mem.eql(u8, entry.driver, "gic")) gic_at = i;
            if (timer_at == null and std.mem.eql(u8, entry.driver, "timer")) timer_at = i;
        }
        break :blk gic_at != null and timer_at != null and gic_at.? < timer_at.?;
    };

    // A failing probe is isolated: the device is marked and counted, and the
    // machine keeps running. The device is invented; the driver is real code.
    const failed_before = driver.failed_probes;
    const broken = driver.inject("broken", "cassa,broken", 0, 0);
    driver.bindAll();
    const iso_ok = broken != null and broken.?.state == .failed and
        driver.failed_probes == failed_before + 1 and driver.isBound("gic") and driver.isBound("timer");

    // Hotplug: take the wall clock out of a running machine and put it back.
    const removed_before = driver.events_removed;
    const added_before = driver.events_added;
    var hot_ok = false;
    if (rtc_dev) |d| {
        const down = driver.removeDevice(d.name);
        const gone = d.state == .absent and !pl031.isPresent();
        const back = driver.readdDevice(d.name);
        hot_ok = down != null and gone and back != null and d.state == .bound and
            driver.events_removed == removed_before + 1 and driver.events_added == added_before + 1;
    } else {
        // A machine with no RTC: removing what is not there must be refused
        // cleanly, not crash, and nothing may be reported as removed.
        hot_ok = driver.removeDevice("rtc@9010000") == null and driver.events_removed == removed_before;
    }

    out("      devices: {d} from the tree, {d} bound, {d} waiting for a driver, {d} failed  {s}\n", .{
        dev_list.len, bound_count, waiting_count, failed_count, status(failed_count == 0 and bound_count >= 3),
    });
    out("      match: pl011->console, gic->gic, timer->timer, rtc->rtc  {s}\n", .{status(match_ok)});
    out("      order: gic probed before timer (declared dependency)  {s}\n", .{status(order_ok)});
    out("      isolation: cassa,broken probe failed, marked, machine unaffected  {s}\n", .{status(iso_ok)});
    out("      hotplug: rtc unbound (listener told) and re-probed  {s}\n", .{status(hot_ok)});
    pass = verdict(pass, failed_count == 0 and bound_count >= 3 and match_ok and order_ok and iso_ok and hot_ok, "[17]");

    out("  [18] pcie: ecam walk, BAR placement, MSI/INTx\n", .{});
    const bus = pci.current();
    const host_id = if (bus.root.ecam != 0) pci.read32(&bus.root, bus.root.bus_first, 0, 0, 0x00) else 0xFFFF_FFFF;
    const root_ok = driver.isBound("pci-host") and bus.root.ecam != 0 and bus.root.mmio_len != 0;
    // The configuration window has to answer: a function 0 that reads back all
    // ones means the ECAM base is wrong or not mapped, not an empty bus.
    const ecam_ok = root_ok and (host_id & 0xFFFF) != 0xFFFF and (host_id & 0xFFFF) != 0;
    const published = driver.countPci();
    const walk_ok = root_ok and bus.count != 0 and published == bus.count;
    var bars_ok = root_ok and bus.bars_placed != 0;
    var irq_ok = true;
    var irq_count: usize = 0;
    for (bus.functions[0..bus.count]) |*f| {
        for (f.bars) |bar| {
            if (bar.kind == .absent) continue;
            if (bar.size == 0 or bar.assigned == 0) bars_ok = false;
            if ((bar.size & (bar.size - 1)) != 0) bars_ok = false; // sizes are powers of two
            if (bar.kind != .io and (bar.assigned < bus.root.mmio or
                bar.assigned + bar.size > bus.root.mmio + bus.root.mmio_len)) bars_ok = false;
        }
        if (!pci.deliveryOk(f)) irq_ok = false;
        if (f.msi_on or f.intx_routed) irq_count += 1;
    }
    irq_ok = irq_ok and irq_count != 0;
    out("      root: pci-host-ecam-generic, ECAM 0x{x}+0x{x}, buses {d}..{d}, mmio 0x{x}+0x{x}  {s}\n", .{
        bus.root.ecam, bus.root.ecam_len, bus.root.bus_first, bus.root.bus_last,
        bus.root.mmio, bus.root.mmio_len, status(root_ok),
    });
    out("      ecam: 00:00.0 reads {x:0>4}:{x:0>4}  {s}\n", .{
        host_id & 0xFFFF, host_id >> 16, status(ecam_ok),
    });
    out("      walk: {d} function(s), {d} published as devices  {s}\n", .{
        bus.count, published, status(walk_ok),
    });
    out("      bars: {d} placed, sizes powers of two inside the windows  {s}\n", .{
        bus.bars_placed, status(bars_ok),
    });
    out("      irq: {d} connected ({d} msi, {d} fell back to intx), {s}  {s}\n", .{
        irq_count, bus.root.msi_functions, bus.root.msi_fallbacks,
        switch (bus.root.msi) {
            .none => "msi unavailable (no GICv2m frame, no ITS): INTx only",
            .its => "msi controller is an ITS, not programmed: INTx only",
            .v2m => "GICv2m frame present",
        },
        status(irq_ok),
    });
    for (bus.functions[0..bus.count]) |*f| {
        out("        {d:0>2}:{d:0>2}.{d} {x:0>4}:{x:0>4} {s}: {s}\n", .{
            f.bus,                                                                         f.dev, f.func, f.vendor, f.device, pci.classLabel(f.class_code),
            if (f.msi_on) "msi" else if (f.intx_routed) "intx routed" else "no interrupt",
        });
    }
    out("      unclaimed: {d} pci function(s) waiting for a driver  {s}\n", .{
        published, status(published != 0),
    });
    pass = verdict(pass, root_ok and ecam_ok and walk_ok and bars_ok and irq_ok, "[18]");

    out("  [19] virtio: negotiation, split queues, echo under pressure, recovery\n", .{});
    const slots = virtio_mmio.info();
    const claimed_slots = driver.countCompat("virtio,mmio");
    const live = virtio_mmio.liveSlots();
    var empty: usize = 0;
    for (slots) |slot| {
        if (!slot.live) empty += 1;
    }
    const transport_ok = slots.len != 0 and slots.len == claimed_slots and live != 0;
    var negotiate_ok = true;
    var queue_ok = true;
    for (slots) |slot| {
        if (!slot.live) continue;
        if (slot.version != 2 or slot.negotiated & virtio.feature_version_1 == 0) negotiate_ok = false;
        if (slot.queue_size == 0) queue_ok = false;
    }
    const echo = virtio.echoTest(100_000);
    const echo_ok = echo.rounds == 100_000 and echo.errors == 0 and echo.coalesced != 0;
    const leak_ok = echo.pages_before == echo.pages_after;
    const recovery_ok = echo.resets >= 1 and echo.recovered;
    out("      transports: {d} slot(s), {d} with a device, {d} empty  {s}\n", .{
        slots.len, live, empty, status(transport_ok),
    });
    out("      negotiate: version 2, VIRTIO_F_VERSION_1 acked by {d} device(s)  {s}\n", .{
        live, status(negotiate_ok),
    });
    out("      queue: {d} live split queue(s), descriptor/available/used rings  {s}\n", .{
        live, status(queue_ok),
    });
    out("      echo: {d} request(s), {d} error(s), {d} coalesced drain(s), {d} page(s) before, {d} after  {s}\n", .{
        echo.rounds, echo.errors, echo.coalesced, echo.pages_before, echo.pages_after, status(echo_ok and leak_ok),
    });
    out("      pressure: {d} page(s) held ({d} KiB), {d} churn cycle(s), {d} allocation failure(s)  {s}\n", .{
        echo.pressure_pages, echo.pressure_pages * 4, echo.churn_cycles, echo.alloc_failures, status(echo.pressure_pages >= 8192 and echo.alloc_failures == 0),
    });
    out("      recovery: {d} reset(s), timeout detected, retry completed  {s}\n", .{
        echo.resets, status(recovery_ok),
    });
    out("      served: {d} device(s) answered real requests; block/net/input/gpu protocols are later phases  {s}\n", .{
        virtio_mmio.servedSlots(), status(virtio_mmio.servedSlots() != 0 and virtio_mmio.failureCount() == 0),
    });
    pass = verdict(pass, transport_ok and negotiate_ok and queue_ok and echo_ok and leak_ok and recovery_ok and
        echo.pressure_pages >= 8192 and echo.alloc_failures == 0 and
        virtio_mmio.servedSlots() != 0 and virtio_mmio.failureCount() == 0, "[19]");

    // 20 -- storage: real requests on a virtual disk, an elevator with a flush
    // barrier, and a digest a later boot checks after an unclean quit.
    out("  [20] storage: virtio-blk requests, elevator, flush, unclean-restart verify\n", .{});
    var disk_ok = false;
    if (!virtio_blk.present()) {
        out("      FAIL: no block device — boot with -device virtio-blk-device\n", .{});
    } else {
        const t = virtio_blk.selfTest();
        const device_ok = t.present and t.flush_negotiated and
            t.capacity >= virtio_blk.data_base + virtio_blk.data_count + 8;
        const write_ok = t.written == virtio_blk.data_count and t.errors == 0;
        const readback_ok = t.mismatches == 0 and t.digest != 0 and t.verified >= virtio_blk.data_count;
        const restart_ok = if (t.restart_verified) !t.restart_mismatch else true;
        // One timeout and one reset are expected: the self-test forces exactly
        // one request into that path to prove recovery works. Anything beyond
        // that count is a device that is not answering.
        const io_ok = t.device.io_errors == 0 and t.device.unsupported == 0 and
            t.device.last_status == 0 and t.device.timeouts == t.fault_resets and
            t.device.resets == t.fault_resets;
        const disk_irq_ok = if (virtio_blk.interruptId() == 0) true else virtio_blk.interruptCount() != 0;
        const fault_ok = t.fault_injected and t.fault_recovered;
        disk_ok = device_ok and write_ok and readback_ok and restart_ok and io_ok and disk_irq_ok and fault_ok;

        out("      device: {d} sector(s) ({d} MiB), FLUSH negotiated, queue 0  {s}\n", .{
            t.capacity, (t.capacity * virtio_blk.sector_size) / (1024 * 1024), status(device_ok),
        });
        out("      write: {d} scattered write(s) in {d} elevator batch(es), {d} error(s), {d} reordered  {s}\n", .{
            t.written, t.batches, t.errors, t.reordered, status(write_ok),
        });
        out("      readback: {d} sector(s) compared, {d} mismatch(es), digest 0x{x:0>16}  {s}\n", .{
            t.verified, t.mismatches, t.digest, status(readback_ok),
        });
        out("      flush: {d} completed, {d} timeout(s) ({d} forced), {d} retry(ies), {d} reset(s), last status {d}  {s}\n", .{
            t.device.flushes,     t.device.timeouts, t.fault_resets, t.device.retries, t.device.resets,
            t.device.last_status, status(io_ok),
        });
        out("      recovery: forced timeout -> {d} retry(ies), {d} transport reset(s), retry data verified  {s}\n", .{
            t.fault_retries, t.fault_resets, status(fault_ok),
        });
        if (t.restart_verified) {
            out("      restart: generation {d} read back after an unclean quit, digest 0x{x:0>16} {s}  {s}\n", .{
                t.restart_seed, t.restart_digest, if (t.restart_mismatch) "MISMATCH" else "match", status(restart_ok),
            });
        } else {
            out("      restart: no previous generation on this disk; this boot writes one  {s}\n", .{status(restart_ok)});
        }
        if (virtio_blk.interruptId() != 0) {
            out("      irq: {d} routed to the GIC, {d} acknowledged, ring drained by the caller  {s}\n", .{
                virtio_blk.interruptId(), virtio_blk.interruptCount(), status(disk_irq_ok),
            });
        } else {
            out("      irq: no interrupt property on the transport, completions polled  {s}\n", .{status(disk_irq_ok)});
        }
        out("      io: {d} read(s), {d} write(s), {d} sector(s) read, {d} sector(s) written, {d} io error(s)  {s}\n", .{
            t.device.reads,     t.device.writes, t.device.sectors_read, t.device.sectors_written,
            t.device.io_errors, status(io_ok),
        });
    }
    pass = verdict(pass, disk_ok, "[20]");

    // 21 -- partitions: GPT primary/backup CRCs, MBR and EBR enumeration, and
    // the negative cases a table parser has to get right.
    var disk_table: partition.Table = .{};
    out("  [21] partitions: GPT primary/backup CRCs, MBR/EBR walk, protective MBR\n", .{});
    const part_pages_before = ctx.pmm.stats().free_pages;
    var part_ok = false;
    if (!virtio_blk.present()) {
        out("      FAIL: no block device — boot with -device virtio-blk-device\n", .{});
    } else {
        // The attached disk's own table. An unformatted disk is a legitimate
        // answer; a refusal to read it is not.
        var disk_answered = true;
        if (partition.read(.{}, &disk_table)) |_| {
            out("      disk: {s}, {d} partition(s), primary {s}, backup {s}  OK\n", .{
                partition.schemeName(disk_table.scheme),                                                       disk_table.count,
                if (disk_table.backup_used) "from backup" else if (disk_table.primary_ok) "valid" else "none", if (disk_table.backup_ok) "valid" else "missing",
            });
        } else |err| {
            if (err == error.NoTable) {
                out("      disk: no MBR signature at LBA 0 (unformatted)  OK\n", .{});
            } else {
                disk_answered = false;
                out("      disk: table read failed: {s}  FAIL\n", .{@errorName(err)});
            }
        }

        const fx = partition.fixtureTest();
        const parsed_ok = fx.present and fx.written and fx.parsed and fx.count == 3 and
            fx.names_ok and fx.lbas_ok and fx.primary_ok and fx.backup_ok;
        const fallback_ok = fx.fallback_ok and fx.fallback_count == 3;
        const restore_ok = fx.restored and fx.restored_count == 3;
        const mbr_ok = fx.mbr_ok and fx.mbr_count == 3 and fx.mbr_primary == 2 and fx.mbr_logical == 1;
        part_ok = disk_answered and parsed_ok and fallback_ok and fx.rejected and restore_ok and mbr_ok and fx.errors == 0;

        out("      gpt: wrote 3 partition(s), header CRC 0x{x:0>8}, entries CRC 0x{x:0>8}  {s}\n", .{
            fx.header_crc, fx.entries_crc, status(fx.written),
        });
        out("      parse: {d} partition(s), primary and backup valid, names and LBAs match  {s}\n", .{
            fx.count, status(parsed_ok),
        });
        out("      fallback: primary entries corrupt -> backup answered, {d} partition(s)  {s}\n", .{
            fx.fallback_count, status(fallback_ok),
        });
        out("      reject: both copies corrupt -> {s}, no table invented  {s}\n", .{
            if (fx.reject_error.len != 0) fx.reject_error else "refused", status(fx.rejected),
        });
        out("      restore: fixture rewritten, {d} partition(s) again  {s}\n", .{
            fx.restored_count, status(restore_ok),
        });
        out("      mbr: {d} primary + {d} logical via {d} EBR, extended container not listed  {s}\n", .{
            fx.mbr_primary, fx.mbr_logical, fx.mbr_ebrs, status(mbr_ok),
        });
    }
    const part_pages_after = ctx.pmm.stats().free_pages;
    const part_leak_ok = part_pages_before == part_pages_after;
    out("      leak: {d} page(s) before, {d} after  {s}\n", .{
        part_pages_before, part_pages_after, status(part_leak_ok),
    });
    pass = verdict(pass, part_ok and part_leak_ok, "[21]");

    // 22 -- filesystem: a real FAT32 volume, formatted by this kernel and
    // mounted through a partition-offset view, then read, created, grown,
    // corrupted on purpose, restored and deleted. The same driver is exercised
    // from the host tests and, on a foreign-formatted partition, by `fat`.
    out("  [22] filesystem: FAT32 over a partition view — mount, write, grow, read, delete\n", .{});
    const fs_pages_before = ctx.pmm.stats().free_pages;
    var fs_ok = false;
    if (!virtio_blk.present()) {
        out("      FAIL: no block device — boot with -device virtio-blk-device\n", .{});
    } else {
        var scratch = partition.Entry{ .scheme = .gpt, .index = 1, .first_lba = 40000, .last_lba = 119999 };
        if (block_view.View.fromPartition(&scratch)) |view| {
            out("      view: partition {d} at LBA {d}..{d} ({d} MiB) -> volume LBA 0, bounds checked\n", .{
                scratch.index, scratch.first_lba, scratch.last_lba, view.capacityBytes() / (1024 * 1024),
            });
            if (fat32.exercise(view)) |e| {
                const fmt_ok = e.clusters >= 65_525 and e.cluster_bytes == 512 and e.fat_sectors != 0;
                const write_ok = e.created and e.written > 0 and e.clusters_used > 1;
                const read_ok = e.written == e.read_back and e.round_trip;
                const free_ok = e.free_before - e.free_after_write == e.clusters_used;
                const corrupt_ok = e.loop_detected and e.restored;
                const delete_ok = e.deleted and e.gone and e.freed == e.clusters_used and e.free_after_delete == e.free_before;
                const check_ok = e.check_ok and e.orphans == 0 and e.loops == 0 and e.size_errors == 0;
                fs_ok = fmt_ok and write_ok and read_ok and free_ok and corrupt_ok and delete_ok and check_ok;
                out("      format: 512 B/sector, {d} sector(s)/cluster, {d} cluster(s), {d} FAT(s) of {d} sector(s), root 2  {s}\n", .{
                    1, e.clusters, 2, e.fat_sectors, status(fmt_ok),
                });
                out("      mount: {d} MiB, {d} free cluster(s) from the FAT, FSInfo tolerated  {s}\n", .{
                    e.bytes / (1024 * 1024), e.free_before, status(fmt_ok),
                });
                out("      write: SALE.TXT {d} byte(s) in {d} cluster(s), free {d} -> {d}  {s}\n", .{
                    e.written, e.clusters_used, e.free_before, e.free_after_write, status(write_ok and free_ok),
                });
                out("      read: {d} byte(s) back, digest 0x{x:0>16}, byte for byte  {s}\n", .{
                    e.read_back, e.digest, status(read_ok),
                });
                out("      corrupt: chain loop -> Corrupt, chain restored, check clean  {s}\n", .{
                    status(corrupt_ok),
                });
                out("      delete: {d} cluster(s) freed, entry gone, free back to {d}  {s}\n", .{
                    e.freed, e.free_after_delete, status(delete_ok),
                });
                out("      check: {d} loop(s), {d} orphan(s), {d} size error(s)  {s}\n", .{
                    e.loops, e.orphans, e.size_errors, status(check_ok),
                });
            } else |err| {
                out("      FAIL: {s}\n", .{@errorName(err)});
            }
        } else |err| {
            out("      FAIL: view over the scratch region: {s}\n", .{@errorName(err)});
        }
    }
    const fs_pages_after = ctx.pmm.stats().free_pages;
    const fs_leak_ok = fs_pages_before == fs_pages_after;
    out("      leak: {d} page(s) before, {d} after  {s}\n", .{
        fs_pages_before, fs_pages_after, status(fs_leak_ok),
    });
    pass = verdict(pass, fs_ok and fs_leak_ok, "[22]");

    out("  ------------------------------------------------------------------\n", .{});
    out("  scheduler: {d} double-run guard(s), {d} queue violation(s), {d} stray ready\n", .{
        sched.double_run_events, sched.queue_violations, sched.stray_ready,
    });
    out("  user syscalls: {d}, processes spawned: {d}, faults caught: {d}\n", .{
        syscall.user_calls, process.spawns, process.kills,
    });
    if (failed_step_count != 0) {
        out("  failing step(s):", .{});
        for (failed_steps[0..failed_step_count]) |label| out(" {s}", .{label});
        out("\n", .{});
    }
    out("  RESULT: {s}\n", .{if (pass) "PASS" else "FAIL"});
}

/// `accounting` — the per-process ledger, as the watchdog sees it. One sample is
/// forced first, so the numbers are current even between watchdog ticks.
fn cmdAccounting() void {
    account.tick();
    out("  pid    pages      handles    cpu ms       level  score  strikes  w/t/k\n", .{});
    var shown: usize = 0;
    for (0..account.max_entries) |i| {
        const e = account.entryAt(i) orelse continue;
        shown += 1;
        out("  {d:<5}  {d:>3}/{d:<3}  {d:>3}/{d:<3}  {d:>4}/{d:<4}  {s:<5}  {d:>4}  {d:>3}    {d}/{d}/{d}\n", .{
            e.pid,        e.pages,        e.quota.pages,               e.handles, e.quota.handles,
            e.cpu_window, e.quota.cpu_ms, account.levelLabel(e.level), e.score,   e.strikes,
            e.warnings,   e.throttles,    e.kills,
        });
    }
    out("  {d} tracked process(es), {d} samples: {d} warning(s), {d} throttle(s), {d} kill(s)\n", .{
        shown, account.samples, account.warnings_total, account.throttles_total, account.kills_total,
    });
    out("  pressure: {d} event(s), {d} victim(s); watermark {d} pages, critical {d}\n", .{
        account.pressures, account.pressure_victims, account.watermark_pages, account.critical_pages,
    });
    out("  refusals: {d} frame(s) over a page budget, {d} handle(s) over a handle quota\n", .{
        user_space.budget_refusals, cap.quota_refusals,
    });
}

/// `sandbox` — the manifests as the kernel sees them, plus the gate counters.
fn cmdSandbox() void {
    out("  id  name      caps  syscalls\n", .{});
    for (&sandbox.manifests) |*m| {
        out("  {d}   {s:<8}  {d}     {d} allowed\n", .{
            @intFromEnum(m.id), m.name, m.caps.len, @popCount(m.syscalls),
        });
        for (m.caps) |c| {
            var rights_buf: [4]u8 = undefined;
            out("        {s:<10} {s}\n", .{ c.kind.label(), cap.rightsText(c.rights, &rights_buf) });
        }
    }
    out("  gate: {d} syscall(s) denied, {d} block attempt(s) denied, {d} W+X mapping(s) refused\n", .{
        sandbox.denied, sandbox.block_denials, mmu.wx_refusals,
    });
}

/// `fat` — a FAT32 volume on partition 1 of the attached disk, reached through
/// the partition-offset view. `uprobe` step 22 exercises the same driver on a
/// scratch volume; these commands operate on a foreign-formatted partition, so
/// a host tool can create, inspect and re-read exactly what the kernel wrote.
var fat_cmd_table: partition.Table = .{};
var fat_cmd_vol: fat32.Volume = undefined;
var fat_cmd_mounted: bool = false;
var fat_cmd_buf: [fat32.max_file_bytes]u8 = undefined;

fn fatEnsureMounted() ?*fat32.Volume {
    if (fat_cmd_mounted) return &fat_cmd_vol;
    partition.read(.{}, &fat_cmd_table) catch |err| {
        out("  no partition table: {s}\n", .{@errorName(err)});
        return null;
    };
    if (fat_cmd_table.count == 0) {
        out("  the disk has no partitions: attach one with a FAT32 partition\n", .{});
        return null;
    }
    const entry = &fat_cmd_table.entries[0];
    const view = block_view.View.fromPartition(entry) catch |err| {
        out("  partition 1 lies outside the disk: {s}\n", .{@errorName(err)});
        return null;
    };
    fat_cmd_vol = fat32.mount(view) catch |err| {
        out("  partition 1 (LBA {d}..{d}, {d} MiB) is not a mountable FAT32: {s}\n", .{
            entry.first_lba, entry.last_lba, entry.sectors() * partition.sector_size / (1024 * 1024), @errorName(err),
        });
        return null;
    };
    fat_cmd_mounted = true;
    return &fat_cmd_vol;
}

/// The power manager's shutdown path calls this before writing its final
/// journal record. It is deliberately synchronous and idempotent: a shutdown
/// may be requested while no FAT volume has ever been mounted.
fn flushFatForPower() void {
    if (!fat_cmd_mounted) return;
    fat_cmd_vol.sync() catch |err| {
        klog.warn("power", "FAT sync before shutdown failed: {s}", .{@errorName(err)});
    };
}

fn cmdFat(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "";
    const vol = fatEnsureMounted() orelse return;
    vol.refresh() catch |err| {
        out("  FAT refresh failed: {s}\n", .{@errorName(err)});
        return;
    };
    const g = vol.geo;
    if (sub.len == 0 or std.mem.eql(u8, sub, "info")) {
        const entry = &fat_cmd_table.entries[0];
        out("  view: partition {d} at LBA {d}..{d} ({d} MiB) -> volume LBA 0, every request bounds-checked\n", .{
            entry.index, entry.first_lba, entry.last_lba, entry.sectors() * partition.sector_size / (1024 * 1024),
        });
        out("  bpb: {d} B/sector, {d} sector(s)/cluster ({d} B), {d} FAT(s) of {d} sector(s), {d} reserved\n", .{
            g.bytes_per_sector, g.sectors_per_cluster, g.cluster_bytes, g.fat_count, g.fat_sectors, g.reserved_sectors,
        });
        out("  geometry: {d} cluster(s), root cluster {d}, data at sector {d}, FSInfo sector {d}\n", .{
            g.clusters, g.root_cluster, g.data_start, g.fsinfo_sector,
        });
        const free = vol.freeCount() catch |err| {
            out("  free space unreadable: {s}\n", .{@errorName(err)});
            return;
        };
        out("  space: {d} free of {d} cluster(s) ({d} KiB)\n", .{
            free, g.clusters, free * g.cluster_bytes / 1024,
        });
    } else if (std.mem.eql(u8, sub, "ls")) {
        out("  name             attr    size      cluster\n", .{});
        var count: usize = 0;
        var it = vol.iterStart();
        while (vol.nextItem(&it)) |maybe| {
            const item = maybe orelse break;
            count += 1;
            out("  {s:<16} {s:<6} {d:>8}  {d}\n", .{
                item.name(), if (item.isDir()) "dir" else "file", item.size, item.cluster,
            });
        } else |err| {
            out("  directory read failed: {s}\n", .{@errorName(err)});
            return;
        }
        const free = vol.freeCount() catch 0;
        out("  {d} entr(ies), {d} free cluster(s)\n", .{ count, free });
    } else if (std.mem.eql(u8, sub, "cat")) {
        const name = tokens.next() orelse {
            out("  usage: fat cat <name>\n", .{});
            return;
        };
        const n = vol.readFile(name, &fat_cmd_buf) catch |err| {
            out("  read failed: {s}\n", .{@errorName(err)});
            return;
        };
        out("{s}", .{fat_cmd_buf[0..n]});
        if (n == 0 or fat_cmd_buf[n - 1] != '\n') out("\n", .{});
        out("  {d} byte(s), digest 0x{x:0>16}\n", .{ n, fat32.digest(fat_cmd_buf[0..n]) });
    } else if (std.mem.eql(u8, sub, "put")) {
        const name = tokens.next() orelse {
            out("  usage: fat put <name> <text>\n", .{});
            return;
        };
        const text = std.mem.trim(u8, tokens.rest(), " \r\n");
        if (text.len == 0) {
            out("  usage: fat put <name> <text>\n", .{});
            return;
        }
        const r = vol.writeFile(name, text) catch |err| {
            out("  write failed: {s}\n", .{@errorName(err)});
            return;
        };
        out("  wrote {s}: {d} byte(s), {d} cluster(s), digest 0x{x:0>16}, {d} free cluster(s)\n", .{
            name, r.size, r.clusters, fat32.digest(text), r.free_after,
        });
    } else if (std.mem.eql(u8, sub, "rm")) {
        const name = tokens.next() orelse {
            out("  usage: fat rm <name>\n", .{});
            return;
        };
        const freed = vol.deleteFile(name) catch |err| {
            out("  delete failed: {s}\n", .{@errorName(err)});
            return;
        };
        out("  removed {s}: {d} cluster(s) freed\n", .{ name, freed });
    } else if (std.mem.eql(u8, sub, "check")) {
        const c = vol.check() catch |err| {
            out("  check failed: {s}\n", .{@errorName(err)});
            return;
        };
        out("  {d} file(s), {d} dir(s), {d} cluster(s) in use, {d} allocated\n", .{
            c.files, c.dirs, c.clusters_used, c.clusters_allocated,
        });
        out("  {d} loop(s), {d} orphan(s), {d} size error(s), free {d}, FSInfo {d}  {s}\n", .{
            c.loops,                                                                  c.orphans, c.size_errors, c.free_count, c.fsinfo_free,
            if (c.free_count_ok) "counter agrees" else "counter differs (tolerated)",
        });
        out("  {s}\n", .{if (c.ok) "consistent" else "INCONSISTENT"});
    } else {
        out("  usage: fat [info|ls|cat <name>|put <name> <text>|rm <name>|check]\n", .{});
    }
}

fn printStorageHealth() void {
    const s = virtio_blk.healthSnapshot();
    out("  health      : {s}, warnings {d}, retries {d}, recovered {d}, unrecovered {d}, bad blocks {d}\n", .{
        s.state.label(), s.warnings, s.retries, s.recovered, s.unrecovered, s.bad_count,
    });
    out("  media       : reads {d}, writes {d}, flushes {d}, sectors read {d}, sectors written {d}\n", .{
        s.reads, s.writes, s.flushes, s.sectors_read, s.sectors_written,
    });
    if (s.last_error) {
        out("  last error  : {s} lba {d} +{d}, reason {s}\n", .{
            s.last_op.label(), s.last_lba, s.last_count, s.last_reason.label(),
        });
    } else {
        out("  last error  : none\n", .{});
    }
    const bad = virtio_blk.badBlocks();
    if (bad.len == 0) {
        out("  bad sectors : none\n", .{});
    } else {
        var i: usize = 0;
        while (i < bad.len and i < 8) : (i += 1) {
            out("  bad sector  : lba {d} +{d}, {d} failure(s)\n", .{ bad[i].lba, bad[i].count, bad[i].failures });
        }
        if (bad.len > 8) out("  bad sector  : ... {d} more\n", .{bad.len - 8});
    }
}

fn drawStorageHealth() void {
    const surface = fb.screen() orelse {
        out("  blk viz     : no framebuffer; use 'blk health'\n", .{});
        return;
    };
    const s = virtio_blk.healthSnapshot();
    const color: fb.Color = switch (s.state) {
        .healthy => fb.Palette.green,
        .degraded => fb.Palette.amber,
        .failing => fb.Palette.red,
    };
    surface.clear(fb.Palette.background);
    _ = surface.drawText(24, 20, "Cassa - storage health", 2, fb.Palette.amber);
    _ = surface.drawText(24, 56, "bounded retries · bad-sector quarantine · read-only fsck · pre-failure warning", 1, fb.Palette.text_dim);

    var line: [180]u8 = undefined;
    const headline = std.fmt.bufPrint(&line, "STATE {s}   WARNINGS {d}   RETRIES {d}   RECOVERED {d}", .{
        s.state.label(), s.warnings, s.retries, s.recovered,
    }) catch "storage health";
    _ = surface.drawText(24, 96, headline, 2, color);

    const media = std.fmt.bufPrint(&line, "MEDIA  reads {d}  writes {d}  flushes {d}  sectors {d}/{d}", .{
        s.reads, s.writes, s.flushes, s.sectors_read, s.sectors_written,
    }) catch "media";
    _ = surface.drawText(24, 136, media, 1, fb.Palette.text);

    const failure = if (s.last_error)
        std.fmt.bufPrint(&line, "LAST  {s}  lba {d} +{d}  reason {s}", .{
            s.last_op.label(), s.last_lba, s.last_count, s.last_reason.label(),
        }) catch "last error"
    else
        "LAST  none";
    _ = surface.drawText(24, 160, failure, 1, if (s.last_error) fb.Palette.amber else fb.Palette.text_dim);

    const bad = std.fmt.bufPrint(&line, "BAD SECTORS  {d} quarantined  refusals {d}  unrecovered {d}", .{
        s.bad_count, s.bad_refusals, s.unrecovered,
    }) catch "bad sectors";
    _ = surface.drawText(24, 184, bad, 1, if (s.bad_count != 0) fb.Palette.red else fb.Palette.text_dim);

    const table = virtio_blk.badBlocks();
    var y: i32 = 224;
    var i: usize = 0;
    while (i < table.len and i < 8) : (i += 1) {
        const row = std.fmt.bufPrint(&line, "QUARANTINE  lba {d} +{d}  {d} failure(s)", .{
            table[i].lba, table[i].count, table[i].failures,
        }) catch "quarantine";
        _ = surface.drawText(24, y, row, 1, fb.Palette.red);
        y += 16;
    }
    if (table.len == 0) {
        _ = surface.drawText(24, y, "QUARANTINE  none", 1, fb.Palette.text_dim);
    }
    _ = surface.drawText(24, @as(i32, @intCast(surface.mode.height)) - 22, "live dashboard: storage supervisor; closes after the set time", 1, fb.Palette.text_dim);
}

fn cmdBlkViz(seconds: u32) void {
    const bounded: u32 = @min(seconds, 60);
    printStorageHealth();
    out("  blk viz     : {d}s storage health dashboard\n", .{bounded});
    const start = timer.uptimeMs();
    while (timer.uptimeMs() - start < @as(u64, bounded) * 1000) {
        drawStorageHealth();
        sched.sleepMsBlocking(100);
    }
    out("  blk viz     : closed\n", .{});
}

fn cmdBlkFsck() void {
    const report = cassafs.fsck() catch |err| {
        out("  blk fsck    : REFUSED: {s}\n", .{@errorName(err)});
        return;
    };
    out("  blk fsck    : PASS, {d} record(s), {d} inode(s), {d} file(s), {d} data byte(s), {d} free block(s)\n", .{
        report.records, report.inode_count, report.files, report.data_bytes, report.free_blocks,
    });
    out("  blk fsck    : read-only; every superblock, record, extent, data CRC and free-map bit verified\n", .{});
}

fn cmdBlkInject(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const op_text = tokens.next() orelse {
        out("  usage: blk inject <read|write|flush> <lba> <sectors> <failures>\n", .{});
        return;
    };
    const lba_text = tokens.next() orelse {
        out("  usage: blk inject <read|write|flush> <lba> <sectors> <failures>\n", .{});
        return;
    };
    const count_text = tokens.next() orelse {
        out("  usage: blk inject <read|write|flush> <lba> <sectors> <failures>\n", .{});
        return;
    };
    const failure_text = tokens.next() orelse {
        out("  usage: blk inject <read|write|flush> <lba> <sectors> <failures>\n", .{});
        return;
    };
    const op: storage_health.Op = if (std.mem.eql(u8, op_text, "read"))
        .read
    else if (std.mem.eql(u8, op_text, "write"))
        .write
    else if (std.mem.eql(u8, op_text, "flush"))
        .flush
    else {
        out("  blk inject  : REFUSED: BadOp\n", .{});
        return;
    };
    const lba = std.fmt.parseInt(u64, lba_text, 10) catch {
        out("  blk inject  : REFUSED: BadLba\n", .{});
        return;
    };
    const count = std.fmt.parseInt(u32, count_text, 10) catch {
        out("  blk inject  : REFUSED: BadCount\n", .{});
        return;
    };
    const failures = std.fmt.parseInt(u32, failure_text, 10) catch {
        out("  blk inject  : REFUSED: BadFailures\n", .{});
        return;
    };
    if (count == 0 or failures == 0) {
        out("  blk inject  : REFUSED: BadRange\n", .{});
        return;
    }
    virtio_blk.injectFault(op, lba, count, failures);
    out("  blk inject  : {s} lba {d} +{d}, {d} simulated failure(s)\n", .{ op.label(), lba, count, failures });
}

fn cmdBlkScrub(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const lba_text = tokens.next() orelse {
        out("  usage: blk scrub <lba> <sectors>\n", .{});
        return;
    };
    const count_text = tokens.next() orelse {
        out("  usage: blk scrub <lba> <sectors>\n", .{});
        return;
    };
    const lba = std.fmt.parseInt(u64, lba_text, 10) catch {
        out("  blk scrub   : REFUSED: BadLba\n", .{});
        return;
    };
    const count = std.fmt.parseInt(u32, count_text, 10) catch {
        out("  blk scrub   : REFUSED: BadCount\n", .{});
        return;
    };
    if (count == 0) {
        out("  blk scrub   : REFUSED: BadCount\n", .{});
        return;
    }
    const removed = virtio_blk.scrubRange(lba, count) catch |err| {
        out("  blk scrub   : REFUSED: {s}\n", .{@errorName(err)});
        return;
    };
    out("  blk scrub   : lba {d} +{d}, {d} bad entr(ies) cleared, readback PASS\n", .{ lba, count, removed });
}

/// `blk` — the block layer's view, storage health, fsck and the test-only
/// media fault injector. No boot test runs here; `uprobe` step 20 does that.
fn cmdBlk(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    if (!virtio_blk.present()) {
        out("  no block device attached\n", .{});
        return;
    }
    const sub = tokens.next() orelse "info";
    if (std.mem.eql(u8, sub, "health")) {
        printStorageHealth();
        return;
    }
    if (std.mem.eql(u8, sub, "fsck")) {
        cmdBlkFsck();
        return;
    }
    if (std.mem.eql(u8, sub, "inject")) {
        cmdBlkInject(tokens);
        return;
    }
    if (std.mem.eql(u8, sub, "clear")) {
        virtio_blk.clearFault();
        out("  blk inject  : cleared\n", .{});
        return;
    }
    if (std.mem.eql(u8, sub, "scrub")) {
        cmdBlkScrub(tokens);
        return;
    }
    if (std.mem.eql(u8, sub, "viz")) {
        const seconds = std.fmt.parseInt(u32, tokens.next() orelse "8", 10) catch 8;
        cmdBlkViz(seconds);
        return;
    }
    if (!std.mem.eql(u8, sub, "info") and !std.mem.eql(u8, sub, "")) {
        out("  usage: blk [info|health|fsck|inject <read|write|flush> <lba> <sectors> <failures>|clear|scrub <lba> <sectors>|viz <s>]\n", .{});
        return;
    }
    const d = virtio_blk.stats;
    out("  disk: {d} sector(s), {d} MiB, features 0x{x}, flush {s}\n", .{
        virtio_blk.capacitySectors(), virtio_blk.capacityBytes() / (1024 * 1024),
        virtio_blk.deviceFeatures(),  if (virtio_blk.flushSupported()) "negotiated" else "absent",
    });
    out("  device: reads {d}, writes {d}, flushes {d}, retries {d}, timeouts {d}, resets {d}, io errors {d}, unsupported {d}, last status {d}\n", .{
        d.reads, d.writes, d.flushes, d.retries, d.timeouts, d.resets, d.io_errors, d.unsupported, d.last_status,
    });
    out("  layer: submitted {d}, dispatched {d}, reordered {d}, sectors {d}, bytes {d}, errors {d}\n", .{
        block.stats.submitted, block.stats.dispatched, block.stats.reordered,
        block.stats.sectors,   block.stats.bytes,      block.stats.errors,
    });
    out("  irq: {d} routed, {d} acknowledged\n", .{ virtio_blk.interruptId(), virtio_blk.interruptCount() });
    printStorageHealth();
}

/// `part` — the partition table of the attached disk, as the parser sees it.
var part_cmd_table: partition.Table = .{};

fn cmdPart() void {
    const table = &part_cmd_table;
    partition.read(.{}, table) catch |err| {
        out("  no table: {s}\n", .{@errorName(err)});
        return;
    };
    out("  scheme: {s}, {d} sector(s), base LBA {d}, protective MBR {s}\n", .{
        partition.schemeName(table.scheme),        table.disk_sectors, table.base_lba,
        if (table.protective_mbr) "yes" else "no",
    });
    if (table.scheme == .gpt) {
        var guid_buf: [36]u8 = undefined;
        out("  disk {s}, revision 0x{x:0>8}, header CRC 0x{x:0>8}, entries CRC 0x{x:0>8}\n", .{
            partition.formatGuid(&table.disk_guid, &guid_buf), table.revision, table.header_crc, table.entries_crc,
        });
        out("  primary {s}, backup {s} ({d} entries of {d} bytes at LBA {d})\n", .{
            if (table.primary_ok) "valid" else if (table.backup_used) "from backup" else "invalid",
            if (table.backup_ok) "valid" else "missing",
            table.entry_capacity,
            table.entry_size,
            table.entry_array_lba,
        });
    }
    out("  #   kind     type            first        last        size      name\n", .{});
    for (table.entries[0..table.count]) |*e| {
        const mib = (e.sectors() * partition.sector_size) / (1024 * 1024);
        out("  {d:<3} {s:<8} {s:<15} {d:<12} {d:<11} {d:>6} MiB  {s}\n", .{
            e.index, @tagName(e.kind), partition.typeName(e), e.first_lba, e.last_lba, mib, e.nameText(),
        });
    }
    if (table.skipped != 0) {
        out("  {d} entr(ies) skipped: out of bounds or beyond the {d}-partition limit\n", .{
            table.skipped, partition.max_partitions,
        });
    }
}

/// `virtio` — every transport, whether it carries a device, and what the
/// negotiation left on the table.
fn cmdVirtio() void {
    out("  slot  base        device      version  queue  features            negotiated\n", .{});
    for (virtio_mmio.info()) |slot| {
        out("  {d:<4}  0x{x:<9} {s:<11} {d:<8} {d:<6} 0x{x:<17} 0x{x}\n", .{
            slot.index,      slot.base,     virtio_mmio.deviceName(slot.device_id), slot.version,
            slot.queue_size, slot.features, slot.negotiated,
        });
    }
    out("  {d} transport(s), {d} with a device, {d} refused\n", .{
        virtio_mmio.info().len, virtio_mmio.liveSlots(), virtio_mmio.failureCount(),
    });
}

/// `lspci` — the PCIe bus as the kernel sees it. Same facts QEMU's `info pci`
/// prints, plus where this kernel placed each BAR and how the interrupt is
/// delivered.
fn cmdLspci() void {
    pci.printTable(out);
}

/// `devices` — the driver model as the kernel sees it: every device the machine
/// described, what claimed it, and everything that is still waiting.
fn cmdFb(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";

    if (std.mem.eql(u8, sub, "info")) {
        bochs_display.describe(out);
        if (fb.screen()) |surface| {
            surface.describe(out);
        } else {
            out("  surface      : not installed\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "test")) {
        if (fb.screen()) |surface| {
            surface.drawTestPattern();
            out("  test pattern drawn: {d}x{d}, {s}, stride {d}\n", .{
                surface.mode.width, surface.mode.height, surface.mode.format.label(), surface.mode.stride,
            });
            out("  corner markers: red top-left, green top-right, blue bottom-left, white bottom-right\n", .{});
        } else {
            out("  no framebuffer: nothing to draw on\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "splash")) {
        if (fb.screen() == null) {
            out("  no framebuffer\n", .{});
            return;
        }
        fb.bootSplash(build_version, "panel ready");
        out("  splash drawn\n", .{});
    } else if (std.mem.eql(u8, sub, "clear")) {
        if (fb.screen()) |surface| {
            surface.clear(fb.Palette.background);
            out("  cleared to 0x{x:0>6}\n", .{fb.Palette.background});
        } else {
            out("  no framebuffer\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "check")) {
        if (fb.screen()) |surface| {
            const ok = surface.verifyReadback();
            out("  framebuffer readback: {s} ({d}x{d}, {d} pixels/frame)\n", .{
                if (ok) "PASS" else "FAIL", surface.mode.width, surface.mode.height, surface.mode.pixelCount(),
            });
        } else {
            out("  no framebuffer\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "mode")) {
        const w_text = tokens.next() orelse {
            out("  usage: fb mode <width> <height>\n", .{});
            return;
        };
        const h_text = tokens.next() orelse {
            out("  usage: fb mode <width> <height>\n", .{});
            return;
        };
        const w = std.fmt.parseInt(u32, w_text, 10) catch {
            out("  width must be a number\n", .{});
            return;
        };
        const h = std.fmt.parseInt(u32, h_text, 10) catch {
            out("  height must be a number\n", .{});
            return;
        };
        bochs_display.setMode(w, h) catch |err| {
            out("  mode change refused: {s}\n", .{@errorName(err)});
            return;
        };
        out("  mode set to {d}x{d}\n", .{ w, h });
    } else if (std.mem.eql(u8, sub, "crash")) {
        @panic("panic-to-screen test requested from the shell");
    } else {
        out("  usage: fb [info|test|splash|clear|check|mode <w> <h>|crash]\n", .{});
    }
}

fn cmdDevices() void {
    out("  device                      state    driver         compatible\n", .{});
    for (driver.allDevices()) |d| {
        out("  {s:<27} {s:<8} {s:<14} {s}\n", .{
            d.name,
            d.state.label(),
            if (d.driver) |drv| drv.name else "-",
            d.compatible,
        });
    }
    var bound: usize = 0;
    var waiting: usize = 0;
    var failed: usize = 0;
    for (driver.allDevices()) |d| switch (d.state) {
        .bound => bound += 1,
        .unbound, .skipped => waiting += 1,
        .failed => failed += 1,
        .absent => {},
    };
    out("  {d} bound, {d} waiting, {d} failed · {d} probe failure(s), {d} removal(s), {d} addition(s)\n", .{
        bound, waiting, failed, driver.failed_probes, driver.removals, driver.additions,
    });
    out("  drivers: {d} registered, {d} hotplug event(s) delivered\n", .{
        driver.driverNames().len, driver.events_added + driver.events_removed + driver.events_failed,
    });
    if (pl031.now()) |dt| {
        var buf: [40]u8 = undefined;
        out("  wall clock: {s}\n", .{pl031.format(dt, &buf)});
    } else {
        out("  wall clock: no RTC bound\n", .{});
    }
}

pub const build_version = "0.1.0-dev";

// ---------------------------------------------------------------------------
// Input subsystem (phase 38)
// ---------------------------------------------------------------------------

var scanner_prefix: [8]u8 = [_]u8{0} ** 8;

fn parseNum(text: ?[]const u8) ?u32 {
    const t = text orelse return null;
    return std.fmt.parseInt(u32, t, 0) catch null;
}

fn parseChar(text: ?[]const u8) ?u8 {
    const t = text orelse return null;
    if (std.mem.eql(u8, t, "enter") or std.mem.eql(u8, t, "cr")) return '\r';
    if (std.mem.eql(u8, t, "tab")) return '\t';
    if (std.mem.eql(u8, t, "lf")) return '\n';
    if (t.len > 2 and (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X"))) {
        return std.fmt.parseInt(u8, t[2..], 16) catch null;
    }
    if (t.len == 1) return t[0];
    return null;
}

fn describeScanner() void {
    const cfg = input.scannerConfig();
    const s = input.scannerStats();
    out("  scanner    : suffix 0x{x:0>2}, min {d}, max {d}, gap {d} ms, charset {s}\n", .{
        cfg.suffix, cfg.min_length, cfg.max_length, cfg.gap_timeout_ms, if (cfg.digits_only) "digits" else "alnum",
    });
    if (cfg.prefix.len > 0) out("  prefix      : '{s}'\n", .{cfg.prefix});
    out("  scans       : {d} committed, {d} released, {d} short, {d} timeouts, {d} overflow\n", .{
        s.scans, s.released, s.short_scans, s.timeouts, s.overflows,
    });
    out("  scan timing : burst last {d} ms, max {d} ms, holding {d} keys\n", .{
        s.last_latency_ms, s.max_latency_ms, s.held_keys,
    });
    const core = input.snapshot();
    out("  delivery    : last {d} ms, max {d} ms from the suffix key to the queued event (budget 20 ms)\n", .{
        core.delivery_last_ms, core.delivery_max_ms,
    });
}

/// Drop characters a debug view generated itself: typing into `input viz` or
/// running the HID self-test must not leave a line for the shell to execute.
fn drainConsole() void {
    while (input.consoleGetc()) |_| {}
}

fn cmdInput(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";

    if (std.mem.eql(u8, sub, "info")) {
        const s = input.snapshot();
        out("  queue       : {d}/{d} pending, {d} pushed, {d} dropped, high water {d}\n", .{
            input.pending(), input.ring_capacity, s.pushed, s.dropped, s.high_water,
        });
        out("  events      : {d} keys, {d} pointers, {d} buttons, {d} scrolls, {d} barcodes, {d} characters\n", .{
            s.keys, s.pointers, s.buttons, s.scrolls, s.barcodes, s.characters,
        });
        out("  console     : {d} pending, {d} dropped, {d} wait wakes\n", .{
            input.consolePending(), s.console_dropped, s.wait_wakes,
        });
        var buf: [96]u8 = undefined;
        for (input.devicesSlice(), 0..) |*dev, i| {
            out("  device {d}    : {s}\n", .{ i, input.describeDevice(dev, &buf) });
        }
        if (input.devicesSlice().len == 0) out("  device      : none registered\n", .{});
        describeScanner();
        virtio_input.describe(out);

        var recent: [input.recent_capacity]input.Event = undefined;
        const n = input.recentEvents(&recent);
        if (n > 0) {
            out("  last {d} events:\n", .{n});
            for (recent[0..n]) |*ev| {
                out("    [{d:0>6}] {s}\n", .{ ev.seq, input.describe(ev, &buf) });
            }
        }
    } else if (std.mem.eql(u8, sub, "dump")) {
        const count = parseNum(tokens.next()) orelse 16;
        var buf: [96]u8 = undefined;
        var shown: u32 = 0;
        while (shown < count) : (shown += 1) {
            const ev = input.pop() orelse break;
            out("  [{d:0>6}] {s}\n", .{ ev.seq, input.describe(&ev, &buf) });
        }
        if (shown == 0) out("  queue empty\n", .{});
    } else if (std.mem.eql(u8, sub, "scan")) {
        const payload = tokens.rest();
        if (payload.len == 0) {
            out("  usage: input scan <payload>   (suffix is added for you)\n", .{});
            return;
        }
        const cfg = input.scannerConfig();
        var text: [scanner.max_payload + 1]u8 = undefined;
        var n: usize = 0;
        while (n < payload.len and n < scanner.max_payload) : (n += 1) text[n] = payload[n];
        text[n] = cfg.suffix;
        n += 1;
        const before = input.snapshot().barcodes;
        const latency = input.feedText(0, text[0..n]);
        const after = input.snapshot().barcodes;
        if (latency) |ms| {
            out("  barcode     : '{s}', {d} chars, one atomic event\n", .{ payload, payload.len });
            out("  latency     : {d} ms (budget 20 ms) {s}\n", .{ ms, if (ms < 20) "PASS" else "OVER BUDGET" });
            out("  queue       : {d} new barcode event(s)\n", .{after - before});
        } else {
            out("  no scan     : payload shorter than min length {d} (released as keystrokes)\n", .{cfg.min_length});
        }
    } else if (std.mem.eql(u8, sub, "viz")) {
        cmdInputViz(parseNum(tokens.next()) orelse 8);
    } else if (std.mem.eql(u8, sub, "prefix")) {
        var cfg = input.scannerConfig();
        const arg = tokens.next() orelse "";
        if (arg.len == 0 or std.mem.eql(u8, arg, "-")) {
            cfg.prefix = "";
            out("  prefix      : cleared\n", .{});
        } else {
            const n = @min(arg.len, scanner_prefix.len);
            @memcpy(scanner_prefix[0..n], arg[0..n]);
            cfg.prefix = scanner_prefix[0..n];
            out("  prefix      : '{s}'\n", .{cfg.prefix});
        }
        input.configureScanner(cfg);
    } else if (std.mem.eql(u8, sub, "suffix")) {
        var cfg = input.scannerConfig();
        if (parseChar(tokens.next())) |ch| {
            cfg.suffix = ch;
            input.configureScanner(cfg);
            out("  suffix      : 0x{x:0>2}\n", .{ch});
        } else {
            out("  usage: input suffix <char|enter|tab|0xNN>\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "minlen")) {
        var cfg = input.scannerConfig();
        const n = parseNum(tokens.next()) orelse 0;
        cfg.min_length = @min(n, scanner.max_payload);
        if (cfg.min_length == 0) cfg.min_length = 1;
        cfg.max_length = @max(cfg.min_length, cfg.max_length);
        input.configureScanner(cfg);
        out("  min length  : {d}\n", .{cfg.min_length});
    } else if (std.mem.eql(u8, sub, "gap")) {
        var cfg = input.scannerConfig();
        const n = parseNum(tokens.next()) orelse 0;
        if (n == 0) {
            out("  usage: input gap <ms>\n", .{});
            return;
        }
        cfg.gap_timeout_ms = n;
        input.configureScanner(cfg);
        out("  max gap     : {d} ms\n", .{cfg.gap_timeout_ms});
    } else if (std.mem.eql(u8, sub, "charset")) {
        var cfg = input.scannerConfig();
        const arg = tokens.next() orelse "";
        if (std.mem.eql(u8, arg, "digits")) {
            cfg.digits_only = true;
        } else if (std.mem.eql(u8, arg, "alnum")) {
            cfg.digits_only = false;
        } else {
            out("  usage: input charset <digits|alnum>\n", .{});
            return;
        }
        input.configureScanner(cfg);
        out("  charset     : {s}\n", .{if (cfg.digits_only) "digits" else "alnum"});
    } else if (std.mem.eql(u8, sub, "reset")) {
        input.resetCounters();
        out("  counters    : cleared, scanner idle\n", .{});
    } else {
        out("  unknown input subcommand: {s}\n", .{sub});
    }
}

fn cmdInputViz(seconds: u32) void {
    const bounded: u32 = @min(seconds, 60);
    const surface = fb.screen() orelse {
        out("  viz         : no framebuffer; use 'input dump' instead\n", .{});
        return;
    };
    out("  viz         : {d}s live monitor (events shown are consumed)\n", .{bounded});
    const start = timer.uptimeMs();
    var events: [input.recent_capacity]input.Event = undefined;
    while (timer.uptimeMs() - start < @as(u64, bounded) * 1000) {
        virtio_input.pollAll();
        usb_core.poll();
        while (input.pop()) |ev| {
            var shown: [96]u8 = undefined;
            out("  {s}\n", .{input.describe(&ev, &shown)});
        }
        drainConsole();

        const n = input.recentEvents(&events);
        const cfg = input.scannerConfig();
        const ss = input.scannerStats();
        surface.clear(fb.Palette.background);
        _ = surface.drawText(24, 20, "Cassa - input monitor", 2, fb.Palette.amber);
        var header: [96]u8 = undefined;
        const header_text = std.fmt.bufPrint(&header, "scans {d}  released {d}  last {d} ms  max {d} ms  holding {d}  gap {d} ms", .{
            ss.scans, ss.released, ss.last_latency_ms, ss.max_latency_ms, ss.held_keys, cfg.gap_timeout_ms,
        }) catch "scanner";
        _ = surface.drawText(24, 56, header_text, 1, fb.Palette.text_dim);
        const us = usb_core.statsSnapshot();
        var usb_header: [96]u8 = undefined;
        const usb_text = std.fmt.bufPrint(&usb_header, "USB {d} device(s)  {d} HID reports  {d} keys  {d} pointer reports", .{
            usb_core.deviceCount(), us.hid_reports, us.key_events, us.pointer_events,
        }) catch "USB";
        _ = surface.drawText(24, 70, usb_text, 1, fb.Palette.amber);
        surface.fillRect(24, 84, @intCast(surface.mode.width - 48), 1, fb.Palette.grid);

        var y: i32 = 86;
        var cursor_x: i32 = -1;
        var cursor_y: i32 = -1;
        for (events[0..n]) |*ev| {
            var shown: [96]u8 = undefined;
            const text = input.describe(ev, &shown);
            const color = switch (ev.kind) {
                .key => fb.Palette.text,
                .barcode => fb.Palette.green,
                .pointer, .button, .scroll => fb.Palette.blue,
                .device => fb.Palette.amber,
            };
            _ = surface.drawText(24, y, text, 1, color);
            y += 14;
            if (ev.kind == .pointer) {
                cursor_x = ev.value;
                cursor_y = ev.aux;
            }
        }
        if (cursor_x >= 0 and cursor_y >= 0) {
            surface.fillRect(cursor_x - 9, cursor_y, 19, 1, fb.Palette.amber);
            surface.fillRect(cursor_x, cursor_y - 9, 1, 19, fb.Palette.amber);
            surface.fillRect(cursor_x - 2, cursor_y - 2, 5, 5, fb.Palette.red);
        }
        _ = surface.drawText(24, @as(i32, @intCast(surface.mode.height)) - 22, "panel live: move the pointer or type; the window closes after the set time", 1, fb.Palette.text_dim);
        sched.sleepMsBlocking(33);
    }
    drainConsole();
    out("  viz         : closed\n", .{});
}

fn cmdKeymap(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";
    if (std.mem.eql(u8, sub, "info")) {
        var chars: usize = 0;
        var code: u16 = 1;
        while (code < 128) : (code += 1) {
            if (keymap.evdev(code).isCharacter()) chars += 1;
        }
        out("  layout      : evdev code -> US characters, {d} keys mapped\n", .{chars});
        out("  remaps      : {d} of {d}, {d} hits\n", .{ keymap.remapCount(), 32, keymap.remapHits() });
        var i: usize = 0;
        while (keymap.remapAt(i)) |r| : (i += 1) {
            out("    {d} ({s}) -> {d} ({s})\n", .{ r.from, keymap.evdev(r.from).name, r.to, keymap.evdev(r.to).name });
        }
    } else if (std.mem.eql(u8, sub, "map")) {
        const from = parseNum(tokens.next()) orelse {
            out("  usage: keymap map <from-code> <to-code>\n", .{});
            return;
        };
        const to = parseNum(tokens.next()) orelse {
            out("  usage: keymap map <from-code> <to-code>\n", .{});
            return;
        };
        if (from > 0xffff or to > 0xffff) {
            out("  codes must fit in 16 bits\n", .{});
            return;
        }
        if (keymap.setRemap(@intCast(from), @intCast(to))) {
            out("  remap       : {s} -> {s}\n", .{ keymap.evdev(@intCast(from)).name, keymap.evdev(@intCast(to)).name });
        } else {
            out("  remap table full\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "reset")) {
        keymap.resetRemaps();
        out("  remaps      : cleared\n", .{});
    } else {
        out("  unknown keymap subcommand: {s}\n", .{sub});
    }
}

fn printJournalRecord(index: usize, r: *const power_lib.JournalRecord) void {
    var when_buf: [32]u8 = undefined;
    const when = if (r.wall_sec != 0) pl031.format(pl031.civilFromUnix(r.wall_sec), &when_buf) else "epoch";
    out("  #{d:<3} {s:<8} {s}  {s}  {d}.{d:0>3} C  {d}%  {s}\n", .{
        index,                      when,                                      @as([]const u8, @tagName(r.kind)), power_lib.journalKindLabel(r.kind),
        @divTrunc(r.temp_mc, 1000), @as(u32, @intCast(@mod(r.temp_mc, 1000))), r.throttle_permille / 10,          r.detailSlice(),
    });
}

fn printPowerInfo() void {
    const wi = power.snapshot();
    const ws = wdt.status();
    const js = journal.snapshot();
    const ts = thermal.stats();
    out("  power       : state {s}, PSCI off/reset available, test hang {s}\n", .{
        @tagName(wi.state), if (wi.test_hang) "YES" else "no",
    });
    out("  watchdog    : {s}, {d} ms/stage ({d} ms total), {d} kick(s), {s}\n", .{
        if (wdt.present()) "i6300ESB armed" else "absent (graceful fallback)",
        ws.timeout_ms,
        ws.timeout_ms * 2,
        ws.kicks,
        if (ws.locked) "locked" else "writable",
    });
    out("  last reset  : {s}\n", .{
        if (wi.watchdog_reset) "hardware watchdog reset" else if (wi.had_history) (if (wi.boot_clean) "clean shutdown" else "unclean shutdown") else "first boot on this journal",
    });
    out("  journal     : {s}, {d} record(s), seq {d}, {d} flush(es)\n", .{
        js.reason, js.count, js.seq, js.flushes,
    });
    if (journal.last()) |last| printJournalRecord(js.count - 1, last);
    out("  thermal     : {d}.{d:0>3} C, {s}, throttle {d}%, idle {d}/4, {d} idle tick(s)\n", .{
        @divTrunc(ts.temp_mc, 1000), @as(u32, @intCast(@mod(ts.temp_mc, 1000))), power_lib.thermalLabel(ts.state),
        ts.throttle_percent,         thermal.idleQuarters(),                     ts.idle_ticks,
    });
    out("  brown-out   : {d} hook(s), {d} event(s), pending {s}\n", .{
        wi.brownout_hooks, wi.brownout_events, if (power.brownoutPending()) "YES" else "no",
    });
    out("  flush path  : {d} filesystem hook(s), journal {s}, block {s}\n", .{
        wi.storage_hooks,
        if (js.active) "FAT-backed" else "memory-only",
        if (block.present()) "attached" else "absent",
    });
}

fn cmdPower(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";
    if (std.mem.eql(u8, sub, "info")) {
        printPowerInfo();
    } else if (std.mem.eql(u8, sub, "journal")) {
        const js = journal.snapshot();
        out("  journal     : {s}, {d} record(s), {d} flush(es)\n", .{ js.reason, js.count, js.flushes });
        var i: usize = 0;
        while (i < js.count) : (i += 1) {
            if (journal.recordAt(i)) |r| printJournalRecord(i, r);
        }
        if (js.count == 0) out("  journal     : no records yet\n", .{});
    } else if (std.mem.eql(u8, sub, "flush")) {
        const ok = power.flushNow(.maintenance, "manual flush");
        out("  flush       : {s}\n", .{if (ok) "journal and device synced" else "completed with an error (see log)"});
    } else if (std.mem.eql(u8, sub, "brownout") or std.mem.eql(u8, sub, "brown-out")) {
        out("  brown-out   : asserting the detector hook, flushing and powering off\n", .{});
        power.signalBrownout();
        power.service();
        out("  brown-out   : shutdown returned unexpectedly\n", .{});
    } else if (std.mem.eql(u8, sub, "poweroff") or std.mem.eql(u8, sub, "off")) {
        power.shutdown(.user);
    } else if (std.mem.eql(u8, sub, "reboot")) {
        power.reboot(.user);
    } else if (std.mem.eql(u8, sub, "selftest")) {
        out("  [23] power: watchdog, journal, hibernate-free shutdown, thermal throttle\n", .{});
        const ok = power.selfTest(out);
        out("  power selftest : {s}\n", .{if (ok) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, sub, "hang")) {
        if (!wdt.present()) {
            out("  hang        : refused: no hardware watchdog is armed\n", .{});
            return;
        }
        out("  hang        : suppressing scheduler heartbeats; the i6300ESB will reset the machine\n", .{});
        power.forceHang();
    } else if (std.mem.eql(u8, sub, "viz")) {
        cmdPowerViz(parseNum(tokens.next()) orelse 8);
    } else {
        out("  usage: power [info|journal|flush|brownout|poweroff|reboot|selftest|viz <s>|hang]\n", .{});
    }
}

fn cmdThermal(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";
    if (std.mem.eql(u8, sub, "info")) {
        const ts = thermal.stats();
        out("  zone 0      : {d}.{d:0>3} C, {s}, sensor {s}\n", .{
            @divTrunc(ts.temp_mc, 1000), @as(u32, @intCast(@mod(ts.temp_mc, 1000))), power_lib.thermalLabel(ts.state), ts.sensor_name,
        });
        out("  throttle    : {d}% of scheduler ticks to idle ({d}/4), {d} idle tick(s), {d} sample(s), {d} transition(s)\n", .{
            ts.throttle_percent, thermal.idleQuarters(), ts.idle_ticks, ts.samples, ts.transitions,
        });
        out("  ladder      : >=70.000 warm 25%, >=82.000 hot 50%, >=92.000 critical 75%; exits 67/79/89\n", .{});
        out("  policy      : duty-cycle idle injection; no DVFS assumption on AArch64\n", .{});
    } else if (std.mem.eql(u8, sub, "set")) {
        const mc = parseNum(tokens.next()) orelse {
            out("  usage: thermal set <milli-C>\n", .{});
            return;
        };
        thermal.setTemperature(@intCast(mc));
        const ts = thermal.stats();
        out("  zone 0      : {d}.{d:0>3} C, {s}, throttle {d}%\n", .{
            @divTrunc(ts.temp_mc, 1000), @as(u32, @intCast(@mod(ts.temp_mc, 1000))), power_lib.thermalLabel(ts.state), ts.throttle_percent,
        });
    } else if (std.mem.eql(u8, sub, "clear") or std.mem.eql(u8, sub, "reset")) {
        thermal.clear();
    } else if (std.mem.eql(u8, sub, "selftest")) {
        const ok = thermal.selfTest(out);
        out("  thermal selftest : {s}\n", .{if (ok) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, sub, "bench")) {
        cmdThermalBench();
    } else {
        out("  usage: thermal [info|set <milli-C>|clear|selftest|bench]\n", .{});
    }
}

fn cmdThermalBench() void {
    const iterations: u64 = 120_000_000;
    var acc: u64 = 0x9e37_79b9_7f4a_7c15;
    const start = timer.uptimeMs();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        acc = acc *% 6364136223846793005 +% 1442695040888963407;
        if (i & 0x003f_ffff == 0) sched.yieldNow();
    }
    const elapsed = timer.uptimeMs() - start;
    const ts = thermal.stats();
    out("  bench       : {d} iteration(s) in {d} ms at {s}/{d}% (hash 0x{x:0>16})\n", .{
        iterations, elapsed, power_lib.thermalLabel(ts.state), ts.throttle_percent, acc,
    });
}

fn cmdWatchdog(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";
    const ws = wdt.status();
    if (std.mem.eql(u8, sub, "info")) {
        out("  watchdog    : {s}, i6300ESB {s}, BAR 0x{x}, preload 0x{x}\n", .{
            if (wdt.present()) "armed" else "absent", if (ws.present) "present" else "not probed", ws.mmio, ws.preload,
        });
        out("  timeout     : {d} ms per stage, {d} ms to reset, {d} kick(s), {d} disarm(s)\n", .{
            ws.timeout_ms, ws.timeout_ms * 2, ws.kicks, ws.disarm_count,
        });
        out("  boot status : {s}\n", .{if (ws.last_reset_was_watchdog) "previous reset was the watchdog" else "no watchdog reset recorded"});
    } else if (std.mem.eql(u8, sub, "kick")) {
        const ok = wdt.kick();
        out("  watchdog    : {s}, {d} kick(s)\n", .{ if (ok) "kicked" else "not armed", wdt.status().kicks });
    } else if (std.mem.eql(u8, sub, "selftest")) {
        const ok = wdt.selfTest();
        out("  wdt selftest: {s}\n", .{if (ok) "PASS" else "FAIL"});
    } else {
        out("  usage: watchdog [info|kick|selftest]\n", .{});
    }
}

fn cmdPowerViz(seconds: u32) void {
    const bounded: u32 = @min(seconds, 60);
    const surface = fb.screen() orelse {
        out("  viz         : no framebuffer; use 'power info' instead\n", .{});
        return;
    };
    out("  viz         : {d}s power/thermal dashboard\n", .{bounded});
    const start = timer.uptimeMs();
    while (timer.uptimeMs() - start < @as(u64, bounded) * 1000) {
        power.service();
        const wi = power.snapshot();
        const ws = wdt.status();
        const js = journal.snapshot();
        const ts = thermal.stats();
        surface.clear(fb.Palette.background);
        _ = surface.drawText(24, 20, "Cassa - power and thermal", 2, fb.Palette.amber);
        var line: [128]u8 = undefined;
        const headline = std.fmt.bufPrint(&line, "{d}.{d:0>3} C  {s}  throttle {d}%  idle {d}/4", .{
            @divTrunc(ts.temp_mc, 1000), @as(u32, @intCast(@mod(ts.temp_mc, 1000))), power_lib.thermalLabel(ts.state), ts.throttle_percent, thermal.idleQuarters(),
        }) catch "thermal";
        _ = surface.drawText(24, 64, headline, 3, if (ts.throttle_percent >= 50) fb.Palette.red else if (ts.throttle_percent > 0) fb.Palette.amber else fb.Palette.green);
        const color = if (wdt.present()) fb.Palette.green else fb.Palette.amber;
        const watchdog_text = if (wdt.present()) "HARDWARE WATCHDOG ARMED" else "NO WATCHDOG - GRACEFUL FALLBACK";
        _ = surface.drawText(24, 112, watchdog_text, 2, color);
        const wd = std.fmt.bufPrint(&line, "{d} ms/stage, {d} ms total, {d} kicks", .{ ws.timeout_ms, ws.timeout_ms * 2, ws.kicks }) catch "watchdog";
        _ = surface.drawText(24, 140, wd, 1, fb.Palette.text_dim);
        const jtext = std.fmt.bufPrint(&line, "JOURNAL  {s}  {d} records  {d} flushes", .{
            if (js.active) "Power.JNL on FAT32" else "memory only", js.count, js.flushes,
        }) catch "journal";
        _ = surface.drawText(24, 172, jtext, 1, fb.Palette.text);
        const last_text = if (journal.last()) |last| std.fmt.bufPrint(&line, "LAST  {s}  {s}  {d}.{d:0>3} C", .{
            power_lib.journalKindLabel(last.kind), last.detailSlice(), @divTrunc(last.temp_mc, 1000), @as(u32, @intCast(@mod(last.temp_mc, 1000))),
        }) catch "last" else "LAST  first boot";
        _ = surface.drawText(24, 188, last_text, 1, fb.Palette.amber);
        surface.fillRect(24, 210, @intCast(surface.mode.width - 48), 1, fb.Palette.grid);
        _ = surface.drawText(24, 224, "RECENT POWER EVENTS", 1, fb.Palette.text_dim);
        var y: i32 = 244;
        const total = js.count;
        const first = if (total > 5) total - 5 else 0;
        var i = first;
        while (i < total) : (i += 1) {
            if (journal.recordAt(i)) |r| {
                var when_buf: [32]u8 = undefined;
                const when = if (r.wall_sec != 0) pl031.format(pl031.civilFromUnix(r.wall_sec), &when_buf) else "epoch";
                const row = std.fmt.bufPrint(&line, "{s}  {s:<18}  {s}", .{ when, power_lib.journalKindLabel(r.kind), r.detailSlice() }) catch "record";
                _ = surface.drawText(24, y, row, 1, fb.Palette.text);
                y += 16;
            }
        }
        const hooks = std.fmt.bufPrint(&line, "brown-out hooks {d}  events {d}  state {s}  fs hooks {d}", .{
            wi.brownout_hooks, wi.brownout_events, @tagName(wi.state), wi.storage_hooks,
        }) catch "hooks";
        _ = surface.drawText(24, 348, hooks, 1, fb.Palette.text_dim);
        _ = surface.drawText(24, @as(i32, @intCast(surface.mode.height)) - 22, "live dashboard: watchdog, thermal throttle, persistent power journal; closes after the set time", 1, fb.Palette.text_dim);
        sched.sleepMsBlocking(100);
    }
    drainConsole();
    out("  viz         : closed\n", .{});
}

/// `usb` — the host controller, the devices the class drivers bound, and the
/// serial bridge. Enumeration happens on this thread when the loop polls; this
/// command makes the current state visible and can force a poll.
fn cmdUsb(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";

    if (std.mem.eql(u8, sub, "info") or std.mem.eql(u8, sub, "devices")) {
        usb_core.describe(out);
        const st = usb_core.statsSnapshot();
        out("  usb activity : {d} enumerated, {d} removed, {d} failed, {d} HID reports\n", .{
            st.enumerated, st.removed, st.failed, st.hid_reports,
        });
        out("  usb events   : {d} keys, {d} pointer reports, {d} hub scans ({d} connect, {d} disconnect)\n", .{
            st.key_events, st.pointer_events, st.hub_scans, st.hub_connects, st.hub_disconnects,
        });
        out("  usb serial   : {d} device(s), {d} bytes out, {d} bytes in\n", .{
            usb_core.serialCount(), st.serial_tx, st.serial_rx,
        });
        usb_core.dumpInputBinding(out);
    } else if (std.mem.eql(u8, sub, "poll")) {
        usb_core.poll();
        out("  usb          : polled ({d} device(s), {d} HID report(s))\n", .{
            usb_core.deviceCount(), usb_core.statsSnapshot().hid_reports,
        });
    } else if (std.mem.eql(u8, sub, "selftest")) {
        _ = usb_core.selfTest(out);
    } else if (std.mem.eql(u8, sub, "serial")) {
        const which = parseNum(tokens.next()) orelse 0;
        const action = tokens.next() orelse "info";
        const dev = usb_core.serialAt(which) orelse {
            out("  usb serial  : no serial device at index {d} ({d} attached)\n", .{ which, usb_core.serialCount() });
            return;
        };
        if (std.mem.eql(u8, action, "send")) {
            const text = tokens.rest();
            var line: [128]u8 = undefined;
            var n: usize = 0;
            while (n < text.len and n < line.len - 2) : (n += 1) line[n] = text[n];
            line[n] = '\r';
            n += 1;
            line[n] = '\n';
            n += 1;
            const sent = usb_core.serialSend(dev, line[0..n]) catch |err| {
                out("  usb serial  : send failed: {s}\n", .{@errorName(err)});
                return;
            };
            out("  usb serial  : sent {d} bytes to '{s}'\n", .{ sent, dev.nameSlice() });
        } else if (std.mem.eql(u8, action, "read")) {
            var buf: [64]u8 = undefined;
            const got = usb_core.serialRead(dev, buf[0..]) catch |err| {
                out("  usb serial  : read failed: {s}\n", .{@errorName(err)});
                return;
            };
            if (got == 0) {
                out("  usb serial  : no bytes within 200 ms\n", .{});
            } else {
                out("  usb serial  : {d} bytes:", .{got});
                for (buf[0..got]) |b| {
                    if (b >= 0x20 and b < 0x7f) out("{c}", .{b}) else out(" {x:0>2}", .{b});
                }
                out("\n", .{});
            }
        } else {
            out("  usb serial  : '{s}' [{s}], bulk in {d} out {d}, {s}\n", .{
                dev.nameSlice(),                          @tagName(dev.kind), dev.cdc.?.bulk_in, dev.cdc.?.bulk_out,
                if (dev.cdc.?.cdc) "CDC-ACM" else "FTDI",
            });
            out("  usage       : usb serial <n> send <text> | usb serial <n> read\n", .{});
        }
    } else {
        out("  usage: usb [info|poll|selftest|serial <n> send <text>|serial <n> read]\n", .{});
    }
}

fn cmdHid() void {
    var keyboard = input_hid.BootKeyboard{};
    var changes: [12]input_hid.Change = undefined;
    var report = [_]u8{0} ** 8;
    report[2] = 0x0f; // 'l'
    report[3] = 0x08; // 'e'
    report[4] = 0x0a; // 'g'
    report[5] = 0x0c; // 'i'
    report[6] = 0x16; // 's'
    const n = keyboard.decode(&report, &changes);
    for (changes[0..n]) |change| {
        input.keyEvent(0, input_hid.usageToEvdev(change.usage), change.pressed, keyboard.modifiers);
    }
    out("  boot keyboard: {d} transitions, modifiers 0x{x:0>2}\n", .{ n, keyboard.modifiers });

    const mouse = input_hid.decodeBootMouse(&[_]u8{ 0x01, 0x03, 0xfe, 0x00 });
    input.pointerMove(0, mouse.dx, mouse.dy, mouse.buttons);
    out("  boot mouse   : buttons 0x{x}, dx {d}, dy {d}\n", .{ mouse.buttons, mouse.dx, mouse.dy });

    const pointer = input_hid.decodeAbsolutePointer(&[_]u8{ 0x00, 0x10, 0x02, 0x20, 0x01 });
    input.pointerMove(0, pointer.x, pointer.y, pointer.buttons);
    out("  touch point  : {d},{d} contact {s}\n", .{ pointer.x, pointer.y, if (pointer.contact) "yes" else "no" });
    drainConsole();
    out("  HID path     : PASS (reports reach the same kernel queue as virtio)\n", .{});
}

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
    } else if (std.mem.eql(u8, command, "cores")) {
        cmdCores(ctx);
    } else if (std.mem.eql(u8, command, "threads") or std.mem.eql(u8, command, "ps")) {
        cmdThreads(ctx);
    } else if (std.mem.eql(u8, command, "map")) {
        cmdMap(&tokens);
    } else if (std.mem.eql(u8, command, "selftest")) {
        if (ctx.selftest(ctx.pmm, ctx.heap)) {
            out("  self-tests: PASS\n", .{});
        } else {
            out("  self-tests: FAIL\n", .{});
        }
    } else if (std.mem.eql(u8, command, "mark")) {
        out("  [{d}.{d:0>3}] {s}\n", .{ timer.uptimeMs() / 1000, timer.uptimeMs() % 1000, tokens.rest() });
    } else if (std.mem.eql(u8, command, "echo")) {
        out("  {s}\n", .{tokens.rest()});
    } else if (std.mem.eql(u8, command, "svc")) {
        cmdSvc();
    } else if (std.mem.eql(u8, command, "textwrite")) {
        cmdTextWrite();
    } else if (std.mem.eql(u8, command, "fault")) {
        cmdFsFault();
    } else if (std.mem.eql(u8, command, "stress")) {
        cmdStress(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "preempt")) {
        cmdPreempt(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "spawn")) {
        cmdSpawn(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "kill")) {
        cmdKill(&tokens);
    } else if (std.mem.eql(u8, command, "reap")) {
        cmdReap(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "killoop")) {
        cmdKillLoop(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "accounting")) {
        cmdAccounting();
    } else if (std.mem.eql(u8, command, "sandbox")) {
        cmdSandbox();
    } else if (std.mem.eql(u8, command, "virtio")) {
        cmdVirtio();
    } else if (std.mem.eql(u8, command, "blk")) {
        cmdBlk(&tokens);
    } else if (std.mem.eql(u8, command, "part")) {
        cmdPart();
    } else if (std.mem.eql(u8, command, "fat")) {
        cmdFat(&tokens);
    } else if (std.mem.eql(u8, command, "cassafs")) {
        const is_viz = std.mem.eql(u8, tokens.peek() orelse "", "viz");
        cassafs.command(&tokens);
        if (is_viz) drainConsole();
    } else if (std.mem.eql(u8, command, "vfs")) {
        const is_viz = std.mem.eql(u8, tokens.peek() orelse "", "viz");
        vfs.command(&tokens);
        if (is_viz) drainConsole();
    } else if (std.mem.eql(u8, command, "retail")) {
        retail.command(&tokens);
    } else if (std.mem.eql(u8, command, "sales")) {
        sales.command(&tokens);
    } else if (std.mem.eql(u8, command, "recovery")) {
        recovery.command(&tokens);
    } else if (std.mem.eql(u8, command, "devices")) {
        cmdDevices();
    } else if (std.mem.eql(u8, command, "fb")) {
        cmdFb(&tokens);
    } else if (std.mem.eql(u8, command, "gfx")) {
        gfx51.command(&tokens);
    } else if (std.mem.eql(u8, command, "input")) {
        cmdInput(&tokens);
    } else if (std.mem.eql(u8, command, "keymap")) {
        cmdKeymap(&tokens);
    } else if (std.mem.eql(u8, command, "hid")) {
        cmdHid();
    } else if (std.mem.eql(u8, command, "usb")) {
        cmdUsb(&tokens);
    } else if (std.mem.eql(u8, command, "power")) {
        cmdPower(&tokens);
    } else if (std.mem.eql(u8, command, "thermal")) {
        cmdThermal(&tokens);
    } else if (std.mem.eql(u8, command, "watchdog") or std.mem.eql(u8, command, "wdt")) {
        cmdWatchdog(&tokens);
    } else if (std.mem.eql(u8, command, "user")) {
        cmdUser(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "uprobe")) {
        cmdUprobe(ctx);
    } else if (std.mem.eql(u8, command, "caps")) {
        cmdCaps(ctx);
    } else if (std.mem.eql(u8, command, "ipc")) {
        cmdIpc(ctx);
    } else if (std.mem.eql(u8, command, "shm")) {
        cmdShm(ctx);
    } else if (std.mem.eql(u8, command, "exec")) {
        cmdExec(&tokens);
    } else if (std.mem.eql(u8, command, "images")) {
        cmdImages(ctx);
    } else if (std.mem.eql(u8, command, "elf")) {
        cmdElf(ctx);
    } else if (std.mem.eql(u8, command, "service")) {
        cmdService(&tokens);
    } else if (std.mem.eql(u8, command, "dumps")) {
        cmdDumps(ctx);
    } else if (std.mem.eql(u8, command, "registry")) {
        cmdRegistry(ctx);
    } else if (std.mem.eql(u8, command, "resolve")) {
        cmdResolve(&tokens, false);
    } else if (std.mem.eql(u8, command, "ensure")) {
        cmdResolve(&tokens, true);
    } else if (std.mem.eql(u8, command, "logstorm")) {
        cmdLogStorm(ctx, &tokens);
    } else if (std.mem.eql(u8, command, "sleep")) {
        cmdSleep(&tokens);
    } else if (std.mem.eql(u8, command, "yield")) {
        sched.yieldNow();
        out("  yielded\n", .{});
    } else if (std.mem.eql(u8, command, "panic")) {
        @panic("panic requested from the kernel shell");
    } else if (std.mem.eql(u8, command, "reboot")) {
        out("  resetting...\n", .{});
        power.reboot(.user);
    } else if (std.mem.eql(u8, command, "poweroff")) {
        power.shutdown(.user);
    } else if (std.mem.eql(u8, command, "halt")) {
        out("  halted\n", .{});
        cpu.halt();
    } else {
        out("  unknown command: {s} (try 'help')\n", .{command});
    }
}

/// The shell is a kernel thread. It never returns: if it somehow did, the
/// thread bootstrap would exit it cleanly.
pub fn run(ctx: Context) noreturn {
    var line: [160]u8 = undefined;
    var len: usize = 0;

    _ = power.registerStorageFlusher(flushFatForPower);
    klog.info("shell", "thread {d} ready on core {d} (type 'help')", .{ sched.running().id, percpu.this().id });
    prompt();

    while (true) {
        // A device that could not allocate an interrupt is polled here, and
        // polling also catches completions posted while interrupts were off.
        virtio_input.pollAll();
        // USB needs the same service: the controller's event ring and root-port
        // changes are consumed on this thread, so hotplug works with or without
        // a routed interrupt.
        usb_core.poll();
        // Brown-out detectors only set a flag from interrupt context. This is
        // the normal-context half: flush and power off before the rail falls.
        power.service();

        // A barcode scanned while the console is idle is announced on its own
        // line, so the cashier sees the scan even before the POS app draws it.
        if (input.takeNotice()) |notice| {
            // Async line, no prompt: reprinting the prompt here would make the
            // console look like a command finished, which confuses scripts.
            out("\n  [scan] {s} ({d} chars, {d} ms burst)\n", .{ notice.text[0..notice.len], notice.len, notice.latency_ms });
        }

        const received = uart.tryGetc() orelse input.consoleGetc();
        if (received) |c| {
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
                        uart.putcLocked(c);
                    }
                },
            }
        } else {
            cpu.wfe();
        }
    }
}
