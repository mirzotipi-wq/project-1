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
const user_space = @import("addrspace.zig");
const cap = @import("cap.zig");
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
    for (0..workers) |i| {
        // Pinned to this core: the workers cannot migrate, so progress on all
        // three can only come from being preempted.
        if (sched.spawnPinned("spin", spinWorker, @ptrFromInt(i + 1))) |id| {
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
                i, seg.vaddr, seg.memsz,
                if (seg.read) "r" else "-",
                if (seg.write) "w" else "-",
                if (seg.exec) "x" else "-",
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
                s.name, service.stateLabel(s.state), s.pid, s.restarts, s.failures,
                s.policy.max_restarts, s.policy.base_ms, last,
            });
        }
        out("  {d} registered, {d} starts, {d} restarts, {d} failures, {d} crash loops, {d} reaps\n", .{
            service.count(), service.starts, service.restarts_total, service.failures_total,
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
fn cmdUprobe(ctx: Context) void {
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
        own_pid, peer_pid, str_pid,
        @tagName(s_own), @tagName(s_peer), @tagName(s_str),
        c_own, c_peer, c_str, status(procs_ok),
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
    pass = pass and shm_ok;

    out("  [12] ELF loading: a separate program launched from the image store\n", .{});
    const refusals = elfRefusals();
    out("      refuses bad magic {s}, writable+executable {s}, bad entry {s}, truncated {s}\n", .{
        status(refusals.bad_magic), status(refusals.write_exec),
        status(refusals.entry), status(refusals.truncated),
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
    pass = pass and loader_ok and exec_ok and refused_ok;

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
    pass = pass and ok1;

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
    pass = pass and ok2;

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
    pass = pass and ok3;

    // 4 -- a syscall pointer outside the process is refused, not followed.
    out("  [4] syscall pointers outside the process\n", .{});
    const rejected = syscall.rejected_ptr - rejected_before;
    const ok4 = rejected >= 2;
    out("      kernel refused {d} pointer(s) (kernel text + unmapped)  {s}\n", .{ rejected, status(ok4) });
    pass = pass and ok4;

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
    pass = pass and ok5;

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
    pass = pass and ok6;

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
    pass = pass and ok7;

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
    pass = pass and ok8;

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
    pass = pass and parked_ok;

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
        srv_pid, cli_pid, out_pid,
        @tagName(s_cli), @tagName(s_out), @tagName(s_srv),
        c_srv, c_cli, c_out, status(ipc_ok),
    });
    out("      ipc: {d} sent, {d} received, {d} replied, {d} timeouts, {d} full, {d} transfers, {d} transfer failures\n", .{
        ipc.sends, ipc.receives, ipc.replies, ipc.timeouts, ipc.full_events, ipc.transfers, ipc.transfer_failures,
    });
    pass = pass and ipc_ok;

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
            killed, printer.restarts, delays[0], delays[1], delays[2], delays[3], delays[4], delays[5],
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
        sched.sleepMsBlocking(50);
        const live_after = process.liveCount();
        const spaces_after = user_space.liveCount();
        const orphan_ok = live_after == live_before and spaces_after == spaces_before and
            service.find("checkout").?.state == .stopped;
        out("      stop: services {s}, live processes {d} -> {d}, spaces {d} -> {d}  {s}\n", .{
            service.stateLabel(service.find("checkout").?.state),
            live_before, live_after, spaces_before, spaces_after, status(orphan_ok),
        });
        lc_ok = lc_ok and orphan_ok;
        out("      services: {d} starts, {d} restarts, {d} failures, {d} crash loops, {d} dumps, {d} reaps\n", .{
            service.starts, service.restarts_total, service.failures_total,
            service.crash_loops, dump.total, service.reaps,
        });
    }
    pass = pass and lc_ok;

    out("  ------------------------------------------------------------------\n", .{});
    out("  user syscalls: {d}, processes spawned: {d}, faults caught: {d}\n", .{
        syscall.user_calls, process.spawns, process.kills,
    });
    out("  RESULT: {s}\n", .{if (pass) "PASS" else "FAIL"});
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
        cpu.systemReset();
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

    klog.info("shell", "thread {d} ready on core {d} (type 'help')", .{ sched.running().id, percpu.this().id });
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
                        uart.putcLocked(c);
                    }
                },
            }
        } else {
            cpu.wfe();
        }
    }
}
