//! CASSAFS on-disk format (phase 41).
//!
//! CASSAFS is a log-structured filesystem built for a till: every variable
//! object is a record in one append-only log, every record carries a CRC32C,
//! and the fixed superblocks are written as an A/B pair so the older copy can
//! recover the volume when the newer copy is torn. The format defined here is
//! intentionally complete enough to be formatted, dumped and verified before
//! the mount/write path arrives in phases 42–43.
//!
//! Volume layout (4 KiB blocks):
//!
//!   block 0      superblock A
//!   block 1      superblock B
//!   block 2..    log records, in increasing sequence order
//!                +-----------+--------------------------------------------+
//!                | header    | payload starts at the next block boundary  |
//!                | 64 bytes  | payload blocks are zero padded              |
//!                +-----------+--------------------------------------------+
//!
//! A record header is 64 bytes: magic, format version, kind, flags, sequence,
//! payload length, total block count, payload CRC32C and header CRC32C. The
//! header CRC covers the first 60 header bytes; the payload CRC covers exactly
//! `payload_len` bytes. Every log record is therefore independently verifiable.
//!
//! The last two records are a free-space bitmap and a checkpoint. The checkpoint
//! names the root inode, the log head and the free-map record. The superblock
//! repeats the checkpoint pointer and is written to both slots with increasing
//! generations; verification chooses the highest valid generation, so damaging
//! one slot is a reported fallback rather than a dead volume.
//!
//! Inodes carry a parent inode and a name, making the inode tree a parent-pointer
//! tree; files carry byte extents into data records. Extents are `(logical
//! offset, physical block, offset in block, length)`, so a future read path can
//! serve a file without copying it. The free-space map is a bitmap over all
//! volume blocks; phase 41's append-only log uses a prefix, so verification can
//! prove both the bitmap and the allocation accounting exactly.
//!
//! Versioning is explicit: `format_version` is 1, the superblock has compatible
//! and incompatible feature words, and unknown incompatible features are refused
//! rather than guessed. The record version is independent so a future format can
//! add record types without changing the superblock contract.
//!
//! This file is pure logic plus a callback block device. The kernel adapter and
//! the host reference tool both use the same formatter, scanner and reader.

const std = @import("std");

pub const block_size: usize = 4096;
pub const superblock_size: usize = 512;
pub const format_version: u16 = 1;
pub const record_version: u8 = 1;
pub const superblock_magic: u32 = 0x5341_5343; // "CSAS" little-endian
pub const record_magic: u32 = 0x4641_5343; // "CSAF" little-endian
pub const record_header_size: usize = 64;
pub const superblock_crc_offset: usize = 508;
pub const max_name = 31;
pub const max_nodes = 128;
pub const max_extents = 8;
pub const max_file_bytes = max_extents * max_record_payload;
pub const max_record_payload = 16 * 1024;
pub const max_records = 128;
pub const max_volume_blocks: u32 = 262_144; // 1 GiB at 4 KiB blocks
pub const inode_payload_size: usize = 76 + max_extents * 24;
pub const checkpoint_payload_size: usize = 120;

pub const Error = error{
    Io,
    ReadOnly,
    NoDevice,
    OutOfRange,
    NoSpace,
    BadMagic,
    BadVersion,
    BadSuperblock,
    BadRecord,
    BadCrc,
    BadSequence,
    BadCheckpoint,
    BadInode,
    DuplicateInode,
    BadTree,
    BadExtent,
    BadFreeMap,
    CountMismatch,
    TooManyNodes,
    TooManyRecords,
    NameTooLong,
    BadFixture,
    FileTooLarge,
    PathNotFound,
    BufferTooSmall,
    Unsupported,
};

pub const Device = struct {
    ctx: *anyopaque,
    blocks: u32,
    read_fn: *const fn (ctx: *anyopaque, block: u32, buf: *[block_size]u8) Error!void,
    write_fn: *const fn (ctx: *anyopaque, block: u32, buf: *const [block_size]u8) Error!void,
    flush_fn: *const fn (ctx: *anyopaque) Error!void,

    pub fn read(self: Device, block: u32, buf: *[block_size]u8) Error!void {
        if (block >= self.blocks) return error.OutOfRange;
        return self.read_fn(self.ctx, block, buf);
    }

    pub fn write(self: Device, block: u32, buf: *const [block_size]u8) Error!void {
        if (block >= self.blocks) return error.OutOfRange;
        return self.write_fn(self.ctx, block, buf);
    }

    pub fn flush(self: Device) Error!void {
        return self.flush_fn(self.ctx);
    }
};

pub const Kind = enum(u8) {
    inode = 1,
    data = 2,
    free_map = 3,
    checkpoint = 4,
};

pub const Slot = enum { a, b };

pub const Extent = struct {
    logical_offset: u64 = 0,
    physical_block: u32 = 0,
    physical_offset: u16 = 0,
    length: u32 = 0,
};

pub const Inode = struct {
    ino: u64 = 0,
    parent: u64 = 0,
    kind: Kind = .inode,
    name: [max_name + 1]u8 = [_]u8{0} ** (max_name + 1),
    name_len: u8 = 0,
    size: u64 = 0,
    mode: u16 = 0,
    mtime: u64 = 0,
    data_crc: u32 = 0,
    extent_count: u8 = 0,
    extents: [max_extents]Extent = [_]Extent{.{}} ** max_extents,

    pub fn nameSlice(self: *const Inode) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Superblock = struct {
    magic: u32 = superblock_magic,
    version: u16 = format_version,
    block_size: u32 = block_size,
    total_blocks: u32 = 0,
    generation: u64 = 0,
    checkpoint_block: u32 = 0,
    checkpoint_seq: u64 = 0,
    checkpoint_crc: u32 = 0,
    root_ino: u64 = 1,
    log_head: u32 = 0,
    free_blocks: u32 = 0,
    inode_count: u32 = 0,
    created_sec: u64 = 0,
    features: u64 = 1,
    compat: u32 = 0,
    incompat: u32 = 1,
    uuid: [16]u8 = [_]u8{0} ** 16,
    label: [32]u8 = [_]u8{0} ** 32,
};

pub const RecordHeader = struct {
    version: u8 = record_version,
    kind: Kind = .inode,
    flags: u16 = 0,
    seq: u64 = 0,
    payload_len: u32 = 0,
    total_blocks: u32 = 0,
    record_crc: u32 = 0,
    timestamp: u64 = 0,
};

pub const Checkpoint = struct {
    version: u8 = 1,
    root_ino: u64 = 1,
    next_ino: u64 = 2,
    inode_count: u32 = 0,
    dir_count: u32 = 0,
    file_count: u32 = 0,
    record_count: u32 = 0,
    log_head: u32 = 0,
    total_blocks: u32 = 0,
    used_blocks: u32 = 0,
    free_blocks: u32 = 0,
    free_map_block: u32 = 0,
    free_map_seq: u64 = 0,
    data_bytes: u64 = 0,
    uuid: [16]u8 = [_]u8{0} ** 16,
    label: [32]u8 = [_]u8{0} ** 32,
};

pub const SuperStatus = struct {
    valid: bool = false,
    generation: u64 = 0,
    checkpoint_block: u32 = 0,
    checkpoint_seq: u64 = 0,
    log_head: u32 = 0,
    free_blocks: u32 = 0,
    inode_count: u32 = 0,
};

pub const RecordInfo = struct {
    seq: u64 = 0,
    kind: Kind = .inode,
    block: u32 = 0,
    blocks: u32 = 0,
    payload_len: u32 = 0,
};

pub const Report = struct {
    a: SuperStatus = .{},
    b: SuperStatus = .{},
    active: Slot = .b,
    fallback: bool = false,
    format_version: u16 = format_version,
    block_size: u32 = block_size,
    total_blocks: u32 = 0,
    log_head: u32 = 0,
    used_blocks: u32 = 0,
    free_blocks: u32 = 0,
    records: u32 = 0,
    first_seq: u64 = 0,
    last_seq: u64 = 0,
    record_infos: [max_records]RecordInfo = [_]RecordInfo{.{}} ** max_records,
    record_info_count: u32 = 0,
    inodes: []Inode = &.{},
    inode_count: u32 = 0,
    dirs: u32 = 0,
    files: u32 = 0,
    data_bytes: u64 = 0,
    root_ino: u64 = 1,
    next_ino: u64 = 2,
    checkpoint: Checkpoint = .{},
    free_map_block: u32 = 0,
    free_map_seq: u64 = 0,
    uuid: [16]u8 = [_]u8{0} ** 16,
    label: [32]u8 = [_]u8{0} ** 32,
};

pub const Node = struct {
    ino: u64,
    parent: u64,
    kind: Kind,
    name: []const u8,
    data: []const u8 = "",
};

pub const Fixture = struct {
    nodes: []const Node,
    label: []const u8 = "Cassa Data",
    uuid: [16]u8 = [_]u8{0} ** 16,
    created_sec: u64 = 0,
};

pub const FormatStats = struct {
    log_head: u32 = 0,
    used_blocks: u32 = 0,
    free_blocks: u32 = 0,
    records: u32 = 0,
    inode_count: u32 = 0,
    dirs: u32 = 0,
    files: u32 = 0,
    data_bytes: u64 = 0,
    a_generation: u64 = 1,
    b_generation: u64 = 2,
};

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

fn writeU16(bytes: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[off..][0..2], value, .little);
}

