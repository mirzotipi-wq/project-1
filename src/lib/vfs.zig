//! A small, backend-neutral VFS (phase 42).
//!
//! This module owns the namespace policy and the visible node/handle tables.
//! Filesystems plug in through `Backend` callbacks, so CASSAFS is one backend
//! today and a second backend can be added without touching path resolution,
//! mount lookup, handles or access checks.
//!
//! The VFS is deliberately read-only in phase 42. `open` rejects a write flag
//! with `ReadOnly` and checks the backend's mode bits before handing out a
//! handle. Mounts are longest-prefix mappings; a mount at `/` is the normal
//! case, and a mount at `/mnt/data` already shadows only that subtree.

const std = @import("std");

pub const max_path = 255;
pub const max_name = 63;
pub const max_mounts = 8;
pub const max_nodes = 128;
pub const max_handles = 32;

pub const Kind = enum { file, directory };

pub const Error = error{
    InvalidPath,
    NameTooLong,
    NotFound,
    NotDirectory,
    IsDirectory,
    AccessDenied,
    ReadOnly,
    TooManyMounts,
    TooManyNodes,
    TooManyHandles,
    Busy,
    NotMounted,
    AlreadyMounted,
    BadHandle,
    Backend,
    Corrupt,
};

pub const Stat = struct {
    ino: u64 = 0,
    parent: u64 = 0,
    kind: Kind = .file,
    size: u64 = 0,
    mode: u16 = 0,
};

