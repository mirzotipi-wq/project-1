//! CASSAFS kernel adapter and diagnostics (phase 41).
//!
//! The on-disk format and verifier live in `src/lib/cassafs.zig`; this file is
//! the thin layer between that pure implementation and the kernel: it wraps
//! partition 1 as a 4 KiB block device, owns the formatter's scratch buffers,
//! and turns the verified report into shell diagnostics and the panel
//! dashboard. Mount and normal file I/O belong to phases 42–43.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");
const pl031 = @import("../devices/pl031.zig");
const sched = @import("sched.zig");
const klog = @import("klog.zig");
const fb = @import("fb.zig");
const block = @import("block.zig");
const partition = @import("partition.zig");
const block_view = @import("block_view.zig");
const journal = @import("journal.zig");
const cassafs = @import("../lib/cassafs.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

var g_view: block_view.View = undefined;
var g_table: partition.Table = .{};
var inode_storage: [cassafs.max_nodes]cassafs.Inode = undefined;
var workspace: [cassafs.workspaceRequired(cassafs.max_volume_blocks)]u8 = undefined;
var read_buffer: [cassafs.max_file_bytes]u8 = undefined;
var g_report: cassafs.Report = .{};

// Phase 42: a mounted volume has its own view, report and inode storage. The
// diagnostics above must not invalidate a live mount when `cassafs info` or
// `cassafs verify` runs.
var mount_view: block_view.View = undefined;
var mount_inode_storage: [cassafs.max_nodes]cassafs.Inode = undefined;
var mount_workspace: [cassafs.workspaceRequired(cassafs.max_volume_blocks)]u8 = undefined;
var mount_report: cassafs.Report = .{};

const demo_catalog = "sku,name,price_cents\n1001,Espresso,250\n1002,Croissant,180\n1003,Water,150\n";
const demo_welcome = "Welcome to Cassa POS.\nThis volume was formatted by the phase 41 reference formatter.\n";

const demo_nodes = [_]cassafs.Node{
    .{ .ino = 1, .parent = 0, .kind = .inode, .name = "" },
    .{ .ino = 2, .parent = 1, .kind = .inode, .name = "catalog" },
    .{ .ino = 3, .parent = 2, .kind = .data, .name = "products.db", .data = demo_catalog },
    .{ .ino = 4, .parent = 1, .kind = .inode, .name = "receipts" },
    .{ .ino = 5, .parent = 4, .kind = .data, .name = "WELCOME.TXT", .data = demo_welcome },
};

const empty_nodes = [_]cassafs.Node{
    .{ .ino = 1, .parent = 0, .kind = .inode, .name = "" },
};

fn blockRead(ctx: *anyopaque, block_index: u32, buf: *[cassafs.block_size]u8) cassafs.Error!void {
    const view: *block_view.View = @ptrCast(@alignCast(ctx));
    const sectors_per_block: u64 = cassafs.block_size / block.sector_size;
    const lba = @as(u64, block_index) * sectors_per_block;
    view.read(lba, buf[0..]) catch return error.Io;
}

fn blockWrite(ctx: *anyopaque, block_index: u32, buf: *const [cassafs.block_size]u8) cassafs.Error!void {
    const view: *block_view.View = @ptrCast(@alignCast(ctx));
    const sectors_per_block: u64 = cassafs.block_size / block.sector_size;
    const lba = @as(u64, block_index) * sectors_per_block;
    view.write(lba, buf[0..]) catch return error.Io;
}

fn blockFlush(ctx: *anyopaque) cassafs.Error!void {
    const view: *block_view.View = @ptrCast(@alignCast(ctx));
    view.flush() catch return error.Io;
}

fn attachTo(view: *block_view.View) !cassafs.Device {
    if (!block.present()) return error.NoDevice;
    try partition.read(.{}, &g_table);
    if (g_table.count == 0) return error.NoTable;
    view.* = try block_view.View.fromPartition(&g_table.entries[0]);
    const sectors = view.capacitySectors();
    const sectors_per_block: u64 = cassafs.block_size / block.sector_size;
    if (sectors == 0 or sectors % sectors_per_block != 0) return error.Unsupported;
    if (sectors / sectors_per_block > cassafs.max_volume_blocks) return error.Unsupported;
    return .{
        .ctx = view,
        .blocks = @intCast(sectors / sectors_per_block),
        .read_fn = blockRead,
        .write_fn = blockWrite,
        .flush_fn = blockFlush,
    };
}

fn attach() !cassafs.Device {
    return attachTo(&g_view);
}

pub const MountSource = struct {
    device: cassafs.Device,
    report: *cassafs.Report,
    workspace: []u8,
    inode_storage: []cassafs.Inode,
};

/// Attach partition 1 and scan the volume into the mount workspace. This is the
/// only path used by the VFS mount: it does not format, write, or mutate the
/// volume, and it returns only after the complete log, inode tree, data CRCs and
/// free map have been verified. A failure leaves no mount state anywhere.
pub fn mountVolume() !MountSource {
    const device = try attachTo(&mount_view);
    mount_report = try cassafs.scan(device, &mount_workspace, &mount_inode_storage);
    return .{
        .device = device,
        .report = &mount_report,
        .workspace = mount_workspace[0..],
        .inode_storage = mount_inode_storage[0..],
    };
}

pub fn explain(err: anyerror) void {
    switch (err) {
        error.NoDevice => out("  cassafs     : no block device; attach a disk with partition 1\n", .{}),
        error.NoTable => out("  cassafs     : no MBR/GPT partition table on the disk\n", .{}),
        error.Unsupported => out("  cassafs     : partition 1 is not a 4 KiB-aligned CASSAFS-sized volume\n", .{}),
        error.BadSuperblock, error.BadMagic => out("  cassafs     : no valid CASSAFS superblock; format the volume first\n", .{}),
        error.BadCrc => out("  cassafs     : CRC32C mismatch; the volume is damaged\n", .{}),
        error.BadRecord => out("  cassafs     : malformed log record\n", .{}),
        error.BadSequence => out("  cassafs     : log sequence is not contiguous\n", .{}),
        error.BadCheckpoint => out("  cassafs     : checkpoint does not match the superblock\n", .{}),
        error.BadInode, error.DuplicateInode, error.BadTree => out("  cassafs     : inode tree is invalid\n", .{}),
        error.BadExtent => out("  cassafs     : an extent does not lie inside a data record\n", .{}),
        error.BadFreeMap => out("  cassafs     : free-space map disagrees with the log\n", .{}),
        error.CountMismatch => out("  cassafs     : checkpoint counters disagree with the log\n", .{}),
        error.NoSpace => out("  cassafs     : partition is too small for this format\n", .{}),
        error.BufferTooSmall => out("  cassafs     : internal format buffer is too small\n", .{}),
        else => out("  cassafs     : {s}\n", .{@errorName(err)}),
    }
}

fn labelText(label: *const [32]u8) []const u8 {
    var n: usize = 0;
    while (n < label.len and label[n] != 0) : (n += 1) {}
    return label[0..n];
}

fn inodePath(report: *const cassafs.Report, index: usize, buf: *[256]u8) []const u8 {
    var indices: [cassafs.max_nodes]usize = undefined;
    var depth: usize = 0;
    var cursor = index;
    while (true) {
        if (depth >= indices.len) return "/";
        indices[depth] = cursor;
        depth += 1;
        const parent = report.inodes[cursor].parent;
        if (parent == 0) break;
        var found: ?usize = null;
        var i: usize = 0;
        while (i < report.inodes.len) : (i += 1) {
            if (report.inodes[i].ino == parent) {
                found = i;
                break;
            }
        }
        cursor = found orelse return "/";
    }
    var pos: usize = 0;
    buf[pos] = '/';
    pos += 1;
    while (depth > 0) {
        depth -= 1;
        const current = &report.inodes[indices[depth]];
        if (current.parent == 0) continue;
        const name = current.nameSlice();
        if (pos + name.len + 1 >= buf.len) break;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        if (depth > 0) {
            buf[pos] = '/';
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn printSuper(status: cassafs.SuperStatus, slot: []const u8) void {
    if (status.valid) {
        out("  superblock {s}: valid, generation {d}, checkpoint block {d}, seq {d}, log head {d}, {d} free\n", .{
            slot, status.generation, status.checkpoint_block, status.checkpoint_seq, status.log_head, status.free_blocks,
        });
    } else {
        out("  superblock {s}: INVALID (CRC32C or version failure)\n", .{slot});
    }
}

fn load() ?*cassafs.Report {
    const device = attach() catch |err| {
        explain(err);
        return null;
    };
    g_report = cassafs.scan(device, &workspace, &inode_storage) catch |err| {
        explain(err);
        return null;
    };
    return &g_report;
}

fn info() void {
    const report = load() orelse return;
    out("  cassafs     : CASSAFS format {d}, {d} B blocks, {d} total block(s)\n", .{
        report.format_version, report.block_size, report.total_blocks,
    });
    printSuper(report.a, "A");
    printSuper(report.b, "B");
    out("  active      : {s}{s}\n", .{
        if (report.active == .a) "A" else "B",
        if (report.fallback) " (fallback; the other copy is damaged)" else " (both copies valid)",
    });
    out("  log         : {d} used, {d} free, {d} record(s), sequence {d}..{d}\n", .{
        report.used_blocks, report.free_blocks, report.records, report.first_seq, report.last_seq,
    });
    const checkpoint_block = if (report.active == .a) report.a.checkpoint_block else report.b.checkpoint_block;
    out("  checkpoint  : block {d}, seq {d}, free map block {d} seq {d}\n", .{
        checkpoint_block, report.last_seq, report.free_map_block, report.free_map_seq,
    });
    out("  inode tree  : {d} inode(s), {d} dir(s), {d} file(s), {d} data byte(s), root ino {d}\n", .{
        report.inode_count, report.dirs, report.files, report.data_bytes, report.root_ino,
    });
    out("  free map    : {d}/{d} block(s) used, {d} free; bitmap and CRC32C agree\n", .{
        report.used_blocks, report.total_blocks, report.free_blocks,
    });
    out("  label       : {s}\n", .{labelText(&report.label)});
}

fn dump() void {
    const report = load() orelse return;
    out("  CASSAFS dump: version {d}, block size {d}, {d} blocks, label '{s}'\n", .{
        report.format_version, report.block_size, report.total_blocks, labelText(&report.label),
    });
    printSuper(report.a, "A");
    printSuper(report.b, "B");
    out("  active {s}, fallback {s}, log head {d}, used {d}, free {d}\n", .{
        if (report.active == .a) "A" else "B", if (report.fallback) "yes" else "no", report.log_head, report.used_blocks, report.free_blocks,
    });
    out("  checkpoint root {d}, next ino {d}, {d} records, {d} bytes data, free map block {d}\n", .{
        report.checkpoint.root_ino, report.checkpoint.next_ino, report.checkpoint.record_count, report.checkpoint.data_bytes, report.free_map_block,
    });
    out("  log records:\n", .{});
    var i: usize = 0;
    while (i < report.record_info_count) : (i += 1) {
        const rec = report.record_infos[i];
        out("    seq {d:>3}  {s:<10}  block {d:>4}  {d} block(s)  {d} byte(s)\n", .{
            rec.seq, @tagName(rec.kind), rec.block, rec.blocks, rec.payload_len,
        });
    }
    out("  inode tree:\n", .{});
    i = 0;
    while (i < report.inodes.len) : (i += 1) {
        const inode = &report.inodes[i];
        var path_buf: [256]u8 = undefined;
        const path = inodePath(report, i, &path_buf);
        out("    {s:<28} {s:<4} ino {d:<3} parent {d:<3} size {d:<6} extents {d}\n", .{
            path, if (inode.kind == .inode) "dir" else "file", inode.ino, inode.parent, inode.size, inode.extent_count,
        });
        var e: usize = 0;
        while (e < inode.extent_count) : (e += 1) {
            const ext = inode.extents[e];
            out("      extent {d}: logical {d}, block {d}, offset {d}, length {d}\n", .{
                e, ext.logical_offset, ext.physical_block, ext.physical_offset, ext.length,
            });
        }
    }
    out("  free-space map: {d} used / {d} free of {d}; bitmap verified against log head {d}\n", .{
        report.used_blocks, report.free_blocks, report.total_blocks, report.log_head,
    });
}

fn verify() bool {
    const report = load() orelse return false;
    out("  [41] cassafs: format, CRC32C records, A/B superblocks, inode tree, extents, free map\n", .{});
    out("      superblocks: A {s}, B {s}, active {s}{s}\n", .{
        if (report.a.valid) "OK" else "INVALID",
        if (report.b.valid) "OK" else "INVALID",
        if (report.active == .a) "A" else "B",
        if (report.fallback) " (fallback)" else "",
    });
    out("      records: {d}, seq {d}..{d}, every header and payload CRC32C OK\n", .{
        report.records, report.first_seq, report.last_seq,
    });
    out("      inode tree: {d} inode(s), {d} dir(s), {d} file(s), root ino {d}, parents and names unique\n", .{
        report.inode_count, report.dirs, report.files, report.root_ino,
    });
    out("      extents: {d} file(s), {d} data byte(s), every extent inside a data record\n", .{
        report.files, report.data_bytes,
    });
    out("      free map: {d} used / {d} free, bitmap agrees with log head {d}\n", .{
        report.used_blocks, report.free_blocks, report.log_head,
    });
    out("      data CRCs: all file extents match their inode data CRC\n", .{});
    out("      cassafs verify: PASS\n", .{});
    return true;
}

fn formatVolume(fixture: *const cassafs.Fixture, label: []const u8) bool {
    if (journal.snapshot().active) {
        out("  cassafs     : refused: the phase-40 power journal is mounted on partition 1 as FAT32\n", .{});
        out("                formatting it would invalidate the journal; use a CASSAFS data disk or phase 43\n", .{});
        return false;
    }
    const device = attach() catch |err| {
        explain(err);
        return false;
    };
    out("  cassafs     : formatting partition 1 ({d} blocks, {d} B) as CASSAFS v1; contents will be replaced\n", .{
        device.blocks, cassafs.block_size,
    });
    const stats = cassafs.format(device, fixture.*, &workspace) catch |err| {
        explain(err);
        return false;
    };
    klog.info("cassafs", "formatted {d} block(s), {d} record(s), {d} free, label '{s}'", .{
        stats.used_blocks, stats.records, stats.free_blocks, label,
    });
    out("  format      : {d} record(s), {d} inode(s), {d} dir(s), {d} file(s), {d} data byte(s)\n", .{
        stats.records, stats.inode_count, stats.dirs, stats.files, stats.data_bytes,
    });
    out("  geometry    : log head {d}, {d} used, {d} free, superblock A gen 1, B gen 2\n", .{
        stats.log_head, stats.used_blocks, stats.free_blocks,
    });
    out("  format      : OK; run 'cassafs verify' for the read-back proof\n", .{});
    return true;
}

fn formatCommand(tokens: *std.mem.TokenIterator(u8, .scalar)) bool {
    const mode = tokens.next() orelse "empty";
    const label: []const u8 = "Cassa POS data";
    if (std.mem.eql(u8, mode, "demo")) {
        const fixture = cassafs.Fixture{
            .nodes = &demo_nodes,
            .label = label,
            .uuid = [_]u8{ 'C', 'A', 'S', 'S', 'A', 'F', 'S', 1, 0, 0, 0, 0, 0, 0, 0, 1 },
            .created_sec = pl031.unixSeconds() orelse 0,
        };
        return formatVolume(&fixture, label);
    } else if (std.mem.eql(u8, mode, "empty")) {
        const fixture = cassafs.Fixture{
            .nodes = &empty_nodes,
            .label = label,
            .uuid = [_]u8{ 'C', 'A', 'S', 'S', 'A', 'F', 'S', 1, 0, 0, 0, 0, 0, 0, 0, 2 },
            .created_sec = pl031.unixSeconds() orelse 0,
        };
        return formatVolume(&fixture, label);
    } else {
        out("  usage: cassafs format [empty|demo]\n", .{});
        return false;
    }
}

fn cat(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const path = tokens.next() orelse {
        out("  usage: cassafs cat <path>\n", .{});
        return;
    };
    const report = load() orelse return;
    const device = attach() catch |err| {
        explain(err);
        return;
    };
    const n = cassafs.readFile(device, report, path, &read_buffer) catch |err| {
        switch (err) {
            error.PathNotFound => out("  cassafs     : {s}: not found\n", .{path}),
            error.BufferTooSmall => out("  cassafs     : {s}: file is larger than the reference buffer\n", .{path}),
            else => explain(err),
        }
        return;
    };
    out("{s}", .{read_buffer[0..n]});
    if (n == 0 or read_buffer[n - 1] != '\n') out("\n", .{});
    out("  cassafs cat : {s}, {d} byte(s), CRC32C 0x{x:0>8}\n", .{ path, n, cassafs.crc32c(read_buffer[0..n]) });
}

fn drawViz(report: *const cassafs.Report) void {
    const surface = fb.screen() orelse {
        out("  cassafs viz : no framebuffer; use 'cassafs dump'\n", .{});
        return;
    };
    surface.clear(fb.Palette.background);
    _ = surface.drawText(24, 20, "Cassa - CASSAFS format", 2, fb.Palette.amber);
    _ = surface.drawText(24, 56, "log-structured · CRC32C records · A/B superblocks · inode tree · extents · free-space map", 1, fb.Palette.text_dim);

    var line: [160]u8 = undefined;
    const headline = std.fmt.bufPrint(&line, "v{d}  BLOCK {d} B  {d} TOTAL  USED {d}  FREE {d}", .{
        report.format_version, report.block_size, report.total_blocks, report.used_blocks, report.free_blocks,
    }) catch "CASSAFS";
    _ = surface.drawText(24, 92, headline, 2, fb.Palette.green);

    const ab = std.fmt.bufPrint(&line, "SUPERBLOCK A gen {d} {s}   B gen {d} {s}   ACTIVE {s}{s}", .{
        report.a.generation,                   if (report.a.valid) "OK" else "BAD",
        report.b.generation,                   if (report.b.valid) "OK" else "BAD",
        if (report.active == .a) "A" else "B", if (report.fallback) "  FALLBACK" else "",
    }) catch "superblocks";
    _ = surface.drawText(24, 128, ab, 1, fb.Palette.amber);

    const log_line = std.fmt.bufPrint(&line, "LOG {d} records  seq {d}..{d}  head {d}  CHECKPOINT seq {d}  FREE MAP seq {d}", .{
        report.records, report.first_seq, report.last_seq, report.log_head, report.last_seq, report.checkpoint.free_map_seq,
    }) catch "log";
    _ = surface.drawText(24, 148, log_line, 1, fb.Palette.text_dim);

    const tree_line = std.fmt.bufPrint(&line, "INODE TREE  {d} inode(s)  {d} dir(s)  {d} file(s)  {d} data byte(s)  ROOT {d}", .{
        report.inode_count, report.dirs, report.files, report.data_bytes, report.root_ino,
    }) catch "tree";
    _ = surface.drawText(24, 168, tree_line, 1, fb.Palette.text);

    // Allocation strip: one cell per group of blocks, green for the append-only
    // log prefix and grey for free space. It is a real map, not a decoration.
    _ = surface.drawText(24, 198, "BLOCK MAP", 1, fb.Palette.text_dim);
    const cells: u32 = 128;
    const per_cell: u32 = @max(1, (report.total_blocks + cells - 1) / cells);
    var cell: u32 = 0;
    while (cell < cells) : (cell += 1) {
        const first = cell * per_cell;
        if (first >= report.total_blocks) break;
        const used = first < report.log_head;
        surface.fillRect(24 + @as(i32, @intCast(cell * 9)), 214, 8, 18, if (used) fb.Palette.amber else fb.Palette.grid);
    }
    const map_line = std.fmt.bufPrint(&line, "log prefix {d} block(s) used   {d} free   {d} block(s) per cell", .{
        report.used_blocks, report.free_blocks, per_cell,
    }) catch "map";
    _ = surface.drawText(24, 238, map_line, 1, fb.Palette.text_dim);

    _ = surface.drawText(24, 270, "INODE TREE / EXTENTS", 1, fb.Palette.text_dim);
    var y: i32 = 290;
    var i: usize = 0;
    while (i < report.inodes.len and i < 8) : (i += 1) {
        const inode = &report.inodes[i];
        var path_buf: [256]u8 = undefined;
        const path = inodePath(report, i, &path_buf);
        const row = std.fmt.bufPrint(&line, "{s:<26} {s:<4} size {d:<6} ext {d}", .{
            path, if (inode.kind == .inode) "dir" else "file", inode.size, inode.extent_count,
        }) catch "inode";
        _ = surface.drawText(24, y, row, 1, if (inode.kind == .data) fb.Palette.text else fb.Palette.amber);
        y += 16;
    }
    const label_line = std.fmt.bufPrint(&line, "LABEL {s}   FREE MAP block {d} seq {d}   DATA CRC OK", .{
        labelText(&report.label), report.free_map_block, report.free_map_seq,
    }) catch "label";
    _ = surface.drawText(24, 450, label_line, 1, fb.Palette.text_dim);
    _ = surface.drawText(24, @as(i32, @intCast(surface.mode.height)) - 22, "live dashboard: verified CASSAFS v1 format; closes after the set time", 1, fb.Palette.text_dim);
}

fn viz(seconds: u32) void {
    const report = load() orelse return;
    const bounded: u32 = @min(seconds, 60);
    out("  cassafs viz : {d}s storage dashboard\n", .{bounded});
    const start = timer.uptimeMs();
    while (timer.uptimeMs() - start < @as(u64, bounded) * 1000) {
        drawViz(report);
        sched.sleepMsBlocking(100);
    }
    out("  cassafs viz : closed\n", .{});
}

pub fn command(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "info";
    if (std.mem.eql(u8, sub, "info")) {
        info();
    } else if (std.mem.eql(u8, sub, "format")) {
        _ = formatCommand(tokens);
    } else if (std.mem.eql(u8, sub, "demo")) {
        const fixture = cassafs.Fixture{
            .nodes = &demo_nodes,
            .label = "Cassa POS data",
            .uuid = [_]u8{ 'C', 'A', 'S', 'S', 'A', 'F', 'S', 1, 0, 0, 0, 0, 0, 0, 0, 1 },
            .created_sec = pl031.unixSeconds() orelse 0,
        };
        _ = formatVolume(&fixture, "Cassa POS data");
    } else if (std.mem.eql(u8, sub, "dump")) {
        dump();
    } else if (std.mem.eql(u8, sub, "verify") or std.mem.eql(u8, sub, "selftest")) {
        if (!verify()) out("      cassafs verify: FAIL\n", .{});
    } else if (std.mem.eql(u8, sub, "cat")) {
        cat(tokens);
    } else if (std.mem.eql(u8, sub, "viz")) {
        const seconds = std.fmt.parseInt(u32, tokens.next() orelse "8", 10) catch 8;
        viz(seconds);
    } else {
        out("  usage: cassafs [info|format [empty|demo]|demo|dump|verify|cat <path>|viz <s>]\n", .{});
    }
}
