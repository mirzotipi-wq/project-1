//! Phase 53 font engine.
//!
//! The embedded face is a 100-glyph DejaVu Sans subset (printable ASCII plus
//! euro, pound, yen and degree) stored as ordinary Zig bytes in `font_data.zig`.
//! This module parses only the tables it needs — head, maxp, hhea, hmtx, cmap
//! format 4, loca, glyf and legacy kern format 0 — and rasterizes simple
//! quadratic contours with a fixed-point 4x vertical scanline coverage pass.
//! Composite glyphs are deliberately not guessed at: they fall back to the
//! phase-37 5x7 bitmap face, as do unsupported codepoints.
//!
//! There is no allocation, no floating point and no second graphics path. A
//! `Renderer` owns a bounded 64-entry coverage cache and its scratch memory, so
//! the kernel can place one in `.bss` and use the existing `gfx.Surface` and
//! `raster2d` colour compositor.

const std = @import("std");
const gfx = @import("gfx.zig");
const font5x7 = @import("font5x7.zig");
const embedded = @import("font_data.zig");

pub const Error = error{
    BadFont,
    BadGlyph,
    CompositeGlyph,
    TooManyPoints,
    TooManyContours,
    TooManySegments,
    GlyphTooLarge,
    NonZeroWinding,
};

pub const max_points: usize = 1024;
pub const max_contours: usize = 32;
pub const max_path_points: usize = 2048;
pub const max_segments: usize = 1536;
pub const max_glyph_px: usize = 64;
pub const max_glyph_area: usize = max_glyph_px * max_glyph_px;
pub const max_cache_entries: usize = 64;
pub const max_text_codepoints: usize = 256;

pub const embedded_font: []const u8 = &embedded.ttf;

fn u8At(data: []const u8, off: usize) Error!u8 {
    if (off >= data.len) return error.BadFont;
    return data[off];
}

fn u16At(data: []const u8, off: usize) Error!u16 {
    if (off + 2 > data.len) return error.BadFont;
    return (@as(u16, data[off]) << 8) | data[off + 1];
}

fn i16At(data: []const u8, off: usize) Error!i16 {
    return @bitCast(try u16At(data, off));
}

fn u32At(data: []const u8, off: usize) Error!u32 {
    if (off + 4 > data.len) return error.BadFont;
    return (@as(u32, data[off]) << 24) |
        (@as(u32, data[off + 1]) << 16) |
        (@as(u32, data[off + 2]) << 8) |
        data[off + 3];
}

fn tagAt(data: []const u8, off: usize) Error![]const u8 {
    if (off + 4 > data.len) return error.BadFont;
    return data[off .. off + 4];
}

fn isTag(tag: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, tag, want);
}

fn findTable(data: []const u8, want: []const u8) Error!?[]const u8 {
    if (data.len < 12) return error.BadFont;
    const count = try u16At(data, 4);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = 12 + i * 16;
        if (rec + 16 > data.len) return error.BadFont;
        if (isTag(try tagAt(data, rec), want)) {
            const offset = try u32At(data, rec + 8);
            const length = try u32At(data, rec + 12);
            const end = @as(u64, offset) + length;
            if (end > data.len) return error.BadFont;
            return data[offset..end];
        }
    }
    return null;
}

/// Choose the best Unicode BMP cmap subtable that has format 4.
fn findCmap4(cmap: []const u8) Error![]const u8 {
    if (cmap.len < 4) return error.BadFont;
    const count = try u16At(cmap, 2);
    var best: ?[]const u8 = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = 4 + i * 8;
        if (rec + 8 > cmap.len) return error.BadFont;
        const platform = try u16At(cmap, rec);
        const encoding = try u16At(cmap, rec + 2);
        const offset = try u32At(cmap, rec + 4);
        if (offset + 2 > cmap.len) return error.BadFont;
        const format = try u16At(cmap, @intCast(offset));
        if (format != 4) continue;
        const usable = (platform == 3 and (encoding == 1 or encoding == 10)) or platform == 0;
        if (!usable) continue;
        if (best == null or platform == 3) best = cmap[offset..];
    }
    return best orelse error.BadFont;
}

/// Find the first horizontal format-0 kern subtable. Other formats are ignored
/// rather than misread.
fn findKern0(kern: ?[]const u8) Error!?[]const u8 {
    const table = kern orelse return null;
    if (table.len < 4) return null;
    const count = try u16At(table, 2);
    var off: usize = 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (off + 6 > table.len) return null;
        const length = try u16At(table, off + 2);
        const coverage = try u16At(table, off + 4);
        if (length < 14 or off + length > table.len) return null;
        const format = coverage >> 8;
        const horizontal = (coverage & 1) != 0;
        if (format == 0 and horizontal) return table[off .. off + length];
        off += length;
    }
    return null;
}

pub const OutlinePoint = struct {
    x: i32,
    y: i32,
    on: bool,
};

pub const Outline = struct {
    points: [max_points]OutlinePoint = undefined,
    ends: [max_contours]u16 = undefined,
    point_count: u16 = 0,
    contour_count: u16 = 0,
    x_min: i32 = 0,
    y_min: i32 = 0,
    x_max: i32 = 0,
    y_max: i32 = 0,
};

