//! A small, backend-neutral VFS (phases 42-46).
//!
//! This module owns the namespace policy, node/handle tables, advisory locks and
//! the change-notification queue. Filesystems plug in through `Backend`
//! callbacks, so CASSAFS, FAT32 and tmpfs share one path resolver and one access
//! policy. Mounts are longest-prefix mappings; a mount at `/` is the normal
//! case, and a mount at `/media/usb` shadows only that subtree.
//!
//! Permissions are the traditional mode bits on `Stat.mode`; the VFS enforces
//! read/write bits before it asks a backend for a handle. A writable backend may
//! provide `chmod_fn` and `mkdir_fn`; read-only backends leave them null and the
//! VFS returns `Unsupported` or `ReadOnly` without guessing.

const std = @import("std");

pub const max_path = 255;
pub const max_name = 63;
pub const max_mounts = 8;
pub const max_nodes = 128;
pub const max_handles = 32;
pub const max_watches = 8;
pub const max_events = 16;

pub const Kind = enum { file, directory };

pub const LockMode = enum { shared, exclusive };

pub const EventKind = enum { created, modified, mounted, unmounted };

pub const Event = struct {
    seq: u64 = 0,
    kind: EventKind = .created,
    path: [max_path]u8 = [_]u8{0} ** max_path,
    path_len: u16 = 0,

    pub fn pathSlice(self: *const Event) []const u8 {
        return self.path[0..self.path_len];
    }
};

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
    NoSpace,
    Exists,
    Unsupported,
    Backend,
    Corrupt,
    LockConflict,
    NotLocked,
    AlreadyLocked,
    TooManyWatches,
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
    create: bool = false,
};

pub const WriteResult = struct {
    written: usize,
    stat: Stat,
};

/// A filesystem backend. `root` is the backend inode used for the mount point.
/// `readdir` must be stable: index 0 is the first child and repeated calls with
/// the same index return the same entry until the backend changes.
pub const Backend = struct {
    ctx: *anyopaque,
    root: u64,
    writable: bool = false,
    stat_fn: *const fn (ctx: *anyopaque, ino: u64, out: *Stat) Error!void,
    lookup_fn: *const fn (ctx: *anyopaque, parent: u64, name: []const u8, out: *Stat) Error!void,
    read_fn: *const fn (ctx: *anyopaque, ino: u64, offset: u64, out: []u8) Error!usize,
    readdir_fn: *const fn (ctx: *anyopaque, ino: u64, index: u32, out: *DirEntry) Error!bool,
    create_fn: *const fn (ctx: *anyopaque, parent: u64, name: []const u8, mode: u16) Error!Stat,
    write_fn: *const fn (ctx: *anyopaque, ino: u64, offset: u64, data: []const u8) Error!WriteResult,
    /// Optional operations. A read-only backend leaves them null; a writable
    /// backend that does not implement a capability returns `Unsupported`.
    mkdir_fn: ?*const fn (ctx: *anyopaque, parent: u64, name: []const u8, mode: u16) Error!Stat = null,
    chmod_fn: ?*const fn (ctx: *anyopaque, ino: u64, mode: u16) Error!void = null,
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
    lock: ?LockMode = null,
    path: [max_path]u8 = [_]u8{0} ** max_path,
    path_len: u16 = 0,

    fn pathSlice(self: *const Handle) []const u8 {
        return self.path[0..self.path_len];
    }
};