fn writeU32(bytes: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], value, .little);
}

fn writeU64(bytes: []u8, off: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[off..][0..8], value, .little);
}

fn copyName(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    @memcpy(dst[0..@min(dst.len, src.len)], src[0..@min(dst.len, src.len)]);
}

fn nameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// CRC32C (Castagnoli, reflected polynomial 0x82F63B78)
// ---------------------------------------------------------------------------

const crc32c_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var c = i;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            c = if ((c & 1) != 0) (c >> 1) ^ 0x82F6_3B78 else c >> 1;
        }
        table[i] = c;
    }
    break :blk table;
};

pub fn crc32cUpdate(state: u32, bytes: []const u8) u32 {
    var crc = state;
    for (bytes) |b| {
        crc = crc32c_table[(crc ^ b) & 0xff] ^ (crc >> 8);
    }
    return crc;
}

pub fn crc32c(bytes: []const u8) u32 {
    return ~crc32cUpdate(0xffff_ffff, bytes);
}

// ---------------------------------------------------------------------------
// Superblock
// ---------------------------------------------------------------------------

pub fn encodeSuperblock(sb: Superblock, out: *[superblock_size]u8) void {
    @memset(out, 0);
    writeU32(out, 0, sb.magic);
    writeU16(out, 4, sb.version);
    writeU16(out, 6, superblock_size);
    writeU64(out, 8, sb.generation);
    writeU32(out, 16, sb.checkpoint_block);
    writeU32(out, 20, sb.block_size);
    writeU32(out, 24, sb.total_blocks);
    writeU32(out, 28, sb.log_head);
    writeU64(out, 32, sb.root_ino);
    writeU32(out, 40, sb.free_blocks);
    writeU32(out, 44, sb.inode_count);
    writeU64(out, 48, sb.created_sec);
    writeU64(out, 56, sb.features);
    writeU32(out, 64, sb.compat);
    writeU32(out, 68, sb.incompat);
    @memcpy(out[72..88], &sb.uuid);
    @memcpy(out[88..120], &sb.label);
    writeU64(out, 120, sb.checkpoint_seq);
    writeU32(out, 128, sb.checkpoint_crc);
    writeU32(out, superblock_crc_offset, crc32c(out[0..superblock_crc_offset]));
}

pub fn decodeSuperblock(bytes: []const u8) Error!Superblock {
    if (bytes.len < superblock_size) return error.BadSuperblock;
    if (readU32(bytes, 0) != superblock_magic) return error.BadMagic;
    if (readU16(bytes, 4) != format_version) return error.Unsupported;
    if (readU16(bytes, 6) != superblock_size) return error.BadSuperblock;
    if (readU32(bytes, 20) != block_size) return error.BadSuperblock;
    if (readU32(bytes, 24) == 0 or readU32(bytes, 24) > max_volume_blocks) return error.BadSuperblock;
    if (readU64(bytes, 56) & 1 == 0) return error.BadSuperblock;
    if (readU32(bytes, 68) & ~@as(u32, 1) != 0) return error.Unsupported;
    if (readU32(bytes, superblock_crc_offset) != crc32c(bytes[0..superblock_crc_offset])) return error.BadCrc;
    var sb = Superblock{};
    sb.magic = readU32(bytes, 0);
    sb.version = readU16(bytes, 4);
    sb.generation = readU64(bytes, 8);
    sb.checkpoint_block = readU32(bytes, 16);
    sb.block_size = readU32(bytes, 20);
    sb.total_blocks = readU32(bytes, 24);
    sb.log_head = readU32(bytes, 28);
    sb.root_ino = readU64(bytes, 32);
    sb.free_blocks = readU32(bytes, 40);
    sb.inode_count = readU32(bytes, 44);
    sb.created_sec = readU64(bytes, 48);
    sb.features = readU64(bytes, 56);
    sb.compat = readU32(bytes, 64);
    sb.incompat = readU32(bytes, 68);
    @memcpy(&sb.uuid, bytes[72..88]);
    @memcpy(&sb.label, bytes[88..120]);
    sb.checkpoint_seq = readU64(bytes, 120);
    sb.checkpoint_crc = readU32(bytes, 128);
    if (sb.checkpoint_block < 2 or sb.checkpoint_block >= sb.total_blocks) return error.BadSuperblock;
    if (sb.log_head < 2 or sb.log_head > sb.total_blocks) return error.BadSuperblock;
    if (sb.checkpoint_block >= sb.log_head) return error.BadSuperblock;
    if (sb.free_blocks > sb.total_blocks) return error.BadSuperblock;
    if (sb.free_blocks != sb.total_blocks - sb.log_head) return error.BadSuperblock;
    return sb;
}

fn superStatus(sb: Superblock) SuperStatus {
    return .{
        .valid = true,
        .generation = sb.generation,
        .checkpoint_block = sb.checkpoint_block,
        .checkpoint_seq = sb.checkpoint_seq,
        .log_head = sb.log_head,
        .free_blocks = sb.free_blocks,
        .inode_count = sb.inode_count,
    };
}

// ---------------------------------------------------------------------------
// Record headers, inodes and checkpoints
// ---------------------------------------------------------------------------

fn validKind(raw: u8) ?Kind {
    return std.meta.intToEnum(Kind, raw) catch null;
}

