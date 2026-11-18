//! Intel 6300ESB watchdog (phase 40).
//!
//! QEMU exposes this part as a PCI function (`8086:25ab`), and it is a real
//! watchdog model rather than a software stand-in: if the guest stops writing
//! the reload register, the device resets the machine. That is exactly the
//! recovery mechanism a till needs when the kernel stops scheduling.
//!
//! The part is simple but not friendly:
//!
//!   * BAR 0 is a 16-byte memory page. Timer preloads live at 0x00 and 0x04,
//!     the reload/status word at 0x0c.
//!   * A preload write is only accepted after the magic unlock sequence
//!     `0x80`, `0x86` is written to 0x0c. The reload bit 0x100 follows the same
//!     unlock; bit 0x200 clears the "reset was caused by the watchdog" flag.
//!   * The configuration registers are in PCI config space: 0x60 (2 bytes,
//!     reboot-on-expiry and clock scale) and 0x68 (1 byte, enable/lock). The
//!     access *size* is significant: QEMU only decodes a 2-byte write at 0x60
//!     and a 1-byte write at 0x68, so these go through ECAM byte/word stores
//!     rather than a 32-bit read/modify/write.
//!   * Two stages of 2 s each: the first is an interrupt on x86 and a no-op
//!     here, the second resets the machine. Kicking restarts stage 1.
//!
//! The scheduler kicks the device every 250 ms on core 0. A core-0 hang that
//! disables interrupts stops those kicks and the machine resets about four
//! seconds later. The reset flag is read before it is cleared, so the next boot
//! can say why it happened.