pub const Font = struct {
    data: []const u8,
    cmap: []const u8,
    loca: []const u8,
    glyf: []const u8,
    hmtx: []const u8,
    kern_table: ?[]const u8,
    units_per_em: u16,
    num_glyphs: u16,
    num_hmetrics: u16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    index_to_loc_format: i16,

    pub fn init(data: []const u8) Error!Font {
        if (data.len < 12) return error.BadFont;
        const version = try u32At(data, 0);
        if (version != 0x00010000 and version != 0x74727565) return error.BadFont;
        const head = (try findTable(data, "head")) orelse return error.BadFont;
        const maxp = (try findTable(data, "maxp")) orelse return error.BadFont;
        const hhea = (try findTable(data, "hhea")) orelse return error.BadFont;
        const hmtx = (try findTable(data, "hmtx")) orelse return error.BadFont;
        const cmap_table = (try findTable(data, "cmap")) orelse return error.BadFont;
        const loca = (try findTable(data, "loca")) orelse return error.BadFont;
        const glyf = (try findTable(data, "glyf")) orelse return error.BadFont;
        if (head.len < 54 or maxp.len < 6 or hhea.len < 36) return error.BadFont;
        const units = try u16At(head, 18);
        if (units < 16 or units > 16384) return error.BadFont;
        const num_glyphs = try u16At(maxp, 4);
        if (num_glyphs == 0) return error.BadFont;
        const loca_format = try i16At(head, 50);
        if (loca_format != 0 and loca_format != 1) return error.BadFont;
        const loca_needed = if (loca_format == 0) (@as(usize, num_glyphs) + 1) * 2 else (@as(usize, num_glyphs) + 1) * 4;
        if (loca.len < loca_needed) return error.BadFont;
        const num_hmetrics = try u16At(hhea, 34);
        if (num_hmetrics == 0 or hmtx.len < @as(usize, num_hmetrics) * 4) return error.BadFont;
        const cmap = try findCmap4(cmap_table);
        const kern_table = try findKern0(try findTable(data, "kern"));
        return .{
            .data = data,
            .cmap = cmap,
            .loca = loca,
            .glyf = glyf,
            .hmtx = hmtx,
            .kern_table = kern_table,
            .units_per_em = units,
            .num_glyphs = num_glyphs,
            .num_hmetrics = num_hmetrics,
            .ascent = try i16At(hhea, 4),
            .descent = try i16At(hhea, 6),
            .line_gap = try i16At(hhea, 8),
            .index_to_loc_format = loca_format,
        };
    }

    pub fn scaleQ16(self: *const Font, px: u16) i64 {
        return @divTrunc(@as(i64, px) * 65536 + @divTrunc(@as(i64, self.units_per_em), 2), @as(i64, self.units_per_em));
    }

    fn clampI32(v: i64) i32 {
        if (v > std.math.maxInt(i32)) return std.math.maxInt(i32);
        if (v < std.math.minInt(i32)) return std.math.minInt(i32);
        return @intCast(v);
    }

    pub fn glyphIndex(self: *const Font, cp: u21) ?u16 {
        if (cp > 0xFFFF) return null;
        const code: u16 = @intCast(cp);
        if (self.cmap.len < 14) return null;
        const seg_count = (@as(usize, u16At(self.cmap, 6) catch return null)) / 2;
        if (seg_count == 0) return null;
        const end_base: usize = 14;
        const start_base = end_base + seg_count * 2 + 2;
        const delta_base = start_base + seg_count * 2;
        const range_base = delta_base + seg_count * 2;
        if (range_base + seg_count * 2 > self.cmap.len) return null;
        var i: usize = 0;
        while (i < seg_count) : (i += 1) {
            const end = u16At(self.cmap, end_base + i * 2) catch return null;
            if (code > end) continue;
            const start = u16At(self.cmap, start_base + i * 2) catch return null;
            if (code < start) return null;
            const delta = u16At(self.cmap, delta_base + i * 2) catch return null;
            const range = u16At(self.cmap, range_base + i * 2) catch return null;
            var gid: u16 = 0;
            if (range == 0) {
                gid = code +% delta;
            } else {
                const address = range_base + i * 2 + range + (code - start) * 2;
                const raw = u16At(self.cmap, address) catch return null;
                if (raw != 0) gid = raw +% delta;
            }
            if (gid == 0 or gid >= self.num_glyphs) return null;
            return gid;
        }
        return null;
    }

    pub fn advanceFont(self: *const Font, gid: u16) u16 {
        if (gid >= self.num_glyphs) return 0;
        const index = @min(gid, self.num_hmetrics - 1);
        return u16At(self.hmtx, @as(usize, index) * 4) catch 0;
    }

    pub fn advanceQ16(self: *const Font, gid: u16, px: u16) i32 {
        const adv = self.advanceFont(gid);
        return clampI32(@as(i64, adv) * self.scaleQ16(px));
    }

    pub fn ascentQ16(self: *const Font, px: u16) i32 {
        return clampI32(@as(i64, self.ascent) * self.scaleQ16(px));
    }

    pub fn lineHeightQ16(self: *const Font, px: u16) i32 {
        const h = @as(i64, self.ascent) - self.descent + self.line_gap;
        return clampI32(h * self.scaleQ16(px));
    }

    /// Legacy kern format 0. The subset's 220 pairs are sorted; binary search
    /// keeps lookup cheap without allocating a hash table.
    pub fn kern(self: *const Font, left: u16, right: u16) i16 {
        const table = self.kern_table orelse return 0;
        if (table.len < 14) return 0;
        const count = u16At(table, 6) catch return 0;
        var lo: usize = 0;
        var hi: usize = count;
        const key = (@as(u32, left) << 16) | right;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const off = 14 + mid * 6;
            const pair_key = (@as(u32, u16At(table, off) catch return 0) << 16) |
                (u16At(table, off + 2) catch return 0);
            if (pair_key == key) return i16At(table, off + 4) catch 0;
            if (pair_key < key) lo = mid + 1 else hi = mid;
        }
        return 0;
    }

    pub fn kernQ16(self: *const Font, left: u16, right: u16, px: u16) i32 {
        return clampI32(@as(i64, self.kern(left, right)) * self.scaleQ16(px));
    }

    pub fn kernPairCount(self: *const Font) u16 {
        const table = self.kern_table orelse return 0;
        return u16At(table, 6) catch 0;
    }

    fn locate(self: *const Font, gid: u16) Error!usize {
        if (gid >= self.num_glyphs) return error.BadGlyph;
        if (self.index_to_loc_format == 0) {
            return @as(usize, try u16At(self.loca, @as(usize, gid) * 2)) * 2;
        }
        return @intCast(try u32At(self.loca, @as(usize, gid) * 4));
    }

    fn nextLocate(self: *const Font, gid: u16) Error!usize {
        if (gid + 1 > self.num_glyphs) return error.BadGlyph;
        if (self.index_to_loc_format == 0) {
            return @as(usize, try u16At(self.loca, @as(usize, gid + 1) * 2)) * 2;
        }
        return @intCast(try u32At(self.loca, @as(usize, gid + 1) * 4));
    }

    /// Parse a simple glyph. Composite glyphs return `CompositeGlyph`; the
    /// embedded subset contains none, and callers use the bitmap fallback
    /// rather than silently drawing a partial accented character.
    pub fn outline(self: *const Font, gid: u16, out: *Outline) Error!void {
        out.point_count = 0;
        out.contour_count = 0;
        const start = try self.locate(gid);
        const end = try self.nextLocate(gid);
        if (end < start or end > self.glyf.len) return error.BadGlyph;
        if (end == start) return;
        if (start + 10 > end) return error.BadGlyph;
        const contours = try i16At(self.glyf, start);
        if (contours < 0) return error.CompositeGlyph;
        if (contours == 0) return;
        if (contours > max_contours) return error.TooManyContours;
        const contour_count: usize = @intCast(contours);
        var off = start + 10;
        if (off + contour_count * 2 + 2 > end) return error.BadGlyph;
        var last_end: i32 = -1;
        var i: usize = 0;
        while (i < contour_count) : (i += 1) {
            const e = try u16At(self.glyf, off);
            if (@as(i32, e) <= last_end) return error.BadGlyph;
            if (e >= max_points) return error.TooManyPoints;
            out.ends[i] = e;
            last_end = e;
            off += 2;
        }
        const total: usize = @as(usize, out.ends[contour_count - 1]) + 1;
        if (total > max_points) return error.TooManyPoints;
        const instruction_len = try u16At(self.glyf, off);
        off += 2 + instruction_len;
        if (off > end) return error.BadGlyph;

        var flags: [max_points]u8 = undefined;
        var p: usize = 0;
        while (p < total) {
            const flag = try u8At(self.glyf, off);
            off += 1;
            flags[p] = flag;
            p += 1;
            if ((flag & 0x08) != 0) {
                const repeat = try u8At(self.glyf, off);
                off += 1;
                var r: usize = 0;
                while (r < repeat and p < total) : (r += 1) {
                    flags[p] = flag;
                    p += 1;
                }
            }
        }

        var x: i32 = 0;
        p = 0;
        while (p < total) : (p += 1) {
            const flag = flags[p];
            if ((flag & 0x02) != 0) {
                const d: i32 = try u8At(self.glyf, off);
                off += 1;
                x += if ((flag & 0x10) != 0) d else -d;
            } else if ((flag & 0x10) == 0) {
                x += try i16At(self.glyf, off);
                off += 2;
            }
            out.points[p].x = x;
        }
        var y: i32 = 0;
        p = 0;
        while (p < total) : (p += 1) {
            const flag = flags[p];
            if ((flag & 0x04) != 0) {
                const d: i32 = try u8At(self.glyf, off);
                off += 1;
                y += if ((flag & 0x20) != 0) d else -d;
            } else if ((flag & 0x20) == 0) {
                y += try i16At(self.glyf, off);
                off += 2;
            }
            out.points[p].y = y;
            out.points[p].on = (flags[p] & 1) != 0;
        }
        if (off > end) return error.BadGlyph;

        out.point_count = @intCast(total);
        out.contour_count = @intCast(contour_count);
        out.x_min = out.points[0].x;
        out.x_max = out.points[0].x;
        out.y_min = out.points[0].y;
        out.y_max = out.points[0].y;
        p = 1;
        while (p < total) : (p += 1) {
            out.x_min = @min(out.x_min, out.points[p].x);
            out.x_max = @max(out.x_max, out.points[p].x);
            out.y_min = @min(out.y_min, out.points[p].y);
            out.y_max = @max(out.y_max, out.points[p].y);
        }
    }
};

