//! Capabilities (phase 23).
//!
//! Authority in Cassa is a value, not an ambient property of the caller. A
//! process holds *handles*: small integers that name a kernel object together
//! with the rights it may exercise on that object. The kernel resolves a handle
//! itself and checks the rights on the object it looked up, so a forged, stale
//! or out-of-range number fails deterministically instead of being
//! reinterpreted as a pointer or an index into something else.
//!
//! Handle numbers carry the slot's *generation* in the upper bits:
//!
//!     handle = (generation << 8) | (slot + 1)
//!
//! Closing or revoking a slot bumps its generation, so every number that used to
//! name it becomes stale forever. A freed slot can be reused immediately without
//! ever handing an old number back to life — the "reused handle" problem that
//! makes raw file-descriptor tables dangerous.
//!
//! Derivation is the only way to obtain authority you were not born with, and it
//! can only lose rights: the new mask must be a subset of the parent's, and the
//! parent must carry CONTROL. Revocation invalidates a handle and everything
//! derived from it in one pass, which is what makes "cut access immediately"
//! possible without walking the object's users.

const std = @import("std");
const pmm = @import("pmm.zig");

pub const max_handles: usize = 16;
pub const max_objects: usize = 16;
pub const max_tables: usize = 8;

pub const R_READ: u32 = 1 << 0;
pub const R_WRITE: u32 = 1 << 1;
/// Execute-or-map: the right to make an object appear in your address space.
pub const R_EXEC: u32 = 1 << 2;
pub const R_CONTROL: u32 = 1 << 3;
pub const R_ALL: u32 = R_READ | R_WRITE | R_EXEC | R_CONTROL;

pub const Error = error{
    BadHandle,
    Permission,
    TableFull,
    Invalid,
};

pub const Kind = enum {
    console,
    ledger,
    supervisor,
    page,
    /// A rendezvous object two processes meet on (phase 24).
    endpoint,
    /// A shared-memory object two processes map into their own spaces (phase 25).
    shm,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .console => "console",
            .ledger => "ledger",
            .supervisor => "supervisor",
            .page => "page",
            .endpoint => "endpoint",
            .shm => "shm",
        };
    }
};

/// A kernel object. Objects outlive handles; `refs` counts the handles that
/// currently name this object, so the table can report exactly how much
/// authority is outstanding.
pub const Object = struct {
    used: bool = false,
    id: u32 = 0,
    kind: Kind = .console,
    name: []const u8 = "",
    refs: u32 = 0,

    /// Ledger state: the bytes last written and how many times.
    bytes: [64]u8 = [_]u8{0} ** 64,
    len: usize = 0,
    version: u64 = 0,
    /// Control operations observed (monotonic counter, never decremented).
    epoch: u64 = 0,

    /// Page object: a read-only kernel frame that R_EXEC holders may map.
    pa: usize = 0,
    magic: u64 = 0,
};

const Handle = struct {
    used: bool = false,
    object: u32 = 0,
    rights: u32 = 0,
    /// Slot generation. Bumped whenever the slot is released, which is what
    /// makes an old handle number stale rather than reusable.
    generation: u32 = 0,
    /// Slot this handle was derived from, and the process that owns that slot.
    /// Transfers set these across tables, which is what lets revocation reach a
    /// copy another process is holding.
    parent: u8 = no_parent,
    parent_pid: u32 = 0,
};

const no_parent: u8 = 0xFF;

const Table = struct {
    used: bool = false,
    pid: u32 = 0,
    handles: [max_handles]Handle = [_]Handle{.{}} ** max_handles,
};

var objects: [max_objects]Object = [_]Object{.{}} ** max_objects;
var tables: [max_tables]Table = [_]Table{.{}} ** max_tables;
var next_object_id: u32 = 1;

pub var derivations: u64 = 0;
pub var transfers: u64 = 0;
pub var revocations: u64 = 0;
pub var refusals: u64 = 0;

// ---------------------------------------------------------------------------
// Handle encoding (pure, host-tested)
// ---------------------------------------------------------------------------

pub fn encodeHandle(slot: usize, generation: u32) u64 {
    return (@as(u64, generation) << 8) | @as(u64, slot + 1);
}

pub const Decoded = struct { slot: usize, generation: u32 };

/// Returns null for anything that cannot name a slot in this table: zero, a
/// number whose slot index is past the end, and anything that overflows.
pub fn decodeHandle(handle: u64) ?Decoded {
    const low: u64 = handle & 0xFF;
    if (low == 0) return null;
    const slot = low - 1;
    if (slot >= max_handles) return null;
    const gen = handle >> 8;
    if (gen > std.math.maxInt(u32)) return null;
    return .{ .slot = @intCast(slot), .generation = @intCast(gen) };
}