const std = @import("std");
const driver = @import("../kernel/driver.zig");
const klog = @import("../kernel/klog.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const pci = @import("../kernel/pci.zig");
const power_lib = @import("../lib/power.zig");

pub const vendor_id: u16 = 0x8086;
pub const device_id: u16 = 0x25ab;

// PCI configuration space.
const config_control: u16 = 0x60;
const config_lock: u16 = 0x68;
const config_control_value: u16 = 0x0003; // reboot on expiry, 1 kHz, timer-1 IRQ off

const lock_enable: u8 = 1 << 1;
const lock_lock: u8 = 1 << 0;

// Memory-mapped registers.
const reg_timer1: usize = 0x00;
const reg_timer2: usize = 0x04;
const reg_reload: usize = 0x0c;
const reload_kick: u16 = 1 << 8;
const reload_timeout: u16 = 1 << 9;
const reload_clear_timeout: u16 = 1 << 12;
const unlock1: u8 = 0x80;
const unlock2: u8 = 0x86;

pub const Status = struct {
    present: bool = false,
    armed: bool = false,
    locked: bool = false,
    mmio: u64 = 0,
    bar_size: u64 = 0,
    bus: u8 = 0,
    dev: u8 = 0,
    func: u8 = 0,
    timeout_ms: u32 = power_lib.watchdog_timeout_ms,
    preload: u32 = 0,
    kicks: u64 = 0,
    disarm_count: u32 = 0,
    previous_reset: bool = false,
    last_reset_was_watchdog: bool = false,
    probe_error: []const u8 = "",
};

var wdt: Status = .{};

pub fn status() *const Status {
    return &wdt;
}

pub fn present() bool {
    return wdt.present and wdt.armed;
}

pub fn previousReset() bool {
    return wdt.last_reset_was_watchdog;
}

fn reg8(base: usize, off: usize) *volatile u8 {
    return @ptrFromInt(base + off);
}

fn reg16(base: usize, off: usize) *volatile u16 {
    return @ptrFromInt(base + off);
}

fn reg32(base: usize, off: usize) *volatile u32 {
    return @ptrFromInt(base + off);
}

fn unlock(base: usize) void {
    reg8(base, reg_reload).* = unlock1;
    reg8(base, reg_reload).* = unlock2;
}

fn writePreload(base: usize, off: usize, preload: u32) void {
    unlock(base);
    reg32(base, off).* = preload & 0x000f_ffff;
}

fn configure(dev: *const driver.Device, preload: u32) bool {
    // Two-byte access, as the part decodes it. 0x0003 means reboot enabled,
    // 1 kHz clock, timer-1 interrupt disabled.
    pci.configWrite16Direct(dev.pci.bus, dev.pci.dev, dev.pci.func, config_control, config_control_value);
    _ = pci.configRead16Direct(dev.pci.bus, dev.pci.dev, dev.pci.func, config_control);

    writePreload(@intCast(wdt.mmio), reg_timer1, preload);
    writePreload(@intCast(wdt.mmio), reg_timer2, preload);

    // One-byte access; enable without setting nowayout, so a graceful shutdown
    // can disarm the part before it powers the machine off.
    pci.configWrite8Direct(dev.pci.bus, dev.pci.dev, dev.pci.func, config_lock, lock_enable);
    const lock = pci.configRead8Direct(dev.pci.bus, dev.pci.dev, dev.pci.func, config_lock);
    if (lock & lock_lock != 0) {
        wdt.locked = true;
        return false;
    }
    return lock & lock_enable != 0;
}

pub fn probe(dev: *driver.Device) driver.ProbeError!void {
    if (dev.reg_count == 0) {
        wdt.probe_error = "no BAR";
        return error.NoRegion;
    }
    const region = dev.regs[0];
    if (region.size < 0x10 or region.base == 0) {
        wdt.probe_error = "BAR 0 is not a 16-byte MMIO page";
        return error.NoRegion;
    }
    const base: usize = @intCast(region.base);
    const page = mmu.page_size;
    const map_size: usize = @intCast((region.size + page - 1) & ~(@as(u64, page) - 1));
    mmu.mapRegion(.{ .base = base, .size = map_size, .kind = .device });

    wdt.mmio = region.base;
    wdt.bar_size = region.size;
    wdt.preload = power_lib.watchdogPreload(wdt.timeout_ms);
    wdt.bus = dev.pci.bus;
    wdt.dev = dev.pci.dev;
    wdt.func = dev.pci.func;

    // Read the previous-reset flag before anything clears it. Both bit 9 (the
    // part's documented flag) and bit 12 (the bit older Linux drivers test) are
    // accepted; QEMU deliberately raises both.
    const status_word = reg16(base, reg_reload).*;
    wdt.previous_reset = (status_word & (reload_timeout | reload_clear_timeout)) != 0;
    wdt.last_reset_was_watchdog = wdt.previous_reset;

    const lock = pci.configRead8Direct(dev.pci.bus, dev.pci.dev, dev.pci.func, config_lock);
    wdt.locked = lock & lock_lock != 0;
    if (wdt.locked) {
        wdt.armed = lock & lock_enable != 0;
        wdt.probe_error = "configuration locked by firmware";
        if (wdt.armed) {
            klog.warn("wdt", "i6300ESB is locked and already armed; only reload is possible", .{});
            return;
        }
        return error.DeviceBusy;
    }

    if (!configure(dev, wdt.preload)) {
        wdt.probe_error = "enable bit did not stick";
        return error.DeviceBusy;
    }
    wdt.present = true;
    wdt.armed = true;

    // Clear the stale reset flag now that it has been recorded.
    unlock(base);
    reg16(base, reg_reload).* = reload_timeout | reload_clear_timeout;

    klog.info("wdt", "i6300ESB at BAR 0x{x}: {d} ms preload 0x{x}, two-stage reset, {d} total, {s}", .{
        wdt.mmio,                                                                                       wdt.timeout_ms, wdt.preload, wdt.timeout_ms * 2,
        if (wdt.previous_reset) "previous boot was a watchdog reset" else "no previous watchdog reset",
    });
}

/// Restart stage 1. Called from the scheduler tick on core 0, so a scheduler
/// that stops running stops the kicks with it.
pub fn kick() bool {
    if (!wdt.present or !wdt.armed) return false;
    const base: usize = @intCast(wdt.mmio);
    unlock(base);
    reg16(base, reg_reload).* = reload_kick;
    wdt.kicks += 1;
    return true;
}

/// Disarm before a planned poweroff. If firmware set nowayout the write is
/// ignored, which is reported rather than hidden; the shutdown path still
/// finishes well inside one watchdog stage.
pub fn disarm() bool {
    if (!wdt.present or !wdt.armed) return true;
    if (wdt.locked) {
        klog.warn("wdt", "watchdog is locked (nowayout); shutdown must finish before the next expiry", .{});
        return false;
    }
    pci.configWrite8Direct(wdt.bus, wdt.dev, wdt.func, config_lock, 0);
    const after = pci.configRead8Direct(wdt.bus, wdt.dev, wdt.func, config_lock);
    wdt.armed = after & lock_enable != 0;
    wdt.disarm_count += 1;
    if (!wdt.armed) {
        klog.info("wdt", "disarmed for planned shutdown after {d} kick(s)", .{wdt.kicks});
        return true;
    }
    return false;
}

pub fn kickNow() bool {
    return kick();
}

pub fn selfTest() bool {
    if (!wdt.present) {
        return wdt.probe_error.len == 0 or std.mem.eql(u8, wdt.probe_error, "no BAR");
    }
    const before = wdt.kicks;
    if (!kickNow()) return false;
    return wdt.kicks == before + 1;
}
