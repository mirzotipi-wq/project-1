//! ELF64/AArch64 program loader (phase 26).
//!
//! The parser is pure: it takes the bytes of an executable and either returns a
//! plan — entry point plus loadable segments with their permissions — or a
//! specific refusal. Nothing here touches memory, so every validation rule is
//! unit-tested on the host, where an off-by-one in a header offset is cheap to
//! find and impossible to debug from a serial line.
//!
//! The rules are deliberately strict, because a kernel that trusts a file is a
//! kernel that runs whatever the file says:
//!
//!   * it must be ELF64, little-endian, ET_EXEC, EM_AARCH64;
//!   * every PT_LOAD must fit inside the file and inside the user window;
//!   * `p_filesz` can never exceed `p_memsz` (the difference is BSS, zeroed by
//!     the loader, never read from the file);
//!   * no segment may be writable and executable at the same time;
//!   * segments may not overlap, and the entry point must land in one that is
//!     executable.
//!
//! Everything the loader later does is a consequence of this plan, so a bad
//! image is refused before a single page is allocated.

const std = @import("std");

pub const max_segments: usize = 6;
pub const max_program_headers: usize = 16;
pub const ehdr_size: usize = 64;
pub const phdr_size: usize = 56;

/// The complete user window. Segments must sit inside it, which is also what
/// keeps a malicious image from asking to be mapped over the kernel.
pub const window_base: usize = 0x8000_0000;
pub const window_end: usize = 0x8800_0000;
pub const page_size: usize = 4096;

pub const Error = error{
    BadMagic,
    BadClass,
    BadEndian,
    BadType,
    BadMachine,
    BadHeader,
    Truncated,
    NoSegments,
    TooManySegments,
    BadSegment,
    OverlappingSegments,
    WriteExecute,
    OutOfRange,
    EntryOutside,
};

pub const Segment = struct {
    vaddr: usize = 0,
    memsz: usize = 0,
    filesz: usize = 0,
    offset: usize = 0,
    read: bool = false,
    write: bool = false,
    exec: bool = false,
};

pub const Image = struct {
    entry: usize = 0,
    segments: [max_segments]Segment = [_]Segment{.{}} ** max_segments,
    count: u8 = 0,
    /// Bytes that come from the file (sum of p_filesz).
    file_bytes: usize = 0,
    /// Bytes the process will see (sum of p_memsz), BSS included.
    memory_bytes: usize = 0,
    /// Of those, the part that has no file contents and is zeroed.
    bss_bytes: usize = 0,
};