pub fn encodeRecordHeader(header: RecordHeader, out: []u8) void {
    @memset(out[0..record_header_size], 0);
    writeU32(out, 0, record_magic);
    out[4] = header.version;
    out[5] = @intFromEnum(header.kind);
    writeU16(out, 6, header.flags);
    writeU64(out, 8, header.seq);
    writeU32(out, 16, header.payload_len);
    writeU32(out, 20, header.total_blocks);
    writeU32(out, 24, header.record_crc);
    writeU64(out, 32, header.timestamp);
    writeU32(out, 60, crc32c(out[0..60]));
}

pub fn decodeRecordHeader(bytes: []const u8) Error!RecordHeader {
    if (bytes.len < record_header_size) return error.BadRecord;
    if (readU32(bytes, 0) != record_magic) return error.BadMagic;
    if (bytes[4] != record_version) return error.BadVersion;
    const kind = validKind(bytes[5]) orelse return error.BadRecord;
    if (readU32(bytes, 60) != crc32c(bytes[0..60])) return error.BadCrc;
    const header = RecordHeader{
        .version = bytes[4],
        .kind = kind,
        .flags = readU16(bytes, 6),
        .seq = readU64(bytes, 8),
        .payload_len = readU32(bytes, 16),
        .total_blocks = readU32(bytes, 20),
        .record_crc = readU32(bytes, 24),
        .timestamp = readU64(bytes, 32),
    };
    if (header.payload_len > max_record_payload) return error.BadRecord;
    const expected: u32 = 1 + @as(u32, @intCast((header.payload_len + block_size - 1) / block_size));
    if (header.total_blocks != expected) return error.BadRecord;
    return header;
}

pub fn encodeInode(inode: *const Inode, out: *[inode_payload_size]u8) void {
    @memset(out, 0);
    out[0] = 1;
    out[1] = @intFromEnum(inode.kind);
    out[2] = inode.name_len;
    out[3] = inode.extent_count;
    writeU64(out, 4, inode.ino);
    writeU64(out, 12, inode.parent);
    writeU64(out, 20, inode.size);
    writeU32(out, 28, inode.data_crc);
    writeU64(out, 32, inode.mtime);
    writeU16(out, 40, inode.mode);
    @memcpy(out[44..76], &inode.name);
    var i: usize = 0;
    while (i < max_extents) : (i += 1) {
        const base = 76 + i * 24;
        const e = inode.extents[i];
        writeU64(out, base, e.logical_offset);
        writeU32(out, base + 8, e.physical_block);
        writeU16(out, base + 12, e.physical_offset);
        writeU32(out, base + 16, e.length);
    }
}

pub fn decodeInode(bytes: []const u8) Error!Inode {
    if (bytes.len != inode_payload_size) return error.BadInode;
    if (bytes[0] != 1) return error.BadInode;
    const kind = validKind(bytes[1]) orelse return error.BadInode;
    if (kind != .inode and kind != .data) return error.BadInode;
    if (bytes[3] > max_extents) return error.BadInode;
    var inode = Inode{};
    inode.kind = kind;
    inode.name_len = bytes[2];
    if (inode.name_len > max_name) return error.BadInode;
    inode.extent_count = bytes[3];
    inode.ino = readU64(bytes, 4);
    inode.parent = readU64(bytes, 12);
    inode.size = readU64(bytes, 20);
    inode.data_crc = readU32(bytes, 28);
    inode.mtime = readU64(bytes, 32);
    inode.mode = readU16(bytes, 40);
    @memcpy(&inode.name, bytes[44..76]);
    var i: usize = 0;
    while (i < inode.extent_count) : (i += 1) {
        const base = 76 + i * 24;
        inode.extents[i] = .{
            .logical_offset = readU64(bytes, base),
            .physical_block = readU32(bytes, base + 8),
            .physical_offset = readU16(bytes, base + 12),
            .length = readU32(bytes, base + 16),
        };
    }
    return inode;
}

pub fn encodeCheckpoint(cp: *const Checkpoint, out: *[checkpoint_payload_size]u8) void {
    @memset(out, 0);
    out[0] = cp.version;
    writeU64(out, 4, cp.root_ino);
    writeU64(out, 12, cp.next_ino);
    writeU32(out, 20, cp.inode_count);
    writeU32(out, 24, cp.dir_count);
    writeU32(out, 28, cp.file_count);
    writeU32(out, 32, cp.record_count);
    writeU32(out, 36, cp.log_head);
    writeU32(out, 40, cp.total_blocks);
    writeU32(out, 44, cp.used_blocks);
    writeU32(out, 48, cp.free_blocks);
    writeU32(out, 52, cp.free_map_block);
    writeU64(out, 56, cp.free_map_seq);
    writeU64(out, 64, cp.data_bytes);
    @memcpy(out[72..88], &cp.uuid);
    @memcpy(out[88..120], &cp.label);
}

pub fn decodeCheckpoint(bytes: []const u8) Error!Checkpoint {
    if (bytes.len != checkpoint_payload_size) return error.BadCheckpoint;
    if (bytes[0] != 1) return error.BadCheckpoint;
    var cp = Checkpoint{};
    cp.version = bytes[0];
    cp.root_ino = readU64(bytes, 4);
    cp.next_ino = readU64(bytes, 12);
    cp.inode_count = readU32(bytes, 20);
    cp.dir_count = readU32(bytes, 24);
    cp.file_count = readU32(bytes, 28);
    cp.record_count = readU32(bytes, 32);
    cp.log_head = readU32(bytes, 36);
    cp.total_blocks = readU32(bytes, 40);
    cp.used_blocks = readU32(bytes, 44);
    cp.free_blocks = readU32(bytes, 48);
    cp.free_map_block = readU32(bytes, 52);
    cp.free_map_seq = readU64(bytes, 56);
    cp.data_bytes = readU64(bytes, 64);
    @memcpy(&cp.uuid, bytes[72..88]);
    @memcpy(&cp.label, bytes[88..120]);
    return cp;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

pub fn freeMapPayloadLen(blocks: u32) usize {
    return 8 + (@as(usize, blocks) + 7) / 8;
}

pub fn workspaceRequired(blocks: u32) usize {
    return @max(freeMapPayloadLen(blocks), max_record_payload);
}

fn recordBlocks(payload_len: usize) u32 {
    return 1 + @as(u32, @intCast((payload_len + block_size - 1) / block_size));
}

fn writeRecord(device: Device, block: u32, seq: u64, kind: Kind, payload: []const u8, timestamp: u64) Error!u32 {
    const blocks = recordBlocks(payload.len);
    var header_block = [_]u8{0} ** block_size;
    encodeRecordHeader(.{
        .kind = kind,
        .seq = seq,
        .payload_len = @intCast(payload.len),
        .total_blocks = blocks,
        .record_crc = crc32c(payload),
        .timestamp = timestamp,
    }, header_block[0..record_header_size]);
    try device.write(block, &header_block);
    var offset: usize = 0;
    while (offset < payload.len) {
        var data_block = [_]u8{0} ** block_size;
        const n = @min(block_size, payload.len - offset);
        @memcpy(data_block[0..n], payload[offset..][0..n]);
        try device.write(block + 1 + @as(u32, @intCast(offset / block_size)), &data_block);
        offset += n;
    }
    return blocks;
}

fn writeRecordChecked(device: Device, block: u32, reserved: u32, seq: u64, kind: Kind, payload: []const u8, timestamp: u64) Error!u32 {
    const need = recordBlocks(payload.len);
    if (block > device.blocks or need > device.blocks or block > device.blocks - need) return error.NoSpace;
    if (device.blocks - block - need < reserved) return error.NoSpace;
    return writeRecord(device, block, seq, kind, payload, timestamp);
}

fn checkFixture(fixture: Fixture) Error!void {
    if (fixture.nodes.len == 0 or fixture.nodes.len > max_nodes) return error.BadFixture;
    const root = fixture.nodes[0];
    if (root.ino != 1 or root.parent != 0 or root.kind != .inode or root.name.len != 0) return error.BadFixture;
    var i: usize = 0;
    while (i < fixture.nodes.len) : (i += 1) {
        const node = fixture.nodes[i];
        if (node.name.len > max_name) return error.NameTooLong;
        if (node.kind == .inode) {
            if (node.data.len != 0) return error.BadFixture;
        } else if (node.kind == .data) {
            if (node.data.len > max_file_bytes) return error.FileTooLarge;
            if (i == 0) return error.BadFixture;
        } else {
            return error.BadFixture;
        }
        if (i != 0) {
            if (node.ino <= 1 or node.name.len == 0) return error.BadFixture;
            var p: usize = 0;
            var parent_ok = false;
            while (p < i) : (p += 1) {
                if (fixture.nodes[p].ino == node.parent and fixture.nodes[p].kind == .inode) parent_ok = true;
            }
            if (!parent_ok) return error.BadTree;
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (fixture.nodes[j].ino == node.ino) return error.DuplicateInode;
                if (fixture.nodes[j].parent == node.parent and nameEql(fixture.nodes[j].name, node.name)) return error.BadFixture;
            }
        }
    }
}

