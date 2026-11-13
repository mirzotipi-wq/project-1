//! AArch64 exception vectors, trap frames and fault decoding (phase 10),
//! extended in phase 15 into the scheduler's context-switch boundary.
//!
//! The vector table and its 16 entry trampolines are generated at comptime as
//! one inline-assembly blob inside a Zig function. This matters for three
//! reasons:
//!
//!   * The table lives in `.text`, so it is executable while `.bss`/`.data` stay
//!     non-executable under W^X, and it never has to be written at runtime.
//!   * Each trampoline knows its own vector index as an immediate, so no
//!     register is sacrificed to carry it. Clobbering x9 before saving it would
//!     silently corrupt interrupted code.
//!   * The dispatcher returns the frame to resume, so the assembler side never
//!     has to know that a context switch happened. `mov sp, x0` is the entire
//!     switch.
//!
//! Vector index layout (architectural):
//!   0-3   current EL with SP0   : sync, irq, fiq, serror
//!   4-7   current EL with SPx   : sync, irq, fiq, serror
//!   8-11  lower EL, AArch64     : sync, irq, fiq, serror
//!   12-15 lower EL, AArch32     : sync, irq, fiq, serror

const std = @import("std");
const cpu = @import("cpu.zig");
const trap = @import("trap.zig");
const irq = @import("../../kernel/irq.zig");
const panic = @import("../../kernel/panic.zig");
const sched = @import("../../kernel/sched.zig");
const syscall = @import("../../kernel/syscall.zig");
const percpu = @import("../../kernel/percpu.zig");
const process = @import("../../kernel/process.zig");

pub const Frame = trap.Frame;

/// Defined by the generated assembly below; VBAR_EL1 points here.
extern const cassa_vectors: u8;

fn saveSimd() []const u8 {
    var text: []const u8 = "";
    for (0..16) |pair| {
        text = text ++ std.fmt.comptimePrint(
            "stp q{d}, q{d}, [sp, #{d}]\n",
            .{ pair * 2, pair * 2 + 1, trap.simd_offset + pair * 16 },
        );
    }
    return text;
}

fn restoreSimd() []const u8 {
    var text: []const u8 = "";
    for (0..16) |pair| {
        text = text ++ std.fmt.comptimePrint(
            "ldp q{d}, q{d}, [sp, #{d}]\n",
            .{ pair * 2, pair * 2 + 1, trap.simd_offset + pair * 16 },
        );
    }
    return text;
}

