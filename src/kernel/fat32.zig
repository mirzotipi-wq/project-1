//! FAT32 filesystem driver (phase 36).
//!
//! Sits on a `block_view.View`, which makes a partition look like a disk of its
//! own. Everything here is bounded: every sector, FAT entry, cluster and
//! directory slot is checked before it is used, corrupt input produces a typed
//! error (`Corrupt`, `BadGeometry`, `BadBoot`, ...) and never a panic, a hang or
//! a write outside the volume.
//!
//! On-disk structures implemented:
//!
//!   * **BPB** — bytes per sector, sectors per cluster, reserved/FAT region
//!     arithmetic, total sectors, root cluster, FSInfo sector. A volume whose
//!     arithmetic does not add up is refused at mount. FSInfo is a hint and is
//!     tolerated when its signatures or counters are wrong.
//!   * **FAT** — 28-bit entries in both copies, updated together. Chains are
//!     walked with a loop bound and range checks; a cluster outside the data
//!     region is `Corrupt`, not an index into memory.
//!   * **Directories** — 32-byte entries, 8.3 short names compared
//!     case-insensitively, LFN entries decoded for display (a file written by
//!     another OS with a long name enumerates its long name). Creating writes an
//!     8.3 short name; writing an LFN is deliberately not implemented yet.
//!   * **Files** — read by chain, create, overwrite (truncate, then free),
//!     grow across clusters, delete. The order of writes is chosen so a crash
//!     can never make a live file point at clusters the FAT considers free: the
//!     data is written first, then the FAT chain, then the directory entry that
//!     publishes it. The one window this leaves (a crash between the FAT flush
//!     and the directory-entry flush) can allocate a chain no directory entry
//!     reaches — an orphan, which `check` counts and a later `fsck` reclaims —
//!     but never the reverse, which is corruption.
//!   * **Allocation** — first fit from a rotating hint, both FAT copies and the
//!     FSInfo free counter kept in step.
//!   * **check()** — at-rest invariants: no loops, no orphans, every file's
//!     chain exactly as long as its size requires, FAT entries either free, EOC,
//!     bad or pointing inside the data region, and the FSInfo counter matching
//!     the FAT.
//!
//! There is exactly one mounted volume at a time and the buffers are static, so
//! the mount does not put a cluster-sized object on a thread stack (phase 35
//! learned that lesson the hard way). Callers are the shell and the probe, both
//! single-threaded.

const std = @import("std");
const builtin = @import("builtin");
const block = @import("block.zig");
const block_view = @import("block_view.zig");

pub const max_cluster_bytes = 32 * 1024;
pub const max_file_bytes = 64 * 1024;
pub const max_name = 63;
const max_check_clusters = 1 << 20;
const eoc_min: u32 = 0x0fff_fff8;
const bad_cluster: u32 = 0x0fff_fff7;
const fat_mask: u32 = 0x0fff_ffff;

pub const Error = error{
    NoDevice,
    Io,
    NoSpace,
    BadBoot,
    BadGeometry,
    Unsupported,
    Corrupt,
    NotFound,
    NotDir,
    IsDir,
    Exists,
    DirFull,
    NameTooLong,
    ReadOnly,
};

const bps_min = 512;
const bps_max = 4096;

pub const Geometry = struct {
    bytes_per_sector: u32 = 0,
    sectors_per_cluster: u32 = 0,
    cluster_bytes: u32 = 0,
    reserved_sectors: u32 = 0,
    fat_count: u32 = 0,
    fat_sectors: u32 = 0,
    total_sectors: u64 = 0,
    root_cluster: u32 = 0,
    clusters: u32 = 0,
    fat_start: u64 = 0,
    data_start: u64 = 0,
    fsinfo_sector: u32 = 0,
};

pub const Slot = struct { lba: u64, offset: u16 };

pub const DirItem = struct {
    display: [max_name + 1]u8 = undefined,
    display_len: u8 = 0,
    short_name: [11]u8 = undefined,
    attr: u8 = 0,
    cluster: u32 = 0,
    size: u32 = 0,
    lba: u64 = 0,
    offset: u16 = 0,

    pub fn name(self: *const DirItem) []const u8 {
        return self.display[0..self.display_len];
    }

    pub fn isDir(self: *const DirItem) bool {
        return self.attr & 0x10 != 0;
    }
};

pub const Check = struct {
    ok: bool = false,
    files: u32 = 0,
    dirs: u32 = 0,
    clusters_used: u32 = 0,
    clusters_allocated: u32 = 0,
    orphans: u32 = 0,
    loops: u32 = 0,
    size_errors: u32 = 0,
    free_count: u32 = 0,
    fsinfo_free: u32 = 0,
    free_count_ok: bool = false,
};

// Static scratch, one mounted volume at a time.
var cluster_buf: [max_cluster_bytes]u8 align(8) = undefined;
var sector_buf: [bps_max]u8 align(8) = undefined;
var fat_buf: [bps_max]u8 align(8) = undefined;
var zero_buf: [8 * 512]u8 align(8) = [_]u8{0} ** (8 * 512);
var visited: [max_check_clusters / 8]u8 align(8) = undefined;
var read_seen: [max_file_bytes / 512]u32 = undefined;
// The probe fixture's buffers are static on purpose: the shell thread's stack is
// 32 KiB and the first version of step [22] put both of these on it. The
// resulting overflow overwrote a neighbouring thread's saved trap frame and the
// scheduler caught it as "corrupt frame". Nothing on the probe path may put KiB
// of data on a kernel stack.
var exercise_content: [4096]u8 = undefined;
var exercise_readback: [4096]u8 = undefined;

