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
    report: *cassafs.Report,
    workspace: []u8,
    inode_storage: []cassafs.Inode,

    pub fn init(
        device: cassafs.Device,
        report: *cassafs.Report,
        workspace: []u8,
        inode_storage: []cassafs.Inode,
    ) Adapter {
        return .{
            .device = device,
            .report = report,
            .workspace = workspace,
            .inode_storage = inode_storage,
        };
    }

    pub fn backend(self: *Adapter) vfs.Backend {
        return .{
            .ctx = self,
            .root = self.report.root_ino,
            .writable = true,
            .stat_fn = statFn,
            .lookup_fn = lookupFn,
            .read_fn = readFn,
            .readdir_fn = readdirFn,
            .create_fn = createFn,
            .write_fn = writeFn,
        };
    }

    fn refresh(self: *Adapter) vfs.Error!void {
        const fresh = cassafs.scan(self.device, self.workspace, self.inode_storage) catch |err| return mapError(err);
        self.report.* = fresh;
    }

    fn statFor(self: *Adapter, ino: u64, out: *vfs.Stat) vfs.Error!void {
        const idx = inodeIndex(self.report, ino) orelse return error.NotFound;
        fillStat(&self.report.inodes[idx], out);
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
            error.NotDirectory => error.NotDirectory,
            error.InvalidPath => error.InvalidPath,
            error.Exists => error.Exists,
            error.NoSpace, error.FileTooLarge, error.TooManyNodes, error.TooManyRecords => error.NoSpace,
            error.ReadOnly => error.ReadOnly,
            error.BadCrc, error.BadInode, error.BadExtent, error.BadRecord, error.BadCheckpoint, error.BadFreeMap, error.BadSuperblock => error.Corrupt,
            error.Io, error.OutOfRange, error.Unsupported => error.Backend,
            else => error.Backend,
        };
    }

    fn statFn(ctx: *anyopaque, ino: u64, out: *vfs.Stat) vfs.Error!void {
        const self = selfFrom(ctx);
        const idx = inodeIndex(self.report, ino) orelse return error.NotFound;
        fillStat(&self.report.inodes[idx], out);
    }

    fn createFn(ctx: *anyopaque, parent: u64, name: []const u8, mode: u16) vfs.Error!vfs.Stat {
        _ = mode;
        const self = selfFrom(ctx);
        const ino = cassafs.createFile(self.device, self.report, parent, name, 0, self.workspace) catch |err| return mapError(err);
        self.refresh() catch |err| return err;
        var out: vfs.Stat = .{};
        self.statFor(ino, &out) catch return error.Backend;
        return out;
    }

    fn writeFn(ctx: *anyopaque, ino: u64, offset: u64, data: []const u8) vfs.Error!vfs.WriteResult {
        const self = selfFrom(ctx);
        cassafs.writeFile(self.device, self.report, ino, offset, data, 0, self.workspace) catch |err| return mapError(err);
        self.refresh() catch |err| return err;
        var out: vfs.Stat = .{};
        self.statFor(ino, &out) catch return error.Backend;
        return .{ .written = data.len, .stat = out };
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
    var report = try cassafs.scan(disk.device(32), &workspace, &inodes);
    var adapter = Adapter.init(disk.device(32), &report, &workspace, &inodes);
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

test "create and write through the VFS round-trip and survive a fresh scan" {
    var storage: [256 * 1024]u8 = [_]u8{0} ** (256 * 1024);
    var disk = TestDisk{ .blocks = storage[0 .. 64 * cassafs.block_size] };
    var workspace: [cassafs.workspaceRequired(64)]u8 = undefined;
    _ = try cassafs.format(disk.device(64), .{ .nodes = &test_nodes }, &workspace);

    var inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
    var report = try cassafs.scan(disk.device(64), &workspace, &inodes);
    var adapter = Adapter.init(disk.device(64), &report, &workspace, &inodes);
    var fs: vfs.Vfs = .{};
    try fs.mount("/", adapter.backend());

    const created = try fs.open("/catalog/new.txt", "/", .{ .read = false, .write = true, .create = true });
    const new_stat = try fs.statHandle(created);
    try std.testing.expectEqual(@as(u64, 0), new_stat.size);
    try std.testing.expectEqual(vfs.Kind.file, new_stat.kind);
    try std.testing.expectEqual(@as(usize, 14), try fs.write(created, "lot 43 created"));
    try fs.close(created);

    const reader = try fs.open("/catalog/new.txt", "/", .{});
    var buf: [64]u8 = undefined;
    const first = try fs.read(reader, &buf);
    try std.testing.expectEqualStrings("lot 43 created", buf[0..first]);
    try std.testing.expectEqual(@as(usize, 0), try fs.read(reader, &buf));
    try fs.close(reader);

    const writer = try fs.open("/catalog/new.txt", "/", .{ .read = false, .write = true });
    try std.testing.expectEqual(@as(usize, 1), try fs.writeAt(writer, 4, "X"));
    try fs.close(writer);
    const after = try fs.statPath("/catalog/new.txt", "/");
    try std.testing.expectEqual(@as(u64, 14), after.size);
    const reader2 = try fs.open("/catalog/new.txt", "/", .{});
    try std.testing.expectEqual(@as(usize, 14), try fs.readAt(reader2, 0, &buf));
    try std.testing.expectEqualStrings("lot X3 created", buf[0..14]);
    try fs.close(reader2);

    // Prove the bytes and CRC are in the committed log, not just the adapter's
    // in-memory report: unmount and scan the same device into fresh storage.
    try fs.unmount("/");
    var fresh_inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
    var fresh_workspace: [cassafs.workspaceRequired(64)]u8 = undefined;
    const fresh = try cassafs.scan(disk.device(64), &fresh_workspace, &fresh_inodes);
    var whole: [64]u8 = undefined;
    const n = try cassafs.readFile(disk.device(64), &fresh, "/catalog/new.txt", &whole);
    try std.testing.expectEqualStrings("lot X3 created", whole[0..n]);
    try std.testing.expectEqual(@as(u32, 6), fresh.inode_count);
    try std.testing.expectEqual(@as(u64, 61), fresh.data_bytes);
}

test "out of space and directory writes fail without leaving a mount claim" {
    var storage: [8 * cassafs.block_size]u8 = [_]u8{0} ** (8 * cassafs.block_size);
    var disk = TestDisk{ .blocks = &storage };
    var workspace: [cassafs.workspaceRequired(8)]u8 = undefined;
    const empty = [_]cassafs.Node{.{ .ino = 1, .parent = 0, .kind = .inode, .name = "" }};
    _ = try cassafs.format(disk.device(8), .{ .nodes = &empty }, &workspace);
    var inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
    var report = try cassafs.scan(disk.device(8), &workspace, &inodes);
    var adapter = Adapter.init(disk.device(8), &report, &workspace, &inodes);
    var fs: vfs.Vfs = .{};
    try fs.mount("/", adapter.backend());

    try std.testing.expectError(vfs.Error.NoSpace, fs.open("/full", "/", .{ .read = false, .write = true, .create = true }));
    try std.testing.expectError(vfs.Error.NotFound, fs.statPath("/full", "/"));
    try std.testing.expectError(vfs.Error.IsDirectory, fs.open("/", "/", .{ .read = false, .write = true }));
    try std.testing.expectError(vfs.Error.AccessDenied, fs.open("/missing", "/", .{ .create = true }));
    try std.testing.expectError(vfs.Error.NotFound, fs.open("/missing", "/", .{}));
    try std.testing.expectError(vfs.Error.InvalidPath, fs.statPath("", "/"));
}

test "a damaged B superblock still mounts through the VFS with fallback" {
    var storage: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024);
    var disk = TestDisk{ .blocks = storage[0 .. 32 * cassafs.block_size] };
    var workspace: [cassafs.workspaceRequired(32)]u8 = undefined;
    _ = try cassafs.format(disk.device(32), .{ .nodes = &test_nodes }, &workspace);
    disk.blocks[cassafs.block_size + 200] ^= 0x40;

    var inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
    var report = try cassafs.scan(disk.device(32), &workspace, &inodes);
    try std.testing.expect(report.fallback);
    try std.testing.expectEqual(cassafs.Slot.a, report.active);
    var adapter = Adapter.init(disk.device(32), &report, &workspace, &inodes);
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