pub const DirEntry = struct {
    ino: u64 = 0,
    parent: u64 = 0,
    kind: Kind = .file,
    size: u64 = 0,
    name: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,

    pub fn nameSlice(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
};

/// A filesystem backend. `root` is the backend inode used for the mount point.
/// `readdir` must be stable: index 0 is the first child and repeated calls with
/// the same index return the same entry until the backend changes.
pub const Backend = struct {
    ctx: *anyopaque,
    root: u64,
    stat_fn: *const fn (ctx: *anyopaque, ino: u64, out: *Stat) Error!void,
    lookup_fn: *const fn (ctx: *anyopaque, parent: u64, name: []const u8, out: *Stat) Error!void,
    read_fn: *const fn (ctx: *anyopaque, ino: u64, offset: u64, out: []u8) Error!usize,
    readdir_fn: *const fn (ctx: *anyopaque, ino: u64, index: u32, out: *DirEntry) Error!bool,
};

const Mount = struct {
    used: bool = false,
    point: [max_path]u8 = [_]u8{0} ** max_path,
    point_len: u16 = 0,
    backend: Backend = undefined,
    generation: u32 = 0,
};

const Node = struct {
    used: bool = false,
    mount: u8 = 0,
    ino: u64 = 0,
    stat: Stat = .{},
    refs: u16 = 0,
};

const Handle = struct {
    used: bool = false,
    node: u8 = 0,
    offset: u64 = 0,
    flags: OpenFlags = .{},
};

pub const Vfs = struct {
    mounts: [max_mounts]Mount = [_]Mount{.{}} ** max_mounts,
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    handles: [max_handles]Handle = [_]Handle{.{}} ** max_handles,
    mount_count: u8 = 0,
    generation: u32 = 1,
    reads: u64 = 0,
    lookups: u64 = 0,
    readdirs: u64 = 0,

    pub fn init() Vfs {
        return .{};
    }

    // ------------------------------------------------------------- namespace

    /// Canonicalise a path against `cwd`. The result always starts with `/`,
    /// has no `.`/`..` components and no repeated or trailing slashes. An empty
    /// input is rejected; `"/"` and a relative "." resolve to `cwd`.
    pub fn normalizePath(cwd: []const u8, input: []const u8, out: *[max_path]u8) Error![]const u8 {
        if (input.len == 0) return error.InvalidPath;
        var combined: [max_path * 2]u8 = undefined;
        var combined_len: usize = 0;
        if (input[0] == '/') {
            if (input.len > combined.len) return error.NameTooLong;
            @memcpy(combined[0..input.len], input);
            combined_len = input.len;
        } else {
            if (cwd.len == 0 or cwd[0] != '/') return error.InvalidPath;
            if (cwd.len + 1 + input.len > combined.len) return error.NameTooLong;
            @memcpy(combined[0..cwd.len], cwd);
            combined_len = cwd.len;
            if (combined_len == 0 or combined[combined_len - 1] != '/') {
                combined[combined_len] = '/';
                combined_len += 1;
            }
            @memcpy(combined[combined_len..][0..input.len], input);
            combined_len += input.len;
        }

        var len: usize = 0;
        var i: usize = 0;
        while (i < combined_len) {
            const start = i;
            while (i < combined_len and combined[i] != '/') : (i += 1) {}
            const part = combined[start..i];
            if (i < combined_len) i += 1;

            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (len == 0) continue;
                var slash = len;
                while (slash > 0) : (slash -= 1) {
                    if (out[slash - 1] == '/') break;
                }
                len = if (slash <= 1) 0 else slash - 1;
                continue;
            }
            if (part.len > max_name) return error.NameTooLong;
            if (len + 1 + part.len >= max_path) return error.NameTooLong;
            if (len == 0) {
                out[0] = '/';
                len = 1;
            } else {
                out[len] = '/';
                len += 1;
            }
            @memcpy(out[len..][0..part.len], part);
            len += part.len;
        }
        if (len == 0) {
            out[0] = '/';
            len = 1;
        }
        return out[0..len];
    }

    fn canonicalMount(point: []const u8, out: *[max_path]u8) Error![]const u8 {
        if (point.len == 0 or point[0] != '/') return error.InvalidPath;
        return normalizePath("/", point, out);
    }

    fn mountPointEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (x != y) return false;
        return true;
    }

    fn findMountExact(self: *const Vfs, point: []const u8) ?usize {
        var i: usize = 0;
        while (i < max_mounts) : (i += 1) {
            if (!self.mounts[i].used) continue;
            if (mountPointEql(self.mounts[i].point[0..self.mounts[i].point_len], point)) return i;
        }
        return null;
    }

    /// Longest-prefix mount for a canonical path. A mount point matches only on
    /// a component boundary (`/mnt` matches `/mnt` and `/mnt/a`, not `/mntx`).
    fn findMountForPath(self: *const Vfs, path: []const u8) ?usize {
        var best: ?usize = null;
        var best_len: usize = 0;
        var i: usize = 0;
        while (i < max_mounts) : (i += 1) {
            if (!self.mounts[i].used) continue;
            const point = self.mounts[i].point[0..self.mounts[i].point_len];
            const matches = mountPointEql(point, "/") or
                mountPointEql(path, point) or
                (path.len > point.len and std.mem.startsWith(u8, path, point) and path[point.len] == '/');
            if (matches and point.len >= best_len) {
                best = i;
                best_len = point.len;
            }
        }
        return best;
    }

    fn mountPath(self: *const Vfs, index: usize, canonical: []const u8) []const u8 {
        const point = self.mounts[index].point[0..self.mounts[index].point_len];
        if (mountPointEql(point, "/")) return canonical[1..];
        if (mountPointEql(canonical, point)) return "";
        return canonical[point.len + 1 ..];
    }

    // ----------------------------------------------------------------- mounts

    pub fn mount(self: *Vfs, point: []const u8, backend: Backend) Error!void {
        var canonical_buf: [max_path]u8 = undefined;
        const canonical = try canonicalMount(point, &canonical_buf);
        if (self.findMountExact(canonical) != null) return error.AlreadyMounted;
        if (self.mount_count >= max_mounts) return error.TooManyMounts;

        // Validate the backend root before touching the table. A backend that
        // cannot answer a root stat must not leave a half-mounted entry behind.
        var root_stat: Stat = .{};
        try backend.stat_fn(backend.ctx, backend.root, &root_stat);
        if (root_stat.kind != .directory) return error.NotDirectory;

        if (!mountPointEql(canonical, "/")) {
            const parent_path = parentPath(canonical);
            if (self.findMountForPath(parent_path) == null) return error.NotMounted;
        }

        var slot: usize = 0;
        while (slot < max_mounts and self.mounts[slot].used) : (slot += 1) {}
        if (slot == max_mounts) return error.TooManyMounts;
        self.mounts[slot] = .{
            .used = true,
            .point = [_]u8{0} ** max_path,
            .point_len = @intCast(canonical.len),
            .backend = backend,
            .generation = self.generation,
        };
        @memcpy(self.mounts[slot].point[0..canonical.len], canonical);
        self.mount_count += 1;
        self.generation +%= 1;
    }

    fn parentPath(path: []const u8) []const u8 {
        if (path.len <= 1) return "/";
        var i = path.len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/') {
                if (i == 1) return "/";
                return path[0 .. i - 1];
            }
        }
        return "/";
    }

    pub fn unmount(self: *Vfs, point: []const u8) Error!void {
        var canonical_buf: [max_path]u8 = undefined;
        const canonical = try canonicalMount(point, &canonical_buf);
        const index = self.findMountExact(canonical) orelse return error.NotMounted;

        var h: usize = 0;
        while (h < max_handles) : (h += 1) {
            if (!self.handles[h].used) continue;
            const node = &self.nodes[self.handles[h].node];
            if (node.mount == index) return error.Busy;
        }

        var n: usize = 0;
        while (n < max_nodes) : (n += 1) {
            if (self.nodes[n].used and self.nodes[n].mount == index) self.nodes[n] = .{};
        }
        self.mounts[index] = .{};
        self.mount_count -= 1;
        self.generation +%= 1;
    }

    pub fn mountCount(self: *const Vfs) usize {
        return self.mount_count;
    }

    pub fn mountPointAt(self: *const Vfs, index: usize) ?[]const u8 {
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_mounts) : (i += 1) {
            if (!self.mounts[i].used) continue;
            if (seen == index) return self.mounts[i].point[0..self.mounts[i].point_len];
            seen += 1;
        }
        return null;
    }

    pub fn backendRootAt(self: *const Vfs, index: usize) ?u64 {
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_mounts) : (i += 1) {
            if (!self.mounts[i].used) continue;
            if (seen == index) return self.mounts[i].backend.root;
            seen += 1;
        }
        return null;
    }

    // --------------------------------------------------------------- node table

    fn nodeCount(self: *const Vfs) usize {
        var count: usize = 0;
        for (self.nodes) |node| {
            if (node.used) count += 1;
        }
        return count;
    }

    fn handleCount(self: *const Vfs) usize {
        var count: usize = 0;
        for (self.handles) |h| {
            if (h.used) count += 1;
        }
        return count;
    }

    pub fn stats(self: *const Vfs) struct { mounts: usize, nodes: usize, handles: usize, reads: u64 } {
        return .{ .mounts = self.mount_count, .nodes = nodeCount(self), .handles = handleCount(self), .reads = self.reads };
    }

    fn findNode(self: *Vfs, mount_index: usize, ino: u64) ?usize {
        var i: usize = 0;
        while (i < max_nodes) : (i += 1) {
            if (self.nodes[i].used and self.nodes[i].mount == mount_index and self.nodes[i].ino == ino) return i;
        }
        return null;
    }

    fn nodeForStat(self: *Vfs, mount_index: usize, stat: Stat) Error!usize {
        if (self.findNode(mount_index, stat.ino)) |existing| {
            self.nodes[existing].stat = stat;
            return existing;
        }
        var i: usize = 0;
        while (i < max_nodes) : (i += 1) {
            if (!self.nodes[i].used) {
                self.nodes[i] = .{ .used = true, .mount = @intCast(mount_index), .ino = stat.ino, .stat = stat };
                return i;
            }
        }
        return error.TooManyNodes;
    }

    fn resolveCanonical(self: *Vfs, canonical: []const u8) Error!usize {
        const mount_index = self.findMountForPath(canonical) orelse return error.NotMounted;
        const current_mount = &self.mounts[mount_index];
        const backend = current_mount.backend;
        var current_stat: Stat = .{};
        try backend.stat_fn(backend.ctx, backend.root, &current_stat);
        var node = try self.nodeForStat(mount_index, current_stat);
        const relative = self.mountPath(mount_index, canonical);
        if (relative.len == 0) return node;

        var rest = relative;
        while (rest.len != 0) {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const part = rest[0..slash];
            if (part.len != 0) {
                if (part.len > max_name) return error.NameTooLong;
                if (current_stat.kind != .directory) return error.NotDirectory;
                var child: Stat = .{};
                backend.lookup_fn(backend.ctx, current_stat.ino, part, &child) catch |err| return err;
                self.lookups += 1;
                node = try self.nodeForStat(mount_index, child);
                current_stat = child;
            }
            if (slash == rest.len) break;
            rest = rest[slash + 1 ..];
        }
        return node;
    }

    pub fn resolve(self: *Vfs, path: []const u8, cwd: []const u8) Error!usize {
        var canonical: [max_path]u8 = undefined;
        const normalized = try normalizePath(cwd, path, &canonical);
        return self.resolveCanonical(normalized);
    }

    pub fn statPath(self: *Vfs, path: []const u8, cwd: []const u8) Error!Stat {
        const node = try self.resolve(path, cwd);
        return self.nodes[node].stat;
    }

    pub fn statNode(self: *const Vfs, node: usize) Error!Stat {
        if (node >= max_nodes or !self.nodes[node].used) return error.NotFound;
        return self.nodes[node].stat;
    }

    // ----------------------------------------------------------------- handles

    pub fn open(self: *Vfs, path: []const u8, cwd: []const u8, flags: OpenFlags) Error!u32 {
        if (flags.write) return error.ReadOnly;
        const node = try self.resolve(path, cwd);
        const stat = self.nodes[node].stat;
        if ((stat.mode & 0o444) == 0) return error.AccessDenied;
        if (!flags.read) return error.AccessDenied;
        var h: usize = 0;
        while (h < max_handles) : (h += 1) {
            if (!self.handles[h].used) {
                self.handles[h] = .{ .used = true, .node = @intCast(node), .offset = 0, .flags = flags };
                self.nodes[node].refs += 1;
                return @intCast(h);
            }
        }
        return error.TooManyHandles;
    }

    pub fn close(self: *Vfs, handle: u32) Error!void {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        const node = self.handles[handle].node;
        if (self.nodes[node].refs > 0) self.nodes[node].refs -= 1;
        self.handles[handle] = .{};
    }

    pub fn statHandle(self: *const Vfs, handle: u32) Error!Stat {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        return self.nodes[self.handles[handle].node].stat;
    }

    pub fn readAt(self: *Vfs, handle: u32, offset: u64, out: []u8) Error!usize {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        const h = &self.handles[handle];
        if (!h.flags.read) return error.AccessDenied;
        const node = &self.nodes[h.node];
        if (node.stat.kind != .file) return error.IsDirectory;
        if (offset >= node.stat.size or out.len == 0) return 0;
        const want: usize = @intCast(@min(@as(u64, out.len), node.stat.size - offset));
        const got = try self.mounts[node.mount].backend.read_fn(
            self.mounts[node.mount].backend.ctx,
            node.ino,
            offset,
            out[0..want],
        );
        if (got > want) return error.Backend;
        self.reads += 1;
        return got;
    }

    /// Sequential read: uses and advances the handle's offset. A short read is
    /// returned at EOF; a read at EOF returns 0, never stale bytes.
    pub fn read(self: *Vfs, handle: u32, out: []u8) Error!usize {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        const offset = self.handles[handle].offset;
        const got = try self.readAt(handle, offset, out);
        self.handles[handle].offset += got;
        return got;
    }

    pub fn readdir(self: *Vfs, handle: u32, index: u32, out: *DirEntry) Error!bool {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        const node = &self.nodes[self.handles[handle].node];
        if (node.stat.kind != .directory) return error.NotDirectory;
        const more = try self.mounts[node.mount].backend.readdir_fn(
            self.mounts[node.mount].backend.ctx,
            node.ino,
            index,
            out,
        );
        if (more) self.readdirs += 1;
        return more;
    }
};

