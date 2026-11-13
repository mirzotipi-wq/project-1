//! The EL0 demo program, embedded in the kernel image as a flat blob.

pub const bytes = @embedFile("user_demo");
