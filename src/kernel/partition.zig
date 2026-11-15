//! Partition tables (phase 35).
//!
//! The block layer (phase 34) gives us sectors; this module answers the next
//! question: which sectors belong to a partition, and who wrote the table.
//!
//! Three layouts, one interface:
//!
//!   * **GPT** — the header at LBA 1 and a backup at the last LBA, both with a
//!     CRC32 over the header (its own CRC field zeroed) and a CRC32 over the
//!     partition entry array. The primary is authoritative; if it is damaged the
//!     backup is read and reported as `backup_used`, never silently mixed with
//!     the primary. A disk whose backup is damaged but whose primary is sound is
//!     still readable, and says so (`backup_ok == false`).
//!   * **MBR** — the four 16-byte entries at offset 446, plus the extended
//!     partition's EBR chain for logical partitions. The chain is bounded and
//!     loop-checked: a corrupt table cannot spin the kernel.
//!   * **Protective MBR** — the single 0xEE entry every GPT disk carries so old
//!     tools see the disk as busy. It is recognised and handed to the GPT
//!     parser; a protective MBR with no valid GPT is reported as such instead of
//!     being enumerated as a partition.
//!
//! Every comparison here is an explicit byte loop. Phase 34 found that
//! `std.mem.eql` in this build returns false for byte-identical buffers whose
//! first slice starts 8 mod 16 (reproduced in-kernel on 44 size/alignment
//! combinations), and a table parser that lies about a GUID match would be
//! worse than no parser at all. `crc32` is the standard reflected 802.3 CRC
//! GPT requires.

const std = @import("std");
const block = @import("block.zig");

pub const sector_size = block.sector_size;
pub const max_partitions = 16;
pub const max_entries = 128;
/// A GPT entry array larger than this is refused rather than truncated. Real
/// tables are 128 entries of 128 bytes (16 KiB); the buffer is static so a
/// parser call cannot press on the shell's stack.
const max_entry_bytes = max_entries * 128;
const max_ebr = 32;

pub const Scheme = enum { none, mbr, gpt };
pub const Kind = enum { primary, logical };

pub const Entry = struct {
    scheme: Scheme = .mbr,
    index: u8 = 0,
    kind: Kind = .primary,
    bootable: bool = false,
    /// MBR type byte (0 when the table is GPT).
    type_mbr: u8 = 0,
    /// GPT type GUID, in on-disk byte order.
    type_guid: [16]u8 = [_]u8{0} ** 16,
    part_guid: [16]u8 = [_]u8{0} ** 16,
    first_lba: u64 = 0,
    /// Inclusive, as the on-disk formats store it.
    last_lba: u64 = 0,
    attributes: u64 = 0,
    name: [36]u8 = [_]u8{0} ** 36,
    name_len: u8 = 0,

    pub fn sectors(self: *const Entry) u64 {
        if (self.last_lba < self.first_lba) return 0;
        return self.last_lba - self.first_lba + 1;
    }

    pub fn nameText(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Table = struct {
    scheme: Scheme = .none,
    base_lba: u64 = 0,
    disk_sectors: u64 = 0,
    entries: [max_partitions]Entry = undefined,
    count: u8 = 0,
    /// Entries the table held but this parser did not return (bad bounds, or
    /// more than `max_partitions`).
    skipped: u16 = 0,

    // GPT facts, all verified before they are set.
    protective_mbr: bool = false,
    primary_ok: bool = false,
    backup_ok: bool = false,
    backup_used: bool = false,
    revision: u32 = 0,
    header_size: u32 = 0,
    header_crc: u32 = 0,
    entries_crc: u32 = 0,
    entry_array_lba: u64 = 0,
    entry_capacity: u32 = 0,
    entry_size: u32 = 0,
    alternate_lba: u64 = 0,
    disk_guid: [16]u8 = [_]u8{0} ** 16,

    // MBR facts.
    extended_containers: u8 = 0,
    ebr_scanned: u8 = 0,
};

pub const Error = error{
    NoDevice,
    Io,
    NoTable,
    ProtectiveOnly,
    BadSignature,
    BadRevision,
    BadHeaderSize,
    BadHeaderCrc,
    BadEntryArray,
    BadEntryCrc,
    TooManyEntries,
    Loop,
    NoSpace,
};

pub const Options = struct {
    base_lba: u64 = 0,
    /// 0 means "whatever the backend reports", minus `base_lba`.
    disk_sectors: u64 = 0,
};

// ---------------------------------------------------------------------------
// Constants: type GUIDs in on-disk byte order, and their human names.
// ---------------------------------------------------------------------------

/// Parse a canonical GUID string at comptime and emit GPT's mixed-endian bytes:
/// the first three fields are little-endian on disk, the last eight bytes are
/// big-endian as written.
fn guid(comptime text: []const u8) [16]u8 {
    var digits: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        digits[n] = c;
        n += 1;
    }
    if (n != 32) @compileError("a GUID needs 32 hex digits");
    var raw: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        raw[i] = (@as(u8, hexDigit(digits[i * 2])) << 4) | @as(u8, hexDigit(digits[i * 2 + 1]));
    }
    var out: [16]u8 = undefined;
    out[0] = raw[3];
    out[1] = raw[2];
    out[2] = raw[1];
    out[3] = raw[0];
    out[4] = raw[5];
    out[5] = raw[4];
    out[6] = raw[7];
    out[7] = raw[6];
    var k: usize = 8;
    while (k < 16) : (k += 1) out[k] = raw[k];
    return out;
}

