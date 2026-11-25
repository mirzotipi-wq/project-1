//! Phase 50 configuration snapshots, rollback, factory reset and support bundle.
//!
//! Every file here is an ordinary VFS file under `/catalog`; there is no block
//! device shortcut and no second storage path. A configuration change first
//! copies the previous record into a bounded snapshot slot, then writes the new
//! generation through the CASSAFS page cache, flushes it, and reads it back
//! before printing success. Rollback does the same in reverse.
//!
//! The audit trail is the existing phase-48 `/catalog/sales.log`. Factory reset
//! only resets configuration and snapshots; it never touches the sale log. The
//! policy argument is explicit, and any unsupported policy is a named refusal.

const std = @import("std");
const uart = @import("../devices/pl011.zig");
const kvfs = @import("vfs.zig");
const virtio_blk = @import("../devices/virtio_blk.zig");
const cassafs = @import("../lib/cassafs.zig");
const model = @import("../lib/recovery.zig");
const sale_log = @import("../lib/sale_log.zig");

fn out(comptime fmt: []const u8, args: anytype) void {
    uart.Writer.print(fmt, args);
}

const config_path = "/catalog/config.cfg";
const snapshot_path = "/catalog/config.snap";
const bundle_path = "/catalog/support.bundle";
const audit_path = "/catalog/sales.log";

const bundle_magic: [8]u8 = .{ 'C', 'S', 'B', 'N', 'D', '5', '0', 0 };
const bundle_version: u16 = 1;
const bundle_header_size: usize = 64;
const bundle_crc_offset: usize = 60;
const bundle_max_bytes: usize = 16 * 1024;
const bundle_flags_config_valid: u16 = 1 << 0;
const bundle_flags_snapshot_present: u16 = 1 << 1;
const bundle_flags_audit_present: u16 = 1 << 2;
const bundle_flags_snapshot_valid: u16 = 1 << 3;

var g_config_bytes: [model.config_size]u8 = undefined;
var g_snapshot_bytes: [model.snapshot_file_size]u8 = undefined;
var g_audit_bytes: [sale_log.max_file_bytes]u8 = undefined;
var g_bundle: [bundle_max_bytes]u8 = undefined;
var g_bundle_check: [bundle_max_bytes]u8 = undefined;

fn printError(context: []const u8, err: anyerror) void {
    out("  {s} : REFUSED: {s}\n", .{ context, @errorName(err) });
}

fn readRaw(path: []const u8, dest: []u8) !usize {
    const handle = try kvfs.fileOpen(path, .{ .read = true });
    defer kvfs.fileClose(handle);
    const stat = try kvfs.fileStat(handle);
    if (stat.size > dest.len) return error.TooLarge;
    const size: usize = @intCast(stat.size);
    var done: usize = 0;
    while (done < size) {
        const got = try kvfs.fileReadAt(handle, done, dest[done..size]);
        if (got == 0) return error.Truncated;
        done += got;
    }
    return size;
}

fn writeExact(path: []const u8, bytes: []const u8) !void {
    const handle = try kvfs.fileOpen(path, .{ .write = true, .create = true });
    defer kvfs.fileClose(handle);
    const wrote = try kvfs.fileWriteAt(handle, 0, bytes);
    if (wrote != bytes.len) return error.ShortWrite;
    const stat = try kvfs.fileStat(handle);
    if (stat.size != bytes.len) return error.LengthMismatch;
    try kvfs.flushCache();
}

fn loadConfig() !model.Config {
    const size = try readRaw(config_path, &g_config_bytes);
    return model.decodeConfig(g_config_bytes[0..size]);
}

fn writeConfig(config: model.Config) !void {
    var bytes: [model.config_size]u8 = undefined;
    try model.encodeConfig(&config, &bytes);
    try writeExact(config_path, &bytes);
    const check = try loadConfig();
    if (check.generation != config.generation or !std.mem.eql(u8, check.storeSlice(), config.storeSlice())) {
        return error.CommitUnverified;
    }
}

fn loadSnapshots(allow_missing: bool) !model.SnapshotSet {
    const size = readRaw(snapshot_path, &g_snapshot_bytes) catch |err| {
        if (err == error.NotFound and allow_missing) return model.SnapshotSet.init();
        return err;
    };
    return model.decodeSnapshotSet(g_snapshot_bytes[0..size]);
}

fn saveSnapshot(config: model.Config) !u8 {
    var set = try loadSnapshots(true);
    const slot = set.add(config);
    var bytes: [model.snapshot_file_size]u8 = undefined;
    try model.encodeSnapshotSet(&set, &bytes);
    try writeExact(snapshot_path, &bytes);
    const check = try loadSnapshots(false);
    const latest = try check.latest();
    if (latest.config.generation != config.generation) return error.CommitUnverified;
    return slot;
}