fn u16At(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn u32At(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn u64At(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

/// Parse an executable into a load plan. No allocation, no side effects.
pub fn parse(file: []const u8) Error!Image {
    if (file.len < ehdr_size) return Error.Truncated;
    if (!std.mem.eql(u8, file[0..4], "\x7fELF")) return Error.BadMagic;
    if (file[4] != 2) return Error.BadClass; // ELFCLASS64
    if (file[5] != 1) return Error.BadEndian; // little-endian
    if (file[6] != 1) return Error.BadHeader; // EV_CURRENT
    if (u16At(file, 16) != 2) return Error.BadType; // ET_EXEC
    if (u16At(file, 18) != 183) return Error.BadMachine; // EM_AARCH64

    const entry: usize = @intCast(u64At(file, 24));
    const phoff: usize = @intCast(u64At(file, 32));
    const phentsize = u16At(file, 54);
    const phnum = u16At(file, 56);

    if (phentsize != phdr_size) return Error.BadHeader;
    if (phnum == 0 or phnum > max_program_headers) return Error.TooManySegments;
    const table_end = phoff + @as(usize, phnum) * phdr_size;
    if (table_end < phoff or table_end > file.len) return Error.Truncated;

    var img = Image{ .entry = entry };
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phdr_size;
        const kind = u32At(file, ph);
        if (kind != 1) continue; // only PT_LOAD describes memory
        const flags = u32At(file, ph + 4);
        const offset: usize = @intCast(u64At(file, ph + 8));
        const vaddr: usize = @intCast(u64At(file, ph + 16));
        const filesz: usize = @intCast(u64At(file, ph + 32));
        const memsz: usize = @intCast(u64At(file, ph + 40));
        const p_align = u64At(file, ph + 48);

        if (filesz > memsz) return Error.BadSegment;
        if (offset > file.len or filesz > file.len - offset) return Error.Truncated;
        if (memsz == 0) continue;
        if (img.count >= max_segments) return Error.TooManySegments;

        const seg = Segment{
            .vaddr = vaddr,
            .memsz = memsz,
            .filesz = filesz,
            .offset = offset,
            .read = (flags & 0b100) != 0,
            .write = (flags & 0b010) != 0,
            .exec = (flags & 0b001) != 0,
        };
        // W^X is a property of the image, not a promise from the loader.
        if (seg.write and seg.exec) return Error.WriteExecute;
        // `p_align` is a congruence requirement, not a page-size ceiling: Zig
        // links the first segment at 64 KiB. What matters is that the file
        // offset and the virtual address agree modulo the page size, so the
        // bytes land where the segment says.
        if (p_align != 0 and (p_align & (p_align - 1)) != 0) return Error.BadSegment;
        if ((vaddr & (page_size - 1)) != (offset & (page_size - 1))) return Error.BadSegment;
        if (vaddr < window_base or memsz > window_end - vaddr) return Error.OutOfRange;
        // A segment that overlaps another would make the second mapping depend
        // on link order; refuse instead of picking a winner.
        for (img.segments[0..img.count]) |other| {
            if (vaddr < other.vaddr + other.memsz and other.vaddr < vaddr + memsz) {
                return Error.OverlappingSegments;
            }
        }

        img.segments[img.count] = seg;
        img.count += 1;
        img.file_bytes += filesz;
        img.memory_bytes += memsz;
        img.bss_bytes += memsz - filesz;
    }
    if (img.count == 0) return Error.NoSegments;

    // The first instruction has to come from something executable, otherwise
    // the very first fetch after the privilege drop would fault.
    var entry_ok = false;
    for (img.segments[0..img.count]) |seg| {
        if (seg.exec and entry >= seg.vaddr and entry < seg.vaddr + seg.memsz) entry_ok = true;
    }
    if (!entry_ok) return Error.EntryOutside;
    return img;
}

/// A human-readable name for a refusal, used in logs and by the shell.
pub fn errorLabel(e: Error) []const u8 {
    return switch (e) {
        error.BadMagic => "bad magic",
        error.BadClass => "not ELF64",
        error.BadEndian => "not little-endian",
        error.BadType => "not an executable",
        error.BadMachine => "not AArch64",
        error.BadHeader => "malformed header",
        error.Truncated => "truncated",
        error.NoSegments => "no loadable segments",
        error.TooManySegments => "too many segments",
        error.BadSegment => "bad segment",
        error.OverlappingSegments => "overlapping segments",
        error.WriteExecute => "writable and executable segment",
        error.OutOfRange => "segment outside the user window",
        error.EntryOutside => "entry point outside an executable segment",
    };
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a minimal but valid ELF image with `n` loadable segments.
fn buildImage(buf: []u8, segs: []const Segment) []u8 {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2; // ELFCLASS64
    buf[5] = 1; // little-endian
    buf[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, buf[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, buf[18..20], 183, .little); // EM_AARCH64
    std.mem.writeInt(u64, buf[24..32], segs[0].vaddr, .little); // entry
    std.mem.writeInt(u64, buf[32..40], ehdr_size, .little); // phoff
    std.mem.writeInt(u16, buf[52..54], ehdr_size, .little);
    std.mem.writeInt(u16, buf[54..56], phdr_size, .little);
    std.mem.writeInt(u16, buf[56..58], @intCast(segs.len), .little);
    for (segs, 0..) |s, i| {
        const ph = ehdr_size + i * phdr_size;
        std.mem.writeInt(u32, buf[ph..][0..4], 1, .little); // PT_LOAD
        var flags: u32 = 0;
        if (s.read) flags |= 0b100;
        if (s.write) flags |= 0b010;
        if (s.exec) flags |= 0b001;
        std.mem.writeInt(u32, buf[ph + 4 ..][0..4], flags, .little);
        std.mem.writeInt(u64, buf[ph + 8 ..][0..8], s.offset, .little);
        std.mem.writeInt(u64, buf[ph + 16 ..][0..8], s.vaddr, .little);
        std.mem.writeInt(u64, buf[ph + 32 ..][0..8], s.filesz, .little);
        std.mem.writeInt(u64, buf[ph + 40 ..][0..8], s.memsz, .little);
        std.mem.writeInt(u64, buf[ph + 48 ..][0..8], 4096, .little);
    }
    // The slice must cover every segment's file contents, or the parser would
    // (correctly) refuse the image as truncated.
    var total = ehdr_size + segs.len * phdr_size;
    for (segs) |s| total = @max(total, s.offset + s.filesz);
    return buf[0..total];
}

test "a well-formed image parses into a load plan" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{
        .{ .vaddr = 0x8000_0000, .memsz = 0x2000, .filesz = 0x1000, .offset = 0, .read = true, .exec = true },
        .{ .vaddr = 0x8100_0000, .memsz = 0x3000, .filesz = 0x1000, .offset = 0x1000, .read = true, .write = true },
    };
    const img = try parse(buildImage(&buf, &segs));
    try testing.expectEqual(@as(usize, 0x8000_0000), img.entry);
    try testing.expectEqual(@as(u8, 2), img.count);
    try testing.expectEqual(@as(usize, 0x5000), img.memory_bytes);
    try testing.expectEqual(@as(usize, 0x2000), img.file_bytes);
    // BSS is the difference, and it is exactly what the loader must zero.
    try testing.expectEqual(@as(usize, 0x3000), img.bss_bytes);
    try testing.expect(img.segments[0].exec and !img.segments[0].write);
    try testing.expect(img.segments[1].write and !img.segments[1].exec);
}

test "bad magic, class, endianness, type and machine are refused" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    const good = buildImage(&buf, &segs);

    var copy: [8192]u8 = undefined;
    @memcpy(copy[0..good.len], good);

    copy[1] = 'X';
    try testing.expectError(error.BadMagic, parse(copy[0..good.len]));
    copy[1] = 'E';

    copy[4] = 1; // ELFCLASS32
    try testing.expectError(error.BadClass, parse(copy[0..good.len]));
    copy[4] = 2;

    copy[5] = 2; // big-endian
    try testing.expectError(error.BadEndian, parse(copy[0..good.len]));
    copy[5] = 1;

    std.mem.writeInt(u16, copy[16..18], 3, .little); // ET_DYN
    try testing.expectError(error.BadType, parse(copy[0..good.len]));
    std.mem.writeInt(u16, copy[16..18], 2, .little);

    std.mem.writeInt(u16, copy[18..20], 62, .little); // x86-64
    try testing.expectError(error.BadMachine, parse(copy[0..good.len]));
}

test "a truncated header or program table is refused" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    const good = buildImage(&buf, &segs);
    try testing.expectError(error.Truncated, parse(good[0..32]));
    try testing.expectError(error.Truncated, parse(good[0 .. ehdr_size + 8]));
}

test "a segment may not claim more file bytes than the file has" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    _ = buildImage(&buf, &segs);
    std.mem.writeInt(u64, buf[ehdr_size + 8 ..][0..8], 0x7000, .little); // offset
    std.mem.writeInt(u64, buf[ehdr_size + 32 ..][0..8], 0x1000, .little); // filesz
    std.mem.writeInt(u64, buf[ehdr_size + 40 ..][0..8], 0x2000, .little); // memsz
    try testing.expectError(error.Truncated, parse(buf[0 .. ehdr_size + phdr_size]));
}

