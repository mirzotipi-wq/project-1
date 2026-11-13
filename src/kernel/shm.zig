//! Shared memory and notifications (phase 25).
//!
//! A shared-memory object is a set of kernel frames that several address spaces
//! point at. The kernel never copies the contents: `shm_map` installs the same
//! physical pages in another process's page tables, so a word written by one
//! process is the word the other reads, at the same offset, with no syscall in
//! between. Ownership of the frames stays with the object, which is why tearing
//! a mapping down must free only the page tables, never the pages.
//!
//! The object is a capability, not a number. Every entry point resolves a handle
//! and checks rights on it, so a process that was never granted the object has
//! nothing to guess: a forged number is EBADF before any page table is touched.
//!
//! Waiting is futex-shaped on purpose. `shm_wait` looks at the 32-bit word at
//! `offset` inside the object and sleeps only if that word still equals the
//! value the caller expected; if it changed, the caller gets EAGAIN and knows a
//! wakeup already happened, which is what removes the lost-wakeup race without
//! any kernel-side queue per caller. Sleepers are parked threads, not spinning
//! loops: a thread that waits is off every run queue until someone wakes it or
//! its deadline passes.

const std = @import("std");
const pmm = @import("pmm.zig");
const cap = @import("cap.zig");
const user_space = @import("addrspace.zig");
const sched = @import("sched.zig");
const thread_mod = @import("thread.zig");
const sync = @import("sync.zig");
const timer = @import("../arch/aarch64/timer.zig");

pub const max_objects: usize = 4;
/// One object holds at most 4 MiB, the size the probe exchanges.
pub const max_pages: usize = 1024;
/// All objects together draw from one pool, so a create cannot exhaust RAM.
pub const pool_pages: usize = 2048;
pub const max_waiters: usize = 8;
pub const max_mappings: usize = 4;

pub const Error = error{
    BadHandle,
    Permission,
    Invalid,
    Fault,
    Timeout,
    Again,
    NoMemory,
    TableFull,
};

const Waiter = struct {
    thread: ?*thread_mod.Thread = null,
    offset: usize = 0,
    woken: bool = false,
};

const Mapping = struct {
    used: bool = false,
    as_id: u32 = 0,
    pid: u32 = 0,
    slot: usize = 0,
    va: usize = 0,
    len: usize = 0,
    writable: bool = false,
};

const Object = struct {
    used: bool = false,
    object_id: u32 = 0,
    base: u32 = 0,
    pages: u32 = 0,
    waiters: [max_waiters]Waiter = [_]Waiter{.{}} ** max_waiters,
    mappings: [max_mappings]Mapping = [_]Mapping{.{}} ** max_mappings,
    mapping_count: u32 = 0,
    /// Every wake that released at least one sleeper bumps this. It is the
    /// object's event counter: monotonic, never reset, visible in `shm`.
    events: u64 = 0,
};

var lock: sync.IrqSpinLock = .{};
var objects: [max_objects]Object = [_]Object{.{}} ** max_objects;
var pool: [pool_pages]usize = [_]usize{0} ** pool_pages;
var pool_used: u32 = 0;
var next_object: u32 = 0;

pub var creates: u64 = 0;
pub var maps: u64 = 0;
pub var unmaps: u64 = 0;
pub var waits: u64 = 0;
pub var wake_calls: u64 = 0;
pub var woken_threads: u64 = 0;
pub var timeouts: u64 = 0;
pub var agains: u64 = 0;
pub var refusals: u64 = 0;
pub var pages_created: u64 = 0;

fn page() usize {
    return pmm.page_size;
}

fn objectFor(id: u32) ?*Object {
    for (&objects) |*o| {
        if (o.used and o.object_id == id) return o;
    }
    return null;
}

fn liveObjects() u32 {
    var n: u32 = 0;
    for (&objects) |*o| {
        if (o.used) n += 1;
    }
    return n;
}

/// Resolve a handle to a shared-memory object and require `need` rights. The
/// object's kind is checked after the rights so a wrong kind cannot be used to
/// probe which object a handle names.
fn resolve(pid: u32, handle: u64, need: u32) Error!*Object {
    const object = cap.access(pid, handle, need) catch |e| {
        refusals += 1;
        return switch (e) {
            error.BadHandle => Error.BadHandle,
            error.Permission => Error.Permission,
            else => Error.Invalid,
        };
    };
    if (object.kind != .shm) {
        refusals += 1;
        return Error.Invalid;
    }
    return objectFor(object.id) orelse Error.Invalid;
}

fn framesOf(o: *Object) []const usize {
    return pool[o.base .. o.base + o.pages];
}