fn resetSnapshots(config: model.Config) !void {
    var set = model.SnapshotSet.init();
    _ = set.add(config);
    var bytes: [model.snapshot_file_size]u8 = undefined;
    try model.encodeSnapshotSet(&set, &bytes);
    try writeExact(snapshot_path, &bytes);
    const check = try loadSnapshots(false);
    const latest = try check.latest();
    if (latest.config.generation != config.generation) return error.CommitUnverified;
}

fn auditSize() !?u64 {
    const handle = kvfs.fileOpen(audit_path, .{ .read = true }) catch |err| {
        if (err == error.NotFound) return null;
        return err;
    };
    defer kvfs.fileClose(handle);
    const stat = try kvfs.fileStat(handle);
    return stat.size;
}

fn initConfig() void {
    if (loadConfig()) |_| {
        out("  recovery init : REFUSED: Exists\n", .{});
        return;
    } else |err| {
        if (err != error.NotFound) {
            printError("recovery init", err);
            return;
        }
    }
    const config = model.Config.default();
    writeConfig(config) catch |write_err| {
        printError("recovery init", write_err);
        return;
    };
    const slot = saveSnapshot(config) catch |snap_err| {
        printError("recovery init", snap_err);
        return;
    };
    out("  recovery init : {s}, {d} byte(s), generation {d}\n", .{ config_path, model.config_size, config.generation });
    out("  recovery init : {s}, snapshot slot {d}, 4-slot bound\n", .{ snapshot_path, slot });
}

fn status() void {
    const config = loadConfig() catch |err| {
        printError("recovery status", err);
        return;
    };
    out("  recovery config : {s}, {d} byte(s), generation {d}, terminal {d}\n", .{
        config_path, model.config_size, config.generation, config.terminal_id,
    });
    out("  recovery values : store \"{s}\", footer \"{s}\", tax {s}, autolock {d}s\n", .{
        config.storeSlice(), config.footerSlice(), config.taxLabel(), config.auto_lock_secs,
    });
    const set = loadSnapshots(true) catch |err| {
        printError("recovery snapshots", err);
        return;
    };
    const latest = set.latest() catch {
        out("  recovery snaps  : 0/{d} valid, no snapshot yet, next slot {d}\n", .{ model.snapshot_slots, set.next_slot });
        return;
    };
    out("  recovery snaps  : {d}/{d} valid, latest generation {d} in slot {d}, next slot {d}\n", .{
        set.validCount(), model.snapshot_slots, latest.config.generation, latest.slot, set.next_slot,
    });
    const audit = auditSize() catch |err| {
        printError("recovery audit", err);
        return;
    };
    if (audit) |bytes| {
        out("  recovery audit : {s}, {d} byte(s), preserved by policy\n", .{ audit_path, bytes });
    } else {
        out("  recovery audit : {s}, absent\n", .{audit_path});
    }
}

fn verify() void {
    const config = loadConfig() catch |err| {
        printError("recovery verify", err);
        return;
    };
    out("  recovery verify : PASS, generation {d}, terminal {d}, store \"{s}\", tax {s}, autolock {d}s\n", .{
        config.generation, config.terminal_id, config.storeSlice(), config.taxLabel(), config.auto_lock_secs,
    });
}

fn setConfig(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const key = tokens.next() orelse {
        out("  usage: recovery set <store|footer|terminal|tax|autolock> <value>\n", .{});
        return;
    };
    const value = tokens.rest();
    if (value.len == 0) {
        out("  recovery set : REFUSED: BadValue\n", .{});
        return;
    }
    const current = loadConfig() catch |err| {
        printError("recovery set", err);
        return;
    };
    var next = current;
    next.setField(key, value) catch |err| {
        printError("recovery set", err);
        return;
    };
    if (current.generation == std.math.maxInt(u32)) {
        out("  recovery set : REFUSED: GenerationExhausted\n", .{});
        return;
    }
    next.generation = current.generation + 1;
    const slot = saveSnapshot(current) catch |err| {
        printError("recovery set", err);
        return;
    };
    writeConfig(next) catch |err| {
        printError("recovery set", err);
        return;
    };
    out("  recovery set : {s} = \"{s}\", generation {d}, snapshot slot {d} kept\n", .{
        key, value, next.generation, slot,
    });
    out("  recovery set : flush + reread PASS\n", .{});
}

fn snapshot() void {
    const config = loadConfig() catch |err| {
        printError("recovery snapshot", err);
        return;
    };
    const slot = saveSnapshot(config) catch |err| {
        printError("recovery snapshot", err);
        return;
    };
    out("  recovery snapshot : generation {d} in slot {d}, flush + reread PASS\n", .{ config.generation, slot });
}

