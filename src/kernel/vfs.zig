//! Kernel VFS front end (phase 42).
//!
//! The namespace policy, mount table, node table and handles live in
//! `src/lib/vfs.zig`. This file owns the one registered backend (CASSAFS on
//! partition 1) and the shell surface: mount/unmount, stat, directory
//! iteration, sequential reads, range reads and a failure-mode self-test.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");
const fb = @import("fb.zig");
const sched = @import("sched.zig");
const cassafs = @import("cassafs.zig");
const cassafs_lib = @import("../lib/cassafs.zig");
const cassafs_vfs = @import("../lib/cassafs_vfs.zig");
const vfs = @import("../lib/vfs.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

var g_vfs: vfs.Vfs = .{};
var g_adapter: cassafs_vfs.Adapter = undefined;
var g_source: cassafs.MountSource = undefined;

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
    return g_vfs.mountCount() != 0;
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
    out("  vfs unmount : / removed and page cache flushed; mount table 0/1, no dangling nodes or handles\n", .{});
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
    const cache = cassafs.mountCacheStats();
    out("  vfs cache   : {d}/{d} page(s) resident ({d}% pressure), {d}/{d} dirty, hit rate {d}% ({d} hit / {d} miss)\n", .{
        cache.used, cache.capacity, cache.pressure(), cache.dirty, cache.max_dirty, cache.hitRate(), cache.hits, cache.misses,
    });
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
    _ = surface.drawText(32, 162, "TREE (real readdir order)", 1, fb.Palette.text_dim);
    var y: i32 = 186;
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
        _ = mount();
    } else if (std.mem.eql(u8, sub, "unmount") or std.mem.eql(u8, sub, "umount")) {
        _ = unmount();
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
    } else if (std.mem.eql(u8, sub, "selftest") or std.mem.eql(u8, sub, "test")) {
        _ = selfTest();
    } else if (std.mem.eql(u8, sub, "viz")) {
        const seconds = std.fmt.parseInt(u32, tokens.next() orelse "8", 10) catch 8;
        viz(seconds);
    } else {
        out("  usage: vfs [mount|unmount|info|df|cache [stats|flush|drop|bench]|ls [path]|stat <path>|cat <path>|create <path>|write <path> <offset> <text>|read <path> <offset> <len>|selftest|viz <s>]\n", .{});
    }
}
