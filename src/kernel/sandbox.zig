//! Sandbox policy (phase 30): manifests, syscall masks, least privilege.
//!
//! Authority in Cassa was already a capability, but until this phase every
//! process was born with the same four handles and could call the whole syscall
//! table. That is ambient authority with extra steps: the ledger was bounded, the
//! surface was not. A manifest is now the single declaration of what a service
//! *is* — the capabilities it is born with and the system calls it may make —
//! and it is data, not code, so it can be checked before the machine runs.
//!
//! Three properties make this a policy rather than a suggestion:
//!
//!   * **Build-time validation.** `validateAll` runs in a `comptime` block, so a
//!     manifest naming an unknown call, a duplicate capability, an empty right
//!     mask or a writable-executable page fails `zig build`, not a boot.
//!   * **No ambient authority.** A process is granted exactly the capabilities
//!     its manifest lists. There is no "open by name" path to authority: a handle
//!     that was not granted at birth can only arrive by transfer or by an object
//!     the process created itself.
//!   * **A syscall gate.** Every EL0 call is checked against the manifest before
//!     it is dispatched, so an exploit that gains control of a process still
//!     cannot ask the kernel for a facility its manifest never included.
//!
//! The raw block device is the worked example: it exists as a kernel object with
//! its own handle kind, exactly one manifest (`storage`) may name it, and a
//! compromised renderer — running arbitrary code inside its own sandbox — cannot
//! reach it through any path.

const std = @import("std");
const cap = @import("cap.zig");

/// Which sandbox a process runs in. The value is stored in its process record
/// and consulted on every EL0 system call.
pub const Id = enum(u8) { harness, service, storage, renderer };

/// One capability a manifest asks for. The shape is `cap`'s own declaration, so
/// a manifest can be handed straight to the grant path with no conversion.
pub const CapSpec = cap.CapSpec;

pub const Manifest = struct {
    id: Id,
    name: []const u8,
    caps: []const CapSpec,
    /// Bit n set means system call number n is allowed. The numbers are the
    /// `UserNr` values; `known_syscalls` is the complete set, and validation
    /// refuses a bit that names nothing.
    syscalls: u64,
};

fn bit(n: u64) u64 {
    return @as(u64, 1) << @intCast(n);
}

// The numbers are mirrored here rather than imported so that this file stays the
// policy and `syscall.zig` stays the mechanism; a host test in `syscall.zig`
// asserts that every `UserNr` is covered by `known_syscalls`, so the mirror
// cannot silently drift.
pub const sys_write: u64 = 1;
pub const sys_exit: u64 = 2;
pub const sys_getpid: u64 = 3;
pub const sys_yield: u64 = 4;
pub const sys_sleep_ms: u64 = 5;
pub const sys_uptime_ms: u64 = 6;
pub const sys_cap_query: u64 = 20;
pub const sys_cap_derive: u64 = 21;
pub const sys_cap_revoke: u64 = 22;
pub const sys_cap_close: u64 = 23;
pub const sys_cap_read: u64 = 24;
pub const sys_cap_write: u64 = 25;
pub const sys_cap_control: u64 = 26;
pub const sys_cap_map: u64 = 27;
pub const sys_ipc_create: u64 = 28;
pub const sys_ipc_send: u64 = 29;
pub const sys_ipc_call: u64 = 30;
pub const sys_ipc_recv: u64 = 31;
pub const sys_ipc_reply: u64 = 32;
pub const sys_shm_create: u64 = 33;
pub const sys_shm_map: u64 = 34;
pub const sys_shm_unmap: u64 = 35;
pub const sys_shm_wait: u64 = 36;
pub const sys_shm_wake: u64 = 37;
pub const sys_resolve: u64 = 38;
pub const sys_account: u64 = 39;
pub const sys_block: u64 = 40;

/// Every system call that exists. Anything outside this set is refused by the
/// gate as an unknown call, exactly as before.
pub const known_syscalls: u64 = blk: {
    var m: u64 = 0;
    m |= bit(sys_write) | bit(sys_exit) | bit(sys_getpid) | bit(sys_yield) |
        bit(sys_sleep_ms) | bit(sys_uptime_ms);
    var n: u64 = sys_cap_query;
    while (n <= sys_block) : (n += 1) m |= bit(n);
    break :blk m;
};

// ---------------------------------------------------------------------------
// The manifests
// ---------------------------------------------------------------------------

const harness_caps = [_]CapSpec{
    .{ .kind = .console, .rights = cap.R_READ | cap.R_WRITE },
    .{ .kind = .ledger, .rights = cap.R_READ | cap.R_WRITE | cap.R_CONTROL },
    .{ .kind = .supervisor, .rights = cap.R_READ },
    .{ .kind = .page, .rights = cap.R_READ | cap.R_EXEC },
};