fn hexDigit(c: u8) u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => @compileError("not a hex digit"),
    };
}

pub const guid_efi_system = guid("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
pub const guid_linux_fs = guid("0FC63DAF-8483-4772-8E79-3D69D8477DE4");
pub const guid_linux_swap = guid("0657FD6D-A4AB-43C4-84E5-0933C84B4F4F");
pub const guid_linux_lvm = guid("E6D6D379-F507-44C2-A23C-238F2A3DF928");
pub const guid_microsoft_basic = guid("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
/// The GUID of the fixture disk the probe writes.
pub const guid_fixture_disk = guid("CA55A000-0035-4000-8000-000000000035");

pub fn schemeName(scheme: Scheme) []const u8 {
    return switch (scheme) {
        .none => "none",
        .mbr => "MBR",
        .gpt => "GPT",
    };
}

pub fn typeName(entry: *const Entry) []const u8 {
    if (entry.scheme == .gpt) {
        if (sameBytes(16, &entry.type_guid, &guid_efi_system)) return "EFI System";
        if (sameBytes(16, &entry.type_guid, &guid_linux_fs)) return "Linux fs";
        if (sameBytes(16, &entry.type_guid, &guid_linux_swap)) return "Linux swap";
        if (sameBytes(16, &entry.type_guid, &guid_linux_lvm)) return "Linux LVM";
        if (sameBytes(16, &entry.type_guid, &guid_microsoft_basic)) return "Microsoft data";
        return "GPT data";
    }
    return switch (entry.type_mbr) {
        0x01 => "FAT12",
        0x04 => "FAT16 <32M",
        0x05, 0x0f, 0x85 => "extended",
        0x06 => "FAT16",
        0x07 => "NTFS/HPFS",
        0x0b => "FAT32",
        0x0c => "FAT32 LBA",
        0x0e => "FAT16 LBA",
        0x82 => "Linux swap",
        0x83 => "Linux",
        0x8e => "Linux LVM",
        0xee => "GPT protective",
        else => "MBR data",
    };
}

// ---------------------------------------------------------------------------
// Small helpers. No std.mem.eql anywhere: see the module comment.
// ---------------------------------------------------------------------------

fn sameBytes(comptime n: usize, a: *const [n]u8, b: *const [n]u8) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn putU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}

fn putU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

fn putU64(bytes: []u8, value: u64) void {
    std.mem.writeInt(u64, bytes[0..8], value, .little);
}

/// The reflected CRC-32/ISO-HDLC (polynomial 0xEDB88320) GPT specifies.
pub fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xffff_ffff;
    for (bytes) |byte| {
        c ^= byte;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = 0 -% (c & 1);
            c = (c >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    return ~c;
}

/// Render a GUID in its canonical form. `buf` must hold 36 bytes.
pub fn formatGuid(g: *const [16]u8, buf: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var pos: usize = 0;
    const order = [_]usize{ 3, 2, 1, 0 };
    for (order) |i| {
        out[pos] = hex[g[i] >> 4];
        out[pos + 1] = hex[g[i] & 0x0f];
        pos += 2;
    }
    out[pos] = '-';
    pos += 1;
    const order2 = [_]usize{ 5, 4 };
    for (order2) |i| {
        out[pos] = hex[g[i] >> 4];
        out[pos + 1] = hex[g[i] & 0x0f];
        pos += 2;
    }
    out[pos] = '-';
    pos += 1;
    const order3 = [_]usize{ 7, 6 };
    for (order3) |i| {
        out[pos] = hex[g[i] >> 4];
        out[pos + 1] = hex[g[i] & 0x0f];
        pos += 2;
    }
    out[pos] = '-';
    pos += 1;
    var i: usize = 8;
    while (i < 10) : (i += 1) {
        out[pos] = hex[g[i] >> 4];
        out[pos + 1] = hex[g[i] & 0x0f];
        pos += 2;
    }
    out[pos] = '-';
    pos += 1;
    i = 10;
    while (i < 16) : (i += 1) {
        out[pos] = hex[g[i] >> 4];
        out[pos + 1] = hex[g[i] & 0x0f];
        pos += 2;
    }
    buf.* = out;
    return buf[0..36];
}

// ---------------------------------------------------------------------------
// Parsing.
// ---------------------------------------------------------------------------

var mbr_sector: [sector_size]u8 align(8) = undefined;
var header_sector: [sector_size]u8 align(8) = undefined;
var entries_buf: [max_entry_bytes]u8 align(8) = undefined;
var write_entries: [max_entry_bytes]u8 align(8) = undefined;
var write_sector: [sector_size]u8 align(8) = undefined;
var write_header: [sector_size]u8 align(8) = undefined;

fn readSectors(b: block.Backend, lba: u64, buf: []u8, count: u32) Error!void {
    b.read(lba, buf.ptr, count) catch return error.Io;
}

fn writeSectors(b: block.Backend, lba: u64, buf: []const u8, count: u32) Error!void {
    b.write(lba, buf.ptr, count) catch return error.Io;
}

fn isExtended(type_mbr: u8) bool {
    return type_mbr == 0x05 or type_mbr == 0x0f or type_mbr == 0x85;
}

fn entryFromMbr(table: *Table, raw: []const u8, kind: Kind, absolute_start: u64) void {
    if (table.count == max_partitions) {
        table.skipped += 1;
        return;
    }
    const first = absolute_start;
    const count = readU32(raw[12..16]);
    if (count == 0 or first == 0 or first >= table.disk_sectors) {
        table.skipped += 1;
        return;
    }
    const last = first + count - 1;
    if (last >= table.disk_sectors) {
        table.skipped += 1;
        return;
    }
    table.entries[table.count] = .{
        .scheme = .mbr,
        .index = table.count + 1,
        .kind = kind,
        .bootable = raw[0] == 0x80,
        .type_mbr = raw[4],
        .first_lba = first,
        .last_lba = last,
    };
    table.count += 1;
}

fn parseMbr(table: *Table) Error!void {
    const b = block.backend orelse return error.NoDevice;
    table.scheme = .mbr;
    var extended_start: u64 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const raw = mbr_sector[446 + i * 16 ..][0..16];
        const type_mbr = raw[4];
        if (type_mbr == 0) continue;
        const start = readU32(raw[8..12]);
        if (isExtended(type_mbr)) {
            table.extended_containers += 1;
            if (extended_start == 0 and start != 0) extended_start = start;
            continue;
        }
        entryFromMbr(table, raw, .primary, start);
    }
    if (extended_start == 0) return;

    var ebr = extended_start;
    var seen: [max_ebr]u64 = undefined;
    var seen_count: usize = 0;
    while (seen_count < max_ebr) {
        if (ebr >= table.disk_sectors) return;
        var j: usize = 0;
        while (j < seen_count) : (j += 1) {
            if (seen[j] == ebr) return error.Loop;
        }
        seen[seen_count] = ebr;
        seen_count += 1;
        try readSectors(b, table.base_lba + ebr, mbr_sector[0..], 1);
        if (mbr_sector[510] != 0x55 or mbr_sector[511] != 0xaa) return error.BadSignature;
        table.ebr_scanned += 1;

        const logical = mbr_sector[446..][0..16];
        if (logical[4] != 0 and !isExtended(logical[4])) {
            entryFromMbr(table, logical, .logical, ebr + readU32(logical[8..12]));
        }
        const link = mbr_sector[462..][0..16];
        if (link[4] == 0 or !isExtended(link[4])) return;
        const next_rel = readU32(link[8..12]);
        if (next_rel == 0) return;
        ebr = extended_start + next_rel;
    }
    // A chain longer than the bound is corrupt, not a disk with 33 partitions.
    return error.Loop;
}

fn parseGptHeader(b: block.Backend, base: u64, disk: u64, header_lba: u64, verify_only: bool, table: *Table) Error!void {
    if (header_lba == 0 or header_lba >= disk or disk < 3) return error.BadEntryArray;
    try readSectors(b, base + header_lba, header_sector[0..], 1);
    if (!sameBytes(8, header_sector[0..8], "EFI PART")) return error.BadSignature;
    const revision = readU32(header_sector[8..12]);
    if ((revision >> 16) != 1) return error.BadRevision;
    const header_size = readU32(header_sector[12..16]);
    if (header_size < 92 or header_size > sector_size) return error.BadHeaderSize;
    const stored_crc = readU32(header_sector[16..20]);

    // CRC over the header with its own CRC field treated as zero.
    var copy: [sector_size]u8 align(8) = undefined;
    @memcpy(copy[0..header_size], header_sector[0..header_size]);
    putU32(copy[16..20], 0);
    const computed = crc32(copy[0..header_size]);
    if (computed != stored_crc) return error.BadHeaderCrc;

    const my_lba = readU64(header_sector[24..32]);
    if (my_lba != header_lba) return error.BadHeaderCrc;
    const alternate = readU64(header_sector[32..40]);
    const entries_lba = readU64(header_sector[72..80]);
    const entry_count = readU32(header_sector[80..84]);
    const entry_size = readU32(header_sector[84..88]);
    const entries_crc = readU32(header_sector[88..92]);

    if (entry_count == 0) return error.BadEntryArray;
    if (entry_count > max_entries) return error.TooManyEntries;
    if (entry_size < 128 or entry_size > 512 or (entry_size & (entry_size - 1)) != 0) return error.BadEntryArray;
    const total: usize = @as(usize, entry_count) * @as(usize, entry_size);
    if (total > max_entry_bytes) return error.BadEntryArray;
    const sectors: u32 = @intCast((total + sector_size - 1) / sector_size);
    if (entries_lba == 0 or entries_lba + sectors > disk) return error.BadEntryArray;
    try readSectors(b, base + entries_lba, entries_buf[0..], sectors);
    if (crc32(entries_buf[0..total]) != entries_crc) return error.BadEntryCrc;

    if (verify_only) return;
    table.revision = revision;
    table.header_size = header_size;
    table.header_crc = computed;
    table.entries_crc = entries_crc;
    table.entry_array_lba = entries_lba;
    table.entry_capacity = entry_count;
    table.entry_size = entry_size;
    table.alternate_lba = alternate;
    @memcpy(&table.disk_guid, header_sector[56..72]);

    table.scheme = .gpt;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        const raw = entries_buf[index * entry_size ..][0..entry_size];
        if (isZero(raw[0..16])) continue;
        const first = readU64(raw[32..40]);
        const last = readU64(raw[40..48]);
        if (first == 0 or last < first or last >= disk) {
            table.skipped += 1;
            continue;
        }
        if (table.count == max_partitions) {
            table.skipped += 1;
            continue;
        }
        var entry = Entry{
            .scheme = .gpt,
            .index = @intCast(index + 1),
            .kind = .primary,
            .type_guid = [_]u8{0} ** 16,
            .part_guid = [_]u8{0} ** 16,
            .first_lba = first,
            .last_lba = last,
            .attributes = readU64(raw[48..56]),
            .name = [_]u8{0} ** 36,
            .name_len = 0,
        };
        @memcpy(&entry.type_guid, raw[0..16]);
        @memcpy(&entry.part_guid, raw[16..32]);
        // Name: 36 UTF-16LE code units at offset 56. Non-ASCII becomes '?',
        // because a POS screen needs printable text, not a byte salad.
        var unit: usize = 0;
        while (unit < 36) : (unit += 1) {
            const code = readU16(raw[56 + unit * 2 ..][0..2]);
            if (code == 0) break;
            entry.name[unit] = if (code >= 0x20 and code < 0x7f) @intCast(code) else '?';
            entry.name_len += 1;
        }
        table.entries[table.count] = entry;
        table.count += 1;
    }
}