/// Format-owned write buffers. A block transport is allowed to retain the
/// caller's buffer until its request is retired; keeping these in module
/// storage means a late retirement can never see a reused stack frame.
var format_superblock_raw: [superblock_size]u8 = undefined;
var format_superblock_block: [block_size]u8 = undefined;

pub fn format(device: Device, fixture: Fixture, workspace: []u8) Error!FormatStats {
    if (device.blocks < 8 or device.blocks > max_volume_blocks) return error.NoSpace;
    if (workspace.len < workspaceRequired(device.blocks)) return error.BufferTooSmall;
    try checkFixture(fixture);

    const free_payload_len = freeMapPayloadLen(device.blocks);
    const free_map_blocks = recordBlocks(free_payload_len);
    const reserve: u32 = free_map_blocks + 2; // free map + checkpoint
    var next: u32 = 2;
    var seq: u64 = 0;
    var records: u32 = 0;
    var stats = FormatStats{};

    // Root and every directory/file in fixture order. File data is written
    // before its inode so the extent can point directly at the payload blocks.
    var node_index: usize = 0;
    while (node_index < fixture.nodes.len) : (node_index += 1) {
        const node = fixture.nodes[node_index];
        var extents: [max_extents]Extent = [_]Extent{.{}} ** max_extents;
        var extent_count: usize = 0;
        var data_crc: u32 = 0;
        if (node.kind == .data) {
            data_crc = crc32c(node.data);
            var data_offset: usize = 0;
            while (data_offset < node.data.len) {
                if (extent_count == max_extents) return error.FileTooLarge;
                const chunk_len = @min(max_record_payload, node.data.len - data_offset);
                const chunk = node.data[data_offset..][0..chunk_len];
                seq += 1;
                records += 1;
                if (records > max_records) return error.TooManyRecords;
                const placed = next;
                const blocks = try writeRecordChecked(device, next, reserve, seq, .data, chunk, fixture.created_sec);
                extents[extent_count] = .{
                    .logical_offset = data_offset,
                    .physical_block = placed + 1,
                    .physical_offset = 0,
                    .length = @intCast(chunk_len),
                };
                extent_count += 1;
                next += blocks;
                data_offset += chunk_len;
            }
        }

        var inode = Inode{
            .ino = node.ino,
            .parent = node.parent,
            .kind = node.kind,
            .name_len = @intCast(node.name.len),
            .size = if (node.kind == .data) node.data.len else 0,
            .mode = if (node.kind == .inode) 0o040755 else 0o100644,
            .mtime = fixture.created_sec,
            .data_crc = data_crc,
            .extent_count = @intCast(extent_count),
            .extents = extents,
        };
        copyName(&inode.name, node.name);
        var payload: [inode_payload_size]u8 = undefined;
        encodeInode(&inode, &payload);
        seq += 1;
        records += 1;
        if (records > max_records) return error.TooManyRecords;
        next += try writeRecordChecked(device, next, reserve, seq, .inode, &payload, fixture.created_sec);
        if (node.kind == .inode) {
            stats.dirs += 1;
        } else {
            stats.files += 1;
            stats.data_bytes += node.data.len;
        }
    }

    const final_head = next + reserve;
    if (final_head > device.blocks) return error.NoSpace;
    const used_blocks = final_head;
    const free_blocks = device.blocks - used_blocks;
    const free_map_seq = seq + 1;
    const free_map_block = next;

    // The bitmap is the free-space map: every block in the append-only log is
    // used, every block after the head is free. Setting the free-map record's
    // own bits is part of the same accounting.
    const bitmap = workspace[0..free_payload_len];
    @memset(bitmap, 0);
    writeU32(bitmap, 0, device.blocks);
    writeU32(bitmap, 4, used_blocks);
    var b: u32 = 0;
    while (b < used_blocks) : (b += 1) {
        bitmap[8 + b / 8] |= @as(u8, 1) << @intCast(b % 8);
    }
    seq = free_map_seq;
    records += 1;
    if (records > max_records) return error.TooManyRecords;
    next += try writeRecord(device, free_map_block, seq, .free_map, bitmap, fixture.created_sec);
    if (next != free_map_block + free_map_blocks) return error.BadRecord;

    const checkpoint_block = next;
    const checkpoint_seq = seq + 1;
    records += 1;
    if (records > max_records) return error.TooManyRecords;
    var label_raw: [32]u8 = [_]u8{0} ** 32;
    copyName(&label_raw, fixture.label);
    var checkpoint = Checkpoint{
        .root_ino = 1,
        .next_ino = 0,
        .inode_count = @intCast(fixture.nodes.len),
        .dir_count = stats.dirs,
        .file_count = stats.files,
        .record_count = records,
        .log_head = used_blocks,
        .total_blocks = device.blocks,
        .used_blocks = used_blocks,
        .free_blocks = free_blocks,
        .free_map_block = free_map_block,
        .free_map_seq = free_map_seq,
        .data_bytes = stats.data_bytes,
        .uuid = fixture.uuid,
        .label = label_raw,
    };
    for (fixture.nodes) |node| {
        if (node.ino >= checkpoint.next_ino) checkpoint.next_ino = node.ino + 1;
    }
    var checkpoint_payload: [checkpoint_payload_size]u8 = undefined;
    encodeCheckpoint(&checkpoint, &checkpoint_payload);
    seq = checkpoint_seq;
    next += try writeRecordChecked(device, checkpoint_block, 0, seq, .checkpoint, &checkpoint_payload, fixture.created_sec);
    if (next != used_blocks) return error.BadRecord;

    const checkpoint_header = RecordHeader{
        .kind = .checkpoint,
        .seq = checkpoint_seq,
        .payload_len = checkpoint_payload_size,
        .total_blocks = 2,
        .record_crc = crc32c(&checkpoint_payload),
        .timestamp = fixture.created_sec,
    };
    var sb = Superblock{
        // Spell the magic out here as well as in the field default. A format
        // must never depend on an optimised default copy for the one value
        // that decides whether the volume is mountable at all.
        .magic = superblock_magic,
        .total_blocks = device.blocks,
        .generation = 1,
        .checkpoint_block = checkpoint_block,
        .checkpoint_seq = checkpoint_seq,
        .checkpoint_crc = checkpoint_header.record_crc,
        .root_ino = 1,
        .log_head = used_blocks,
        .free_blocks = free_blocks,
        .inode_count = @intCast(fixture.nodes.len),
        .created_sec = fixture.created_sec,
        .uuid = fixture.uuid,
        .label = label_raw,
    };
    encodeSuperblock(sb, &format_superblock_raw);
    @memset(&format_superblock_block, 0);
    @memcpy(format_superblock_block[0..superblock_size], &format_superblock_raw);
    try device.write(0, &format_superblock_block);
    sb.generation = 2;
    encodeSuperblock(sb, &format_superblock_raw);
    @memset(&format_superblock_block, 0);
    @memcpy(format_superblock_block[0..superblock_size], &format_superblock_raw);
    try device.write(1, &format_superblock_block);
    try device.flush();

    // Read the two superblocks back and decode them before declaring success.
    // The on-disk image is the contract; returning stats without this check
    // would let a bad first sector look like a successful format.
    var verify_block: [block_size]u8 = undefined;
    try device.read(0, &verify_block);
    _ = try decodeSuperblock(verify_block[0..superblock_size]);
    try device.read(1, &verify_block);
    _ = try decodeSuperblock(verify_block[0..superblock_size]);

    stats.log_head = used_blocks;
    stats.used_blocks = used_blocks;
    stats.free_blocks = free_blocks;
    stats.records = records;
    stats.inode_count = @intCast(fixture.nodes.len);
    stats.a_generation = 1;
    stats.b_generation = 2;
    return stats;
}