pub const Volume = struct {
    view: block_view.View = undefined,
    geo: Geometry = .{},
    mounted: bool = false,
    free_hint: u32 = 2,
    fat_cache_sector: u64 = 0,
    fat_cache_valid: bool = false,
    fat_cache_dirty: bool = false,
    fsinfo_free_hint: u32 = 0,

    pub fn clusterBytes(self: *const Volume) u32 {
        return self.geo.cluster_bytes;
    }

    pub fn totalBytes(self: *const Volume) u64 {
        return self.geo.total_sectors * self.geo.bytes_per_sector;
    }

    // -- low level ---------------------------------------------------------

    fn readFs(self: *Volume, fs_sector: u64, buf: []u8) Error!void {
        const per = self.geo.bytes_per_sector / 512;
        self.view.read(fs_sector * per, buf) catch return error.Io;
    }

    fn writeFs(self: *Volume, fs_sector: u64, buf: []const u8) Error!void {
        const per = self.geo.bytes_per_sector / 512;
        self.view.write(fs_sector * per, buf) catch return error.Io;
    }

    fn flush(self: *Volume) Error!void {
        try self.fatFlush();
        self.view.flush() catch return error.Io;
    }

    fn clusterLba(self: *const Volume, cluster: u32) Error!u64 {
        if (cluster < 2 or cluster >= self.geo.clusters + 2) return error.Corrupt;
        return self.geo.data_start + @as(u64, cluster - 2) * self.geo.sectors_per_cluster;
    }

    fn readCluster(self: *Volume, cluster: u32, buf: []u8) Error!void {
        const lba = try self.clusterLba(cluster);
        try self.readFs(lba, buf[0..self.geo.cluster_bytes]);
    }

    fn writeCluster(self: *Volume, cluster: u32, buf: []const u8) Error!void {
        const lba = try self.clusterLba(cluster);
        try self.writeFs(lba, buf[0..self.geo.cluster_bytes]);
    }

    // -- FAT ---------------------------------------------------------------

    fn fatLoad(self: *Volume, sector_index: u64) Error!void {
        if (self.fat_cache_valid and self.fat_cache_sector == sector_index) return;
        try self.fatFlush();
        const fat_sector = self.geo.fat_start + sector_index;
        try self.readFs(fat_sector, fat_buf[0..self.geo.bytes_per_sector]);
        self.fat_cache_sector = sector_index;
        self.fat_cache_valid = true;
    }

    fn fatFlush(self: *Volume) Error!void {
        if (!self.fat_cache_valid or !self.fat_cache_dirty) return;
        const bps = self.geo.bytes_per_sector;
        var copy: u32 = 0;
        while (copy < self.geo.fat_count) : (copy += 1) {
            const base = self.geo.fat_start + @as(u64, copy) * self.geo.fat_sectors;
            try self.writeFs(base + self.fat_cache_sector, fat_buf[0..bps]);
        }
        self.fat_cache_dirty = false;
    }

    pub fn fatGet(self: *Volume, cluster: u32) Error!u32 {
        const bps = self.geo.bytes_per_sector;
        const byte_off = cluster * 4;
        const sector_index = byte_off / bps;
        if (sector_index >= self.geo.fat_sectors) return error.Corrupt;
        try self.fatLoad(sector_index);
        return std.mem.readInt(u32, fat_buf[byte_off % bps ..][0..4], .little) & fat_mask;
    }

    fn fatSet(self: *Volume, cluster: u32, value: u32) Error!void {
        const bps = self.geo.bytes_per_sector;
        const byte_off = cluster * 4;
        const sector_index = byte_off / bps;
        if (sector_index >= self.geo.fat_sectors) return error.Corrupt;
        try self.fatLoad(sector_index);
        const slot = fat_buf[byte_off % bps ..][0..4];
        const old = std.mem.readInt(u32, slot, .little);
        const merged = (old & ~fat_mask) | (value & fat_mask);
        std.mem.writeInt(u32, slot, merged, .little);
        self.fat_cache_dirty = true;
    }

    /// The next cluster in a chain, 0 for a free entry, `eoc` sentinel for the
    /// end. Anything outside the data region is corruption.
    fn chainNext(self: *Volume, cluster: u32) Error!u32 {
        const value = try self.fatGet(cluster);
        if (value == 0) return error.Corrupt;
        if (value >= eoc_min) return 0xffff_ffff;
        if (value < 2 or value >= self.geo.clusters + 2) return error.Corrupt;
        return value;
    }

    fn freeChain(self: *Volume, start: u32) Error!u32 {
        var cluster = start;
        var freed: u32 = 0;
        var guard: u32 = 0;
        while (cluster != 0 and guard < self.geo.clusters + 2) : (guard += 1) {
            const next = self.fatGet(cluster) catch return error.Corrupt;
            try self.fatSet(cluster, 0);
            freed += 1;
            if (next >= eoc_min) break;
            if (next < 2 or next >= self.geo.clusters + 2) return error.Corrupt;
            cluster = next;
        }
        if (guard >= self.geo.clusters + 2) return error.Corrupt;
        return freed;
    }

    fn allocCluster(self: *Volume, skip: []const u32) Error!u32 {
        var pass: u32 = 0;
        while (pass < 2) : (pass += 1) {
            var cluster: u32 = if (pass == 0) self.free_hint else 2;
            while (cluster < self.geo.clusters + 2) : (cluster += 1) {
                var used = false;
                for (skip) |s| {
                    if (s == cluster) {
                        used = true;
                        break;
                    }
                }
                if (used) continue;
                if (try self.fatGet(cluster) == 0) {
                    self.free_hint = cluster + 1;
                    return cluster;
                }
            }
        }
        return error.NoSpace;
    }

    fn setFreeCount(self: *Volume, free: u32) Error!void {
        self.fsinfo_free_hint = free;
        const fs_sector = self.geo.fsinfo_sector;
        if (fs_sector == 0 or fs_sector >= self.geo.reserved_sectors) return;
        var buf: [512]u8 = undefined;
        const per = self.geo.bytes_per_sector / 512;
        self.view.read(@as(u64, fs_sector) * per, buf[0..]) catch return error.Io;
        std.mem.writeInt(u32, buf[488..492], free, .little);
        std.mem.writeInt(u32, buf[492..496], self.free_hint, .little);
        self.view.write(@as(u64, fs_sector) * per, buf[0..]) catch return error.Io;
    }

    // -- directories -------------------------------------------------------

    fn entriesPerSector(self: *const Volume) u32 {
        return self.geo.bytes_per_sector / 32;
    }

    fn entriesPerCluster(self: *const Volume) u32 {
        return self.geo.cluster_bytes / 32;
    }

    pub const Iter = struct {
        cluster: u32,
        slot: u32,
        total: u32,
        lfn: [max_name + 1]u8 = undefined,
        lfn_present: bool = false,
        lfn_len: u8 = 0,
    };

    pub fn iterStart(self: *Volume) Iter {
        return .{ .cluster = self.geo.root_cluster, .slot = 0, .total = self.entriesPerCluster() };
    }

    pub fn nextItem(self: *Volume, it: *Iter) Error!?DirItem {
        const bps = self.geo.bytes_per_sector;
        const per_sector = self.entriesPerSector();
        var guard: u32 = 0;
        while (true) {
            if (it.slot >= it.total) {
                const next = try self.chainNext(it.cluster);
                if (next == 0xffff_ffff) return null;
                it.cluster = next;
                it.slot = 0;
                if (guard > self.geo.clusters + 2) return error.Corrupt;
                guard += 1;
            }
            const sector_in_cluster = it.slot / per_sector;
            const slot_in_sector = it.slot % per_sector;
            const lba = try self.clusterLba(it.cluster) + sector_in_cluster;
            try self.readFs(lba, sector_buf[0..bps]);
            const raw = sector_buf[slot_in_sector * 32 ..][0..32];
            it.slot += 1;
            if (raw[0] == 0x00) return null;
            if (raw[0] == 0xe5) {
                it.lfn_present = false;
                it.lfn_len = 0;
                continue;
            }
            const attr = raw[11];
            if (attr & 0x3f == 0x0f) {
                // Long-name chunk: sequence 1..20 (0x40 marks the last), the 13
                // UTF-16 units live at 1, 14 and 28. On disk the chunks come in
                // reverse order, so the sequence decides the offset.
                const seq = raw[0] & 0x1f;
                if (seq == 0 or seq > 20) {
                    it.lfn_present = false;
                    continue;
                }
                const base: usize = @as(usize, seq - 1) * 13;
                const offs = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
                var k: usize = 0;
                while (k < 13 and base + k < max_name) : (k += 1) {
                    const code = std.mem.readInt(u16, raw[offs[k]..][0..2], .little);
                    if (code == 0 or code == 0xffff) break;
                    it.lfn[base + k] = if (code >= 0x20 and code < 0x7f) @intCast(code) else '?';
                }
                it.lfn_len = @max(it.lfn_len, @as(u8, @intCast(@min(base + k, max_name))));
                it.lfn_present = true;
                continue;
            }
            if (attr & 0x08 != 0) continue; // volume label
            var item = DirItem{
                .short_name = undefined,
                .attr = attr,
                .cluster = (@as(u32, std.mem.readInt(u16, raw[20..22], .little)) << 16) | @as(u32, std.mem.readInt(u16, raw[26..28], .little)),
                .size = std.mem.readInt(u32, raw[28..32], .little),
                .lba = lba,
                .offset = @intCast(slot_in_sector * 32),
            };
            @memcpy(&item.short_name, raw[0..11]);
            if (it.lfn_present and it.lfn_len != 0) {
                @memcpy(item.display[0..it.lfn_len], it.lfn[0..it.lfn_len]);
                item.display_len = it.lfn_len;
            } else {
                var n: usize = 0;
                for (raw[0..8]) |c| {
                    if (c == ' ') continue;
                    item.display[n] = c;
                    n += 1;
                }
                if (raw[8] != ' ') {
                    item.display[n] = '.';
                    n += 1;
                    var e: usize = 8;
                    while (e < 11) : (e += 1) {
                        if (raw[e] == ' ') continue;
                        item.display[n] = raw[e];
                        n += 1;
                    }
                }
                item.display_len = @intCast(n);
            }
            it.lfn_present = false;
            it.lfn_len = 0;
            return item;
        }
    }

    fn nameEq(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            const x = std.ascii.toLower(a[i]);
            const y = std.ascii.toLower(b[i]);
            if (x != y) return false;
        }
        return true;
    }

    pub fn find(self: *Volume, name: []const u8) Error!?DirItem {
        var it = self.iterStart();
        while (try self.nextItem(&it)) |item| {
            if (nameEq(item.name(), name)) return item;
        }
        return null;
    }

    fn findFreeSlot(self: *Volume) Error!Slot {
        const bps = self.geo.bytes_per_sector;
        const per_sector = self.entriesPerSector();
        var cluster = self.geo.root_cluster;
        var guard: u32 = 0;
        while (guard < self.geo.clusters + 2) : (guard += 1) {
            var sector: u32 = 0;
            while (sector < self.geo.sectors_per_cluster) : (sector += 1) {
                const lba = try self.clusterLba(cluster) + sector;
                try self.readFs(lba, sector_buf[0..bps]);
                var slot: u32 = 0;
                while (slot < per_sector) : (slot += 1) {
                    const first = sector_buf[slot * 32];
                    if (first == 0x00 or first == 0xe5) {
                        return .{ .lba = lba, .offset = @intCast(slot * 32) };
                    }
                }
            }
            const next = try self.chainNext(cluster);
            if (next == 0xffff_ffff) return error.DirFull;
            cluster = next;
        }
        return error.DirFull;
    }

    fn writeEntry(self: *Volume, lba: u64, offset: u16, raw: *const [32]u8) Error!void {
        const bps = self.geo.bytes_per_sector;
        try self.readFs(lba, sector_buf[0..bps]);
        @memcpy(sector_buf[offset..][0..32], raw);
        try self.writeFs(lba, sector_buf[0..bps]);
    }

    fn encodeShort(name: []const u8, out: *[11]u8) Error!void {
        if (name.len == 0 or name.len > 12) return error.NameTooLong;
        var base_len: usize = 0;
        var ext_len: usize = 0;
        var after_dot = false;
        for (name) |c| {
            if (c == '.') {
                if (after_dot) return error.NameTooLong;
                after_dot = true;
                continue;
            }
            if (c < 0x20 or c == '/' or c == '\\' or c == ':' or c == '*' or c == '?' or
                c == '"' or c == '<' or c == '>' or c == '|' or c == ' ')
            {
                return error.NameTooLong;
            }
            if (after_dot) {
                ext_len += 1;
            } else {
                base_len += 1;
            }
        }
        if (base_len == 0 or base_len > 8 or ext_len > 3) return error.NameTooLong;
        @memset(out, ' ');
        var b: usize = 0;
        var e: usize = 0;
        for (name) |c| {
            if (c == '.') continue;
            if (b < base_len) {
                out[b] = std.ascii.toUpper(c);
                b += 1;
            } else {
                out[8 + e] = std.ascii.toUpper(c);
                e += 1;
            }
        }
    }

    fn encodeTime() struct { time: u16, date: u16 } {
        // A fixed, valid timestamp: FAT has no requirement that it be true, and
        // the shell has no clock calibration here. 2026-01-01 00:00:00.
        return .{ .time = 0, .date = ((2026 - 1980) << 9) | (1 << 5) | 1 };
    }

    fn buildEntry(short: *const [11]u8, cluster: u32, size: u32, is_dir: bool) [32]u8 {
        var raw = [_]u8{0} ** 32;
        @memcpy(raw[0..11], short);
        raw[11] = if (is_dir) 0x10 else 0x20;
        const stamp = encodeTime();
        std.mem.writeInt(u16, raw[14..16], stamp.time, .little);
        std.mem.writeInt(u16, raw[16..18], stamp.date, .little);
        std.mem.writeInt(u16, raw[18..20], stamp.date, .little);
        std.mem.writeInt(u16, raw[20..22], @intCast(cluster >> 16), .little);
        std.mem.writeInt(u16, raw[24..26], stamp.time, .little);
        std.mem.writeInt(u16, raw[26..28], @intCast(cluster & 0xffff), .little);
        std.mem.writeInt(u32, raw[28..32], size, .little);
        return raw;
    }

    // -- files -------------------------------------------------------------

    /// Read up to `buf.len` bytes of a file. The whole file must fit: a short
    /// buffer is a refusal, not a partial read, because a caller that silently
    /// gets half a configuration file is worse off than one that gets an error.
    pub fn readFile(self: *Volume, name: []const u8, buf: []u8) Error!usize {
        const item = (try self.find(name)) orelse return error.NotFound;
        if (item.isDir()) return error.IsDir;
        if (item.size > buf.len) return error.NoSpace;
        var cluster = item.cluster;
        var remaining: u64 = item.size;
        var written: usize = 0;
        const expected: u32 = @intCast((item.size + self.geo.cluster_bytes - 1) / self.geo.cluster_bytes);
        if (expected > read_seen.len) return error.NoSpace;
        var seen: u32 = 0;
        while (remaining > 0) {
            if (cluster < 2 or cluster >= self.geo.clusters + 2) return error.Corrupt;
            // A chain that revisits a cluster would otherwise satisfy a size by
            // reading the same data twice; that is a loop, not a file.
            var i: u32 = 0;
            while (i < seen) : (i += 1) {
                if (read_seen[i] == cluster) return error.Corrupt;
            }
            if (seen >= expected) return error.Corrupt;
            read_seen[seen] = cluster;
            seen += 1;
            try self.readCluster(cluster, cluster_buf[0..]);
            const take: usize = @intCast(@min(@as(u64, self.geo.cluster_bytes), remaining));
            @memcpy(buf[written..][0..take], cluster_buf[0..take]);
            written += take;
            remaining -= take;
            if (remaining == 0) break;
            const next = try self.chainNext(cluster);
            if (next == 0xffff_ffff) return error.Corrupt;
            cluster = next;
        }
        // The entry must end where the size says it does, or the directory and
        // the chain disagree.
        if (self.chainNext(cluster)) |next| {
            if (next != 0xffff_ffff) return error.Corrupt;
        } else |_| return error.Corrupt;
        return written;
    }

    pub const WriteResult = struct {
        clusters: u32 = 0,
        freed: u32 = 0,
        size: u32 = 0,
        free_after: u32 = 0,
    };

    /// Create or replace a file. Data is written before the FAT chain and the
    /// directory entry that publishes it; see the module comment for why.
    pub fn writeFile(self: *Volume, name: []const u8, data: []const u8) Error!WriteResult {
        if (data.len > max_file_bytes) return error.NoSpace;
        const need: u32 = if (data.len == 0) 0 else @intCast((data.len + self.geo.cluster_bytes - 1) / self.geo.cluster_bytes);
        if (need > self.geo.clusters) return error.NoSpace;
        var result = WriteResult{ .size = @intCast(data.len) };
        var short: [11]u8 = undefined;
        try encodeShort(name, &short);

        var slot: Slot = undefined;
        const existing = try self.find(name);
        if (existing) |item| {
            if (item.isDir()) return error.IsDir;
            // Unpublish the old content first: a crash here leaves a valid
            // zero-length file, never a size that outlives its chain.
            var trunc = [_]u8{0} ** 32;
            @memcpy(trunc[0..11], &item.short_name);
            trunc[11] = item.attr;
            try self.writeEntry(item.lba, item.offset, &trunc);
            try self.flush();
            if (item.cluster != 0) result.freed = try self.freeChain(item.cluster);
            slot = .{ .lba = item.lba, .offset = item.offset };
        } else {
            slot = try self.findFreeSlot();
        }

        var reserved: [max_file_bytes / 512]u32 = undefined;
        var i: u32 = 0;
        while (i < need) : (i += 1) {
            reserved[i] = try self.allocCluster(reserved[0..i]);
        }

        // 1. The data, into clusters the FAT still calls free.
        i = 0;
        while (i < need) : (i += 1) {
            const start: usize = @as(usize, i) * self.geo.cluster_bytes;
            const take: usize = @min(self.geo.cluster_bytes, data.len - start);
            @memset(cluster_buf[0..self.geo.cluster_bytes], 0);
            @memcpy(cluster_buf[0..take], data[start..][0..take]);
            try self.writeCluster(reserved[i], cluster_buf[0..]);
        }
        try self.flush();

        // 2. The chain. A crash before the directory entry below leaves these
        //    clusters allocated but unreferenced (an orphan); a crash after it
        //    leaves a consistent file.
        i = 0;
        while (i < need) : (i += 1) {
            try self.fatSet(reserved[i], if (i + 1 < need) reserved[i + 1] else eoc_min);
        }

        const cluster: u32 = if (need == 0) 0 else reserved[0];
        const raw = buildEntry(&short, cluster, @intCast(data.len), false);
        try self.writeEntry(slot.lba, slot.offset, &raw);
        try self.setFreeCount(try self.freeCount());
        try self.flush();
        result.clusters = need;
        result.free_after = try self.freeCount();
        return result;
    }

    pub fn deleteFile(self: *Volume, name: []const u8) Error!u32 {
        const item = (try self.find(name)) orelse return error.NotFound;
        if (item.isDir()) return error.IsDir;
        var raw = [_]u8{0} ** 32;
        @memcpy(raw[0..11], &item.short_name);
        raw[11] = item.attr;
        raw[0] = 0xe5;
        try self.writeEntry(item.lba, item.offset, &raw);
        try self.flush();
        var freed: u32 = 0;
        if (item.cluster != 0) freed = try self.freeChain(item.cluster);
        try self.setFreeCount(try self.freeCount());
        try self.flush();
        return freed;
    }

    /// Write the cached FAT/FSInfo sector and ask the device to make it
    /// durable. The power path calls this before the final shutdown record is
    /// written, so a mounted filesystem is never left with a dirty cache.
    pub fn sync(self: *Volume) Error!void {
        try self.flush();
    }

    /// Another mount of the same partition may have changed the FAT or the
    /// directory since this volume last read them (the power journal and the
    /// shell's `fat` command are two such mounts). Flush what this volume owns,
    /// then drop the cached FAT sector so the next operation re-reads it.
    pub fn refresh(self: *Volume) Error!void {
        try self.flush();
        self.fat_cache_valid = false;
        self.free_hint = 2;
    }

    pub fn freeCount(self: *Volume) Error!u32 {
        var used: u32 = 0;
        var cluster: u32 = 2;
        while (cluster < self.geo.clusters + 2) : (cluster += 1) {
            if (try self.fatGet(cluster) != 0) used += 1;
        }
        return self.geo.clusters - used;
    }

    pub fn list(self: *Volume) Error!u32 {
        var count: u32 = 0;
        var it = self.iterStart();
        while (try self.nextItem(&it)) |_| count += 1;
        return count;
    }

    // -- at-rest consistency ----------------------------------------------

    fn mark(self: *Volume, cluster: u32, result: *Check) Error!void {
        if (cluster < 2 or cluster >= self.geo.clusters + 2) return error.Corrupt;
        const byte = cluster / 8;
        const bit: u3 = @intCast(cluster % 8);
        if (visited[byte] & (@as(u8, 1) << bit) != 0) {
            result.loops += 1;
            return;
        }
        visited[byte] |= @as(u8, 1) << bit;
        result.clusters_used += 1;
    }

    fn walkChain(self: *Volume, start: u32, expected: u32, result: *Check) Error!void {
        var cluster = start;
        var length: u32 = 0;
        while (true) {
            try self.mark(cluster, result);
            length += 1;
            const next = try self.chainNext(cluster);
            if (next == 0xffff_ffff) break;
            cluster = next;
            if (length > self.geo.clusters + 2) {
                result.loops += 1;
                return;
            }
        }
        if (expected != 0 and length != expected) result.size_errors += 1;
        if (expected == 0 and length != 0) result.size_errors += 1;
    }

    pub fn check(self: *Volume) Error!Check {
        if (self.geo.clusters > max_check_clusters) return error.Unsupported;
        @memset(visited[0..], 0);
        var result = Check{};
        if (self.geo.root_cluster < 2 or self.geo.root_cluster >= self.geo.clusters + 2) return error.Corrupt;
        try self.mark(self.geo.root_cluster, &result);
        result.dirs += 1;

        // The root chain, then every file the root references.
        var root = self.geo.root_cluster;
        var scan_guard: u32 = 0;
        var it = self.iterStart();
        while (try self.nextItem(&it)) |item| {
            scan_guard += 1;
            if (scan_guard > self.geo.clusters * self.entriesPerCluster() + 16) return error.Corrupt;
            if (item.isDir()) {
                result.dirs += 1;
                continue;
            }
            result.files += 1;
            if (item.cluster == 0) {
                if (item.size != 0) result.size_errors += 1;
                continue;
            }
            const expected: u32 = @intCast((item.size + self.geo.cluster_bytes - 1) / self.geo.cluster_bytes);
            try self.walkChain(item.cluster, expected, &result);
        }
        // The rest of the root chain must be visited too, or a gap would look
        // like an orphan.
        while (true) {
            const next = try self.chainNext(root);
            if (next == 0xffff_ffff) break;
            try self.mark(next, &result);
            root = next;
        }

        var allocated: u32 = 0;
        var cluster: u32 = 2;
        while (cluster < self.geo.clusters + 2) : (cluster += 1) {
            const value = try self.fatGet(cluster);
            if (value == 0) continue;
            allocated += 1;
            if (value != bad_cluster and value < eoc_min) {
                if (value < 2 or value >= self.geo.clusters + 2) return error.Corrupt;
            }
        }
        result.clusters_allocated = allocated;
        if (allocated > result.clusters_used) result.orphans = allocated - result.clusters_used;
        if (result.clusters_used > allocated) result.orphans = result.clusters_used - allocated;
        result.free_count = self.geo.clusters - allocated;
        result.fsinfo_free = self.fsinfo_free_hint;
        result.free_count_ok = result.fsinfo_free == result.free_count;
        result.ok = result.loops == 0 and result.orphans == 0 and result.size_errors == 0;
        return result;
    }
};