test "a writable and executable segment is refused" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .write = true, .exec = true }};
    try testing.expectError(error.WriteExecute, parse(buildImage(&buf, &segs)));
}

test "segments outside the user window are refused" {
    var buf: [8192]u8 = undefined;
    // Below the window: that is kernel memory.
    const low = [_]Segment{.{ .vaddr = 0x4000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    try testing.expectError(error.OutOfRange, parse(buildImage(&buf, &low)));
    // Past the end of the window.
    const high = [_]Segment{.{ .vaddr = 0x87FF_F000, .memsz = 0x2000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    try testing.expectError(error.OutOfRange, parse(buildImage(&buf, &high)));
}

test "overlapping segments are refused" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{
        .{ .vaddr = 0x8000_0000, .memsz = 0x2000, .filesz = 0x100, .offset = 0, .read = true, .exec = true },
        // Congruent with the page size, so the overlap is what is wrong here.
        .{ .vaddr = 0x8000_1000, .memsz = 0x1000, .filesz = 0x100, .offset = 0x1000, .read = true, .write = true },
    };
    try testing.expectError(error.OverlappingSegments, parse(buildImage(&buf, &segs)));
}

test "the entry point must be inside an executable segment" {
    var buf: [8192]u8 = undefined;
    // No file contents: the segment is all BSS, so the slice is just the headers.
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0, .offset = 0, .read = true, .exec = true }};
    _ = buildImage(&buf, &segs);
    std.mem.writeInt(u64, buf[24..32], 0x8000_9000, .little);
    try testing.expectError(error.EntryOutside, parse(buf[0 .. ehdr_size + phdr_size]));
    // Entry at the very end of the segment is one past the last byte.
    std.mem.writeInt(u64, buf[24..32], 0x8000_1000, .little);
    try testing.expectError(error.EntryOutside, parse(buf[0 .. ehdr_size + phdr_size]));
    std.mem.writeInt(u64, buf[24..32], 0x8000_0FFC, .little);
    const img = try parse(buf[0 .. ehdr_size + phdr_size]);
    try testing.expectEqual(@as(usize, 0x8000_0FFC), img.entry);
}

test "a program header table with no PT_LOAD is refused" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    _ = buildImage(&buf, &segs);
    std.mem.writeInt(u32, buf[ehdr_size..][0..4], 4, .little); // PT_NOTE
    try testing.expectError(error.NoSegments, parse(buf[0 .. ehdr_size + phdr_size]));
}

test "filesz larger than memsz is refused" {
    var buf: [8192]u8 = undefined;
    const segs = [_]Segment{.{ .vaddr = 0x8000_0000, .memsz = 0x1000, .filesz = 0x100, .offset = 0, .read = true, .exec = true }};
    _ = buildImage(&buf, &segs);
    std.mem.writeInt(u64, buf[ehdr_size + 32 ..][0..8], 0x2000, .little);
    try testing.expectError(error.BadSegment, parse(buf[0 .. ehdr_size + phdr_size]));
}