const PathPoint = struct {
    x: i32,
    y: i32,
    on: bool,
};

const Segment = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

const Crossing = struct {
    x: i64,
    dir: i8,
};

const Bounds = struct {
    min_x: i64 = std.math.maxInt(i64),
    min_y: i64 = std.math.maxInt(i64),
    max_x: i64 = std.math.minInt(i64),
    max_y: i64 = std.math.minInt(i64),
};

const Raster = struct {
    left: i16,
    top: i16,
    width: u16,
    height: u16,
};

const Scratch = struct {
    outline: Outline = undefined,
    path: [max_path_points]PathPoint = undefined,
    segments: [max_segments]Segment = undefined,
    crossings: [max_segments]Crossing = undefined,
    coverage: [max_glyph_area]u16 = undefined,
    coverage8: [max_glyph_area]u8 = undefined,
    segment_count: usize = 0,
    bounds: Bounds = .{},
};

fn transformPoint(p: OutlinePoint, scale: i64, phase: u8) PathPoint {
    const fx = @as(i64, p.x) * scale + @as(i64, phase) * 16384;
    const fy = -@as(i64, p.y) * scale;
    return .{ .x = Font.clampI32(fx), .y = Font.clampI32(fy), .on = p.on };
}

fn midPoint(a: PathPoint, b: PathPoint) PathPoint {
    return .{
        .x = @intCast(@divTrunc(@as(i64, a.x) + b.x, 2)),
        .y = @intCast(@divTrunc(@as(i64, a.y) + b.y, 2)),
        .on = true,
    };
}