const Watch = struct {
    used: bool = false,
    id: u32 = 0,
    path: [max_path]u8 = [_]u8{0} ** max_path,
    path_len: u16 = 0,

    fn pathSlice(self: *const Watch) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const Vfs = struct {
    mounts: [max_mounts]Mount = [_]Mount{.{}} ** max_mounts,
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    handles: [max_handles]Handle = [_]Handle{.{}} ** max_handles,
    watches: [max_watches]Watch = [_]Watch{.{}} ** max_watches,
    events: [max_events]Event = [_]Event{.{}} ** max_events,
    event_head: u8 = 0,
    event_count: u8 = 0,
    event_seq: u64 = 0,
    events_dropped: u64 = 0,
    watch_counter: u32 = 0,
    mount_count: u8 = 0,
    generation: u32 = 1,
    reads: u64 = 0,
    writes: u64 = 0,
    lookups: u64 = 0,
    readdirs: u64 = 0,
    locks_held: u32 = 0,

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
        self.notify(.mounted, canonical);
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
        self.notify(.unmounted, canonical);
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

    pub const Stats = struct {
        mounts: usize,
        nodes: usize,
        handles: usize,
        reads: u64,
        writes: u64,
        locks: u32,
        watches: usize,
        pending_events: usize,
        dropped_events: u64,
    };

    pub fn stats(self: *const Vfs) Stats {
        var watches: usize = 0;
        for (self.watches) |entry| if (entry.used) {
            watches += 1;
        };
        return .{
            .mounts = self.mount_count,
            .nodes = nodeCount(self),
            .handles = handleCount(self),
            .reads = self.reads,
            .writes = self.writes,
            .locks = self.locks_held,
            .watches = watches,
            .pending_events = self.event_count,
            .dropped_events = self.events_dropped,
        };
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

    fn freeHandle(self: *const Vfs) ?usize {
        var h: usize = 0;
        while (h < max_handles) : (h += 1) {
            if (!self.handles[h].used) return h;
        }
        return null;
    }

    fn openNode(self: *Vfs, node_index: usize, flags: OpenFlags, canonical: []const u8) Error!u32 {
        const stat = self.nodes[node_index].stat;
        const backend = &self.mounts[self.nodes[node_index].mount].backend;
        if (flags.write) {
            if (!backend.writable) return error.ReadOnly;
            if (stat.kind != .file) return error.IsDirectory;
            if ((stat.mode & 0o222) == 0) return error.AccessDenied;
        }
        if (flags.read and (stat.mode & 0o444) == 0) return error.AccessDenied;
        if (!flags.read and !flags.write) return error.AccessDenied;
        if (canonical.len > max_path) return error.NameTooLong;
        const h = self.freeHandle() orelse return error.TooManyHandles;
        self.handles[h] = .{
            .used = true,
            .node = @intCast(node_index),
            .offset = 0,
            .flags = flags,
            .path_len = @intCast(canonical.len),
        };
        @memcpy(self.handles[h].path[0..canonical.len], canonical);
        self.nodes[node_index].refs += 1;
        return @intCast(h);
    }

    const ParentSplit = struct {
        parent: []const u8,
        name: []const u8,
    };

    fn splitParent(canonical: []const u8) ParentSplit {
        var i = canonical.len;
        while (i > 0) : (i -= 1) {
            if (canonical[i - 1] == '/') break;
        }
        if (i <= 1) return .{ .parent = "/", .name = canonical[1..] };
        return .{ .parent = canonical[0 .. i - 1], .name = canonical[i..] };
    }

    fn createOpen(self: *Vfs, canonical: []const u8, flags: OpenFlags) Error!u32 {
        if (canonical.len <= 1) return error.IsDirectory;
        const split = splitParent(canonical);
        if (split.name.len == 0) return error.InvalidPath;
        if (split.name.len > max_name) return error.NameTooLong;
        const parent_node = try self.resolveCanonical(split.parent);
        const parent_stat = self.nodes[parent_node].stat;
        if (parent_stat.kind != .directory) return error.NotDirectory;
        const mount_index = self.nodes[parent_node].mount;
        const backend = &self.mounts[mount_index].backend;
        if (!backend.writable) return error.ReadOnly;
        if (self.freeHandle() == null) return error.TooManyHandles;
        // Reserve a node slot before creating so a full table cannot leave a
        // newly-created file without a VFS node.
        if (self.freeNodeSlot() == null) return error.TooManyNodes;
        const st = try backend.create_fn(backend.ctx, parent_stat.ino, split.name, 0o100644);
        const node = try self.nodeForStat(mount_index, st);
        const h = self.freeHandle() orelse return error.TooManyHandles;
        self.handles[h] = .{
            .used = true,
            .node = @intCast(node),
            .offset = 0,
            .flags = flags,
            .path_len = @intCast(canonical.len),
        };
        @memcpy(self.handles[h].path[0..canonical.len], canonical);
        self.nodes[node].refs += 1;
        self.notify(.created, canonical);
        return @intCast(h);
    }

    fn freeNodeSlot(self: *const Vfs) ?usize {
        var i: usize = 0;
        while (i < max_nodes) : (i += 1) {
            if (!self.nodes[i].used) return i;
        }
        return null;
    }

    pub fn open(self: *Vfs, path: []const u8, cwd: []const u8, flags: OpenFlags) Error!u32 {
        var canonical_buf: [max_path]u8 = undefined;
        const canonical = try normalizePath(cwd, path, &canonical_buf);
        if (flags.create) {
            if (!flags.write) return error.AccessDenied;
            if (self.resolveCanonical(canonical)) |node| {
                return self.openNode(node, flags, canonical);
            } else |err| {
                if (err != error.NotFound) return err;
                return self.createOpen(canonical, flags);
            }
        }
        const node = try self.resolveCanonical(canonical);
        return self.openNode(node, flags, canonical);
    }

    pub fn close(self: *Vfs, handle: u32) Error!void {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        if (self.handles[handle].lock != null) self.locks_held -= 1;
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

    pub fn writeAt(self: *Vfs, handle: u32, offset: u64, data: []const u8) Error!usize {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        const h = &self.handles[handle];
        if (!h.flags.write) return error.AccessDenied;
        const node = &self.nodes[h.node];
        if (node.stat.kind != .file) return error.IsDirectory;
        const backend = &self.mounts[node.mount].backend;
        if (!backend.writable) return error.ReadOnly;
        if ((node.stat.mode & 0o222) == 0) return error.AccessDenied;
        const result = try backend.write_fn(backend.ctx, node.ino, offset, data);
        node.stat = result.stat;
        self.writes += 1;
        if (result.written != 0) self.notify(.modified, h.pathSlice());
        return result.written;
    }

    /// Sequential write: uses and advances the handle's offset.
    pub fn write(self: *Vfs, handle: u32, data: []const u8) Error!usize {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        const offset = self.handles[handle].offset;
        const got = try self.writeAt(handle, offset, data);
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

    // ----------------------------------------------------------- permissions

    /// Change permission bits on a writable backend that implements chmod.
    /// The file type bits are preserved by the backend; callers pass 0o755 etc.
    pub fn chmod(self: *Vfs, path: []const u8, cwd: []const u8, mode: u16) Error!Stat {
        const node_index = try self.resolve(path, cwd);
        const node = &self.nodes[node_index];
        const backend = &self.mounts[node.mount].backend;
        if (!backend.writable) return error.ReadOnly;
        const chmod_fn = backend.chmod_fn orelse return error.Unsupported;
        try chmod_fn(backend.ctx, node.ino, mode);
        var refreshed: Stat = .{};
        try backend.stat_fn(backend.ctx, node.ino, &refreshed);
        node.stat = refreshed;
        return refreshed;
    }

    // ---------------------------------------------------------------- mkdir

    pub fn mkdir(self: *Vfs, path: []const u8, cwd: []const u8, mode: u16) Error!Stat {
        var canonical_buf: [max_path]u8 = undefined;
        const canonical = try normalizePath(cwd, path, &canonical_buf);
        if (canonical.len <= 1) return error.Exists;
        const split = splitParent(canonical);
        if (split.name.len == 0 or split.name.len > max_name) return error.InvalidPath;
        const parent_node = try self.resolveCanonical(split.parent);
        const parent_stat = self.nodes[parent_node].stat;
        if (parent_stat.kind != .directory) return error.NotDirectory;
        if (self.resolveCanonical(canonical)) |_| return error.Exists else |err| {
            if (err != error.NotFound) return err;
        }
        const mount_index = self.nodes[parent_node].mount;
        const backend = &self.mounts[mount_index].backend;
        if (!backend.writable) return error.ReadOnly;
        const mkdir_fn = backend.mkdir_fn orelse return error.Unsupported;
        if (self.freeNodeSlot() == null) return error.TooManyNodes;
        const st = try mkdir_fn(backend.ctx, parent_stat.ino, split.name, mode & 0o7777);
        _ = try self.nodeForStat(mount_index, st);
        self.notify(.created, canonical);
        return st;
    }

    // --------------------------------------------------------------- locking

    /// Advisory whole-file locks. Shared locks may coexist; any exclusive lock
    /// conflicts with every other lock on the same node. The lock follows the
    /// handle and is released by close/unmount (handles already block unmount).
    pub fn lock(self: *Vfs, handle: u32, mode: LockMode) Error!void {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        if (self.handles[handle].lock != null) return error.AlreadyLocked;
        const node_index = self.handles[handle].node;
        for (self.handles) |other| {
            if (!other.used or other.node != node_index or other.lock == null) continue;
            if (mode == .exclusive or other.lock.? == .exclusive) return error.LockConflict;
        }
        self.handles[handle].lock = mode;
        self.locks_held += 1;
    }

    pub fn unlock(self: *Vfs, handle: u32) Error!void {
        if (handle >= max_handles or !self.handles[handle].used) return error.BadHandle;
        if (self.handles[handle].lock == null) return error.NotLocked;
        self.handles[handle].lock = null;
        self.locks_held -= 1;
    }

    pub fn lockMode(self: *const Vfs, handle: u32) ?LockMode {
        if (handle >= max_handles or !self.handles[handle].used) return null;
        return self.handles[handle].lock;
    }

    // ------------------------------------------------------- change events

    /// Register a watch on an existing path. A directory watch covers its whole
    /// subtree; a file watch matches only that file. Events are queued in a
    /// bounded ring, so a slow consumer loses old events rather than RAM.
    pub fn watch(self: *Vfs, path: []const u8, cwd: []const u8) Error!u32 {
        var canonical_buf: [max_path]u8 = undefined;
        const canonical = try normalizePath(cwd, path, &canonical_buf);
        _ = try self.resolveCanonical(canonical);
        var slot: usize = 0;
        while (slot < max_watches and self.watches[slot].used) : (slot += 1) {}
        if (slot == max_watches) return error.TooManyWatches;
        self.watch_counter +%= 1;
        if (self.watch_counter == 0) self.watch_counter = 1;
        self.watches[slot] = .{
            .used = true,
            .id = self.watch_counter,
            .path_len = @intCast(canonical.len),
        };
        @memcpy(self.watches[slot].path[0..canonical.len], canonical);
        return self.watch_counter;
    }

    pub fn unwatch(self: *Vfs, id: u32) Error!void {
        for (&self.watches) |*entry| {
            if (entry.used and entry.id == id) {
                entry.* = .{};
                return;
            }
        }
        return error.NotFound;
    }

    /// Pop the oldest queued event. Returns false when the queue is empty.
    pub fn nextEvent(self: *Vfs, out: *Event) bool {
        if (self.event_count == 0) return false;
        out.* = self.events[self.event_head];
        self.event_head = (self.event_head + 1) % max_events;
        self.event_count -= 1;
        return true;
    }

    pub fn pendingEvents(self: *const Vfs) usize {
        return self.event_count;
    }

    fn watchMatches(watch_path: []const u8, event_path: []const u8) bool {
        if (std.mem.eql(u8, watch_path, event_path)) return true;
        if (std.mem.eql(u8, watch_path, "/")) return event_path.len > 1 and event_path[0] == '/';
        return event_path.len > watch_path.len and
            std.mem.startsWith(u8, event_path, watch_path) and
            event_path[watch_path.len] == '/';
    }

    fn notify(self: *Vfs, kind: EventKind, path: []const u8) void {
        var watched = false;
        for (self.watches) |entry| {
            if (entry.used and watchMatches(entry.pathSlice(), path)) {
                watched = true;
                break;
            }
        }
        if (!watched) return;

        self.event_seq +%= 1;
        const event = Event{
            .seq = self.event_seq,
            .kind = kind,
            .path_len = @intCast(@min(path.len, max_path)),
        };
        var stored = event;
        @memcpy(stored.path[0..stored.path_len], path[0..stored.path_len]);
        if (self.event_count == max_events) {
            self.events[self.event_head] = stored;
            self.event_head = (self.event_head + 1) % max_events;
            self.events_dropped += 1;
        } else {
            const index = (self.event_head + self.event_count) % max_events;
            self.events[index] = stored;
            self.event_count += 1;
        }
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

    fn createFn(_: *anyopaque, _: u64, _: []const u8, _: u16) Error!Stat {
        return error.Unsupported;
    }

    fn writeFn(_: *anyopaque, _: u64, _: u64, _: []const u8) Error!WriteResult {
        return error.Unsupported;
    }

    fn backend(self: *TestBackend) Backend {
        return .{
            .ctx = self,
            .root = 1,
            .writable = false,
            .stat_fn = statFn,
            .lookup_fn = lookupFn,
            .read_fn = readFn,
            .readdir_fn = readdirFn,
            .create_fn = createFn,
            .write_fn = writeFn,
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
        .create_fn = TestBackend.createFn,
        .write_fn = TestBackend.writeFn,
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
        .create_fn = TestBackend.createFn,
        .write_fn = TestBackend.writeFn,
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
