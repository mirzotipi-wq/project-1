//! System call surface. The trap plumbing is final; phase 21 replaces the
//! debug entry points with the capability-checked table when user mode lands.
//!
//! Threading calls are deliberately syscalls and not plain function calls: a
//! thread that blocks or exits must do so from an exception frame, because that
//! frame *is* its context. Going through SVC buys the scheduler a valid frame
//! for free and keeps one switching mechanism instead of two.

const std = @import("std");
const cpu = @import("../arch/aarch64/cpu.zig");
const trap = @import("../arch/aarch64/trap.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const klog = @import("klog.zig");
const uart = @import("../devices/pl011.zig");
const timer = @import("../arch/aarch64/timer.zig");
const sched = @import("sched.zig");
const percpu = @import("percpu.zig");
const process = @import("process.zig");
const uaccess = @import("uaccess.zig");
const user_space = @import("addrspace.zig");
const cap = @import("cap.zig");
const ipc = @import("ipc.zig");
const shm = @import("shm.zig");
const registry = @import("registry.zig");
const names = @import("names.zig");
const account = @import("account.zig");
const sandbox = @import("sandbox.zig");

/// System calls a process may make from EL0. Deliberately small: each one is a
/// place where the kernel acts with its own authority, so the surface is the
/// contract.
pub const UserNr = enum(u64) {
    write = 1,
    exit = 2,
    getpid = 3,
    yield = 4,
    sleep_ms = 5,
    uptime_ms = 6,

    // Capability operations. Every one of them names its object with a handle;
    // none of them accepts a raw kernel identifier.
    cap_query = 20,
    cap_derive = 21,
    cap_revoke = 22,
    cap_close = 23,
    cap_read = 24,
    cap_write = 25,
    cap_control = 26,
    cap_map = 27,

    // IPC endpoints (phase 24). A process reaches an endpoint only through a
    // handle; none of these takes an object identifier.
    ipc_create = 28,
    ipc_send = 29,
    ipc_call = 30,
    ipc_recv = 31,
    ipc_reply = 32,
    shm_create = 33,
    shm_map = 34,
    shm_unmap = 35,
    shm_wait = 36,
    shm_wake = 37,

    // Service registry (phase 28). The name is a byte string in the caller's own
    // address space; the answer is a reason code, never an error that has to be
    // guessed from a pid.
    resolve = 38,

    // Resource accounting (phase 29). A process asks about itself: the answer is
    // its own usage, its own quota's verdict and whether the machine reported
    // memory pressure. There is no way to name another process.
    account = 39,

    // Raw block device (phase 30). A read of eight bytes at a byte offset, on a
    // handle that names the block object. Reaching the disk is therefore a
    // capability question, and a sandbox without the handle cannot ask at all.
    block = 40,
};

/// Rejected user pointers, counted so the probe can prove the kernel refused to
/// follow one rather than merely returning an error.
pub var rejected_ptr: u64 = 0;
pub var user_calls: u64 = 0;
pub var cap_calls: u64 = 0;
pub var ipc_calls: u64 = 0;
pub var shm_calls: u64 = 0;

pub const Nr = enum(u64) {
    debug_write = 1,
    debug_exit = 2,
    uptime_ms = 3,
    cpu_id = 4,

    yield = 64,
    exit = 65,
    sleep_ms = 66,
    thread_id = 67,
    thread_count = 68,
};

pub const Errno = enum(i64) {
    perm = -1,
    again = -11,
    timeout = -110,
    badf = -9,
    nomem = -12,
    fault = -14,
    invalid = -22,
    mfile = -24,
    nosys = -38,
};

fn errnoShm(e: shm.Error) u64 {
    return switch (e) {
        error.BadHandle => errno(.badf),
        error.Permission => errno(.perm),
        error.Invalid => errno(.invalid),
        error.Fault => errno(.fault),
        error.Timeout => errno(.timeout),
        error.Again => errno(.again),
        error.NoMemory => errno(.nomem),
        error.TableFull => errno(.mfile),
    };
}

fn errnoIpc(e: ipc.Error) u64 {
    return switch (e) {
        error.BadHandle => errno(.badf),
        error.Permission => errno(.perm),
        error.Invalid => errno(.invalid),
        error.Fault => errno(.fault),
        error.Timeout => errno(.timeout),
        error.Again => errno(.again),
        error.NoMemory => errno(.nomem),
        error.TableFull => errno(.mfile),
    };
}

/// Run one IPC operation: a result becomes the syscall's two return registers,
/// a parked caller reschedules instead of returning.
fn ipcFinish(r: ipc.Error!ipc.Outcome, frame: *trap.Frame) Action {
    const outcome = r catch |e| {
        frame.x[0] = errnoIpc(e);
        frame.x[1] = 0;
        return .keep;
    };
    return switch (outcome) {
        .done => |d| blk: {
            frame.x[0] = d.value;
            frame.x[1] = d.extra;
            break :blk .keep;
        },
        .block => .reschedule,
    };
}

fn errnoOf(e: cap.Error) u64 {
    return switch (e) {
        error.BadHandle => errno(.badf),
        error.Permission => errno(.perm),
        error.TableFull => errno(.mfile),
        error.Invalid => errno(.invalid),
    };
}

/// What the exception layer must do after the call returns.
pub const Action = enum {
    /// Resume the caller at the returned frame.
    keep,
    /// Re-enter the scheduler; a different thread may come back.
    reschedule,
};

fn errno(code: Errno) u64 {
    return @bitCast(@intFromEnum(code));
}

/// Validate a buffer against the live page tables. Anything the MMU cannot
/// translate must never be dereferenced on behalf of a caller.
fn validRange(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr + len < ptr) return false;
    if (mmu.translate(ptr) == null) return false;
    if (mmu.translate(ptr + len - 1) == null) return false;
    return true;
}