fn appendSegment(scratch: *Scratch, a: PathPoint, b: PathPoint) Error!void {
    if (a.x == b.x and a.y == b.y) return;
    if (scratch.segment_count >= max_segments) return error.TooManySegments;
    scratch.segments[scratch.segment_count] = .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y };
    scratch.segment_count += 1;
}

fn appendQuad(scratch: *Scratch, p0: PathPoint, p1: PathPoint, p2: PathPoint, depth: u8) Error!void {
    if (depth >= 6) {
        try appendSegment(scratch, p0, p2);
        return;
    }
    const dx = @as(i64, p2.x) - p0.x;
    const dy = @as(i64, p2.y) - p0.y;
    const cx = @as(i64, p1.x) - p0.x;
    const cy = @as(i64, p1.y) - p0.y;
    const cross = dx * cy - dy * cx;
    const len2 = dx * dx + dy * dy;
    // Flatness tolerance is 1/16 px in Q16. Cross products are widened to
    // i128 so a 48 px curve cannot overflow the comparison.
    const tol: i128 = 4096;
    if (@as(i128, cross) * cross <= @as(i128, len2) * tol * tol) {
        try appendSegment(scratch, p0, p2);
        return;
    }
    const p01 = midPoint(p0, p1);
    const p12 = midPoint(p1, p2);
    const p012 = midPoint(p01, p12);
    try appendQuad(scratch, p0, p01, p012, depth + 1);
    try appendQuad(scratch, p012, p12, p2, depth + 1);
}

fn flattenContour(font: *const Font, outline: *const Outline, contour: usize, scale: i64, phase: u8, scratch: *Scratch) Error!void {
    _ = font;
    const raw_start: usize = if (contour == 0) 0 else @as(usize, outline.ends[contour - 1]) + 1;
    const raw_end: usize = outline.ends[contour];
    const raw_count = raw_end - raw_start + 1;
    if (raw_count == 0) return;

    var n: usize = 0;
    var i: usize = raw_start;
    while (i <= raw_end) : (i += 1) {
        const p = transformPoint(outline.points[i], scale, phase);
        if (n >= max_path_points) return error.TooManyPoints;
        scratch.path[n] = p;
        n += 1;
        const j = if (i == raw_end) raw_start else i + 1;
        const q = transformPoint(outline.points[j], scale, phase);
        if (!p.on and !q.on) {
            if (n >= max_path_points) return error.TooManyPoints;
            scratch.path[n] = midPoint(p, q);
            n += 1;
        }
    }

    var start: ?usize = null;
    for (scratch.path[0..n], 0..) |p, idx| {
        if (p.on) {
            start = idx;
            break;
        }
    }
    const s = start orelse return error.BadGlyph;

    var step: usize = 0;
    var cur = s;
    while (step < n) {
        const next = (cur + 1) % n;
        if (scratch.path[next].on) {
            try appendSegment(scratch, scratch.path[cur], scratch.path[next]);
            step += 1;
            cur = next;
        } else {
            const end = (next + 1) % n;
            if (!scratch.path[end].on) return error.BadGlyph;
            try appendQuad(scratch, scratch.path[cur], scratch.path[next], scratch.path[end], 0);
            step += 2;
            cur = end;
        }
        if (step > n) return error.BadGlyph;
    }

    for (scratch.path[0..n]) |p| {
        scratch.bounds.min_x = @min(scratch.bounds.min_x, p.x);
        scratch.bounds.min_y = @min(scratch.bounds.min_y, p.y);
        scratch.bounds.max_x = @max(scratch.bounds.max_x, p.x);
        scratch.bounds.max_y = @max(scratch.bounds.max_y, p.y);
    }
}