// ---------------------------------------------------------------------------
// Scanning and verification
// ---------------------------------------------------------------------------

fn readPayload(device: Device, block: u32, header: RecordHeader, out: []u8) Error!void {
    if (out.len < header.payload_len) return error.BufferTooSmall;
    var copied: usize = 0;
    var b = block + 1;
    while (copied < header.payload_len) {
        var data_block: [block_size]u8 = undefined;
        try device.read(b, &data_block);
        const n = @min(block_size, header.payload_len - copied);
        @memcpy(out[copied..][0..n], data_block[0..n]);
        copied += n;
        b += 1;
    }
    if (crc32c(out[0..header.payload_len]) != header.record_crc) return error.BadCrc;
}

fn dataRange(info: *const RecordInfo, block: u32, offset: u16, length: u32) bool {
    if (info.kind != .data) return false;
    const payload_start = info.block + 1;
    const payload_blocks = info.payload_len / @as(u32, @intCast(block_size)) + @as(u32, if (info.payload_len % @as(u32, @intCast(block_size)) != 0) 1 else 0);
    if (block < payload_start or block >= payload_start + payload_blocks) return false;
    const within = (block - payload_start) * @as(u32, @intCast(block_size)) + offset;
    return within <= info.payload_len and length <= info.payload_len - within;
}

fn extentInData(records: []const RecordInfo, extent: Extent) bool {
    if (extent.length == 0 or extent.physical_offset >= block_size) return false;
    for (records) |*info| {
        if (dataRange(info, extent.physical_block, extent.physical_offset, extent.length)) return true;
    }
    return false;
}

fn findInode(inodes: []const Inode, ino: u64) ?usize {
    var i: usize = 0;
    while (i < inodes.len) : (i += 1) {
        if (inodes[i].ino == ino) return i;
    }
    return null;
}

/// Read a byte range of one inode through its extents. This is the phase-42
/// VFS read primitive: it never reads the whole file and never returns bytes
/// outside the requested range. An offset at or past EOF returns 0; the caller
/// sees a short read only when the request crosses EOF.
pub fn readInodeRange(device: Device, report: *const Report, ino: u64, offset: u64, out: []u8) Error!usize {
    if (out.len == 0) return 0;
    const idx = findInode(report.inodes, ino) orelse return error.PathNotFound;
    const inode = &report.inodes[idx];
    if (inode.kind != .data) return error.BadInode;
    if (offset >= inode.size) return 0;
    const want: usize = @intCast(@min(@as(u64, out.len), inode.size - offset));
    var copied: usize = 0;
    var e: usize = 0;
    while (e < inode.extent_count and copied < want) : (e += 1) {
        const extent = inode.extents[e];
        const start = extent.logical_offset;
        const end = start + extent.length;
        const request_end = offset + want;
        if (request_end <= start or offset >= end) continue;
        const first = @max(offset, start);
        const last = @min(request_end, end);
        const n: usize = @intCast(last - first);
        try readExtentRange(device, extent, first - start, out[copied..][0..n]);
        copied += n;
    }
    if (copied != want) return error.BadExtent;
    return copied;
}

fn readExtentRange(device: Device, extent: Extent, within: u64, out: []u8) Error!void {
    const absolute = @as(u64, extent.physical_offset) + within;
    var block = extent.physical_block + @as(u32, @intCast(absolute / block_size));
    var offset: usize = @intCast(absolute % block_size);
    var copied: usize = 0;
    while (copied < out.len) {
        var data_block: [block_size]u8 = undefined;
        try device.read(block, &data_block);
        const n = @min(out.len - copied, block_size - offset);
        @memcpy(out[copied..][0..n], data_block[offset..][0..n]);
        copied += n;
        block += 1;
        offset = 0;
    }
}

pub fn readFile(device: Device, report: *const Report, path: []const u8, out: []u8) Error!usize {
    var current: ?usize = null;
    if (path.len == 0 or nameEql(path, "/")) {
        current = findInode(report.inodes, report.root_ino);
    } else {
        var rest = path;
        if (rest[0] == '/') rest = rest[1..];
        var dir = findInode(report.inodes, report.root_ino) orelse return error.PathNotFound;
        while (rest.len != 0) {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const part = rest[0..slash];
            var found: ?usize = null;
            var i: usize = 0;
            while (i < report.inodes.len) : (i += 1) {
                if (report.inodes[i].parent == report.inodes[dir].ino and nameEql(report.inodes[i].nameSlice(), part)) {
                    found = i;
                    break;
                }
            }
            const next = found orelse return error.PathNotFound;
            if (slash == rest.len) {
                current = next;
                rest = rest[rest.len..];
            } else {
                if (report.inodes[next].kind != .inode) return error.PathNotFound;
                dir = next;
                rest = rest[slash + 1 ..];
            }
        }
    }
    const idx = current orelse return error.PathNotFound;
    const inode = &report.inodes[idx];
    if (inode.kind != .data) return error.PathNotFound;
    if (inode.size > out.len) return error.BufferTooSmall;
    var written: usize = 0;
    var e: usize = 0;
    while (e < inode.extent_count) : (e += 1) {
        const extent = inode.extents[e];
        var left: usize = extent.length;
        var block = extent.physical_block;
        var offset: usize = extent.physical_offset;
        while (left > 0) {
            var data_block: [block_size]u8 = undefined;
            try device.read(block, &data_block);
            const n = @min(left, block_size - offset);
            @memcpy(out[written..][0..n], data_block[offset..][0..n]);
            written += n;
            left -= n;
            offset = 0;
            block += 1;
        }
    }
    if (written != inode.size) return error.BadExtent;
    return written;
}

