//! Remove a node from a flattened device tree without moving anything.
//!
//! Phase 31's acceptance test asks what happens when QEMU does not present a
//! device. `virt` creates its RTC unconditionally, so the honest way to ask is
//! to boot with a tree that lacks the node: dump QEMU's own tree, nop the node
//! out, and pass the result back with `-machine virt,dtb=...`.
//!
//! The DTB format has had a no-op token since forever, precisely so a tree can
//! be edited without recompiling offsets. Replacing the node's tokens and its
//! property bytes with FDT_NOP leaves the header, the strings block and the
//! memory reservation map byte-identical, so the result is a valid tree with the
//! node gone. This is a host-side test tool written in Zig; the OS never runs it.
//!
//! Usage: zig run tools/nop-node.zig -- <in.dtb> <out.dtb> <node-name>

const std = @import("std");

const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

fn writeU32(bytes: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], value, .big);
}

fn nodeName(bytes: []const u8, off: usize) []const u8 {
    const start = off + 4;
    var end = start;
    while (end < bytes.len and bytes[end] != 0) end += 1;
    return bytes[start..end];
}

/// Offset just past a node's matching END_NODE.
fn nodeEnd(bytes: []const u8, start: usize) usize {
    var p = start;
    var depth: usize = 0;
    while (p + 4 <= bytes.len) {
        switch (readU32(bytes, p)) {
            FDT_BEGIN_NODE => {
                depth += 1;
                p = align4(p + 4 + nodeName(bytes, p).len + 1);
            },
            FDT_END_NODE => {
                if (depth > 0) depth -= 1;
                p += 4;
                if (depth == 0) return p;
            },
            FDT_PROP => {
                const len: usize = readU32(bytes, p + 4);
                p = align4(p + 12 + len);
            },
            FDT_NOP => p += 4,
            else => return 0,
        }
    }
    return 0;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len != 4) {
        std.debug.print("usage: nop-node <in.dtb> <out.dtb> <node-name>\n", .{});
        return error.BadArguments;
    }
    const input = try std.fs.cwd().readFileAlloc(alloc, args[1], 16 * 1024 * 1024);
    defer alloc.free(input);

    if (input.len < 40 or readU32(input, 0) != 0xd00d_feed) return error.NotAnFdt;
    const off_struct: usize = readU32(input, 8);
    const size_struct: usize = readU32(input, 36);

    const out = try alloc.dupe(u8, input);
    defer alloc.free(out);

    const wanted = args[3];
    var removed: usize = 0;
    var p = off_struct;
    const end = off_struct + size_struct;
    while (p + 4 <= end) {
        const token = readU32(out, p);
        if (token == FDT_BEGIN_NODE) {
            const name = nodeName(out, p);
            const node_end = nodeEnd(out, p);
            if (node_end == 0) return error.Malformed;
            if (std.mem.eql(u8, name, wanted)) {
                var q = p;
                while (q + 4 <= node_end) : (q += 4) writeU32(out, q, FDT_NOP);
                removed += 1;
            }
            p = align4(p + 4 + name.len + 1);
        } else if (token == FDT_PROP) {
            p = align4(p + 12 + @as(usize, readU32(out, p + 4)));
        } else if (token == FDT_NOP) {
            p += 4;
        } else if (token == FDT_END_NODE) {
            p += 4;
        } else if (token == FDT_END) {
            break;
        } else {
            return error.Malformed;
        }
    }

    if (removed == 0) {
        std.debug.print("nop-node: '{s}' not found\n", .{wanted});
        return error.NodeNotFound;
    }
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = out });
    std.debug.print("nop-node: removed {d} node(s) named '{s}' -> {s} ({d} bytes)\n", .{ removed, wanted, args[2], out.len });
}