/// Read the partition table of the disk (or of a region inside it) into
/// `table`. The caller owns the storage because a Table is a kilobyte of
/// entries: returning it by value put too much on the shell's stack once and
/// the scheduler caught the overflow (thread 7 'wd' corrupt frame).
///
/// A disk with no signature is `error.NoTable`, not an empty table: the caller
/// must be able to tell "this disk is unformatted" from "this disk says it has
/// no partitions".
pub fn read(opts: Options, table: *Table) Error!void {
    const b = block.backend orelse return error.NoDevice;
    const base = opts.base_lba;
    if (base >= b.capacity_sectors) return error.NoTable;
    const disk: u64 = if (opts.disk_sectors != 0) opts.disk_sectors else b.capacity_sectors - base;
    if (disk < 4) return error.NoTable;

    table.* = .{ .base_lba = base, .disk_sectors = disk };
    try readSectors(b, base, mbr_sector[0..], 1);
    if (mbr_sector[510] != 0x55 or mbr_sector[511] != 0xaa) return error.NoTable;

    var protective = false;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (mbr_sector[446 + i * 16 + 4] == 0xee) protective = true;
    }
    table.protective_mbr = protective;

    if (!protective) {
        try parseMbr(table);
        return;
    }

    // Primary GPT. A damaged primary is retried on the backup, and the result
    // says which copy answered.
    parseGptHeader(b, base, disk, 1, false, table) catch |primary_err| {
        table.* = .{ .base_lba = base, .disk_sectors = disk, .protective_mbr = true };
        parseGptHeader(b, base, disk, disk - 1, false, table) catch return primary_err;
        table.backup_ok = true;
        table.backup_used = true;
        return;
    };
    table.protective_mbr = true;
    table.primary_ok = true;
    const backup_lba: u64 = if (table.alternate_lba != 0 and table.alternate_lba < disk) table.alternate_lba else disk - 1;
    if (backup_lba != 1) {
        parseGptHeader(b, base, disk, backup_lba, true, table) catch {
            table.backup_ok = false;
            return;
        };
        table.backup_ok = true;
    }
}