pub fn handle(number: u64, frame: *trap.Frame) Action {
    switch (number) {
        @intFromEnum(Nr.debug_write) => {
            const ptr = frame.x[0];
            const len = frame.x[1];
            if (!validRange(ptr, len)) {
                frame.x[0] = errno(.fault);
            } else {
                const bytes: [*]const u8 = @ptrFromInt(ptr);
                uart.writeAll(bytes[0..len]);
                frame.x[0] = len;
            }
            return .keep;
        },
        @intFromEnum(Nr.debug_exit) => {
            klog.info("syscall", "thread {d} exiting at pc=0x{x}", .{ sched.running().id, frame.elr });
            sched.markDead();
            return .reschedule;
        },
        @intFromEnum(Nr.uptime_ms) => {
            frame.x[0] = timer.uptimeMs();
            return .keep;
        },
        @intFromEnum(Nr.cpu_id) => {
            frame.x[0] = percpu.this().id;
            return .keep;
        },
        @intFromEnum(Nr.yield) => {
            frame.x[0] = 0;
            return .reschedule;
        },
        @intFromEnum(Nr.exit) => {
            sched.markDead();
            return .reschedule;
        },
        @intFromEnum(Nr.sleep_ms) => {
            sched.sleepCurrent(frame.x[0]);
            frame.x[0] = 0;
            return .reschedule;
        },
        @intFromEnum(Nr.thread_id) => {
            frame.x[0] = sched.running().id;
            return .keep;
        },
        @intFromEnum(Nr.thread_count) => {
            frame.x[0] = sched.threadCount();
            return .keep;
        },
        else => {
            klog.warn("syscall", "unimplemented syscall {d} from pc=0x{x}", .{ number, frame.elr });
            frame.x[0] = errno(.nosys);
            return .keep;
        },
    }
}

test "syscall numbers stay out of the signal-handler range" {
    try std.testing.expectEqual(@as(u64, 64), Nr.yield);
    try std.testing.expectEqual(@as(u64, 65), Nr.exit);
}

/// EL0 entry point. Every argument is untrusted: numbers are matched against a
/// fixed table, and every pointer is validated against the calling process's own
/// regions *and* its live page tables before the kernel touches it.
/// A block-device attempt that did not reach the object. Counted every time,
/// logged a few times (see `Process.sandbox_denials`).
fn denyBlock(pid: u32) void {
    sandbox.block_denials += 1;
    if (process.processOfPid(pid)) |p| {
        p.sandbox_denials +|= 1;
        if (p.sandbox_denials <= 4) {
            klog.warn("sandbox", "pid {d}: block device refused — no such capability", .{pid});
        }
    }
}