/// True when every right in `requested` is present in `held`.
pub fn isSubset(requested: u32, held: u32) bool {
    return (requested & ~held) == 0;
}

/// "rwxc" for a mask, into a caller-supplied buffer of at least 4 bytes.
pub fn rightsText(rights: u32, buf: []u8) []const u8 {
    if (buf.len < 4) return "?";
    buf[0] = if (rights & R_READ != 0) 'r' else '-';
    buf[1] = if (rights & R_WRITE != 0) 'w' else '-';
    buf[2] = if (rights & R_EXEC != 0) 'x' else '-';
    buf[3] = if (rights & R_CONTROL != 0) 'c' else '-';
    return buf[0..4];
}

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

pub fn create(kind: Kind, name: []const u8) ?*Object {
    for (&objects) |*o| {
        if (o.used) continue;
        o.* = .{ .used = true, .id = next_object_id, .kind = kind, .name = name };
        next_object_id += 1;
        return o;
    }
    return null;
}

pub fn find(id: u32) ?*Object {
    for (&objects) |*o| {
        if (o.used and o.id == id) return o;
    }
    return null;
}

pub fn objectAt(index: usize) ?*const Object {
    if (index >= objects.len) return null;
    if (!objects[index].used) return null;
    return &objects[index];
}

pub fn objectSlots() usize {
    return objects.len;
}