// ---------------------------------------------------------------------------
// Writing a GPT. The installer does not exist yet (it is a later phase), but
// the probe needs a table it produced itself to parse back, and a formatter is
// the only way to prove the writer/reader pair agrees on every field.
// ---------------------------------------------------------------------------

pub const Spec = struct {
    type_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    name: []const u8 = "",
    attributes: u64 = 0,
};

pub const WriteResult = struct {
    disk_guid: [16]u8 = [_]u8{0} ** 16,
    header_crc: u32 = 0,
    entries_crc: u32 = 0,
    backup_lba: u64 = 0,
    entry_count: u32 = 0,
};

fn fillName(raw: []u8, name: []const u8) void {
    @memset(raw, 0);
    var i: usize = 0;
    while (i < name.len and i < 36) : (i += 1) {
        const c = name[i];
        putU16(raw[i * 2 ..][0..2], if (c >= 0x20 and c < 0x7f) c else '?');
    }
}

/// Write a GPT (protective MBR, primary header+entries, backup entries+header)
/// over `opts.base_lba .. base_lba+disk_sectors`.
pub fn writeGpt(opts: Options, parts: []const Spec, disk_guid: [16]u8) Error!WriteResult {
    const b = block.backend orelse return error.NoDevice;
    const base = opts.base_lba;
    const disk: u64 = if (opts.disk_sectors != 0) opts.disk_sectors else b.capacity_sectors - base;
    if (disk < 128) return error.NoSpace;
    if (parts.len == 0 or parts.len > max_entries) return error.NoSpace;
    for (parts) |p| {
        if (p.first_lba < 34 or p.last_lba < p.first_lba or p.last_lba >= disk - 33) return error.NoSpace;
    }

    var result = WriteResult{
        .disk_guid = disk_guid,
        .backup_lba = disk - 1,
        .entry_count = max_entries,
    };

    // Entry array: 128 entries of 128 bytes.
    @memset(write_entries[0..], 0);
    for (parts, 0..) |p, index| {
        const raw = write_entries[index * 128 ..][0..128];
        @memcpy(raw[0..16], &p.type_guid);
        // A deterministic but unique partition GUID: the disk GUID with the
        // index folded into its last four bytes.
        var part_guid = disk_guid;
        part_guid[12] = @intCast((index + 1) & 0xff);
        part_guid[13] = @intCast(((index + 1) >> 8) & 0xff);
        @memcpy(raw[16..32], &part_guid);
        putU64(raw[32..40], p.first_lba);
        putU64(raw[40..48], p.last_lba);
        putU64(raw[48..56], p.attributes);
        fillName(raw[56..128], p.name);
    }
    result.entries_crc = crc32(write_entries[0..max_entry_bytes]);

    // Primary header at LBA 1.
    @memset(write_header[0..], 0);
    @memcpy(write_header[0..8], "EFI PART");
    putU32(write_header[8..12], 0x0001_0000);
    putU32(write_header[12..16], 92);
    putU64(write_header[24..32], 1);
    putU64(write_header[32..40], disk - 1);
    putU64(write_header[40..48], 34);
    putU64(write_header[48..56], disk - 34);
    @memcpy(write_header[56..72], &disk_guid);
    putU64(write_header[72..80], 2);
    putU32(write_header[80..84], max_entries);
    putU32(write_header[84..88], 128);
    putU32(write_header[88..92], result.entries_crc);
    putU32(write_header[16..20], 0);
    result.header_crc = crc32(write_header[0..92]);
    putU32(write_header[16..20], result.header_crc);

    // Protective MBR: one 0xEE entry covering the disk.
    @memset(write_sector[0..], 0);
    write_sector[446 + 4] = 0xee;
    putU32(write_sector[446 + 8 ..][0..4], 1);
    const covered: u32 = if (disk - 1 > 0xffff_ffff) 0xffff_ffff else @intCast(disk - 1);
    putU32(write_sector[446 + 12 ..][0..4], covered);
    write_sector[510] = 0x55;
    write_sector[511] = 0xaa;

    // Backup header at the last LBA, pointing at the backup entry array.
    var backup_header: [sector_size]u8 align(8) = undefined;
    @memcpy(backup_header[0..], write_header[0..]);
    putU64(backup_header[24..32], disk - 1);
    putU64(backup_header[32..40], 1);
    putU64(backup_header[72..80], disk - 33);
    putU32(backup_header[16..20], 0);
    const backup_crc = crc32(backup_header[0..92]);
    putU32(backup_header[16..20], backup_crc);

    // Order matters: entries before the headers that vouch for them, and a
    // flush before the primary is written so a crash cannot leave a header
    // promising an array that never reached the disk.
    try writeSectors(b, base + 2, write_entries[0..], max_entries * 128 / sector_size);
    try writeSectors(b, base + disk - 33, write_entries[0..], max_entries * 128 / sector_size);
    try writeSectors(b, base + disk - 1, backup_header[0..], 1);
    b.flush() catch return error.Io;
    try writeSectors(b, base, write_sector[0..], 1);
    try writeSectors(b, base + 1, write_header[0..], 1);
    b.flush() catch return error.Io;
    return result;
}

