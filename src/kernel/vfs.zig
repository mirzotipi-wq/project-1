//! Kernel VFS front end (phase 42).
//!
//! The namespace policy, mount table, node table and handles live in
//! `src/lib/vfs.zig`. This file owns the kernel front end and shell surface:
//! CASSAFS on partition 1 at `/`, the read-only FAT32 reader on partition 2 at
//! `/media/usb`, stat, directory iteration, range reads, catalog import and a
//! failure-mode self-test.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");
const fb = @import("fb.zig");
const sched = @import("sched.zig");
const block_view = @import("block_view.zig");
const cassafs = @import("cassafs.zig");
const cassafs_lib = @import("../lib/cassafs.zig");
const cassafs_vfs = @import("../lib/cassafs_vfs.zig");
const fat32 = @import("fat32.zig");
const fat32_vfs = @import("../lib/fat32_vfs.zig");
const catalog_csv = @import("../lib/catalog_csv.zig");
const partition = @import("partition.zig");
const vfs = @import("../lib/vfs.zig");
const tmpfs = @import("../lib/tmpfs.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

var g_vfs: vfs.Vfs = .{};
var g_adapter: cassafs_vfs.Adapter = undefined;
var g_source: cassafs.MountSource = undefined;
var g_fat_adapter: fat32_vfs.Adapter = undefined;
var g_fat_volume: fat32.Volume = undefined;
var g_fat_table: partition.Table = .{};
var g_root_mounted = false;
var g_usb_mounted = false;
var g_tmpfs_mounted = false;
var g_tmpfs: tmpfs.Fs = .{};
var import_buf: [4096]u8 = undefined;

const demo_catalog = "sku,name,price_cents\n1001,Espresso,250\n1002,Croissant,180\n1003,Water,150\n";
const demo_welcome = "Welcome to Cassa POS.\nThis volume was formatted by the phase 41 reference formatter.\n";

fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "no such file or directory",
        error.NotDirectory => "not a directory",
        error.IsDirectory => "is a directory",
        error.AccessDenied => "permission denied",
        error.ReadOnly => "this filesystem is read-only",
        error.NoSpace => "out of space (free map, inode table or record budget)",
        error.Exists => "file already exists",
        error.Unsupported => "operation is not supported by this backend",
        error.NotMounted => "no CASSAFS volume is mounted; run 'vfs mount'",
        error.Busy => "volume is busy; close every open handle first",
        error.BadHandle => "invalid file handle",
        error.Corrupt => "integrity failure (CRC32C or inode/extent corruption)",
        error.NameTooLong => "path or name is too long",
        error.InvalidPath => "invalid path (empty paths are rejected)",
        error.LockConflict => "another handle holds a conflicting lock",
        error.NotLocked => "this handle does not hold a lock",
        error.AlreadyLocked => "this handle already holds a lock",
        error.TooManyWatches => "the watch table is full",
        else => @errorName(err),
    };
}

fn printReason(err: anyerror) void {
    out("  {s}\n", .{reason(err)});
}

fn printError(err: anyerror) void {
    out("  vfs         : {s}\n", .{reason(err)});
}

fn canonicalPath(path: []const u8, buf: *[vfs.max_path]u8) []const u8 {
    return vfs.Vfs.normalizePath("/", path, buf) catch path;
}

pub fn mounted() bool {
    return g_root_mounted;
}

/// Narrow file API for kernel subsystems that own their own format logic (the
/// phase-47 retail store is the first). Paths are always resolved against the
/// VFS root and every operation goes through the same permissions, cache and
/// backend callbacks as the shell commands.
pub fn fileOpen(path: []const u8, flags: vfs.OpenFlags) vfs.Error!u32 {
    if (!g_root_mounted) return error.NotMounted;
    return g_vfs.open(path, "/", flags);
}

pub fn fileClose(handle: u32) void {
    g_vfs.close(handle) catch {};
}

pub fn fileStat(handle: u32) vfs.Error!vfs.Stat {
    return g_vfs.statHandle(handle);
}

pub fn fileReadAt(handle: u32, offset: u64, dest: []u8) vfs.Error!usize {
    return g_vfs.readAt(handle, offset, dest);
}

pub fn fileWriteAt(handle: u32, offset: u64, data: []const u8) vfs.Error!usize {
    return g_vfs.writeAt(handle, offset, data);
}

/// Commit every dirty CASSAFS page before a caller acknowledges a durable
/// transaction. Phase 48 uses this as the `fsync` boundary for its sale log.
pub fn flushCache() !void {
    if (!g_root_mounted) return error.NotMounted;
    try cassafs.flushMountCache();
}

pub fn mount() bool {
    if (mounted()) {
        out("  vfs mount   : refused: / is already mounted\n", .{});
        return false;
    }
    const source = cassafs.mountVolume() catch |err| {
        out("  vfs mount   : refused (no table entry was created)\n", .{});
        cassafs.explain(err);
        return false;
    };
    g_adapter = cassafs_vfs.Adapter.init(source.device, source.report, source.workspace, source.inode_storage);
    g_vfs.mount("/", g_adapter.backend()) catch |err| {
        out("  vfs mount   : refused by the VFS (no table entry was created): {s}\n", .{@errorName(err)});
        return false;
    };
    g_source = source;
    g_root_mounted = true;
    const report = source.report;
    out("  vfs mount   : / <- cassafs, format {d}, {d} inode(s), {d} file(s), {d} data byte(s), active {s}{s}\n", .{
        report.format_version,                 report.inode_count,                             report.files, report.data_bytes,
        if (report.active == .a) "A" else "B", if (report.fallback) " (A/B fallback)" else "",
    });
    out("  vfs mount   : mount table {d}/1, node table 0/{d}, open handles 0/{d}\n", .{
        g_vfs.mountCount(), vfs.max_nodes, vfs.max_handles,
    });
    return true;
}

pub fn unmount() bool {
    if (!mounted()) {
        out("  vfs unmount : refused: nothing is mounted\n", .{});
        return false;
    }
    if (g_usb_mounted or g_tmpfs_mounted) {
        out("  vfs unmount : refused: a child mount is still mounted; unmount it first\n", .{});
        return false;
    }
    // The page cache is write-back: unmount must push every dirty page before
    // it is allowed to forget the mount. A failed flush is a refusal, not a
    // silent loss of bytes that the mounted view already accepted.
    cassafs.flushMountCache() catch |err| {
        out("  vfs unmount : refused: page-cache flush failed: {s}\n", .{@errorName(err)});
        return false;
    };
    g_vfs.unmount("/") catch |err| {
        if (err == error.Busy) {
            out("  vfs unmount : refused: open handles still reference the volume\n", .{});
        } else {
            printError(err);
        }
        return false;
    };
    cassafs.invalidateMountCache();
    g_root_mounted = false;
    out("  vfs unmount : / removed and page cache flushed; mount table 0/1, no dangling nodes or handles\n", .{});
    return true;
}

