//! Synchronization primitives (phase 13).
//!
//! Four things live here, in increasing order of policy:
//!
//!   * `SpinLock`     — test-and-set with acquire/release ordering. Cheap, no
//!                      fairness, correct for short critical sections.
//!   * `TicketLock`   — FIFO fairness under contention (a thread cannot starve
//!                      behind a stream of newcomers). Used where a lock is
//!                      held across a page-table walk, which can take a while.
//!   * `IrqSpinLock`  — the only lock allowed in code that can also run in
//!                      interrupt context on the same core: it masks IRQs for
//!                      the whole critical section, so an interrupt handler on
//!                      this core can never spin forever waiting for the thread
//!                      it interrupted to release.
//!   * `WaitQueue` / `Semaphore` — blocking primitives with a signed permit
//!                      count, the classic Dijkstra formulation. The count is
//!                      what makes wakeups impossible to lose: a post that
//!                      arrives before the waiter blocks is remembered as a
//!                      permit, and a post that arrives after hands the permit
//!                      straight to the waiter.
//!
//! The queue and semaphore are generic over a backend so the exact same code
//! that runs in the kernel is executed by the host unit tests with a scripted
//! stand-in for the scheduler.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Interrupt masking
// ---------------------------------------------------------------------------

/// Save DAIF and mask IRQs. On any other target (host unit tests) this is a
/// no-op that returns a token `irqRestore` accepts. The target-specific bodies
/// are selected at comptime so the host build never tries to assemble `mrs`.
pub const irqSave = if (builtin.cpu.arch == .aarch64) struct {
    fn save() u64 {
        var flags: u64 = undefined;
        asm volatile ("mrs %[out], daif" : [out] "=r" (flags));
        asm volatile ("msr daifset, #2" ::: "memory");
        return flags;
    }
}.save else struct {
    fn save() u64 {
        return 0;
    }
}.save;

pub const irqRestore = if (builtin.cpu.arch == .aarch64) struct {
    fn restore(flags: u64) void {
        asm volatile ("msr daif, %[in]" :: [in] "r" (flags) : "memory");
    }
}.restore else struct {
    fn restore(_: u64) void {}
}.restore;

inline fn pause() void {
    std.atomic.spinLoopHint();
}

// ---------------------------------------------------------------------------
// Spin lock
// ---------------------------------------------------------------------------

pub const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn acquire(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            // Spin on a plain load: the cache line is shared read-only until
            // the holder releases, so this does not bounce needlessly.
            while (self.state.load(.monotonic) != 0) pause();
        }
    }

    pub fn tryAcquire(self: *SpinLock) bool {
        return self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }

    pub fn release(self: *SpinLock) void {
        self.state.store(0, .release);
    }

    pub fn isLocked(self: *const SpinLock) bool {
        return self.state.load(.monotonic) != 0;
    }
};

// ---------------------------------------------------------------------------
// Ticket lock
// ---------------------------------------------------------------------------

pub const TicketLock = struct {
    next: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    owner: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Returns this acquisition's ticket (useful for debugging lock order).
    pub fn acquire(self: *TicketLock) u32 {
        const mine = self.next.fetchAdd(1, .monotonic);
        while (self.owner.load(.acquire) != mine) pause();
        return mine;
    }

    pub fn release(self: *TicketLock) void {
        _ = self.owner.fetchAdd(1, .release);
    }
};

// ---------------------------------------------------------------------------
// IRQ-safe spin lock
// ---------------------------------------------------------------------------

pub const IrqSpinLock = struct {
    lock: SpinLock = .{},

    /// Masks IRQs and takes the lock. The returned token must be handed back to
    /// `release`; it restores the previous interrupt mask rather than blindly
    /// enabling interrupts (so nesting inside an exception handler is safe).
    pub fn acquire(self: *IrqSpinLock) u64 {
        const flags = irqSave();
        self.lock.acquire();
        return flags;
    }

    pub fn release(self: *IrqSpinLock, flags: u64) void {
        self.lock.release();
        irqRestore(flags);
    }
};

// ---------------------------------------------------------------------------
// Wait queue
// ---------------------------------------------------------------------------

