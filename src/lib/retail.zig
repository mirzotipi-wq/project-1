//! Retail data model for CassaOS.
//!
//! This is the durable schema a store needs for a trading day: catalog items,
//! variants, barcodes, tax classes, promotions, staff and roles, terminals,
//! shifts, cash drawers, suppliers, receipts and receipt lines.
//!
//! The model deliberately is one fixed-size, checksummed snapshot. Persisting it
//! is the VFS/CASSAFS layer's job (src/kernel/retail.zig); this file is pure Zig
//! logic with no allocator, no I/O and no clock. A record is 128 bytes and the
//! complete file is 61,480 bytes, below CASSAFS's 128 KiB file limit and small
//! enough to be committed in one bounded write.
//!
//! Cross-record references are checked by `validate`, including receipt totals
//! recomputed from their sale lines and tax recomputed from the product's tax
//! class. Bad data is refused rather than reported as a valid day.

const std = @import("std");
const cassafs = @import("cassafs.zig");

pub const format_version: u16 = 1;
pub const header_size: usize = 40;
pub const record_size: usize = 128;
pub const max_records: usize = 480;
pub const file_bytes: usize = header_size + max_records * record_size;
pub const max_code: usize = 16;
pub const max_name: usize = 32;
pub const magic: [8]u8 = .{ 'C', 'S', 'R', 'T', 'L', '1', 0, 0 };
pub const record_crc_offset: usize = 112;
pub const record_crc_bytes: usize = 112;
/// Money is bounded to one trillion cents and quantities to one million so
/// validation and report arithmetic cannot overflow i64. CSV prices are limited
/// to 12 digits, inside this bound.
pub const max_money: i64 = 1_000_000_000_000;
pub const max_qty: i32 = 1_000_000;

pub const Kind = enum(u8) {
    product,
    variant,
    barcode,
    tax_class,
    promotion,
    user,
    role,
    receipt,
    sale_line,
    shift,
    drawer,
    terminal,
    supplier,
};

pub const Error = error{
    InvalidMagic,
    InvalidVersion,
    Truncated,
    Corrupt,
    RecordCorrupt,
    BadKind,
    BadCode,
    BadName,
    BadAmount,
    BadReference,
    BadTotals,
    BadTax,
    DuplicateId,
    DuplicateCode,
    NoSpace,
    NoProducts,
    BufferTooSmall,
};

pub const Record = struct {
    kind: Kind = .product,
    flags: u8 = 0,
    id: u32 = 0,
    parent: u32 = 0,
    ref1: u32 = 0,
    ref2: u32 = 0,
    amount: i64 = 0,
    amount2: i64 = 0,
    amount3: i64 = 0,
    amount4: i64 = 0,
    qty: i32 = 0,
    time: u64 = 0,
    code: [max_code]u8 = [_]u8{0} ** max_code,
    name: [max_name]u8 = [_]u8{0} ** max_name,
    code_len: u8 = 0,
    name_len: u8 = 0,

    pub fn codeSlice(self: *const Record) []const u8 {
        return self.code[0..self.code_len];
    }

    pub fn nameSlice(self: *const Record) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setCode(self: *Record, text: []const u8) Error!void {
        if (text.len == 0 or text.len > max_code) return error.BadCode;
        @memset(self.code[0..], 0);
        @memcpy(self.code[0..text.len], text);
        self.code_len = @intCast(text.len);
    }

    pub fn setName(self: *Record, text: []const u8) Error!void {
        if (text.len == 0 or text.len > max_name) return error.BadName;
        @memset(self.name[0..], 0);
        @memcpy(self.name[0..text.len], text);
        self.name_len = @intCast(text.len);
    }
};

pub const Header = struct {
    count: u16 = 0,
    capacity: u16 = max_records,
    next_id: u32 = 1,
    generation: u32 = 0,
    updated: u64 = 0,
};

