//! Host-side unit tests. Only pure logic is imported here — anything that
//! touches system registers or MMIO is verified in QEMU instead.

const std = @import("std");

test {
    _ = @import("kernel/heap.zig");
    _ = @import("kernel/pmm.zig");
    _ = @import("lib/fdt.zig");
    _ = @import("arch/aarch64/cpu.zig");
    _ = @import("arch/aarch64/mmu.zig");
    _ = @import("arch/aarch64/gic.zig");
    _ = @import("arch/aarch64/timer.zig");
    _ = @import("arch/aarch64/trap.zig");
    _ = @import("devices/pl011.zig");
    _ = @import("kernel/klog.zig");
    _ = @import("kernel/sync.zig");
    _ = @import("kernel/uaccess.zig");
    _ = @import("kernel/cap.zig");
    _ = @import("kernel/elf.zig");
    _ = @import("kernel/restart.zig");
    _ = @import("kernel/names.zig");
    _ = @import("kernel/thread.zig");
    _ = @import("kernel/quota.zig");
    _ = @import("kernel/sandbox.zig");
    _ = @import("kernel/driver.zig");
    _ = @import("devices/pl031.zig");
    _ = @import("kernel/pci.zig");
    _ = @import("kernel/virtio.zig");
    _ = @import("kernel/block.zig");
    _ = @import("kernel/partition.zig");
    _ = @import("kernel/block_view.zig");
    _ = @import("kernel/fat32.zig");
    _ = @import("lib/font5x7.zig");
    _ = @import("lib/keymap.zig");
    _ = @import("lib/scanner.zig");
    _ = @import("lib/input_hid.zig");
    _ = @import("kernel/input.zig");
    _ = @import("lib/edid.zig");
    _ = @import("lib/display_mode.zig");
    _ = @import("kernel/fb.zig");
}

test "seeded prng is deterministic across runs" {
    var a = std.Random.DefaultPrng.init(1234);
    var b = std.Random.DefaultPrng.init(1234);
    try std.testing.expectEqual(a.random().int(u64), b.random().int(u64));
}
