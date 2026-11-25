//! Phase 48 transactional sale log.
//!
//! The log is the commit point. A sale transaction is serialized into one fixed
//! 512-byte record, chained to the previous record with CRC32C, appended through
//! the VFS/CASSAFS write path and flushed before the shell reports it committed.
//! Replay is a pure scan: a transaction is present exactly when its record is in
//! the committed file prefix, so a retry after a crash or network disconnect can
//! be deduplicated by `(terminal_id, txn_id)` without double-counting.
//!
//! The header carries no mutable count. The number of records is derived from
//! the committed file length, which keeps append a single record write and
//! prevents a half-updated header from claiming records that are not present.
//!
//! Bounds: 16 transactions, 4 lines each, 512-byte records. There is no
//! allocator, no unbounded replay loop, and no silent overwrite when full.

const std = @import("std");
const cassafs = @import("cassafs.zig");

pub const version: u16 = 1;
pub const header_size: usize = 64;
pub const record_size: usize = 512;
pub const max_records: usize = 16;
pub const max_lines: usize = 4;
pub const max_file_bytes: usize = header_size + max_records * record_size;
pub const max_code: usize = 16;
/// Money is held in cents. These bounds keep every sum in `i64` and make an
/// out-of-range catalog price a refusal instead of an overflow.
pub const max_amount: i64 = 1_000_000_000_000;
pub const max_total: i64 = 8 * max_amount;
pub const header_magic: [8]u8 = .{ 'C', 'S', 'L', 'O', 'G', '4', '8', 0 };
pub const record_magic: [8]u8 = .{ 'C', 'S', 'T', 'X', 'N', '4', '8', 0 };
pub const record_crc_offset: usize = 508;
pub const record_crc_bytes: usize = 508;

pub const Error = error{
    InvalidMagic,
    InvalidVersion,
    Truncated,
    TooLarge,
    Corrupt,
    RecordCorrupt,
    BadLine,
    BadCode,
    BadQty,
    BadAmount,
    BadTax,
    BadTotals,
    BadSequence,
    BadChain,
    DuplicateKey,
    Conflict,
    Full,
    NoSpace,
    BufferTooSmall,
};

pub const Line = struct {
    code: [max_code]u8 = [_]u8{0} ** max_code,
    code_len: u8 = 0,
    qty: i32 = 0,
    unit_price: i64 = 0,
    tax: i64 = 0,
    total: i64 = 0,

    pub fn codeSlice(self: *const Line) []const u8 {
        return self.code[0..self.code_len];
    }

    pub fn setCode(self: *Line, text: []const u8) Error!void {
        if (text.len == 0 or text.len > max_code) return error.BadCode;
        @memset(self.code[0..], 0);
        @memcpy(self.code[0..text.len], text);
        self.code_len = @intCast(text.len);
    }
};

pub const Txn = struct {
    sequence: u64 = 0,
    txn_id: u64 = 0,
    terminal_id: u32 = 0,
    terminal_seq: u32 = 0,
    receipt_no: u32 = 0,
    flags: u16 = 0,
    subtotal: i64 = 0,
    tax: i64 = 0,
    total: i64 = 0,
    tender: i64 = 0,
    time: u64 = 0,
    prev_crc: u32 = 0,
    crc: u32 = 0,
    line_count: u8 = 0,
    lines: [max_lines]Line = [_]Line{.{}} ** max_lines,
};

pub const InsertResult = struct {
    appended: bool,
    index: usize,
};

pub const Summary = struct {
    transactions: u32 = 0,
    units: i64 = 0,
    subtotal: i64 = 0,
    tax: i64 = 0,
    total: i64 = 0,
    tender: i64 = 0,
    first_sequence: u64 = 0,
    last_sequence: u64 = 0,
    last_crc: u32 = 0,
    terminals: u16 = 0,
};