// ---------------------------------------------------------------------------
// Host tests: a tiny in-memory backend proves namespace policy and handle
// behaviour independently of any filesystem implementation.
// ---------------------------------------------------------------------------

const TestNode = struct {
    ino: u64 = 0,
    parent: u64 = 0,
    name: []const u8 = "",
    kind: Kind = .file,
    mode: u16 = 0o100644,
    data: []const u8 = "",
};

const TestBackend = struct {
    nodes: []const TestNode,

    fn find(ctx: *anyopaque, ino: u64) ?*const TestNode {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        for (self.nodes) |*node| {
            if (node.ino == ino) return node;
        }
        return null;
    }

    fn statFn(ctx: *anyopaque, ino: u64, out: *Stat) Error!void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        const node = find(self, ino) orelse return error.NotFound;
        out.* = .{
            .ino = node.ino,
            .parent = node.parent,
            .kind = node.kind,
            .size = node.data.len,
            .mode = node.mode,
        };
    }

    fn lookupFn(ctx: *anyopaque, parent: u64, name: []const u8, out: *Stat) Error!void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        for (self.nodes) |*node| {
            if (node.parent == parent and std.mem.eql(u8, node.name, name)) return statFn(ctx, node.ino, out);
        }
        return error.NotFound;
    }

    fn readFn(ctx: *anyopaque, ino: u64, offset: u64, out: []u8) Error!usize {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        const node = find(self, ino) orelse return error.NotFound;
        if (offset >= node.data.len) return 0;
        const n: usize = @intCast(@min(@as(u64, out.len), node.data.len - offset));
        @memcpy(out[0..n], node.data[@intCast(offset)..][0..n]);
        return n;
    }

    fn readdirFn(ctx: *anyopaque, ino: u64, index: u32, out: *DirEntry) Error!bool {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        var seen: u32 = 0;
        for (self.nodes) |*node| {
            if (node.parent != ino or node.ino == ino) continue;
            if (seen == index) {
                out.* = .{ .ino = node.ino, .parent = node.parent, .kind = node.kind, .size = node.data.len };
                const n = @min(node.name.len, max_name);
                @memcpy(out.name[0..n], node.name[0..n]);
                out.name_len = @intCast(n);
                return true;
            }
            seen += 1;
        }
        return false;
    }

    fn backend(self: *TestBackend) Backend {
        return .{
            .ctx = self,
            .root = 1,
            .stat_fn = statFn,
            .lookup_fn = lookupFn,
            .read_fn = readFn,
            .readdir_fn = readdirFn,
        };
    }
};

