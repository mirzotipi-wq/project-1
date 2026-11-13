//! User pointer validation (phase 21).
//!
//! The kernel never dereferences an address supplied by EL0 without deciding
//! first whether that address is something the caller is allowed to name. The
//! check is deliberately redundant with the MMU:
//!
//!   1. the range must sit inside one of the process's declared regions and the
//!      region must carry the right (read, write) for this access;
//!   2. the caller additionally walks the process's own page tables to confirm
//!      the pages are actually mapped right now.
//!
//! Two independent answers before a byte is touched, and neither of them trusts
//! the number the user handed over. Keeping the range logic pure means it is
//! unit-tested on the host, where a security-relevant off-by-one is easy to
//! catch and impossible to debug over a serial line.

const std = @import("std");

pub const Access = enum { read, write };

/// A contiguous stretch of a process's address space with its rights.
pub const Region = struct {
    base: usize,
    len: usize,
    user_read: bool = true,
    user_write: bool = false,
    user_exec: bool = false,
    name: []const u8 = "",

    pub fn end(self: Region) usize {
        return self.base + self.len;
    }

    pub fn allows(self: Region, access: Access) bool {
        return switch (access) {
            .read => self.user_read,
            .write => self.user_write,
        };
    }
};

pub const max_regions = 8;

/// A single copy never spans more than this; the limit exists so that a bogus
/// length cannot turn a validation into a table walk of the whole space.
pub const max_copy: usize = 1 << 20;

/// True when `[va, va+len)` lies entirely inside one region that permits
/// `access`. A zero-length request is legal and touches nothing.
pub fn check(regions: []const Region, va: usize, len: usize, access: Access) bool {
    if (len == 0) return true;
    if (len > max_copy) return false;
    const end = va +% len; // wrapping add: overflow is caught immediately below
    if (end < va) return false;
    for (regions) |r| {
        if (!r.allows(access)) continue;
        if (va >= r.base and end <= r.end()) return true;
    }
    return false;
}

test "a range inside a readable region is accepted" {
    const regions = [_]Region{
        .{ .base = 0x8000_0000, .len = 0x1000, .name = "code" },
        .{ .base = 0x8100_0000, .len = 0x2000, .user_write = true, .name = "data" },
    };
    try std.testing.expect(check(&regions, 0x8000_0000, 16, .read));
    try std.testing.expect(check(&regions, 0x8100_0fff, 1, .write));
    try std.testing.expect(check(&regions, 0x8100_0000, 0x2000, .write));
}

test "writes to code are refused even though reads are allowed" {
    const regions = [_]Region{.{ .base = 0x8000_0000, .len = 0x1000 }};
    try std.testing.expect(check(&regions, 0x8000_0000, 8, .read));
    try std.testing.expect(!check(&regions, 0x8000_0000, 8, .write));
}

test "ranges that straddle a region boundary are refused" {
    const regions = [_]Region{.{ .base = 0x8100_0000, .len = 0x1000, .user_write = true }};
    try std.testing.expect(!check(&regions, 0x8100_0ff8, 16, .write)); // spills past the end
    try std.testing.expect(!check(&regions, 0x80ff_fff8, 16, .write)); // spills past the start
    try std.testing.expect(check(&regions, 0x8100_0ff0, 16, .write)); // exactly fits
}

test "length overflow and oversized copies are refused" {
    const regions = [_]Region{.{ .base = 0x8100_0000, .len = 0x1000, .user_write = true }};
    try std.testing.expect(!check(&regions, 0x8100_0000, std.math.maxInt(usize), .write));
    try std.testing.expect(!check(&regions, 0x8100_0000, max_copy + 1, .write));
    // The end of the address space must not wrap into a valid start.
    try std.testing.expect(!check(&regions, std.math.maxInt(usize) - 3, 8, .write));
}

test "an empty region list accepts nothing" {
    const regions = [_]Region{};
    try std.testing.expect(!check(&regions, 0x8100_0000, 1, .read));
    try std.testing.expect(check(&regions, 0x8100_0000, 0, .read)); // nothing to touch
}