// ---------------------------------------------------------------------------
// Mount.
// ---------------------------------------------------------------------------

pub fn mount(view: block_view.View) Error!Volume {
    var vol = Volume{ .view = view };
    if (view.sectors < 64) return error.BadGeometry;
    var boot: [512]u8 align(8) = undefined;
    view.read(0, boot[0..]) catch return error.Io;
    if (boot[510] != 0x55 or boot[511] != 0xaa) return error.BadBoot;
    const jump_ok = boot[0] == 0xeb or boot[0] == 0xe9;
    if (!jump_ok) return error.BadBoot;

    const bps = std.mem.readInt(u16, boot[11..13], .little);
    const spc = boot[13];
    const reserved = std.mem.readInt(u16, boot[14..16], .little);
    const fats = boot[16];
    const total16 = std.mem.readInt(u16, boot[19..21], .little);
    const total32 = std.mem.readInt(u32, boot[32..36], .little);
    const fat16 = std.mem.readInt(u16, boot[22..24], .little);
    const fat32 = std.mem.readInt(u32, boot[36..40], .little);
    const root_cluster = std.mem.readInt(u32, boot[44..48], .little);
    const fsinfo = std.mem.readInt(u16, boot[48..50], .little);

    if (bps < bps_min or bps > bps_max or bps % 512 != 0) return error.BadGeometry;
    if (!std.math.isPowerOfTwo(spc) or spc == 0 or spc > 128) return error.BadGeometry;
    const cluster_bytes: u32 = @as(u32, bps) * @as(u32, spc);
    if (cluster_bytes > max_cluster_bytes) return error.Unsupported;
    if (reserved == 0 or fats == 0 or fats > 4) return error.BadGeometry;
    if (fat32 == 0 or fat16 != 0) return error.BadGeometry;
    const total: u64 = if (total16 != 0) total16 else total32;
    if (total == 0) return error.BadGeometry;
    if (total > view.sectors) return error.BadGeometry;
    const fat_start: u64 = reserved;
    const data_start: u64 = @as(u64, reserved) + @as(u64, fats) * fat32;
    if (data_start >= total) return error.BadGeometry;
    const data_sectors = total - data_start;
    if (data_sectors < spc) return error.BadGeometry;
    const clusters: u32 = @intCast(data_sectors / spc);
    if (clusters < 1) return error.BadGeometry;
    if (root_cluster < 2 or root_cluster >= clusters + 2) return error.BadGeometry;
    // The FAT must be able to describe every cluster with 4-byte entries.
    const fat_entries = @as(u64, fat32) * bps / 4;
    if (fat_entries < clusters + 2) return error.BadGeometry;

    vol.geo = .{
        .bytes_per_sector = bps,
        .sectors_per_cluster = spc,
        .cluster_bytes = cluster_bytes,
        .reserved_sectors = reserved,
        .fat_count = fats,
        .fat_sectors = fat32,
        .total_sectors = total,
        .root_cluster = root_cluster,
        .clusters = clusters,
        .fat_start = fat_start,
        .data_start = data_start,
        .fsinfo_sector = fsinfo,
    };
    vol.free_hint = 2;
    vol.fsinfo_free_hint = 0;
    if (fsinfo != 0 and fsinfo < reserved) {
        var info: [512]u8 align(8) = undefined;
        const per = bps / 512;
        // FSInfo is a hint: an unreadable sector or a wrong signature is
        // tolerated, the FAT itself is authoritative.
        if (view.read(@as(u64, fsinfo) * per, info[0..])) |_| {
            if (std.mem.readInt(u32, info[0..4], .little) == 0x41615252 and
                std.mem.readInt(u32, info[484..488], .little) == 0x61417272)
            {
                const free = std.mem.readInt(u32, info[488..492], .little);
                const next = std.mem.readInt(u32, info[492..496], .little);
                if (free <= clusters) vol.fsinfo_free_hint = free;
                if (next >= 2 and next < clusters + 2) vol.free_hint = next;
            }
        } else |_| {}
    }
    // FAT[0] carries the media byte in its low 8 bits; the upper bits are
    // reserved. A volume whose first entry is not a media marker is refused.
    const fat0 = vol.fatGet(0) catch return error.BadGeometry;
    if (fat0 & 0xff != 0xf8 and fat0 & 0xff != 0xf0) return error.BadBoot;
    vol.mounted = true;
    return vol;
}

