//! Read-only image store (phase 26).
//!
//! The smallest honest thing that lets the shell launch a program by name: a
//! table of named files whose bytes are embedded in the kernel image at build
//! time. Phase 26 needs the *loader* to work against real file bytes, not a
//! blob with a fixed entry; the store is what a filesystem will replace, and
//! every lookup here is the same call that will later go through a VFS.
//!
//! `pos.elf` is built by `zig build` as its own executable and embedded as-is,
//! so the kernel parses a real ELF64 file at runtime.

const std = @import("std");

pub const File = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const pos_elf = @embedFile("pos_elf");

pub const files = [_]File{
    .{ .name = "pos.elf", .bytes = pos_elf },
};

pub fn count() usize {
    return files.len;
}

pub fn at(index: usize) File {
    return files[index];
}

pub fn find(name: []const u8) ?File {
    for (files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}
