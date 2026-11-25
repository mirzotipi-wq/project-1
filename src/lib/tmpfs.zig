//! Bounded in-memory filesystem for phase 46.
//!
//! tmpfs is deliberately small: sixteen nodes, 4 KiB per file and no
//! allocation. It gives the VFS a writable, fast scratch backend that needs no
//! block device, and it exercises the same `Backend` callbacks as CASSAFS and
//! FAT32. Data is volatile by design; the POS runtime puts receipts and the
//! catalog on CASSAFS, while tmpfs holds short-lived spool/cache files.

const std = @import("std");
const vfs = @import("vfs.zig");

pub const max_nodes = 16;
pub const max_file_bytes = 4096;

const Error = vfs.Error;
const Stat = vfs.Stat;
const DirEntry = vfs.DirEntry;
const WriteResult = vfs.WriteResult;

pub const Node = struct {
    used: bool = false,
    ino: u64 = 0,
    parent: u64 = 0,
    kind: vfs.Kind = .file,
    mode: u16 = 0o100644,
    size: u32 = 0,
    name: [vfs.max_name]u8 = [_]u8{0} ** vfs.max_name,
    name_len: u8 = 0,
    data: [max_file_bytes]u8 = undefined,
};

pub const Fs = struct {
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    next_ino: u64 = 2,

    pub fn init() Fs {
        var fs = Fs{};
        fs.reset();
        return fs;
    }

    /// Reset a persistent instance in place. The kernel uses this instead of
    /// constructing a 64 KiB `Fs` temporary on its small boot stack.
    pub fn reset(self: *Fs) void {
        @memset(std.mem.asBytes(self), 0);
        self.next_ino = 2;
        self.nodes[0] = .{
            .used = true,
            .ino = 1,
            .parent = 0,
            .kind = .directory,
            .mode = 0o040755,
            .size = 0,
            .name_len = 0,
        };
    }

    pub fn backend(self: *Fs) vfs.Backend {
        return .{
            .ctx = self,
            .root = 1,
            .writable = true,
            .stat_fn = statFn,
            .lookup_fn = lookupFn,
            .read_fn = readFn,
            .readdir_fn = readdirFn,
            .create_fn = createFn,
            .write_fn = writeFn,
            .mkdir_fn = mkdirFn,
            .chmod_fn = chmodFn,
        };
    }

    pub fn usedNodes(self: *const Fs) usize {
        var count: usize = 0;
        for (self.nodes) |node| if (node.used) {
            count += 1;
        };
        return count;
    }

    pub fn usedBytes(self: *const Fs) usize {
        var total: usize = 0;
        for (self.nodes) |node| {
            if (node.used and node.kind == .file) total += node.size;
        }
        return total;
    }

    fn find(self: *Fs, ino: u64) ?*Node {
        for (&self.nodes) |*node| {
            if (node.used and node.ino == ino) return node;
        }
        return null;
    }

    fn child(self: *Fs, parent: u64, name: []const u8) ?*Node {
        for (&self.nodes) |*node| {
            if (node.used and node.parent == parent and std.mem.eql(u8, node.name[0..node.name_len], name)) return node;
        }
        return null;
    }

    fn statOf(node: *const Node) Stat {
        return .{
            .ino = node.ino,
            .parent = node.parent,
            .kind = node.kind,
            .size = node.size,
            .mode = node.mode,
        };
    }

    fn newChild(self: *Fs, parent: u64, name: []const u8, kind: vfs.Kind, mode: u16) Error!Stat {
        if (name.len == 0 or name.len > vfs.max_name) return error.InvalidPath;
        const parent_node = self.find(parent) orelse return error.NotFound;
        if (parent_node.kind != .directory) return error.NotDirectory;
        if (self.child(parent, name) != null) return error.Exists;

        var slot: usize = 1;
        while (slot < max_nodes) : (slot += 1) {
            const node = &self.nodes[slot];
            if (node.used) continue;
            const type_bits: u16 = if (kind == .directory) 0o040000 else 0o100000;
            node.* = .{
                .used = true,
                .ino = self.next_ino,
                .parent = parent,
                .kind = kind,
                .mode = type_bits | (mode & 0o7777),
                .size = 0,
                .name_len = @intCast(name.len),
            };
            self.next_ino += 1;
            @memcpy(node.name[0..name.len], name);
            @memset(node.data[0..], 0);
            return statOf(node);
        }
        return error.NoSpace;
    }

    fn statFn(ctx: *anyopaque, ino: u64, out: *Stat) Error!void {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        const node = self.find(ino) orelse return error.NotFound;
        out.* = statOf(node);
    }

    fn lookupFn(ctx: *anyopaque, parent: u64, name: []const u8, out: *Stat) Error!void {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        const node = self.child(parent, name) orelse return error.NotFound;
        out.* = statOf(node);
    }

    fn readFn(ctx: *anyopaque, ino: u64, offset: u64, out: []u8) Error!usize {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        const node = self.find(ino) orelse return error.NotFound;
        if (node.kind != .file) return error.IsDirectory;
        if (offset >= node.size or out.len == 0) return 0;
        const start: usize = @intCast(offset);
        const n = @min(out.len, @as(usize, node.size) - start);
        @memcpy(out[0..n], node.data[start..][0..n]);
        return n;
    }

    fn readdirFn(ctx: *anyopaque, ino: u64, index: u32, out: *DirEntry) Error!bool {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        const parent = self.find(ino) orelse return error.NotFound;
        if (parent.kind != .directory) return error.NotDirectory;
        var seen: u32 = 0;
        for (&self.nodes) |*node| {
            if (!node.used or node.ino == ino or node.parent != ino) continue;
            if (seen == index) {
                out.* = .{
                    .ino = node.ino,
                    .parent = node.parent,
                    .kind = node.kind,
                    .size = node.size,
                    .name_len = node.name_len,
                };
                @memcpy(out.name[0..node.name_len], node.name[0..node.name_len]);
                return true;
            }
            seen += 1;
        }
        return false;
    }

    fn createFn(ctx: *anyopaque, parent: u64, name: []const u8, mode: u16) Error!Stat {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        return self.newChild(parent, name, .file, mode);
    }

    fn mkdirFn(ctx: *anyopaque, parent: u64, name: []const u8, mode: u16) Error!Stat {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        return self.newChild(parent, name, .directory, mode);
    }

    fn writeFn(ctx: *anyopaque, ino: u64, offset: u64, data: []const u8) Error!WriteResult {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        const node = self.find(ino) orelse return error.NotFound;
        if (node.kind != .file) return error.IsDirectory;
        if (offset > max_file_bytes) return error.NoSpace;
        const start: usize = @intCast(offset);
        if (start + data.len > max_file_bytes) return error.NoSpace;
        if (start > node.size) @memset(node.data[node.size..start], 0);
        @memcpy(node.data[start..][0..data.len], data);
        node.size = @intCast(@max(@as(usize, node.size), start + data.len));
        return .{ .written = data.len, .stat = statOf(node) };
    }

    fn chmodFn(ctx: *anyopaque, ino: u64, mode: u16) Error!void {
        const self: *Fs = @ptrCast(@alignCast(ctx));
        const node = self.find(ino) orelse return error.NotFound;
        const type_bits: u16 = if (node.kind == .directory) 0o040000 else 0o100000;
        node.mode = type_bits | (mode & 0o7777);
    }
};