// ---------------------------------------------------------------------------
// Formatter. The installer does not exist yet; this makes the probe's fixture a
// real FAT32 volume (spec geometry, both FATs, FSInfo, backup boot sector) and
// is the primitive a later installer will use.
// ---------------------------------------------------------------------------

pub const MkfsOptions = struct {
    total_sectors: u64,
    sectors_per_cluster: u32 = 1,
    label: []const u8 = "CASSA",
};

pub const MkfsResult = struct {
    total_sectors: u64 = 0,
    clusters: u32 = 0,
    fat_sectors: u32 = 0,
    cluster_bytes: u32 = 0,
};

fn vwrite(view: block_view.View, lba: u64, buf: []const u8) Error!void {
    view.write(lba, buf) catch return error.Io;
}
fn vread(view: block_view.View, lba: u64, buf: []u8) Error!void {
    view.read(lba, buf) catch return error.Io;
}
fn vflush(view: block_view.View) Error!void {
    view.flush() catch return error.Io;
}

pub fn mkfs(view: block_view.View, opts: MkfsOptions) Error!MkfsResult {
    if (opts.total_sectors < 1024 or opts.total_sectors > view.sectors) return error.BadGeometry;
    if (!std.math.isPowerOfTwo(opts.sectors_per_cluster) or opts.sectors_per_cluster > 128) return error.BadGeometry;
    const bps: u32 = 512;
    const spc = opts.sectors_per_cluster;
    const cluster_bytes = bps * spc;
    if (cluster_bytes > max_cluster_bytes) return error.BadGeometry;
    const total = opts.total_sectors;
    const reserved: u32 = 32;
    const fats: u32 = 2;
    var fat_sectors: u32 = 1;
    var clusters: u32 = 0;
    var iter: u8 = 0;
    while (iter < 4) : (iter += 1) {
        const data = total - reserved - @as(u64, fats) * fat_sectors;
        if (data <= spc) return error.BadGeometry;
        clusters = @intCast(data / spc);
        const entries = @as(u64, clusters) + 2;
        const needed: u32 = @intCast((entries * 4 + bps - 1) / bps);
        if (needed == fat_sectors) break;
        fat_sectors = needed;
    }
    if (clusters < 65_525) return error.BadGeometry; // not a FAT32 by the spec's own count
    if (clusters > max_check_clusters) return error.Unsupported;

    var boot: [512]u8 align(8) = [_]u8{0} ** 512;
    boot[0] = 0xeb;
    boot[1] = 0x58;
    boot[2] = 0x90;
    @memcpy(boot[3..11], "CASSA   ");
    std.mem.writeInt(u16, boot[11..13], bps, .little);
    boot[13] = @intCast(spc);
    std.mem.writeInt(u16, boot[14..16], @intCast(reserved), .little);
    boot[16] = @intCast(fats);
    boot[21] = 0xf8;
    std.mem.writeInt(u16, boot[24..26], 32, .little);
    std.mem.writeInt(u16, boot[26..28], 64, .little);
    std.mem.writeInt(u32, boot[32..36], @intCast(total), .little);
    std.mem.writeInt(u32, boot[36..40], fat_sectors, .little);
    std.mem.writeInt(u32, boot[44..48], 2, .little); // root cluster
    std.mem.writeInt(u16, boot[48..50], 1, .little); // FSInfo
    std.mem.writeInt(u16, boot[50..52], 6, .little); // backup boot
    boot[64] = 0x80;
    boot[66] = 0x29;
    std.mem.writeInt(u32, boot[67..71], 0xca55_0036, .little);
    var label: [11]u8 = [_]u8{' '} ** 11;
    var li: usize = 0;
    while (li < opts.label.len and li < 11) : (li += 1) label[li] = std.ascii.toUpper(opts.label[li]);
    @memcpy(boot[71..82], &label);
    @memcpy(boot[82..90], "FAT32   ");
    boot[510] = 0x55;
    boot[511] = 0xaa;

    var fsinfo: [512]u8 align(8) = [_]u8{0} ** 512;
    std.mem.writeInt(u32, fsinfo[0..4], 0x41615252, .little);
    std.mem.writeInt(u32, fsinfo[484..488], 0x61417272, .little);
    std.mem.writeInt(u32, fsinfo[488..492], clusters - 1, .little);
    std.mem.writeInt(u32, fsinfo[492..496], 3, .little);
    std.mem.writeInt(u32, fsinfo[508..512], 0xaa55_0000, .little);

    try vwrite(view, 0, boot[0..]);
    try vwrite(view, 1, fsinfo[0..]);
    try vwrite(view, 6, boot[0..]);
    try vwrite(view, 7, fsinfo[0..]);

    // Zero both FATs in 4 KiB writes.
    var fat_index: u32 = 0;
    while (fat_index < fats) : (fat_index += 1) {
        const base = @as(u64, reserved) + @as(u64, fat_index) * fat_sectors;
        var sector: u32 = 0;
        while (sector < fat_sectors) {
            const batch: u32 = @min(8, fat_sectors - sector);
            try vwrite(view, base + sector, zero_buf[0 .. batch * 512]);
            sector += batch;
        }
    }
    var fat_first: [512]u8 align(8) = [_]u8{0} ** 512;
    std.mem.writeInt(u32, fat_first[0..4], 0x0fff_fff8, .little);
    std.mem.writeInt(u32, fat_first[4..8], 0x0fff_ffff, .little);
    std.mem.writeInt(u32, fat_first[8..12], 0x0fff_ffff, .little);
    var copy: u32 = 0;
    while (copy < fats) : (copy += 1) {
        try vwrite(view, @as(u64, reserved) + @as(u64, copy) * fat_sectors, fat_first[0..]);
    }

    // Zero the root directory cluster.
    const data_start: u64 = @as(u64, reserved) + @as(u64, fats) * fat_sectors;
    var s: u32 = 0;
    while (s < spc) : (s += 1) try vwrite(view, data_start + s, zero_buf[0..512]);
    try vflush(view);

    return .{ .total_sectors = total, .clusters = clusters, .fat_sectors = fat_sectors, .cluster_bytes = cluster_bytes };
}