const test_nodes = [_]TestNode{
    .{ .ino = 1, .parent = 0, .kind = .directory, .mode = 0o040755 },
    .{ .ino = 2, .parent = 1, .name = "catalog", .kind = .directory, .mode = 0o040755 },
    .{ .ino = 3, .parent = 2, .name = "products.db", .kind = .file, .data = "sku,price\n1001,250\n" },
    .{ .ino = 4, .parent = 1, .name = "receipts", .kind = .directory, .mode = 0o040755 },
    .{ .ino = 5, .parent = 4, .name = "welcome.txt", .kind = .file, .data = "hello\n" },
    .{ .ino = 6, .parent = 1, .name = "secret", .kind = .file, .mode = 0o100000, .data = "no\n" },
};

fn testVfs() struct { vfs: Vfs, backend: TestBackend } {
    return .{ .vfs = .{}, .backend = .{ .nodes = &test_nodes } };
}

test "path normalization is canonical for absolute, relative and dot-dot" {
    var out: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("/a/b", try Vfs.normalizePath("/", "a/b", &out));
    try std.testing.expectEqualStrings("/catalog/products.db", try Vfs.normalizePath("/", "//catalog///products.db/", &out));
    try std.testing.expectEqualStrings("/", try Vfs.normalizePath("/", "/", &out));
    try std.testing.expectEqualStrings("/", try Vfs.normalizePath("/", "///", &out));
    try std.testing.expectEqualStrings("/receipts", try Vfs.normalizePath("/catalog", "../receipts", &out));
    try std.testing.expectEqualStrings("/", try Vfs.normalizePath("/a/b", "../../..", &out));
    try std.testing.expectEqualStrings("/catalog", try Vfs.normalizePath("/catalog", ".", &out));
    try std.testing.expectError(error.InvalidPath, Vfs.normalizePath("/", "", &out));
    try std.testing.expectError(error.InvalidPath, Vfs.normalizePath("", "relative", &out));
    const too_long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.NameTooLong, Vfs.normalizePath("/", too_long, &out));
}

