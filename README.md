# Cassa

**A point-of-sale operating system for 64-bit ARM retail hardware, written entirely in Zig.**

Cassa is a from-scratch operating system: its own boot path, kernel, drivers, filesystem,
graphics stack, UI toolkit, and the point-of-sale application that store staff actually use.
There is no Linux underneath, no libc, and no second language anywhere in the build.

```
    ┌──────────────────────────────────────────────┐
    │  POS application — cart, tenders, receipts    │  Stage G
    ├──────────────────────────────────────────────┤
    │  UI toolkit — compositor, widgets, fonts      │  Stage F
    ├──────────────────────────────────────────────┤
    │  Services — storage, printing, payments, net  │  Stages C–E, H
    ├──────────────────────────────────────────────┤
    │  Cassa kernel — mm, sched, IPC, caps, drivers │  Stages A–D
    ├──────────────────────────────────────────────┤
    │  AArch64 firmware  (UEFI)  /  QEMU virt       │
    └──────────────────────────────────────────────┘
```

## Status

**Phases 1–51 of [PLAN.md](PLAN.md) boot and run on QEMU `virt` with four cores.**
Processes run at EL0 in their own address spaces, hold bounded handle tables whose rights
masks the kernel enforces, and reach the kernel only through validated syscalls. Two
processes talk over capability-addressed endpoints with synchronous call/reply, 64-byte
inline messages and handle transfer, and share 4 MiB buffers by mapping the same frames with
futex-style wait and wake. Separately built ELF64 programs are loaded from an image store,
given argv/envp and their own BSS, and run with their exit status propagated. Services are
named processes under a supervisor: one that dies is restarted with exponential backoff, one
that keeps dying is parked as a crash loop instead of thrashing the till, a fault leaves a
crash record with its registers and stack, and stopping a service reaps its child. Services are
also addressable by name: a kernel-owned table maps `pos://` names to service identities, lookup
answers with a reason (ok, unknown, not running, restarting, crash-loop parked) instead of an
ambient error, a stopped service can be started lazily by name, and a POS program that asks for
an absent service gets a reason code it can branch on. (Phase 13 is partial: IRQ-safe locks and counters exist, storm throttling does not.
Phase 19 is deferred until block devices exist.)

The kernel also drives a panel. It reads the monitor's EDID over the bochs-display MMIO BAR,
programs the preferred mode, maps VRAM as non-cacheable memory, verifies a pixel round trip, and
draws the boot splash, a deterministic self-test pattern and kernel panics — the same fault that
goes to the serial console is now also on the screen. See
[docs/screenshots](docs/screenshots).

| Phase | What exists | How it is verified |
|---|---|---|
| 1 | Zig build, generated linker script, host tests, QEMU runner | `zig build` from a clean tree |
| 2 | `_start`, BSS clear, SP_EL1/SP_EL0, device-tree handoff | boot log |
| 3 | PL011 console | banner and command output |
| 4 | structured `klog` with ring buffer | every boot line |
| 5 | panic surface with register dump and captured log | `panic` command |
| 6 | FDT parser: RAM, UART, GIC, model, cmdline | `info` shows `linux,dummy-virt`, 512 MiB/1 GiB; `-m 1024` changes totals |
| 7 | bitmap physical page allocator | host tests + `mem` counters |
| 8 | boundary-tag heap behind `std.mem.Allocator` | 6 host tests incl. randomised workload; `std.ArrayList`/`allocPrint` at boot |
| 9 | 4 KiB granule MMU, 48-bit VA, caches, W^X | `textwrite` faults; `map` translates |
| 10 | 16-entry exception vectors, trap frames, ESR decoding | SVC round trip; data abort report names cause/address/write |
| 11 | GICv2 + GICv3 | `irq` shows PPI 30 firing, 0 spurious |
| 12 | generic timer, 1 kHz tick, uptime | `time` shows ticks advancing at 1 kHz |
| 13 | IRQ-safe spinlocks, per-CPU IRQ counters | `irq` shows 0 spurious, 0 unhandled |
| 14 | spin/ticket/IRQ locks, atomics, semaphores | `stress 4 20000` → 80000 exact, 0 lost |
| 15 | kernel threads, 64 KiB stacks, exit and reaping | `threads`; `reap 8` → 0 pages leaked |
| 16 | preemptive round-robin, work stealing, pinning | `preempt` → equal timeslices on one core |
| 17 | wait queues, semaphore, timed sleep | `sleep 100`; host tests for blocking |
| 18 | PSCI SMP bring-up, per-CPU state, reschedule IPI | `cores` shows 4/4 online and switching |
| 20 | boot self-tests, counters, switch trace ring | every boot prints a PASS verdict |
| 21 | EL0, SVC entry, validated syscall table | `uprobe`: prints via `write`, bad pointers refused |
| 22 | per-process TTBR0, W^X user pages, teardown | `uprobe`: two processes, same VA, own data |
| 23 | handle tables, rights masks, derivation, revocation, object refcounts | `uprobe` cases 1–6 on 1 and 4 cores; `caps` |
| 24 | IPC endpoints, call/reply, handle transfer, deadlines, backpressure | `uprobe` step 10: 11 cases on 1 and 4 cores; `ipc` |
| 25 | shared memory objects, multi-space mapping, futex wait/wake, event counters | `uprobe` step 11: 21 cases on 1 and 4 cores; `shm` |
| 26 | ELF64 loader, segment permissions, BSS, argv/envp, exit status | `uprobe` step 12: `pos.elf` exits 42; `exec`, `images`, `elf` |
| 27 | service supervisor, backoff restarts, crash-loop parking, crash records, orphan reaping | `uprobe` step 13: printer killed 7× restarts 6× then parks, checkout 3/3; `service`, `dumps` |
| 28 | name registry (`pos://`), by-name resolve with reasons, duplicate rejection, lazy start, generation counter | `uprobe` step 14: live/restarting/parked/unknown lookups, `pos.elf resolve` exits 0/4/1; `registry`, `resolve`, `ensure` |
| 28a | run-queue lifecycle: single publish point, queue invariant, reaper guard, stray-ready audit; IPC deadline refusal decided by the deadline alone | `killoop 150` ×2 clean, 20/20 four-core and 5/5 single-core probe boots green with 0 queue anomalies, `stress`/`preempt`/`reap` green |

