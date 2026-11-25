//! Phase 47 retail store: the shell-facing retail commands and the CASSAFS
//! persistence path.
//!
//! The model lives in `src/lib/retail.zig` and is pure. This module owns three
//! bounded static buffers (current snapshot, staging snapshot and serialized
//! bytes), imports CSV rows from whatever the VFS exposes (including the real
//! FAT32 mount), and writes the snapshot through the normal VFS/CASSAFS
//! `writeAt` path. No separate block-device shortcut is used.
//!
//! A failed import or seed is staged into `g_stage`; `g_db` is only replaced
//! after every row and the final relation checks pass. The caller can still
//! lose an accepted write if the page cache has not been flushed, so commands
//! report exactly that distinction and the harness proves cache flush,
//! unmount/remount and reboot.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const kvfs = @import("vfs.zig");
const retail = @import("../lib/retail.zig");
const catalog_csv = @import("../lib/catalog_csv.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

const database_path = "/catalog/retail.db";

var g_db: retail.Db = .{};
var g_stage: retail.Db = .{};
var g_disk: [retail.file_bytes]u8 = undefined;

const ImportSink = struct {
    db: *retail.Db,
    reason: ?retail.Error = null,

    fn onRow(raw: *anyopaque, row: catalog_csv.Row) bool {
        const self: *ImportSink = @ptrCast(@alignCast(raw));
        const price = std.fmt.parseInt(u64, row.price_cents, 10) catch {
            self.reason = error.BadAmount;
            return false;
        };
        if (price > @as(u64, @intCast(std.math.maxInt(i64)))) {
            self.reason = error.BadAmount;
            return false;
        }
        _ = self.db.addProduct(row.sku, row.name, @intCast(price)) catch |err| {
            self.reason = err;
            return false;
        };
        return true;
    }
};

fn printError(err: anyerror) void {
    out("  retail       : {s}\n", .{@errorName(err)});
}

fn loadSnapshot() !void {
    const handle = try kvfs.fileOpen(database_path, .{ .read = true });
    defer kvfs.fileClose(handle);
    const stat = try kvfs.fileStat(handle);
    if (stat.size != retail.file_bytes) return error.Truncated;
    const got = try kvfs.fileReadAt(handle, 0, &g_disk);
    if (got != retail.file_bytes) return error.Truncated;
    try retail.decodeInto(&g_db, g_disk[0..]);
}

fn writeSnapshot(bytes: []const u8) !void {
    if (bytes.len > retail.file_bytes) return error.BufferTooSmall;
    const handle = try kvfs.fileOpen(database_path, .{ .read = false, .write = true, .create = true });
    defer kvfs.fileClose(handle);
    const wrote = try kvfs.fileWriteAt(handle, 0, bytes);
    if (wrote != bytes.len) return error.ShortWrite;
}

fn persist() !void {
    try retail.encode(&g_db, &g_disk);
    try writeSnapshot(g_disk[0..]);
}

fn loadOrInit() !void {
    loadSnapshot() catch |err| {
        if (err != error.NotFound) return err;
        g_db = retail.Db.init();
    };
}

fn initDb() void {
    g_db = retail.Db.init();
    persist() catch |err| {
        printError(err);
        return;
    };
    out("  retail init   : {s}, {d} byte empty snapshot committed to the VFS page cache\n", .{ database_path, retail.file_bytes });
}

fn importCsv(path: []const u8) void {
    loadOrInit() catch |err| {
        printError(err);
        return;
    };
    g_stage = g_db;
    const handle = kvfs.fileOpen(path, .{ .read = true }) catch |err| {
        printError(err);
        return;
    };
    defer kvfs.fileClose(handle);

    var parser = catalog_csv.Parser{};
    var sink = ImportSink{ .db = &g_stage };
    parser.row_sink = .{ .ctx = &sink, .on_row = ImportSink.onRow };

    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const got = kvfs.fileReadAt(handle, offset, &buffer) catch |err| {
            printError(err);
            return;
        };
        if (got == 0) break;
        parser.feed(buffer[0..got]) catch |err| {
            if (sink.reason) |reason| {
                out("  retail import : refused at byte {d}: {s}\n", .{ parser.bytes, @errorName(reason) });
            } else {
                out("  retail import : refused at byte {d}: {s}\n", .{ parser.bytes, @errorName(err) });
            }
            return;
        };
        offset += got;
    }
    const result = parser.finish() catch |err| {
        if (sink.reason) |reason| {
            out("  retail import : refused: {s}\n", .{@errorName(reason)});
        } else {
            out("  retail import : refused: {s}\n", .{@errorName(err)});
        }
        return;
    };
    if (sink.reason) |reason| {
        out("  retail import : refused: {s}\n", .{@errorName(reason)});
        return;
    }
    retail.validate(&g_stage) catch |err| {
        out("  retail import : refused by model validation: {s}\n", .{@errorName(err)});
        return;
    };

    g_db = g_stage;
    persist() catch |err| {
        printError(err);
        return;
    };
    out("  retail import : {s}, {d} row(s), {d} product(s), {d} byte CSV, {d} max line\n", .{
        path, result.rows, g_db.countKind(.product), result.bytes, result.max_line,
    });
    out("  retail import : {d} byte snapshot committed to the VFS page cache\n", .{retail.file_bytes});
}