test "tmpfs backend serves nested files through the VFS" {
    var fs = Fs.init();
    var v = vfs.Vfs.init();
    try v.mount("/", fs.backend());

    _ = try v.mkdir("/spool", "/", 0o040755);
    const h = try v.open("/spool/ticket.txt", "/", .{ .write = true, .create = true });
    try std.testing.expectEqual(@as(usize, 5), try v.write(h, "hello"));
    try v.close(h);

    const read_handle = try v.open("/spool/ticket.txt", "/", .{});
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try v.read(read_handle, &bytes));
    try std.testing.expectEqualStrings("hello", bytes[0..5]);
    try v.close(read_handle);

    const dir = try v.open("/spool", "/", .{});
    var entry: vfs.DirEntry = .{};
    try std.testing.expect(try v.readdir(dir, 0, &entry));
    try std.testing.expectEqualStrings("ticket.txt", entry.nameSlice());
    try v.close(dir);

    const st = try v.statPath("/spool/ticket.txt", "/");
    try std.testing.expectEqual(@as(u64, 5), st.size);
    try std.testing.expectEqual(@as(usize, 3), fs.usedNodes());
    try std.testing.expectEqual(@as(usize, 5), fs.usedBytes());
}

test "tmpfs enforces permissions and supports VFS locks and events" {
    var fs = Fs.init();
    var v = vfs.Vfs.init();
    try v.mount("/", fs.backend());
    _ = try v.mkdir("/spool", "/", 0o040755);
    const created = try v.open("/spool/events.txt", "/", .{ .write = true, .create = true });
    try v.close(created);

    const changed = try v.chmod("/spool/events.txt", "/", 0o444);
    try std.testing.expectEqual(@as(u16, 0o100444), changed.mode);
    try std.testing.expectError(error.AccessDenied, v.open("/spool/events.txt", "/", .{ .write = true }));
    _ = try v.chmod("/spool/events.txt", "/", 0o644);

    const first = try v.open("/spool/events.txt", "/", .{ .write = true });
    const second = try v.open("/spool/events.txt", "/", .{});
    try v.lock(first, .exclusive);
    try std.testing.expectError(error.LockConflict, v.lock(second, .shared));
    try v.unlock(first);
    try v.lock(first, .shared);
    try v.lock(second, .shared);
    try v.unlock(second);
    try v.unlock(first);
    try std.testing.expectEqual(@as(u32, 0), v.stats().locks);

    const id = try v.watch("/spool", "/");
    try std.testing.expectEqual(@as(usize, 1), v.stats().watches);
    _ = try v.write(first, "sale");
    try v.close(first);
    try v.close(second);

    var event: vfs.Event = .{};
    try std.testing.expect(v.nextEvent(&event));
    try std.testing.expectEqual(vfs.EventKind.modified, event.kind);
    try std.testing.expectEqualStrings("/spool/events.txt", event.pathSlice());
    try std.testing.expect(!v.nextEvent(&event));

    try v.unwatch(id);
    try std.testing.expectEqual(@as(usize, 0), v.stats().watches);
}