/// Read and verify the whole volume. `inode_storage` is filled with every inode
/// in log order; `workspace` must hold the free-map payload (or one maximum
/// record payload, whichever is larger). The report's slices point into both
/// caller buffers and remain valid until they are reused.
pub fn scan(device: Device, workspace: []u8, inode_storage: []Inode) Error!Report {
    if (device.blocks < 8 or device.blocks > max_volume_blocks) return error.NoSpace;
    if (workspace.len < workspaceRequired(device.blocks)) return error.BufferTooSmall;
    if (inode_storage.len < 1) return error.TooManyNodes;

    var sb_block = [_]u8{0} ** block_size;
    try device.read(0, &sb_block);
    const a: ?Superblock = decodeSuperblock(sb_block[0..superblock_size]) catch null;
    try device.read(1, &sb_block);
    const b: ?Superblock = decodeSuperblock(sb_block[0..superblock_size]) catch null;
    if (a == null and b == null) return error.BadSuperblock;

    var report = Report{};
    report.total_blocks = device.blocks;
    if (a) |sb| {
        report.a = superStatus(sb);
    }
    if (b) |sb| {
        report.b = superStatus(sb);
    }
    var chosen: Superblock = undefined;
    var active: Slot = .b;
    if (a != null and b != null) {
        if (a.?.generation > b.?.generation) {
            chosen = a.?;
            active = .a;
        } else {
            chosen = b.?;
            active = .b;
        }
        report.fallback = false;
    } else if (a) |sb| {
        chosen = sb;
        active = .a;
        report.fallback = true;
    } else {
        chosen = b.?;
        active = .b;
        report.fallback = true;
    }
    report.active = active;
    report.format_version = chosen.version;
    report.block_size = chosen.block_size;
    report.total_blocks = chosen.total_blocks;
    report.root_ino = chosen.root_ino;
    report.log_head = chosen.log_head;
    report.free_blocks = chosen.free_blocks;
    report.uuid = chosen.uuid;
    report.label = chosen.label;
    if (chosen.total_blocks != device.blocks) return error.BadSuperblock;
    if (chosen.log_head < 2 or chosen.log_head > chosen.total_blocks) return error.BadSuperblock;
    if (chosen.checkpoint_block < 2 or chosen.checkpoint_block >= chosen.log_head) return error.BadSuperblock;

    var header_block = [_]u8{0} ** block_size;
    try device.read(chosen.checkpoint_block, &header_block);
    const checkpoint_header = decodeRecordHeader(header_block[0..record_header_size]) catch return error.BadCheckpoint;
    if (checkpoint_header.kind != .checkpoint or checkpoint_header.seq != chosen.checkpoint_seq) return error.BadCheckpoint;
    if (checkpoint_header.record_crc != chosen.checkpoint_crc) return error.BadCheckpoint;
    var checkpoint_payload: [checkpoint_payload_size]u8 = undefined;
    try readPayload(device, chosen.checkpoint_block, checkpoint_header, &checkpoint_payload);
    const checkpoint = decodeCheckpoint(&checkpoint_payload) catch return error.BadCheckpoint;
    report.checkpoint = checkpoint;
    if (checkpoint.root_ino != chosen.root_ino) return error.BadCheckpoint;
    if (checkpoint.log_head != chosen.log_head) return error.BadCheckpoint;
    if (checkpoint.free_blocks != chosen.free_blocks) return error.BadCheckpoint;
    if (checkpoint.total_blocks != chosen.total_blocks) return error.BadCheckpoint;
    if (checkpoint.inode_count != chosen.inode_count) return error.CountMismatch;

    var block: u32 = 2;
    var expected_seq: u64 = 1;
    var last_kind: ?Kind = null;
    var last_seq: u64 = 0;
    var free_map_seen = false;
    var checkpoint_seen = false;
    var record_count: u32 = 0;
    var dirs: u32 = 0;
    var files: u32 = 0;
    var inode_count: u32 = 0;
    var data_bytes: u64 = 0;
    var free_map_seq: u64 = 0;
    var free_map_block: u32 = 0;
    while (block < chosen.log_head) {
        try device.read(block, &header_block);
        const header = decodeRecordHeader(header_block[0..record_header_size]) catch return error.BadRecord;
        if (header.seq != expected_seq) return error.BadSequence;
        const total = header.total_blocks;
        if (total == 0 or block + total > chosen.log_head) return error.BadRecord;
        if (header.payload_len > workspace.len) return error.BufferTooSmall;
        try readPayload(device, block, header, workspace[0..header.payload_len]);
        if (record_count >= max_records) return error.TooManyRecords;
        report.record_infos[record_count] = .{
            .seq = header.seq,
            .kind = header.kind,
            .block = block,
            .blocks = total,
            .payload_len = header.payload_len,
        };
        record_count += 1;
        if (record_count == 1) report.first_seq = header.seq;
        last_seq = header.seq;
        last_kind = header.kind;
        expected_seq += 1;
        switch (header.kind) {
            .inode => {
                if (header.payload_len != inode_payload_size) return error.BadInode;
                if (inode_count >= inode_storage.len or inode_count >= max_nodes) return error.TooManyNodes;
                const inode = decodeInode(workspace[0..inode_payload_size]) catch return error.BadInode;
                var i: usize = 0;
                while (i < inode_count) : (i += 1) {
                    if (inode_storage[i].ino == inode.ino) return error.DuplicateInode;
                }
                inode_storage[inode_count] = inode;
                inode_count += 1;
                if (inode.kind == .inode) {
                    dirs += 1;
                } else {
                    files += 1;
                    data_bytes += inode.size;
                }
            },
            .data => {},
            .free_map => {
                if (free_map_seen) return error.BadFreeMap;
                free_map_seen = true;
                free_map_seq = header.seq;
                free_map_block = block;
                if (header.payload_len != freeMapPayloadLen(chosen.total_blocks)) return error.BadFreeMap;
                const map = workspace[0..header.payload_len];
                if (readU32(map, 0) != chosen.total_blocks) return error.BadFreeMap;
                if (readU32(map, 4) != chosen.log_head) return error.BadFreeMap;
                var i: u32 = 0;
                while (i < chosen.total_blocks) : (i += 1) {
                    const set = (map[8 + i / 8] & (@as(u8, 1) << @intCast(i % 8))) != 0;
                    const expected = i < chosen.log_head;
                    if (set != expected) return error.BadFreeMap;
                }
            },
            .checkpoint => {
                if (checkpoint_seen or block != chosen.checkpoint_block) return error.BadCheckpoint;
                checkpoint_seen = true;
            },
        }
        block += total;
    }
    if (block != chosen.log_head) return error.BadRecord;
    if (!checkpoint_seen or last_kind != .checkpoint or last_seq != chosen.checkpoint_seq) return error.BadCheckpoint;
    if (!free_map_seen or free_map_seq != checkpoint.free_map_seq or free_map_block != checkpoint.free_map_block) return error.BadFreeMap;
    if (inode_count != checkpoint.inode_count) return error.CountMismatch;
    if (dirs != checkpoint.dir_count or files != checkpoint.file_count) return error.CountMismatch;
    if (data_bytes != checkpoint.data_bytes) return error.CountMismatch;
    if (record_count != checkpoint.record_count) return error.CountMismatch;
    if (free_map_seq >= chosen.checkpoint_seq) return error.BadFreeMap;

    report.inodes = inode_storage[0..inode_count];
    report.inode_count = inode_count;
    report.record_info_count = record_count;
    report.used_blocks = chosen.log_head;
    report.dirs = dirs;
    report.files = files;
    report.data_bytes = data_bytes;
    report.records = record_count;
    report.last_seq = last_seq;
    report.next_ino = checkpoint.next_ino;
    report.free_map_block = free_map_block;
    report.free_map_seq = free_map_seq;

    const root_index = findInode(report.inodes, checkpoint.root_ino) orelse return error.BadTree;
    if (report.inodes[root_index].parent != 0 or report.inodes[root_index].kind != .inode) return error.BadTree;
    var i: usize = 0;
    while (i < report.inodes.len) : (i += 1) {
        const inode = &report.inodes[i];
        if (inode.ino >= checkpoint.next_ino) return error.BadTree;
        if ((inode.ino == checkpoint.root_ino) != (inode.parent == 0)) return error.BadTree;
        if (inode.parent != 0) {
            const parent_index = findInode(report.inodes, inode.parent) orelse return error.BadTree;
            if (report.inodes[parent_index].kind != .inode) return error.BadTree;
            if (inode.name_len == 0) return error.BadTree;
            var j: usize = 0;
            while (j < report.inodes.len) : (j += 1) {
                if (j == i) continue;
                if (report.inodes[j].parent == inode.parent and nameEql(report.inodes[j].nameSlice(), inode.nameSlice())) return error.BadTree;
            }
        }
        var depth: u32 = 0;
        var walk = inode;
        while (walk.parent != 0) {
            const parent_index = findInode(report.inodes, walk.parent) orelse return error.BadTree;
            walk = &report.inodes[parent_index];
            depth += 1;
            if (depth > report.inodes.len) return error.BadTree;
        }
        if (walk.ino != checkpoint.root_ino) return error.BadTree;
        if (inode.kind == .data) {
            var logical: u64 = 0;
            var e: usize = 0;
            var crc_state: u32 = 0xffff_ffff;
            while (e < inode.extent_count) : (e += 1) {
                const extent = inode.extents[e];
                if (extent.logical_offset != logical) return error.BadExtent;
                if (!extentInData(report.record_infos[0..report.record_info_count], extent)) return error.BadExtent;
                var left: u32 = extent.length;
                var physical = extent.physical_block;
                var off: usize = extent.physical_offset;
                while (left > 0) {
                    var data_block: [block_size]u8 = undefined;
                    try device.read(physical, &data_block);
                    const n: usize = @min(left, block_size - off);
                    crc_state = crc32cUpdate(crc_state, data_block[off..][0..n]);
                    left -= @intCast(n);
                    off = 0;
                    physical += 1;
                }
                logical += extent.length;
            }
            if (logical != inode.size) return error.BadExtent;
            if (~crc_state != inode.data_crc) return error.BadCrc;
        } else if (inode.size != 0 or inode.extent_count != 0 or inode.data_crc != 0) {
            return error.BadInode;
        }
    }
    return report;
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

const TestDisk = struct {
    blocks: []u8,
    reads: usize = 0,
    writes: usize = 0,
    flush_count: usize = 0,
    read_error: bool = false,

    fn read(ctx: *anyopaque, block: u32, buf: *[block_size]u8) Error!void {
        const self: *TestDisk = @ptrCast(@alignCast(ctx));
        if (self.read_error) return error.Io;
        const off = @as(usize, block) * block_size;
        if (off + block_size > self.blocks.len) return error.OutOfRange;
        @memcpy(buf, self.blocks[off..][0..block_size]);
        self.reads += 1;
    }

    fn write(ctx: *anyopaque, block: u32, buf: *const [block_size]u8) Error!void {
        const self: *TestDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, block) * block_size;
        if (off + block_size > self.blocks.len) return error.OutOfRange;
        @memcpy(self.blocks[off..][0..block_size], buf);
        self.writes += 1;
    }

    fn flush(ctx: *anyopaque) Error!void {
        const self: *TestDisk = @ptrCast(@alignCast(ctx));
        self.flush_count += 1;
    }

    fn device(self: *TestDisk, blocks: u32) Device {
        return .{
            .ctx = self,
            .blocks = blocks,
            .read_fn = TestDisk.read,
            .write_fn = TestDisk.write,
            .flush_fn = TestDisk.flush,
        };
    }
};