fn valueAt(o: *Object, offset: usize) u32 {
    const pa = pool[o.base + offset / page()];
    const ptr: *const u32 = @ptrFromInt(pa + offset % page());
    return @atomicLoad(u32, ptr, .monotonic);
}

/// Create an object of `pages` zeroed frames and return a handle carrying
/// `rwc`. The frames come from the page allocator, so a request the machine
/// cannot satisfy fails with ENOMEM instead of overcommitting.
pub fn create(pid: u32, pages: u64, alloc: *pmm.PageAllocator) Error!u64 {
    const want: usize = @intCast(@min(pages, max_pages));
    if (want == 0) return Error.Invalid;

    var slot_index: ?usize = null;
    for (&objects, 0..) |*o, i| {
        if (!o.used) {
            slot_index = i;
            break;
        }
    }
    const index = slot_index orelse return Error.TableFull;

    const flags = lock.acquire();
    defer lock.release(flags);
    if (pool_used + want > pool_pages) return Error.NoMemory;

    const base = pool_used;
    var i: usize = 0;
    while (i < want) : (i += 1) {
        // allocZeroed is the whole confidentiality story: a peer can only ever
        // read zeroes it did not put there, never another object's old bytes.
        const pa = alloc.allocZeroed() orelse {
            var j = base;
            while (j < pool_used + i) : (j += 1) alloc.free(pool[j]);
            return Error.NoMemory;
        };
        pool[base + i] = pa;
    }
    pool_used += @intCast(want);

    const object = cap.create(.shm, "shm") orelse {
        var j = base;
        while (j < pool_used) : (j += 1) alloc.free(pool[j]);
        pool_used = base;
        return Error.TableFull;
    };
    next_object += 1;
    objects[index] = .{
        .used = true,
        .object_id = object.id,
        .base = base,
        .pages = @intCast(want),
    };
    pages_created += want;

    const handle = cap.grant(pid, object.id, cap.R_ALL) catch |e| {
        objects[index] = .{};
        var j = base;
        while (j < pool_used) : (j += 1) alloc.free(pool[j]);
        pool_used = base;
        return switch (e) {
            error.TableFull => Error.TableFull,
            else => Error.Invalid,
        };
    };
    creates += 1;
    return handle;
}

/// Map the object into the caller's space. The mapping is writable only when the
/// handle carries `w`, so the same object can be read-write here and read-only
/// there without any extra flag from the user.
pub fn map(pid: u32, as: *user_space.AddressSpace, handle: u64, alloc: *pmm.PageAllocator) Error!u64 {
    const o = try resolve(pid, handle, cap.R_READ);
    const rights = cap.query(pid, handle) catch return Error.BadHandle;
    const writable = (rights & cap.R_WRITE) != 0;

    const flags = lock.acquire();
    defer lock.release(flags);

    var slot: ?usize = null;
    var used = [_]bool{false} ** user_space.shm_slots;
    var slot_i: usize = 0;
    while (slot_i < o.mappings.len) : (slot_i += 1) {
        const m = o.mappings[slot_i];
        if (!m.used or m.as_id != as.id) continue;
        used[m.slot] = true;
    }
    for (used, 0..) |taken, i| {
        if (!taken) {
            slot = i;
            break;
        }
    }
    const chosen = slot orelse return Error.TableFull;

    var free_record: ?usize = null;
    for (&o.mappings, 0..) |*m, i| {
        if (!m.used) {
            free_record = i;
            break;
        }
    }
    const record = free_record orelse return Error.TableFull;

    const va = user_space.shmBase(chosen);
    const len = @as(usize, o.pages) * page();
    if (!user_space.mapShared(as, alloc, va, framesOf(o), writable)) return Error.NoMemory;

    o.mappings[record] = .{
        .used = true,
        .as_id = as.id,
        .pid = pid,
        .slot = chosen,
        .va = va,
        .len = len,
        .writable = writable,
    };
    o.mapping_count += 1;
    maps += 1;
    return va;
}

/// Drop this process's mapping. A second unmap of the same object is EINVAL:
/// the handle is fine, but nothing of it is mapped here any more.
pub fn unmap(pid: u32, as: *user_space.AddressSpace, handle: u64) Error!u64 {
    const o = try resolve(pid, handle, cap.R_READ);

    const flags = lock.acquire();
    defer lock.release(flags);
    for (&o.mappings) |*m| {
        if (!m.used or m.as_id != as.id) continue;
        if (!user_space.unmapShared(as, m.va, m.len)) return Error.Fault;
        m.used = false;
        o.mapping_count -= 1;
        unmaps += 1;
        return 0;
    }
    return Error.Invalid;
}