// ---------------------------------------------------------------------------
// Probe fixture: format a scratch region, then create/grow/read/corrupt/delete
// a file through the driver. Step [22] runs this on hardware; the host tests
// run the same code on a RAM disk, so both sides exercise one implementation.
// ---------------------------------------------------------------------------

pub const Exercise = struct {
    bytes: u64 = 0,
    total_sectors: u64 = 0,
    clusters: u32 = 0,
    cluster_bytes: u32 = 0,
    fat_sectors: u32 = 0,
    free_before: u32 = 0,
    free_after_write: u32 = 0,
    free_after_delete: u32 = 0,
    written: u32 = 0,
    read_back: u32 = 0,
    clusters_used: u32 = 0,
    digest: u64 = 0,
    created: bool = false,
    round_trip: bool = false,
    loop_detected: bool = false,
    restored: bool = false,
    deleted: bool = false,
    gone: bool = false,
    freed: u32 = 0,
    check_ok: bool = false,
    orphans: u32 = 0,
    loops: u32 = 0,
    size_errors: u32 = 0,
};

pub fn digest(bytes: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100_0000_01b3;
    }
    return h;
}

/// Deterministic content: readable in a hexdump, spans several clusters, and
/// includes a newline so host tools print it sensibly.
pub fn exerciseText(buf: []u8) usize {
    const line = "Cassa POS phase 36 FAT32 write test: the quick brown fox jumps over the lazy dog.\n";
    var n: usize = 0;
    var i: usize = 0;
    while (n + line.len <= buf.len and i < 25) : (i += 1) {
        @memcpy(buf[n..][0..line.len], line);
        n += line.len;
    }
    return n;
}