/// A normal POS service: it can talk, read the shared ledger, look at the
/// supervisor's counters, map the read-only page, create endpoints and shared
/// memory for its own peers, resolve names, and ask about its own account.
const service_caps = [_]CapSpec{
    .{ .kind = .console, .rights = cap.R_READ | cap.R_WRITE },
    .{ .kind = .ledger, .rights = cap.R_READ | cap.R_WRITE | cap.R_CONTROL },
    .{ .kind = .supervisor, .rights = cap.R_READ },
    .{ .kind = .page, .rights = cap.R_READ | cap.R_EXEC },
};

/// The one service allowed to touch the raw device. It gets the block object and
/// nothing else beyond a console and the read-only page.
const storage_caps = [_]CapSpec{
    .{ .kind = .console, .rights = cap.R_READ | cap.R_WRITE },
    .{ .kind = .page, .rights = cap.R_READ | cap.R_EXEC },
    .{ .kind = .block, .rights = cap.R_READ | cap.R_WRITE },
};

/// An untrusted renderer: a console and the right to ask about itself. No ledger,
/// no page mapping, no IPC, no shared memory, no block device, no name lookup.
const renderer_caps = [_]CapSpec{
    .{ .kind = .console, .rights = cap.R_READ | cap.R_WRITE },
};

const service_syscalls: u64 = bit(sys_write) | bit(sys_exit) | bit(sys_getpid) |
    bit(sys_yield) | bit(sys_sleep_ms) | bit(sys_uptime_ms) |
    bit(sys_cap_query) | bit(sys_cap_derive) | bit(sys_cap_close) |
    bit(sys_ipc_create) | bit(sys_ipc_send) | bit(sys_ipc_call) |
    bit(sys_ipc_recv) | bit(sys_ipc_reply) |
    bit(sys_shm_create) | bit(sys_shm_map) | bit(sys_shm_unmap) |
    bit(sys_shm_wait) | bit(sys_shm_wake) |
    bit(sys_resolve) | bit(sys_account);

const storage_syscalls: u64 = bit(sys_write) | bit(sys_exit) | bit(sys_getpid) |
    bit(sys_yield) | bit(sys_sleep_ms) | bit(sys_uptime_ms) |
    bit(sys_cap_query) | bit(sys_cap_read) | bit(sys_account) | bit(sys_block);

/// A renderer cannot even resolve a name, create a channel, or ask the kernel
/// for a block read: the calls are not in its table entry.
const renderer_syscalls: u64 = bit(sys_write) | bit(sys_exit) | bit(sys_getpid) |
    bit(sys_yield) | bit(sys_sleep_ms) | bit(sys_uptime_ms) | bit(sys_account);

pub const manifests = [_]Manifest{
    .{ .id = .harness, .name = "harness", .caps = &harness_caps, .syscalls = known_syscalls },
    .{ .id = .service, .name = "service", .caps = &service_caps, .syscalls = service_syscalls },
    .{ .id = .storage, .name = "storage", .caps = &storage_caps, .syscalls = storage_syscalls },
    .{ .id = .renderer, .name = "renderer", .caps = &renderer_caps, .syscalls = renderer_syscalls },
};

pub fn of(id: Id) *const Manifest {
    return &manifests[@intFromEnum(id)];
}

pub fn allows(id: Id, number: u64) bool {
    if (number >= 64) return false;
    return (of(id).syscalls & bit(number)) != 0;
}

pub fn allowsForPid(pid: u32, number: u64) bool {
    const process = @import("process.zig");
    const p = process.processOfPid(pid) orelse return false;
    return allows(p.sandbox, number);
}

/// How many EL0 calls were refused because the caller's manifest does not name
/// them. Monotonic, so a probe can show the gate ran.
pub var denied: u64 = 0;
/// Block-device reads refused for a process that does not hold the object.
pub var block_denials: u64 = 0;

/// Which capability kinds may appear in a manifest. Endpoints and shared memory
/// are minted by their users, not granted at birth, so a manifest naming one is
/// a mistake the build catches.
fn isBootKind(kind: cap.Kind) bool {
    return switch (kind) {
        .console, .ledger, .supervisor, .page, .block => true,
        .endpoint, .shm => false,
    };
}

pub const Invalid = error{
    DuplicateId,
    DuplicateName,
    EmptyName,
    EmptyCaps,
    UnknownSyscall,
    NoSyscalls,
    DuplicateKind,
    NonBootKind,
    EmptyRights,
    UnknownRight,
    WritableExecutablePage,
    BlockOutsideStorage,
    RendererHasAuthorities,
};

