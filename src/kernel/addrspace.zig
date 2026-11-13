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
const elf = @import("elf.zig");
const klog = @import("klog.zig");

/// Base of the user window. Outside every kernel mapping (the kernel identity
/// maps RAM at 1 GiB and devices in the first gigabyte).
pub const code_va: usize = 0x8000_0000;
pub const data_va: usize = 0x8100_0000;
pub const stack_va: usize = 0x8200_0000;
/// One past the highest address a process may name.
/// Shared-memory window: four 4 MiB slots per process, above the stack.
pub const shm_va: usize = 0x8400_0000;
pub const shm_slot_bytes: usize = 4 * 1024 * 1024;
pub const shm_slots: usize = 4;
pub const window_end: usize = shm_va + shm_slots * shm_slot_bytes;

pub const data_pages: usize = 2;
pub const stack_pages: usize = 4;
pub const max_image_bytes: usize = 48 * 1024;
pub const max_frames: usize = 32;
/// Upper bound on the pages one ELF image may occupy (256 KiB of program).
pub const max_elf_pages: usize = 64;
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

    /// Frames (own + page tables + shared mappings) this process may have. Set
    /// from its quota when the ledger is attached; the default is a ceiling that
    /// no image can reach, so creation is never refused by accounting.
    page_budget: u32 = 4096,
    /// Pages a shared object contributes to this space's budget (phase 29).
    shared_pages: u16 = 0,
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

    /// Everything this space has mapped and is charged for: its own frames, the
    /// tables that map them, and any shared pages it attached (phase 29).
    pub fn mappedPages(self: *const AddressSpace) usize {
        return @as(usize, self.frame_count) + @as(usize, self.table_count) + @as(usize, self.shared_pages);
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

/// Frames refused because the process reached its page budget. Monotonic, so the
/// probe can show that a cap was enforced even after the process is gone.
pub var budget_refusals: u64 = 0;

fn allocFrameInto(as: *AddressSpace, alloc: *pmm.PageAllocator) ?usize {
    if (as.mappedPages() + 1 > as.page_budget) {
        budget_refusals += 1;
        return null;
    }
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

/// Hand the process its capability numbers. They go in the data page next to
/// the mode word: the virtual address is only valid while this process is the
/// one loaded, so the kernel writes through the physical address.
pub fn setHandles(as: *AddressSpace, console: u64, ledger: u64, supervisor: u64, page_handle: u64) void {
    if (as.args_pa == 0) return;
    const words: [*]u64 = @ptrFromInt(as.args_pa);
    words[4] = console;
    words[5] = ledger;
    words[6] = supervisor;
    words[7] = page_handle;
}

/// The bootstrap IPC endpoint, handed to processes that ask for a channel.
pub fn setEndpointHandle(as: *AddressSpace, handle: u64) void {
    if (as.args_pa == 0) return;
    const words: [*]u64 = @ptrFromInt(as.args_pa);
    words[8] = handle;
}

/// Base address of shared-memory slot `slot` in every process.
pub fn shmBase(slot: usize) usize {
    return shm_va + slot * shm_slot_bytes;
}

/// Map a shared object's frames into this address space. The frames are owned by
/// the object, not by the space, so teardown must not free them: only the page
/// tables that point at them belong here.
pub fn mapShared(as: *AddressSpace, alloc: *pmm.PageAllocator, va: usize, frames: []const usize, writable: bool) bool {
    if (frames.len == 0) return false;
    if (va < shm_va or va + frames.len * page > window_end) return false;
    if (as.region_count >= uaccess.max_regions) return false;
    // Shared pages are charged to the mapping process: attaching someone else's
    // memory is still using your own address space and page tables (phase 29).
    if (as.mappedPages() + frames.len > as.page_budget) {
        budget_refusals += 1;
        return false;
    }
    for (frames, 0..) |pa, i| {
        if (!mapPage(as, alloc, va + i * page, pa, false, writable)) return false;
    }
    as.regions[as.region_count] = .{
        .base = va,
        .len = frames.len * page,
        .user_write = writable,
        .name = "shm",
    };
    as.region_count += 1;
    const pages: u16 = @intCast(frames.len);
    as.shared_pages +|= pages;
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();
    return true;
}

/// Remove a shared mapping. The frames stay alive with their object; only the
/// translations and the region record go away.
pub fn unmapShared(as: *AddressSpace, va: usize, len: usize) bool {
    var found: ?usize = null;
    var i: usize = 0;
    while (i < as.region_count) : (i += 1) {
        if (as.regions[i].base == va and as.regions[i].len == len) found = i;
    }
    const slot = found orelse return false;
    const l2: *[512]u64 = @ptrFromInt(as.l2);
    var off: usize = 0;
    while (off < len) : (off += page) {
        const v = va + off;
        const entry = &l2[mmu.l2Index(v)];
        if (entry.* & 0b11 != 0b11) continue;
        const l3: *[512]u64 = @ptrFromInt(entry.* & mmu.addr_mask);
        l3[mmu.tableIndex(v)] = 0;
    }
    var j = slot;
    while (j + 1 < as.region_count) : (j += 1) as.regions[j] = as.regions[j + 1];
    as.region_count -= 1;
    const pages: u16 = @intCast(len / page);
    as.shared_pages = if (as.shared_pages >= pages) as.shared_pages - pages else 0;
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();
    return true;
}

/// Write into a process's memory through its own page tables. The loader runs
/// while the process is not scheduled, so it cannot just store to the address.
pub fn writeUser(as: *AddressSpace, va: usize, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const v = va + done;
        const pa = translate(as, v) orelse return false;
        const chunk = @min(page - (v % page), bytes.len - done);
        const dst: [*]u8 = @ptrFromInt(pa);
        @memcpy(dst[0..chunk], bytes[done .. done + chunk]);
        done += chunk;
    }
    return true;
}

pub const Start = struct {
    sp: usize,
    argc: usize,
    argv: usize,
    envp: usize,
};

pub const max_start_args: usize = 8;

/// Build the process's initial stack: the strings, then the argv and envp
/// pointer vectors. The startup ABI hands these over in x0..x2, so nothing has
/// to be read out of a data page or guessed by the program.
pub fn buildStartStack(as: *AddressSpace, argv: []const []const u8, envp: []const []const u8) ?Start {
    if (argv.len == 0 or argv.len > max_start_args or envp.len > max_start_args) return null;
    var p = as.stackTop();
    var arg_va: [max_start_args]usize = [_]usize{0} ** max_start_args;
    var env_va: [max_start_args]usize = [_]usize{0} ** max_start_args;
    const nul = [_]u8{0};

    var i: usize = 0;
    while (i < envp.len) : (i += 1) {
        const s = envp[i];
        p -= s.len + 1;
        if (!writeUser(as, p, s)) return null;
        if (!writeUser(as, p + s.len, &nul)) return null;
        env_va[i] = p;
    }
    i = 0;
    while (i < argv.len) : (i += 1) {
        const s = argv[i];
        p -= s.len + 1;
        if (!writeUser(as, p, s)) return null;
        if (!writeUser(as, p + s.len, &nul)) return null;
        arg_va[i] = p;
    }
    p &= ~@as(usize, 15);

    var vec: [max_start_args + 1]u64 = [_]u64{0} ** (max_start_args + 1);
    i = 0;
    while (i < envp.len) : (i += 1) vec[i] = env_va[i];
    p -= (envp.len + 1) * 8;
    const envp_va = p;
    if (!writeUser(as, p, std.mem.asBytes(&vec)[0 .. (envp.len + 1) * 8])) return null;

    i = 0;
    while (i < argv.len) : (i += 1) vec[i] = arg_va[i];
    p -= (argv.len + 1) * 8;
    const argv_va = p;
    if (!writeUser(as, p, std.mem.asBytes(&vec)[0 .. (argv.len + 1) * 8])) return null;

    // Red zone below the vectors, and a 16-byte aligned SP as the ABI requires.
    const sp = (p - 16) & ~@as(usize, 15);
    return .{ .sp = sp, .argc = argv.len, .argv = argv_va, .envp = envp_va };
}

/// Build an address space from an ELF load plan. Each segment gets exactly the
/// permissions the file asked for, its file-backed part is copied in, and the
/// rest of `p_memsz` is BSS that stays zero because the frames are zeroed.
pub fn createElf(alloc: *pmm.PageAllocator, img: *const elf.Image, file: []const u8) ?*AddressSpace {
    const as = freeSlot() orelse return null;
    as.* = .{ .in_use = true, .id = next_id };
    next_id += 1;

    as.root = allocFrameInto(as, alloc) orelse return bail(alloc, as);
    mmu.copyKernelRoot(as.root);
    const l1 = allocFrameInto(as, alloc) orelse return bail(alloc, as);
    as.l1 = l1;
    copyPage(l1, mmu.kernelL1Pa());
    @as(*[512]u64, @ptrFromInt(as.root))[mmu.l0Index(code_va)] = l1 | 0b11;
    const l2 = allocFrameInto(as, alloc) orelse return bail(alloc, as);
    as.l2 = l2;
    @as(*[512]u64, @ptrFromInt(as.l1))[mmu.l1Index(code_va)] = l2 | 0b11;

    // Two segments can share a page: the linker puts .text and .rodata in the
    // same 4 KiB page when the first one ends mid-page. Mapping per segment
    // would allocate the page twice and let the last segment's permissions win,
    // so pages are collected first, given the union of the rights that touch
    // them, and only then mapped and filled.
    var page_va: [max_elf_pages]usize = undefined;
    var page_write: [max_elf_pages]bool = undefined;
    var page_exec: [max_elf_pages]bool = undefined;
    var page_count: usize = 0;

    var s: usize = 0;
    while (s < img.count) : (s += 1) {
        const seg = img.segments[s];
        const first = std.mem.alignBackward(usize, seg.vaddr, page);
        const last = std.mem.alignForward(usize, seg.vaddr + seg.memsz, page);
        var va = first;
        while (va < last) : (va += page) {
            var found: ?usize = null;
            var k: usize = 0;
            while (k < page_count) : (k += 1) {
                if (page_va[k] == va) found = k;
            }
            if (found) |idx| {
                page_write[idx] = page_write[idx] or seg.write;
                page_exec[idx] = page_exec[idx] or seg.exec;
            } else {
                if (page_count == max_elf_pages) return bail(alloc, as);
                page_va[page_count] = va;
                page_write[page_count] = seg.write;
                page_exec[page_count] = seg.exec;
                page_count += 1;
            }
        }
    }
    // A shared page can only stay W^X if no writable segment touches a page an
    // executable segment also touches. Refuse rather than create a page that is
    // both, which the ELF's own per-segment check cannot see.
    var k: usize = 0;
    while (k < page_count) : (k += 1) {
        if (page_write[k] and page_exec[k]) return bail(alloc, as);
    }
    k = 0;
    while (k < page_count) : (k += 1) {
        const pa = allocFrameInto(as, alloc) orelse return bail(alloc, as);
        if (!mapPage(as, alloc, page_va[k], pa, page_exec[k], page_write[k])) return bail(alloc, as);
    }
    // With the pages in place, the file-backed bytes are copied through the
    // process's own tables; everything else in those pages stays zero.
    s = 0;
    while (s < img.count) : (s += 1) {
        const seg = img.segments[s];
        if (seg.filesz == 0) continue;
        const lo = seg.vaddr;
        const hi = seg.vaddr + seg.filesz;
        var va = std.mem.alignBackward(usize, lo, page);
        while (va < hi) : (va += page) {
            const from = @max(va, lo);
            const to = @min(va + page, hi);
            const pa = translate(as, from) orelse return bail(alloc, as);
            const dst: [*]u8 = @ptrFromInt(pa);
            const src = seg.offset + (from - lo);
            @memcpy(dst[0 .. to - from], file[src .. src + (to - from)]);
        }
        if (as.region_count >= uaccess.max_regions) return bail(alloc, as);
        as.regions[as.region_count] = .{
            .base = seg.vaddr,
            .len = seg.memsz,
            .user_write = seg.write,
            .user_exec = seg.exec,
            .name = "elf",
        };
        as.region_count += 1;
    }

    var i: usize = 0;
    while (i < stack_pages) : (i += 1) {
        const pa = allocFrameInto(as, alloc) orelse return bail(alloc, as);
        if (!mapPage(as, alloc, stack_va + i * page, pa, false, true)) return bail(alloc, as);
    }
    if (as.region_count >= uaccess.max_regions) return bail(alloc, as);
    as.regions[as.region_count] = .{
        .base = stack_va,
        .len = stack_pages * page,
        .user_write = true,
        .name = "stack",
    };
    as.region_count += 1;
    as.code_len = img.memory_bytes;

    // The instructions came from the file; make them visible to the fetcher.
    cpu.icIallu();
    return as;
}

/// Where a mapped capability page appears in the user window. Between the data
/// region (0x81000000) and the stack (0x82000000), so it collides with neither.
pub const mapped_va: usize = 0x8150_0000;

/// Map a kernel-owned page into this process. The frame is not owned by the
/// address space, so teardown leaves it alone: the object outlives the mapping.
pub fn mapKernelPage(as: *AddressSpace, alloc: *pmm.PageAllocator, va: usize, pa: usize) bool {
    if (!mapPage(as, alloc, va, pa, false, false)) return false;
    if (as.region_count < uaccess.max_regions) {
        as.regions[as.region_count] = .{
            .base = va,
            .len = page,
            .user_write = false,
            .name = "mapped",
        };
        as.region_count += 1;
    }
    // The new translation must be visible before EL0 runs again.
    cpu.tlbiVmalle1();
    cpu.dsbSy();
    cpu.isb();
    return true;
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
