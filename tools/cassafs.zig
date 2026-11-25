//! cassafs — host-side reference reader for the phase 41 CASSAFS format.
//!
//! This is a normal Zig host program built by `zig build`; it is not part of the
//! kernel. It reads an image exactly the way the on-disk verifier does (same
//! library, same CRC32C, same A/B selection) so a QEMU run can be checked from
//! outside the guest.
//!
//! Usage:
//!   cassafs info   --image disk.img [--partition 1 | --offset BYTES]
//!   cassafs verify --image disk.img [--partition 1 | --offset BYTES]
//!   cassafs dump   --image disk.img [--partition 1 | --offset BYTES]
//!   cassafs cat    --image disk.img --path /catalog/products.db [--partition 1]

const std = @import("std");
const cassafs = @import("cassafs_lib");

var workspace: [cassafs.workspaceRequired(cassafs.max_volume_blocks)]u8 = undefined;
var inodes: [cassafs.max_nodes]cassafs.Inode = undefined;
var file_buffer: [cassafs.max_file_bytes]u8 = undefined;

const Image = struct {
    file: std.fs.File,
    base: u64,
    blocks: u32,
};

fn readBlock(ctx: *anyopaque, index: u32, buf: *[cassafs.block_size]u8) cassafs.Error!void {
    const image: *Image = @ptrCast(@alignCast(ctx));
    const offset = image.base + @as(u64, index) * cassafs.block_size;
    const got = image.file.preadAll(buf, offset) catch return error.Io;
    if (got != buf.len) return error.Io;
}

fn writeBlock(ctx: *anyopaque, index: u32, buf: *const [cassafs.block_size]u8) cassafs.Error!void {
    _ = ctx;
    _ = index;
    _ = buf;
    return error.ReadOnly;
}

fn flushBlock(ctx: *anyopaque) cassafs.Error!void {
    const image: *Image = @ptrCast(@alignCast(ctx));
    image.file.sync() catch return error.Io;
}

fn usage() noreturn {
    std.debug.print(
        \\cassafs host reference tool (phase 41)
        \\usage:
        \\  cassafs info   --image disk.img [--partition N | --offset BYTES]
        \\  cassafs verify --image disk.img [--partition N | --offset BYTES]
        \\  cassafs dump   --image disk.img [--partition N | --offset BYTES]
        \\  cassafs cat    --image disk.img --path /catalog/products.db [--partition N]
        \\
    , .{});
    std.process.exit(2);
}

fn nameText(name: *const [cassafs.max_name + 1]u8) []const u8 {
    var n: usize = 0;
    while (n < name.len and name[n] != 0) : (n += 1) {}
    return name[0..n];
}