/// The policy check. Pure and callable at comptime, which is what makes it a
/// build-time check rather than a runtime one.
pub fn validate(list: []const Manifest) Invalid!void {
    for (list, 0..) |m, i| {
        if (@intFromEnum(m.id) != i) return Invalid.DuplicateId;
        if (m.name.len == 0) return Invalid.EmptyName;
        if (m.syscalls == 0) return Invalid.NoSyscalls;
        if ((m.syscalls & ~known_syscalls) != 0) return Invalid.UnknownSyscall;
        if (m.caps.len == 0) return Invalid.EmptyCaps;
        for (list[0..i]) |other| {
            if (other.id == m.id) return Invalid.DuplicateId;
            if (std.mem.eql(u8, other.name, m.name)) return Invalid.DuplicateName;
        }
        for (m.caps, 0..) |c, ci| {
            if (!isBootKind(c.kind)) return Invalid.NonBootKind;
            if (c.rights == 0) return Invalid.EmptyRights;
            if ((c.rights & ~cap.R_ALL) != 0) return Invalid.UnknownRight;
            // W^X is a property of the policy, not just of the MMU: no manifest
            // may even ask for a page it could write and execute.
            if (c.kind == .page and (c.rights & cap.R_WRITE) != 0 and (c.rights & cap.R_EXEC) != 0) {
                return Invalid.WritableExecutablePage;
            }
            for (m.caps[0..ci]) |prev| {
                if (prev.kind == c.kind) return Invalid.DuplicateKind;
            }
        }
        // The raw device has exactly one owner in the whole machine.
        for (m.caps) |c| {
            if (c.kind == .block and m.id != .storage) return Invalid.BlockOutsideStorage;
        }
        // Least privilege is stated, not implied: the untrusted sandbox holds a
        // console and nothing that could reach another process's data.
        if (m.id == .renderer) {
            if (m.caps.len != 1 or m.caps[0].kind != .console) return Invalid.RendererHasAuthorities;
        }
    }
}

comptime {
    validate(&manifests) catch @compileError("sandbox: an invalid manifest reached the build");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the shipped manifests are valid and the renderer is least-privileged" {
    try validate(&manifests);
    try std.testing.expectEqual(@as(usize, 1), of(.renderer).caps.len);
    try std.testing.expectEqual(cap.Kind.console, of(.renderer).caps[0].kind);
    try std.testing.expect(!allows(.renderer, sys_block));
    try std.testing.expect(!allows(.renderer, sys_shm_create));
    try std.testing.expect(!allows(.renderer, sys_resolve));
    try std.testing.expect(!allows(.renderer, sys_cap_query));
    // ... and the storage service is the only holder of the block object.
    var holders: usize = 0;
    for (&manifests) |*m| {
        for (m.caps) |c| {
            if (c.kind == .block) holders += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), holders);
    try std.testing.expect(allows(.storage, sys_block));
    try std.testing.expect(allows(.harness, sys_shm_wake));
}

test "validation refuses an unknown syscall bit" {
    const caps = [_]CapSpec{.{ .kind = .console, .rights = cap.R_READ }};
    var bad = manifests;
    bad[1].syscalls = bit(63);
    try std.testing.expectError(Invalid.UnknownSyscall, validate(&bad));
    _ = caps;
}

test "validation refuses a writable-executable page" {
    var caps = [_]CapSpec{.{ .kind = .page, .rights = cap.R_WRITE | cap.R_EXEC }};
    var bad = manifests;
    bad[1].caps = &caps;
    try std.testing.expectError(Invalid.WritableExecutablePage, validate(&bad));
}

test "validation refuses a block object outside the storage manifest" {
    var caps = [_]CapSpec{
        .{ .kind = .console, .rights = cap.R_READ },
        .{ .kind = .block, .rights = cap.R_READ },
    };
    var bad = manifests;
    bad[3].caps = &caps;
    try std.testing.expectError(Invalid.BlockOutsideStorage, validate(&bad));
}

test "validation refuses duplicate and empty declarations" {
    var dup = [_]CapSpec{
        .{ .kind = .console, .rights = cap.R_READ },
        .{ .kind = .console, .rights = cap.R_WRITE },
    };
    var bad = manifests;
    bad[1].caps = &dup;
    try std.testing.expectError(Invalid.DuplicateKind, validate(&bad));

    var none = [_]CapSpec{};
    var bad2 = manifests;
    bad2[1].caps = &none;
    try std.testing.expectError(Invalid.EmptyCaps, validate(&bad2));

    var zero = [_]CapSpec{.{ .kind = .page, .rights = 0 }};
    var bad3 = manifests;
    bad3[1].caps = &zero;
    try std.testing.expectError(Invalid.EmptyRights, validate(&bad3));
}

test "the gate is a bit test, and an unknown number is never allowed" {
    try std.testing.expect(allows(.harness, sys_block));
    try std.testing.expect(!allows(.renderer, 47));
    try std.testing.expect(!allows(.renderer, 64));
}
