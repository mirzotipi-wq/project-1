//! Host-side unit test root. Kernel-only code is never imported here.

const std = @import("std");

test "host harness is alive" {
    try std.testing.expectEqual(@as(u32, 4), 2 + 2);
}