fn pathOf(report: *const cassafs.Report, index: usize, buf: *[256]u8) []const u8 {
    var stack: [cassafs.max_nodes]usize = undefined;
    var depth: usize = 0;
    var cursor = index;
    while (true) {
        if (depth >= stack.len) return "/";
        stack[depth] = cursor;
        depth += 1;
        const parent = report.inodes[cursor].parent;
        if (parent == 0) break;
        var found: ?usize = null;
        for (report.inodes, 0..) |inode, i| {
            if (inode.ino == parent) {
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
        const inode = &report.inodes[stack[depth]];
        if (inode.parent == 0) continue;
        const name = nameText(&inode.name);
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
        std.debug.print("  superblock {s}: valid, generation {d}, checkpoint block {d}, seq {d}, head {d}, {d} free\n", .{
            slot, status.generation, status.checkpoint_block, status.checkpoint_seq, status.log_head, status.free_blocks,
        });
    } else {
        std.debug.print("  superblock {s}: INVALID\n", .{slot});
    }
}

fn reportInfo(report: *const cassafs.Report) void {
    std.debug.print("  format      : CASSAFS v{d}, {d} B blocks, {d} total\n", .{
        report.format_version, report.block_size, report.total_blocks,
    });
    std.debug.print("  label       : {s}\n", .{nameText(&report.label)});
    printSuper(report.a, "A");
    printSuper(report.b, "B");
    std.debug.print("  active      : {s}{s}\n", .{
        if (report.active == .a) "A" else "B",
        if (report.fallback) " (fallback)" else "",
    });
    std.debug.print("  log         : {d} record(s), seq {d}..{d}, {d} used, {d} free, head {d}\n", .{
        report.records, report.first_seq, report.last_seq, report.used_blocks, report.free_blocks, report.log_head,
    });
    std.debug.print("  checkpoint  : seq {d}, root ino {d}, next ino {d}, {d} data byte(s)\n", .{
        report.last_seq, report.checkpoint.root_ino, report.checkpoint.next_ino, report.checkpoint.data_bytes,
    });
    std.debug.print("  inode tree  : {d} inode(s), {d} dir(s), {d} file(s)\n", .{
        report.inode_count, report.dirs, report.files,
    });
    std.debug.print("  free map    : block {d}, seq {d}, {d}/{d} used\n", .{
        report.free_map_block, report.free_map_seq, report.used_blocks, report.total_blocks,
    });
}

fn reportDump(report: *const cassafs.Report) void {
    reportInfo(report);
    std.debug.print("  records:\n", .{});
    var i: usize = 0;
    while (i < report.record_info_count) : (i += 1) {
        const rec = report.record_infos[i];
        std.debug.print("    seq {d:>3}  {s:<9} block {d:>4}  {d} block(s)  {d} byte(s)\n", .{
            rec.seq, @tagName(rec.kind), rec.block, rec.blocks, rec.payload_len,
        });
    }
    std.debug.print("  inodes:\n", .{});
    i = 0;
    while (i < report.inodes.len) : (i += 1) {
        const inode = &report.inodes[i];
        var buf: [256]u8 = undefined;
        const path = pathOf(report, i, &buf);
        std.debug.print("    {s:<28} {s:<4} ino {d:<3} parent {d:<3} size {d:<6} extents {d}\n", .{
            path, if (inode.kind == .inode) "dir" else "file", inode.ino, inode.parent, inode.size, inode.extent_count,
        });
        var e: usize = 0;
        while (e < inode.extent_count) : (e += 1) {
            const ext = inode.extents[e];
            std.debug.print("      extent {d}: logical {d}, block {d}, offset {d}, length {d}\n", .{
                e, ext.logical_offset, ext.physical_block, ext.physical_offset, ext.length,
            });
        }
    }
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const sub = args.next() orelse usage();

    var image_path: ?[]const u8 = null;
    var offset: ?u64 = null;
    var part_index: u32 = 1;
    var cat_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--image")) {
            image_path = args.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--offset")) {
            offset = std.fmt.parseInt(u64, args.next() orelse usage(), 0) catch usage();
        } else if (std.mem.eql(u8, arg, "--partition")) {
            part_index = std.fmt.parseInt(u32, args.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, arg, "--path")) {
            cat_path = args.next() orelse usage();
        } else {
            usage();
        }
    }
    const path = image_path orelse usage();

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cassafs: cannot open {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(2);
    };
    defer file.close();
    const size = (try file.stat()).size;

    var base: u64 = offset orelse 0;
    var partition_bytes: ?u64 = null;
    if (offset == null) {
        var sector: [512]u8 = undefined;
        if (part_index == 0 or part_index > 4) usage();
        const got = file.preadAll(&sector, 0) catch 0;
        if (got != sector.len or sector[510] != 0x55 or sector[511] != 0xAA) {
            std.debug.print("cassafs: {s} has no MBR; pass --offset BYTES\n", .{path});
            std.process.exit(2);
        }
        const entry = 446 + (part_index - 1) * 16;
        const start = std.mem.readInt(u32, sector[entry + 8 ..][0..4], .little);
        const sectors = std.mem.readInt(u32, sector[entry + 12 ..][0..4], .little);
        if (start == 0 or sectors == 0) {
            std.debug.print("cassafs: partition {d} is empty\n", .{part_index});
            std.process.exit(2);
        }
        base = @as(u64, start) * 512;
        partition_bytes = @as(u64, sectors) * 512;
        std.debug.print("cassafs: partition {d} at byte {d}, type 0x{x:0>2}, {d} sector(s)\n", .{
            part_index, base, sector[entry + 4], sectors,
        });
    }

    if (base >= size) {
        std.debug.print("cassafs: offset {d} is past end of image ({d} bytes)\n", .{ base, size });
        std.process.exit(2);
    }
    const volume_bytes = partition_bytes orelse (size - base);
    var blocks64 = volume_bytes / cassafs.block_size;
    if (offset != null) {
        // A raw offset has no partition length. The superblock is self-describing,
        // so use its total_blocks rather than the rest of the container file.
        var first: [cassafs.block_size]u8 = undefined;
        const got = file.preadAll(&first, base) catch 0;
        if (got == first.len) {
            const sb = cassafs.decodeSuperblock(first[0..cassafs.superblock_size]) catch null;
            if (sb) |good| blocks64 = good.total_blocks;
        }
    }
    if (blocks64 == 0 or blocks64 > cassafs.max_volume_blocks) {
        std.debug.print("cassafs: volume has {d} blocks, outside 1..{d}\n", .{ blocks64, cassafs.max_volume_blocks });
        std.process.exit(2);
    }
    var image = Image{ .file = file, .base = base, .blocks = @intCast(blocks64) };
    const device = cassafs.Device{
        .ctx = &image,
        .blocks = image.blocks,
        .read_fn = readBlock,
        .write_fn = writeBlock,
        .flush_fn = flushBlock,
    };

    var report = cassafs.scan(device, &workspace, &inodes) catch |err| {
        std.debug.print("cassafs: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, sub, "info")) {
        std.debug.print("cassafs host reader: {s}\n", .{path});
        reportInfo(&report);
    } else if (std.mem.eql(u8, sub, "verify")) {
        std.debug.print("cassafs host reader: {s}\n", .{path});
        reportInfo(&report);
        std.debug.print("  verify      : PASS (format, A/B superblocks, CRC32C records, inode tree, extents, free map)\n", .{});
    } else if (std.mem.eql(u8, sub, "dump")) {
        std.debug.print("cassafs host dump: {s}\n", .{path});
        reportDump(&report);
    } else if (std.mem.eql(u8, sub, "cat")) {
        const wanted = cat_path orelse usage();
        const n = cassafs.readFile(device, &report, wanted, &file_buffer) catch |err| {
            std.debug.print("cassafs: cat {s}: {s}\n", .{ wanted, @errorName(err) });
            std.process.exit(1);
        };
        const stdout = std.io.getStdOut();
        stdout.writeAll(file_buffer[0..n]) catch {};
        std.debug.print("cassafs: {s}, {d} byte(s), CRC32C 0x{x:0>8}\n", .{
            wanted, n, cassafs.crc32c(file_buffer[0..n]),
        });
    } else {
        usage();
    }
}