fn seedDay() void {
    loadSnapshot() catch |err| {
        printError(err);
        return;
    };
    g_stage = g_db;
    retail.seedDay(&g_stage) catch |err| {
        out("  retail seed   : refused: {s}\n", .{@errorName(err)});
        return;
    };
    g_db = g_stage;
    persist() catch |err| {
        printError(err);
        return;
    };
    out("  retail seed   : {d} record(s), {d} receipt(s), {d} line(s) committed to the VFS page cache\n", .{
        g_db.header.count, g_db.countKind(.receipt), g_db.countKind(.sale_line),
    });
}

fn report() void {
    loadSnapshot() catch |err| {
        printError(err);
        return;
    };
    const summary = retail.summarize(&g_db) catch |err| {
        out("  retail report : REFUSED: {s}\n", .{@errorName(err)});
        return;
    };
    out("  retail report : {d} records, {d} products, {d} variants, {d} barcodes, {d} tax classes, {d} promotions\n", .{
        summary.records,
        g_db.countKind(.product),
        g_db.countKind(.variant),
        g_db.countKind(.barcode),
        g_db.countKind(.tax_class),
        g_db.countKind(.promotion),
    });
    out("  staff/day     : {d} users, {d} roles, {d} terminals, {d} shifts ({d} closed, {d} open), {d} drawers, {d} suppliers\n", .{
        g_db.countKind(.user),
        g_db.countKind(.role),
        g_db.countKind(.terminal),
        g_db.countKind(.shift),
        summary.closed_shifts,
        summary.open_shifts,
        g_db.countKind(.drawer),
        g_db.countKind(.supplier),
    });
    out("  sales         : {d} receipts, {d} lines, {d} units, subtotal {d}, tax {d}, total {d} cents\n", .{
        summary.receipts, summary.lines, summary.units, summary.subtotal, summary.tax, summary.total,
    });
    out("  tender        : {d} cents, cash {d}, change {d}, drawer variance {d}\n", .{
        summary.tender, summary.cash, summary.change, summary.variance,
    });
    if (g_db.find(summary.top_product)) |top| {
        out("  top product   : {s} {s}, {d} units, {d} cents\n", .{
            top.codeSlice(), top.nameSlice(), summary.top_units, summary.top_revenue,
        });
    } else {
        out("  top product   : none\n", .{});
    }
    out("  audit         : PASS (relations, receipt totals and tax recomputed)\n", .{});
}

fn verify() void {
    loadSnapshot() catch |err| {
        out("  retail verify : REFUSED: {s}\n", .{@errorName(err)});
        return;
    };
    retail.validate(&g_db) catch |err| {
        out("  retail verify : REFUSED: {s}\n", .{@errorName(err)});
        return;
    };
    out("  retail verify : PASS, {d} records, {d} bytes, generation {d}\n", .{
        g_db.header.count, retail.file_bytes, g_db.header.generation,
    });
}

fn corruptSnapshot() void {
    loadSnapshot() catch |err| {
        printError(err);
        return;
    };
    retail.encode(&g_db, &g_disk) catch |err| {
        printError(err);
        return;
    };
    // Flip a byte inside the first record's code field. The record CRC32C must
    // make the next load refuse it; a successful reload would be a data-loss bug.
    g_disk[retail.header_size + 65] ^= 0x80;
    writeSnapshot(g_disk[0..]) catch |err| {
        printError(err);
        return;
    };
    out("  retail corrupt : wrote a bad record and checksum intentionally; run 'retail verify'\n", .{});
}

pub fn command(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "help";
    if (std.mem.eql(u8, sub, "init")) {
        initDb();
    } else if (std.mem.eql(u8, sub, "import")) {
        const path = tokens.next() orelse {
            out("  usage: retail import <csv-path>\n", .{});
            return;
        };
        importCsv(path);
    } else if (std.mem.eql(u8, sub, "seedday")) {
        seedDay();
    } else if (std.mem.eql(u8, sub, "report") or std.mem.eql(u8, sub, "info")) {
        report();
    } else if (std.mem.eql(u8, sub, "verify")) {
        verify();
    } else if (std.mem.eql(u8, sub, "corrupt")) {
        corruptSnapshot();
    } else {
        out("  usage: retail [init|import <csv>|seedday|report|verify|corrupt]\n", .{});
    }
}