/// Attach the read-only FAT32 reader to partition 2 at `/media/usb`. The plan's
/// "vendor USB stick" is represented by a second partition until USB mass
/// storage lands; the reader itself is the same BPB/LFN/cluster-chain path a
/// real stick uses. The mount is refused, with no table entry, unless the BPB,
/// FAT geometry and root directory validate.
pub fn mountUsb() bool {
    if (!mounted()) {
        out("  vfs mount   : refused: mount the CASSAFS root at / first\n", .{});
        return false;
    }
    if (g_usb_mounted) {
        out("  vfs mount   : refused: /media/usb is already mounted\n", .{});
        return false;
    }
    partition.read(.{}, &g_fat_table) catch |err| {
        out("  vfs mount   : refused: partition table unreadable: {s}\n", .{@errorName(err)});
        return false;
    };
    if (g_fat_table.count < 2) {
        out("  vfs mount   : refused: no FAT32 partition 2 on this disk\n", .{});
        return false;
    }
    const entry = &g_fat_table.entries[1];
    const view = block_view.View.fromPartition(entry) catch |err| {
        out("  vfs mount   : refused: partition 2 lies outside the disk: {s}\n", .{@errorName(err)});
        return false;
    };
    g_fat_volume = fat32.mount(view) catch |err| {
        out("  vfs mount   : refused: partition 2 is not a mountable FAT32: {s}\n", .{@errorName(err)});
        return false;
    };
    _ = g_fat_volume.list() catch |err| {
        out("  vfs mount   : refused: FAT32 root directory is unreadable: {s}\n", .{@errorName(err)});
        return false;
    };
    g_fat_adapter = fat32_vfs.Adapter.init(&g_fat_volume);
    g_vfs.mount("/media/usb", g_fat_adapter.backend()) catch |err| {
        out("  vfs mount   : refused by the VFS (no table entry was created): {s}\n", .{@errorName(err)});
        return false;
    };
    g_usb_mounted = true;
    const geo = g_fat_volume.geo;
    out("  vfs mount   : /media/usb <- fat32, read-only, partition 2 LBA {d}..{d}, {d} B/cluster, {d} cluster(s), root {d}\n", .{
        entry.first_lba, entry.last_lba, geo.cluster_bytes, geo.clusters, geo.root_cluster,
    });
    out("  vfs mount   : mount table {d}/8, node table {d}/{d}, open handles {d}/{d}\n", .{
        g_vfs.mountCount(), g_vfs.stats().nodes, vfs.max_nodes, g_vfs.stats().handles, vfs.max_handles,
    });
    return true;
}

pub fn unmountUsb() bool {
    if (!g_usb_mounted) {
        out("  vfs unmount : refused: /media/usb is not mounted\n", .{});
        return false;
    }
    g_vfs.unmount("/media/usb") catch |err| {
        if (err == error.Busy) {
            out("  vfs unmount : refused: open handles still reference /media/usb\n", .{});
        } else {
            printError(err);
        }
        return false;
    };
    g_usb_mounted = false;
    out("  vfs unmount : /media/usb removed; mount table {d}/8, no dangling nodes or handles\n", .{g_vfs.mountCount()});
    return true;
}

/// Attach the bounded in-memory scratch filesystem at `/tmp`. It is writable,
/// volatile by design and has no block device behind it; the VFS path resolver,
/// permission checks, locks and watches are identical to the persistent mounts.
fn mountTmpfs() bool {
    if (!mounted()) {
        out("  vfs mount   : refused: mount the CASSAFS root at / first\n", .{});
        return false;
    }
    if (g_tmpfs_mounted) {
        out("  vfs mount   : refused: /tmp is already mounted\n", .{});
        return false;
    }
    g_tmpfs.reset();
    g_vfs.mount("/tmp", g_tmpfs.backend()) catch |err| {
        out("  vfs mount   : refused by the VFS (no table entry was created): {s}\n", .{@errorName(err)});
        return false;
    };
    g_tmpfs_mounted = true;
    out("  vfs mount   : /tmp <- tmpfs, writable scratch, {d} node(s), {d} B/file, volatile\n", .{
        tmpfs.max_nodes, tmpfs.max_file_bytes,
    });
    out("  vfs mount   : mount table {d}/8, node table {d}/{d}, open handles {d}/{d}\n", .{
        g_vfs.mountCount(), g_vfs.stats().nodes, vfs.max_nodes, g_vfs.stats().handles, vfs.max_handles,
    });
    return true;
}

fn unmountTmpfs() bool {
    if (!g_tmpfs_mounted) {
        out("  vfs unmount : refused: /tmp is not mounted\n", .{});
        return false;
    }
    g_vfs.unmount("/tmp") catch |err| {
        if (err == error.Busy) {
            out("  vfs unmount : refused: open handles still reference /tmp\n", .{});
        } else {
            printError(err);
        }
        return false;
    };
    g_tmpfs_mounted = false;
    out("  vfs unmount : /tmp removed; scratch data discarded, mount table {d}/8\n", .{g_vfs.mountCount()});
    return true;
}