| 29 | resource accounting: per-process page/handle/CPU quotas, OOM scoring, memory-pressure report, watchdog warn→throttle→kill ladder, `SYS_ACCOUNT`, `accounting` command | `uprobe` step 15: a leaking service is capped (handle refusal + page-quota breach), throttled and killed by the watchdog while 3/3 checkouts are served; pressure event reported |
| 30 | sandbox policy: declarative per-service manifests (capabilities + syscall mask) validated at build time, a syscall gate ahead of dispatch, a block-device capability, W^X at the mapping funnel, `sandbox` command | `uprobe` step 16: the storage service reads the device signature; a compromised renderer fails all 16 handle probes and an undeclared syscall, and a process that may call `SYS_BLOCK` but holds no block object is refused by the capability check |
| 31 | driver model: device objects from the device tree, compatible-string matching, declared dependency order, isolated probe failures, hotplug unbind/rebind, PL031 wall clock, `devices` command | `uprobe` step 17: devices discovered and matched in dependency order, an injected probe failure isolated, the RTC unbound and re-probed; the same image on a QEMU tree without the RTC logs `idle: 'rtc'` and still passes |
| 32 | PCIe host bridge: ECAM config space, 256-bus walk, BAR sizing/assignment with readback, MSI, MSI-X and INTx routing through the device tree, every function published as a device, `lspci` | `uprobe` step 18: root complex and ECAM verified, function walk matches QEMU's device list, every BAR placed inside the host bridge's windows, INTx routed and enabled in the GIC; a tree without the GICv2m frame proves the INTx fallback |
| 33 | Virtio transport: modern virtio-mmio v2, feature negotiation with `VIRTIO_F_VERSION_1`, split virtqueues with descriptor chains and available/used rings, coalesced completion draining, transport reset and retry, `virtio` command; the first real virtio request on hardware (entropy) | `uprobe` step 19: 32 transports bound (1 with a device, 31 empty), version-1 features acked, 100000 echo requests with 0 errors and 25000 coalesced drains while 32 MiB of pages are held and churned with no page leaked, a timeout detected and recovered by reset+retry, 64 bytes served by the entropy device |
| 34 | block layer: virtio-blk requests (16-byte header, data descriptor, status byte) on the phase-33 split rings, a 64-request elevator that sorts LBA runs while a flush acts as a strict barrier, 3-attempt retry with transport reset and re-negotiation on timeout, the virtio-mmio interrupt routed through the GIC, per-device I/O statistics, `blk` command | `uprobe` step 20: 10000 scattered single-sector writes in 157 elevator batches with 0 errors, byte-exact readback (digest `0xf7c1084666c80b64`), 2 flushes, a forced timeout recovered by reset+retry with the retried data verified; the next boot after a `kill -9` reads generation 1 back and the digest matches |
| 35 | partition tables: GPT primary and backup headers with header and entry-array CRC32 validation and backup fallback, entry iteration with names and attributes, MBR primaries plus the extended/EBR chain with loop bounds, protective-MBR handling, a formatter used as the installer primitive, `part` command | `uprobe` step 21: a self-written GPT parses back with both copies valid, a corrupted primary falls back to the backup, two corrupted copies are refused with `BadEntryCrc`, a 2-primary + 1-logical MBR walks one EBR, and no page is leaked; a parted-made GPT (3 partitions) and a parted-made MBR (2 primaries + 2 logicals) enumerate field for field over the same device |
| 36 | FAT32 filesystem on a partition-offset block view: BPB validation, FSInfo tolerance, directory walk with LFN read-back, create/read/write/grow/delete with both FAT copies and free-space accounting, at-rest consistency check, formatter, `fat` command | `uprobe` step 22: a 39 MiB scratch volume is formatted and mounted through a partition view, a 2050-byte file is written over 5 clusters, read back byte for byte, deliberately looped and caught, then deleted with 0 orphans and 0 pages leaked; a parted GPT + `mkfs.fat` volume cross-verified with mtools 4.0.48 and `fsck.fat 4.2` in both directions (kernel reads `HOST.TXT` byte-identically, host `mtype` reads the kernel's `SALE.TXT`, `fsck` clean) |
| 37 | Framebuffer: bochs-display PCI driver (EDID parsed from the device, bochs-dispi mode programming), a non-cacheable VRAM mapping verified by pixel readback, a 5x7 bitmap font, a drawing core (rects, gradients, text, clipping), boot splash, panic-to-screen, `fb` command; also fixes the phase-32 bus gap that left every BAR undecoded | QEMU 8.2.2: EDID reads `QEMU Monitor`, 1280x800 preferred; the mode is programmed, read back and mapped (write/readback `PASS`); the test-pattern screendump was checked pixel for pixel (bars, grey ramp, RGB ramps, grid, four corner markers, mode label); `fb mode 1024 768` re-modes and the screendump is 1024x768; `fb crash` draws the panic screen; a boot without the device logs `no framebuffer` and still passes the self-tests |
| 38 | Input: virtio keyboard and tablet over a two-queue virtio-mmio driver (16 posted buffers, IRQ drain/repost, EV_BITS/ABS_INFO classification, absolute scaling to the panel, wheel and three buttons), an ordered IRQ-safe event queue with console mirror, USB HID boot-keyboard/mouse/absolute-pointer decoders, a hold-and-decide barcode scanner with prefix/suffix and ordered release, key remapping, `input`, `input viz`, `hid`, `keymap` | QEMU 8.2.2: `QEMU Virtio Keyboard` and `QEMU Virtio Tablet` bind at irq 78/79 with tablet abs 0..32767; 72 key events and 11 tablet events (pointer 351,146 → 702,292 with button down/up) from `sendkey` and QMP absolute input; a 13-digit burst becomes exactly one barcode event with 0 ms suffix-to-queue delivery; HID self-test PASS; boot without input devices clean; 162 host tests |
| 39 | USB host stack: xHCI over PCI (BAR mapping, controller reset, command/event/transfer rings, 64-entry DCBAA, slot and endpoint contexts, port reset), descriptor-driven enumeration, HID and CDC-ACM class drivers, FTDI serial bridge, hubs and child devices, unplug/replug, `usb`, `usb selftest`, `usb serial` | QEMU 8.2.2: keyboard slot 1 port 5 and tablet slot 2 port 6 enumerate; 12 key events and pointer 234,97 → 702,268 with button down/up; one `barcode '1234'` from a HID burst; two replug cycles on ports 7/8; a child keyboard behind an 8-port hub; FTDI `hello`/`world` payloads in both directions and across replug; no-controller boot and `usb selftest` PASS; 187 host tests; `tools/qemu_usb_test.py` |
| 40 | Watchdog and power: real i6300ESB PCI watchdog with a two-stage 4 s reset and previous-reset flag, core-0 scheduler heartbeat, brown-out hooks and emergency service path, FAT32-backed `POWER.JNL` with 72-byte CRC32 records and a 96-record ring, thermal ladder with 0/25/50/75% idle injection, PSCI poweroff/reboot with storage flush, `power`, `thermal`, `watchdog`, `poweroff` | QEMU 8.2.2: forced hang resets in 4 s and the next boot reports `watchdog_boot` with an unclean journal and intact FAT32 file; poweroff and brownout exit 0 and the next boot is clean with the file intact; thermal benchmark 2212 → 3604 ms (1.63x) at critical/75% with 12,990 idle ticks; no-watchdog/no-disk boot PASS with two `OK (degraded)` and `power hang` refused; 197 host tests; `tools/qemu_power_test.py` |
| 41 | CASSAFS format 1: 4 KiB log-structured volume, A/B superblocks with CRC32C, 64-byte record headers with header and payload CRC32C, 268-byte inode tree (parent/name), ordered byte extents, free-space bitmap, checkpoint, on-disk versioning; kernel `cassafs info/format/demo/dump/verify/cat/viz`, read-only host reference reader, shell integration | QEMU 8.2.2: 64 MiB MBR partition formats to 20 blocks/9 records/5 inodes/2 files/158 data bytes with 16,364 free; verify PASS covers every CRC, tree edge, extent, data CRC and bitmap bit; 73-byte CSV CRC `0x3b60dc1d` read by guest and host; reboot persistence; damaged B superblock falls back to A; corrupted data payload rejected by both; no-disk absence PASS; 208 host tests (+11); `tools/qemu_cassafs_test.py`; screenshot `docs/screenshots/phase41-cassafs.png` |
| 42 | Read-only VFS: backend-neutral node and mount tables, canonical absolute/relative paths with `.` and `..`, open/close handles, sequential and offset reads, stable readdir, stat, read-only access checks, validate-before-mount; CASSAFS backend on partition 1; `vfs` shell commands | QEMU 8.2.2: 5-inode demo mounts at `/` and reads 73-byte products.db CRC `0x3b60dc1d` and 85-byte WELCOME.TXT, both matching `cassafs cat`; stable root order, unmount/remount, byte-identical reads after a soft reboot; no-disk and bad-CRC mounts refused with zero table entries; damaged B superblock falls back to A; 217 host tests (+9); `tools/qemu_vfs_test.py`; screenshot `docs/screenshots/phase42-vfs.png` |
| 43 | CASSAFS write path: append-only create and offset write/extend, touched-chunk rebuild, latest-inode supersession, free-map allocation, new checkpoint, A/B superblock generation with readback, writable VFS handles and repair-free rescan; `vfs create/write/df`, `vfs selftest` write checks | QEMU 8.2.2: create `/catalog/note.txt` inode 6, write 7 bytes CRC `0xdb03992b`, overwrite to 8 bytes CRC `0x394478f0`; 6 inodes/3 files/166 data bytes read back after unmount/remount and a soft reboot; 73-byte products CRC unchanged; host `cassafs verify` PASS; 8-block 0-free volume refuses create with out-of-space and no entry; corrupted committed payload refused with CRC32C; 219 host tests (+2); `tools/qemu_vfs_write_test.py`; screenshot `docs/screenshots/phase43-write.png` |
| 44 | CASSAFS page cache: bounded 4 KiB LRU between VFS and the partition view, 64 resident pages (256 KiB), 16-page write-back bound (64 KiB), four-page readahead, dirty-written-before-eviction/flush, pressure accounting, `vfs cache stats/flush/drop/bench`, unmount flush, dashboard cache line, 19-check `vfs selftest` | QEMU 8.2.2: mount warms 23/64 pages, 35% pressure, 79% hit (19/5); after cache drop and cold read 21 hit/6 miss, 22 readahead reads, 0 errors; 8 sale-sized VFS commits **27–38 ms** observed / 100 ms while interleaving 16 catalog reads/1,264 B; 64/64 pages, 344 evictions, 88 writebacks, 20 flushes, 0 dirty; sale 33 B CRC `0x12b569fa` survives cache drop, unmount/remount and host verify; 225 host tests (+6); fixes: 4 KiB cache bounce page moved off-stack and thread stacks raised to 128 KiB after a real post-mount stack overflow, plus the console writer now holds its lock across a whole formatted record so four-core boot logs cannot split the shell prompt; `tools/qemu_page_cache_test.py`; screenshot `docs/screenshots/phase44-cache.png` |
| 45 | Read-only FAT32 reader at `/media/usb`: BPB/LFN/cluster-chain validation, stable inode mapping, range reads, read-only backend and mount integration on partition 2; bounded streaming catalog CSV parser and `vfs import`; `vfs mount usb`, `vfs unmount usb`, `vfs selftest` LFN/read-only checks | QEMU 8.2.2: foreign-formatted partition 2 has 201,616 clusters of 512 B, root cluster 2; long name `store-catalog-2026.csv`; import reads **10,000 rows / 220,021 B / max line 21 / CRC32C `0x8678e4e7`** across cache-free 4 KiB VFS reads and repeats after unmount/remount and soft reboot; readdir/stat expose the LFN, write/create refuse as read-only, a looped FAT chain is refused with `integrity failure`, a one-partition disk refuses the USB mount, and the CASSAFS root stays intact; 231 host tests (+6); `tools/qemu_fat32_test.py`; design `docs/fat32-reader.md` |
| 46 | Unified VFS: bounded writable tmpfs at `/tmp` (16 nodes, 4 KiB/file, nested directories), optional backend `mkdir`/`chmod`, mode-bit permissions, advisory shared/exclusive whole-file locks, 8-watch/16-event inotify-style queue with created/modified/mounted/unmounted events and dropped-event accounting; `vfs mount tmpfs`, `mkdir`, `chmod`, `lock`, `watch`, `unwatch`, `events`; same resolver for CASSAFS, FAT32 and tmpfs | QEMU 8.2.2: `mount table 3/8`; `./catalog/products.db`, `./media/usb/./store-catalog-2026.csv` and `./tmp/spool/../spool/notice.txt` canonicalise identically through one resolver; tmpfs 7 B `notice.txt` CRC `0x6d6a12e7`, chmod 444 refuses writes while reads stay allowed, chmod 644 appends to 9 B CRC `0x9e9cac38`; exclusive lock conflict and two shared locks PASS; watch `/tmp` delivers exactly `created` + `modified` events for `/tmp/spool/event.txt`; unmount discards /tmp and remount starts at 1 node/0 bytes; FAT32 import still **10,000 rows / 220,021 B / CRC32C `0x8678e4e7`**; 233 host tests (+2); all eight prior harnesses PASS (input 13 chars/259 ms, page cache 64/64 pages + sale CRC `0x12b569fa`); fixes a real virtio-input drain race between IRQ and shell polling; `tools/qemu_vfs46_test.py`; design `docs/vfs-phase46.md` |
| 47 | Retail data model: 480 fixed 128-byte records (61,480 B, header and per-record CRC32C) for products, variants, barcodes, prices, tax classes, promotions, users, roles, receipts, sale lines, shifts, drawers, terminals and suppliers; staged FAT32 CSV import through the phase-45 reader; deterministic day of 64 receipts/128 lines across 3 terminals, 3 closed shifts and 3 drawers; `retail init/import/seedday/report/verify/corrupt` | QEMU 8.2.2: phase-45 FAT32 import still **10,000 rows / 220,021 B / max line 21 / CRC32C `0x8678e4e7`**, followed by an 8-product LFN import; seeded **239 records, 64 receipts, 128 lines, 160 units, subtotal 42,020, tax 0, cash 16,540, variance +50, top `100001 Croissant` 24 units/4,320 cents**; duplicate import refused with `DuplicateCode` and day unchanged; cache flush + drop, unmount/remount and soft reboot preserve `retail verify : PASS`; a deliberately corrupted record is refused with `RecordCorrupt`; **243 host tests (+10)**; all nine prior harnesses PASS (input 13 digits/259 ms/0 ms delivery, USB 4/4, power 2362→3995 ms/1.69x, 37 ms max sale commit, sale CRC `0x12b569fa`, 64/64 cache pages); `tools/qemu_retail_test.py`; design `docs/retail-phase47.md` |
| 48 | Transactional sale log: immutable 64-byte header + 16×512-byte CRC32C-chained records (8,256 B) at `/catalog/sales.log`; append through VFS/CASSAFS `writeAt`, page-cache flush and read-back before receipt; `(terminal_id, txn_id)` idempotency with terminal-local sequences, replay, verify and test-only corruption hook; kernel prices/tax from the phase-47 snapshot | QEMU 8.2.2: phase-45 import **10,000 rows / 220,021 B / `0x8678e4e7`** and phase-47 **239 records** still green; three sales committed at seq 1/2/3 with **680 + 150 + 725 = 1,555 cents, 6 units, 2 terminals**; exact retry of `T1/5001` is a no-op, changed payload is `Conflict`, unknown terminal/SKU refuse; cache flush + drop, unmount/remount and soft reboot preserve **`sales verify : PASS, 3 transaction(s)`**; retry after reboot still a no-op; corrupted record refuses `RecordCorrupt` across cache drop, remount and reboot; **248 host tests (+5)**; all ten prior harnesses PASS (input 13 chars/259 ms/0 ms, USB 4/4, power 2374→4039 ms/1.70x with 1.61–1.64x repeats, page cache 37 ms/64/64 + sale CRC `0x12b569fa`, FAT32 10,000/220,021/`0x8678e4e7`, VFS46, retail 239); `tools/qemu_sales48_test.py`; design `docs/sales-phase48.md` |
| 49 | Storage health: bounded `src/lib/storage_health.zig` policy (32 bad ranges, 3 retries, healthy/degraded/failing, media counters, recovered/unrecovered ledger), virtio-blk quarantine check and read/flush fault injection through the existing retry/reset path, `BadBlock` propagation, read-only CASSAFS `fsck`, and `blk health/fsck/inject/clear/scrub/viz` supervisor dashboard | QEMU 8.2.2: phase-45 **10,000 rows / 220,021 B / `0x8678e4e7`**, phase-47 **239 records** and phase-48 **`sales verify : PASS, 1 transaction(s)`** on the same disk; transient superblock read at LBA 2048 recovered with **`degraded, warnings 1, retries 1, recovered 1`** and fsck PASS; transient flush recovered; persistent failure printed **`REFUSED: Io`** then **`REFUSED: BadBlock`**, health **`failing, warnings 3, retries 5, recovered 2, unrecovered 1, bad blocks 1`**; `blk scrub 2048 16` cleared 1 entry, fsck PASS and 73 B product CRC `0x3b60dc1d` unchanged; raw payload corruption on a separate fixture prints **`REFUSED: BadCrc`**; sale and product survive cache drop, unmount/remount and soft reboot; **252 host tests (+4)**; all eleven prior harnesses PASS (input 13 chars/259 ms/0 ms, USB 4/4, power **1.63x**, page cache 29 ms/64/64 + sale CRC `0x12b569fa`, FAT32, VFS46, retail 239, sales48 3 transactions); `tools/qemu_storage49_test.py`; design `docs/storage-phase49.md` |
| 50 | Snapshots and recovery: a bounded 128-byte CRC32C config record and 544-byte four-slot snapshot file; copy-before-write `recovery set`, one-command `recovery rollback`, `recovery status/verify`, `factory-reset preserve` retaining the phase-48 sale audit, a support bundle carrying config/snapshot/audit/phase-49 health, and test-only config/snapshot corruption hooks | QEMU 8.2.2: phase-45 **10,000 rows / 220,021 B / `0x8678e4e7`**, phase-47 **239 records** and phase-48 **one committed sale / `sales verify : PASS`** still green; config generation 3 with 4/4 snapshots in slot 3; config corruption refused **`BadCrc`**, one `recovery rollback` restored generation 3 / `North Till`; cache drop, unmount/remount and soft reboot preserved config, slots and sale, with rollback still working after reboot; support bundle **1312 B / CRC32C `0x66d093ce`**, `vfs stat` size matches; factory reset preserve restored generation 1, left the **576-byte** sale audit intact and `sales verify` still PASS; corrupt snapshot rollback refused `BadCrc`; **256 host tests (+4)**; all twelve prior harnesses PASS (input 13 digits, USB 4/4, power PASS, page cache 64/64 + sale CRC `0x12b569fa`, FAT32, VFS46, retail; sales48 verifies 3 transactions / 1,555 cents, with a boot-uptime-dependent chain CRC; storage49); `tools/qemu_recovery50_test.py`; design `docs/recovery-phase50.md` |
| 51 | Graphics core: pure `src/lib/gfx.zig` with `bgrx8888`/`rgba8888`/`rgb888`/`rgb565` surfaces, clipped 1:1 blits with conversion, straight 8-bit alpha compositing, and a bounded 8-rectangle damage set; `fb.rawBytes()` bridge, `gfx [test|inject|repair|info]`, test-only negative control | QEMU 8.2.2: all four formats round-trip in the kernel; scratch clip/blit/blend/damage PASS; live **128×96** card at `576,352` on **1280x800 BGRX**, exact screenshot pixels `220,32,32`, `32,180,64`, `8,44,144`, `255,255,255`, transparent `16,24,32`, `8,140,16`, `255,128,0`; **1 damage rect / 12,288 px**; clean snapshot **`0x27ae8280`**; injected corruption **`0xda4f8ba2`** → `gfx core : FAIL`, repair → PASS; **264 host tests (+8)**; all thirteen prior harnesses PASS one at a time (input 13 chars/259–260 ms/0 ms, USB 4/4, power 2372–2390→3763–3893 ms/1.57–1.64x, page cache 27–42 ms/64/64 + sale CRC `0x12b569fa`, FAT32 10,000/220,021/`0x8678e4e7`, VFS46, retail 239 records, sales48 3 transactions/1,555 cents with boot-dependent chain `0x72b85792`, storage49, recovery50 1312 B/`0x66d093ce`); `tools/qemu_gfx51_test.py`; design `docs/graphics-phase51.md` |

The remaining 49 phases are specified in [PLAN.md](PLAN.md) and are being implemented in
order. Nothing in this repository is a mock: everything marked done boots and runs.

## Building

Requires Zig 0.14.x. From a clean checkout:

```sh
zig build           # ELF + cassa.bin (raw) + cassa.img (arm64 Image) in zig-out/bin
zig build test      # host-side unit tests for pure logic
zig build run       # boot the raw image under QEMU with 4 vCPUs and a USB keyboard/tablet
zig build run-nousb # boot with no xHCI controller attached
zig build run-elf   # boot the ELF directly (no device-tree handoff)
zig build image     # only the flat arm64 Image container
```

`zig build` also installs `zig-out/bin/cassafs`, the host-side reference reader for the phase-41
CASSAFS format. It is deliberately read-only (the kernel is the writer) and takes an image plus
an MBR partition number or raw byte offset:

```sh
zig-out/bin/cassafs verify --image disk.img --partition 1
zig-out/bin/cassafs dump   --image disk.img --partition 1
zig-out/bin/cassafs cat    --image disk.img --partition 1 --path /catalog/products.db
```

`zig build run` invokes `qemu-system-aarch64` from `$PATH` (override with
`-Dqemu=/path/to/qemu-system-aarch64`) with `-smp 4` (override with `-Dsmp=N`) and attaches
`qemu-xhci`, `usb-kbd` and `usb-tablet`; `run-nousb` is the same boot without any USB controller.
The power and thermal paths have their own black-box run: `python3 tools/qemu_power_test.py` boots
QEMU with an `i6300esb` watchdog and a generated FAT32 disk, then checks forced-hang reset,
graceful poweroff, brownout shutdown, thermal throttling, the degraded no-hardware boot and the
dashboard screenshot. The phase-41 storage format has its own run:
`python3 tools/qemu_cassafs_test.py` formats a 64 MiB MBR disk, verifies it in the guest and with
the host reader, reboots on the same image, corrupts a superblock and a payload, and boots with
no disk at all. The format contract is in [docs/cassafs-format.md](docs/cassafs-format.md). The phase-42 mount
and read path has its own black-box run: `python3 tools/qemu_vfs_test.py` formats a volume,
mounts it, walks the tree, reads both files, checks no-disk and bad-CRC refusals, exercises A/B
fallback, unmounts and remounts, then soft-reboots the same guest and reads the same bytes again.
The phase-43 write path adds `python3 tools/qemu_vfs_write_test.py`: it creates and overwrites a
file through the VFS, compares read-back bytes and CRCs, unmounts/remounts and soft-reboots on
the same medium, runs the host verifier, then proves an 8-block volume refuses a create and a
damaged committed payload is refused at mount. The VFS contract is in [docs/vfs.md](docs/vfs.md).
The phase-44 page cache adds `python3 tools/qemu_page_cache_test.py`: it mounts a formatted
volume, reads the mount-warmed cache counters, drops the cache and proves a cold read misses and
prefetches, benchmarks eight sale-sized commits while catalog reads run, checks that dirty
write-back stays bounded, verifies the committed sale after another cache drop and an
unmount/remount, then runs the host verifier. Design and limits: [docs/page-cache.md](docs/page-cache.md).
The phase-45 FAT32 reader adds `python3 tools/qemu_fat32_test.py`: it bootstraps a two-partition
disk (CASSAFS root and a foreign-formatted FAT32 stick), mounts the stick read-only at
`/media/usb`, reads the 220,021-byte 10k-row LFN catalog in 4 KiB VFS chunks, proves write/create
refusal, unmounts/remounts, soft-reboots and imports again, then corrupts the file's FAT chain
and proves the import is refused instead of returning a partial catalog. Design and limits:
[docs/fat32-reader.md](docs/fat32-reader.md).
The phase-46 VFS adds `python3 tools/qemu_vfs46_test.py`: it mounts all three backends, resolves
relative/dot-dot paths to the same canonical form, creates and reads a tmpfs file, proves
chmod enforcement and restoration, exercises exclusive/shared locks, watches a directory for
created and modified events, remounts tmpfs, and reimports the FAT32 catalog through the same
VFS. Design and limits: [docs/vfs-phase46.md](docs/vfs-phase46.md).
The phase-49 storage-health surface adds `python3 tools/qemu_storage49_test.py`: it re-establishes
the phase-45/47/48 evidence on one disk, injects one transient and then one persistent superblock
read fault, proves retry/recovery, `REFUSED: Io` followed by `REFUSED: BadBlock`, scrubs the
quarantined range back to a passing read-only fsck, and preserves the product CRC and committed
sale across cache drop, unmount/remount and a soft reboot. Design, observed lines and honest
limits: [docs/storage-phase49.md](docs/storage-phase49.md).
The phase-50 recovery surface adds `python3 tools/qemu_recovery50_test.py`: it initializes a bounded
128-byte config and four 128-byte snapshot slots, changes the config, corrupts it directly, proves
`REFUSED: BadCrc`, restores it with one `recovery rollback`, and repeats the rollback after a soft
reboot. It exports a checksummed support bundle, then proves `factory-reset preserve` restores the
defaults while keeping the phase-48 sale audit intact and verifiable. Design and limits:
[docs/recovery-phase50.md](docs/recovery-phase50.md).
The phase-51 graphics core adds `python3 tools/qemu_gfx51_test.py`: it draws a
deterministic clipped/alpha-composited 128×96 card through the mapped
framebuffer, checks exact pixels in the kernel and independently in a QEMU
screendump, and requires a test-only injected corruption to turn the same proof
into FAIL before repairing it. Design and limits:
[docs/graphics-phase51.md](docs/graphics-phase51.md).
The kernel
console is the first PL011 UART; press Enter for a prompt and type `help`. Concurrency can be
inspected live: `cores` (per-core ticks, switches, preemptions), `threads`, `stress 4 20000`
(contended counter), `preempt 1000` (three spinning threads, one core), `reap 8` (reaping),
`logstorm 4` (unbroken console lines from four cores), `caps` (capability objects and their
reference counts), `ipc` (endpoint counters), `shm` (shared-memory objects, mappings and event
counters), `exec`/`images`/`elf` (launch a program from the image store), `service` (list, start, kill or
stop a supervised service by name), `dumps` (the crash records kept for faulting programs), `registry` (registered names, slots,
generations and lookup counters), `resolve <name>` (ask the registry for a service and print the
reason), `ensure <name>` (start it if it is stopped), `killoop [rounds]` (a launch/kill/reap
relaunch ladder that hammers the run-queue lifecycle and reports any queue anomaly), and
`svc`.

The panel has its own command group: `fb` prints the mode, EDID and mapping, `fb test` draws the
self-test pattern, `fb mode <w> <h>` re-programs the panel, `fb check` proves the write path by
reading pixels back through the MMU, and `fb crash` renders the panic screen. Screenshots of the
splash, the test pattern and the panic screen are in [docs/screenshots](docs/screenshots).

Input has its own command group too. `input` prints the event queue, every registered device
(keyboard, tablet, absolute range, IRQ), the scanner rules and the last events; `input dump <n>`
drains the queue; `input scan <payload>` runs a scan through the real state machine and reports
the latency against the 20 ms budget; `input viz [seconds]` draws a live event monitor with a
pointer crosshair on the panel; `input prefix`, `suffix`, `minlen`, `gap` and `charset` configure
the scanner; `hid` decodes USB HID boot reports through the same queue; `keymap` lists, changes
and resets key remappings. A barcode scanned while the shell is idle prints an asynchronous
`[scan]` line, and a burst that is not a scan is released as ordinary keystrokes.

The input path is real hardware, not a simulation. QEMU attaches a virtio keyboard and an
absolute tablet on virtio-mmio; both are classified from their own config space, the tablet's
0..32767 axes are scaled to the panel, and the keyboard shares one ordered event queue with the
tablet and the USB HID decoders. The QEMU run steps pass `-global virtio-mmio.force-legacy=false`
because QEMU still defaults the transport to legacy mode; the kernel only speaks modern virtio 1.0.
A 13-digit scan arrives as one atomic barcode event with 0 ms from the committing suffix to the
queued event. The monitor screenshot is
[phase38-input-monitor.png](docs/screenshots/phase38-input-monitor.png).

USB is the retail peripheral path. An xHCI driver claims the QEMU (and NEC) PCI function, maps
BAR0 as Device memory, resets the controller and runs command, event and transfer rings from one
non-cacheable DMA arena. Ports are reset and devices enumerated from their device,
configuration, interface, endpoint and string descriptors; HID keyboards/tablets feed the same
phase-38 event queue, CDC-ACM and FTDI bridges become serial devices, and a hub's children are
polled and enumerated. A barcode scanner is a HID keyboard: a fast digit burst plus CR commits
one barcode event. Unplug/replug releases the slot, disables it, releases the input device and
re-enumerates on the next attach. `usb` prints the controller, rings, ports, devices and counters;
`usb selftest` validates every bound class driver; `usb serial <n> send <text>` and
`usb serial <n> read` drive a serial bridge. The live monitor's header names the USB device and
HID/pointer counters. Screenshot:
[phase39-usb-input.png](docs/screenshots/phase39-usb-input.png).

Power is not a promise in a log line. QEMU attaches a real Intel 6300ESB watchdog over PCI; the scheduler kicks it every 250 ms on core 0, and `power hang` stops those kicks so the hardware resets the machine. The next boot reads the watchdog's reset flag, reports `previous boot was a watchdog reset`, and opens the FAT32-backed `POWER.JNL` to say whether the previous session ended cleanly. `power poweroff` and `power brownout` both run the same flush path: registered filesystems sync, a final journal record is written, the block device flushes, the watchdog is disarmed, and only then does PSCI power off. Thermal policy is visible in the scheduler: warm/hot/critical inject 25/50/75% idle ticks and `thermal bench` is measurably slower at critical, while `thermal clear` returns to 42 C and normal. `power`, `power journal`, `power selftest`, `thermal`, `watchdog` and the top-level `poweroff` expose all of it; `power viz` is the live dashboard. A machine with neither watchdog nor disk still boots, reports both limitations and passes the self-tests. Screenshot:
[phase40-power.png](docs/screenshots/phase40-power.png).

CASSAFS is the storage format the till will use, and phase 41 ships its byte-level contract.
The volume is a 4 KiB log-structured format: A/B superblocks, CRC32C on every record header and
payload, an inode tree with parent pointers and names, ordered byte extents into data records,
a free-space bitmap and a checkpoint, with explicit format/record versions and incompatible
feature refusal. `cassafs info` reports the A/B state, log head, tree and free map; `cassafs
format demo` writes a demo catalog; `cassafs verify` re-derives every CRC, tree edge, extent,
data CRC and bitmap bit; `cassafs dump` prints the log and extents; `cassafs cat` reads through
the extents; `cassafs viz` is the live dashboard. The host reader `zig-out/bin/cassafs` verifies
the same image outside the guest and is the reference dump/verify tool the phase requires. A
machine with no disk reports the absence and still passes its self-tests; formatting refuses
while the phase-40 FAT journal is mounted, because formatting would invalidate its storage.
Screenshot: [phase41-cassafs.png](docs/screenshots/phase41-cassafs.png).

The VFS is now mounted above CASSAFS. `vfs mount` scans partition 1, verifies every CRC and the
inode tree, and registers the volume at `/`; `vfs ls` walks the real directory order, `vfs stat`
reports inode/parent/size/mode, and `vfs cat` reads through opened handles. Path resolution
normalises `.`, `..`, repeated and trailing slashes and rejects empty paths. The core
(`src/lib/vfs.zig`) is backend-neutral; CASSAFS is the first adapter and phase 43 makes it
writable. `vfs create` allocates a new inode, `vfs write` writes at an offset through a write
handle, and `vfs df` reports the commit head, free blocks, record budget and next inode. A write
rebuilds only the 16 KiB chunks it touches, appends a new inode/free map/checkpoint and both
superblocks, then rescans the committed medium before the mounted view changes. A failed or
full write leaves the old view intact. This is append-only: journal replay, GC, truncate and
concurrent writers are still future work. A failed mount leaves no table entry and reports the
specific cause, including a missing disk, a bad CRC, or A/B fallback. Screenshots:
[phase42-vfs.png](docs/screenshots/phase42-vfs.png),
[phase43-write.png](docs/screenshots/phase43-write.png); design and limits:
[docs/vfs.md](docs/vfs.md).

The mounted volume now reads and writes through a bounded 4 KiB LRU page cache: 64 resident
pages (256 KiB), a 16-page dirty bound, four-page readahead, write-back on eviction and a real
flush before the commit superblock barrier. `vfs cache stats` shows resident/pressure/dirty
counters and hits/misses/readahead, `vfs cache flush` forces dirty pages, `vfs cache drop`
flushes and invalidates, and `vfs cache bench` measures eight sale-sized VFS commits against
the **100 ms** phase-44 budget while interleaving catalog reads. On QEMU the mount scan warms
23/64 pages (79% hit), the benchmark reached **27–38 ms** across runs with 16 catalog reads/1,264 B and
88% hit, and the 33-byte sale CRC survived cache drop, unmount/remount and the host verifier.
This is a single-volume, single-threaded storage cache, not the POS checkout; journal replay,
GC and concurrency remain future work. Screenshot:
[phase44-cache.png](docs/screenshots/phase44-cache.png); contract and limits:
[docs/page-cache.md](docs/page-cache.md).

User mode has its own commands. `user [mode]` runs the embedded EL0 program (0 normal,
1 privileged-register attempt, 2 kernel-memory read, 3 two-process isolation, 4 the capability
suite, 5 the IPC client, 6 the IPC server, 7 the IPC outsider, 8 the shared-memory owner,
9 the shared-memory peer, 10 the shared-memory outsider). `uprobe` runs the whole thing as one pass/fail suite: the program printing through
syscalls, the two privilege violations caught as faults, syscall pointers refused instead of
followed, two processes at the same virtual address each keeping their own data, five
launch/exit cycles leaving the page counter unchanged, and six capability cases — granted
rights working, missing rights refused with EPERM, unallocated and out-of-range handles
refused with EBADF without faulting, use-after-revoke refused, two holders of one ledger each
bounded by their own mask, and a full table returning EMFILE that recovers after a close; then
IPC — an endpoint arriving as a transferred handle, a synchronous call and reply, a ledger
handle travelling to another process and staying read-only there, forged and closed handles
refused with EBADF before anything is sent, revocation reaching the receiver's copy, a
deadline returning ETIMEDOUT with the channel intact, a blocked receiver that is not scheduled
while it waits, and 2000 exact round trips. The measured round-trip rate (5.7k msg/s on four
cores, 19.9k on one) is recorded in PLAN.md together with the open 100k target. Step 11 then
shares memory: a 4 MiB object created by one process, mapped read-write there and read-write
plus read-only in a second process through transferred handles, verified word for word in both
directions, with one sleeper woken on a futex word, a stale expectation returning EAGAIN, a
deadline returning ETIMEDOUT and an outsider refused with EBADF and EINVAL without a fault.
Step 12 loads a program: `pos.elf` is built as its own ELF64 executable, parsed by the kernel,
mapped segment by segment with the permissions the file asks for, given argv/envp on its
stack, and exits 42 after proving its BSS arrived zeroed and its arguments intact.

The kernel is built for the ARMv8.0-A baseline (`cortex-a53` + FP/NEON), so the same binary
runs on Cortex-A53/A55/A72/A76/A78/X-series, Neoverse N1/N2/V1, Apple silicon and Graviton.
Machine differences are discovered at boot from the device tree, not compiled in.

## Design principles

1. **Zig only.** Kernel, drivers, filesystem, network, UI and POS app are Zig source. The
   linker script is generated by `build.zig`; there are no `.S` or `.c` files. No libc is
   linked. Dependencies in the OS image: none.
2. **Discover, don't assume.** Every address, RAM size, interrupt number and clock frequency
   comes from firmware (device tree today, ACPI later).
3. **Fail loudly, fail safe.** A fault produces a named cause, not a silent reset. A power cut
   produces the previous state, not corruption.
4. **The till comes first.** Memory, CPU and I/O are budgeted per service so that the
   checkout path cannot be starved by a background catalog sync or a misbehaving printer.
5. **Least privilege.** Services hold capabilities, not ambient authority.

## Repository layout

```
build.zig            build graph, generated linker script, QEMU runner, host tests
src/main.zig         boot sequence, kernel wiring, self-tests
src/arch/aarch64/    cpu registers, MMU, exceptions/trap frames, GIC, timer
src/devices/         PL011 UART
src/user/            the EL0 demo program and its embedded image
src/kernel/          logging, panic, pmm, heap, irq, sync, percpu, thread, sched,
                     smp, addrspace, process, uaccess, syscall, machine, shell, pci,
                     virtio, block, partition, fat32, cassafs, vfs, fb, input, usb,
                     power, thermal, journal
src/devices/         PL011, PL031, virtio-mmio, virtio-blk, virtio-input, bochs-display, xhci,
                     i6300esb
src/lib/             freestanding helpers (device tree, EDID, 5x7 font, display modes,
                     keymap, scanner, USB descriptors/HID/xHCI arithmetic, power policy,
                     CASSAFS codec/format/verify/range-read/write path, page cache,
                     backend-neutral VFS, CASSAFS VFS adapter, read-only FAT32
                     VFS adapter, bounded writable tmpfs, bounded catalog CSV parser)
tools/mkimage.zig    host-side Image wrapper used by the build
tools/cassafs.zig    read-only host reference reader for CASSAFS images
tools/qemu_input_test.py  boots with virtio keyboard/tablet, drives them over HMP/QMP
tools/qemu_usb_test.py    boots xHCI with HID/tablet/hub/FTDI, drives QMP and checks replug
tools/qemu_power_test.py  watchdog hang/reset, poweroff, brownout, thermal and fallback
tools/qemu_cassafs_test.py  formats/verifies, reboots, corrupts and checks absence
tools/qemu_vfs_test.py      mounts CASSAFS through the VFS, reads, refuses bad mounts, reboots
tools/qemu_vfs_write_test.py  creates/writes/overwrites through the VFS, remounts, reboots,
                              checks out-of-space and committed-payload corruption
tools/qemu_page_cache_test.py  proves cache hits/readahead/eviction/write-back and the 100 ms
                               sale-commit budget in the booted image
tools/qemu_fat32_test.py        mounts partition 2 read-only, imports a 10k-row LFN catalog,
                               proves read-only/remount/reboot and corrupt-chain refusal
tools/qemu_vfs46_test.py        proves one resolver across CASSAFS/FAT32/tmpfs, tmpfs writes,
                               chmod, locks, two change events and remount
tools/qemu_storage49_test.py   injects transient/persistent media errors, proves retry,
                               quarantine/BadBlock, scrub and fsck over real CASSAFS data
tools/qemu_recovery50_test.py  proves bounded config snapshots, one-command rollback,
                               audit-preserving factory reset and support-bundle export
tools/qemu_gfx51_test.py      proves all-format/clip/alpha/damage pixels live, checks the
                               QEMU screendump, and rejects an injected card corruption
src/tests.zig        host unit-test root
docs/cassafs-format.md  the CASSAFS v1 on-disk contract, write path and limits
docs/vfs.md             the VFS contract, write path, backend interface and limits
docs/page-cache.md      phase-44 page-cache policy, commands, evidence and limits
docs/fat32-reader.md    phase-45 FAT32/LFN/cluster reader and catalog-import contract
docs/vfs-phase46.md     phase-46 tmpfs, permissions, locks, watches and evidence
docs/storage-phase49.md phase-49 retry policy, bad-range quarantine, fsck and evidence
docs/recovery-phase50.md phase-50 config snapshots, rollback, factory reset and evidence
docs/graphics-phase51.md phase-51 formats, surfaces, blits, clipping, alpha, damage and evidence
docs/screenshots/    what the panel actually shows, captured from QEMU
PLAN.md              100-phase master engineering plan
```

## Hardware

| Target | Status |
|---|---|
| QEMU `virt` (GICv2 now, GICv3 driver present) | boots to shell on 4 vCPUs, self-tests pass |
| Cortex-A53/A72 boards | kernel builds, board bring-up in Stage D |
| Integrated POS terminals | Stage D/H |
| Raspberry Pi 4/5 class SBCs | Stage D/H |

## License

Proprietary. All rights reserved.
