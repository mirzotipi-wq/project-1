//! Per-process address spaces (phase 22).
//!
//! Every process gets its own top-level translation table, built as a copy of
//! the kernel's. That copy is what makes the design work without a higher-half
//! split: while a process runs, the kernel's own text, stack and device mappings
//! are still present, so a syscall or an interrupt needs no table swap, and the
//! user window is one extra branch of the same tree.
//!
//! The user window lives at 2 GiB, deliberately outside everything the kernel
//! maps, and contains three regions:
//!
//!     0x8000_0000  code    read-only, executable, EL0
//!     0x8100_0000  data    read/write, never executable
//!     0x8200_0000  stack   read/write, never executable (grows down)
//!
//! W^X is a property of the page descriptors, not of the loader: writing to code
//! faults before it reaches memory, from either EL. The stack sits below its top
//! with unmapped pages beneath it, so an overflow lands on a translation fault
//! rather than on whatever the next region happens to be.
//!
//! Switching process means loading that table into TTBR0_EL1 and dropping this
//! core's TLB. ASIDs are not in use yet; the flush is the honest cost of not
//! having them, and it is noted in the plan rather than hidden.

const std = @import("std");
const pmm = @import("pmm.zig");
const cpu = @import("../arch/aarch64/cpu.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const uaccess = @import("uaccess.zig");
const klog = @import("klog.zig");

/// Base of the user window. Outside every kernel mapping (the kernel identity
/// maps RAM at 1 GiB and devices in the first gigabyte).
pub const code_va: usize = 0x8000_0000;
pub const data_va: usize = 0x8100_0000;
pub const stack_va: usize = 0x8200_0000;
/// One past the highest address a process may name.
pub const window_end: usize = 0x8300_0000;

pub const data_pages: usize = 2;
pub const stack_pages: usize = 4;
pub const max_image_bytes: usize = 48 * 1024;
pub const max_frames: usize = 32;
pub const max_tables: usize = 8;
pub const max_spaces: usize = 6;

const page = pmm.page_size;

pub const AddressSpace = struct {
    in_use: bool = false,
    id: u32 = 0,

    /// Physical addresses of the translation tables (L0, L1, L2 and any L3s).
    root: usize = 0,
    l1: usize = 0,
    l2: usize = 0,
    tables: [max_tables]usize = [_]usize{0} ** max_tables,
    table_count: u8 = 0,

    /// Physical frames owned by the process: code, data, stack.
    frames: [max_frames]usize = [_]usize{0} ** max_frames,
    frame_count: u8 = 0,

    regions: [uaccess.max_regions]uaccess.Region = undefined,
    region_count: u8 = 0,

    code_len: usize = 0,
    /// Physical address of the first data page. The kernel writes the startup
    /// arguments here through the identity map, because the user virtual
    /// address is only valid while this process is the one loaded in TTBR0.
    args_pa: usize = 0,

    pub fn stackTop(self: *const AddressSpace) usize {
        _ = self;
        return stack_va + stack_pages * page;
    }

    pub fn bytes(self: *const AddressSpace) usize {
        return (@as(usize, self.frame_count) + @as(usize, self.table_count)) * page;
    }
};

var spaces: [max_spaces]AddressSpace = [_]AddressSpace{.{}} ** max_spaces;
var next_id: u32 = 1;

fn freeSlot() ?*AddressSpace {
    for (&spaces) |*s| {
        if (!s.in_use) return s;
    }
    return null;
}

fn trackTable(as: *AddressSpace, pa: usize) bool {
    if (as.table_count >= max_tables) return false;
    as.tables[as.table_count] = pa;
    as.table_count += 1;
    return true;
}

fn trackFrame(as: *AddressSpace, pa: usize) bool {
    if (as.frame_count >= max_frames) return false;
    as.frames[as.frame_count] = pa;
    as.frame_count += 1;
    return true;
}

fn copyPage(dst: usize, src: usize) void {
    const to: [*]u8 = @ptrFromInt(dst);
    const from: [*]const u8 = @ptrFromInt(src);
    @memcpy(to[0..page], from[0..page]);
}

fn bail(alloc: *pmm.PageAllocator, as: *AddressSpace) ?*AddressSpace {
    destroy(alloc, as);
    return null;
}

/// Walk to the level-3 table for `va`, creating it on the way. Only the user
/// branch of the tree is touched: L0 and L1 are private to the process, so
/// installing a new L3 can never change what another process sees.
fn l3For(as: *AddressSpace, alloc: *pmm.PageAllocator, va: usize) ?*[512]u64 {
    const l2: *[512]u64 = @ptrFromInt(as.l2);
    const entry = &l2[mmu.l2Index(va)];
    if (entry.* & 0b11 != 0b11) {
        // Table frames are tracked with the space, so a failure halfway through
        // a build still frees everything on the way out.
        const table = alloc.allocZeroed() orelse return null;
        if (!trackTable(as, table)) {
            alloc.free(table);
            return null;
        }
        entry.* = table | 0b11;
    }
    return @ptrFromInt(entry.* & mmu.addr_mask);
}

fn mapPage(as: *AddressSpace, alloc: *pmm.PageAllocator, va: usize, pa: usize, exec: bool, writable: bool) bool {
    const l3 = l3For(as, alloc, va) orelse return false;
    l3[mmu.tableIndex(va)] = (pa & mmu.addr_mask) | mmu.userAttrs(exec, writable) | 0b11;
    return true;
}

fn allocFrameInto(as: *AddressSpace, alloc: *pmm.PageAllocator) ?usize {
    const pa = alloc.allocZeroed() orelse return null;
    if (!trackFrame(as, pa)) {
        alloc.free(pa);
        return null;
    }
    return pa;
}

/// Build a fresh address space containing `image` mapped read-only and
/// executable at `code_va`, plus a zeroed data region and stack.
pub fn create(alloc: *pmm.PageAllocator, image: []const u8) ?*AddressSpace {
    if (image.len == 0 or image.len > max_image_bytes) return null;
    const as = freeSlot() orelse return null;
    as.* = .{ .in_use = true, .id = next_id };
    next_id += 1;

    // A process root starts life as an exact copy of the kernel's, so every
    // mapping the kernel relies on stays valid inside this process.
    as.root = allocFrameInto(as, alloc) orelse return bail(alloc, as);
    mmu.copyKernelRoot(as.root);

    // The user window at 2 GiB walks L0[0] -> L1[2] -> L2, and L0[0] is the
    // same level-0 slot that holds the kernel's own mappings for the first
    // 512 GiB. The L1 must therefore be a *clone*: overwriting L0[0] with a
    // fresh table (the obvious mistake) leaves kernel text and RAM unmapped the
    // moment the process is scheduled, and the CPU fault-loops on its own
    // instructions.
    const l1 = allocFrameInto(as, alloc) orelse return bail(alloc, as);
    as.l1 = l1;
    copyPage(l1, mmu.kernelL1Pa());
    @as(*[512]u64, @ptrFromInt(as.root))[mmu.l0Index(code_va)] = l1 | 0b11;

    const l2 = allocFrameInto(as, alloc) orelse return bail(alloc, as);
    as.l2 = l2;
    // L1[2] covers 2..3 GiB and is empty in the kernel: this process gets the
    // only mapping there, and no kernel translation lives in that range.
    @as(*[512]u64, @ptrFromInt(as.l1))[mmu.l1Index(code_va)] = l2 | 0b11;

    // Code: copy the image, map read-only and executable. The frames are
    // zeroed first so the tail of the last page cannot leak kernel memory.
    const code_bytes = std.mem.alignForward(usize, image.len, page);
    var off: usize = 0;
    while (off < code_bytes) : (off += page) {
        const pa = allocFrameInto(as, alloc) orelse return bail(alloc, as);
        const chunk = @min(page, image.len - off);
        const dst: [*]u8 = @ptrFromInt(pa);
        @memcpy(dst[0..chunk], image[off .. off + chunk]);
        if (!mapPage(as, alloc, code_va + off, pa, true, false)) return bail(alloc, as);
    }
    as.code_len = code_bytes;

    // Data: writable, never executable. The first page carries the arguments.
    var i: usize = 0;
    while (i < data_pages) : (i += 1) {
        const pa = allocFrameInto(as, alloc) orelse return bail(alloc, as);
        if (i == 0) as.args_pa = pa;
        if (!mapPage(as, alloc, data_va + i * page, pa, false, true)) return bail(alloc, as);
    }

    i = 0;
    while (i < stack_pages) : (i += 1) {
        const pa = allocFrameInto(as, alloc) orelse return bail(alloc, as);
        if (!mapPage(as, alloc, stack_va + i * page, pa, false, true)) return bail(alloc, as);
    }

    as.regions[0] = .{ .base = code_va, .len = code_bytes, .user_write = false, .user_exec = true, .name = "code" };
    as.regions[1] = .{ .base = data_va, .len = data_pages * page, .user_write = true, .name = "data" };
    as.regions[2] = .{ .base = stack_va, .len = stack_pages * page, .user_write = true, .name = "stack" };
    as.region_count = 3;

    // The instructions were written as data; make them visible to the
    // instruction fetcher before EL0 executes the first one.
    cpu.icIallu();
    return as;
}

/// Release every frame and table the process owns. The observable check is the
/// free-page counter: it must land exactly where it was before the launch.
pub fn destroy(alloc: *pmm.PageAllocator, as: *AddressSpace) void {
    var i: usize = 0;
    while (i < as.frame_count) : (i += 1) alloc.free(as.frames[i]);
    i = 0;
    while (i < as.table_count) : (i += 1) alloc.free(as.tables[i]);
    as.* = .{};
}

/// Write the startup arguments into the process's data page. Uses the physical
/// address, because the kernel runs on its own tables when it does this.
pub fn setArgs(as: *AddressSpace, mode: u64, secret: u64) void {
    if (as.args_pa == 0) return;
    const words: [*]u64 = @ptrFromInt(as.args_pa);
    words[0] = mode;
    words[1] = secret;
}

/// Validate a user pointer against this process, then confirm the mapping
/// exists. Both answers must agree before the kernel dereferences anything.
pub fn checkPtr(as: *const AddressSpace, va: usize, len: usize, access: uaccess.Access) bool {
    if (!uaccess.check(as.regions[0..as.region_count], va, len, access)) return false;
    if (len == 0) return true;
    const root: *const [512]u64 = @ptrFromInt(as.root);
    if (mmu.translateFrom(root, va) == null) return false;
    if (mmu.translateFrom(root, va + len - 1) == null) return false;
    return true;
}

pub fn translate(as: *const AddressSpace, va: usize) ?usize {
    const root: *const [512]u64 = @ptrFromInt(as.root);
    return mmu.translateFrom(root, va);
}

pub fn liveCount() u32 {
    var n: u32 = 0;
    for (&spaces) |*s| {
        if (s.in_use) n += 1;
    }
    return n;
}
