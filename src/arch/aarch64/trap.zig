//! Trap frame layout shared by the exception stub, the scheduler and the
//! syscall layer. The layout is produced by the generated trampolines in
//! exceptions.zig and must stay in sync with them.
//!
//! The frame holds:
//!   0..248   x0..x30
//!   248      ELR_EL1 (where `eret` resumes)
//!   256      SPSR_EL1 (PSTATE to resume with)
//!   264      padding, so the SIMD block is 16-byte aligned
//!   272..784 q0..q31 — the whole SIMD register file
//!
//! Why the whole register file and not just the callee-saved half: a context
//! switch is an *asynchronous* interruption, so every register the running code
//! could be holding a live value in must be preserved, and the AArch64 PCS
//! makes d0..d31 caller-saved. Saving only d8..d15 would be correct across a
//! function call and wrong across a preemption, which is exactly the bug that
//! would show up as rare corrupted arithmetic under load. FPCR/FPSR are *not*
//! per-thread: the kernel fixes rounding and exception modes once at boot, so
//! they are global state by design.

pub const Frame = extern struct {
    /// x0..x30 as saved by the entry stub.
    x: [31]u64,
    /// Exception link register (return address).
    elr: u64,
    /// Saved program status.
    spsr: u64,
    /// SP_EL0: the user stack pointer. Meaningful only for a thread that
    /// returns to EL0; the entry stub saves and restores it on every trap so a
    /// preempted user thread resumes with its own stack.
    sp_el0: u64 = 0,
    /// q0..q31, the full 128-bit SIMD register file.
    q: [32]u128,

    pub fn pc(self: *const Frame) usize {
        return @intCast(self.elr);
    }
};

pub const size: usize = 784;
pub const simd_offset: usize = 272;

/// PSTATE the kernel runs threads in: EL1h (M[3:0] = 0b0101) with DAIF clear,
/// so a thread can be preempted by the routine tick. Interrupts are re-masked
/// by the exception entry sequence itself.
///
/// M[3:0] = 0 is EL0t, which is what firmware hands over in SPSR_EL2 for a
/// lower-EL return; using 0 here silently drops every new thread into user mode
/// instead of the kernel.
pub const el1_thread_spsr: u64 = 0x5;

/// PSTATE for a thread that must run unprivileged: M[3:0] = 0 is EL0t, all
/// interrupts open. `eret` with this SPSR drops to user mode.
pub const el0_thread_spsr: u64 = 0x0;

comptime {
    if (@sizeOf(Frame) != size) @compileError("trap frame layout drifted from the assembly stub");
    if (@offsetOf(Frame, "q") != simd_offset) @compileError("SIMD block offset drifted");
    if (size % 16 != 0) @compileError("frame must keep the stack 16-byte aligned");
}

test "frame layout is the documented one" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 248), @offsetOf(Frame, "elr"));
    try std.testing.expectEqual(@as(usize, 256), @offsetOf(Frame, "spsr"));
    try std.testing.expectEqual(@as(usize, 272), @offsetOf(Frame, "q"));
    try std.testing.expectEqual(@as(usize, 784), @sizeOf(Frame));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(Frame));
}