pub const Log = struct {
    count: u16 = 0,
    records: [max_records]Txn = [_]Txn{.{}} ** max_records,

    pub fn init() Log {
        return .{};
    }

    pub fn findKey(self: *const Log, terminal_id: u32, txn_id: u64) ?*const Txn {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const rec = &self.records[i];
            if (rec.terminal_id == terminal_id and rec.txn_id == txn_id) return rec;
        }
        return null;
    }

    pub fn nextTerminalSequence(self: *const Log, terminal_id: u32) Error!u32 {
        var last: u32 = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const rec = &self.records[i];
            if (rec.terminal_id != terminal_id) continue;
            if (rec.terminal_seq > last) last = rec.terminal_seq;
        }
        if (last == std.math.maxInt(u32)) return error.BadSequence;
        return last + 1;
    }

    /// Add a sale at the tail. Duplicate keys are resolved before capacity or
    /// terminal-sequence checks: an idempotent retry is not a new transaction.
    pub fn insert(self: *Log, tx: *const Txn) Error!InsertResult {
        if (self.findKey(tx.terminal_id, tx.txn_id)) |existing| {
            if (sameSale(existing, tx)) {
                return .{ .appended = false, .index = indexOf(self, existing) };
            }
            return error.Conflict;
        }
        if (self.count >= max_records) return error.Full;
        try validateShape(tx);
        const expected_terminal_seq = try self.nextTerminalSequence(tx.terminal_id);
        if (tx.terminal_seq != expected_terminal_seq) return error.BadSequence;

        var rec = tx.*;
        rec.sequence = @as(u64, self.count) + 1;
        rec.receipt_no = @intCast(rec.sequence);
        rec.prev_crc = if (self.count == 0) 0 else self.records[self.count - 1].crc;
        rec.crc = 0;
        rec.crc = recordCrc(&rec);
        self.records[self.count] = rec;
        self.count += 1;
        return .{ .appended = true, .index = self.count - 1 };
    }

    pub fn verify(self: *const Log) Error!void {
        if (self.count > max_records) return error.Corrupt;
        var terminals: [16]struct { id: u32, seq: u32 } = undefined;
        var terminal_count: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const rec = &self.records[i];
            try validateShape(rec);
            if (rec.sequence != @as(u64, i) + 1) return error.BadSequence;
            if (rec.receipt_no != @as(u32, @intCast(rec.sequence))) return error.BadSequence;
            const expected_prev = if (i == 0) 0 else self.records[i - 1].crc;
            if (rec.prev_crc != expected_prev) return error.BadChain;
            if (rec.crc != recordCrc(rec)) return error.RecordCorrupt;

            var t: usize = 0;
            while (t < terminal_count) : (t += 1) {
                if (terminals[t].id == rec.terminal_id) break;
            }
            if (t == terminal_count) {
                if (rec.terminal_seq != 1) return error.BadSequence;
                if (terminal_count == terminals.len) return error.Corrupt;
                terminals[terminal_count] = .{ .id = rec.terminal_id, .seq = rec.terminal_seq };
                terminal_count += 1;
            } else {
                if (terminals[t].seq == std.math.maxInt(u32)) return error.BadSequence;
                if (rec.terminal_seq != terminals[t].seq + 1) return error.BadSequence;
                terminals[t].seq = rec.terminal_seq;
            }

            var j: usize = 0;
            while (j < i) : (j += 1) {
                const earlier = &self.records[j];
                if (earlier.terminal_id == rec.terminal_id and earlier.txn_id == rec.txn_id) {
                    return error.DuplicateKey;
                }
            }
        }
    }

    pub fn summarize(self: *const Log) Error!Summary {
        try self.verify();
        var out = Summary{};
        out.transactions = self.count;
        if (self.count != 0) {
            out.first_sequence = self.records[0].sequence;
            out.last_sequence = self.records[self.count - 1].sequence;
            out.last_crc = self.records[self.count - 1].crc;
        }
        var seen: [16]u32 = undefined;
        var seen_count: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const rec = &self.records[i];
            out.subtotal += rec.subtotal;
            out.tax += rec.tax;
            out.total += rec.total;
            out.tender += rec.tender;
            var j: usize = 0;
            while (j < rec.line_count) : (j += 1) out.units += rec.lines[j].qty;
            var k: usize = 0;
            while (k < seen_count) : (k += 1) {
                if (seen[k] == rec.terminal_id) break;
            }
            if (k == seen_count) {
                if (seen_count == seen.len) return error.Corrupt;
                seen[seen_count] = rec.terminal_id;
                seen_count += 1;
            }
        }
        out.terminals = @intCast(seen_count);
        return out;
    }
};