fn rollback() void {
    const set = loadSnapshots(false) catch |err| {
        printError("recovery rollback", err);
        return;
    };
    const latest = set.latest() catch |err| {
        printError("recovery rollback", err);
        return;
    };
    writeConfig(latest.config) catch |err| {
        printError("recovery rollback", err);
        return;
    };
    out("  recovery rollback : restored generation {d} from slot {d}, store \"{s}\"\n", .{
        latest.config.generation, latest.slot, latest.config.storeSlice(),
    });
    out("  recovery rollback : flush + reread PASS\n", .{});
}

fn factoryReset(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const policy = tokens.next() orelse "preserve";
    if (!std.mem.eql(u8, policy, "preserve")) {
        out("  recovery reset : REFUSED: UnsupportedPolicy\n", .{});
        return;
    }
    const audit_before = auditSize() catch |err| {
        printError("recovery reset", err);
        return;
    };
    const config = model.Config.default();
    writeConfig(config) catch |err| {
        printError("recovery reset", err);
        return;
    };
    resetSnapshots(config) catch |err| {
        printError("recovery reset", err);
        return;
    };
    const audit_after = auditSize() catch |err| {
        printError("recovery reset", err);
        return;
    };
    if (audit_before != audit_after) {
        out("  recovery reset : REFUSED: AuditChanged\n", .{});
        return;
    }
    out("  recovery reset : PASS, generation 1, 128-byte config, snapshot reset\n", .{});
    if (audit_after) |bytes| {
        out("  recovery reset : audit preserved: {s}, {d} byte(s)\n", .{ audit_path, bytes });
    } else {
        out("  recovery reset : audit absent: {s}\n", .{audit_path});
    }
}

fn bundle() void {
    var flags: u16 = 0;
    const config_size = readRaw(config_path, &g_config_bytes) catch |err| switch (err) {
        error.NotFound => 0,
        else => {
            printError("recovery bundle", err);
            return;
        },
    };
    const config_valid = if (config_size == model.config_size) blk: {
        _ = model.decodeConfig(g_config_bytes[0..config_size]) catch break :blk false;
        break :blk true;
    } else false;
    if (config_valid) flags |= bundle_flags_config_valid;

    var snapshot_size: usize = 0;
    var snapshot_valid = false;
    snapshot_size = readRaw(snapshot_path, &g_snapshot_bytes) catch |err| switch (err) {
        error.NotFound => 0,
        else => {
            printError("recovery bundle", err);
            return;
        },
    };
    if (snapshot_size != 0) {
        flags |= bundle_flags_snapshot_present;
        snapshot_valid = blk: {
            _ = model.decodeSnapshotSet(g_snapshot_bytes[0..snapshot_size]) catch break :blk false;
            break :blk true;
        };
        if (snapshot_valid) flags |= bundle_flags_snapshot_valid;
    }

    const audit_size = readRaw(audit_path, &g_audit_bytes) catch |err| switch (err) {
        error.NotFound => 0,
        else => {
            printError("recovery bundle", err);
            return;
        },
    };
    if (audit_size != 0) flags |= bundle_flags_audit_present;

    const health = virtio_blk.healthSnapshot();
    @memset(g_bundle[0..], 0);
    @memcpy(g_bundle[0..8], &bundle_magic);
    std.mem.writeInt(u16, g_bundle[8..10], bundle_version, .little);
    std.mem.writeInt(u16, g_bundle[10..12], flags, .little);
    std.mem.writeInt(u32, g_bundle[12..16], @intCast(config_size), .little);
    std.mem.writeInt(u32, g_bundle[16..20], @intCast(snapshot_size), .little);
    std.mem.writeInt(u32, g_bundle[20..24], @intCast(audit_size), .little);
    g_bundle[24] = @intFromEnum(health.state);
    std.mem.writeInt(u16, g_bundle[26..28], @intCast(health.bad_count), .little);
    std.mem.writeInt(u32, g_bundle[28..32], @intCast(health.retries), .little);
    std.mem.writeInt(u32, g_bundle[32..36], @intCast(health.recovered), .little);
    std.mem.writeInt(u32, g_bundle[36..40], @intCast(health.unrecovered), .little);
    std.mem.writeInt(u64, g_bundle[40..48], health.reads, .little);
    std.mem.writeInt(u64, g_bundle[48..56], health.writes, .little);
    std.mem.writeInt(u32, g_bundle[56..60], @intCast(health.flushes), .little);

    var offset: usize = bundle_header_size;
    if (config_size != 0) {
        @memcpy(g_bundle[offset..][0..config_size], g_config_bytes[0..config_size]);
        offset += config_size;
    }
    if (snapshot_size != 0) {
        @memcpy(g_bundle[offset..][0..snapshot_size], g_snapshot_bytes[0..snapshot_size]);
        offset += snapshot_size;
    }
    if (audit_size != 0) {
        @memcpy(g_bundle[offset..][0..audit_size], g_audit_bytes[0..audit_size]);
        offset += audit_size;
    }
    if (offset > g_bundle.len) {
        out("  recovery bundle : REFUSED: TooLarge\n", .{});
        return;
    }
    var crc = cassafs.crc32cUpdate(0xffff_ffff, g_bundle[0..bundle_crc_offset]);
    crc = cassafs.crc32cUpdate(crc, g_bundle[bundle_header_size..offset]);
    std.mem.writeInt(u32, g_bundle[bundle_crc_offset..][0..4], ~crc, .little);

    writeExact(bundle_path, g_bundle[0..offset]) catch |err| {
        printError("recovery bundle", err);
        return;
    };
    const readback = readRaw(bundle_path, &g_bundle_check) catch |err| {
        printError("recovery bundle", err);
        return;
    };
    if (!std.mem.eql(u8, g_bundle[0..offset], g_bundle_check[0..readback])) {
        out("  recovery bundle : REFUSED: CommitUnverified\n", .{});
        return;
    }
    const got_crc = cassafs.crc32c(g_bundle_check[0..readback]);
    out("  recovery bundle : {s}, {d} byte(s), CRC32C 0x{x:0>8}\n", .{ bundle_path, readback, got_crc });
    out("  recovery bundle : config {d} B ({s}), snapshot {d} B ({s}), audit {d} B, health {s}\n", .{
        config_size,
        if (config_valid) "valid" else "absent/corrupt",
        snapshot_size,
        if (snapshot_valid) "valid" else "absent/corrupt",
        audit_size,
        health.state.label(),
    });
}