fn info() void {
    if (!mounted()) {
        out("  vfs info    : no mounts; run 'vfs mount' to attach CASSAFS on partition 1\n", .{});
        out("  vfs info    : node table 0/{d}, open handles 0/{d}\n", .{ vfs.max_nodes, vfs.max_handles });
        return;
    }
    const report = g_source.report;
    var canonical: [vfs.max_path]u8 = undefined;
    const point = g_vfs.mountPointAt(0) orelse "/";
    _ = canonicalPath(point, &canonical);
    out("  vfs info    : mount / <- cassafs (root ino {d}), {d} mount(s)\n", .{ g_vfs.backendRootAt(0) orelse 0, g_vfs.mountCount() });
    out("  vfs info    : volume {d} inode(s), {d} dir(s), {d} file(s), {d} data byte(s), active {s}{s}\n", .{
        report.inode_count,                    report.dirs,                                                            report.files, report.data_bytes,
        if (report.active == .a) "A" else "B", if (report.fallback) " (the other superblock copy is damaged)" else "",
    });
    const stats = g_vfs.stats();
    out("  vfs info    : node table {d}/{d}, open handles {d}/{d}, {d} lookup(s), {d} read(s), {d} write(s), {d} readdir(s)\n", .{
        stats.nodes, vfs.max_nodes, stats.handles, vfs.max_handles, g_vfs.lookups, stats.reads, stats.writes, g_vfs.readdirs,
    });
    out("  vfs info    : {d} lock(s), {d} watch(es), {d} pending event(s), {d} dropped event(s)\n", .{
        stats.locks, stats.watches, stats.pending_events, stats.dropped_events,
    });
    const cache = cassafs.mountCacheStats();
    out("  vfs cache   : {d}/{d} page(s) resident ({d}% pressure), {d}/{d} dirty, hit rate {d}% ({d} hit / {d} miss)\n", .{
        cache.used, cache.capacity, cache.pressure(), cache.dirty, cache.max_dirty, cache.hitRate(), cache.hits, cache.misses,
    });
    if (g_usb_mounted) {
        const geo = g_fat_volume.geo;
        out("  vfs info    : /media/usb <- fat32, read-only, {d} cluster(s), {d} B/cluster, root cluster {d}\n", .{
            geo.clusters, geo.cluster_bytes, geo.root_cluster,
        });
        out("  vfs info    : FAT32 directory entries are LFN-decoded on demand; writes are refused by the backend\n", .{});
    }
    if (g_tmpfs_mounted) {
        out("  vfs info    : /tmp <- tmpfs, writable, {d} node(s) used, {d} data byte(s), {d} B/file bound\n", .{
            g_tmpfs.usedNodes(), g_tmpfs.usedBytes(), tmpfs.max_file_bytes,
        });
    }
}

fn statPath(path: []const u8) void {
    var canonical: [vfs.max_path]u8 = undefined;
    const shown = canonicalPath(path, &canonical);
    const st = g_vfs.statPath(path, "/") catch |err| {
        out("  vfs stat    : {s}: ", .{shown});
        printReason(err);
        return;
    };
    out("  vfs stat    : {s}\n", .{shown});
    out("              : type {s}, inode {d}, parent {d}, size {d} B, mode 0o{o:0>6}\n", .{
        if (st.kind == .directory) "directory" else "file", st.ino, st.parent, st.size, st.mode,
    });
}

fn list(path: []const u8) void {
    var canonical: [vfs.max_path]u8 = undefined;
    const shown = canonicalPath(path, &canonical);
    const h = g_vfs.open(path, "/", .{}) catch |err| {
        out("  vfs ls      : {s}: ", .{shown});
        printReason(err);
        return;
    };
    defer g_vfs.close(h) catch {};
    const st = g_vfs.statHandle(h) catch |err| {
        printError(err);
        return;
    };
    if (st.kind != .directory) {
        out("  vfs ls      : refused: {s} is a file; readdir requires a directory\n", .{shown});
        return;
    }
    out("  vfs ls      : {s} (directory ino {d}, parent {d})\n", .{ shown, st.ino, st.parent });
    var entry: vfs.DirEntry = .{};
    var index: u32 = 0;
    var count: u32 = 0;
    while (g_vfs.readdir(h, index, &entry) catch |err| {
        printError(err);
        return;
    }) : (index += 1) {
        out("              : [{d}] {s}{s}  ino {d} parent {d} size {d}\n", .{
            index, entry.nameSlice(), if (entry.kind == .directory) "/" else "", entry.ino, entry.parent, entry.size,
        });
        count += 1;
        if (count > 4096) {
            out("              : iteration stopped after 4096 entries\n", .{});
            return;
        }
    }
    out("  vfs ls      : {d} entr{s}, stable backend order\n", .{ count, if (count == 1) "y" else "ies" });
}

fn cat(path: []const u8) void {
    var canonical: [vfs.max_path]u8 = undefined;
    const shown = canonicalPath(path, &canonical);
    const h = g_vfs.open(path, "/", .{}) catch |err| {
        out("  vfs cat     : {s}: ", .{shown});
        printReason(err);
        return;
    };
    defer g_vfs.close(h) catch {};
    const st = g_vfs.statHandle(h) catch |err| {
        printError(err);
        return;
    };
    if (st.kind == .directory) {
        out("  vfs cat     : refused: {s} is a directory\n", .{shown});
        return;
    }
    var buf: [256]u8 = undefined;
    var total: u64 = 0;
    var crc_state: u32 = 0xffff_ffff;
    while (true) {
        const n = g_vfs.read(h, &buf) catch |err| {
            printError(err);
            return;
        };
        if (n == 0) break;
        uart.writeAll(buf[0..n]);
        crc_state = cassafs_lib.crc32cUpdate(crc_state, buf[0..n]);
        total += n;
    }
    if (total == 0) uart.writeAll("\n");
    out("  vfs cat     : {s}, {d} byte(s), CRC32C 0x{x:0>8}, read to EOF (0)\n", .{
        shown, total, ~crc_state,
    });
}

fn create(path: []const u8) void {
    var canonical: [vfs.max_path]u8 = undefined;
    const shown = canonicalPath(path, &canonical);
    const h = g_vfs.open(path, "/", .{ .read = false, .write = true, .create = true }) catch |err| {
        out("  vfs create  : {s}: ", .{shown});
        printReason(err);
        return;
    };
    defer g_vfs.close(h) catch {};
    const st = g_vfs.statHandle(h) catch |err| {
        printError(err);
        return;
    };
    out("  vfs create  : {s} (inode {d}, parent {d}, mode 0o{o:0>6})\n", .{ shown, st.ino, st.parent, st.mode });
}

fn mkdir(path: []const u8) void {
    var canonical: [vfs.max_path]u8 = undefined;
    const shown = canonicalPath(path, &canonical);
    const st = g_vfs.mkdir(path, "/", 0o040755) catch |err| {
        out("  vfs mkdir   : {s}: ", .{shown});
        printReason(err);
        return;
    };
    out("  vfs mkdir   : {s} (inode {d}, parent {d}, mode 0o{o:0>6})\n", .{ shown, st.ino, st.parent, st.mode });
}

fn chmod(path: []const u8, mode_text: []const u8) void {
    const mode = std.fmt.parseInt(u16, mode_text, 8) catch {
        out("  vfs chmod   : mode must be octal, for example 644\n", .{});
        return;
    };
    if (mode > 0o7777) {
        out("  vfs chmod   : mode must fit permission bits 0..7777\n", .{});
        return;
    }
    var canonical: [vfs.max_path]u8 = undefined;
    const shown = canonicalPath(path, &canonical);
    const st = g_vfs.chmod(path, "/", mode) catch |err| {
        out("  vfs chmod   : {s}: ", .{shown});
        printReason(err);
        return;
    };
    out("  vfs chmod   : {s} mode 0o{o:0>6}, inode {d}\n", .{ shown, st.mode, st.ino });
}