/// Create the objects that exist for the lifetime of the machine. The page
/// object owns one read-only frame whose first word is a magic value, so a
/// process that maps it can prove the mapping really happened.
pub fn boot(alloc: *pmm.PageAllocator) void {
    _ = create(.console, "console");
    _ = create(.ledger, "ledger");
    _ = create(.supervisor, "supervisor");
    const page = create(.page, "page") orelse return;
    const pa = alloc.allocZeroed() orelse return;
    page.pa = pa;
    page.magic = 0xCA55_A0B1_0000_0023;
    const words: [*]u64 = @ptrFromInt(pa);
    words[0] = page.magic;
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

fn tableFor(pid: u32) ?*Table {
    for (&tables) |*t| {
        if (t.used and t.pid == pid) return t;
    }
    return null;
}

fn createTable(pid: u32) ?*Table {
    for (&tables) |*t| {
        if (!t.used) {
            t.* = .{ .used = true, .pid = pid };
            return t;
        }
    }
    return null;
}

/// Refused grants because the process reached its handle quota (phase 29).
pub var quota_refusals: u64 = 0;

/// Who answers "how many handles may this pid hold". Set by the accounting
/// module at boot; without it there is no per-process handle ceiling.
var handle_limit_hook: ?*const fn (u32) u32 = null;

pub fn setHandleLimitHook(hook: *const fn (u32) u32) void {
    handle_limit_hook = hook;
}

fn allocateSlot(table: *Table, object_id: u32, rights: u32, parent: u8, parent_pid: u32) ?u64 {
    if (handle_limit_hook) |limit| {
        var held: u32 = 0;
        for (&table.handles) |*h| {
            if (h.used) held += 1;
        }
        if (held >= limit(table.pid)) {
            quota_refusals += 1;
            return null;
        }
    }
    for (&table.handles, 0..) |*h, slot| {
        if (h.used) continue;
        h.object = object_id;
        h.rights = rights;
        h.parent = parent;
        h.parent_pid = parent_pid;
        h.used = true;
        if (find(object_id)) |o| o.refs += 1;
        return encodeHandle(slot, h.generation);
    }
    return null;
}

fn lookup(pid: u32, handle: u64) Error!*Handle {
    const decoded = decodeHandle(handle) orelse return Error.BadHandle;
    const table = tableFor(pid) orelse return Error.BadHandle;
    const h = &table.handles[decoded.slot];
    if (!h.used) return Error.BadHandle;
    // A stale number (slot closed, revoked, or reused) never matches. This is
    // checked before anything else so a forged handle cannot even reveal
    // whether the slot exists.
    if (h.generation != decoded.generation) return Error.BadHandle;
    return h;
}

/// Resolve a handle and require `need` rights on the object it names.
pub fn access(pid: u32, handle: u64, need: u32) Error!*Object {
    const h = try lookup(pid, handle);
    if (!isSubset(need, h.rights)) {
        refusals += 1;
        return Error.Permission;
    }
    const object = find(h.object) orelse return Error.BadHandle;
    return object;
}

pub fn query(pid: u32, handle: u64) Error!u32 {
    const h = try lookup(pid, handle);
    return h.rights;
}

/// Grant a handle. Used at process creation and by derivation.
pub fn grant(pid: u32, object_id: u32, rights: u32) Error!u64 {
    const table = tableFor(pid) orelse return Error.BadHandle;
    return allocateSlot(table, object_id, rights, no_parent, 0) orelse Error.TableFull;
}

/// Refuse now if a handle could never be handed over: only a CONTROL holder may
/// grant authority away, exactly as with derivation.
pub fn checkTransferable(pid: u32, handle: u64) Error!void {
    const h = try lookup(pid, handle);
    if (!isSubset(R_CONTROL, h.rights)) {
        refusals += 1;
        return Error.Permission;
    }
}

/// Install a copy of `handle` in another process's table. The receiving mask
/// loses CONTROL: a transfer hands over use, not the power to grant further.
pub fn transfer(src_pid: u32, dst_pid: u32, handle: u64) Error!u64 {
    const h = try lookup(src_pid, handle);
    if (!isSubset(R_CONTROL, h.rights)) {
        refusals += 1;
        return Error.Permission;
    }
    const rights = h.rights & ~R_CONTROL;
    if (rights == 0) {
        refusals += 1;
        return Error.Invalid;
    }
    const dst = tableFor(dst_pid) orelse return Error.BadHandle;
    const src_slot: u8 = @intCast((handle & 0xFF) - 1);
    const installed = allocateSlot(dst, h.object, rights, src_slot, src_pid) orelse {
        refusals += 1;
        return Error.TableFull;
    };
    transfers += 1;
    return installed;
}

pub fn derive(pid: u32, parent_handle: u64, rights: u32) Error!u64 {
    const parent = try lookup(pid, parent_handle);
    // Granting authority is itself an authority: without CONTROL a holder can
    // use what it has but cannot mint more of it.
    if (!isSubset(R_CONTROL, parent.rights)) {
        refusals += 1;
        return Error.Permission;
    }
    if (!isSubset(rights, parent.rights)) {
        refusals += 1;
        return Error.Permission;
    }
    const table = tableFor(pid) orelse return Error.BadHandle;
    const slot = @as(u8, @intCast((parent_handle & 0xFF) - 1));
    const handle = allocateSlot(table, parent.object, rights, slot, pid) orelse return Error.TableFull;
    derivations += 1;
    return handle;
}

fn releaseSlot(table: *Table, slot: usize) void {
    const h = &table.handles[slot];
    if (!h.used) return;
    if (find(h.object)) |o| {
        if (o.refs > 0) o.refs -= 1;
    }
    h.used = false;
    h.generation +%= 1;
    h.object = 0;
    h.rights = 0;
    h.parent = no_parent;
    h.parent_pid = 0;
}

/// Drop authority. Always allowed: giving up rights never needs permission.
pub fn close(pid: u32, handle: u64) Error!void {
    const h = try lookup(pid, handle);
    const table = tableFor(pid).?;
    const slot = (@as(usize, handle & 0xFF)) - 1;
    _ = h;
    releaseSlot(table, slot);
}

/// Invalidate a handle and every handle derived from it, in this process and in
/// any process that received a copy through IPC.
///
/// Only a CONTROL holder may revoke. The walk is bounded: at most `max_tables`
/// tables of `max_handles` slots each, and every pass either marks something new
/// or stops.
pub fn revoke(pid: u32, handle: u64) Error!void {
    const h = try lookup(pid, handle);
    if (!isSubset(R_CONTROL, h.rights)) {
        refusals += 1;
        return Error.Permission;
    }
    const root_table = tableIndex(pid) orelse return Error.BadHandle;
    const root_slot: usize = (@as(usize, handle & 0xFF)) - 1;

    var revoked: [max_tables]u16 = [_]u16{0} ** max_tables;
    revoked[root_table] |= @as(u16, 1) << @intCast(root_slot);

    var changed = true;
    while (changed) {
        changed = false;
        for (&tables, 0..) |*t, ti| {
            if (!t.used) continue;
            var slot: usize = 0;
            while (slot < max_handles) : (slot += 1) {
                const bit = @as(u16, 1) << @intCast(slot);
                if (revoked[ti] & bit != 0) continue;
                const entry = &t.handles[slot];
                if (!entry.used or entry.parent == no_parent) continue;
                const parent_table = tableIndex(entry.parent_pid) orelse continue;
                const parent_bit = @as(u16, 1) << @intCast(entry.parent);
                if (revoked[parent_table] & parent_bit != 0) {
                    revoked[ti] |= bit;
                    changed = true;
                }
            }
        }
    }

    for (&tables, 0..) |*t, ti| {
        if (!t.used or revoked[ti] == 0) continue;
        var slot: usize = 0;
        while (slot < max_handles) : (slot += 1) {
            if (revoked[ti] & (@as(u16, 1) << @intCast(slot)) == 0) continue;
            if (t.handles[slot].used) {
                releaseSlot(t, slot);
                revocations += 1;
            }
        }
    }
}

fn tableIndex(pid: u32) ?usize {
    for (&tables, 0..) |*t, i| {
        if (t.used and t.pid == pid) return i;
    }
    return null;
}

/// The handles a freshly spawned process receives.
pub const Grants = struct {
    console: u64,
    ledger: u64,
    supervisor: u64,
    page: u64,
};

/// Prepare a process's table with its initial authority.
pub fn grantForProcess(pid: u32) ?Grants {
    _ = createTable(pid) orelse return null;
    const console = findByName("console") orelse return null;
    const ledger = findByName("ledger") orelse return null;
    const supervisor = findByName("supervisor") orelse return null;
    const page = findByName("page") orelse return null;
    return .{
        .console = grant(pid, console.id, R_READ | R_WRITE) catch 0,
        .ledger = grant(pid, ledger.id, R_READ | R_WRITE | R_CONTROL) catch 0,
        .supervisor = grant(pid, supervisor.id, R_READ) catch 0,
        .page = grant(pid, page.id, R_READ | R_EXEC) catch 0,
    };
}

/// A process that may only read the shared ledger. Used by the probe to prove
/// that two holders of one object are each bounded by their own mask.
pub fn grantReadOnlyProfile(pid: u32) ?Grants {
    _ = createTable(pid) orelse return null;
    const console = findByName("console") orelse return null;
    const ledger = findByName("ledger") orelse return null;
    const supervisor = findByName("supervisor") orelse return null;
    return .{
        .console = grant(pid, console.id, R_READ | R_WRITE) catch 0,
        .ledger = grant(pid, ledger.id, R_READ) catch 0,
        .supervisor = grant(pid, supervisor.id, R_READ) catch 0,
        .page = 0,
    };
}

pub fn findByName(name: []const u8) ?*Object {
    for (&objects) |*o| {
        if (o.used and std.mem.eql(u8, o.name, name)) return o;
    }
    return null;
}

/// Release every handle a process held. Called when its slot is reused, so a
/// dead process leaves no authority behind.
pub fn releaseProcess(pid: u32) void {
    const table = tableFor(pid) orelse return;
    for (&table.handles, 0..) |_, slot| releaseSlot(table, slot);
    table.used = false;
    table.pid = 0;
}

pub fn handleCount(pid: u32) usize {
    const table = tableFor(pid) orelse return 0;
    var n: usize = 0;
    for (&table.handles) |*h| {
        if (h.used) n += 1;
    }
    return n;
}

pub fn liveTables() usize {
    var n: usize = 0;
    for (&tables) |*t| {
        if (t.used) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "handle numbers round-trip and reject nonsense" {
    try std.testing.expectEqual(@as(usize, 0), decodeHandle(encodeHandle(0, 0)).?.slot);
    try std.testing.expectEqual(@as(u32, 7), decodeHandle(encodeHandle(3, 7)).?.generation);
    // Zero never names a slot.
    try std.testing.expect(decodeHandle(0) == null);
    // Past the end of the table.
    try std.testing.expect(decodeHandle(encodeHandle(max_handles, 1)) == null);
    try std.testing.expect(decodeHandle(0xFFFF_FFFF_FFFF_FFFF) == null);
    // A handle from a future generation is still a well-formed number; only the
    // table can say whether it is stale.
    const future = encodeHandle(2, 99);
    try std.testing.expectEqual(@as(u32, 99), decodeHandle(future).?.generation);
}

test "generation is what makes a number stale" {
    const first = encodeHandle(4, 1);
    const second = encodeHandle(4, 2);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(decodeHandle(first).?.slot, decodeHandle(second).?.slot);
}

test "rights can only be narrowed" {
    try std.testing.expect(isSubset(R_READ, R_READ | R_WRITE));
    try std.testing.expect(!isSubset(R_WRITE, R_READ));
    try std.testing.expect(isSubset(R_ALL, R_ALL));
    try std.testing.expect(isSubset(0, 0));
}

test "rights are rendered in a stable order" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("rw--", rightsText(R_READ | R_WRITE, &buf));
    try std.testing.expectEqualStrings("-wxc", rightsText(R_WRITE | R_EXEC | R_CONTROL, &buf));
}
