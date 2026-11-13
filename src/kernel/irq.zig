//! Interrupt registry and dispatch (phase 11/13 groundwork).
//!
//! The exception layer acks the controller and calls `dispatch`, which routes
//! to a registered handler and signals end-of-interrupt. Handlers must be
//! short; deferred work belongs on a workqueue (phase 19).

const gic = @import("../arch/aarch64/gic.zig");
const klog = @import("klog.zig");

pub const Handler = *const fn (intid: u32) void;

const max_intid = 256;

var handlers: [max_intid]?Handler = [_]?Handler{null} ** max_intid;
var counts: [max_intid]u32 = [_]u32{0} ** max_intid;
var spurious: u32 = 0;
var unhandled: u32 = 0;

pub fn register(intid: u32, handler: Handler) void {
    if (intid >= max_intid) {
        klog.warn("irq", "refusing to register handler for intid {d}", .{intid});
        return;
    }
    handlers[intid] = handler;
    gic.enableIrq(intid);
}

pub fn dispatch() void {
    const id = gic.acknowledge();
    if (id >= 1020) {
        spurious += 1;
        return;
    }
    if (id < max_intid) {
        counts[id] += 1;
        if (handlers[id]) |handler| {
            handler(id);
        } else {
            unhandled += 1;
            klog.warn("irq", "unhandled interrupt {d}", .{id});
        }
    } else {
        unhandled += 1;
    }
    gic.endOfInterrupt(id);
}

pub fn countFor(intid: u32) u32 {
    if (intid >= max_intid) return 0;
    return counts[intid];
}

pub fn stats() struct { spurious: u32, unhandled: u32 } {
    return .{ .spurious = spurious, .unhandled = unhandled };
}