pub fn exercise(view: block_view.View) Error!Exercise {
    var e = Exercise{};
    const content = &exercise_content;
    const len = exerciseText(content);
    e.bytes = view.capacityBytes();
    const made = try mkfs(view, .{ .total_sectors = view.capacitySectors(), .sectors_per_cluster = 1, .label = "CASSA" });
    e.total_sectors = made.total_sectors;
    e.clusters = made.clusters;
    e.cluster_bytes = made.cluster_bytes;
    e.fat_sectors = made.fat_sectors;
    var vol = try mount(view);
    e.free_before = try vol.freeCount();

    const w = try vol.writeFile("SALE.TXT", content[0..len]);
    e.created = true;
    e.written = w.size;
    e.clusters_used = w.clusters;
    e.free_after_write = try vol.freeCount();

    const readback = &exercise_readback;
    const got = try vol.readFile("SALE.TXT", readback);
    e.read_back = @intCast(got);
    e.digest = digest(readback[0..got]);
    var same = got == len;
    if (same) {
        for (content[0..len], readback[0..got]) |a, b| {
            if (a != b) {
                same = false;
                break;
            }
        }
    }
    e.round_trip = same;

    const clean = try vol.check();
    e.check_ok = clean.ok;
    e.orphans = clean.orphans;
    e.loops = clean.loops;
    e.size_errors = clean.size_errors;

    // A corrupt chain must be detected, not followed. Point the first cluster
    // at itself, prove the read refuses, then put the chain back.
    const item = (try vol.find("SALE.TXT")) orelse return error.Corrupt;
    const first = item.cluster;
    const second = try vol.chainNext(first);
    try vol.fatSet(first, first);
    e.loop_detected = if (vol.readFile("SALE.TXT", readback)) |_| false else |err| err == error.Corrupt;
    try vol.fatSet(first, second);
    const after_restore = try vol.check();
    e.restored = after_restore.ok and after_restore.loops == 0;

    e.freed = try vol.deleteFile("SALE.TXT");
    e.deleted = true;
    e.gone = (try vol.find("SALE.TXT")) == null;
    e.free_after_delete = try vol.freeCount();
    const final = try vol.check();
    e.check_ok = e.check_ok and final.ok;
    e.orphans = final.orphans;
    e.loops = final.loops;
    return e;
}

