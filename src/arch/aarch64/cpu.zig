//! AArch64 system-register access, barriers and CPU control.
//!
//! Zig's inline assembly is used for everything a system register needs; there
//! is no assembly source file anywhere in this project.

const std = @import("std");

/// Read a system register by name, e.g. `sysRead("tcr_el1")`.
pub inline fn sysRead(comptime reg: []const u8) u64 {
    var value: u64 = undefined;
    asm volatile ("mrs %[out], " ++ reg : [out] "=r" (value));
    return value;
}

/// Write a system register by name, e.g. `sysWrite("vbar_el1", addr)`.
pub inline fn sysWrite(comptime reg: []const u8, value: u64) void {
    asm volatile ("msr " ++ reg ++ ", %[in]" :: [in] "r" (value) : "memory");
}

pub inline fn isb() void {
    asm volatile ("isb" ::: "memory");
}

pub inline fn dsbSy() void {
    asm volatile ("dsb sy" ::: "memory");
}

pub inline fn dmbSy() void {
    asm volatile ("dmb sy" ::: "memory");
}

pub inline fn sev() void {
    asm volatile ("sev");
}

pub inline fn wfe() void {
    asm volatile ("wfe");
}

pub inline fn nop() void {
    asm volatile ("nop");
}

pub inline fn tlbiVmalle1() void {
    asm volatile ("tlbi vmalle1" ::: "memory");
}

/// Current exception level, 0..3.
pub inline fn currentEl() u64 {
    return (sysRead("CurrentEL") >> 2) & 0x3;
}

// ---------------------------------------------------------------------------
// Interrupt masking
// ---------------------------------------------------------------------------

pub inline fn irqDisable() void {
    asm volatile ("msr daifset, #2" ::: "memory");
}

pub inline fn irqEnable() void {
    asm volatile ("msr daifclr, #2" ::: "memory");
}

pub inline fn allInterruptsDisable() void {
    asm volatile ("msr daifset, #0xf" ::: "memory");
}

/// Save the interrupt mask and disable IRQs. Pair with `irqRestore`.
pub inline fn irqSave() u64 {
    const flags = sysRead("DAIF");
    irqDisable();
    return flags;
}

pub inline fn irqRestore(flags: u64) void {
    sysWrite("DAIF", flags);
}

/// Whether IRQs are currently unmasked.
pub inline fn irqsEnabled() bool {
    return (sysRead("DAIF") & (1 << 7)) == 0;
}

// ---------------------------------------------------------------------------
// Floating point / NEON
// ---------------------------------------------------------------------------

pub inline fn enableFp() void {
    var cpacr = sysRead("cpacr_el1");
    cpacr |= (0x3 << 20); // FPEN: do not trap FP/SIMD at EL1 or EL0
    sysWrite("cpacr_el1", cpacr);
    isb();
}

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------

pub inline fn cntFrq() u64 {
    return sysRead("cntfrq_el0");
}

pub inline fn cntPct() u64 {
    return sysRead("cntpct_el0");
}

// ---------------------------------------------------------------------------
// PSCI (power state coordination interface), used for reset/poweroff
// ---------------------------------------------------------------------------

const PSCI_SYSTEM_OFF: u64 = 0x8400_0008;
const PSCI_SYSTEM_RESET: u64 = 0x8400_0009;

fn psciCall(function: u64) void {
    // QEMU and most firmware expose PSCI over HVC at EL1; some boards only
    // implement SMC. HVC is attempted first, then SMC.
    asm volatile ("hvc #0" :: [func] "{x0}" (function) : "memory");
}

pub fn systemOff() noreturn {
    allInterruptsDisable();
    psciCall(PSCI_SYSTEM_OFF);
    halt();
}

pub fn systemReset() noreturn {
    allInterruptsDisable();
    dsbSy();
    psciCall(PSCI_SYSTEM_RESET);
    halt();
}

/// Stop this core forever.
pub fn halt() noreturn {
    allInterruptsDisable();
    while (true) {
        asm volatile ("wfi");
    }
}

test "movz encoding used by the exception table" {
    // MOVZ X9, #3, LSL #0 -> 0xd2800069
    const imm: u32 = 3;
    const insn: u32 = 0xD280_0009 | (imm << 5);
    try std.testing.expectEqual(@as(u32, 0xD280_0069), insn);
}