fn lockTest(path: []const u8) void {
    const h1 = g_vfs.open(path, "/", .{}) catch |err| {
        out("  vfs lock    : {s}: ", .{path});
        printReason(err);
        return;
    };
    defer g_vfs.close(h1) catch {};
    const h2 = g_vfs.open(path, "/", .{}) catch |err| {
        out("  vfs lock    : {s}: ", .{path});
        printReason(err);
        return;
    };
    defer g_vfs.close(h2) catch {};

    g_vfs.lock(h1, .exclusive) catch |err| {
        out("  vfs lock    : exclusive acquire failed: {s}\n", .{reason(err)});
        return;
    };
    out("  vfs lock    : {s} exclusive acquired by handle {d}\n", .{ path, h1 });
    const conflict = g_vfs.lock(h2, .exclusive);
    if (conflict) |_| {
        out("  vfs lock    : FAIL: second exclusive lock unexpectedly succeeded\n", .{});
        return;
    } else |err| {
        out("  vfs lock    : {s}, second exclusive lock refused ({s}) PASS\n", .{ path, reason(err) });
    }
    g_vfs.unlock(h1) catch |err| {
        out("  vfs lock    : unlock failed: {s}\n", .{reason(err)});
        return;
    };
    g_vfs.lock(h1, .shared) catch |err| {
        out("  vfs lock    : shared acquire failed: {s}\n", .{reason(err)});
        return;
    };
    const shared = g_vfs.lock(h2, .shared);
    if (shared) |_| {
        out("  vfs lock    : shared locks coexist on {s} PASS\n", .{path});
    } else |err| {
        out("  vfs lock    : FAIL: shared lock was refused: {s}\n", .{reason(err)});
    }
    g_vfs.unlock(h2) catch {};
    g_vfs.unlock(h1) catch {};
}

fn watch(path: []const u8) void {
    const id = g_vfs.watch(path, "/") catch |err| {
        out("  vfs watch   : {s}: ", .{path});
        printReason(err);
        return;
    };
    out("  vfs watch   : id {d} on {s}; pending {d}, dropped {d}\n", .{
        id, path, g_vfs.pendingEvents(), g_vfs.stats().dropped_events,
    });
}

fn unwatch(id_text: []const u8) void {
    const id = std.fmt.parseInt(u32, id_text, 10) catch {
        out("  vfs unwatch : id must be decimal\n", .{});
        return;
    };
    g_vfs.unwatch(id) catch |err| {
        out("  vfs unwatch : {d}: ", .{id});
        printReason(err);
        return;
    };
    out("  vfs unwatch : id {d} removed\n", .{id});
}

fn events() void {
    var event: vfs.Event = .{};
    var count: usize = 0;
    while (g_vfs.nextEvent(&event)) {
        out("  vfs event   : seq {d} {s} {s}\n", .{
            event.seq, @tagName(event.kind), event.pathSlice(),
        });
        count += 1;
        if (count >= vfs.max_events) break;
    }
    out("  vfs events  : {d} event(s), {d} still pending, {d} dropped\n", .{
        count, g_vfs.pendingEvents(), g_vfs.stats().dropped_events,
    });
}

fn write(path: []const u8, offset_text: []const u8, text: []const u8) void {
    const offset = std.fmt.parseInt(u64, offset_text, 10) catch {
        out("  vfs write   : offset must be a decimal byte offset\n", .{});
        return;
    };
    const h = g_vfs.open(path, "/", .{ .read = false, .write = true }) catch |err| {
        out("  vfs write   : {s}: ", .{path});
        printReason(err);
        return;
    };
    defer g_vfs.close(h) catch {};
    const n = g_vfs.writeAt(h, offset, text) catch |err| {
        printError(err);
        return;
    };
    const st = g_vfs.statHandle(h) catch |err| {
        printError(err);
        return;
    };
    out("  vfs write   : {s} offset {d}, wrote {d} byte(s), size {d} B\n", .{
        path, offset, n, st.size,
    });
}

fn df() void {
    if (!mounted()) {
        out("  vfs df      : no mounts; run 'vfs mount'\n", .{});
        return;
    }
    const r = g_source.report;
    out("  vfs df      : log head {d}/{d} block(s), {d} free, {d} record(s)/{d}, next inode {d}\n", .{
        r.log_head, r.total_blocks, r.free_blocks, r.records, cassafs_lib.max_records, r.next_ino,
    });
    const cache = cassafs.mountCacheStats();
    out("  vfs cache   : {d}/{d} page(s), {d}% pressure, {d} dirty\n", .{
        cache.used, cache.capacity, cache.pressure(), cache.dirty,
    });
    if (g_usb_mounted) {
        out("  vfs df      : /media/usb is FAT32 read-only; free-cluster scan is not run on the import path\n", .{});
    }
    if (g_tmpfs_mounted) {
        out("  vfs df      : /tmp tmpfs {d}/{d} node(s), {d}/{d} byte(s), volatile\n", .{
            g_tmpfs.usedNodes(), tmpfs.max_nodes, g_tmpfs.usedBytes(), tmpfs.max_nodes * tmpfs.max_file_bytes,
        });
    }
}

fn cacheStats() void {
    if (!mounted()) {
        out("  vfs cache   : no mounts; run 'vfs mount'\n", .{});
        return;
    }
    const s = cassafs.mountCacheStats();
    out("  vfs cache   : {d}/{d} page(s) resident ({d}% pressure), {d}/{d} dirty, hit rate {d}% ({d} hit / {d} miss)\n", .{
        s.used, s.capacity, s.pressure(), s.dirty, s.max_dirty, s.hitRate(), s.hits, s.misses,
    });
    out("              : {d} read(s), {d} write(s), {d} eviction(s), {d} writeback(s), {d} flush(es), readahead {d} read(s)/{d} hit(s)/{d} error(s)\n", .{
        s.read_calls, s.write_calls, s.evictions, s.writebacks, s.flushes, s.readahead_reads, s.readahead_hits, s.readahead_errors,
    });
}

fn cacheDrop() void {
    if (!mounted()) {
        out("  vfs cache   : no mounts; run 'vfs mount'\n", .{});
        return;
    }
    g_source.cache.drop() catch |err| {
        out("  vfs cache   : drop refused: page-cache flush failed: {s}\n", .{@errorName(err)});
        return;
    };
    out("  vfs cache   : every resident page dropped after a successful write-back flush\n", .{});
}