fn indexOf(log: *const Log, target: *const Txn) usize {
    var i: usize = 0;
    while (i < log.count) : (i += 1) {
        if (&log.records[i] == target) return i;
    }
    return 0;
}

fn sameSale(a: *const Txn, b: *const Txn) bool {
    if (a.terminal_id != b.terminal_id or a.txn_id != b.txn_id) return false;
    if (a.flags != b.flags or a.line_count != b.line_count) return false;
    if (a.subtotal != b.subtotal or a.tax != b.tax or a.total != b.total or a.tender != b.tender) return false;
    var i: usize = 0;
    while (i < a.line_count) : (i += 1) {
        const x = &a.lines[i];
        const y = &b.lines[i];
        if (x.code_len != y.code_len or x.qty != y.qty or
            x.unit_price != y.unit_price or x.tax != y.tax or x.total != y.total)
        {
            return false;
        }
        if (!std.mem.eql(u8, x.codeSlice(), y.codeSlice())) return false;
    }
    return true;
}

fn validateShape(tx: *const Txn) Error!void {
    if (tx.terminal_id == 0 or tx.txn_id == 0) return error.BadLine;
    if (tx.line_count == 0 or tx.line_count > max_lines) return error.BadLine;
    if ((tx.flags & ~@as(u16, 3)) != 0 or (tx.flags & 1) == 0) return error.BadLine;
    if (tx.subtotal < 0 or tx.tax < 0 or tx.total < 0 or tx.tender < 0) return error.BadAmount;
    if (tx.subtotal > max_total or tx.tax > max_total or tx.total > max_total or tx.tender > max_total) return error.BadAmount;
    var subtotal: i64 = 0;
    var tax: i64 = 0;
    var i: usize = 0;
    while (i < tx.line_count) : (i += 1) {
        const line = &tx.lines[i];
        if (line.code_len == 0 or line.code_len > max_code) return error.BadCode;
        if (line.qty <= 0 or line.unit_price < 0 or line.tax < 0 or line.total < 0) return error.BadAmount;
        if (line.unit_price > max_amount or line.total > max_amount or line.tax > max_amount) return error.BadAmount;
        const expected = std.math.mul(i64, line.unit_price, @as(i64, line.qty)) catch return error.BadAmount;
        if (line.total != expected) return error.BadTotals;
        if (line.tax > line.total) return error.BadTax;
        subtotal = std.math.add(i64, subtotal, line.total) catch return error.BadAmount;
        tax = std.math.add(i64, tax, line.tax) catch return error.BadAmount;
    }
    if (subtotal != tx.subtotal or tax != tx.tax) return error.BadTotals;
    const total = std.math.add(i64, subtotal, tax) catch return error.BadAmount;
    if (total != tx.total) return error.BadTotals;
    if (tx.tender < tx.total) return error.BadTotals;
}

fn crc32c(bytes: []const u8) u32 {
    return ~cassafs.crc32cUpdate(0xffffffff, bytes);
}

fn put16(buf: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], value, .little);
}

fn put32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

fn put64(buf: []u8, off: usize, value: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], value, .little);
}

fn get16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

fn get32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn get64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

pub fn encodeHeader(out: *[header_size]u8) void {
    @memset(out[0..], 0);
    @memcpy(out[0..8], header_magic[0..]);
    put16(out[0..], 8, version);
    put16(out[0..], 10, record_size);
    put16(out[0..], 12, @intCast(max_records));
    put32(out[0..], 60, crc32c(out[0..60]));
}