pub const Db = struct {
    header: Header = .{},
    records: [max_records]Record = [_]Record{.{}} ** max_records,

    pub fn init() Db {
        return .{ .header = .{} };
    }

    pub fn append(self: *Db, kind: Kind) Error!*Record {
        if (self.header.count >= max_records) return error.NoSpace;
        const index: usize = self.header.count;
        var rec = Record{};
        rec.kind = kind;
        rec.id = self.header.next_id;
        self.header.next_id +%= 1;
        if (self.header.next_id == 0) self.header.next_id = 1;
        self.header.count += 1;
        self.header.generation +%= 1;
        self.records[index] = rec;
        return &self.records[index];
    }

    pub fn find(self: *const Db, id: u32) ?*const Record {
        if (id == 0) return null;
        for (self.records[0..self.header.count]) |*rec| {
            if (rec.id == id) return rec;
        }
        return null;
    }

    pub fn findKind(self: *const Db, kind: Kind, id: u32) ?*const Record {
        if (id == 0) return null;
        for (self.records[0..self.header.count]) |*rec| {
            if (rec.kind == kind and rec.id == id) return rec;
        }
        return null;
    }

    pub fn findMut(self: *Db, id: u32) ?*Record {
        if (id == 0) return null;
        for (self.records[0..self.header.count]) |*rec| {
            if (rec.id == id) return rec;
        }
        return null;
    }

    pub fn findKindMut(self: *Db, kind: Kind, id: u32) ?*Record {
        if (id == 0) return null;
        for (self.records[0..self.header.count]) |*rec| {
            if (rec.kind == kind and rec.id == id) return rec;
        }
        return null;
    }

    pub fn findCode(self: *const Db, kind: Kind, code: []const u8) ?*const Record {
        if (code.len == 0) return null;
        for (self.records[0..self.header.count]) |*rec| {
            if (rec.kind == kind and std.mem.eql(u8, rec.codeSlice(), code)) return rec;
        }
        return null;
    }

    pub fn countKind(self: *const Db, kind: Kind) u32 {
        var count: u32 = 0;
        for (self.records[0..self.header.count]) |*rec| {
            if (rec.kind == kind) count += 1;
        }
        return count;
    }

    pub fn addProduct(self: *Db, code: []const u8, name: []const u8, price: i64) Error!*Record {
        if (price < 0) return error.BadAmount;
        if (self.findCode(.product, code) != null) return error.DuplicateCode;
        const rec = try self.append(.product);
        try rec.setCode(code);
        try rec.setName(name);
        rec.amount = price;
        return rec;
    }
};

pub fn taxFor(net_cents: i64, rate_bp: u16) i64 {
    if (net_cents <= 0 or rate_bp == 0) return 0;
    const wide = @as(i128, net_cents) * @as(i128, rate_bp);
    return @intCast(@divTrunc(wide, 10_000));
}

fn moneyOk(value: i64) bool {
    return value >= 0 and value <= max_money;
}

fn kindFromByte(value: u8) Error!Kind {
    return switch (value) {
        0 => .product,
        1 => .variant,
        2 => .barcode,
        3 => .tax_class,
        4 => .promotion,
        5 => .user,
        6 => .role,
        7 => .receipt,
        8 => .sale_line,
        9 => .shift,
        10 => .drawer,
        11 => .terminal,
        12 => .supplier,
        else => error.BadKind,
    };
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

fn checksum(bytes: []const u8) u32 {
    return ~cassafs.crc32cUpdate(0xffffffff, bytes);
}

fn encodeRecord(rec: *const Record, out: *[record_size]u8) void {
    @memset(out[0..], 0);
    out[0] = @intFromEnum(rec.kind);
    out[1] = rec.flags;
    out[2] = rec.code_len;
    out[3] = rec.name_len;
    put32(out[0..], 4, rec.id);
    put32(out[0..], 8, rec.parent);
    put32(out[0..], 12, rec.ref1);
    put32(out[0..], 16, rec.ref2);
    put64(out[0..], 20, @bitCast(rec.amount));
    put64(out[0..], 28, @bitCast(rec.amount2));
    put64(out[0..], 36, @bitCast(rec.amount3));
    put64(out[0..], 44, @bitCast(rec.amount4));
    put32(out[0..], 52, @bitCast(rec.qty));
    put64(out[0..], 56, rec.time);
    @memcpy(out[64..80], rec.code[0..]);
    @memcpy(out[80..112], rec.name[0..]);
    put32(out[0..], record_crc_offset, checksum(out[0..record_crc_bytes]));
}

fn decodeRecord(bytes: *const [record_size]u8) Error!Record {
    if (get32(bytes, record_crc_offset) != checksum(bytes[0..record_crc_bytes])) return error.RecordCorrupt;
    var rec = Record{};
    rec.kind = try kindFromByte(bytes[0]);
    rec.flags = bytes[1];
    rec.code_len = bytes[2];
    rec.name_len = bytes[3];
    if (rec.code_len > max_code or rec.name_len > max_name) return error.BadCode;
    rec.id = get32(bytes, 4);
    rec.parent = get32(bytes, 8);
    rec.ref1 = get32(bytes, 12);
    rec.ref2 = get32(bytes, 16);
    rec.amount = @bitCast(get64(bytes, 20));
    rec.amount2 = @bitCast(get64(bytes, 28));
    rec.amount3 = @bitCast(get64(bytes, 36));
    rec.amount4 = @bitCast(get64(bytes, 44));
    rec.qty = @bitCast(get32(bytes, 52));
    rec.time = get64(bytes, 56);
    @memcpy(rec.code[0..], bytes[64..80]);
    @memcpy(rec.name[0..], bytes[80..112]);
    return rec;
}

pub fn encode(db: *const Db, out: *[file_bytes]u8) Error!void {
    if (db.header.count > max_records) return error.NoSpace;
    @memset(out[0..], 0);
    var header = [_]u8{0} ** header_size;
    @memcpy(header[0..8], magic[0..]);
    put16(header[0..], 8, format_version);
    put16(header[0..], 10, record_size);
    put16(header[0..], 12, db.header.count);
    put16(header[0..], 14, max_records);
    put32(header[0..], 16, db.header.next_id);
    put32(header[0..], 20, db.header.generation);
    put64(header[0..], 24, db.header.updated);
    put32(header[0..], 32, checksum(header[0..32]));
    @memcpy(out[0..header_size], header[0..]);

    var i: usize = 0;
    while (i < db.header.count) : (i += 1) {
        const offset = header_size + i * record_size;
        var bytes: [record_size]u8 = undefined;
        encodeRecord(&db.records[i], &bytes);
        @memcpy(out[offset .. offset + record_size], bytes[0..]);
    }
}

pub fn decodeInto(out: *Db, data: []const u8) Error!void {
    if (data.len != file_bytes) return error.Truncated;
    if (!std.mem.eql(u8, data[0..8], magic[0..])) return error.InvalidMagic;
    if (get16(data, 8) != format_version) return error.InvalidVersion;
    if (get16(data, 10) != record_size) return error.InvalidVersion;
    const count = get16(data, 12);
    const capacity = get16(data, 14);
    if (capacity != max_records or count > capacity) return error.Corrupt;
    if (get32(data, 32) != checksum(data[0..32])) return error.Corrupt;

    out.* = Db.init();
    out.header.count = count;
    out.header.next_id = get32(data, 16);
    out.header.generation = get32(data, 20);
    out.header.updated = get64(data, 24);
    if (out.header.next_id == 0) return error.Corrupt;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const offset = header_size + i * record_size;
        const bytes: *const [record_size]u8 = data[offset..][0..record_size];
        out.records[i] = try decodeRecord(bytes);
    }
}