fn cacheFlush() void {
    if (!mounted()) {
        out("  vfs cache   : no mounts; run 'vfs mount'\n", .{});
        return;
    }
    g_source.cache.flush() catch |err| {
        out("  vfs cache   : flush failed: {s}; dirty pages retained\n", .{@errorName(err)});
        return;
    };
    out("  vfs cache   : dirty pages written back and the backing device flushed\n", .{});
}

/// A storage-level latency probe for the phase-44 exit criterion. The POS
/// checkout itself is a later phase, so this measures the same CASSAFS commit
/// path a sale will use: a small sale-sized write through the VFS, interleaved
/// with a catalog read loop. It is intentionally not called a concurrent
/// benchmark; the shell is single-threaded and the result records that limit.
fn cacheBench() void {
    if (!mounted()) {
        out("  vfs bench   : no mounts; run 'vfs mount'\n", .{});
        return;
    }
    const sale = "sale=43 sku=1001 qty=1 total=250\n";
    const h = g_vfs.open("/receipts/sale44.tmp", "/", .{ .read = false, .write = true, .create = true }) catch |err| {
        out("  vfs bench   : cannot open sale file: {s}\n", .{@errorName(err)});
        return;
    };
    defer g_vfs.close(h) catch {};
    const products = g_vfs.open("/catalog/products.db", "/", .{}) catch |err| {
        out("  vfs bench   : cannot open catalog: {s}\n", .{@errorName(err)});
        return;
    };
    defer g_vfs.close(products) catch {};
    const welcome = g_vfs.open("/receipts/WELCOME.TXT", "/", .{}) catch |err| {
        out("  vfs bench   : cannot open welcome file: {s}\n", .{@errorName(err)});
        return;
    };
    defer g_vfs.close(welcome) catch {};

    const iterations: u32 = 8;
    const budget_ms: u64 = 100;
    var max_ms: u64 = 0;
    var catalog_reads: u32 = 0;
    var catalog_bytes: u64 = 0;
    var catalog_buf: [128]u8 = undefined;
    var iter: u32 = 0;
    while (iter < iterations) : (iter += 1) {
        const pn = g_vfs.readAt(products, 0, &catalog_buf) catch |err| {
            out("  vfs bench   : catalog read failed: {s}\n", .{@errorName(err)});
            return;
        };
        const wn = g_vfs.readAt(welcome, 0, &catalog_buf) catch |err| {
            out("  vfs bench   : catalog read failed: {s}\n", .{@errorName(err)});
            return;
        };
        catalog_reads += 2;
        catalog_bytes += pn + wn;
        const started = timer.uptimeMs();
        _ = g_vfs.writeAt(h, 0, sale) catch |err| {
            out("  vfs bench   : sale commit failed: {s}\n", .{@errorName(err)});
            return;
        };
        const elapsed = timer.uptimeMs() - started;
        if (elapsed > max_ms) max_ms = elapsed;
    }
    const stats = cassafs.mountCacheStats();
    out("  vfs bench   : {d} sale-sized commit(s), max {d} ms (budget {d} ms), catalog {d} read(s)/{d} B, cache {d}% hit\n", .{
        iterations, max_ms, budget_ms, catalog_reads, catalog_bytes, stats.hitRate(),
    });
    out("  vfs bench   : {s}; interleaved single-threaded catalog load, not concurrent checkout\n", .{
        if (max_ms <= budget_ms) "PASS" else "FAIL",
    });
}

fn readRange(path: []const u8, offset_text: []const u8, length_text: []const u8) void {
    const offset = std.fmt.parseInt(u64, offset_text, 10) catch {
        out("  vfs read    : offset must be a decimal byte offset\n", .{});
        return;
    };
    const length = std.fmt.parseInt(usize, length_text, 10) catch {
        out("  vfs read    : length must be a decimal byte count\n", .{});
        return;
    };
    if (length > 4096) {
        out("  vfs read    : length is capped at 4096 bytes\n", .{});
        return;
    }
    const h = g_vfs.open(path, "/", .{}) catch |err| {
        printError(err);
        return;
    };
    defer g_vfs.close(h) catch {};
    var buf: [4096]u8 = undefined;
    const n = g_vfs.readAt(h, offset, buf[0..length]) catch |err| {
        printError(err);
        return;
    };
    out("  vfs read    : {s} offset {d}, requested {d}, returned {d} byte(s)\n", .{ path, offset, length, n });
    if (n != 0) {
        out("              : ", .{});
        uart.writeAll(buf[0..n]);
        if (buf[n - 1] != '\n') out("\n", .{});
    }
}

/// Stream a CSV catalog through the VFS and validate it without ever holding
/// the whole file in memory. This is the phase-45 "catalog import" proof: the
/// CSV parser is bounded, the FAT32 backend reads 4 KiB at a time, and a
/// malformed or corrupt file is refused instead of being reported as imported.
fn catalogImport(path: []const u8) void {
    const h = g_vfs.open(path, "/", .{}) catch |err| {
        out("  vfs import  : {s}: ", .{path});
        printReason(err);
        return;
    };
    defer g_vfs.close(h) catch {};
    const st = g_vfs.statHandle(h) catch |err| {
        printError(err);
        return;
    };
    if (st.kind == .directory) {
        out("  vfs import  : refused: {s} is a directory\n", .{path});
        return;
    }

    var parser = catalog_csv.Parser{};
    var crc_state: u32 = 0xffff_ffff;
    var reads: u32 = 0;
    while (true) {
        const n = g_vfs.read(h, &import_buf) catch |err| {
            out("  vfs import  : read failed at {d} byte(s): {s}\n", .{ parser.bytes, reason(err) });
            return;
        };
        if (n == 0) break;
        crc_state = cassafs_lib.crc32cUpdate(crc_state, import_buf[0..n]);
        reads += 1;
        parser.feed(import_buf[0..n]) catch |err| {
            out("  vfs import  : refused at line {d}: {s}\n", .{ parser.line_no + 1, @errorName(err) });
            return;
        };
    }
    const result = parser.finish() catch |err| {
        out("  vfs import  : refused: {s}\n", .{@errorName(err)});
        return;
    };
    if (result.bytes != st.size) {
        out("  vfs import  : refused: parsed {d} byte(s), file stat says {d}\n", .{ result.bytes, st.size });
        return;
    }
    out("  vfs import  : {s}, {d} read(s), directed through the VFS/FAT32 chain reader\n", .{ path, reads });
    out("  vfs import  : {d} data row(s), {d} line(s), {d} byte(s), max line {d}, CRC32C 0x{x:0>8}  PASS\n", .{
        result.rows, result.lines, result.bytes, result.max_line, ~crc_state,
    });
}

