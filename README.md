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

**Phases 1–28 of [PLAN.md](PLAN.md) boot and run on QEMU `virt` with four cores.**
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
| 15 | kernel threads, 32 KiB stacks, exit and reaping | `threads`; `reap 8` → 0 pages leaked |
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
The remaining 73 phases are specified in [PLAN.md](PLAN.md) and are being implemented in
order. Nothing in this repository is a mock: everything marked done boots and runs.

## Building

Requires Zig 0.14.x. From a clean checkout:

```sh
zig build           # ELF + cassa.bin (raw) + cassa.img (arm64 Image) in zig-out/bin
zig build test      # host-side unit tests for pure logic
zig build run       # boot the raw image under QEMU with 4 vCPUs (firmware hands over a DTB)
zig build run-elf   # boot the ELF directly (no device-tree handoff)
zig build image     # only the flat arm64 Image container
```

`zig build run` invokes `qemu-system-aarch64` from `$PATH` (override with
`-Dqemu=/path/to/qemu-system-aarch64`) with `-smp 4` (override with `-Dsmp=N`). The kernel
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
                     smp, addrspace, process, uaccess, syscall, machine, shell
src/lib/             freestanding helpers (device-tree parser)
tools/mkimage.zig    host-side Image wrapper used by the build
src/tests.zig        host unit-test root
docs/                subsystem documentation
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