pub fn decode(data: []const u8) Error!Db {
    var db = Db.init();
    try decodeInto(&db, data);
    return db;
}

fn hasKind(db: *const Db, id: u32, kind: Kind) bool {
    return db.findKind(kind, id) != null;
}

fn existsAny(db: *const Db, id: u32) bool {
    return db.find(id) != null;
}

pub fn validate(db: *const Db) Error!void {
    if (db.header.count > max_records or db.header.next_id == 0) return error.Corrupt;

    var i: usize = 0;
    while (i < db.header.count) : (i += 1) {
        const rec = &db.records[i];
        if (rec.id == 0) return error.DuplicateId;
        if (rec.code_len > max_code or rec.name_len > max_name) return error.BadCode;

        var j = i + 1;
        while (j < db.header.count) : (j += 1) {
            const other = &db.records[j];
            if (other.id == rec.id) return error.DuplicateId;
            if (rec.code_len != 0 and other.code_len != 0 and rec.kind == other.kind and
                std.mem.eql(u8, rec.codeSlice(), other.codeSlice()))
            {
                return error.DuplicateCode;
            }
        }

        switch (rec.kind) {
            .product => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (!moneyOk(rec.amount) or rec.qty < 0 or rec.qty > max_qty) return error.BadAmount;
                if (rec.ref1 != 0 and !hasKind(db, rec.ref1, .tax_class)) return error.BadReference;
                if (rec.ref2 != 0 and !hasKind(db, rec.ref2, .supplier)) return error.BadReference;
            },
            .variant => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (!hasKind(db, rec.parent, .product)) return error.BadReference;
                if (!moneyOk(rec.amount)) return error.BadAmount;
            },
            .barcode => {
                if (rec.code_len == 0) return error.BadCode;
                if (!hasKind(db, rec.parent, .product) and !hasKind(db, rec.parent, .variant)) {
                    return error.BadReference;
                }
            },
            .tax_class => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (rec.amount < 0 or rec.amount > 10_000) return error.BadAmount;
            },
            .promotion => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (rec.flags != 1 and rec.flags != 2) return error.BadReference;
                if (!moneyOk(rec.amount) or (rec.flags == 1 and rec.amount > 10_000)) return error.BadAmount;
                if (rec.ref1 != 0 and !hasKind(db, rec.ref1, .product)) return error.BadReference;
            },
            .user => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (!hasKind(db, rec.ref1, .role)) return error.BadReference;
                if (rec.ref2 != 0 and !hasKind(db, rec.ref2, .terminal)) return error.BadReference;
            },
            .role => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (rec.qty < 0 or rec.qty > max_qty) return error.BadAmount;
            },
            .receipt => {
                if (rec.code_len == 0) return error.BadCode;
                if (!hasKind(db, rec.parent, .shift)) return error.BadReference;
                if (!hasKind(db, rec.ref1, .terminal)) return error.BadReference;
                if (!hasKind(db, rec.ref2, .user)) return error.BadReference;
                if ((rec.flags & 0xfc) != 0 or (rec.flags & 1) == 0) return error.BadReference;
                if (rec.qty <= 0 or rec.qty > max_qty or !moneyOk(rec.amount) or
                    !moneyOk(rec.amount2) or !moneyOk(rec.amount3) or !moneyOk(rec.amount4))
                {
                    return error.BadAmount;
                }
                if (rec.amount3 != rec.amount + rec.amount2) return error.BadTotals;
                if (rec.amount4 < rec.amount3) return error.BadTotals;
            },
            .sale_line => {
                if (!hasKind(db, rec.parent, .receipt)) return error.BadReference;
                if (!hasKind(db, rec.ref1, .product) and !hasKind(db, rec.ref1, .variant)) {
                    return error.BadReference;
                }
                if (rec.qty <= 0 or rec.qty > max_qty or !moneyOk(rec.amount) or
                    !moneyOk(rec.amount2) or !moneyOk(rec.amount3) or !moneyOk(rec.amount4))
                {
                    return error.BadAmount;
                }
                const base = std.math.mul(i64, rec.amount, @as(i64, rec.qty)) catch return error.BadAmount;
                if (rec.amount2 > base) return error.BadAmount;
                if (rec.amount4 != base - rec.amount2) return error.BadTotals;
                if (rec.ref2 != 0) {
                    const promo = db.findKind(.promotion, rec.ref2) orelse return error.BadReference;
                    const expected_discount: i64 = if (promo.flags == 1)
                        @intCast(@divTrunc(@as(i128, base) * @as(i128, promo.amount), 10_000))
                    else
                        @min(promo.amount, base);
                    if (rec.amount2 != expected_discount) return error.BadTotals;
                }
                const rate = try taxRateForItem(db, rec.ref1);
                if (rec.amount3 != taxFor(rec.amount4, rate)) return error.BadTax;
            },
            .shift => {
                if (rec.code_len == 0) return error.BadCode;
                if (!hasKind(db, rec.ref1, .terminal)) return error.BadReference;
                if (!hasKind(db, rec.ref2, .user)) return error.BadReference;
                if (!moneyOk(rec.amount) or !moneyOk(rec.amount2) or !moneyOk(rec.amount3)) return error.BadAmount;
                if (rec.amount4 != rec.amount3 - rec.amount2) return error.BadTotals;
            },
            .drawer => {
                if (rec.code_len == 0) return error.BadCode;
                if (!hasKind(db, rec.ref1, .shift)) return error.BadReference;
                if (!hasKind(db, rec.ref2, .terminal)) return error.BadReference;
                if (!moneyOk(rec.amount) or !moneyOk(rec.amount2) or !moneyOk(rec.amount3)) return error.BadAmount;
                if (rec.amount4 != rec.amount3 - rec.amount2) return error.BadTotals;
            },
            .terminal => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
                if (rec.qty < 0 or rec.qty > max_qty) return error.BadAmount;
            },
            .supplier => {
                if (rec.code_len == 0 or rec.name_len == 0) return error.BadCode;
            },
        }
    }

    // Receipts are checked against their lines after every record exists.
    i = 0;
    while (i < db.header.count) : (i += 1) {
        const rec = &db.records[i];
        if (rec.kind != .receipt) continue;
        var lines: i32 = 0;
        var subtotal: i64 = 0;
        var tax: i64 = 0;
        var j: usize = 0;
        while (j < db.header.count) : (j += 1) {
            const line = &db.records[j];
            if (line.kind != .sale_line or line.parent != rec.id) continue;
            lines += 1;
            subtotal += line.amount4;
            tax += line.amount3;
        }
        if (lines != rec.qty) return error.BadTotals;
        if (subtotal != rec.amount or tax != rec.amount2) return error.BadTotals;
    }
}

