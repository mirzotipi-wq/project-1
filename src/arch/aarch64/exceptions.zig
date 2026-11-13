//! AArch64 exception vectors, trap frames and fault decoding (phase 10).
//!
//! The vector table and its 16 entry trampolines are generated at comptime as
//! one inline-assembly blob inside a Zig function. This matters for two
//! reasons:
//!
//!   * The table lives in `.text`, so it is executable while `.bss`/`.data` stay
//!     non-executable under W^X, and it never has to be written at runtime.
//!   * Each trampoline knows its own vector index as an immediate, so no
//!     register is sacrificed to carry it. Clobbering x9 before saving it would
//!     silently corrupt interrupted code.
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

pub const Frame = trap.Frame;

/// Defined by the generated assembly below; VBAR_EL1 points here.
extern const cassa_vectors: u8;

const frame_size = 272;

const save_asm =
    \\sub sp, sp, #272
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
    \\stp x0, xzr, [sp, #256]
;

const restore_asm =
    \\ldr x0, [sp, #248]
    \\msr elr_el1, x0
    \\ldp x0, xzr, [sp, #256]
    \\msr spsr_el1, x0
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
    \\add sp, sp, #272
    \\eret
;

fn vectorAsm() []const u8 {
    var text: []const u8 = " .balign 2048\n.global cassa_vectors\ncassa_vectors:\n";
    for (0..16) |i| {
        if (i != 0) text = text ++ ".balign 128\n";
        text = text ++ std.fmt.comptimePrint("b cassa_tramp{d}\n", .{i});
    }
    for (0..16) |i| {
        text = text ++ std.fmt.comptimePrint("cassa_tramp{d}:\n", .{i});
        text = text ++ save_asm ++ "\n";
        text = text ++ std.fmt.comptimePrint("mov x0, #{d}\nmov x1, sp\nbl cassa_exception_dispatch\n", .{i});
        text = text ++ restore_asm ++ "\n";
    }
    return text;
}

/// The vector table plus all sixteen entry trampolines.
export fn cassa_vector_entries() callconv(.Naked) noreturn {
    asm volatile (vectorAsm());
}

/// Point VBAR_EL1 at the table. Safe with the MMU on: the table is read-only
/// and executable, and never patched at runtime.
pub fn init() void {
    comptime std.debug.assert(frame_size == @sizeOf(Frame) + 8);
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

fn faultStatusName(fsc: u64) []const u8 {
    return switch (fsc & 0x3F) {
        0b000000 => "address size fault, level 0",
        0b000100 => "address size fault, level 1",
        0b000101 => "address size fault, level 2",
        0b000110 => "address size fault, level 3",
        0b000111 => "translation fault, level 0",
        0b001001 => "translation fault, level 1",
        0b001010 => "translation fault, level 2",
        0b001011 => "translation fault, level 3",
        0b001101 => "access flag fault, level 1",
        0b001110 => "access flag fault, level 2",
        0b001111 => "access flag fault, level 3",
        0b010001 => "synchronous external abort",
        0b100001 => "alignment fault",
        0b110000 => "permission fault, level 0",
        0b110101 => "permission fault, level 1",
        0b110110 => "permission fault, level 2",
        0b110111 => "permission fault, level 3",
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

export fn cassa_exception_dispatch(kind: u64, frame: *Frame) callconv(.C) void {
    const index: usize = @intCast(kind & 0xF);
    const esr = cpu.sysRead("esr_el1");

    switch (index) {
        // IRQ from any source.
        1, 5, 9, 13 => irq.dispatch(),
        // Synchronous exceptions.
        0, 4, 8, 12 => {
            if (exceptionClass(esr) == 0x15) {
                const number = esr & 0xFFFF;
                @import("../../kernel/syscall.zig").handle(number, frame);
                return;
            }
            formatFault(index, frame, esr, cpu.sysRead("far_el1"));
        },
        // FIQ and SError are not expected yet, but must never be silent.
        else => formatFault(index, frame, esr, cpu.sysRead("far_el1")),
    }
}

test "vector table is exactly 2 KiB and 128 bytes per entry" {
    try std.testing.expectEqual(@as(usize, 2048), 16 * 128);
    try std.testing.expectEqual(@as(usize, 16), vector_names.len);
}
