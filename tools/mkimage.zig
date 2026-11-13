//! mkimage — wraps a raw AArch64 kernel binary in the arm64 `Image` header.
//!
//! This is a host-side build tool (also Zig), not part of the OS. Firmware
//! that speaks the Linux arm64 boot protocol (U-Boot `booti`, TF-A, most
//! bootloaders, and QEMU when it recognises the header) expects:
//!
//!   offset 0x00  code0/code1        reserved (0)
//!   offset 0x08  text_offset        distance from load address to the kernel
//!   offset 0x10  image_size         0 => use the file size
//!   offset 0x18  flags             0 => little endian, 4 KiB pages
//!   offset 0x38  magic              "ARM\x64" (0x644d5241, little endian)
//!
//! Usage: mkimage <raw-binary> <output.img> [text_offset]

const std = @import("std");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    const input_path = args.next() orelse return usage();
    const output_path = args.next() orelse return usage();
    const text_offset: u64 = blk: {
        if (args.next()) |raw| break :blk try std.fmt.parseInt(u64, raw, 0);
        break :blk 0x8_0000;
    };

    const allocator = std.heap.page_allocator;
    const raw = try std.fs.cwd().readFileAlloc(allocator, input_path, 64 * 1024 * 1024);
    defer allocator.free(raw);

    if (text_offset < 64) {
        std.debug.print("mkimage: text_offset must be at least 64 bytes\n", .{});
        std.process.exit(2);
    }

    var header = [_]u8{0} ** 64;
    std.mem.writeInt(u64, header[8..16], text_offset, .little);
    std.mem.writeInt(u64, header[16..24], 0, .little);
    std.mem.writeInt(u64, header[24..32], 0, .little);
    std.mem.writeInt(u32, header[56..60], 0x644d_5241, .little);

    var out = try std.fs.cwd().createFile(output_path, .{});
    defer out.close();

    try out.writeAll(&header);

    // Zero padding up to the kernel's link address.
    var padding = [_]u8{0} ** 4096;
    var remaining = text_offset - header.len;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, padding.len));
        try out.writeAll(padding[0..chunk]);
        remaining -= chunk;
    }

    try out.writeAll(raw);

    std.debug.print("mkimage: {s} -> {s} ({d} bytes, text_offset 0x{x})\n", .{
        input_path,
        output_path,
        text_offset + raw.len,
        text_offset,
    });
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: mkimage <raw-binary> <output.img> [text_offset]\n", .{});
    return error.InvalidArguments;
}