// ---------------------------------------------------------------------------
// The probe's fixture test: real device writes, real parses, and the negative
// cases that matter (a corrupt primary must fall back; two corrupt copies must
// be refused rather than guessed at).
// ---------------------------------------------------------------------------

pub const FixtureTest = struct {
    present: bool = false,
    written: bool = false,
    header_crc: u32 = 0,
    entries_crc: u32 = 0,
    parsed: bool = false,
    count: u8 = 0,
    names_ok: bool = false,
    lbas_ok: bool = false,
    primary_ok: bool = false,
    backup_ok: bool = false,
    fallback_ok: bool = false,
    fallback_count: u8 = 0,
    rejected: bool = false,
    reject_error: []const u8 = "",
    restored: bool = false,
    restored_count: u8 = 0,
    mbr_ok: bool = false,
    mbr_count: u8 = 0,
    mbr_primary: u8 = 0,
    mbr_logical: u8 = 0,
    mbr_ebrs: u8 = 0,
    errors: u16 = 0,
};

pub const fixture_base: u64 = 20_000;
pub const fixture_sectors: u64 = 4_096;
const mbr_base: u64 = 30_000;
const mbr_sectors: u64 = 4_096;

fn fixtureSpecs() [3]Spec {
    return .{
        .{ .type_guid = guid_efi_system, .first_lba = 2_048, .last_lba = 2_303, .name = "EFI" },
        .{ .type_guid = guid_linux_fs, .first_lba = 2_304, .last_lba = 3_071, .name = "system" },
        .{ .type_guid = guid_linux_swap, .first_lba = 3_072, .last_lba = 3_327, .name = "swap" },
    };
}