fn encodeLine(line: *const Line, out: []u8) void {
    @memset(out[0..64], 0);
    @memcpy(out[0..16], line.code[0..]);
    out[16] = line.code_len;
    put32(out[0..], 20, @bitCast(line.qty));
    put64(out[0..], 24, @bitCast(line.unit_price));
    put64(out[0..], 32, @bitCast(line.tax));
    put64(out[0..], 40, @bitCast(line.total));
}

fn decodeLine(bytes: []const u8) Error!Line {
    var line = Line{};
    line.code_len = bytes[16];
    if (line.code_len == 0 or line.code_len > max_code) return error.BadCode;
    @memcpy(line.code[0..], bytes[0..16]);
    line.qty = @bitCast(get32(bytes, 20));
    line.unit_price = @bitCast(get64(bytes, 24));
    line.tax = @bitCast(get64(bytes, 32));
    line.total = @bitCast(get64(bytes, 40));
    return line;
}

fn encodeRecordBody(tx: *const Txn, out: *[record_size]u8) void {
    @memset(out[0..], 0);
    @memcpy(out[0..8], record_magic[0..]);
    put16(out[0..], 8, version);
    put16(out[0..], 10, record_size);
    put16(out[0..], 12, tx.line_count);
    put16(out[0..], 14, tx.flags);
    put64(out[0..], 16, tx.sequence);
    put64(out[0..], 24, tx.txn_id);
    put32(out[0..], 32, tx.terminal_id);
    put32(out[0..], 36, tx.terminal_seq);
    put32(out[0..], 40, tx.receipt_no);
    put64(out[0..], 48, @bitCast(tx.subtotal));
    put64(out[0..], 56, @bitCast(tx.tax));
    put64(out[0..], 64, @bitCast(tx.total));
    put64(out[0..], 72, @bitCast(tx.tender));
    put64(out[0..], 80, tx.time);
    put32(out[0..], 88, tx.prev_crc);
    var i: usize = 0;
    while (i < max_lines) : (i += 1) {
        encodeLine(&tx.lines[i], out[96 + i * 64 ..][0..64]);
    }
}

fn recordCrc(tx: *const Txn) u32 {
    var bytes: [record_size]u8 = undefined;
    encodeRecordBody(tx, &bytes);
    return crc32c(bytes[0..record_crc_bytes]);
}

pub fn encodeRecord(tx: *const Txn, out: *[record_size]u8) void {
    encodeRecordBody(tx, out);
    put32(out[0..], record_crc_offset, crc32c(out[0..record_crc_bytes]));
}

fn decodeRecord(bytes: *const [record_size]u8) Error!Txn {
    if (get32(bytes, record_crc_offset) != crc32c(bytes[0..record_crc_bytes])) return error.RecordCorrupt;
    if (!std.mem.eql(u8, bytes[0..8], record_magic[0..])) return error.InvalidMagic;
    if (get16(bytes, 8) != version or get16(bytes, 10) != record_size) return error.InvalidVersion;
    var tx = Txn{};
    tx.line_count = @intCast(get16(bytes, 12));
    tx.flags = get16(bytes, 14);
    tx.sequence = get64(bytes, 16);
    tx.txn_id = get64(bytes, 24);
    tx.terminal_id = get32(bytes, 32);
    tx.terminal_seq = get32(bytes, 36);
    tx.receipt_no = get32(bytes, 40);
    tx.subtotal = @bitCast(get64(bytes, 48));
    tx.tax = @bitCast(get64(bytes, 56));
    tx.total = @bitCast(get64(bytes, 64));
    tx.tender = @bitCast(get64(bytes, 72));
    tx.time = get64(bytes, 80);
    tx.prev_crc = get32(bytes, 88);
    tx.crc = get32(bytes, record_crc_offset);
    if (tx.line_count == 0 or tx.line_count > max_lines) return error.BadLine;
    var i: usize = 0;
    while (i < tx.line_count) : (i += 1) tx.lines[i] = try decodeLine(bytes[96 + i * 64 ..][0..64]);
    return tx;
}