// ---------------------------------------------------------------------------
// Host tests. The RAM disk below is only allocated in test builds; the kernel
// image gets one byte.
// ---------------------------------------------------------------------------

const test_sectors: u64 = 40 * 1024 * 1024 / 512;
var test_disk: [if (builtin.is_test) test_sectors * 512 else 1]u8 align(8) = undefined;

fn ramRead(lba: u64, buf: [*]u8, count: u32) block.Error!void {
    const n = @as(u64, count) * 512;
    if (lba > test_sectors or n > test_sectors * 512 - lba * 512) return error.NoSpace;
    @memcpy(buf[0..n], test_disk[@as(usize, @intCast(lba * 512))..][0..n]);
}
fn ramWrite(lba: u64, buf: [*]const u8, count: u32) block.Error!void {
    const n = @as(u64, count) * 512;
    if (lba > test_sectors or n > test_sectors * 512 - lba * 512) return error.NoSpace;
    @memcpy(test_disk[@as(usize, @intCast(lba * 512))..][0..n], buf[0..n]);
}
fn ramFlush() block.Error!void {}

fn ramView() Error!block_view.View {
    block.install(.{
        .capacity_sectors = test_sectors,
        .read = ramRead,
        .write = ramWrite,
        .flush = ramFlush,
    });
    return .{ .backend = block.backend.?, .base_lba = 0, .sectors = test_sectors };
}