fn addSpan(cov: []u16, width: usize, origin_x: i64, xa_in: i64, xb_in: i64) void {
    const xa = @min(xa_in, xb_in);
    const xb = @max(xa_in, xb_in);
    if (xb <= xa) return;
    const first = @divFloor(xa, 65536);
    const last = @divFloor(xb + 65535, 65536);
    var p = @max(first, origin_x);
    const end = @min(last, origin_x + @as(i64, @intCast(width)));
    while (p < end) : (p += 1) {
        const a = @max(xa, p * 65536);
        const b = @min(xb, (p + 1) * 65536);
        if (b > a) {
            const add = (@as(u64, @intCast(b - a)) * 255 + 2 * 65536) / (4 * 65536);
            const idx: usize = @intCast(p - origin_x);
            cov[idx] += @intCast(add);
        }
    }
}

fn crossingLess(_: void, a: Crossing, b: Crossing) bool {
    if (a.x == b.x) return a.dir < b.dir;
    return a.x < b.x;
}

fn rasterize(font: *const Font, scale: i64, phase: u8, scratch: *Scratch) Error!Raster {
    scratch.segment_count = 0;
    scratch.bounds = .{};
    var contour: usize = 0;
    while (contour < scratch.outline.contour_count) : (contour += 1) {
        try flattenContour(font, &scratch.outline, contour, scale, phase, scratch);
    }
    if (scratch.segment_count == 0) return .{ .left = 0, .top = 0, .width = 0, .height = 0 };

    const x0 = @divFloor(scratch.bounds.min_x, 65536);
    const x1 = @divFloor(scratch.bounds.max_x + 65535, 65536);
    const y0 = @divFloor(scratch.bounds.min_y, 65536);
    const y1 = @divFloor(scratch.bounds.max_y + 65535, 65536);
    const wi = x1 - x0;
    const hi = y1 - y0;
    if (wi <= 0 or hi <= 0) return .{ .left = 0, .top = 0, .width = 0, .height = 0 };
    if (wi > max_glyph_px or hi > max_glyph_px) return error.GlyphTooLarge;
    const w: usize = @intCast(wi);
    const h: usize = @intCast(hi);
    const area = w * h;
    @memset(scratch.coverage[0..area], 0);

    var row: usize = 0;
    while (row < h) : (row += 1) {
        var sub: i64 = 0;
        while (sub < 4) : (sub += 1) {
            const ys = (y0 + @as(i64, @intCast(row))) * 65536 + 8192 + sub * 16384;
            var count: usize = 0;
            for (scratch.segments[0..scratch.segment_count]) |s| {
                const sy0: i64 = s.y0;
                const sy1: i64 = s.y1;
                const inside = (sy0 <= ys and ys < sy1) or (sy1 <= ys and ys < sy0);
                if (!inside) continue;
                const t = @divTrunc((ys - sy0) * 65536, sy1 - sy0);
                const x = @as(i64, s.x0) + @divTrunc((@as(i64, s.x1) - s.x0) * t, 65536);
                if (count >= max_segments) return error.TooManySegments;
                scratch.crossings[count] = .{ .x = x, .dir = if (sy1 > sy0) 1 else -1 };
                count += 1;
            }
            if (count < 2) continue;
            std.mem.sort(Crossing, scratch.crossings[0..count], {}, crossingLess);
            var wind: i32 = 0;
            var span: i64 = 0;
            for (scratch.crossings[0..count]) |c| {
                if (wind == 0) span = c.x;
                wind += c.dir;
                if (wind == 0) addSpan(scratch.coverage[row * w .. row * w + w], w, x0, span, c.x);
            }
            if (wind != 0) return error.NonZeroWinding;
        }
    }
    var idx: usize = 0;
    while (idx < area) : (idx += 1) {
        scratch.coverage8[idx] = @intCast(@min(scratch.coverage[idx], 255));
    }
    return .{
        .left = @intCast(x0),
        .top = @intCast(y0),
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

pub const Entry = struct {
    valid: bool = false,
    gid: u16 = 0,
    px: u16 = 0,
    phase: u8 = 0,
    used: u64 = 0,
    left: i16 = 0,
    top: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    advance: i32 = 0,
};

pub const Glyph = struct {
    left: i16,
    top: i16,
    width: u16,
    height: u16,
    advance: i32,
    pixels: []const u8,
};

pub const Renderer = struct {
    font: Font,
    entries: [max_cache_entries]Entry = undefined,
    bitmaps: [max_cache_entries][max_glyph_area]u8 = undefined,
    scratch: Scratch = undefined,
    clock: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn initInPlace(self: *Renderer, data: []const u8) Error!void {
        self.font = try Font.init(data);
        for (&self.entries) |*e| e.* = .{};
        self.clock = 0;
        self.hits = 0;
        self.misses = 0;
        self.evictions = 0;
    }

    fn glyphFromEntry(self: *Renderer, slot: usize) Glyph {
        const e = self.entries[slot];
        const area: usize = @as(usize, e.width) * e.height;
        return .{
            .left = e.left,
            .top = e.top,
            .width = e.width,
            .height = e.height,
            .advance = e.advance,
            .pixels = self.bitmaps[slot][0..area],
        };
    }

    /// Fetch a coverage glyph. A phase of 0..3 shifts the outline by 0, 1/4,
    /// 1/2 or 3/4 px before rasterizing, which is the subpixel positioning
    /// implemented here (four phases, not a full 1/64 pen grid).
    pub fn get(self: *Renderer, gid: u16, px: u16, phase: u8) ?Glyph {
        if (gid == 0 or gid >= self.font.num_glyphs or px == 0 or px > 96 or phase > 3) return null;
        var free: ?usize = null;
        var victim: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&self.entries, 0..) |*e, idx| {
            if (e.valid) {
                if (e.gid == gid and e.px == px and e.phase == phase) {
                    self.clock += 1;
                    e.used = self.clock;
                    self.hits += 1;
                    return self.glyphFromEntry(idx);
                }
                if (e.used < oldest) {
                    oldest = e.used;
                    victim = idx;
                }
            } else if (free == null) {
                free = idx;
            }
        }
        const slot = free orelse victim;
        if (self.entries[slot].valid) self.evictions += 1;
        self.misses += 1;

        const advance = self.font.advanceQ16(gid, px);
        self.font.outline(gid, &self.scratch.outline) catch return null;
        const r = rasterize(&self.font, self.font.scaleQ16(px), phase, &self.scratch) catch return null;
        const area: usize = @as(usize, r.width) * r.height;
        if (area > max_glyph_area) return null;
        if (area > 0) @memcpy(self.bitmaps[slot][0..area], self.scratch.coverage8[0..area]);
        self.clock += 1;
        self.entries[slot] = .{
            .valid = true,
            .gid = gid,
            .px = px,
            .phase = phase,
            .used = self.clock,
            .left = r.left,
            .top = r.top,
            .width = r.width,
            .height = r.height,
            .advance = advance,
        };
        return self.glyphFromEntry(slot);
    }
};

pub const Direction = enum { ltr, rtl };

pub const ShapeHook = *const fn (cp: u21) u21;

pub const DrawOptions = struct {
    direction: Direction = .ltr,
    kerning: bool = true,
    shape_hook: ?ShapeHook = null,
    corrupt_gid: ?u16 = null,
};

pub const DrawResult = struct {
    glyphs: u32 = 0,
    missing: u32 = 0,
    fallback: u32 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_evictions: u64 = 0,
    width_q16: i32 = 0,
    ink: u32 = 0,
    missing_cp: u21 = 0,
    corrupted: bool = false,
};

pub const Measure = struct {
    glyphs: u32 = 0,
    missing: u32 = 0,
    fallback: u32 = 0,
    width_q16: i32 = 0,
    kerning_q16: i32 = 0,
};

const Run = struct {
    cps: [max_text_codepoints]u21 = undefined,
    count: usize = 0,
};

fn decodeOne(text: []const u8, at: usize) struct { cp: u21, len: usize } {
    const b0 = text[at];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 & 0xE0 == 0xC0 and at + 1 < text.len) {
        return .{ .cp = (@as(u21, b0 & 0x1F) << 6) | (text[at + 1] & 0x3F), .len = 2 };
    }
    if (b0 & 0xF0 == 0xE0 and at + 2 < text.len) {
        return .{
            .cp = (@as(u21, b0 & 0x0F) << 12) |
                (@as(u21, text[at + 1] & 0x3F) << 6) |
                (text[at + 2] & 0x3F),
            .len = 3,
        };
    }
    if (b0 & 0xF8 == 0xF0 and at + 3 < text.len) {
        return .{
            .cp = (@as(u21, b0 & 0x07) << 18) |
                (@as(u21, text[at + 1] & 0x3F) << 12) |
                (@as(u21, text[at + 2] & 0x3F) << 6) |
                (text[at + 3] & 0x3F),
            .len = 4,
        };
    }
    return .{ .cp = 0xFFFD, .len = 1 };
}