fn parentProductId(db: *const Db, item_id: u32) Error!u32 {
    if (db.findKind(.product, item_id)) |product| return product.id;
    if (db.findKind(.variant, item_id)) |variant| return variant.parent;
    return error.BadReference;
}

fn taxRateForItem(db: *const Db, item_id: u32) Error!u16 {
    const product_id = try parentProductId(db, item_id);
    const product = db.findKind(.product, product_id) orelse return error.BadReference;
    if (product.ref1 == 0) return 0;
    const tax = db.findKind(.tax_class, product.ref1) orelse return error.BadReference;
    if (tax.amount < 0 or tax.amount > 10_000) return error.BadTax;
    return @intCast(tax.amount);
}

pub const Summary = struct {
    records: u32 = 0,
    receipts: u32 = 0,
    lines: u32 = 0,
    units: i64 = 0,
    subtotal: i64 = 0,
    tax: i64 = 0,
    total: i64 = 0,
    tender: i64 = 0,
    change: i64 = 0,
    cash: i64 = 0,
    top_product: u32 = 0,
    top_units: i64 = 0,
    top_revenue: i64 = 0,
    open_shifts: u32 = 0,
    closed_shifts: u32 = 0,
    variance: i64 = 0,
};

pub fn summarize(db: *const Db) Error!Summary {
    try validate(db);
    var summary = Summary{};
    summary.records = db.header.count;
    var i: usize = 0;
    while (i < db.header.count) : (i += 1) {
        const rec = &db.records[i];
        switch (rec.kind) {
            .receipt => {
                summary.receipts += 1;
                summary.subtotal += rec.amount;
                summary.tax += rec.amount2;
                summary.total += rec.amount3;
                summary.tender += rec.amount4;
                if ((rec.flags & 2) != 0) summary.cash += rec.amount4;
            },
            .sale_line => {
                summary.lines += 1;
                summary.units += rec.qty;
            },
            .shift => {
                if ((rec.flags & 1) != 0) summary.closed_shifts += 1 else summary.open_shifts += 1;
            },
            .drawer => summary.variance += rec.amount4,
            else => {},
        }
    }
    summary.change = summary.tender - summary.total;

    var best_id: u32 = 0;
    var best_units: i64 = 0;
    var best_revenue: i64 = 0;
    i = 0;
    while (i < db.header.count) : (i += 1) {
        const rec = &db.records[i];
        if (rec.kind != .sale_line) continue;
        const product_id = try parentProductId(db, rec.ref1);
        var units: i64 = 0;
        var revenue: i64 = 0;
        var j: usize = 0;
        while (j < db.header.count) : (j += 1) {
            const line = &db.records[j];
            if (line.kind != .sale_line) continue;
            const line_product = try parentProductId(db, line.ref1);
            if (line_product != product_id) continue;
            units += line.qty;
            revenue += line.amount4;
        }
        if (units > best_units or (units == best_units and product_id < best_id)) {
            best_id = product_id;
            best_units = units;
            best_revenue = revenue;
        }
    }
    summary.top_product = best_id;
    summary.top_units = best_units;
    summary.top_revenue = best_revenue;
    return summary;
}