const SelfTest = struct {
    passed: u32 = 0,
    failed: u32 = 0,

    fn check(self: *SelfTest, ok: bool, comptime label: []const u8) void {
        if (ok) {
            self.passed += 1;
            out("  [ok]   {s}\n", .{label});
        } else {
            self.failed += 1;
            out("  [FAIL] {s}\n", .{label});
        }
    }
};

fn reportInode(report: *const cassafs_lib.Report, ino: u64) ?*const cassafs_lib.Inode {
    var i: usize = 0;
    while (i < report.inodes.len) : (i += 1) {
        if (report.inodes[i].ino == ino) return &report.inodes[i];
    }
    return null;
}

fn checkFile(self: *SelfTest, report: *const cassafs_lib.Report, path: []const u8, expected: []const u8) void {
    const h = g_vfs.open(path, "/", .{}) catch |err| {
        out("  [FAIL] open {s}: {s}\n", .{ path, @errorName(err) });
        self.failed += 1;
        return;
    };
    defer g_vfs.close(h) catch {};
    const st = g_vfs.statHandle(h) catch |err| {
        out("  [FAIL] stat {s}: {s}\n", .{ path, @errorName(err) });
        self.failed += 1;
        return;
    };
    var offset: u64 = 0;
    var bytes: u64 = 0;
    var crc_state: u32 = 0xffff_ffff;
    var local: [512]u8 = undefined;
    var expected_chunk: [512]u8 = undefined;
    var same = true;
    while (offset < st.size) {
        const want: usize = @intCast(@min(@as(u64, local.len), st.size - offset));
        const n = g_vfs.readAt(h, offset, local[0..want]) catch |err| {
            out("  [FAIL] read {s} at {d}: {s}\n", .{ path, offset, @errorName(err) });
            self.failed += 1;
            return;
        };
        const m = cassafs_lib.readInodeRange(g_source.device, report, st.ino, offset, expected_chunk[0..n]) catch |err| {
            out("  [FAIL] reference read {s}: {s}\n", .{ path, @errorName(err) });
            self.failed += 1;
            return;
        };
        if (n != m or !std.mem.eql(u8, local[0..n], expected_chunk[0..m])) same = false;
        crc_state = cassafs_lib.crc32cUpdate(crc_state, local[0..n]);
        offset += n;
        bytes += n;
        if (n == 0) break;
    }
    const inode = reportInode(report, st.ino);
    const crc_matches = if (inode) |node| (~crc_state == node.data_crc and bytes == node.size) else false;
    self.check(same and bytes == st.size and bytes == expected.len, "VFS bytes equal the reference read extent by extent");
    self.check(crc_matches, "VFS read CRC32C equals the inode's stored data CRC");
    const eof = g_vfs.readAt(h, st.size, &local) catch 1;
    self.check(eof == 0, "read at EOF returns zero bytes, not stale data");
    const past = g_vfs.readAt(h, st.size + 4096, &local) catch 1;
    self.check(past == 0, "read past EOF returns zero bytes");
}

fn selfTest() bool {
    if (!mounted()) {
        out("  vfs selftest: FAIL: no volume mounted; run 'vfs mount' first\n", .{});
        return false;
    }
    out("  vfs selftest: mount, namespace and read-path checks\n", .{});
    const report = g_source.report;
    var suite = SelfTest{};

    var path_buf: [vfs.max_path]u8 = undefined;
    const root_dotdot = vfs.Vfs.normalizePath("/", "../../..", &path_buf) catch "/";
    const root_stat = g_vfs.statPath(root_dotdot, "/") catch {
        suite.check(false, "dot-dot at the root stays at the root");
        return false;
    };
    suite.check(std.mem.eql(u8, root_dotdot, "/") and root_stat.ino == report.root_ino, "dot-dot at the root stays at the root");

    var absolute_buf: [vfs.max_path]u8 = undefined;
    var relative_buf: [vfs.max_path]u8 = undefined;
    const absolute = vfs.Vfs.normalizePath("/", "/catalog/./products.db", &absolute_buf) catch "";
    const relative = vfs.Vfs.normalizePath("/catalog", "./products.db", &relative_buf) catch "";
    suite.check(std.mem.eql(u8, absolute, "/catalog/products.db") and std.mem.eql(u8, absolute, relative), "absolute and relative paths normalize identically");

    const file = g_vfs.statPath("/catalog/products.db", "/") catch {
        suite.check(false, "stat products.db");
        return false;
    };
    suite.check(file.ino == 3 and file.parent == 2 and file.size == demo_catalog.len, "stat returns type, size, inode and parent");

    const cache_before = cassafs.mountCacheStats();
    checkFile(&suite, report, "/catalog/products.db", demo_catalog);
    checkFile(&suite, report, "/receipts/WELCOME.TXT", demo_welcome);
    const cache_after = cassafs.mountCacheStats();
    suite.check(cache_before.capacity == 64 and cache_after.used > 0, "page cache is bounded and resident");
    suite.check(cache_after.hits > cache_before.hits or cache_after.misses > cache_before.misses, "page cache accounts for VFS read traffic");

    const file_h = g_vfs.open("/catalog/products.db", "/", .{}) catch {
        suite.check(false, "open products.db");
        return false;
    };
    var dir_entry: vfs.DirEntry = .{};
    const readdir_file = g_vfs.readdir(file_h, 0, &dir_entry);
    suite.check(if (readdir_file) |_| false else |err| err == error.NotDirectory, "readdir on a file is refused");
    g_vfs.close(file_h) catch {};

    const dir_h = g_vfs.open("/", "/", .{}) catch {
        suite.check(false, "open root directory");
        return false;
    };
    var byte_buf: [1]u8 = undefined;
    const read_dir = g_vfs.read(dir_h, &byte_buf);
    suite.check(if (read_dir) |_| false else |err| err == error.IsDirectory, "read on a directory is refused");
    var first: vfs.DirEntry = .{};
    var again: vfs.DirEntry = .{};
    const has_first = g_vfs.readdir(dir_h, 0, &first) catch false;
    const has_again = g_vfs.readdir(dir_h, 0, &again) catch false;
    suite.check(has_first and has_again and first.ino == again.ino and std.mem.eql(u8, first.nameSlice(), again.nameSlice()), "readdir index 0 is stable across calls");
    var names: [8][vfs.max_name]u8 = undefined;
    var name_lens: [8]u8 = [_]u8{0} ** 8;
    var seen: usize = 0;
    while (seen < names.len) {
        var entry: vfs.DirEntry = .{};
        const more = g_vfs.readdir(dir_h, @intCast(seen), &entry) catch false;
        if (!more) break;
        const n = @min(entry.name_len, vfs.max_name);
        @memcpy(names[seen][0..n], entry.name[0..n]);
        name_lens[seen] = @intCast(n);
        seen += 1;
    }
    var stable = true;
    var i: usize = 0;
    while (i < seen) : (i += 1) {
        var entry: vfs.DirEntry = .{};
        const more = g_vfs.readdir(dir_h, @intCast(i), &entry) catch false;
        if (!more or !std.mem.eql(u8, names[i][0..name_lens[i]], entry.nameSlice())) stable = false;
    }
    suite.check(seen >= 2 and stable, "root readdir returns a stable ordered set");
    g_vfs.close(dir_h) catch {};

    if (g_usb_mounted) {
        const usb_h = g_vfs.open("/media/usb", "/", .{}) catch {
            suite.check(false, "FAT32 mount point opens as a directory");
            return false;
        };
        var usb_entry: vfs.DirEntry = .{};
        const has_usb_entry = g_vfs.readdir(usb_h, 0, &usb_entry) catch false;
        g_vfs.close(usb_h) catch {};
        suite.check(has_usb_entry and usb_entry.name_len > 8, "FAT32 readdir decodes a long file name");
        var usb_path_buf: [vfs.max_path]u8 = undefined;
        if (std.fmt.bufPrint(&usb_path_buf, "/media/usb/{s}", .{usb_entry.nameSlice()})) |usb_path| {
            const usb_write = g_vfs.open(usb_path, "/", .{ .read = false, .write = true });
            suite.check(if (usb_write) |uh| blk: {
                g_vfs.close(uh) catch {};
                break :blk false;
            } else |err| err == error.ReadOnly, "FAT32 write open is refused as read-only");
        } else |_| {
            suite.check(false, "FAT32 long-name path fits the VFS boundary");
        }
    }

    const write_open = g_vfs.open("/catalog/products.db", "/", .{ .read = false, .write = true });
    var write_ok = false;
    if (write_open) |h| {
        write_ok = true;
        g_vfs.close(h) catch {};
    } else |_| {}
    suite.check(write_ok, "write open is accepted on the writable CASSAFS backend");
    const dir_write = g_vfs.open("/", "/", .{ .read = false, .write = true });
    suite.check(if (dir_write) |_| false else |err| err == error.IsDirectory, "write open on a directory is refused");
    if (dir_write) |h| {
        g_vfs.close(h) catch {};
    } else |_| {}

    out("  vfs selftest: {s} ({d} passed, {d} failed)\n", .{
        if (suite.failed == 0) "PASS" else "FAIL", suite.passed, suite.failed,
    });
    return suite.failed == 0;
}