pub fn encode(log: *const Log, out: *[max_file_bytes]u8) Error![]const u8 {
    if (log.count > max_records) return error.Corrupt;
    @memset(out[0..], 0);
    var header: [header_size]u8 = undefined;
    encodeHeader(&header);
    @memcpy(out[0..header_size], header[0..]);
    var i: usize = 0;
    while (i < log.count) : (i += 1) {
        var record: [record_size]u8 = undefined;
        encodeRecord(&log.records[i], &record);
        const off = header_size + i * record_size;
        @memcpy(out[off..][0..record_size], record[0..]);
    }
    return out[0 .. header_size + @as(usize, log.count) * record_size];
}

pub fn decodeInto(log: *Log, data: []const u8) Error!void {
    if (data.len < header_size) return error.Truncated;
    if (data.len > max_file_bytes) return error.TooLarge;
    if (!std.mem.eql(u8, data[0..8], header_magic[0..])) return error.InvalidMagic;
    if (get16(data, 8) != version or get16(data, 10) != record_size) return error.InvalidVersion;
    if (get16(data, 12) != max_records) return error.InvalidVersion;
    if (get32(data, 60) != crc32c(data[0..60])) return error.Corrupt;
    const body = data.len - header_size;
    if (body % record_size != 0) return error.Truncated;
    const count = body / record_size;
    if (count > max_records) return error.TooLarge;
    log.* = Log.init();
    log.count = @intCast(count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = header_size + i * record_size;
        const record: *const [record_size]u8 = data[off..][0..record_size];
        log.records[i] = try decodeRecord(record);
    }
    try log.verify();
}

pub fn decode(data: []const u8) Error!Log {
    var log = Log.init();
    try decodeInto(&log, data);
    return log;
}

fn testTxn(txn_id: u64, terminal_id: u32, terminal_seq: u32, code: []const u8, qty: i32, price: i64) !Txn {
    var tx = Txn{};
    tx.txn_id = txn_id;
    tx.terminal_id = terminal_id;
    tx.terminal_seq = terminal_seq;
    tx.flags = 3;
    tx.line_count = 1;
    try tx.lines[0].setCode(code);
    tx.lines[0].qty = qty;
    tx.lines[0].unit_price = price;
    tx.lines[0].total = price * qty;
    tx.subtotal = tx.lines[0].total;
    tx.total = tx.subtotal;
    tx.tender = tx.total;
    return tx;
}

test "sale log round-trips with sequence and chain" {
    var log = Log.init();
    const a = try testTxn(1001, 7, 1, "SKU1", 2, 250);
    const b = try testTxn(1002, 7, 2, "SKU2", 1, 180);
    _ = try log.insert(&a);
    _ = try log.insert(&b);
    try log.verify();
    var bytes: [max_file_bytes]u8 = undefined;
    const encoded = try encode(&log, &bytes);
    try std.testing.expectEqual(header_size + 2 * record_size, encoded.len);
    const decoded = try decode(encoded);
    try std.testing.expectEqual(@as(u16, 2), decoded.count);
    try std.testing.expectEqual(@as(u64, 1), decoded.records[0].sequence);
    try std.testing.expectEqual(@as(u64, 2), decoded.records[1].sequence);
    try std.testing.expectEqual(decoded.records[0].crc, decoded.records[1].prev_crc);
    const summary = try decoded.summarize();
    try std.testing.expectEqual(@as(u32, 2), summary.transactions);
    try std.testing.expectEqual(@as(i64, 680), summary.total);
    try std.testing.expectEqual(@as(i64, 3), summary.units);
}

