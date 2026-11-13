//! Trap frame layout shared by the exception stub, the syscall layer and
//! (from phase 21) user-mode entry. The layout is produced by `exceptionStub`
//! in exceptions.zig and must stay in sync with it.

pub const Frame = extern struct {
    /// x0..x30 as saved by the entry stub.
    x: [31]u64,
    /// Exception link register (return address).
    elr: u64,
    /// Saved program status.
    spsr: u64,
};

comptime {
    if (@sizeOf(Frame) != 33 * 8) @compileError("trap frame layout drifted from the assembly stub");
}