fn childPath(path: []const u8, name: []const u8, buf: *[256]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
        path, if (std.mem.eql(u8, path, "/")) "" else "/", name,
    }) catch path;
}

fn drawTree(surface: *fb.Framebuffer, path: []const u8, depth: u32, y: *i32) void {
    if (depth > 2 or y.* > 690) return;
    const h = g_vfs.open(path, "/", .{}) catch return;
    defer g_vfs.close(h) catch {};
    var entry: vfs.DirEntry = .{};
    var index: u32 = 0;
    while (g_vfs.readdir(h, index, &entry) catch false) : (index += 1) {
        if (y.* > 690) return;
        var child_buf: [256]u8 = undefined;
        const child = childPath(path, entry.nameSlice(), &child_buf);
        var line: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s}{s}  ino {d}  {d} B", .{
            entry.nameSlice(), if (entry.kind == .directory) "/" else "", entry.ino, entry.size,
        }) catch entry.nameSlice();
        _ = surface.drawText(32 + @as(i32, @intCast(depth)) * 28, y.*, text, 1, if (entry.kind == .directory) fb.Palette.amber else fb.Palette.text);
        y.* += 22;
        if (entry.kind == .directory) drawTree(surface, child, depth + 1, y);
    }
}

fn drawViz() void {
    if (!mounted()) {
        out("  vfs viz     : no mounts; run 'vfs mount'\n", .{});
        return;
    }
    const surface = fb.screen() orelse {
        out("  vfs viz     : no framebuffer; use 'vfs info' and 'vfs ls'\n", .{});
        return;
    };
    surface.clear(fb.Palette.background);
    _ = surface.drawText(24, 20, "Cassa - VFS mount", 2, fb.Palette.amber);
    _ = surface.drawText(24, 56, "backend-neutral namespace · node table · open handles · stable readdir · extent reads", 1, fb.Palette.text_dim);
    if (!mounted()) {
        _ = surface.drawText(24, 110, "NO MOUNT - run 'vfs mount'", 2, fb.Palette.red);
        return;
    }
    const report = g_source.report;
    var line: [180]u8 = undefined;
    const headline = std.fmt.bufPrint(&line, "MOUNT / <- CASSAFS  v{d}  ACTIVE {s}{s}  {d} INODES  {d} FILES  {d} DATA BYTES", .{
        report.format_version,
        if (report.active == .a) "A" else "B",
        if (report.fallback) " (FALLBACK)" else "",
        report.inode_count,
        report.files,
        report.data_bytes,
    }) catch "CASSAFS";
    _ = surface.drawText(24, 92, headline, 1, fb.Palette.green);

    const stats = g_vfs.stats();
    const tables = std.fmt.bufPrint(&line, "NODE TABLE {d}/{d}   OPEN HANDLES {d}/{d}   LOOKUPS {d}   READS {d}   WRITES {d}   READDIRS {d}", .{
        stats.nodes, vfs.max_nodes, stats.handles, vfs.max_handles, g_vfs.lookups, stats.reads, stats.writes, g_vfs.readdirs,
    }) catch "tables";
    _ = surface.drawText(24, 116, tables, 1, fb.Palette.text_dim);
    const cache = cassafs.mountCacheStats();
    const cache_line = std.fmt.bufPrint(&line, "CACHE {d}/{d} PAGES  {d}% PRESSURE  {d} DIRTY  HIT {d}%  {d} HIT / {d} MISS", .{
        cache.used, cache.capacity, cache.pressure(), cache.dirty, cache.hitRate(), cache.hits, cache.misses,
    }) catch "cache";
    _ = surface.drawText(24, 136, cache_line, 1, fb.Palette.green);
    if (g_usb_mounted) {
        const geo = g_fat_volume.geo;
        const usb_line = std.fmt.bufPrint(&line, "USB /media/usb <- FAT32 READ-ONLY  {d} CLUSTERS  {d} B/CLUSTER  ROOT {d}", .{
            geo.clusters, geo.cluster_bytes, geo.root_cluster,
        }) catch "USB FAT32 READ-ONLY";
        _ = surface.drawText(24, 158, usb_line, 1, fb.Palette.amber);
    }
    _ = surface.drawText(32, if (g_usb_mounted) 184 else 162, "TREE (real readdir order)", 1, fb.Palette.text_dim);
    var y: i32 = if (g_usb_mounted) 208 else 186;
    drawTree(surface, "/", 0, &y);
    _ = surface.drawText(24, 748, "CASSAFS write path and 64-page LRU cache are live; journal replay, GC and concurrent writers remain future work.", 1, fb.Palette.text_dim);
}

