const std = @import("std");

const PL011_BASE: usize = 0x0900_0000;

var boot_stack: [16 * 1024]u8 align(16) = undefined;

comptime {
    @export(&boot_stack, .{ .name = "boot_stack" });
}

fn uartPut(c: u8) void {
    const dr: *volatile u32 = @ptrFromInt(PL011_BASE + 0x00);
    const fr: *volatile u32 = @ptrFromInt(PL011_BASE + 0x18);
    while (fr.* & (1 << 5) != 0) {}
    dr.* = c;
}

fn print(s: []const u8) void {
    for (s) |c| uartPut(c);
}

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\adrp x2, __bss_start
        \\add  x2, x2, :lo12:__bss_start
        \\adrp x3, __bss_end
        \\add  x3, x3, :lo12:__bss_end
        \\1:
        \\  cmp x2, x3
        \\  b.hs 2f
        \\  str xzr, [x2], #8
        \\  b 1b
        \\2:
        \\msr  spsel, #1
        \\adrp x9, boot_stack
        \\add  x9, x9, :lo12:boot_stack
        \\add  x9, x9, #16384
        \\mov  sp, x9
        \\b    kmain
    );
}

pub export fn kmain() callconv(.C) noreturn {
    print("CASSA BOOT OK\n");
    print("smoke test: uart + bss + stack\n");
    while (true) {
        asm volatile ("wfe");
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    print("\nPANIC: ");
    print(msg);
    print("\n");
    while (true) {
        asm volatile ("wfe");
    }
}