fn addTaxClass(db: *Db, code: []const u8, name: []const u8, basis_points: i64) Error!*Record {
    const rec = try db.append(.tax_class);
    try rec.setCode(code);
    try rec.setName(name);
    rec.amount = basis_points;
    return rec;
}

fn addSupplier(db: *Db, code: []const u8, name: []const u8) Error!*Record {
    const rec = try db.append(.supplier);
    try rec.setCode(code);
    try rec.setName(name);
    return rec;
}

fn addTerminal(db: *Db, code: []const u8, name: []const u8) Error!*Record {
    const rec = try db.append(.terminal);
    try rec.setCode(code);
    try rec.setName(name);
    return rec;
}

fn addRole(db: *Db, code: []const u8, name: []const u8, permissions: i32) Error!*Record {
    const rec = try db.append(.role);
    try rec.setCode(code);
    try rec.setName(name);
    rec.qty = permissions;
    return rec;
}

fn addUser(db: *Db, code: []const u8, name: []const u8, role_id: u32, terminal_id: u32) Error!*Record {
    const rec = try db.append(.user);
    try rec.setCode(code);
    try rec.setName(name);
    rec.ref1 = role_id;
    rec.ref2 = terminal_id;
    return rec;
}

fn addShift(db: *Db, code: []const u8, terminal_id: u32, user_id: u32, opening: i64, time: u64) Error!*Record {
    const rec = try db.append(.shift);
    try rec.setCode(code);
    rec.ref1 = terminal_id;
    rec.ref2 = user_id;
    rec.amount = opening;
    rec.time = time;
    return rec;
}

fn addDrawer(db: *Db, code: []const u8, shift_id: u32, terminal_id: u32, opening: i64, expected: i64, counted: i64) Error!*Record {
    const rec = try db.append(.drawer);
    try rec.setCode(code);
    rec.ref1 = shift_id;
    rec.ref2 = terminal_id;
    rec.amount = opening;
    rec.amount2 = expected;
    rec.amount3 = counted;
    rec.amount4 = counted - expected;
    return rec;
}

fn addPromotion(db: *Db, code: []const u8, name: []const u8, flags: u8, value: i64, product_id: u32) Error!*Record {
    const rec = try db.append(.promotion);
    try rec.setCode(code);
    try rec.setName(name);
    rec.flags = flags;
    rec.amount = value;
    rec.ref1 = product_id;
    return rec;
}

