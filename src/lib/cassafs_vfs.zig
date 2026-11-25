//! CASSAFS backend for the phase-42 VFS.
//!
//! The adapter is deliberately thin: it translates VFS nodes to CASSAFS inode
//! numbers and range reads to `cassafs.readInodeRange`. Mount validation happens
//! in the kernel before this adapter is registered; the callbacks still return
//! `Corrupt` for an inode or extent that cannot be honoured.

const std = @import("std");
const cassafs = @import("cassafs.zig");
const vfs = @import("vfs.zig");

pub const Adapter = struct {
    device: cassafs.Device,
    report: *const cassafs.Report,

    pub fn init(device: cassafs.Device, report: *const cassafs.Report) Adapter {
        return .{ .device = device, .report = report };
    }

    pub fn backend(self: *Adapter) vfs.Backend {
        return .{
            .ctx = self,
            .root = self.report.root_ino,
            .stat_fn = statFn,
            .lookup_fn = lookupFn,
            .read_fn = readFn,
            .readdir_fn = readdirFn,
        };
    }

    fn selfFrom(ctx: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn inodeIndex(report: *const cassafs.Report, ino: u64) ?usize {
        var i: usize = 0;
        while (i < report.inodes.len) : (i += 1) {
            if (report.inodes[i].ino == ino) return i;
        }
        return null;
    }

    fn fillStat(inode: *const cassafs.Inode, out: *vfs.Stat) void {
        out.* = .{
            .ino = inode.ino,
            .parent = inode.parent,
            .kind = if (inode.kind == .inode) .directory else .file,
            .size = inode.size,
            .mode = inode.mode,
        };
    }

    fn mapError(err: cassafs.Error) vfs.Error {
        return switch (err) {
            error.PathNotFound => error.NotFound,
            error.BadCrc, error.BadInode, error.BadExtent => error.Corrupt,
            error.Io, error.OutOfRange => error.Backend,
            else => error.Backend,
        };
    }

    fn statFn(ctx: *anyopaque, ino: u64, out: *vfs.Stat) vfs.Error!void {
        const self = selfFrom(ctx);
        const idx = inodeIndex(self.report, ino) orelse return error.NotFound;
        fillStat(&self.report.inodes[idx], out);
    }

    fn lookupFn(ctx: *anyopaque, parent: u64, name: []const u8, out: *vfs.Stat) vfs.Error!void {
        const self = selfFrom(ctx);
        var i: usize = 0;
        while (i < self.report.inodes.len) : (i += 1) {
            const inode = &self.report.inodes[i];
            if (inode.parent == parent and std.mem.eql(u8, inode.nameSlice(), name)) {
                fillStat(inode, out);
                return;
            }
        }
        return error.NotFound;
    }

    fn readFn(ctx: *anyopaque, ino: u64, offset: u64, out: []u8) vfs.Error!usize {
        const self = selfFrom(ctx);
        const idx = inodeIndex(self.report, ino) orelse return error.NotFound;
        if (self.report.inodes[idx].kind != .data) return error.IsDirectory;
        return cassafs.readInodeRange(self.device, self.report, ino, offset, out) catch |err| return mapError(err);
    }

    fn readdirFn(ctx: *anyopaque, ino: u64, index: u32, out: *vfs.DirEntry) vfs.Error!bool {
        const self = selfFrom(ctx);
        var seen: u32 = 0;
        var i: usize = 0;
        while (i < self.report.inodes.len) : (i += 1) {
            const inode = &self.report.inodes[i];
            if (inode.parent != ino or inode.ino == ino) continue;
            if (seen == index) {
                out.* = .{
                    .ino = inode.ino,
                    .parent = inode.parent,
                    .kind = if (inode.kind == .inode) .directory else .file,
                    .size = inode.size,
                };
                const name = inode.nameSlice();
                if (name.len > vfs.max_name) return error.NameTooLong;
                @memcpy(out.name[0..name.len], name);
                out.name_len = @intCast(name.len);
                return true;
            }
            seen += 1;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Host test: format a real CASSAFS image in memory, mount it through the VFS,
// and read the same bytes through the adapter that the kernel uses.
// ---------------------------------------------------------------------------

const TestDisk = struct {
    blocks: []u8,

    fn read(ctx: *anyopaque, block: u32, buf: *[cassafs.block_size]u8) cassafs.Error!void {
        const self: *TestDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, block) * cassafs.block_size;
        if (off + cassafs.block_size > self.blocks.len) return error.OutOfRange;
        @memcpy(buf, self.blocks[off..][0..cassafs.block_size]);
    }

    fn write(ctx: *anyopaque, block: u32, buf: *const [cassafs.block_size]u8) cassafs.Error!void {
        const self: *TestDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, block) * cassafs.block_size;
        if (off + cassafs.block_size > self.blocks.len) return error.OutOfRange;
        @memcpy(self.blocks[off..][0..cassafs.block_size], buf);
    }

    fn flush(_: *anyopaque) cassafs.Error!void {}

    fn device(self: *TestDisk, blocks: u32) cassafs.Device {
        return .{ .ctx = self, .blocks = blocks, .read_fn = TestDisk.read, .write_fn = TestDisk.write, .flush_fn = TestDisk.flush };
    }
};

const test_nodes = [_]cassafs.Node{
    .{ .ino = 1, .parent = 0, .kind = .inode, .name = "" },
    .{ .ino = 2, .parent = 1, .kind = .inode, .name = "catalog" },
    .{ .ino = 3, .parent = 2, .kind = .data, .name = "products.db", .data = "sku,price\n1001,250\n1002,180\n" },
    .{ .ino = 4, .parent = 1, .kind = .inode, .name = "receipts" },
    .{ .ino = 5, .parent = 4, .kind = .data, .name = "WELCOME.TXT", .data = "Welcome to CassaOS\n" },
};

test "CASSAFS mounts through the VFS and reads byte-identical ranges" {
    var storage: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024);
    var disk = TestDisk{ .blocks = storage[0 .. 32 * cassafs.block_size] };
    var workspace: [cassafs.workspaceRequired(32)]u8 = undefined;
    _ = try cassafs.format(disk.device(32), .{ .nodes = &test_nodes, .label = "VFS Test", .uuid = [_]u8{0x42} ** 16 }, &workspace);

    var inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
    const report = try cassafs.scan(disk.device(32), &workspace, &inodes);
    var adapter = Adapter.init(disk.device(32), &report);
    var fs: vfs.Vfs = .{};
    try fs.mount("/", adapter.backend());

    const stat = try fs.statPath("/catalog/products.db", "/");
    try std.testing.expectEqual(@as(u64, 3), stat.ino);
    try std.testing.expectEqual(@as(u64, 2), stat.parent);
    try std.testing.expectEqual(vfs.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u64, 28), stat.size);

    const h = try fs.open("/catalog/products.db", "/", .{});
    var buf: [7]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), try fs.read(h, &buf));
    try std.testing.expectEqualStrings("sku,pri", &buf);
    try std.testing.expectEqual(@as(usize, 7), try fs.readAt(h, 10, &buf));
    try std.testing.expectEqualStrings("1001,25", &buf);
    try std.testing.expectEqual(@as(usize, 0), try fs.readAt(h, 28, &buf));
    var whole: [64]u8 = undefined;
    const n = try fs.readAt(h, 0, &whole);
    try std.testing.expectEqualStrings("sku,price\n1001,250\n1002,180\n", whole[0..n]);
    try fs.close(h);

    const dir = try fs.open("/", "/", .{});
    var entry: vfs.DirEntry = .{};
    try std.testing.expect(try fs.readdir(dir, 0, &entry));
    try std.testing.expectEqualStrings("catalog", entry.nameSlice());
    try std.testing.expect(try fs.readdir(dir, 1, &entry));
    try std.testing.expectEqualStrings("receipts", entry.nameSlice());
    try std.testing.expect(!try fs.readdir(dir, 2, &entry));
    try fs.close(dir);

    const w = try fs.open("./WELCOME.TXT", "/receipts", .{});
    var line: [64]u8 = undefined;
    const wn = try fs.read(w, &line);
    try std.testing.expectEqualStrings("Welcome to CassaOS\n", line[0..wn]);
    try fs.close(w);
    try fs.unmount("/");
    try std.testing.expectEqual(@as(usize, 0), fs.mountCount());
}

test "a damaged B superblock still mounts through the VFS with fallback" {
    var storage: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024);
    var disk = TestDisk{ .blocks = storage[0 .. 32 * cassafs.block_size] };
    var workspace: [cassafs.workspaceRequired(32)]u8 = undefined;
    _ = try cassafs.format(disk.device(32), .{ .nodes = &test_nodes }, &workspace);
    disk.blocks[cassafs.block_size + 200] ^= 0x40;

    var inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
    const report = try cassafs.scan(disk.device(32), &workspace, &inodes);
    try std.testing.expect(report.fallback);
    try std.testing.expectEqual(cassafs.Slot.a, report.active);
    var adapter = Adapter.init(disk.device(32), &report);
    var fs: vfs.Vfs = .{};
    try fs.mount("/", adapter.backend());
    const stat = try fs.statPath("/receipts/WELCOME.TXT", "/");
    try std.testing.expectEqual(@as(u64, 5), stat.ino);
    const h = try fs.open("/receipts/WELCOME.TXT", "/", .{});
    var buf: [64]u8 = undefined;
    const n = try fs.read(h, &buf);
    try std.testing.expectEqualStrings("Welcome to CassaOS\n", buf[0..n]);
    try fs.close(h);
    try fs.unmount("/");
}