const test_root = Node{ .ino = 1, .parent = 0, .kind = .inode, .name = "" };
const test_catalog = Node{ .ino = 2, .parent = 1, .kind = .inode, .name = "catalog" };
const test_file = Node{ .ino = 3, .parent = 2, .kind = .data, .name = "products.db", .data = "sku,price\n1001,250\n1002,180\n" };
const test_nodes = [_]Node{ test_root, test_catalog, test_file };

fn testDisk(blocks: u32, storage: *[64 * 1024]u8) TestDisk {
    return .{ .blocks = storage[0 .. @as(usize, blocks) * block_size] };
}

test "crc32c matches the Castagnoli reference vector" {
    try std.testing.expectEqual(@as(u32, 0xe306_9283), crc32c("123456789"));
    try std.testing.expectEqual(@as(u32, 0), crc32c(""));
    const first = crc32cUpdate(0xffff_ffff, "1234");
    try std.testing.expectEqual(crc32c("123456789"), ~crc32cUpdate(first, "56789"));
}

test "superblock round trip and version/checksum refusal" {
    var raw: [superblock_size]u8 = undefined;
    const sb = Superblock{
        .total_blocks = 128,
        .generation = 7,
        .checkpoint_block = 16,
        .checkpoint_seq = 20,
        .checkpoint_crc = 0x1234_5678,
        .log_head = 24,
        .free_blocks = 104,
        .inode_count = 5,
        .created_sec = 42,
        .label = [_]u8{'t'} ++ [_]u8{0} ** 31,
    };
    encodeSuperblock(sb, &raw);
    const decoded = try decodeSuperblock(&raw);
    try std.testing.expectEqual(@as(u64, 7), decoded.generation);
    try std.testing.expectEqual(@as(u32, 128), decoded.total_blocks);
    try std.testing.expectEqual(@as(u32, 104), decoded.free_blocks);
    raw[24] ^= 1;
    try std.testing.expectError(error.BadCrc, decodeSuperblock(&raw));
    encodeSuperblock(sb, &raw);
    raw[4] = 99;
    try std.testing.expectError(error.Unsupported, decodeSuperblock(&raw));
}

test "record header round trip and CRC coverage" {
    var raw = [_]u8{0} ** record_header_size;
    const h = RecordHeader{ .kind = .data, .seq = 9, .payload_len = 20, .total_blocks = 2, .record_crc = 0xabcd, .timestamp = 77 };
    encodeRecordHeader(h, &raw);
    const decoded = try decodeRecordHeader(&raw);
    try std.testing.expectEqual(h, decoded);
    raw[8] ^= 1;
    try std.testing.expectError(error.BadCrc, decodeRecordHeader(&raw));
}