pub fn handleUser(number: u64, frame: *trap.Frame) Action {
    user_calls += 1;
    const t = sched.running();
    const as = t.address_space orelse {
        klog.warn("syscall", "EL0 call {d} from a thread with no address space", .{number});
        frame.x[0] = errno(.invalid);
        return .keep;
    };

    // Phase 30: the manifest is checked before dispatch, not inside each call.
    // A process that never declared a facility cannot reach it even if it runs
    // arbitrary code — the table entry, not the program, decides.
    const caller = process.currentPid();
    if (!sandbox.allowsForPid(caller, number)) {
        sandbox.denied += 1;
        if (process.processOfPid(caller)) |p| {
            p.sandbox_denials +|= 1;
            if (p.sandbox_denials <= 4) {
                klog.warn("sandbox", "pid {d}: syscall {d} refused — not in its manifest", .{ caller, number });
            }
        }
        frame.x[0] = errno(.perm);
        return .keep;
    }

    switch (number) {
        @intFromEnum(UserNr.write) => {
            const ptr = frame.x[0];
            const len = frame.x[1];
            if (len > 4096 or !user_space.checkPtr(as, ptr, len, .read)) {
                rejected_ptr += 1;
                klog.warn("syscall", "pid {d}: refused write({d} bytes) at 0x{x} — pointer is outside the process", .{ process.currentPid(), len, ptr });
                frame.x[0] = errno(.fault);
                return .keep;
            }
            const bytes: [*]const u8 = @ptrFromInt(ptr);
            uart.writeAll(bytes[0..len]);
            frame.x[0] = len;
            return .keep;
        },
        @intFromEnum(UserNr.exit) => {
            process.exitCurrent(@bitCast(frame.x[0]));
            return .reschedule;
        },
        @intFromEnum(UserNr.getpid) => {
            frame.x[0] = process.currentPid();
            return .keep;
        },
        @intFromEnum(UserNr.yield) => {
            frame.x[0] = 0;
            return .reschedule;
        },
        @intFromEnum(UserNr.sleep_ms) => {
            sched.sleepCurrent(frame.x[0]);
            frame.x[0] = 0;
            return .reschedule;
        },
        @intFromEnum(UserNr.uptime_ms) => {
            frame.x[0] = timer.uptimeMs();
            return .keep;
        },

        @intFromEnum(UserNr.cap_query) => {
            cap_calls += 1;
            frame.x[0] = cap.query(process.currentPid(), frame.x[0]) catch |e| errnoOf(e);
            return .keep;
        },
        @intFromEnum(UserNr.cap_derive) => {
            cap_calls += 1;
            const rights: u32 = @truncate(frame.x[1]);
            frame.x[0] = cap.derive(process.currentPid(), frame.x[0], rights) catch |e| errnoOf(e);
            return .keep;
        },
        @intFromEnum(UserNr.cap_revoke) => {
            cap_calls += 1;
            cap.revoke(process.currentPid(), frame.x[0]) catch |e| {
                frame.x[0] = errnoOf(e);
                return .keep;
            };
            frame.x[0] = 0;
            return .keep;
        },
        @intFromEnum(UserNr.cap_close) => {
            cap_calls += 1;
            cap.close(process.currentPid(), frame.x[0]) catch |e| {
                frame.x[0] = errnoOf(e);
                return .keep;
            };
            frame.x[0] = 0;
            return .keep;
        },
        @intFromEnum(UserNr.cap_read) => {
            cap_calls += 1;
            return capRead(as, frame);
        },
        @intFromEnum(UserNr.cap_write) => {
            cap_calls += 1;
            return capWrite(as, frame);
        },
        @intFromEnum(UserNr.cap_control) => {
            cap_calls += 1;
            const object = cap.access(process.currentPid(), frame.x[0], cap.R_CONTROL) catch |e| {
                frame.x[0] = errnoOf(e);
                return .keep;
            };
            switch (object.kind) {
                .ledger => {
                    object.epoch += 1;
                    frame.x[0] = object.epoch;
                },
                else => frame.x[0] = errno(.invalid),
            }
            return .keep;
        },
        @intFromEnum(UserNr.cap_map) => {
            cap_calls += 1;
            // Execute-or-map: the only way a page enters a process's address
            // space is through a handle that carries the right to do it.
            const object = cap.access(process.currentPid(), frame.x[0], cap.R_EXEC) catch |e| {
                frame.x[0] = errnoOf(e);
                return .keep;
            };
            if (object.kind != .page or object.pa == 0) {
                frame.x[0] = errno(.invalid);
                return .keep;
            }
            const alloc = process.pageAllocator() orelse {
                frame.x[0] = errno(.nomem);
                return .keep;
            };
            if (!user_space.mapKernelPage(as, alloc, user_space.mapped_va, object.pa)) {
                frame.x[0] = errno(.nomem);
                return .keep;
            }
            frame.x[0] = user_space.mapped_va;
            return .keep;
        },

        @intFromEnum(UserNr.ipc_create) => {
            ipc_calls += 1;
            frame.x[0] = ipc.create(process.currentPid()) catch |e| errnoIpc(e);
            return .keep;
        },
        @intFromEnum(UserNr.ipc_send) => {
            ipc_calls += 1;
            return ipcFinish(ipc.send(
                process.currentPid(),
                as,
                frame.x[0],
                frame.x[1],
                frame.x[2],
                frame.x[3],
            ), frame);
        },
        @intFromEnum(UserNr.ipc_call) => {
            ipc_calls += 1;
            return ipcFinish(ipc.call(
                process.currentPid(),
                as,
                frame.x[0],
                frame.x[1],
                frame.x[2],
                frame.x[3],
                frame.x[4],
            ), frame);
        },
        @intFromEnum(UserNr.ipc_recv) => {
            ipc_calls += 1;
            return ipcFinish(ipc.recv(
                process.currentPid(),
                as,
                frame.x[0],
                frame.x[1],
                frame.x[2],
            ), frame);
        },
        @intFromEnum(UserNr.ipc_reply) => {
            ipc_calls += 1;
            return ipcFinish(ipc.reply(
                process.currentPid(),
                as,
                frame.x[0],
                frame.x[1],
            ), frame);
        },
        @intFromEnum(UserNr.shm_create) => {
            shm_calls += 1;
            const alloc = process.pageAllocator() orelse {
                frame.x[0] = errno(.nomem);
                return .keep;
            };
            frame.x[0] = shm.create(process.currentPid(), frame.x[0], alloc) catch |e| errnoShm(e);
            return .keep;
        },
        @intFromEnum(UserNr.shm_map) => {
            shm_calls += 1;
            const alloc = process.pageAllocator() orelse {
                frame.x[0] = errno(.nomem);
                return .keep;
            };
            frame.x[0] = shm.map(process.currentPid(), as, frame.x[0], alloc) catch |e| errnoShm(e);
            return .keep;
        },
        @intFromEnum(UserNr.shm_unmap) => {
            shm_calls += 1;
            frame.x[0] = shm.unmap(process.currentPid(), as, frame.x[0]) catch |e| errnoShm(e);
            return .keep;
        },
        @intFromEnum(UserNr.shm_wait) => {
            shm_calls += 1;
            frame.x[0] = shm.wait(
                process.currentPid(),
                frame.x[0],
                frame.x[1],
                frame.x[2],
                frame.x[3],
            ) catch |e| errnoShm(e);
            return .keep;
        },
        @intFromEnum(UserNr.shm_wake) => {
            shm_calls += 1;
            frame.x[0] = shm.wake(
                process.currentPid(),
                frame.x[0],
                frame.x[1],
                frame.x[2],
            ) catch |e| errnoShm(e);
            return .keep;
        },
        @intFromEnum(UserNr.block) => {
            // The raw device. Every failure here is counted as a denied attempt,
            // because the interesting number is how often something without the
            // capability tried.
            const object = cap.access(process.currentPid(), frame.x[0], cap.R_READ) catch {
                denyBlock(caller);
                frame.x[0] = errno(.badf);
                return .keep;
            };
            const offset = frame.x[1];
            if (object.kind != .block or offset > 56 or offset % 8 != 0) {
                denyBlock(caller);
                frame.x[0] = errno(.perm);
                return .keep;
            }
            const out = frame.x[2];
            if (!user_space.checkPtr(as, out, 8, .write)) {
                rejected_ptr += 1;
                frame.x[0] = errno(.fault);
                return .keep;
            }
            const word: *u64 = @ptrFromInt(out);
            word.* = std.mem.readInt(u64, object.bytes[@intCast(offset)..][0..8], .little);
            frame.x[0] = 0;
            return .keep;
        },
        @intFromEnum(UserNr.account) => {
            const space = sched.running().address_space orelse {
                frame.x[0] = errno(.invalid);
                return .keep;
            };
            const out = frame.x[0];
            if (!user_space.checkPtr(space, out, 48, .write)) {
                rejected_ptr += 1;
                frame.x[0] = errno(.fault);
                return .keep;
            }
            const snap = account.snapshot(process.currentPid());
            const words: [*]u64 = @ptrFromInt(out);
            words[0] = snap.pages;
            words[1] = snap.handles;
            words[2] = snap.cpu_ms;
            words[3] = @intFromEnum(snap.level);
            words[4] = snap.score;
            words[5] = snap.flags;
            frame.x[0] = 0;
            return .keep;
        },
        @intFromEnum(UserNr.resolve) => {
            // resolve(name_ptr, name_len, out_pid) -> reason code. The program asks
            // for a name and is told *why* it cannot have it; it is never handed a
            // pid that might not exist and never an errno it has to interpret.
            const space = sched.running().address_space orelse {
                frame.x[0] = @intFromEnum(names.Reason.unknown);
                return .keep;
            };
            const ptr = frame.x[0];
            const len = frame.x[1];
            const out = frame.x[2];
            if (len == 0 or len > names.max_len or
                !user_space.checkPtr(space, ptr, len, .read) or
                !user_space.checkPtr(space, out, 8, .write))
            {
                rejected_ptr += 1;
                frame.x[0] = @intFromEnum(names.Reason.invalid_name);
                return .keep;
            }
            const bytes: [*]const u8 = @ptrFromInt(ptr);
            const r = registry.lookup(bytes[0..len]);
            if (r.reason == .ok) {
                const pid_out: *u64 = @ptrFromInt(out);
                pid_out.* = r.pid;
            }
            frame.x[0] = @intFromEnum(r.reason);
            return .keep;
        },
        else => {
            klog.warn("syscall", "pid {d}: unknown syscall {d} from pc=0x{x}", .{ process.currentPid(), number, frame.elr });
            frame.x[0] = errno(.nosys);
            return .keep;
        },
    }
}