fn prepareRun(text: []const u8, opts: DrawOptions) Run {
    var run = Run{};
    var i: usize = 0;
    while (i < text.len and run.count < max_text_codepoints) {
        const d = decodeOne(text, i);
        var cp = d.cp;
        if (opts.shape_hook) |hook| cp = hook(cp);
        run.cps[run.count] = cp;
        run.count += 1;
        i += d.len;
    }
    if (opts.direction == .rtl) {
        var lo: usize = 0;
        var hi = run.count;
        while (lo + 1 < hi) {
            hi -= 1;
            const tmp = run.cps[lo];
            run.cps[lo] = run.cps[hi];
            run.cps[hi] = tmp;
            lo += 1;
        }
    }
    return run;
}

fn fallbackAdvanceQ16(px: u16) i32 {
    const scale: i32 = @max(1, @divTrunc(@as(i32, px), 7));
    return (@as(i32, font5x7.advance) * scale) << 16;
}

fn drawFallback(surface: *gfx.Surface, cp: u21, x_q16: i32, baseline: i32, px: u16, color: gfx.Color) void {
    var ch: u8 = '?';
    if (cp >= 0x20 and cp <= 0x7E) ch = @intCast(cp);
    const index = ch - font5x7.first_printable;
    if (index >= font5x7.glyph_count) return;
    const scale: i32 = @max(1, @divTrunc(@as(i32, px), 7));
    const x = @divFloor(x_q16, 65536);
    const top = baseline - @as(i32, font5x7.glyph_height) * scale;
    const glyph = font5x7.glyphs[index];
    var row: usize = 0;
    while (row < font5x7.glyph_height) : (row += 1) {
        var col: usize = 0;
        while (col < font5x7.glyph_width) : (col += 1) {
            if ((glyph[row] & (@as(u8, 1) << @intCast(4 - col))) != 0) {
                surface.fillRect(x + @as(i32, @intCast(col)) * scale, top + @as(i32, @intCast(row)) * scale, scale, scale, color);
            }
        }
    }
}