test "inode codec preserves names, sizes, extents and CRC" {
    var inode = Inode{
        .ino = 3,
        .parent = 2,
        .kind = .data,
        .name_len = 8,
        .size = 120,
        .data_crc = 0x5555_5555,
        .mtime = 12,
        .extent_count = 2,
    };
    copyName(&inode.name, "products");
    inode.extents[0] = .{ .logical_offset = 0, .physical_block = 40, .physical_offset = 0, .length = 64 };
    inode.extents[1] = .{ .logical_offset = 64, .physical_block = 41, .physical_offset = 8, .length = 56 };
    var raw: [inode_payload_size]u8 = undefined;
    encodeInode(&inode, &raw);
    const decoded = try decodeInode(&raw);
    try std.testing.expectEqual(@as(u64, 3), decoded.ino);
    try std.testing.expectEqual(@as(u64, 120), decoded.size);
    try std.testing.expectEqual(@as(u8, 2), decoded.extent_count);
    try std.testing.expect(nameEql(decoded.nameSlice(), "products"));
    try std.testing.expectEqual(@as(u32, 64), decoded.extents[0].length);
    try std.testing.expectEqual(@as(u16, 8), decoded.extents[1].physical_offset);
}

test "format writes a demo tree, free map, checkpoint and both superblocks" {
    var storage: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var disk = testDisk(16, &storage);
    var workspace: [workspaceRequired(16)]u8 = undefined;
    var inodes: [max_nodes]Inode = undefined;
    const stats = try format(disk.device(16), .{ .nodes = &test_nodes, .label = "Cassa Test", .uuid = [_]u8{1} ** 16 }, &workspace);
    try std.testing.expectEqual(@as(u32, 2), stats.dirs);
    try std.testing.expectEqual(@as(u32, 1), stats.files);
    try std.testing.expect(stats.log_head > 2);
    try std.testing.expectEqual(@as(u32, 16 - stats.log_head), stats.free_blocks);
    const report = try scan(disk.device(16), &workspace, &inodes);
    try std.testing.expect(report.a.valid and report.b.valid);
    try std.testing.expectEqual(Slot.b, report.active);
    try std.testing.expectEqual(@as(u64, 2), report.b.generation);
    try std.testing.expectEqual(@as(u32, 2), report.dirs);
    try std.testing.expectEqual(@as(u32, 1), report.files);
    try std.testing.expectEqual(@as(u64, test_file.data.len), report.data_bytes);
    try std.testing.expectEqual(@as(u32, 16 - stats.log_head), report.free_blocks);
    try std.testing.expectEqual(@as(u32, 6), report.records);
    try std.testing.expectEqual(@as(u64, 1), report.first_seq);
    try std.testing.expectEqual(@as(u64, 6), report.last_seq);
    var out: [64]u8 = undefined;
    const n = try readFile(disk.device(16), &report, "/catalog/products.db", &out);
    try std.testing.expectEqualStrings("sku,price\n1001,250\n1002,180\n", out[0..n]);
}

test "a damaged B superblock falls back to A and still verifies" {
    var storage: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var disk = testDisk(16, &storage);
    var workspace: [workspaceRequired(16)]u8 = undefined;
    var inodes: [max_nodes]Inode = undefined;
    _ = try format(disk.device(16), .{ .nodes = &test_nodes }, &workspace);
    disk.blocks[block_size + 100] ^= 0x40;
    const report = try scan(disk.device(16), &workspace, &inodes);
    try std.testing.expect(report.fallback);
    try std.testing.expect(!report.b.valid);
    try std.testing.expect(report.a.valid);
    try std.testing.expectEqual(Slot.a, report.active);
}

test "a corrupted payload is rejected by CRC32C" {
    var storage: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var disk = testDisk(16, &storage);
    var workspace: [workspaceRequired(16)]u8 = undefined;
    var inodes: [max_nodes]Inode = undefined;
    const stats = try format(disk.device(16), .{ .nodes = &test_nodes }, &workspace);
    _ = stats;
    // Block 7 is the data record's payload (the file is the third node). A
    // payload flip must be caught by the record CRC, not by the header CRC.
    disk.blocks[7 * block_size + 5] ^= 0x01;
    try std.testing.expectError(error.BadCrc, scan(disk.device(16), &workspace, &inodes));
}

test "a damaged free-map bit is rejected" {
    var storage: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var disk = testDisk(16, &storage);
    var workspace: [workspaceRequired(16)]u8 = undefined;
    var inodes: [max_nodes]Inode = undefined;
    _ = try format(disk.device(16), .{ .nodes = &test_nodes }, &workspace);
    // The free-map record is the last-but-one record. Flip a byte in its bitmap
    // through a second scan's record table rather than assuming a block index.
    var report = try scan(disk.device(16), &workspace, &inodes);
    var map_block: u32 = 0;
    var i: usize = 0;
    while (i < report.record_info_count) : (i += 1) {
        if (report.record_infos[i].kind == .free_map) map_block = report.record_infos[i].block;
    }
    try std.testing.expect(map_block != 0);
    disk.blocks[@as(usize, map_block + 1) * block_size + 9] ^= 0x02;
    try std.testing.expectError(error.BadCrc, scan(disk.device(16), &workspace, &inodes));
    _ = &report;
}

test "an oversized or malformed fixture is refused before writing" {
    var storage: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var disk = testDisk(16, &storage);
    var workspace: [workspaceRequired(16)]u8 = undefined;
    const bad_root = [_]Node{.{ .ino = 1, .parent = 1, .kind = .inode, .name = "" }};
    try std.testing.expectError(error.BadFixture, format(disk.device(16), .{ .nodes = &bad_root }, &workspace));
    const bad_name = [_]Node{ test_root, .{ .ino = 2, .parent = 1, .kind = .data, .name = "012345678901234567890123456789012" } };
    try std.testing.expectError(error.NameTooLong, format(disk.device(16), .{ .nodes = &bad_name }, &workspace));
    const bad_parent = [_]Node{ test_root, .{ .ino = 2, .parent = 9, .kind = .data, .name = "x" } };
    try std.testing.expectError(error.BadTree, format(disk.device(16), .{ .nodes = &bad_parent }, &workspace));
}

test "a path lookup and readFile refuse missing files and directories" {
    var storage: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024);
    var disk = testDisk(16, &storage);
    var workspace: [workspaceRequired(16)]u8 = undefined;
    var inodes: [max_nodes]Inode = undefined;
    _ = try format(disk.device(16), .{ .nodes = &test_nodes }, &workspace);
    const report = try scan(disk.device(16), &workspace, &inodes);
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.PathNotFound, readFile(disk.device(16), &report, "/missing", &out));
    try std.testing.expectError(error.PathNotFound, readFile(disk.device(16), &report, "/catalog", &out));
    try std.testing.expectError(error.BufferTooSmall, readFile(disk.device(16), &report, "/catalog/products.db", out[0..4]));
}

test "an unknown incompatible superblock feature is refused" {
    var raw: [superblock_size]u8 = undefined;
    var sb = Superblock{ .total_blocks = 32, .log_head = 8, .free_blocks = 24, .checkpoint_block = 6, .checkpoint_seq = 4, .inode_count = 1 };
    encodeSuperblock(sb, &raw);
    sb.incompat = 2;
    encodeSuperblock(sb, &raw);
    try std.testing.expectError(error.Unsupported, decodeSuperblock(&raw));
}