fn fixtureMatches(table: *const Table) bool {
    if (table.count != 3) return false;
    const want = fixtureSpecs();
    for (want, 0..) |w, i| {
        const got = table.entries[i];
        if (got.first_lba != w.first_lba or got.last_lba != w.last_lba) return false;
        if (!bytesEqual(got.nameText(), w.name)) return false;
        if (got.scheme != .gpt) return false;
    }
    return true;
}

fn writeSectorAt(lba: u64, raw: []const u8) Error!void {
    const b = block.backend orelse return error.NoDevice;
    try writeSectors(b, lba, raw, 1);
}

fn readSectorAt(lba: u64, raw: []u8) Error!void {
    const b = block.backend orelse return error.NoDevice;
    try readSectors(b, lba, raw, 1);
}

pub fn fixtureTest() FixtureTest {
    var result = FixtureTest{};
    if (block.backend == null) return result;
    result.present = true;

    const gpt_opts = Options{ .base_lba = fixture_base, .disk_sectors = fixture_sectors };
    const written = writeGpt(gpt_opts, &fixtureSpecs(), guid_fixture_disk) catch |err| {
        result.errors += 1;
        result.reject_error = @errorName(err);
        return result;
    };
    result.written = written.header_crc != 0 and written.entries_crc != 0;
    result.header_crc = written.header_crc;
    result.entries_crc = written.entries_crc;

    var table: Table = .{};
    if (read(gpt_opts, &table)) |_| {
        result.parsed = table.scheme == .gpt;
        result.count = table.count;
        result.primary_ok = table.primary_ok;
        result.backup_ok = table.backup_ok;
        result.names_ok = fixtureMatches(&table);
        result.lbas_ok = fixtureMatches(&table);
    } else |_| {
        result.errors += 1;
    }

    // Corrupt one byte of the primary entry array: the primary CRC must fail and
    // the backup must answer, with the same three partitions.
    readSectorAt(fixture_base + 2, write_sector[0..]) catch {
        result.errors += 1;
    };
    write_sector[0] ^= 0xff;
    writeSectorAt(fixture_base + 2, write_sector[0..]) catch {
        result.errors += 1;
    };
    if (read(gpt_opts, &table)) |_| {
        result.fallback_ok = table.backup_used and table.count == 3 and !table.primary_ok and table.backup_ok;
        result.fallback_count = table.count;
    } else |_| {
        result.errors += 1;
    }

    // Corrupt the backup header too: both copies are now damaged, and the parser
    // must refuse instead of returning a half-believed table.
    readSectorAt(fixture_base + fixture_sectors - 1, write_sector[0..]) catch {
        result.errors += 1;
    };
    write_sector[0] = 0;
    writeSectorAt(fixture_base + fixture_sectors - 1, write_sector[0..]) catch {
        result.errors += 1;
    };
    if (read(gpt_opts, &table)) |_| {
        result.errors += 1;
    } else |err| {
        result.rejected = true;
        result.reject_error = @errorName(err);
    }

    // Put the fixture back: a formatter and a parser that are worth anything
    // leave the disk usable.
    _ = writeGpt(gpt_opts, &fixtureSpecs(), guid_fixture_disk) catch {
        result.errors += 1;
        return result;
    };
    if (read(gpt_opts, &table)) |_| {
        result.restored = table.count == 3 and table.primary_ok and table.backup_ok;
        result.restored_count = table.count;
    } else |_| {
        result.errors += 1;
    }

    // An MBR disk: two primaries, an extended container and one logical
    // partition found through the EBR chain.
    const mbr_opts = Options{ .base_lba = mbr_base, .disk_sectors = mbr_sectors };
    @memset(write_sector[0..], 0);
    write_sector[446] = 0x80; // bootable
    write_sector[446 + 4] = 0x07; // NTFS
    putU32(write_sector[446 + 8 ..][0..4], 64);
    putU32(write_sector[446 + 12 ..][0..4], 512);
    write_sector[462 + 4] = 0x83; // Linux
    putU32(write_sector[462 + 8 ..][0..4], 1_024);
    putU32(write_sector[462 + 12 ..][0..4], 512);
    write_sector[478 + 4] = 0x0f; // extended
    putU32(write_sector[478 + 8 ..][0..4], 1_600);
    putU32(write_sector[478 + 12 ..][0..4], 400);
    write_sector[510] = 0x55;
    write_sector[511] = 0xaa;
    writeSectorAt(mbr_base, write_sector[0..]) catch {
        result.errors += 1;
    };

    @memset(write_sector[0..], 0);
    write_sector[446 + 4] = 0x83; // logical
    putU32(write_sector[446 + 8 ..][0..4], 8); // relative to its EBR
    putU32(write_sector[446 + 12 ..][0..4], 200);
    write_sector[510] = 0x55;
    write_sector[511] = 0xaa;
    writeSectorAt(mbr_base + 1_600, write_sector[0..]) catch {
        result.errors += 1;
    };

    if (read(mbr_opts, &table)) |_| {
        result.mbr_count = table.count;
        result.mbr_ebrs = table.ebr_scanned;
        var primary: u8 = 0;
        var logical: u8 = 0;
        for (table.entries[0..table.count]) |*e| {
            if (e.kind == .primary) primary += 1 else logical += 1;
        }
        result.mbr_primary = primary;
        result.mbr_logical = logical;
        result.mbr_ok = table.scheme == .mbr and table.count == 3 and primary == 2 and logical == 1 and
            table.ebr_scanned == 1 and table.extended_containers == 1;
    } else |_| {
        result.errors += 1;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Tests: the parsers against hand-built tables, including every rejection path.
// ---------------------------------------------------------------------------

var test_image: [4096 * sector_size]u8 align(8) = undefined;

fn testRead(lba: u64, buf: [*]u8, count: u32) block.Error!void {
    const start: usize = @intCast(lba * sector_size);
    const len: usize = @as(usize, count) * sector_size;
    if (start + len > test_image.len) return error.IoError;
    @memcpy(buf[0..len], test_image[start..][0..len]);
}

fn testWrite(lba: u64, buf: [*]const u8, count: u32) block.Error!void {
    const start: usize = @intCast(lba * sector_size);
    const len: usize = @as(usize, count) * sector_size;
    if (start + len > test_image.len) return error.NoSpace;
    @memcpy(test_image[start..][0..len], buf[0..len]);
}

fn testFlush() block.Error!void {}

fn installTestDisk() void {
    @memset(test_image[0..], 0);
    block.install(.{
        .capacity_sectors = test_image.len / sector_size,
        .read = testRead,
        .write = testWrite,
        .flush = testFlush,
    });
}

test "crc32 matches the published check value" {
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0), crc32(""));
}

