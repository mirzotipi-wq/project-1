//! Phase 48 sale log front end.
//!
//! A committed sale is one appended 512-byte record in `/catalog/sales.log`.
//! The record is serialized from catalog prices, appended at the committed file
//! end through the VFS/CASSAFS write path, flushed, and read back before the
//! shell reports success. Replay and duplicate detection are pure scans over the
//! committed prefix, so a retry after a reboot cannot count the same
//! `(terminal, txn_id)` twice.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");
const kvfs = @import("vfs.zig");
const retail = @import("retail.zig");
const retail_lib = @import("../lib/retail.zig");
const sale_log = @import("../lib/sale_log.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

const log_path = "/catalog/sales.log";

var g_log: sale_log.Log = .{};
var g_buf: [sale_log.max_file_bytes]u8 = undefined;

const Item = struct {
    code: []const u8,
    price: i64,
    tax_rate: u16,
};

fn printError(context: []const u8, err: anyerror) void {
    out("  {s} : REFUSED: {s}\n", .{ context, @errorName(err) });
}

fn loadLog() !void {
    const handle = try kvfs.fileOpen(log_path, .{ .read = true });
    defer kvfs.fileClose(handle);
    const stat = try kvfs.fileStat(handle);
    if (stat.size < sale_log.header_size) return error.Truncated;
    if (stat.size > sale_log.max_file_bytes) return error.TooLarge;
    const size: usize = @intCast(stat.size);
    const got = try kvfs.fileReadAt(handle, 0, g_buf[0..size]);
    if (got != size) return error.Truncated;
    try sale_log.decodeInto(&g_log, g_buf[0..size]);
}

fn createLog() !void {
    const handle = try kvfs.fileOpen(log_path, .{ .read = true, .write = true, .create = true });
    defer kvfs.fileClose(handle);
    const stat = try kvfs.fileStat(handle);
    if (stat.size != 0) return error.Exists;
    var header: [sale_log.header_size]u8 = undefined;
    sale_log.encodeHeader(&header);
    const wrote = try kvfs.fileWriteAt(handle, 0, header[0..]);
    if (wrote != header.len) return error.ShortWrite;
    try kvfs.flushCache();
    const after = try kvfs.fileStat(handle);
    if (after.size != sale_log.header_size) return error.CommitUnverified;
    g_log = sale_log.Log.init();
}

fn ensureLog() !void {
    loadLog() catch |err| {
        if (err != error.NotFound) return err;
        try createLog();
    };
}

fn resolveItem(db: *const retail_lib.Db, code: []const u8) !Item {
    var item_code = code;
    var price: i64 = 0;
    var product: *const retail_lib.Record = undefined;
    if (db.findCode(.product, code)) |product_rec| {
        product = product_rec;
        price = product_rec.amount;
    } else if (db.findCode(.variant, code)) |variant| {
        product = db.findKind(.product, variant.parent) orelse return error.CatalogItemMissing;
        price = if (variant.amount != 0) variant.amount else product.amount;
        item_code = code;
    } else {
        return error.CatalogItemMissing;
    }
    var rate: u16 = 0;
    if (product.ref1 != 0) {
        const tax = db.findKind(.tax_class, product.ref1) orelse return error.CatalogTaxMissing;
        if (tax.amount < 0 or tax.amount > 10_000) return error.CatalogTaxMissing;
        rate = @intCast(tax.amount);
    }
    return .{ .code = item_code, .price = price, .tax_rate = rate };
}

fn terminalCode(db: *const retail_lib.Db, id: u32) []const u8 {
    if (db.findKind(.terminal, id)) |term| return term.codeSlice();
    return "?";
}

fn catalogTicket() !void {
    try retail.loadForSales();
    const db = retail.saleDb();
    try retail_lib.validate(db);
    var i: usize = 0;
    while (i < g_log.count) : (i += 1) {
        const txn = &g_log.records[i];
        if (db.findKind(.terminal, txn.terminal_id) == null) return error.TerminalMissing;
        var j: usize = 0;
        while (j < txn.line_count) : (j += 1) {
            const line = &txn.lines[j];
            const item = resolveItem(db, line.codeSlice()) catch |err| return err;
            if (line.unit_price != item.price) return error.PriceMismatch;
            if (line.tax != retail_lib.taxFor(line.total, item.tax_rate)) return error.TaxMismatch;
        }
    }
}

fn appendRecord(index: usize) !void {
    var record: [sale_log.record_size]u8 = undefined;
    sale_log.encodeRecord(&g_log.records[index], &record);
    const offset: u64 = sale_log.header_size + @as(u64, @intCast(index * sale_log.record_size));
    const handle = try kvfs.fileOpen(log_path, .{ .read = true, .write = true });
    defer kvfs.fileClose(handle);
    const before = try kvfs.fileStat(handle);
    if (before.size != offset) return error.LogTruncated;
    const wrote = try kvfs.fileWriteAt(handle, offset, record[0..]);
    if (wrote != record.len) return error.ShortWrite;
    try kvfs.flushCache();
    const after = try kvfs.fileStat(handle);
    if (after.size != offset + record.len) return error.CommitUnverified;
    loadLog() catch |err| {
        // The append was accepted by the VFS but did not survive the immediate
        // readback. Never report it as committed.
        printError("sales commit", err);
        return error.CommitUnverified;
    };
}

fn sell(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const terminal_text = tokens.next() orelse {
        out("  usage: sales sell <terminal> <txn-id> <sku> <qty> [<sku> <qty> ...]\n", .{});
        return;
    };
    const txn_text = tokens.next() orelse {
        out("  usage: sales sell <terminal> <txn-id> <sku> <qty> [<sku> <qty> ...]\n", .{});
        return;
    };
    const txn_id = std.fmt.parseInt(u64, txn_text, 10) catch {
        out("  sales sell : REFUSED: BadTxnId\n", .{});
        return;
    };
    if (txn_id == 0) {
        out("  sales sell : REFUSED: BadTxnId\n", .{});
        return;
    }

    retail.loadForSales() catch |err| {
        printError("sales sell", err);
        return;
    };
    const db = retail.saleDb();
    retail_lib.validate(db) catch |err| {
        printError("sales sell", err);
        return;
    };
    const terminal = db.findCode(.terminal, terminal_text) orelse {
        out("  sales sell : REFUSED: UnknownTerminal\n", .{});
        return;
    };

    var tx = sale_log.Txn{};
    tx.txn_id = txn_id;
    tx.terminal_id = terminal.id;
    tx.flags = 3;
    var subtotal: i64 = 0;
    var tax: i64 = 0;
    var line_count: usize = 0;
    while (tokens.next()) |sku| {
        const qty_text = tokens.next() orelse {
            out("  sales sell : REFUSED: BadLine\n", .{});
            return;
        };
        if (line_count == sale_log.max_lines) {
            out("  sales sell : REFUSED: TooManyLines\n", .{});
            return;
        }
        const qty = std.fmt.parseInt(i32, qty_text, 10) catch {
            out("  sales sell : REFUSED: BadQty\n", .{});
            return;
        };
        if (qty <= 0 or qty > max_qty) {
            out("  sales sell : REFUSED: BadQty\n", .{});
            return;
        }
        const item = resolveItem(db, sku) catch |err| {
            printError("sales sell", err);
            return;
        };
        if (item.code.len > sale_log.max_code) {
            out("  sales sell : REFUSED: BadCode\n", .{});
            return;
        }
        const line_total = std.math.mul(i64, item.price, @as(i64, qty)) catch {
            out("  sales sell : REFUSED: BadAmount\n", .{});
            return;
        };
        const line_tax = retail_lib.taxFor(line_total, item.tax_rate);
        var line = &tx.lines[line_count];
        line.setCode(item.code) catch {
            out("  sales sell : REFUSED: BadCode\n", .{});
            return;
        };
        line.qty = qty;
        line.unit_price = item.price;
        line.tax = line_tax;
        line.total = line_total;
        subtotal = std.math.add(i64, subtotal, line_total) catch {
            out("  sales sell : REFUSED: BadAmount\n", .{});
            return;
        };
        tax = std.math.add(i64, tax, line_tax) catch {
            out("  sales sell : REFUSED: BadAmount\n", .{});
            return;
        };
        line_count += 1;
    }
    if (line_count == 0) {
        out("  sales sell : REFUSED: BadLine\n", .{});
        return;
    }
    tx.line_count = @intCast(line_count);
    tx.subtotal = subtotal;
    tx.tax = tax;
    tx.total = std.math.add(i64, subtotal, tax) catch {
        out("  sales sell : REFUSED: BadAmount\n", .{});
        return;
    };
    tx.tender = tx.total;
    tx.time = timer.uptimeMs();

    ensureLog() catch |err| {
        printError("sales sell", err);
        return;
    };
    tx.terminal_seq = g_log.nextTerminalSequence(terminal.id) catch |err| {
        printError("sales sell", err);
        return;
    };
    const result = g_log.insert(&tx) catch |err| {
        printError("sales sell", err);
        return;
    };
    if (!result.appended) {
        const existing = &g_log.records[result.index];
        out("  sales sell : duplicate terminal {s} txn {d} at sequence {d}; no append, no double count\n", .{
            terminal.codeSlice(), txn_id, existing.sequence,
        });
        return;
    }

    const index = result.index;
    appendRecord(index) catch |err| {
        printError("sales sell", err);
        return;
    };
    const committed = &g_log.records[index];
    out("  sales commit: seq {d}, terminal {s} (id {d}, local {d}), txn {d}, receipt {d}\n", .{
        committed.sequence, terminal.codeSlice(), committed.terminal_id, committed.terminal_seq,
        committed.txn_id,   committed.receipt_no,
    });
    out("  sales commit: {d} line(s), subtotal {d}, tax {d}, total {d} cents, flush + reread PASS\n", .{
        committed.line_count, committed.subtotal, committed.tax, committed.total,
    });
    out("  sales commit: {d} B record at offset {d}, {d} B log, next sequence {d}\n", .{
        sale_log.record_size,                                                  sale_log.header_size + @as(u64, @intCast(index * sale_log.record_size)),
        sale_log.header_size + @as(usize, g_log.count) * sale_log.record_size, committed.sequence + 1,
    });
}

const max_qty: i32 = 1_000_000;

fn report() void {
    loadLog() catch |err| {
        printError("sales report", err);
        return;
    };
    const summary = g_log.summarize() catch |err| {
        printError("sales report", err);
        return;
    };
    out("  sales report : {d} transaction(s), {d} unit(s), subtotal {d}, tax {d}, total {d} cents\n", .{
        summary.transactions, summary.units, summary.subtotal, summary.tax, summary.total,
    });
    if (summary.transactions == 0) {
        out("  sales chain : empty, first sequence 1\n", .{});
        out("  sales terminal: none\n", .{});
        return;
    }
    out("  sales chain : seq {d}..{d}, chain CRC 0x{x:0>8}\n", .{
        summary.first_sequence, summary.last_sequence, summary.last_crc,
    });

    var terminal_ids: [16]u32 = [_]u32{0} ** 16;
    var terminal_counts: [16]u32 = [_]u32{0} ** 16;
    var terminal_totals: [16]i64 = [_]i64{0} ** 16;
    var terminal_count: usize = 0;
    var i: usize = 0;
    while (i < g_log.count) : (i += 1) {
        const txn = &g_log.records[i];
        var t: usize = 0;
        while (t < terminal_count) : (t += 1) {
            if (terminal_ids[t] == txn.terminal_id) break;
        }
        if (t == terminal_count) {
            terminal_ids[t] = txn.terminal_id;
            terminal_count += 1;
        }
        terminal_counts[t] += 1;
        terminal_totals[t] += txn.total;
    }
    out("  sales terminals: {d} distinct\n", .{terminal_count});
    retail.loadForSales() catch {};
    const db = retail.saleDb();
    var t: usize = 0;
    while (t < terminal_count) : (t += 1) {
        const code = terminalCode(db, terminal_ids[t]);
        out("  sales terminal : {s} (id {d}) {d} txn(s), total {d} cents\n", .{
            code, terminal_ids[t], terminal_counts[t], terminal_totals[t],
        });
    }
}

fn verify() void {
    loadLog() catch |err| {
        printError("sales verify", err);
        return;
    };
    g_log.verify() catch |err| {
        printError("sales verify", err);
        return;
    };
    catalogTicket() catch |err| {
        printError("sales verify", err);
        return;
    };
    const summary = g_log.summarize() catch |err| {
        printError("sales verify", err);
        return;
    };
    out("  sales verify : PASS, {d} transaction(s), chain CRC 0x{x:0>8}, {d} terminal(s)\n", .{
        summary.transactions, summary.last_crc, summary.terminals,
    });
}

fn replay() void {
    loadLog() catch |err| {
        printError("sales replay", err);
        return;
    };
    g_log.verify() catch |err| {
        printError("sales replay", err);
        return;
    };
    catalogTicket() catch |err| {
        printError("sales replay", err);
        return;
    };
    retail.loadForSales() catch {};
    const db = retail.saleDb();
    var i: usize = 0;
    while (i < g_log.count) : (i += 1) {
        const txn = &g_log.records[i];
        const code = terminalCode(db, txn.terminal_id);
        out("  sales replay : [seq {d}] {s} txn {d} receipt {d} lines {d} total {d}\n", .{
            txn.sequence, code, txn.txn_id, txn.receipt_no, txn.line_count, txn.total,
        });
    }
    out("  sales replay : PASS, {d} transaction(s)\n", .{g_log.count});
}

fn corrupt() void {
    loadLog() catch |err| {
        printError("sales corrupt", err);
        return;
    };
    if (g_log.count == 0) {
        out("  sales corrupt : REFUSED: LogEmpty\n", .{});
        return;
    }
    const offset: u64 = sale_log.header_size + @as(u64, g_log.count - 1) * sale_log.record_size + 20;
    const handle = kvfs.fileOpen(log_path, .{ .read = true, .write = true }) catch |err| {
        printError("sales corrupt", err);
        return;
    };
    defer kvfs.fileClose(handle);
    var one: [1]u8 = undefined;
    const got = kvfs.fileReadAt(handle, offset, &one) catch |err| {
        printError("sales corrupt", err);
        return;
    };
    if (got != 1) {
        out("  sales corrupt : REFUSED: Truncated\n", .{});
        return;
    }
    one[0] ^= 0x40;
    const wrote = kvfs.fileWriteAt(handle, offset, one[0..]) catch |err| {
        printError("sales corrupt", err);
        return;
    };
    if (wrote != 1) {
        out("  sales corrupt : REFUSED: ShortWrite\n", .{});
        return;
    }
    kvfs.flushCache() catch |err| {
        printError("sales corrupt", err);
        return;
    };
    out("  sales corrupt : flipped one byte in sequence {d}; run 'sales verify'\n", .{
        g_log.records[g_log.count - 1].sequence,
    });
}

fn initLog() void {
    loadLog() catch |err| {
        if (err != error.NotFound) {
            printError("sales init", err);
            return;
        }
        createLog() catch |create_err| {
            printError("sales init", create_err);
            return;
        };
        out("  sales init : {s}, {d} B header, 0/{d} transactions, capacity {d} B\n", .{
            log_path, sale_log.header_size, sale_log.max_records, sale_log.max_file_bytes,
        });
        return;
    };
    out("  sales init : REFUSED: Exists ({d} transaction(s) already committed)\n", .{g_log.count});
}

pub fn command(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "help";
    if (std.mem.eql(u8, sub, "init")) {
        initLog();
    } else if (std.mem.eql(u8, sub, "sell") or std.mem.eql(u8, sub, "commit")) {
        sell(tokens);
    } else if (std.mem.eql(u8, sub, "report") or std.mem.eql(u8, sub, "info")) {
        report();
    } else if (std.mem.eql(u8, sub, "verify")) {
        verify();
    } else if (std.mem.eql(u8, sub, "replay")) {
        replay();
    } else if (std.mem.eql(u8, sub, "corrupt")) {
        corrupt();
    } else {
        out("  usage: sales [init|sell <terminal> <txn> <sku> <qty> ...|report|verify|replay|corrupt]\n", .{});
    }
}
