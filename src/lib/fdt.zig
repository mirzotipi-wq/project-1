//! Flat device tree (DTB) parser — phase 6.
//!
//! Only what the kernel needs: header validation, node walking, property
//! lookup, compatible-string matching and `reg` decoding for 2/2 cell layouts
//! (the AArch64 convention).

const std = @import("std");

pub const Error = error{ NotAnFdt, UnsupportedVersion, Truncated, Malformed };

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

pub const Reg = struct { base: u64, size: u64 };

pub const Node = struct { off: usize };

pub const Fdt = struct {
    bytes: []const u8,
    off_struct: usize,
    off_strings: usize,
    size_struct: usize,
    size_strings: usize,

    pub fn init(bytes: []const u8) Error!Fdt {
        if (bytes.len < 40) return error.Truncated;
        if (readU32(bytes, 0) != 0xd00d_feed) return error.NotAnFdt;
        const total: usize = readU32(bytes, 4);
        const off_struct: usize = readU32(bytes, 8);
        const off_strings: usize = readU32(bytes, 12);
        const version = readU32(bytes, 20);
        const size_strings: usize = readU32(bytes, 32);
        const size_struct: usize = readU32(bytes, 36);
        if (version < 16) return error.UnsupportedVersion;
        const end = @min(bytes.len, if (total == 0) bytes.len else total);
        if (off_struct + size_struct > end) return error.Truncated;
        if (off_strings + size_strings > end) return error.Truncated;
        if (end < 40) return error.Truncated;
        return .{
            .bytes = bytes[0..end],
            .off_struct = off_struct,
            .off_strings = off_strings,
            .size_struct = size_struct,
            .size_strings = size_strings,
        };
    }

    pub fn root(self: Fdt) Node {
        return .{ .off = self.off_struct };
    }

    fn nodeName(self: Fdt, off: usize) []const u8 {
        const start = off + 4;
        if (start >= self.bytes.len) return "";
        var end = start;
        while (end < self.bytes.len and self.bytes[end] != 0) end += 1;
        return self.bytes[start..end];
    }

    fn stringAt(self: Fdt, nameoff: usize) []const u8 {
        const start = self.off_strings + nameoff;
        if (start >= self.bytes.len) return "";
        var end = start;
        while (end < self.bytes.len and self.bytes[end] != 0) end += 1;
        return self.bytes[start..end];
    }

    fn skipNode(self: Fdt, begin_off: usize) usize {
        var p = begin_off;
        var depth: usize = 0;
        while (p + 4 <= self.bytes.len) {
            switch (readU32(self.bytes, p)) {
                FDT_BEGIN_NODE => {
                    depth += 1;
                    const node_name = self.nodeName(p);
                    p = align4(p + 4 + node_name.len + 1);
                },
                FDT_END_NODE => {
                    if (depth > 0) depth -= 1;
                    p += 4;
                    if (depth == 0) return p;
                },
                FDT_PROP => {
                    const len: usize = readU32(self.bytes, p + 4);
                    p = align4(p + 12 + len);
                },
                FDT_NOP => p += 4,
                else => return self.bytes.len,
            }
        }
        return self.bytes.len;
    }

    pub fn name(self: Fdt, node: Node) []const u8 {
        return self.nodeName(node.off);
    }

    pub fn firstChild(self: Fdt, node: Node) ?Node {
        var p = node.off + 4;
        const n = self.nodeName(node.off);
        p = align4(p + n.len + 1);
        while (p + 4 <= self.bytes.len) {
            switch (readU32(self.bytes, p)) {
                FDT_PROP => {
                    const len: usize = readU32(self.bytes, p + 4);
                    p = align4(p + 12 + len);
                },
                FDT_NOP => p += 4,
                FDT_BEGIN_NODE => return Node{ .off = p },
                else => return null,
            }
        }
        return null;
    }

    pub fn nextSibling(self: Fdt, node: Node) ?Node {
        var after = self.skipNode(node.off);
        // FDT_NOP tokens are legal anywhere a token is legal, and a tree that
        // has been edited in place (QEMU re-packs a `-dtb` blob, a bootloader
        // patches /chosen) leaves them between nodes. A no-op is not the end of
        // the sibling list: skip it and keep looking.
        while (after + 4 <= self.bytes.len and readU32(self.bytes, after) == FDT_NOP) after += 4;
        if (after + 4 > self.bytes.len) return null;
        if (readU32(self.bytes, after) == FDT_BEGIN_NODE) return Node{ .off = after };
        return null;
    }

    pub fn prop(self: Fdt, node: Node, wanted: []const u8) ?[]const u8 {
        var p = node.off + 4;
        const n = self.nodeName(node.off);
        p = align4(p + n.len + 1);
        while (p + 4 <= self.bytes.len) {
            switch (readU32(self.bytes, p)) {
                FDT_END_NODE => return null,
                FDT_NOP => {
                    p += 4;
                },
                FDT_PROP => {
                    const len: usize = readU32(self.bytes, p + 4);
                    const nameoff: usize = readU32(self.bytes, p + 8);
                    const value_off = p + 12;
                    if (value_off + len > self.bytes.len) return null;
                    if (std.mem.eql(u8, self.stringAt(nameoff), wanted)) {
                        return self.bytes[value_off..][0..len];
                    }
                    p = align4(value_off + len);
                },
                else => return null,
            }
        }
        return null;
    }

    /// True if the node's `compatible` list contains `want`.
    pub fn isCompatible(self: Fdt, node: Node, want: []const u8) bool {
        const value = self.prop(node, "compatible") orelse return false;
        var it = std.mem.splitScalar(u8, value, 0);
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry, want)) return true;
        }
        return false;
    }

    pub fn findByCompatible(self: Fdt, want: []const u8) ?Node {
        return self.searchCompatible(self.root(), want, 0);
    }

    fn searchCompatible(self: Fdt, node: Node, want: []const u8, depth: usize) ?Node {
        if (depth > 24) return null;
        if (self.isCompatible(node, want)) return node;
        var child = self.firstChild(node);
        while (child) |c| : (child = self.nextSibling(c)) {
            if (self.searchCompatible(c, want, depth + 1)) |found| return found;
        }
        return null;
    }

    pub fn findByName(self: Fdt, wanted: []const u8) ?Node {
        return self.searchName(self.root(), wanted, 0);
    }

    fn searchName(self: Fdt, node: Node, wanted: []const u8, depth: usize) ?Node {
        if (depth > 24) return null;
        const n = self.nodeName(node.off);
        const base = if (std.mem.indexOfScalar(u8, n, '@')) |at| n[0..at] else n;
        if (std.mem.eql(u8, base, wanted)) return node;
        var child = self.firstChild(node);
        while (child) |c| : (child = self.nextSibling(c)) {
            if (self.searchName(c, wanted, depth + 1)) |found| return found;
        }
        return null;
    }

    /// Decode `reg` assuming 2 address cells and 2 size cells (AArch64).
    pub fn regs(self: Fdt, node: Node, out: []Reg) []Reg {
        const value = self.prop(node, "reg") orelse return out[0..0];
        var count: usize = 0;
        var i: usize = 0;
        while (i + 16 <= value.len and count < out.len) : (i += 16) {
            const base = (@as(u64, readU32(value, i)) << 32) | readU32(value, i + 4);
            const size = (@as(u64, readU32(value, i + 8)) << 32) | readU32(value, i + 12);
            out[count] = .{ .base = base, .size = size };
            count += 1;
        }
        return out[0..count];
    }

    /// All `device_type = "memory"` regions (or nodes named memory@).
    pub fn memoryRegions(self: Fdt, out: []Reg) []Reg {
        var count: usize = 0;
        var child = self.firstChild(self.root());
        while (child) |c| : (child = self.nextSibling(c)) {
            const n = self.nodeName(c.off);
            const is_memory = blk: {
                if (self.prop(c, "device_type")) |dt| {
                    const trimmed = std.mem.trimRight(u8, dt, "\x00");
                    if (std.mem.eql(u8, trimmed, "memory")) break :blk true;
                }
                break :blk std.mem.startsWith(u8, n, "memory@");
            };
            if (!is_memory) continue;
            var ranges: [8]Reg = undefined;
            const found = self.regs(c, &ranges);
            for (found) |r| {
                if (count >= out.len) break;
                if (r.size == 0) continue;
                out[count] = r;
                count += 1;
            }
        }
        return out[0..count];
    }

    pub fn model(self: Fdt) []const u8 {
        const raw = self.prop(self.root(), "model") orelse return "unknown";
        return std.mem.trimRight(u8, raw, "\x00");
    }

    pub fn bootArgs(self: Fdt) []const u8 {
        const chosen = self.findByName("chosen") orelse return "";
        const raw = self.prop(chosen, "bootargs") orelse return "";
        return std.mem.trimRight(u8, raw, "\x00");
    }
};