test "duplicate transaction keys are idempotent and payload changes conflict" {
    var log = Log.init();
    const a = try testTxn(1001, 7, 1, "SKU1", 2, 250);
    const first = try log.insert(&a);
    try std.testing.expect(first.appended);
    const retry = try log.insert(&a);
    try std.testing.expect(!retry.appended);
    try std.testing.expectEqual(@as(usize, 0), retry.index);
    try std.testing.expectEqual(@as(u16, 1), log.count);

    var changed = a;
    changed.lines[0].qty = 3;
    changed.lines[0].total = 750;
    changed.subtotal = 750;
    changed.total = 750;
    changed.tender = 750;
    try std.testing.expectError(error.Conflict, log.insert(&changed));
    try std.testing.expectEqual(@as(u16, 1), log.count);
}

test "sale log refuses corrupted records and broken sequence chains" {
    var log = Log.init();
    const a = try testTxn(1001, 7, 1, "SKU1", 1, 100);
    const b = try testTxn(1002, 7, 2, "SKU2", 1, 100);
    _ = try log.insert(&a);
    _ = try log.insert(&b);
    var bytes: [max_file_bytes]u8 = undefined;
    const encoded = try encode(&log, &bytes);
    var damaged = bytes;
    damaged[header_size + 30] ^= 0x40;
    try std.testing.expectError(error.RecordCorrupt, decode(damaged[0..encoded.len]));

    var broken = log;
    broken.records[1].prev_crc ^= 0x1;
    var record: [record_size]u8 = undefined;
    encodeRecord(&broken.records[1], &record);
    var broken_bytes = bytes;
    @memcpy(broken_bytes[header_size + record_size ..][0..record_size], record[0..]);
    try std.testing.expectError(error.BadChain, decode(broken_bytes[0..encoded.len]));

    var gap = log;
    gap.records[1].sequence = 3;
    encodeRecord(&gap.records[1], &record);
    var gap_bytes = bytes;
    @memcpy(gap_bytes[header_size + record_size ..][0..record_size], record[0..]);
    try std.testing.expectError(error.BadSequence, decode(gap_bytes[0..encoded.len]));
}

test "sale log enforces terminal sequence and bounded capacity" {
    var log = Log.init();
    const a = try testTxn(1001, 7, 1, "SKU1", 1, 100);
    _ = try log.insert(&a);
    const skip = try testTxn(1002, 7, 3, "SKU1", 1, 100);
    try std.testing.expectError(error.BadSequence, log.insert(&skip));
    const other = try testTxn(2001, 8, 1, "SKU1", 1, 100);
    _ = try log.insert(&other);
    try std.testing.expectEqual(@as(u32, 2), try log.nextTerminalSequence(7));

    var full = Log.init();
    var i: usize = 1;
    while (i <= max_records) : (i += 1) {
        const tx = try testTxn(i, 7, @intCast(i), "SKU1", 1, 100);
        _ = try full.insert(&tx);
    }
    const over = try testTxn(max_records + 1, 7, max_records + 1, "SKU1", 1, 100);
    try std.testing.expectError(error.Full, full.insert(&over));
}

test "sale log accepts non-zero tax and rejects malformed totals" {
    var taxed = try testTxn(3001, 7, 1, "SKU1", 1, 1000);
    taxed.lines[0].tax = 200;
    taxed.tax = 200;
    taxed.total = 1200;
    taxed.tender = 1200;
    var log = Log.init();
    _ = try log.insert(&taxed);
    try std.testing.expectEqual(@as(i64, 200), (try log.summarize()).tax);

    var bad_tax = try testTxn(3002, 7, 2, "SKU1", 1, 1000);
    bad_tax.lines[0].tax = 1001;
    bad_tax.tax = 1001;
    bad_tax.total = 2001;
    bad_tax.tender = 2001;
    try std.testing.expectError(error.BadTax, log.insert(&bad_tax));

    var bad_subtotal = try testTxn(3003, 7, 2, "SKU1", 2, 100);
    bad_subtotal.subtotal = 1;
    var bad_log = Log.init();
    try std.testing.expectError(error.BadTotals, bad_log.insert(&bad_subtotal));
    var empty = Txn{ .txn_id = 1, .terminal_id = 7, .terminal_seq = 1, .flags = 1 };
    var empty_log = Log.init();
    try std.testing.expectError(error.BadLine, empty_log.insert(&empty));
}