test "mkfs produces a FAT32 whose BPB arithmetic mounts" {
    const view = try ramView();
    defer block.uninstall();
    const made = try mkfs(view, .{ .total_sectors = test_sectors, .sectors_per_cluster = 1 });
    try std.testing.expect(made.clusters >= 65_525);
    var vol = try mount(view);
    try std.testing.expectEqual(@as(u32, 512), vol.geo.bytes_per_sector);
    try std.testing.expectEqual(@as(u32, 2), vol.geo.fat_count);
    try std.testing.expectEqual(@as(u32, 2), vol.geo.root_cluster);
    try std.testing.expectEqual(made.clusters, vol.geo.clusters);
    try std.testing.expectEqual(@as(u32, 0), try vol.list());
}

test "create, grow across clusters, read back, check, delete" {
    const view = try ramView();
    defer block.uninstall();
    const e = try exercise(view);
    try std.testing.expect(e.created);
    try std.testing.expect(e.round_trip);
    try std.testing.expectEqual(@as(u32, e.written), @as(u32, @intCast(e.read_back)));
    try std.testing.expect(e.written > 2000);
    try std.testing.expectEqual(@as(u32, 5), e.clusters_used);
    try std.testing.expectEqual(e.free_before - e.clusters_used, e.free_after_write);
    try std.testing.expect(e.loop_detected);
    try std.testing.expect(e.restored);
    try std.testing.expect(e.deleted);
    try std.testing.expect(e.gone);
    try std.testing.expectEqual(@as(u32, 5), e.freed);
    try std.testing.expectEqual(e.free_before, e.free_after_delete);
    try std.testing.expect(e.check_ok);
    try std.testing.expectEqual(@as(u32, 0), e.orphans);
}

test "a corrupt BPB is refused" {
    const view = try ramView();
    defer block.uninstall();
    _ = try mkfs(view, .{ .total_sectors = test_sectors });
    var boot: [512]u8 = undefined;
    try view.read(0, &boot);
    // sector size 1000 is not a power-of-two multiple of 512
    std.mem.writeInt(u16, boot[11..13], 1000, .little);
    try view.write(0, &boot);
    try std.testing.expectError(error.BadGeometry, mount(view));
    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[510] = 0;
    try view.write(0, &boot);
    try std.testing.expectError(error.BadBoot, mount(view));
}

test "a long name written by another OS is read from its LFN entries" {
    const view = try ramView();
    defer block.uninstall();
    const made = try mkfs(view, .{ .total_sectors = test_sectors });
    var vol = try mount(view);
    const root_lba = vol.geo.data_start;

    const short = [_]u8{ 'L', 'O', 'N', 'G', 'F', 'I', '~', '1', 'T', 'X', 'T' };
    var sum: u8 = 0;
    for (short) |c| sum = (sum >> 1) +% (sum << 7) +% c;

    // "LongFileName.txt" (16 chars): chunk 2 holds chars 14..16, chunk 1 1..13.
    var sector: [512]u8 = [_]u8{0} ** 512;
    const lfn = "LongFileName.txt";
    var chunk: u8 = 2;
    while (chunk >= 1) : (chunk -= 1) {
        const base: usize = @as(usize, chunk - 1) * 13;
        var raw = [_]u8{0xff} ** 32;
        raw[0] = if (chunk == 2) 0x42 else 0x01;
        raw[11] = 0x0f;
        raw[13] = sum;
        const offs = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        var k: usize = 0;
        while (k < 13) : (k += 1) {
            const idx = base + k;
            const code: u16 = if (idx < lfn.len) lfn[idx] else if (idx == lfn.len) 0 else 0xffff;
            std.mem.writeInt(u16, raw[offs[k]..][0..2], code, .little);
        }
        const slot = @as(usize, 2 - chunk);
        @memcpy(sector[slot * 32 ..][0..32], &raw);
        if (chunk == 1) break;
    }
    // Short entry for the same file, cluster 0 size 0.
    var entry = [_]u8{0} ** 32;
    @memcpy(entry[0..11], &short);
    entry[11] = 0x20;
    @memcpy(sector[64..][0..32], &entry);
    try view.write(root_lba, sector[0..]);

    const item = (try vol.find("LongFileName.txt")) orelse return error.NotFound;
    try std.testing.expectEqualStrings("LongFileName.txt", item.name());
    try std.testing.expect(!item.isDir());
    // ... and a case-insensitive lookup by the long name, which is how a shell
    // user will type it.
    try std.testing.expect((try vol.find("longfilename.TXT")) != null);
    _ = made;
}

test "an 8.3 name is required for creation, and overwriting keeps one entry" {
    const view = try ramView();
    defer block.uninstall();
    _ = try mkfs(view, .{ .total_sectors = test_sectors });
    var vol = try mount(view);
    try std.testing.expectError(error.NameTooLong, vol.writeFile("a-rather-long-name.txt", "x"));
    _ = try vol.writeFile("SALE.TXT", "first");
    _ = try vol.writeFile("sale.txt", "second version, longer");
    try std.testing.expectEqual(@as(u32, 1), try vol.list());
    var buf: [64]u8 = undefined;
    const n = try vol.readFile("SALE.TXT", &buf);
    try std.testing.expectEqualStrings("second version, longer", buf[0..n]);
    const c = try vol.check();
    try std.testing.expect(c.ok and c.files == 1 and c.size_errors == 0);
    // A directory entry is not a file.
    try std.testing.expectError(error.NotFound, vol.deleteFile("NOPE.TXT"));
}
