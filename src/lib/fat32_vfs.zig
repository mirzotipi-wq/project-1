//! Read-only FAT32 backend for the VFS (phase 45).
//!
//! The phase-36 driver already parses the BPB, walks cluster chains, decodes
//! long file names and validates every on-disk bound. This adapter adds only
//! what a namespace needs: stable inode numbers derived from the directory
//! entry's on-disk location, a small cache of those entries, case-insensitive
//! lookup, range reads and the VFS access policy. It never writes.
//!
//! FAT32 has no inode number. A directory entry's `(sector, slot)` is stable on
//! a read-only volume and unique within it, so the backend inode is that pair
//! packed into a u64. The root has the reserved inode 1.

const std = @import("std");
const builtin = @import("builtin");
const fat32 = @import("../kernel/fat32.zig");
const vfs = @import("vfs.zig");

pub const root_ino: u64 = 1;

const Cached = struct {
    used: bool = false,
    ino: u64 = 0,
    parent: u64 = 0,
    cluster: u32 = 0,
    size: u32 = 0,
    attr: u8 = 0,

    fn isDir(self: *const Cached) bool {
        return self.attr & 0x10 != 0;
    }
};

pub const Adapter = struct {
    volume: *fat32.Volume,
    root_cluster: u32,
    entries: [vfs.max_nodes]Cached = [_]Cached{.{}} ** vfs.max_nodes,

    pub fn init(volume: *fat32.Volume) Adapter {
        var self = Adapter{
            .volume = volume,
            .root_cluster = volume.geo.root_cluster,
        };
        self.entries[0] = .{
            .used = true,
            .ino = root_ino,
            .parent = root_ino,
            .cluster = volume.geo.root_cluster,
            .size = 0,
            .attr = 0x10,
        };
        return self;
    }

    pub fn backend(self: *Adapter) vfs.Backend {
        return .{
            .ctx = self,
            .root = root_ino,
            .writable = false,
            .stat_fn = statFn,
            .lookup_fn = lookupFn,
            .read_fn = readFn,
            .readdir_fn = readdirFn,
            .create_fn = createFn,
            .write_fn = writeFn,
        };
    }

    fn selfFrom(ctx: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn inoFor(item: *const fat32.DirItem) u64 {
        // A sector has at most 128 32-byte entries (4096-byte sectors), so the
        // low eight bits hold the slot and the rest holds the absolute LBA.
        return (@as(u64, item.lba) << 8) | @as(u64, item.offset / 32);
    }

    fn find(self: *Adapter, ino: u64) ?*Cached {
        for (&self.entries) |*entry| {
            if (entry.used and entry.ino == ino) return entry;
        }
        return null;
    }

    fn remember(self: *Adapter, item: *const fat32.DirItem, parent: u64) vfs.Error!u64 {
        const ino = inoFor(item);
        if (self.find(ino)) |entry| {
            entry.parent = parent;
            entry.cluster = item.cluster;
            entry.size = item.size;
            entry.attr = item.attr;
            return ino;
        }
        for (&self.entries) |*entry| {
            if (!entry.used) {
                entry.* = .{
                    .used = true,
                    .ino = ino,
                    .parent = parent,
                    .cluster = item.cluster,
                    .size = item.size,
                    .attr = item.attr,
                };
                return ino;
            }
        }
        return error.TooManyNodes;
    }

    fn fillStat(entry: *const Cached, out: *vfs.Stat) void {
        out.* = .{
            .ino = entry.ino,
            .parent = entry.parent,
            .kind = if (entry.isDir()) .directory else .file,
            .size = entry.size,
            .mode = if (entry.isDir()) 0o040555 else 0o100444,
        };
    }

    fn mapError(err: fat32.Error) vfs.Error {
        return switch (err) {
            error.NotFound => error.NotFound,
            error.NotDir => error.NotDirectory,
            error.IsDir => error.IsDirectory,
            error.Corrupt, error.BadBoot, error.BadGeometry => error.Corrupt,
            error.NameTooLong => error.NameTooLong,
            error.ReadOnly => error.ReadOnly,
            error.NoSpace => error.NoSpace,
            error.Unsupported => error.Unsupported,
            else => error.Backend,
        };
    }

    fn statFn(ctx: *anyopaque, ino: u64, out: *vfs.Stat) vfs.Error!void {
        const self = selfFrom(ctx);
        const entry = self.find(ino) orelse return error.NotFound;
        fillStat(entry, out);
    }

    fn lookupFn(ctx: *anyopaque, parent: u64, name: []const u8, out: *vfs.Stat) vfs.Error!void {
        const self = selfFrom(ctx);
        const dir = self.find(parent) orelse return error.NotFound;
        if (!dir.isDir()) return error.NotDirectory;
        const item = (self.volume.findIn(dir.cluster, name) catch |err| return mapError(err)) orelse return error.NotFound;
        if (item.isDir()) {
            if (item.cluster < 2 or item.cluster >= self.volume.geo.clusters + 2) return error.Corrupt;
        } else {
            self.volume.validateFileChain(item.cluster, item.size) catch |err| return mapError(err);
        }
        const ino = try self.remember(&item, parent);
        const entry = self.find(ino) orelse return error.NotFound;
        fillStat(entry, out);
    }

    fn readFn(ctx: *anyopaque, ino: u64, offset: u64, out: []u8) vfs.Error!usize {
        const self = selfFrom(ctx);
        const entry = self.find(ino) orelse return error.NotFound;
        if (entry.isDir()) return error.IsDirectory;
        return self.volume.readFileRange(entry.cluster, entry.size, offset, out) catch |err| return mapError(err);
    }

    fn readdirFn(ctx: *anyopaque, ino: u64, index: u32, out: *vfs.DirEntry) vfs.Error!bool {
        const self = selfFrom(ctx);
        const dir = self.find(ino) orelse return error.NotFound;
        if (!dir.isDir()) return error.NotDirectory;
        var it = self.volume.iterStartAt(dir.cluster);
        var seen: u32 = 0;
        while (self.volume.nextItem(&it) catch |err| return mapError(err)) |item| {
            if (std.mem.eql(u8, item.name(), ".") or std.mem.eql(u8, item.name(), "..")) continue;
            const child_ino = try self.remember(&item, ino);
            if (seen == index) {
                const entry = self.find(child_ino) orelse return error.NotFound;
                out.* = .{
                    .ino = entry.ino,
                    .parent = entry.parent,
                    .kind = if (entry.isDir()) .directory else .file,
                    .size = entry.size,
                };
                const name = item.name();
                if (name.len > vfs.max_name) return error.NameTooLong;
                @memcpy(out.name[0..name.len], name);
                out.name_len = @intCast(name.len);
                return true;
            }
            seen += 1;
        }
        return false;
    }

    fn createFn(_: *anyopaque, _: u64, _: []const u8, _: u16) vfs.Error!vfs.Stat {
        return error.ReadOnly;
    }

    fn writeFn(_: *anyopaque, _: u64, _: u64, _: []const u8) vfs.Error!vfs.WriteResult {
        return error.ReadOnly;
    }
};

// ---------------------------------------------------------------------------
// Host test: a real FAT32 volume on a RAM disk, mounted through the VFS with
// the same adapter the kernel uses. The file spans several clusters so the
// range reader's chain walking and EOF checks are exercised, not a single
// cluster that could hide an offset bug.
// ---------------------------------------------------------------------------

const test_sectors: u64 = 40 * 1024 * 1024 / 512;
var test_disk: [if (builtin.is_test) test_sectors * 512 else 1]u8 align(8) = undefined;

fn ramRead(lba: u64, buf: [*]u8, count: u32) @import("../kernel/block.zig").Error!void {
    const n = @as(u64, count) * 512;
    if (lba > test_sectors or n > test_sectors * 512 - lba * 512) return error.NoSpace;
    @memcpy(buf[0..n], test_disk[@as(usize, @intCast(lba * 512))..][0..n]);
}

fn ramWrite(lba: u64, buf: [*]const u8, count: u32) @import("../kernel/block.zig").Error!void {
    const n = @as(u64, count) * 512;
    if (lba > test_sectors or n > test_sectors * 512 - lba * 512) return error.NoSpace;
    @memcpy(test_disk[@as(usize, @intCast(lba * 512))..][0..n], buf[0..n]);
}

fn ramFlush() @import("../kernel/block.zig").Error!void {}

test "FAT32 mounts read-only through the VFS and streams across clusters" {
    const block = @import("../kernel/block.zig");
    const block_view = @import("../kernel/block_view.zig");
    block.install(.{
        .capacity_sectors = test_sectors,
        .read = ramRead,
        .write = ramWrite,
        .flush = ramFlush,
    });
    defer block.uninstall();

    const view = block_view.View{ .backend = block.backend.?, .base_lba = 0, .sectors = test_sectors };
    _ = try fat32.mkfs(view, .{ .total_sectors = test_sectors, .sectors_per_cluster = 1 });
    var volume = try fat32.mount(view);

    var content: [3000]u8 = undefined;
    for (&content, 0..) |*byte, i| byte.* = @intCast((i * 17 + 3) & 0xff);
    _ = try volume.writeFile("CATALOG.CSV", &content);

    var adapter = Adapter.init(&volume);
    var fs = vfs.Vfs.init();
    try fs.mount("/", adapter.backend());

    const st = try fs.statPath("/catalog.csv", "/");
    try std.testing.expectEqual(vfs.Kind.file, st.kind);
    try std.testing.expectEqual(@as(u64, 3000), st.size);
    try std.testing.expectEqual(@as(u64, root_ino), st.parent);
    try std.testing.expectEqual(@as(u16, 0o100444), st.mode);

    const root = try fs.statPath("/", "/");
    try std.testing.expectEqual(vfs.Kind.directory, root.kind);
    try std.testing.expectEqual(@as(u16, 0o040555), root.mode);

    const h = try fs.open("/catalog.csv", "/", .{});
    defer fs.close(h) catch {};
    var got: [3000]u8 = undefined;
    var total: usize = 0;
    while (total < got.len) {
        const n = try fs.read(h, got[total..]);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expectEqual(@as(usize, 3000), total);
    try std.testing.expectEqualSlices(u8, content[0..], got[0..]);

    var window: [1200]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1200), try fs.readAt(h, 500, &window));
    try std.testing.expectEqualSlices(u8, content[500..1700], window[0..]);
    var eof: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try fs.readAt(h, 3000, &eof));

    const dir_h = try fs.open("/", "/", .{});
    defer fs.close(dir_h) catch {};
    var entry: vfs.DirEntry = .{};
    try std.testing.expect(try fs.readdir(dir_h, 0, &entry));
    try std.testing.expectEqualStrings("CATALOG.CSV", entry.nameSlice());
    try std.testing.expectEqual(@as(u64, 3000), entry.size);

    try std.testing.expectError(error.ReadOnly, fs.open("/catalog.csv", "/", .{ .read = false, .write = true }));
    try std.testing.expectError(error.ReadOnly, fs.open("/", "/", .{ .read = false, .write = true }));
}