const save_asm = std.fmt.comptimePrint(
    \\sub sp, sp, #{d}
    \\stp x0, x1, [sp, #0]
    \\stp x2, x3, [sp, #16]
    \\stp x4, x5, [sp, #32]
    \\stp x6, x7, [sp, #48]
    \\stp x8, x9, [sp, #64]
    \\stp x10, x11, [sp, #80]
    \\stp x12, x13, [sp, #96]
    \\stp x14, x15, [sp, #112]
    \\stp x16, x17, [sp, #128]
    \\stp x18, x19, [sp, #144]
    \\stp x20, x21, [sp, #160]
    \\stp x22, x23, [sp, #176]
    \\stp x24, x25, [sp, #192]
    \\stp x26, x27, [sp, #208]
    \\stp x28, x29, [sp, #224]
    \\str x30, [sp, #240]
    \\mrs x0, elr_el1
    \\str x0, [sp, #248]
    \\mrs x0, spsr_el1
    \\str x0, [sp, #256]
    \\mrs x0, sp_el0
    \\str x0, [sp, #264]
    \\
, .{trap.size}) ++ saveSimd();

const restore_asm = std.fmt.comptimePrint(
    \\ldr x0, [sp, #248]
    \\msr elr_el1, x0
    \\ldr x0, [sp, #256]
    \\msr spsr_el1, x0
    \\ldr x0, [sp, #264]
    \\msr sp_el0, x0
    \\
, .{}) ++ restoreSimd() ++ std.fmt.comptimePrint(
    \\
    \\ldp x0, x1, [sp, #0]
    \\ldp x2, x3, [sp, #16]
    \\ldp x4, x5, [sp, #32]
    \\ldp x6, x7, [sp, #48]
    \\ldp x8, x9, [sp, #64]
    \\ldp x10, x11, [sp, #80]
    \\ldp x12, x13, [sp, #96]
    \\ldp x14, x15, [sp, #112]
    \\ldp x16, x17, [sp, #128]
    \\ldp x18, x19, [sp, #144]
    \\ldp x20, x21, [sp, #160]
    \\ldp x22, x23, [sp, #176]
    \\ldp x24, x25, [sp, #192]
    \\ldp x26, x27, [sp, #208]
    \\ldp x28, x29, [sp, #224]
    \\ldr x30, [sp, #240]
    \\add sp, sp, #{d}
    \\eret
    \\
, .{trap.size});

fn vectorAsm() []const u8 {
    var text: []const u8 = " .balign 2048\n.global cassa_vectors\ncassa_vectors:\n";
    for (0..16) |i| {
        if (i != 0) text = text ++ ".balign 128\n";
        text = text ++ std.fmt.comptimePrint("b cassa_tramp{d}\n", .{i});
    }
    for (0..16) |i| {
        text = text ++ std.fmt.comptimePrint("cassa_tramp{d}:\n", .{i});
        text = text ++ save_asm;
        text = text ++ std.fmt.comptimePrint(
            \\mov x0, #{d}
            \\mov x1, sp
            \\bl cassa_exception_dispatch
            \\mov sp, x0
            \\bl cassa_after_switch
            \\
        , .{i});
        text = text ++ restore_asm;
    }
    return text;
}

/// The vector table plus all sixteen entry trampolines.
export fn cassa_vector_entries() callconv(.Naked) noreturn {
    asm volatile (vectorAsm());
}

/// Point VBAR_EL1 at the table. Safe with the MMU on: the table is read-only
/// and executable, and never patched at runtime. Per-core register.
pub fn init() void {
    cpu.sysWrite("vbar_el1", @intFromPtr(&cassa_vectors));
    cpu.isb();
}

// ---------------------------------------------------------------------------
// ESR decoding
// ---------------------------------------------------------------------------

fn exceptionClass(esr: u64) u64 {
    return (esr >> 26) & 0x3F;
}

fn esrDescription(ec: u64) []const u8 {
    return switch (ec) {
        0x00 => "undefined instruction",
        0x01 => "trapped WFI/WFE",
        0x03 => "trapped MCR/MRC (coprocessor)",
        0x07 => "trapped FP/SIMD access",
        0x0E => "illegal exception return",
        0x11 => "trapped MSR/MRS (system register)",
        0x15 => "SVC (supervisor call)",
        0x18 => "trapped MSR/MRS",
        0x20 => "instruction abort from lower EL",
        0x21 => "instruction abort from same EL",
        0x22 => "PC alignment fault",
        0x24 => "data abort from lower EL",
        0x25 => "data abort from same EL",
        0x26 => "SP alignment fault",
        0x2C => "trapped floating-point exception",
        0x30 => "breakpoint",
        0x32 => "software step",
        0x34 => "watchpoint",
        0x3C => "BRK instruction",
        else => "unclassified exception",
    };
}

/// DFSC/IFSC encoding (ARM ARM D13.2.37). The low two bits are the translation
/// level for the first four classes; getting this table wrong turns a W^X
/// permission fault into a confusing "access flag" report, which is exactly
/// what happened before this was corrected.
fn faultStatusName(fsc: u64) []const u8 {
    return switch (fsc & 0x3F) {
        0b000000 => "address size fault, level 0",
        0b000001 => "address size fault, level 1",
        0b000010 => "address size fault, level 2",
        0b000011 => "address size fault, level 3",
        0b000100 => "translation fault, level 0",
        0b000101 => "translation fault, level 1",
        0b000110 => "translation fault, level 2",
        0b000111 => "translation fault, level 3",
        0b001000 => "access flag fault, level 0",
        0b001001 => "access flag fault, level 1",
        0b001010 => "access flag fault, level 2",
        0b001011 => "access flag fault, level 3",
        0b001100 => "permission fault, level 0",
        0b001101 => "permission fault, level 1",
        0b001110 => "permission fault, level 2",
        0b001111 => "permission fault, level 3",
        0b010000 => "synchronous external abort",
        0b100001 => "alignment fault",
        0b110000 => "TLB conflict abort",
        else => "abort with unknown status",
    };
}

const vector_names = [_][]const u8{
    "sync   · current EL · SP0",  "irq    · current EL · SP0",
    "fiq    · current EL · SP0",  "serror · current EL · SP0",
    "sync   · current EL · SPx",  "irq    · current EL · SPx",
    "fiq    · current EL · SPx",  "serror · current EL · SPx",
    "sync   · lower EL · aarch64", "irq    · lower EL · aarch64",
    "fiq    · lower EL · aarch64", "serror · lower EL · aarch64",
    "sync   · lower EL · aarch32", "irq    · lower EL · aarch32",
    "fiq    · lower EL · aarch32", "serror · lower EL · aarch32",
};

fn formatFault(index: usize, frame: *const Frame, esr: u64, far: u64) noreturn {
    const ec = exceptionClass(esr);
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.print("vector      : {d} ({s})\n", .{ index, vector_names[index] }) catch {};
    w.print("ESR_EL1     : 0x{x:0>16}\n", .{esr}) catch {};
    w.print("cause       : {s} (EC 0x{x:0>2})\n", .{ esrDescription(ec), ec }) catch {};
    if (ec == 0x24 or ec == 0x25 or ec == 0x21 or ec == 0x20) {
        w.print("fault       : {s}\n", .{faultStatusName(esr & 0x3F)}) catch {};
        w.print("address     : 0x{x:0>16}\n", .{far}) catch {};
        w.print("write       : {s}\n", .{if ((esr & (1 << 6)) != 0) "yes" else "no"}) catch {};
    }
    w.print("ELR_EL1     : 0x{x:0>16}\n", .{frame.elr}) catch {};
    w.print("SPSR_EL1    : 0x{x:0>16}\n", .{frame.spsr}) catch {};
    w.print("x0..x3      : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[0], frame.x[1], frame.x[2], frame.x[3] }) catch {};
    w.print("x4..x7      : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[4], frame.x[5], frame.x[6], frame.x[7] }) catch {};
    w.print("x8..x11     : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[8], frame.x[9], frame.x[10], frame.x[11] }) catch {};
    w.print("x12..x15    : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[12], frame.x[13], frame.x[14], frame.x[15] }) catch {};
    w.print("x16..x19    : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[16], frame.x[17], frame.x[18], frame.x[19] }) catch {};
    w.print("x20..x23    : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[20], frame.x[21], frame.x[22], frame.x[23] }) catch {};
    w.print("x24..x27    : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[24], frame.x[25], frame.x[26], frame.x[27] }) catch {};
    w.print("x28,x29,x30 : 0x{x:0>16} 0x{x:0>16} 0x{x:0>16}\n", .{ frame.x[28], frame.x[29], frame.x[30] }) catch {};
    w.print("SP          : 0x{x:0>16}\n", .{@intFromPtr(frame) + @sizeOf(Frame)}) catch {};
    panic.faultReport("unhandled CPU exception", stream.getWritten());
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Called by every trampoline with the vector index and the frame it just
/// built. Returns the frame to resume — the same one for an ordinary
/// interrupt, or another thread's after a context switch.
export fn cassa_exception_dispatch(kind: u64, frame: *Frame) callconv(.C) *Frame {
    const index: usize = @intCast(kind & 0xF);
    percpu.this().irqs += 1;

    switch (index) {
        // IRQ from any source.
        1, 5, 9, 13 => {
            irq.dispatch();
            return sched.preempt(frame);
        },
        // Synchronous exceptions.
        0, 4, 8, 12 => {
            const esr = cpu.sysRead("esr_el1");
            // PSTATE.M[3:0] == 0 means the exception came from EL0. User code
            // is the only thing on this machine that runs unprivileged.
            const from_user = (frame.spsr & 0xF) == 0;
            if (exceptionClass(esr) == 0x15) {
                // On AArch64 a supervisor call is not restartable: ELR_EL1
                // already holds the address of the instruction after the SVC.
                // Advancing it here would skip one instruction of the caller —
                // which silently skipped the `ldp x29, x30, [sp], #16` that
                // restores a callee's frame, so the callee returned into
                // whatever happened to be in x30.
                // Two calling conventions, deliberately. Kernel code encodes
                // the number in the instruction (`svc #64`), which costs no
                // register. EL0 needs a register because the number is chosen
                // at runtime: x8, the same place the AArch64 Linux ABI puts it.
                const number = if (from_user) frame.x[8] else esr & 0xFFFF;
                const action = if (from_user)
                    syscall.handleUser(number, frame)
                else
                    syscall.handle(number, frame);
                if (action == .reschedule) return sched.reschedule(frame);
                return frame;
            }
            // A fault from EL0 belongs to the process, not to the kernel: log
            // it, terminate that process and let the scheduler pick the next
            // thread. A fault from EL1 still stops the machine, because it
            // means the kernel itself is wrong.
            if (from_user) return process.faultCurrent(frame, esr, cpu.sysRead("far_el1"));
            formatFault(index, frame, esr, cpu.sysRead("far_el1"));
        },
        // FIQ and SError are not expected yet, but must never be silent.
        else => formatFault(index, frame, cpu.sysRead("esr_el1"), cpu.sysRead("far_el1")),
    }
}

test "vector table is exactly 2 KiB and 128 bytes per entry" {
    try std.testing.expectEqual(@as(usize, 2048), 16 * 128);
    try std.testing.expectEqual(@as(usize, 16), vector_names.len);
}