test "a written GPT reads back: three partitions, both copies valid" {
    installTestDisk();
    defer block.uninstall();
    const specs = fixtureSpecs();
    const w = try writeGpt(.{ .disk_sectors = 4096 }, &specs, guid_fixture_disk);
    try std.testing.expect(w.header_crc != 0);

    var table: Table = .{};
    try read(.{ .disk_sectors = 4096 }, &table);
    try std.testing.expectEqual(Scheme.gpt, table.scheme);
    try std.testing.expectEqual(@as(u8, 3), table.count);
    try std.testing.expect(table.primary_ok);
    try std.testing.expect(table.backup_ok);
    try std.testing.expect(!table.backup_used);
    try std.testing.expect(table.protective_mbr);
    try std.testing.expectEqual(w.header_crc, table.header_crc);
    try std.testing.expectEqual(w.entries_crc, table.entries_crc);
    try std.testing.expect(fixtureMatches(&table));
    try std.testing.expectEqual(@as(u64, 2_048), table.entries[0].first_lba);
    try std.testing.expectEqualStrings("EFI", table.entries[0].nameText());
}

test "a corrupt primary entry array is read from the backup" {
    installTestDisk();
    defer block.uninstall();
    const specs = fixtureSpecs();
    _ = try writeGpt(.{ .disk_sectors = 4096 }, &specs, guid_fixture_disk);
    test_image[2 * sector_size + 40] ^= 0x7f; // inside the primary entry array

    var table: Table = .{};
    try read(.{ .disk_sectors = 4096 }, &table);
    try std.testing.expect(table.backup_used);
    try std.testing.expect(!table.primary_ok);
    try std.testing.expect(table.backup_ok);
    try std.testing.expectEqual(@as(u8, 3), table.count);
    try std.testing.expect(fixtureMatches(&table));
}

