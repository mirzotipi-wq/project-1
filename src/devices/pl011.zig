//! PL011 UART driver (QEMU `virt`, Raspberry Pi, i.MX, and most ARM SoCs).
//!
//! Phase 3 of the plan: byte output must work before anything else exists, so
//! this driver has no dependencies and never blocks forever.

const cpu = @import("../../arch/aarch64/cpu.zig");

const Reg = enum(u32) {
    dr = 0x000,
    ecr = 0x004,
    fr = 0x018,
    ibrd = 0x024,
    fbrd = 0x028,
    lcrh = 0x02c,
    cr = 0x030,
    imsc = 0x038,
    icr = 0x044,
};

const FR_TXFF: u32 = 1 << 5;
const FR_RXFE: u32 = 1 << 4;
const FR_BUSY: u32 = 1 << 3;

const CR_UARTEN: u32 = 1 << 0;
const CR_TXE: u32 = 1 << 8;
const CR_RXE: u32 = 1 << 9;

const LCRH_FEN: u32 = 1 << 4;
const LCRH_8N1: u32 = 0x3 << 5;

pub const Pl011 = struct {
    base: usize,
    clock_hz: u32,

    fn reg(self: Pl011, which: Reg) *volatile u32 {
        return @ptrFromInt(self.base + @intFromEnum(which));
    }

    /// Program the UART for `baud` 8N1 with FIFOs enabled. Firmware has usually
    /// already done this, so a failure here is never fatal — we only need the
    /// data register to work.
    pub fn init(base: usize, clock_hz: u32, baud: u32) Pl011 {
        const self = Pl011{ .base = base, .clock_hz = clock_hz };

        // If firmware already brought the UART up (the normal case), leave it
        // alone: reprogramming would drop bytes the user has already typed.
        if ((self.reg(.cr).* & CR_UARTEN) != 0) {
            self.reg(.cr).* |= CR_TXE | CR_RXE;
            return self;
        }

        // Program the line settings without disabling the UART or flushing its
        // FIFOs: bytes typed before the kernel started must not be lost.

        if (baud != 0 and clock_hz != 0) {
            const div = @as(u64, clock_hz) * 4 / baud; // 16x oversampling
            const ibrd: u32 = @intCast(div >> 6);
            const fbrd: u32 = @intCast(div & 0x3f);
            self.reg(.ibrd).* = ibrd;
            self.reg(.fbrd).* = fbrd;
        }
        self.reg(.lcrh).* = LCRH_FEN | LCRH_8N1;
        self.reg(.imsc).* = 0; // polling mode for now; phase 36 enables RX IRQs
        self.reg(.cr).* = self.reg(.cr).* | CR_UARTEN | CR_TXE | CR_RXE;
        return self;
    }

    pub fn putc(self: Pl011, c: u8) void {
        var guard: u32 = 1_000_000;
        while ((self.reg(.fr).* & FR_TXFF) != 0) {
            guard -= 1;
            if (guard == 0) return;
        }
        self.reg(.dr).* = c;
    }

    pub fn writeAll(self: Pl011, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') self.putc('\r');
            self.putc(b);
        }
    }

    /// Non-blocking receive.
    pub fn tryGetc(self: Pl011) ?u8 {
        if ((self.reg(.fr).* & FR_RXFE) != 0) return null;
        return @truncate(self.reg(.dr).*);
    }

    pub fn flush(self: Pl011) void {
        var guard: u32 = 1_000_000;
        while ((self.reg(.fr).* & FR_BUSY) != 0 and guard > 0) : (guard -= 1) {}
    }
};

var console: ?Pl011 = null;

pub fn install(uart: Pl011) void {
    console = uart;
}

pub fn installed() ?Pl011 {
    return console;
}

pub fn putc(c: u8) void {
    if (console) |uart| uart.putc(c);
}

pub fn writeAll(bytes: []const u8) void {
    if (console) |uart| uart.writeAll(bytes);
}

pub fn tryGetc() ?u8 {
    if (console) |uart| return uart.tryGetc();
    return null;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    Writer.print(fmt, args);
}

pub fn flush() void {
    if (console) |uart| uart.flush();
}

/// Writer used by the rest of the kernel for formatted output.
pub const Writer = struct {
    pub const Error = error{};
    pub const Context = void;

    pub fn writeFn(_: Context, bytes: []const u8) Error!usize {
        if (console) |uart| uart.writeAll(bytes);
        return bytes.len;
    }

    pub fn print(comptime fmt: []const u8, args: anytype) void {
        const writer = std.io.GenericWriter(Context, Error, writeFn){ .context = {} };
        std.fmt.format(writer, fmt, args) catch {};
    }
};

const std = @import("std");

test "uart register offsets match the PL011 TRM" {
    try std.testing.expectEqual(@as(u32, 0x18), @intFromEnum(Reg.fr));
    try std.testing.expectEqual(@as(u32, 0x30), @intFromEnum(Reg.cr));
}