fn viz(seconds: u32) void {
    const bounded: u32 = @min(seconds, 60);
    out("  vfs viz     : {d}s mount dashboard\n", .{bounded});
    const start = timer.uptimeMs();
    while (timer.uptimeMs() - start < @as(u64, bounded) * 1000) {
        drawViz();
        sched.sleepMsBlocking(100);
    }
    out("  vfs viz     : closed\n", .{});
}

pub fn command(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";
    if (std.mem.eql(u8, sub, "mount")) {
        const which = tokens.next();
        if (which == null) {
            _ = mount();
        } else if (std.mem.eql(u8, which.?, "usb") or std.mem.eql(u8, which.?, "fat") or std.mem.eql(u8, which.?, "/media/usb")) {
            _ = mountUsb();
        } else if (std.mem.eql(u8, which.?, "tmpfs") or std.mem.eql(u8, which.?, "tmp") or std.mem.eql(u8, which.?, "/tmp")) {
            _ = mountTmpfs();
        } else {
            out("  usage: vfs mount [usb|tmpfs]\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "unmount") or std.mem.eql(u8, sub, "umount")) {
        const which = tokens.next() orelse "/";
        if (std.mem.eql(u8, which, "usb") or std.mem.eql(u8, which, "/media/usb")) {
            _ = unmountUsb();
        } else if (std.mem.eql(u8, which, "tmpfs") or std.mem.eql(u8, which, "tmp") or std.mem.eql(u8, which, "/tmp")) {
            _ = unmountTmpfs();
        } else if (std.mem.eql(u8, which, "/")) {
            _ = unmount();
        } else {
            out("  usage: vfs unmount [/|usb|tmpfs]\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "info")) {
        info();
    } else if (std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "readdir")) {
        list(tokens.next() orelse "/");
    } else if (std.mem.eql(u8, sub, "cat")) {
        cat(tokens.next() orelse "/");
    } else if (std.mem.eql(u8, sub, "stat")) {
        statPath(tokens.next() orelse "/");
    } else if (std.mem.eql(u8, sub, "create")) {
        create(tokens.next() orelse {
            out("  usage: vfs create <path>\n", .{});
            return;
        });
    } else if (std.mem.eql(u8, sub, "mkdir")) {
        mkdir(tokens.next() orelse {
            out("  usage: vfs mkdir <path>\n", .{});
            return;
        });
    } else if (std.mem.eql(u8, sub, "chmod")) {
        const path = tokens.next() orelse {
            out("  usage: vfs chmod <path> <octal-mode>\n", .{});
            return;
        };
        const mode_text = tokens.next() orelse {
            out("  usage: vfs chmod <path> <octal-mode>\n", .{});
            return;
        };
        chmod(path, mode_text);
    } else if (std.mem.eql(u8, sub, "lock")) {
        lockTest(tokens.next() orelse {
            out("  usage: vfs lock <path>\n", .{});
            return;
        });
    } else if (std.mem.eql(u8, sub, "watch")) {
        watch(tokens.next() orelse {
            out("  usage: vfs watch <path>\n", .{});
            return;
        });
    } else if (std.mem.eql(u8, sub, "unwatch")) {
        unwatch(tokens.next() orelse {
            out("  usage: vfs unwatch <id>\n", .{});
            return;
        });
    } else if (std.mem.eql(u8, sub, "events")) {
        events();
    } else if (std.mem.eql(u8, sub, "write")) {
        const path = tokens.next() orelse {
            out("  usage: vfs write <path> <offset> <text>\n", .{});
            return;
        };
        const offset = tokens.next() orelse "0";
        const text = tokens.next() orelse {
            out("  usage: vfs write <path> <offset> <text>\n", .{});
            return;
        };
        write(path, offset, text);
    } else if (std.mem.eql(u8, sub, "df")) {
        df();
    } else if (std.mem.eql(u8, sub, "cache")) {
        const action = tokens.next() orelse "stats";
        if (std.mem.eql(u8, action, "stats")) {
            cacheStats();
        } else if (std.mem.eql(u8, action, "flush")) {
            cacheFlush();
        } else if (std.mem.eql(u8, action, "drop")) {
            cacheDrop();
        } else if (std.mem.eql(u8, action, "bench")) {
            cacheBench();
        } else {
            out("  usage: vfs cache [stats|flush|drop|bench]\n", .{});
        }
    } else if (std.mem.eql(u8, sub, "read")) {
        const path = tokens.next() orelse {
            out("  usage: vfs read <path> <offset> <length>\n", .{});
            return;
        };
        const offset = tokens.next() orelse "0";
        const length = tokens.next() orelse "128";
        readRange(path, offset, length);
    } else if (std.mem.eql(u8, sub, "import")) {
        const path = tokens.next() orelse {
            out("  usage: vfs import <csv-path>\n", .{});
            return;
        };
        catalogImport(path);
    } else if (std.mem.eql(u8, sub, "selftest") or std.mem.eql(u8, sub, "test")) {
        _ = selfTest();
    } else if (std.mem.eql(u8, sub, "viz")) {
        const seconds = std.fmt.parseInt(u32, tokens.next() orelse "8", 10) catch 8;
        viz(seconds);
    } else {
        out("  usage: vfs [mount [usb|tmpfs]|unmount [/|usb|tmpfs]|info|df|cache [stats|flush|drop|bench]|ls [path]|stat <path>|cat <path>|create <path>|mkdir <path>|chmod <path> <octal>|lock <path>|watch <path>|unwatch <id>|events|write <path> <offset> <text>|read <path> <offset> <len>|import <csv>|selftest|viz <s>]\n", .{});
    }
}