test "mount table rejects duplicates and failed backends without half state" {
    var state = testVfs();
    try state.vfs.mount("/", state.backend.backend());
    try std.testing.expectEqual(@as(usize, 1), state.vfs.mountCount());
    try std.testing.expectError(error.AlreadyMounted, state.vfs.mount("/", state.backend.backend()));
    try std.testing.expectError(error.InvalidPath, state.vfs.mount("relative", state.backend.backend()));
    const bad = Backend{
        .ctx = &state.backend,
        .root = 99,
        .stat_fn = TestBackend.statFn,
        .lookup_fn = TestBackend.lookupFn,
        .read_fn = TestBackend.readFn,
        .readdir_fn = TestBackend.readdirFn,
    };
    try std.testing.expectError(error.NotFound, state.vfs.mount("/mnt", bad));
    try std.testing.expectEqual(@as(usize, 1), state.vfs.mountCount());
}

test "mount failure does not add a table entry" {
    var state = testVfs();
    const bad = Backend{
        .ctx = &state.backend,
        .root = 99,
        .stat_fn = TestBackend.statFn,
        .lookup_fn = TestBackend.lookupFn,
        .read_fn = TestBackend.readFn,
        .readdir_fn = TestBackend.readdirFn,
    };
    try std.testing.expectError(error.NotFound, state.vfs.mount("/", bad));
    try std.testing.expectEqual(@as(usize, 0), state.vfs.mountCount());
}