/// Populate a deterministic trading day on top of the imported products.
/// Prices are treated as tax-exclusive net amounts. The demo products use the
/// zero-rate tax class, so the day's tax is zero while the schema still carries
/// 20% and 5% classes for products that need them.
pub fn seedDay(db: *Db) Error!void {
    var product_ids: [16]u32 = [_]u32{0} ** 16;
    var product_prices: [16]i64 = [_]i64{0} ** 16;
    var product_count: usize = 0;
    for (db.records[0..db.header.count]) |*rec| {
        if (rec.kind != .product) continue;
        if (product_count == product_ids.len) break;
        product_ids[product_count] = rec.id;
        product_prices[product_count] = rec.amount;
        product_count += 1;
    }
    if (product_count == 0) return error.NoProducts;

    const tax_zero = try addTaxClass(db, "ZERO", "Tax free", 0);
    const tax_20 = try addTaxClass(db, "VAT20", "Standard VAT", 2000);
    _ = tax_20;
    const tax_5 = try addTaxClass(db, "VAT5", "Reduced VAT", 500);
    _ = tax_5;
    const supplier_a = try addSupplier(db, "SUP-A", "North Roastery");
    const supplier_b = try addSupplier(db, "SUP-B", "City Bakery");

    var p: usize = 0;
    while (p < product_count) : (p += 1) {
        const product = db.findKindMut(.product, product_ids[p]) orelse return error.BadReference;
        product.ref1 = tax_zero.id;
        product.ref2 = if ((p & 1) == 0) supplier_a.id else supplier_b.id;
    }

    var variant_ids: [16]u32 = [_]u32{0} ** 16;
    var v: usize = 0;
    while (v < product_count and v < 4) : (v += 1) {
        const product = db.findKind(.product, product_ids[v]) orelse return error.BadReference;
        var code_buf: [max_code]u8 = undefined;
        var name_buf: [max_name]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buf, "V{d}", .{product.id}) catch return error.BadCode;
        const name = std.fmt.bufPrint(&name_buf, "Variant {d}", .{product.id}) catch return error.BadCode;
        const variant = try db.append(.variant);
        try variant.setCode(code);
        try variant.setName(name);
        variant.parent = product.id;
        variant.amount = product.amount + 50;
        variant_ids[v] = variant.id;
    }

    p = 0;
    while (p < product_count) : (p += 1) {
        const product = db.findKind(.product, product_ids[p]) orelse return error.BadReference;
        var code_buf: [max_code]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buf, "B{d}", .{product.id}) catch return error.BadCode;
        const barcode = try db.append(.barcode);
        try barcode.setCode(code);
        barcode.parent = product.id;
        if (variant_ids[p] != 0) {
            const variant = db.findKind(.variant, variant_ids[p]) orelse return error.BadReference;
            const vcode = std.fmt.bufPrint(&code_buf, "VB{d}", .{variant.id}) catch return error.BadCode;
            const vb = try db.append(.barcode);
            try vb.setCode(vcode);
            vb.parent = variant.id;
        }
    }

    const role_cashier = try addRole(db, "CASHIER", "Cashier", 0x0001);
    const role_supervisor = try addRole(db, "SUPER", "Supervisor", 0x0003);
    const role_manager = try addRole(db, "MANAGER", "Manager", 0x0007);

    const term1 = try addTerminal(db, "T1", "Front till 1");
    const term2 = try addTerminal(db, "T2", "Front till 2");
    const term3 = try addTerminal(db, "T3", "Service desk");

    const cash1 = try addUser(db, "cash1", "Ari Cash", role_cashier.id, term1.id);
    const cash2 = try addUser(db, "cash2", "Bea Till", role_cashier.id, term2.id);
    const sup1 = try addUser(db, "sup1", "Cy Super", role_supervisor.id, term3.id);
    const mgr1 = try addUser(db, "mgr1", "Dee Manager", role_manager.id, term1.id);
    _ = mgr1;

    const promo_percent = try addPromotion(db, "PROMO10", "Ten percent", 1, 1000, product_ids[0]);
    const promo_fixed = try addPromotion(db, "SAVE50", "Fifty off", 2, 50, product_ids[1]);

    const time_base: u64 = 1_767_225_600; // 2026-01-01T00:00:00Z, fixed for reproducibility
    const shift1 = try addShift(db, "S1", term1.id, cash1.id, 10_000, time_base);
    const shift2 = try addShift(db, "S2", term2.id, cash2.id, 10_000, time_base);
    const shift3 = try addShift(db, "S3", term3.id, sup1.id, 10_000, time_base);

    var cash_totals = [_]i64{0} ** 3;
    var i: usize = 0;
    const receipt_count: usize = 64;
    while (i < receipt_count) : (i += 1) {
        const p1_index = i % product_count;
        const p2_index = (i * 3 + 1) % product_count;
        const p1 = db.findKind(.product, product_ids[p1_index]) orelse return error.BadReference;
        const p2 = db.findKind(.product, product_ids[p2_index]) orelse return error.BadReference;
        const q1: i32 = 1 + @as(i32, @intCast(i & 1));
        const q2: i32 = 1;
        const unit1 = product_prices[p1_index];
        const unit2 = product_prices[p2_index];
        var discount: i64 = 0;
        var promo_id: u32 = 0;
        if ((i % 8) == 0) {
            if ((i % 16) == 0) {
                discount = @divTrunc(unit1 * q1 * promo_percent.amount, 10_000);
                promo_id = promo_percent.id;
            } else {
                discount = promo_fixed.amount;
                promo_id = promo_fixed.id;
            }
            if (discount > unit1 * q1) discount = unit1 * q1;
        }
        const line1_total = unit1 * q1 - discount;
        const line2_total = unit2 * q2;
        const subtotal = line1_total + line2_total;
        const tax: i64 = 0;
        const total = subtotal + tax;
        const tender = total;
        const shift_index = i % 3;
        const shift_id = switch (shift_index) {
            0 => shift1.id,
            1 => shift2.id,
            else => shift3.id,
        };
        const terminal_id = switch (shift_index) {
            0 => term1.id,
            1 => term2.id,
            else => term3.id,
        };
        const user_id = switch (shift_index) {
            0 => cash1.id,
            1 => cash2.id,
            else => sup1.id,
        };

        var rcode_buf: [max_code]u8 = undefined;
        const rcode = std.fmt.bufPrint(&rcode_buf, "R{d:0>4}", .{i + 1}) catch return error.BadCode;
        const receipt = try db.append(.receipt);
        try receipt.setCode(rcode);
        receipt.parent = shift_id;
        receipt.ref1 = terminal_id;
        receipt.ref2 = user_id;
        receipt.amount = subtotal;
        receipt.amount2 = tax;
        receipt.amount3 = total;
        receipt.amount4 = tender;
        receipt.qty = 2;
        receipt.flags = 1 | (if ((i & 1) == 0) @as(u8, 2) else 0);
        receipt.time = time_base + @as(u64, @intCast(i)) * 60_000;

        var lcode_buf: [max_code]u8 = undefined;
        const lcode = std.fmt.bufPrint(&lcode_buf, "L{d:0>4}A", .{i + 1}) catch return error.BadCode;
        const line1 = try db.append(.sale_line);
        try line1.setCode(lcode);
        line1.parent = receipt.id;
        line1.ref1 = if (variant_ids[p1_index] != 0) variant_ids[p1_index] else p1.id;
        line1.ref2 = promo_id;
        line1.amount = unit1;
        line1.amount2 = discount;
        line1.amount3 = 0;
        line1.amount4 = line1_total;
        line1.qty = q1;
        line1.time = receipt.time;

        const lcode2 = std.fmt.bufPrint(&lcode_buf, "L{d:0>4}B", .{i + 1}) catch return error.BadCode;
        const line2 = try db.append(.sale_line);
        try line2.setCode(lcode2);
        line2.parent = receipt.id;
        line2.ref1 = p2.id;
        line2.amount = unit2;
        line2.amount3 = 0;
        line2.amount4 = line2_total;
        line2.qty = q2;
        line2.time = receipt.time;

        if ((receipt.flags & 2) != 0) {
            cash_totals[shift_index] += total;
        }
    }

    const shift_ids = [_]u32{ shift1.id, shift2.id, shift3.id };
    const terminal_ids = [_]u32{ term1.id, term2.id, term3.id };
    const variances = [_]i64{ 0, 100, -50 };
    var s: usize = 0;
    while (s < 3) : (s += 1) {
        const expected = 10_000 + cash_totals[s];
        const counted = expected + variances[s];
        var dcode_buf: [max_code]u8 = undefined;
        const dcode = std.fmt.bufPrint(&dcode_buf, "D{d}", .{s + 1}) catch return error.BadCode;
        _ = try addDrawer(db, dcode, shift_ids[s], terminal_ids[s], 10_000, expected, counted);
        const shift = db.findKindMut(.shift, shift_ids[s]) orelse return error.BadReference;
        shift.amount2 = expected;
        shift.amount3 = counted;
        shift.amount4 = counted - expected;
        shift.flags = 1;
    }
    try validate(db);
}