fn drawCoverage(surface: *gfx.Surface, glyph: Glyph, x: i32, y: i32, color: gfx.Color) u32 {
    if (glyph.width == 0 or glyph.height == 0) return 0;
    const w: usize = glyph.width;
    var ink: u32 = 0;
    var row: usize = 0;
    while (row < glyph.height) : (row += 1) {
        var col: usize = 0;
        while (col < w) : (col += 1) {
            const cov = glyph.pixels[row * w + col];
            if (cov != 0) {
                surface.blendPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color, cov);
                ink += 1;
            }
        }
    }
    surface.damage.add(.{ .x = x, .y = y, .w = glyph.width, .h = glyph.height });
    return ink;
}

fn phaseFor(pen: i32) u8 {
    const frac: u32 = @intCast(@mod(pen, 65536));
    return @intCast((frac * 4) / 65536);
}

/// Draw a UTF-8 text run. The pen is Q16; `baseline` is an integer pixel row.
/// Unsupported codepoints and composite glyphs use the 5x7 fallback and are
/// counted in `missing` and `fallback`; they are never silently omitted.
pub fn drawText(self: *Renderer, surface: *gfx.Surface, text: []const u8, x_q16: i32, baseline: i32, px: u16, color: gfx.Color, opts: DrawOptions) DrawResult {
    var out = DrawResult{
        .cache_hits = self.hits,
        .cache_misses = self.misses,
        .cache_evictions = self.evictions,
    };
    if (px == 0 or px > 96) return out;
    const run = prepareRun(text, opts);
    var pen = x_q16;
    var prev: ?u16 = null;
    for (run.cps[0..run.count]) |cp| {
        const gid_opt = self.font.glyphIndex(cp);
        const gid = gid_opt orelse {
            drawFallback(surface, cp, pen, baseline, px, color);
            pen += fallbackAdvanceQ16(px);
            out.glyphs += 1;
            if (out.missing == 0) out.missing_cp = cp;
            out.missing += 1;
            out.fallback += 1;
            prev = null;
            continue;
        };
        if (prev != null and opts.kerning) {
            const k = self.font.kernQ16(prev.?, gid, px);
            pen += k;
            out.width_q16 += k;
        }
        const phase = phaseFor(pen);
        const glyph = self.get(gid, px, phase) orelse {
            drawFallback(surface, cp, pen, baseline, px, color);
            pen += fallbackAdvanceQ16(px);
            out.glyphs += 1;
            if (out.missing == 0) out.missing_cp = cp;
            out.missing += 1;
            out.fallback += 1;
            prev = null;
            out.width_q16 = pen - x_q16;
            continue;
        };
        if (opts.corrupt_gid != null and opts.corrupt_gid.? == gid) {
            out.corrupted = true;
        } else {
            const gx = @divFloor(pen, 65536) + @as(i32, glyph.left);
            const gy = baseline + @as(i32, glyph.top);
            out.ink += drawCoverage(surface, glyph, gx, gy, color);
        }
        out.glyphs += 1;
        pen += glyph.advance;
        out.width_q16 = pen - x_q16;
        prev = gid;
    }
    out.cache_hits = self.hits;
    out.cache_misses = self.misses;
    out.cache_evictions = self.evictions;
    return out;
}

/// Measure without rasterizing. This is the same kerning/order path used by
/// `drawText`, so a width assertion exercises the real layout logic.
pub fn measure(self: *Renderer, text: []const u8, px: u16, opts: DrawOptions) Measure {
    var out = Measure{};
    if (px == 0 or px > 96) return out;
    const run = prepareRun(text, opts);
    var pen: i32 = 0;
    var prev: ?u16 = null;
    for (run.cps[0..run.count]) |cp| {
        const gid_opt = self.font.glyphIndex(cp);
        const gid = gid_opt orelse {
            pen += fallbackAdvanceQ16(px);
            out.glyphs += 1;
            out.missing += 1;
            out.fallback += 1;
            prev = null;
            continue;
        };
        if (prev != null and opts.kerning) {
            const k = self.font.kernQ16(prev.?, gid, px);
            pen += k;
            out.kerning_q16 += k;
        }
        pen += self.font.advanceQ16(gid, px);
        out.glyphs += 1;
        out.width_q16 = pen;
        prev = gid;
    }
    return out;
}

test "embedded font parses its required tables" {
    var f = try Font.init(&embedded.ttf);
    try std.testing.expectEqual(@as(u16, 2048), f.units_per_em);
    try std.testing.expectEqual(@as(u16, 100), f.num_glyphs);
    try std.testing.expect(f.ascent > 0 and f.descent < 0);
    try std.testing.expect(f.kern_table != null);
    const a = f.glyphIndex('A') orelse return error.TestUnexpectedResult;
    const v = f.glyphIndex('V') orelse return error.TestUnexpectedResult;
    try std.testing.expect(f.kern(a, v) < 0);
    try std.testing.expect(f.advanceFont(a) > 0);
}

test "printable ASCII and price symbols all map to glyphs" {
    var f = try Font.init(&embedded.ttf);
    var cp: u21 = 0x20;
    while (cp <= 0x7E) : (cp += 1) {
        try std.testing.expect(f.glyphIndex(cp) != null);
    }
    for ([_]u21{ 0x20AC, 0xA3, 0xA5, 0xB0 }) |symbol| {
        try std.testing.expect(f.glyphIndex(symbol) != null);
    }
}