test "root lookup, relative paths and dot-dot at root" {
    var state = testVfs();
    try state.vfs.mount("/", state.backend.backend());
    const root = try state.vfs.statPath("/", "/");
    try std.testing.expectEqual(@as(u64, 1), root.ino);
    try std.testing.expectEqual(Kind.directory, root.kind);
    const file = try state.vfs.statPath("../catalog/products.db", "/receipts/..");
    try std.testing.expectEqual(@as(u64, 3), file.ino);
    try std.testing.expectEqual(@as(u64, 2), file.parent);
    const again = try state.vfs.statPath("../../../../", "/catalog");
    try std.testing.expectEqual(@as(u64, 1), again.ino);
    try std.testing.expectError(error.NotFound, state.vfs.statPath("/missing", "/"));
}

test "open/close, offsets, short EOF and read-only checks" {
    var state = testVfs();
    try state.vfs.mount("/", state.backend.backend());
    const h = try state.vfs.open("/catalog/products.db", "/", .{});
    var four: [4]u8 = undefined;
    var eight: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try state.vfs.readAt(h, 4, &four));
    try std.testing.expectEqualStrings("pric", &four);
    try std.testing.expectEqual(@as(usize, 0), try state.vfs.readAt(h, 999, &four));
    try std.testing.expectEqual(@as(usize, 4), try state.vfs.read(h, &four));
    try std.testing.expectEqualStrings("sku,", &four);
    try std.testing.expectEqual(@as(usize, 8), try state.vfs.read(h, &eight));
    try std.testing.expectEqualStrings("price\n10", &eight);
    try std.testing.expectEqual(@as(usize, 7), try state.vfs.read(h, &eight));
    try std.testing.expectEqualStrings("01,250\n", eight[0..7]);
    try std.testing.expectEqual(@as(usize, 0), try state.vfs.read(h, &eight));
    try std.testing.expectError(error.ReadOnly, state.vfs.open("/catalog/products.db", "/", .{ .write = true }));
    try std.testing.expectError(error.AccessDenied, state.vfs.open("/secret", "/", .{}));
    try state.vfs.close(h);
    try std.testing.expectError(error.BadHandle, state.vfs.read(h, &eight));
}

test "readdir is ordered, files refuse it, and directories refuse read" {
    var state = testVfs();
    try state.vfs.mount("/", state.backend.backend());
    const h = try state.vfs.open("/", "/", .{});
    var entry: DirEntry = .{};
    try std.testing.expect(try state.vfs.readdir(h, 0, &entry));
    try std.testing.expectEqualStrings("catalog", entry.nameSlice());
    try std.testing.expectEqual(Kind.directory, entry.kind);
    try std.testing.expect(try state.vfs.readdir(h, 1, &entry));
    try std.testing.expectEqualStrings("receipts", entry.nameSlice());
    try std.testing.expect(try state.vfs.readdir(h, 2, &entry));
    try std.testing.expectEqualStrings("secret", entry.nameSlice());
    try std.testing.expect(!try state.vfs.readdir(h, 3, &entry));
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.IsDirectory, state.vfs.read(h, &byte));

    const f = try state.vfs.open("/catalog/products.db", "/", .{});
    try std.testing.expectError(error.NotDirectory, state.vfs.readdir(f, 0, &entry));
    try state.vfs.close(f);
    try state.vfs.close(h);

    const root = try state.vfs.open("/", "/", .{});
    try std.testing.expectError(error.Busy, state.vfs.unmount("/"));
    try state.vfs.close(root);
    try state.vfs.unmount("/");
    try std.testing.expectEqual(@as(usize, 0), state.vfs.mountCount());
}

test "a longer mount shadows its subtree and unmount restores the parent" {
    var state = testVfs();
    try state.vfs.mount("/", state.backend.backend());
    var second = TestBackend{ .nodes = &test_nodes };
    try state.vfs.mount("/catalog", second.backend());
    const nested = try state.vfs.statPath("/catalog/receipts/welcome.txt", "/");
    try std.testing.expectEqual(@as(u64, 5), nested.ino);
    try state.vfs.unmount("/catalog");
    const parent = try state.vfs.statPath("/catalog/products.db", "/");
    try std.testing.expectEqual(@as(u64, 3), parent.ino);
    try std.testing.expectEqual(@as(usize, 1), state.vfs.mountCount());
}