/// Intrusive FIFO of waiters. `T` is any type with a `wait_next: ?*T` field, so
/// the kernel passes `Thread` and the tests pass a three-line fake.
pub fn WaitQueue(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        len: u32 = 0,

        const Self = @This();

        pub fn push(self: *Self, item: *T) void {
            @field(item, "wait_next") = null;
            if (self.tail) |tail| {
                @field(tail, "wait_next") = item;
            } else {
                self.head = item;
            }
            self.tail = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?*T {
            const first = self.head orelse return null;
            self.head = @field(first, "wait_next");
            if (self.head == null) self.tail = null;
            @field(first, "wait_next") = null;
            self.len -= 1;
            return first;
        }

        pub fn empty(self: *const Self) bool {
            return self.head == null;
        }
    };
}

// ---------------------------------------------------------------------------
// Counting semaphore
// ---------------------------------------------------------------------------

/// Backend contract used by `Semaphore`:
///
///   Handle            opaque waiter identity (a thread pointer in the kernel)
///   current() Handle  the caller's identity
///   block(h)          mark `h` as blocked (must not schedule)
///   wake(h)           mark `h` runnable (must not schedule)
///   schedule()        give up the CPU until woken
///
/// `block` is called while the semaphore's spin lock is held; `schedule` is
/// called only after the lock is released. That split is what makes a wakeup
/// that races with the block impossible to lose.
pub fn Semaphore(comptime Backend: type) type {
    return struct {
        /// IRQ-safe on purpose: a waiter must not be preempted between pushing
        /// itself onto the queue and blocking, or the permit it is owed could
        /// be handed to a thread that is still runnable.
        lock: IrqSpinLock = .{},
        /// Negative values count waiting threads, non-negative values count
        /// available permits. Exactly one meaning is active at a time.
        count: i32 = 0,
        waiters: WaitQueue(Backend.Node) = .{},

        const Self = @This();

        pub fn post(self: *Self) void {
            self.postMany(1);
        }

        pub fn postMany(self: *Self, n: u32) void {
            const flags = self.lock.acquire();
            defer self.lock.release(flags);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                self.count += 1;
                if (self.count <= 0) {
                    if (self.waiters.pop()) |waiter| Backend.wake(waiter);
                }
            }
        }

        pub fn wait(self: *Self) void {
            var flags = self.lock.acquire();
            self.count -= 1;
            if (self.count < 0) {
                const me = Backend.current();
                self.waiters.push(me);
                // Transition to blocked *while holding the lock*: a concurrent
                // post either finds us in the queue (and wakes us) or finds a
                // permit, never neither.
                Backend.block(me);
                self.lock.release(flags);
                Backend.schedule();
                flags = self.lock.acquire();
            }
            self.lock.release(flags);
        }

        pub fn permits(self: *const Self) i32 {
            return self.count;
        }

        pub fn waiterCount(self: *const Self) u32 {
            return self.waiters.len;
        }
    };
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------

const TestWaiter = struct {
    wait_next: ?*TestWaiter = null,
    id: u32 = 0,
};

const TestBackend = struct {
    pub const Node = TestWaiter;
    pub const Handle = *TestWaiter;

    var blocked: u32 = 0;
    var woken: u32 = 0;
    var scheduled: u32 = 0;
    var me: TestWaiter = .{ .id = 7 };

    pub fn current() Handle {
        return &me;
    }
    pub fn block(_: Handle) void {
        blocked += 1;
    }
    pub fn wake(_: Handle) void {
        woken += 1;
    }
    pub fn schedule() void {
        scheduled += 1;
    }
    fn reset() void {
        blocked = 0;
        woken = 0;
        scheduled = 0;
        me = .{ .id = 7 };
    }
};

const TestSemaphore = Semaphore(TestBackend);

test "spin lock serialises a contended counter without lost updates" {
    const Shared = struct {
        var lock: SpinLock = .{};
        var counter: u64 = 0;
        fn worker() void {
            for (0..2000) |_| {
                lock.acquire();
                counter += 1;
                lock.release();
            }
        }
    };
    Shared.counter = 0;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.worker, .{});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 8000), Shared.counter);
}