test "simple glyph outlines have contours and points" {
    var f = try Font.init(&embedded.ttf);
    var out: Outline = undefined;
    const a = f.glyphIndex('A') orelse return error.TestUnexpectedResult;
    try f.outline(a, &out);
    try std.testing.expect(out.contour_count > 0);
    try std.testing.expect(out.point_count > 0);
    try std.testing.expect(out.x_max > out.x_min and out.y_max > out.y_min);
}

test "rasterizer produces bounded coverage at 8 through 48 px" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    const a = r.font.glyphIndex('A') orelse return error.TestUnexpectedResult;
    for ([_]u16{ 8, 12, 24, 48 }) |px| {
        const g = r.get(a, px, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expect(g.width > 0 and g.height > 0);
        try std.testing.expect(g.width <= max_glyph_px and g.height <= max_glyph_px);
        var ink: usize = 0;
        for (g.pixels) |v| ink += v;
        try std.testing.expect(ink > 0);
    }
}

test "kerning narrows AV and the glyph cache reuses coverage" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    const av = measure(&r, "AV", 32, .{});
    const a = measure(&r, "A", 32, .{});
    const v = measure(&r, "V", 32, .{});
    try std.testing.expect(av.missing == 0);
    try std.testing.expect(av.kerning_q16 < 0);
    try std.testing.expect(av.width_q16 < a.width_q16 + v.width_q16);
    var buf = [_]u8{0} ** (128 * 64 * 4);
    var surface = try gfx.Surface.init(&buf, 128, 64, 128 * 4, .rgba8888);
    surface.clear(gfx.rgb(8, 12, 16));
    const first = drawText(&r, &surface, "AV 10", 4 << 16, 40, 24, gfx.rgb(240, 244, 248), .{});
    const second = drawText(&r, &surface, "AV 10", 4 << 16, 40, 24, gfx.rgb(240, 244, 248), .{});
    try std.testing.expect(first.glyphs == 5 and first.missing == 0);
    try std.testing.expect(second.cache_hits > first.cache_hits);
    try std.testing.expect(r.evictions == 0);
}

test "four-phase subpixel positioning changes coverage" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    const a = r.font.glyphIndex('A') orelse return error.TestUnexpectedResult;
    const p0 = r.get(a, 32, 0) orelse return error.TestUnexpectedResult;
    const p2 = r.get(a, 32, 2) orelse return error.TestUnexpectedResult;
    const dw = if (p0.width > p2.width) p0.width - p2.width else p2.width - p0.width;
    try std.testing.expect(dw <= 1 and p0.height == p2.height);
    try std.testing.expect(!std.mem.eql(u8, p0.pixels, p2.pixels));
}

test "RTL order and a shaping hook are wired through layout" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    const ltr = measure(&r, "AV", 32, .{});
    const rtl = measure(&r, "AV", 32, .{ .direction = .rtl });
    try std.testing.expect(ltr.width_q16 == rtl.width_q16);
    const hooked = measure(&r, "A", 32, .{ .shape_hook = struct {
        fn hook(cp: u21) u21 {
            return if (cp == 'A') 'V' else cp;
        }
    }.hook });
    const v = measure(&r, "V", 32, .{});
    try std.testing.expect(hooked.width_q16 == v.width_q16);
}

test "unsupported codepoints use a visible fallback, not a missing box" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    var buf = [_]u8{0} ** (128 * 64 * 4);
    var surface = try gfx.Surface.init(&buf, 128, 64, 128 * 4, .rgba8888);
    surface.clear(gfx.rgb(8, 12, 16));
    const before = surface.snapshot();
    const result = drawText(&r, &surface, "\u{4E2D}", 4 << 16, 40, 24, gfx.rgb(240, 244, 248), .{});
    try std.testing.expect(result.missing == 1);
    try std.testing.expect(result.fallback == 1);
    try std.testing.expect(surface.snapshot() != before);
}

test "text at every required size renders ink" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    var buf = [_]u8{0} ** (640 * 96 * 4);
    var surface = try gfx.Surface.init(&buf, 640, 96, 640 * 4, .rgba8888);
    for ([_]u16{ 8, 12, 18, 24, 36, 48 }) |px| {
        surface.clear(gfx.rgb(8, 12, 16));
        const m = measure(&r, "CASSA 1,234.56", px, .{});
        try std.testing.expect(m.glyphs == 14 and m.missing == 0);
        const d = drawText(&r, &surface, "CASSA 1,234.56", 4 << 16, 70, px, gfx.rgb(240, 244, 248), .{});
        try std.testing.expect(d.glyphs == 14 and d.missing == 0);
        try std.testing.expect(d.ink > 0);
        try std.testing.expect(surface.snapshot() != 0);
    }
}

test "euro renders at 48" {
    var r: Renderer = undefined;
    try r.initInPlace(&embedded.ttf);
    const e = r.font.glyphIndex(0x20AC) orelse return error.TestUnexpectedResult;
    const g = r.get(e, 48, 0) orelse return error.TestUnexpectedResult;
    var ink: usize = 0;
    for (g.pixels) |v| ink += v;
    try std.testing.expect(ink > 0);
}