test "align4 rounds up to the next 4-byte boundary" {
    try std.testing.expectEqual(@as(usize, 0), align4(0));
    try std.testing.expectEqual(@as(usize, 4), align4(1));
    try std.testing.expectEqual(@as(usize, 4), align4(4));
    try std.testing.expectEqual(@as(usize, 8), align4(5));
}

test "init rejects non-FDT memory" {
    var junk = [_]u8{0} ** 64;
    try std.testing.expectError(error.NotAnFdt, Fdt.init(&junk));
    try std.testing.expectError(error.Truncated, Fdt.init(junk[0..8]));
}

test "init accepts a minimal valid header" {
    var blob = [_]u8{0} ** 64;
    const header = [_]u32{ 0xd00d_feed, 64, 40, 44, 40, 17, 16, 0, 4, 20 };
    for (header, 0..) |word, i| {
        std.mem.writeInt(u32, blob[i * 4 ..][0..4], word, .big);
    }
    const fdt = try Fdt.init(&blob);
    try std.testing.expectEqual(@as(usize, 40), fdt.off_struct);
    try std.testing.expectEqualStrings("unknown", fdt.model());
}

test "nextSibling skips FDT_NOP tokens between nodes" {
    // A minimal tree: root -> a, NOP, b. A tree edited in place can leave a
    // no-op where a node used to be; traversal must step over it.
    var blob = [_]u8{0} ** 88;
    const header = [_]u32{ 0xd00d_feed, 88, 40, 84, 40, 17, 16, 0, 4, 44 };
    for (header, 0..) |word, i| std.mem.writeInt(u32, blob[i * 4 ..][0..4], word, .big);
    const put = struct {
        fn at(bytes: []u8, off: usize, token: u32) void {
            std.mem.writeInt(u32, bytes[off..][0..4], token, .big);
        }
    }.at;
    put(&blob, 40, 1); // begin root, empty name at 44
    put(&blob, 48, 1); // begin "a", name at 52
    blob[52] = 'a';
    put(&blob, 56, 2); // end "a"
    put(&blob, 60, 4); // a no-op where a node used to be
    put(&blob, 64, 1); // begin "b", name at 68
    blob[68] = 'b';
    put(&blob, 72, 2); // end "b"
    put(&blob, 76, 2); // end root
    put(&blob, 80, 9); // end of structure

    const fdt = try Fdt.init(&blob);
    const root = fdt.root();
    const a = fdt.firstChild(root).?;
    try std.testing.expectEqualStrings("a", fdt.name(a));
    const b = fdt.nextSibling(a).?;
    try std.testing.expectEqualStrings("b", fdt.name(b));
    try std.testing.expect(fdt.nextSibling(b) == null);
}
