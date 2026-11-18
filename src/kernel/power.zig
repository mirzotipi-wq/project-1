//! Power management and recovery (phase 40).
//!
//! Coordinates the four pieces this phase promises:
//!
//!   * the i6300ESB hardware watchdog, kicked from the scheduler tick on core 0;
//!   * brown-out detection hooks for a board's PMIC/GPIO driver, with an
//!     emergency flush before the rail collapses;
//!   * thermal throttling, driven by `kernel/thermal.zig` and applied by the
//!     scheduler as idle ticks;
//!   * graceful poweroff/reboot that first syncs the mounted filesystem, writes
//!     one final journal record and flushes the device.
//!
//! A brown-out hook is deliberately not allowed to do I/O from interrupt
//! context: the detector raises a pending flag, and the shell's normal loop
//! calls `service()` at the first opportunity. The hardware watchdog is the
//! backstop if the loop itself is wedged. A planned shutdown disarms the
//! watchdog before touching storage, because a watchdog expiry in the middle of
//! a flush would be a worse outcome than the shutdown taking another second.

const std = @import("std");
const klog = @import("klog.zig");
const timer = @import("../arch/aarch64/timer.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const block = @import("block.zig");
const thermal = @import("thermal.zig");
const journal = @import("journal.zig");
const wdt = @import("../devices/i6300esb.zig");
const pl011 = @import("../devices/pl011.zig");
const power_lib = @import("../lib/power.zig");

pub const Reason = enum { user, brownout, thermal, maintenance, reboot };
pub const State = enum { running, shutting_down, halted };

pub const Info = struct {
    state: State = .running,
    boot_clean: bool = false,
    had_history: bool = false,
    watchdog_reset: bool = false,
    kicks: u64 = 0,
    brownout_events: u32 = 0,
    brownout_hooks: u32 = 0,
    brownout_hook_runs: u32 = 0,
    storage_hooks: u32 = 0,
    test_hang: bool = false,
};

var state: State = .running;
var info: Info = .{};
var last_kick_ms: u64 = 0;
var brownout_pending: bool = false;
var test_hang: bool = false;

var storage_flushers: [4]*const fn () void = undefined;
var storage_flusher_count: u32 = 0;

var brownout_hooks: [4]*const fn () void = undefined;
var brownout_hook_count: u32 = 0;
var brownout_hook_runs: u32 = 0;

fn onBrownoutHook() void {
    // The built-in hook is intentionally tiny: it is the place a board driver
    // would cut non-essential rails or park motors. The actual data flush is
    // ordered by `shutdown`, not by this hook.
    brownout_hook_runs += 1;
}

pub fn init() void {
    info = .{};
    state = .running;
    brownout_pending = false;
    test_hang = false;
    last_kick_ms = timer.uptimeMs();

    _ = registerBrownoutHook(onBrownoutHook);

    thermal.init();
    journal.init();

    info.had_history = journal.hasPrevious();
    info.boot_clean = journal.previousClean();
    info.watchdog_reset = wdt.previousReset();
    info.brownout_hooks = brownout_hook_count;
    info.storage_hooks = storage_flusher_count;

    journal.boot(info.watchdog_reset, thermal.temperatureMc(), thermal.throttlePercent());

    klog.info("power", "PSCI off/reset ready, watchdog {s}, journal {s}", .{
        if (wdt.present()) "armed" else "absent (graceful fallback)",
        journal.snapshot().reason,
    });
    if (info.watchdog_reset) {
        klog.warn("power", "previous boot ended in a hardware watchdog reset; journal history is {s}", .{
            if (info.boot_clean) "clean (stale flag?)" else "unclean",
        });
    } else if (info.had_history) {
        klog.info("power", "previous shutdown: {s}", .{if (info.boot_clean) "clean" else "unclean"});
    }
    klog.info("power", "brownout hooks {d}, storage flush hooks {d}, thermal {s}", .{
        info.brownout_hooks, info.storage_hooks, thermal.stats().sensor_name,
    });
}

pub fn snapshot() Info {
    var out = info;
    out.state = state;
    out.kicks = wdt.status().kicks;
    out.brownout_events = info.brownout_events;
    out.brownout_hooks = brownout_hook_count;
    out.brownout_hook_runs = brownout_hook_runs;
    out.storage_hooks = storage_flusher_count;
    out.test_hang = @atomicLoad(bool, &test_hang, .acquire);
    return out;
}

pub fn currentState() State {
    return state;
}

pub fn registerStorageFlusher(flush_fn: *const fn () void) bool {
    if (storage_flusher_count >= storage_flushers.len) return false;
    storage_flushers[storage_flusher_count] = flush_fn;
    storage_flusher_count += 1;
    info.storage_hooks = storage_flusher_count;
    return true;
}

pub fn registerBrownoutHook(hook: *const fn () void) bool {
    if (brownout_hook_count >= brownout_hooks.len) return false;
    brownout_hooks[brownout_hook_count] = hook;
    brownout_hook_count += 1;
    info.brownout_hooks = brownout_hook_count;
    return true;
}

/// The detector side of a brown-out: safe for an interrupt handler. It only
/// publishes the event; `service()` performs the shutdown on the shell thread.
pub fn signalBrownout() void {
    if (@atomicLoad(bool, &brownout_pending, .acquire)) return;
    @atomicStore(bool, &brownout_pending, true, .release);
    _ = @atomicRmw(u32, &info.brownout_events, .Add, 1, .monotonic);
}

pub fn brownoutPending() bool {
    return @atomicLoad(bool, &brownout_pending, .acquire);
}

/// Called by the shell loop. This is the normal-context half of the brown-out
/// hook: flush and power off immediately instead of waiting for the watchdog.
pub fn service() void {
    if (brownoutPending() and state == .running) {
        klog.warn("power", "brown-out pending: emergency flush and shutdown", .{});
        shutdown(.brownout);
    }
}

/// Scheduler heartbeat. Core 0 alone owns the watchdog, so a hang on the shell
/// core stops the kicks even while the other cores continue to tick. The
/// `test_hang` flag lets the shell's deliberate fault suppress every heartbeat
/// without needing a cross-core NMI.
pub fn tick(core: u32) void {
    if (core != 0) return;
    if (@atomicLoad(bool, &test_hang, .acquire)) return;
    const now = timer.uptimeMs();
    if (power_lib.watchdogKickDue(now, last_kick_ms)) {
        if (wdt.kick()) {
            last_kick_ms = now;
            info.kicks += 1;
        }
    }
}

fn runStorageFlushers() u32 {
    var ran: u32 = 0;
    var i: u32 = 0;
    while (i < storage_flusher_count) : (i += 1) {
        storage_flushers[i]();
        ran += 1;
    }
    return ran;
}

fn runBrownoutHooks() u32 {
    var ran: u32 = 0;
    var i: u32 = 0;
    while (i < brownout_hook_count) : (i += 1) {
        brownout_hooks[i]();
        ran += 1;
    }
    return ran;
}

fn journalKind(reason: Reason) power_lib.JournalKind {
    return switch (reason) {
        .user => .clean_shutdown,
        .reboot => .reboot,
        .brownout => .brownout,
        .thermal => .thermal,
        // A manual `power flush` is not a shutdown. Recording it as one would
        // make a later watchdog reset look clean on the next boot.
        .maintenance => .power_event,
    };
}

fn reasonText(reason: Reason) []const u8 {
    return switch (reason) {
        .user => "poweroff",
        .brownout => "brownout",
        .thermal => "thermal",
        .maintenance => "maintenance",
        .reboot => "reboot",
    };
}

/// Flush everything the power path can flush. The shell uses this directly as
/// `power flush`; shutdown uses the same code, so the tested path and the
/// emergency path cannot drift.
pub fn flushNow(reason: Reason, detail: []const u8) bool {
    const filesystems = runStorageFlushers();
    journal.append(journalKind(reason), detail, thermal.temperatureMc(), thermal.throttlePercent());
    const journal_ok = journal.flush();
    var block_ok = true;
    if (block.present()) {
        block.backend.?.flush() catch {
            block_ok = false;
        };
    }
    pl011.flush();
    const ok = journal_ok and block_ok;
    klog.info("power", "flush {s}: {d} filesystem(s), journal {s}, device {s}", .{
        reasonText(reason),                          filesystems,
        if (journal_ok) "synced" else "unavailable", if (block_ok) "synced" else "error",
    });
    return ok;
}

pub fn shutdown(reason: Reason) noreturn {
    if (state == .shutting_down or state == .halted) {
        cpu.halt();
    }
    state = .shutting_down;
    if (reason == .brownout) {
        // Hooks are the board's chance to quiesce before the rail goes away.
        const ran = runBrownoutHooks();
        klog.warn("power", "brown-out shutdown: {d} hook(s) ran", .{ran});
    }
    const disarmed = wdt.disarm();
    klog.info("power", "shutdown ({s}): watchdog {s}, syncing storage", .{
        reasonText(reason), if (disarmed) "disarmed" else "still armed",
    });
    _ = flushNow(reason, reasonText(reason));
    klog.info("power", "clean shutdown complete; PSCI SYSTEM_OFF", .{});
    pl011.flush();
    cpu.systemOff();
}

pub fn reboot(reason: Reason) noreturn {
    if (state == .shutting_down or state == .halted) {
        cpu.halt();
    }
    state = .shutting_down;
    const disarmed = wdt.disarm();
    klog.info("power", "reboot ({s}): watchdog {s}, syncing storage", .{
        reasonText(reason), if (disarmed) "disarmed" else "still armed",
    });
    _ = flushNow(.reboot, "reboot");
    pl011.flush();
    cpu.systemReset();
}

/// Deliberate hang used by the phase 40 harness. Setting the flag suppresses
/// the heartbeat on every core, and disabling this core's interrupts means the
/// shell cannot accidentally service the watchdog before the reset.
pub fn forceHang() noreturn {
    @atomicStore(bool, &test_hang, true, .release);
    klog.warn("power", "fault injection: scheduler heartbeats suppressed; watchdog should reset in {d} ms", .{
        wdt.status().timeout_ms * 2,
    });
    pl011.flush();
    cpu.allInterruptsDisable();
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn forceHangForTest() bool {
    return @atomicLoad(bool, &test_hang, .acquire);
}

/// `power selftest` — the parts that do not require powering the machine off.
/// A missing watchdog or journal is a supported degraded configuration, so it
/// is reported as such and does not fail the test.
pub fn selfTest(write: anytype) bool {
    var ok = true;
    const wi = snapshot();
    write("      watchdog: {s}, {d} kick(s), {d} ms timeout  {s}\n", .{
        if (wdt.present()) "armed i6300ESB" else "absent (graceful fallback)",
        wi.kicks,
        wdt.status().timeout_ms,
        if (wdt.present()) "OK" else "OK (degraded)",
    });
    if (wdt.present()) {
        const tested = wdt.selfTest();
        if (!tested) ok = false;
        write("      reload: one explicit kick accepted  {s}\n", .{if (tested) "OK" else "FAIL"});
    }

    const js = journal.snapshot();
    write("      journal: {s}, {d} record(s), {d} flush(es)  {s}\n", .{
        js.reason,                                                                     js.count, js.flushes,
        if (!js.active) "OK (degraded)" else if (journal.selfTest()) "OK" else "FAIL",
    });
    if (js.active) {
        const js_after = journal.snapshot();
        if (js_after.last_error.len != 0) ok = false;
    }

    const thermal_ok = thermal.selfTest(write);
    write("      thermal: {s}\n", .{if (thermal_ok) "OK" else "FAIL"});
    if (!thermal_ok) ok = false;

    write("      brownout: {d} hook(s), {d} event(s), pending {s}  {s}\n", .{
        wi.brownout_hooks,                           wi.brownout_events, if (brownout_pending) "yes" else "no",
        if (wi.brownout_hooks > 0) "OK" else "FAIL",
    });
    if (wi.brownout_hooks == 0) ok = false;
    return ok;
}