test "user syscall numbers are the documented ones" {
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(UserNr.write));
    try std.testing.expectEqual(@as(u64, 6), @intFromEnum(UserNr.uptime_ms));
}

/// Capability-gated read: the handle decides what may be read, the pointer is
/// validated only afterwards. Nothing about the object's identity comes from
/// the user, so a forged handle cannot name anything.
fn capRead(as: *user_space.AddressSpace, frame: *trap.Frame) Action {
    const h = frame.x[0];
    const ptr = frame.x[1];
    const len = frame.x[2];
    if (len > 64) {
        frame.x[0] = errno(.invalid);
        return .keep;
    }
    const object = cap.access(process.currentPid(), h, cap.R_READ) catch |e| {
        frame.x[0] = errnoOf(e);
        return .keep;
    };
    if (!user_space.checkPtr(as, ptr, len, .write)) {
        rejected_ptr += 1;
        frame.x[0] = errno(.fault);
        return .keep;
    }
    switch (object.kind) {
        .ledger => {
            const n = @min(len, object.len);
            const dst: [*]u8 = @ptrFromInt(ptr);
            @memcpy(dst[0..n], object.bytes[0..n]);
            frame.x[0] = n;
        },
        .supervisor => {
            // Another process's state, reduced to exactly what READ exposes.
            if (len < 16) {
                frame.x[0] = errno(.invalid);
                return .keep;
            }
            const dst: [*]u64 = @ptrFromInt(ptr);
            dst[0] = 1; // the supervisor (the shell) is process slot 1
            dst[1] = sched.threadCount();
            var copied: usize = 16;
            if (len >= 24) {
                dst[2] = percpu.cpu_count;
                copied = 24;
            }
            frame.x[0] = copied;
        },
        else => frame.x[0] = errno(.invalid),
    }
    return .keep;
}

/// Capability-gated write.
fn capWrite(as: *user_space.AddressSpace, frame: *trap.Frame) Action {
    const h = frame.x[0];
    const ptr = frame.x[1];
    const len = frame.x[2];
    if (len > 64) {
        frame.x[0] = errno(.invalid);
        return .keep;
    }
    const object = cap.access(process.currentPid(), h, cap.R_WRITE) catch |e| {
        frame.x[0] = errnoOf(e);
        return .keep;
    };
    if (!user_space.checkPtr(as, ptr, len, .read)) {
        rejected_ptr += 1;
        frame.x[0] = errno(.fault);
        return .keep;
    }
    switch (object.kind) {
        .ledger => {
            const n = @min(len, object.bytes.len);
            const src: [*]const u8 = @ptrFromInt(ptr);
            @memcpy(object.bytes[0..n], src[0..n]);
            object.len = n;
            object.version += 1;
            frame.x[0] = n;
        },
        else => frame.x[0] = errno(.invalid),
    }
    return .keep;
}