fn corrupt(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const target = tokens.next() orelse {
        out("  usage: recovery corrupt <config|snapshot>\n", .{});
        return;
    };
    if (std.mem.eql(u8, target, "config")) {
        const size = readRaw(config_path, &g_config_bytes) catch |err| {
            printError("recovery corrupt", err);
            return;
        };
        if (size != model.config_size) {
            out("  recovery corrupt : REFUSED: Truncated\n", .{});
            return;
        }
        g_config_bytes[24] ^= 0x80;
        writeExact(config_path, g_config_bytes[0..size]) catch |err| {
            printError("recovery corrupt", err);
            return;
        };
        out("  recovery corrupt : flipped a config payload byte; run 'recovery verify'\n", .{});
        return;
    }
    if (std.mem.eql(u8, target, "snapshot")) {
        const size = readRaw(snapshot_path, &g_snapshot_bytes) catch |err| {
            printError("recovery corrupt", err);
            return;
        };
        if (size != model.snapshot_file_size) {
            out("  recovery corrupt : REFUSED: Truncated\n", .{});
            return;
        }
        g_snapshot_bytes[model.snapshot_header_crc_offset] ^= 0x80;
        writeExact(snapshot_path, g_snapshot_bytes[0..size]) catch |err| {
            printError("recovery corrupt", err);
            return;
        };
        out("  recovery corrupt : flipped the snapshot header CRC; run 'recovery rollback'\n", .{});
        return;
    }
    out("  recovery corrupt : REFUSED: BadTarget\n", .{});
}

pub fn command(tokens: *std.mem.TokenIterator(u8, .scalar)) void {
    const sub = tokens.next() orelse "help";
    if (std.mem.eql(u8, sub, "init")) {
        initConfig();
    } else if (std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "info")) {
        status();
    } else if (std.mem.eql(u8, sub, "verify")) {
        verify();
    } else if (std.mem.eql(u8, sub, "set")) {
        setConfig(tokens);
    } else if (std.mem.eql(u8, sub, "snapshot")) {
        snapshot();
    } else if (std.mem.eql(u8, sub, "rollback")) {
        rollback();
    } else if (std.mem.eql(u8, sub, "factory-reset") or std.mem.eql(u8, sub, "reset")) {
        factoryReset(tokens);
    } else if (std.mem.eql(u8, sub, "bundle")) {
        bundle();
    } else if (std.mem.eql(u8, sub, "corrupt")) {
        corrupt(tokens);
    } else {
        out("  usage: recovery [init|status|verify|set <key> <value>|snapshot|rollback|factory-reset [preserve]|bundle|corrupt <config|snapshot>]\n", .{});
    }
}