fn seedEightProducts(db: *Db) !void {
    const names = [_][]const u8{
        "Espresso", "Croissant", "Water", "Orange Juice",
        "Sandwich", "Cookie",    "Tea",   "Salad",
    };
    const prices = [_]i64{ 250, 180, 150, 300, 425, 125, 200, 475 };
    for (names, prices, 0..) |name, price, i| {
        var code_buf: [max_code]u8 = undefined;
        const code = try std.fmt.bufPrint(&code_buf, "10000{d}", .{i});
        _ = try db.addProduct(code, name, price);
    }
}

test "retail tax calculation is integer and bounded" {
    try std.testing.expectEqual(@as(i64, 0), taxFor(0, 2000));
    try std.testing.expectEqual(@as(i64, 200), taxFor(1000, 2000));
    try std.testing.expectEqual(@as(i64, 50), taxFor(1000, 500));
    try std.testing.expectEqual(@as(i64, 0), taxFor(-1000, 2000));
}

test "retail day snapshot round-trips with exact counts" {
    var db = Db.init();
    try seedEightProducts(&db);
    try seedDay(&db);
    try std.testing.expectEqual(@as(u16, 239), db.header.count);
    try std.testing.expectEqual(@as(u32, 64), db.countKind(.receipt));
    try std.testing.expectEqual(@as(u32, 128), db.countKind(.sale_line));
    try validate(&db);

    const summary = try summarize(&db);
    try std.testing.expectEqual(@as(u32, 64), summary.receipts);
    try std.testing.expectEqual(@as(u32, 128), summary.lines);
    try std.testing.expectEqual(@as(i64, 160), summary.units);
    try std.testing.expectEqual(@as(i64, 0), summary.tax);
    try std.testing.expectEqual(@as(i64, 0), summary.change);
    try std.testing.expect(summary.top_product != 0);

    var bytes: [file_bytes]u8 = undefined;
    try encode(&db, &bytes);
    var decoded = Db.init();
    try decodeInto(&decoded, bytes[0..]);
    try std.testing.expectEqual(db.header.count, decoded.header.count);
    try std.testing.expectEqual(db.header.next_id, decoded.header.next_id);
    try validate(&decoded);
}

