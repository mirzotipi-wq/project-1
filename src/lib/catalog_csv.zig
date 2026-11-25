//! Bounded catalog CSV parser (phase 45).
//!
//! The FAT32 reader imports a product catalog from a vendor stick. A catalog is
//! larger than the kernel's old whole-file buffer, so this parser consumes it
//! in caller-sized chunks and never allocates. It validates the schema and
//! every row as it streams:
//!
//!     sku,name,price_cents
//!     100000,Item 00000,100
//!
//! The parser owns no file handle and knows nothing about FAT32. That keeps the
//! CSV contract host-testable while the VFS/FAT32 layers prove the bytes came
//! from the medium.

const std = @import("std");

pub const max_line = 255;

pub const Error = error{
    BadHeader,
    BadRow,
    LineTooLong,
    NoRows,
    AlreadyFinished,
};

pub const Result = struct {
    rows: u32 = 0,
    lines: u32 = 0,
    bytes: u64 = 0,
    max_line: u16 = 0,
    header_ok: bool = false,
};

pub const Parser = struct {
    line: [max_line]u8 = undefined,
    line_len: usize = 0,
    line_no: u32 = 0,
    rows: u32 = 0,
    bytes: u64 = 0,
    max_line_seen: u16 = 0,
    header_ok: bool = false,
    finished: bool = false,

    /// Consume the next chunk. A malformed header or row is refused at the
    /// first byte that proves it; the caller must not treat later chunks as a
    /// successful import.
    pub fn feed(self: *Parser, data: []const u8) Error!void {
        if (self.finished) return error.AlreadyFinished;
        for (data) |byte| {
            self.bytes += 1;
            if (byte == '\n') {
                try self.finishLine();
                continue;
            }
            if (self.line_len == self.line.len) return error.LineTooLong;
            self.line[self.line_len] = byte;
            self.line_len += 1;
            if (self.line_len > self.max_line_seen) self.max_line_seen = @intCast(self.line_len);
        }
    }

    /// Finish a file whose last line may not end in a newline. The result is
    /// only available after every chunk has been fed successfully.
    pub fn finish(self: *Parser) Error!Result {
        if (self.finished) return error.AlreadyFinished;
        if (self.line_len != 0) try self.finishLine();
        self.finished = true;
        if (!self.header_ok) return error.BadHeader;
        if (self.rows == 0) return error.NoRows;
        return .{
            .rows = self.rows,
            .lines = self.line_no,
            .bytes = self.bytes,
            .max_line = self.max_line_seen,
            .header_ok = self.header_ok,
        };
    }

    fn finishLine(self: *Parser) Error!void {
        var n = self.line_len;
        if (n != 0 and self.line[n - 1] == '\r') n -= 1;
        if (self.line_no == 0) {
            if (!std.mem.eql(u8, self.line[0..n], "sku,name,price_cents")) return error.BadHeader;
            self.header_ok = true;
        } else {
            if (n == 0) return error.BadRow;
            var fields: [3][]const u8 = undefined;
            var field_count: usize = 0;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                if (i == n or self.line[i] == ',') {
                    if (field_count >= fields.len) return error.BadRow;
                    fields[field_count] = self.line[start..i];
                    field_count += 1;
                    start = i + 1;
                }
            }
            if (field_count != 3) return error.BadRow;
            if (fields[0].len == 0 or fields[0].len > 12 or !digits(fields[0])) return error.BadRow;
            if (fields[1].len == 0 or !printable(fields[1])) return error.BadRow;
            if (fields[2].len == 0 or fields[2].len > 12 or !digits(fields[2])) return error.BadRow;
            self.rows += 1;
        }
        self.line_no += 1;
        self.line_len = 0;
    }
};

fn digits(text: []const u8) bool {
    for (text) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn printable(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Host tests: the exact 10k-row shape the FAT32 harness emits, fed in awkward
// chunk sizes so header and row boundaries are crossed, not conveniently
// aligned.
// ---------------------------------------------------------------------------

fn makeCatalog(buf: []u8) ![]const u8 {
    var n: usize = 0;
    const header = try std.fmt.bufPrint(buf[n..], "sku,name,price_cents\n", .{});
    n += header.len;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const line = try std.fmt.bufPrint(buf[n..], "{d:0>6},Item {d:0>5},100\n", .{ 100_000 + i, i });
        n += line.len;
    }
    return buf[0..n];
}

test "a 10k-row catalog parses across small chunk boundaries" {
    var content_buf: [256 * 1024]u8 = undefined;
    const content = try makeCatalog(&content_buf);
    try std.testing.expectEqual(@as(usize, 220_021), content.len);

    const chunk_sizes = [_]usize{ 7, 31, 4_093 };
    for (chunk_sizes) |chunk| {
        var parser = Parser{};
        var pos: usize = 0;
        while (pos < content.len) {
            const end = @min(pos + chunk, content.len);
            try parser.feed(content[pos..end]);
            pos = end;
        }
        const result = try parser.finish();
        try std.testing.expectEqual(@as(u32, 10_000), result.rows);
        try std.testing.expectEqual(@as(u32, 10_001), result.lines);
        try std.testing.expectEqual(@as(u64, content.len), result.bytes);
        try std.testing.expect(result.header_ok);
        try std.testing.expect(result.max_line <= 22);
    }
}

test "a final row without a newline is still parsed" {
    var parser = Parser{};
    try parser.feed("sku,name,price_cents\n1001,Coffee,250");
    const result = try parser.finish();
    try std.testing.expectEqual(@as(u32, 1), result.rows);
    try std.testing.expectEqual(@as(u32, 2), result.lines);
}

test "bad header, malformed row and oversized line are refused" {
    var parser = Parser{};
    try std.testing.expectError(error.BadHeader, parser.feed("sku,name\n"));

    var bad_row = Parser{};
    try std.testing.expectError(error.BadRow, bad_row.feed("sku,name,price_cents\n1001,Coffee\n"));

    var non_numeric = Parser{};
    try std.testing.expectError(error.BadRow, non_numeric.feed("sku,name,price_cents\nabc,Coffee,250\n"));

    var long = Parser{};
    const prefix = "sku,name,price_cents\n1001,";
    try long.feed(prefix);
    const filler = [_]u8{'x'} ** max_line;
    try std.testing.expectError(error.LineTooLong, long.feed(&filler));
}

test "an empty data section is refused" {
    var parser = Parser{};
    try parser.feed("sku,name,price_cents\n");
    try std.testing.expectError(error.NoRows, parser.finish());
}