test "ticket lock serialises a contended counter and hands out FIFO tickets" {
    const Shared = struct {
        var lock: TicketLock = .{};
        var counter: u64 = 0;
        fn worker() void {
            for (0..1500) |_| {
                _ = lock.acquire();
                counter += 1;
                lock.release();
            }
        }
    };
    Shared.counter = 0;
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.worker, .{});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 4500), Shared.counter);
    try std.testing.expectEqual(@as(u32, 4500), Shared.lock.next.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 4500), Shared.lock.owner.load(.monotonic));
}

test "tryAcquire fails while the lock is held" {
    var lock: SpinLock = .{};
    try std.testing.expect(lock.tryAcquire());
    try std.testing.expect(!lock.tryAcquire());
    lock.release();
    try std.testing.expect(lock.tryAcquire());
    lock.release();
}

test "wait queue keeps strict FIFO order" {
    const Q = WaitQueue(TestWaiter);
    var q = Q{};
    var items: [6]TestWaiter = undefined;
    for (&items, 0..) |*item, i| item.* = .{ .id = @intCast(i) };
    try std.testing.expect(q.empty());

    q.push(&items[0]);
    q.push(&items[1]);
    q.push(&items[2]);
    try std.testing.expectEqual(@as(u32, 3), q.len);

    const first = q.pop().?;
    try std.testing.expectEqual(@as(u32, 0), first.id);
    try std.testing.expect(first.wait_next == null);

    q.push(&items[3]);
    const second = q.pop().?;
    const third = q.pop().?;
    const fourth = q.pop().?;
    try std.testing.expectEqual(@as(u32, 1), second.id);
    try std.testing.expectEqual(@as(u32, 2), third.id);
    try std.testing.expectEqual(@as(u32, 3), fourth.id);
    try std.testing.expect(q.empty());
    try std.testing.expectEqual(@as(u32, 0), q.len);
    try std.testing.expect(q.pop() == null);
}

test "semaphore: a post with no waiter becomes a permit" {
    TestBackend.reset();
    var sem = TestSemaphore{};
    sem.post();
    try std.testing.expectEqual(@as(i32, 1), sem.permits());
    sem.wait();
    try std.testing.expectEqual(@as(i32, 0), sem.permits());
    try std.testing.expectEqual(@as(u32, 0), TestBackend.blocked);
    try std.testing.expectEqual(@as(u32, 0), TestBackend.scheduled);
}

test "semaphore: a waiter blocks, and the later post is delivered to it" {
    TestBackend.reset();
    var sem = TestSemaphore{};

    // No permit available: the waiter must enqueue itself and block, and the
    // count must go negative to record the outstanding obligation.
    sem.wait();
    try std.testing.expectEqual(@as(i32, -1), sem.permits());
    try std.testing.expectEqual(@as(u32, 1), TestBackend.blocked);
    try std.testing.expectEqual(@as(u32, 1), TestBackend.scheduled);
    try std.testing.expectEqual(@as(u32, 1), sem.waiterCount());

    // The post must be handed to the waiter, not banked as a permit.
    sem.post();
    try std.testing.expectEqual(@as(u32, 1), TestBackend.woken);
    try std.testing.expectEqual(@as(i32, 0), sem.permits());
    try std.testing.expectEqual(@as(u32, 0), sem.waiterCount());
}

test "semaphore: posting N permits wakes at most N waiters" {
    TestBackend.reset();
    var sem = TestSemaphore{};
    var waiters: [3]TestWaiter = undefined;
    for (&waiters, 0..) |*w, i| {
        w.* = .{ .id = @intCast(i + 1) };
        sem.waiters.push(w);
        sem.count -= 1;
    }
    sem.postMany(2);
    try std.testing.expectEqual(@as(u32, 2), TestBackend.woken);
    try std.testing.expectEqual(@as(u32, 1), sem.waiterCount());
    // Three waiters, two posts: one obligation is still outstanding, so the
    // permit count stays negative by exactly one.
    try std.testing.expectEqual(@as(i32, -1), sem.permits());
    sem.post();
    try std.testing.expectEqual(@as(u32, 3), TestBackend.woken);
    try std.testing.expectEqual(@as(u32, 0), sem.waiterCount());
}