test "a corrupt header CRC with a sound backup is still readable" {
    installTestDisk();
    defer block.uninstall();
    _ = try writeGpt(.{ .disk_sectors = 4096 }, &fixtureSpecs(), guid_fixture_disk);
    test_image[sector_size + 20] ^= 0xff; // inside the primary header CRC field

    var table: Table = .{};
    try read(.{ .disk_sectors = 4096 }, &table);
    try std.testing.expect(table.backup_used);
    try std.testing.expectEqual(@as(u8, 3), table.count);
}

test "both copies damaged is refused, not guessed" {
    installTestDisk();
    defer block.uninstall();
    _ = try writeGpt(.{ .disk_sectors = 4096 }, &fixtureSpecs(), guid_fixture_disk);
    test_image[2 * sector_size] ^= 0xff; // primary entries
    test_image[(4096 - 1) * sector_size] = 0; // backup signature

    var table: Table = .{};
    try std.testing.expectError(error.BadEntryCrc, read(.{ .disk_sectors = 4096 }, &table));
}

test "an unformatted disk is NoTable, not an empty table" {
    installTestDisk();
    defer block.uninstall();
    var table: Table = .{};
    try std.testing.expectError(error.NoTable, read(.{ .disk_sectors = 4096 }, &table));
}

test "MBR primaries and an EBR chain enumerate" {
    installTestDisk();
    defer block.uninstall();
    var mbr = [_]u8{0} ** sector_size;
    mbr[446 + 4] = 0x07;
    putU32(mbr[446 + 8 ..][0..4], 64);
    putU32(mbr[446 + 12 ..][0..4], 512);
    mbr[462 + 4] = 0x83;
    putU32(mbr[462 + 8 ..][0..4], 1_024);
    putU32(mbr[462 + 12 ..][0..4], 512);
    mbr[478 + 4] = 0x0f;
    putU32(mbr[478 + 8 ..][0..4], 1_600);
    putU32(mbr[478 + 12 ..][0..4], 400);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    @memcpy(test_image[0..sector_size], &mbr);

    var ebr = [_]u8{0} ** sector_size;
    ebr[446 + 4] = 0x83;
    putU32(ebr[446 + 8 ..][0..4], 8);
    putU32(ebr[446 + 12 ..][0..4], 200);
    ebr[510] = 0x55;
    ebr[511] = 0xaa;
    @memcpy(test_image[1_600 * sector_size ..][0..sector_size], &ebr);

    var table: Table = .{};
    try read(.{ .disk_sectors = 4096 }, &table);
    try std.testing.expectEqual(Scheme.mbr, table.scheme);
    try std.testing.expectEqual(@as(u8, 3), table.count);
    try std.testing.expectEqual(@as(u8, 1), table.extended_containers);
    try std.testing.expectEqual(@as(u8, 1), table.ebr_scanned);
    try std.testing.expectEqual(@as(u64, 1_608), table.entries[2].first_lba);
    try std.testing.expectEqual(Kind.logical, table.entries[2].kind);
    try std.testing.expect(table.entries[0].bootable == false);
}

test "a protective MBR with no GPT is reported, not enumerated" {
    installTestDisk();
    defer block.uninstall();
    var mbr = [_]u8{0} ** sector_size;
    mbr[446 + 4] = 0xee;
    putU32(mbr[446 + 8 ..][0..4], 1);
    putU32(mbr[446 + 12 ..][0..4], 255);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    @memcpy(test_image[0..sector_size], &mbr);
    var table: Table = .{};
    try std.testing.expectError(error.BadSignature, read(.{ .disk_sectors = 4096 }, &table));
}

test "a runaway EBR chain stops at the bound" {
    installTestDisk();
    defer block.uninstall();
    var mbr = [_]u8{0} ** sector_size;
    mbr[446 + 4] = 0x0f;
    putU32(mbr[446 + 8 ..][0..4], 100);
    putU32(mbr[446 + 12 ..][0..4], 200);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    @memcpy(test_image[0..sector_size], &mbr);
    // Each EBR links to the next one, forever (relative to the extended start).
    var step: u32 = 0;
    while (step < max_ebr + 4) : (step += 1) {
        var ebr = [_]u8{0} ** sector_size;
        ebr[446 + 4] = 0x83;
        putU32(ebr[446 + 8 ..][0..4], 4);
        putU32(ebr[446 + 12 ..][0..4], 1);
        ebr[462 + 4] = 0x0f;
        putU32(ebr[462 + 8 ..][0..4], step + 1);
        putU32(ebr[462 + 12 ..][0..4], 1);
        ebr[510] = 0x55;
        ebr[511] = 0xaa;
        const lba: usize = 100 + step;
        @memcpy(test_image[lba * sector_size ..][0..sector_size], &ebr);
    }
    var table: Table = .{};
    try std.testing.expectError(error.Loop, read(.{ .disk_sectors = 4096 }, &table));
}

test "GUID text renders in the canonical order" {
    var buf: [36]u8 = undefined;
    try std.testing.expectEqualStrings("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", formatGuid(&guid_efi_system, &buf));
}