test "retail refuses duplicate product codes" {
    var db = Db.init();
    _ = try db.addProduct("DUP", "First", 100);
    try std.testing.expectError(error.DuplicateCode, db.addProduct("DUP", "Second", 200));
}

test "retail refuses a corrupted record" {
    var db = Db.init();
    try seedEightProducts(&db);
    try seedDay(&db);
    var bytes: [file_bytes]u8 = undefined;
    try encode(&db, &bytes);
    bytes[header_size + 65] ^= 0x80;
    var decoded = Db.init();
    try std.testing.expectError(error.RecordCorrupt, decodeInto(&decoded, bytes[0..]));
}

test "retail refuses tax that does not match the product class" {
    var db = Db.init();
    try seedEightProducts(&db);
    try seedDay(&db);
    const tax20 = db.findCode(.tax_class, "VAT20") orelse return error.BadReference;
    const product = db.findCode(.product, "100000") orelse return error.BadReference;
    const mutable = db.findKindMut(.product, product.id) orelse return error.BadReference;
    mutable.ref1 = tax20.id;
    try std.testing.expectError(error.BadTax, validate(&db));
}

test "retail can represent a taxed receipt line exactly" {
    var db = Db.init();
    const tax = try addTaxClass(&db, "VAT20", "Standard VAT", 2000);
    const product = try db.addProduct("TAXED", "Taxed item", 1000);
    product.ref1 = tax.id;
    const role = try addRole(&db, "CASHIER", "Cashier", 1);
    const terminal = try addTerminal(&db, "T1", "Till 1");
    const user = try addUser(&db, "cash1", "Cashier One", role.id, terminal.id);
    const shift = try addShift(&db, "S1", terminal.id, user.id, 0, 1);
    const receipt = try db.append(.receipt);
    try receipt.setCode("R0001");
    receipt.parent = shift.id;
    receipt.ref1 = terminal.id;
    receipt.ref2 = user.id;
    receipt.amount = 1000;
    receipt.amount2 = 200;
    receipt.amount3 = 1200;
    receipt.amount4 = 2000;
    receipt.qty = 1;
    receipt.flags = 1;
    const line = try db.append(.sale_line);
    try line.setCode("L0001");
    line.parent = receipt.id;
    line.ref1 = product.id;
    line.amount = 1000;
    line.amount3 = 200;
    line.amount4 = 1000;
    line.qty = 1;
    try validate(&db);
    const summary = try summarize(&db);
    try std.testing.expectEqual(@as(i64, 1200), summary.total);
    try std.testing.expectEqual(@as(i64, 200), summary.tax);
    try std.testing.expectEqual(@as(i64, 800), summary.change);
}

test "retail capacity and names are bounded, never truncated" {
    var db = Db.init();
    var i: usize = 0;
    while (i < max_records) : (i += 1) {
        var code_buf: [max_code]u8 = undefined;
        var name_buf: [max_name]u8 = undefined;
        const code = try std.fmt.bufPrint(&code_buf, "P{d}", .{i});
        const name = try std.fmt.bufPrint(&name_buf, "Item {d}", .{i});
        _ = try db.addProduct(code, name, 1);
    }
    try std.testing.expectError(error.NoSpace, db.addProduct("OVER", "Overflow", 1));

    var long_db = Db.init();
    const long_name = [_]u8{'x'} ** (max_name + 1);
    try std.testing.expectError(error.BadName, long_db.addProduct("LONG", long_name[0..], 1));
}

test "retail bounds arithmetic and refuses overflowing sale lines" {
    try std.testing.expectEqual(max_money, taxFor(max_money, 10_000));
    var db = Db.init();
    try seedEightProducts(&db);
    try seedDay(&db);
    var found = false;
    var i: usize = 0;
    while (i < db.header.count) : (i += 1) {
        if (db.records[i].kind != .sale_line) continue;
        db.records[i].amount = std.math.maxInt(i64);
        db.records[i].qty = 2;
        try std.testing.expectError(error.BadAmount, validate(&db));
        found = true;
        break;
    }
    try std.testing.expect(found);
}