fn deadlineOf(timeout_ms: u64) u64 {
    if (timeout_ms == 0) return 0;
    return timer.uptimeMs() + timeout_ms;
}

fn expired(deadline: u64) bool {
    return deadline != 0 and timer.uptimeMs() >= deadline;
}

/// Sleep until the word at `offset` is woken or the deadline passes. Returns 0 on
/// a wakeup, EAGAIN if the word was already different from `expected`, and
/// ETIMEDOUT when the deadline fires. Every decision is taken under the object
/// lock, so a wake that lands between the value check and the park cannot be lost.
pub fn wait(pid: u32, handle: u64, offset: u64, expected: u64, timeout_ms: u64) Error!u64 {
    const o = try resolve(pid, handle, cap.R_READ);
    const off: usize = @intCast(offset);
    const total = @as(usize, o.pages) * page();
    if (off % 4 != 0 or off + 4 > total) return Error.Invalid;
    if (expected > std.math.maxInt(u32)) return Error.Invalid;
    const want: u32 = @intCast(expected);
    const deadline = deadlineOf(timeout_ms);
    waits += 1;

    var entry: ?usize = null;
    const t = sched.running();
    while (true) {
        const flags = lock.acquire();
        // A wake addressed to us is the answer, even if the value changed again
        // before we got here.
        if (entry) |e| {
            if (o.waiters[e].woken) {
                o.waiters[e] = .{};
                lock.release(flags);
                return 0;
            }
        }
        if (valueAt(o, off) != want) {
            if (entry) |e| o.waiters[e] = .{};
            lock.release(flags);
            agains += 1;
            return Error.Again;
        }
        if (expired(deadline)) {
            if (entry) |e| o.waiters[e] = .{};
            lock.release(flags);
            timeouts += 1;
            return Error.Timeout;
        }
        if (entry == null) {
            for (&o.waiters, 0..) |*w, i| {
                if (w.thread == null and !w.woken) {
                    w.* = .{ .thread = t, .offset = off };
                    entry = i;
                    break;
                }
            }
            if (entry == null) {
                lock.release(flags);
                return Error.TableFull;
            }
        }
        // Parked with the lock held: a waker either finds this thread in the
        // list or has already marked it woken, and never both.
        t.state = .blocked;
        t.wake_at_ms = deadline;
        lock.release(flags);
        sched.yieldNow();
    }
}

/// Wake up to `count` sleepers waiting on `offset` and report how many were
/// released. The caller normally stores the new value in the word first; the
/// kernel does not interpret the word's meaning, exactly like a futex.
pub fn wake(pid: u32, handle: u64, offset: u64, count: u64) Error!u64 {
    const o = try resolve(pid, handle, cap.R_WRITE);
    const off: usize = @intCast(offset);
    const total = @as(usize, o.pages) * page();
    if (off % 4 != 0 or off + 4 > total) return Error.Invalid;

    const flags = lock.acquire();
    defer lock.release(flags);
    var woken: u64 = 0;
    for (&o.waiters) |*w| {
        if (woken >= count) break;
        const t = w.thread orelse continue;
        if (w.offset != off or w.woken) continue;
        w.woken = true;
        w.thread = null;
        sched.makeReady(t);
        woken += 1;
    }
    wake_calls += 1;
    if (woken > 0) {
        woken_threads += woken;
        o.events += 1;
    }
    return woken;
}

/// Shell view, kept to plain data so the object layout stays private.
pub const Info = struct {
    id: u32,
    pages: u32,
    mappings: u32,
    events: u64,
};

pub const MappingInfo = struct {
    pid: u32,
    va: usize,
    len: usize,
    writable: bool,
};

pub fn objectCount() u32 {
    return liveObjects();
}

pub fn infoAt(index: usize) ?Info {
    if (index >= objects.len or !objects[index].used) return null;
    const o = &objects[index];
    return .{ .id = o.object_id, .pages = o.pages, .mappings = o.mapping_count, .events = o.events };
}

pub fn mappingAt(index: usize, which: usize) ?MappingInfo {
    if (index >= objects.len or !objects[index].used) return null;
    const o = &objects[index];
    var seen: usize = 0;
    for (&o.mappings) |*m| {
        if (!m.used) continue;
        if (seen == which) return .{ .pid = m.pid, .va = m.va, .len = m.len, .writable = m.writable };
        seen += 1;
    }
    return null;
}

pub fn poolUsed() u32 {
    return pool_used;
}
