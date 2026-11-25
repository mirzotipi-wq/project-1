# CassaOS storage health (phase 49)

Phase 49 makes a failing medium observable before it becomes a lost sale. It does
not add a second storage path: every check goes through the existing
VFS → CASSAFS page cache → partition view → virtio-blk request path. The pure
health policy is `src/lib/storage_health.zig`; the retry and quarantine edges
live in `src/devices/virtio_blk.zig` because that is where the request state
machine and transport reset already live.

The done criterion is deliberately narrow: **simulated media errors reduce to
retries and warnings without data loss**. The implementation quarantines a range
it cannot read, makes reads of that range fail as `BadBlock`, and lets the
operator prove the range is readable again with an explicit scrub. It does not
pretend that a disk with no spare sectors was repaired.

## Layers

```
shell: blk health | fsck | inject | clear | scrub | viz
                         │
CASSAFS fsck ────────────┤  cassafs.scan(): superblocks, records, inodes,
                         │  extents, data CRC, free map (read-only)
VFS / page cache ────────┤  unchanged; fsck bypasses the page cache
partition view ──────────┤  unchanged LBA offset
virtio-blk request ──────┘  quarantine check, retry, health ledger, fault inject
```

`cassafs.fsck()` is the same verifier used by mount (`cassafs.scan`), but it
returns the actual error to the caller instead of only printing it. That matters
for the refusal contract: the shell can print `BadBlock`, `BadCrc`,
`BadSuperblock`, `BadFreeMap`, `Overlap`, `ExtentOutOfRange` and the other named
reasons rather than collapsing them into a generic `Io`.

## Health model

`Health` is bounded and allocation-free:

| Field | Bound / meaning |
|---|---|
| states | `healthy`, `degraded`, `failing` |
| media counters | read/write/flush operations, sectors read/written |
| retry ledger | retries, recovered, unrecovered, per-op failure counters |
| bad table | **32** `(lba, count, failures)` ranges |
| warnings | one transition warning for first recoverable error, first exhausted request, first bad range, first full table |

A successful request counts its operation and sectors. A failed attempt that
will be retried calls `noteRetry`: the first one moves `healthy → degraded` and
raises one warning. A retry that succeeds calls `noteRecovered` and increments
`recovered`. An exhausted request calls `noteFailure` (`failing`, one warning per
first failure) and, for reads/writes, `addBad` quarantines the range. Repeated
failures that overlap an existing entry increment its failure count instead of
growing the table. A full table raises one warning and refuses to evict an older
bad range.

`clearBad` is called only after a scrub has read every sector in the range. It
removes overlapping entries and returns `failing → degraded`; it never returns
to `healthy`, because the supervisor should still see that the device has a
history. That is intentional, not a missing reset.

### Why the boot self-test does not make every boot degraded

The phase-34 self-test forces one request to time out by withholding the device
notification. That is a test fault, not a medium warning. The request path marks
that attempt as `forced_timeout` and skips the health retry/warning accounting for
it. Operational timeouts still increment `timeouts`, `retries`, the health
ledger and the warning state. This is why the baseline in the harness is exactly
`healthy, warnings 0` despite the self-test having exercised the recovery path.

## Retry and quarantine path

`request(kind, lba, buf, len, bypass_bad)` now:

1. rejects a range present in the bad table with `BadBlock` unless `bypass_bad`
   is set (scrub uses the bypass);
2. checks the test-only injector before submission; a simulated medium error
   takes the same retry path as a real I/O status;
3. submits the normal 16-byte virtio header, data descriptor and status byte;
4. waits for completion; a missing completion resets/re-negotiates the
   transport through the existing recovery function and retries;
5. on a successful retry after a failure, records `recovered`;
6. after three attempts, records `unrecovered`, quarantines reads/writes and
   returns `IoError` (the CASSAFS adapter maps the later `BadBlock`).

A fault injector is not a second I/O path: it fails before the descriptor is
submitted, so it cannot leave a half-submitted chain or a stale used entry.
`blk inject` can arm `read`, `write` or `flush`. Flush has no range and matches
any flush while armed; its final failure is counted as a flush failure but does
not add a bad range. The harness exercises read and flush faults; the write path
shares the same `request` code but has no independent booted injection case.

## fsck and exact refusals

`blk fsck` calls `cassafs.fsck()` and prints either:

```
blk fsck    : PASS, <records> record(s), <inodes> inode(s), <files> file(s), <bytes> data byte(s), <free> free block(s)
blk fsck    : read-only; every superblock, record, extent, data CRC and free-map bit verified
```

or the actual error name:

```
blk fsck    : REFUSED: <Error>
```

The first persistent medium failure is `REFUSED: Io` because the request itself
exhausted its retries. The next attempt is refused before the device is touched
because the range is quarantined, so it prints `REFUSED: BadBlock`. This
distinction is the point of the test: the first refusal says the medium was
unreadable, the second says the storage layer learned from it. A separate
scenario flips one byte of a demo record payload directly on the image (not
through the VFS), and fsck prints `blk fsck    : REFUSED: BadCrc`; it never
reports `PASS` for a volume whose data CRC no longer matches.

`fsck` does not repair anything. `blk scrub <lba> <sectors>` performs bounded
8-sector reads with the bad-range bypass, then clears the matching quarantine
only if all reads succeeded. A scrub of a range that still fails prints
`REFUSED: Io` and leaves the quarantine in place.

## Shell and supervisor surface

```
blk                       disk/device/layer/irq counters plus health
blk health                state, warnings, retries, recovered/unrecovered,
                          media reads/writes/flushes/sectors, last error,
                          and the bounded bad-range table
blk fsck                  full read-only CASSAFS verification
blk inject read|write|flush <lba> <sectors> <failures>
blk clear                 clear the test fault injector
blk scrub <lba> <sectors> bounded readback, then clear matching quarantine
blk viz [seconds]         live supervisor dashboard (1–60 s, default 8)
```

`blk viz` is the phase's supervisor UI: it paints the state colour (green/amber/
red), warning and retry counters, media counters, last error with LBA/range/
reason, and the quarantined ranges, then repaints every 100 ms until the bounded
duration expires. It uses the phase-37 framebuffer surface and the existing
`drawText` path; it is not a new graphics stack.

## Booted evidence

`python3 tools/qemu_storage49_test.py` boots the real aarch64 image on the same
two-partition disk used by phases 45/47/48. It deliberately re-establishes those
layers before injecting anything:

```
10k FAT32 import: 10000 rows, 220021 B, CRC32C 0x8678e4e7
retail import : /media/usb/store-catalog-2026-small.csv, 8 row(s), 8 product(s)
retail seed   : 239 record(s), 64 receipt(s), 128 line(s)
sales init : /catalog/sales.log, 64 B header, 0/16 transactions
sales commit: seq 1, terminal T1
baseline: fsck PASS, product 73 B CRC 0x3b60dc1d, health healthy
```

The baseline fsck line is:

```
blk fsck    : PASS, 37 record(s), 7 inode(s), 4 file(s), 62214 data byte(s), 16284 free block(s)
```

One transient read fault is armed on physical LBA 2048 + 16 sectors, the
CASSAFS blocks 0/1 superblock range:

```
blk inject  : read lba 2048 +16, 1 simulated failure(s)
blk fsck    : PASS, 37 record(s), 7 inode(s), 4 file(s), 62214 data byte(s), 16284 free block(s)
health      : degraded, warnings 1, retries 1, recovered 1, unrecovered 0, bad blocks 0
media       : reads 1319, writes 92, flushes 14, sectors read 6569, sectors written 736
last error  : read lba 2048 +8, reason io
```

The request that failed was the 8-sector CASSAFS block read, so the recorded
range is `+8` even though the injector matched the 16-sector superblock range.
The retry succeeded and fsck saw identical bytes.

The harness then writes an 8-byte scratch file, arms one flush fault, and runs
`vfs cache flush`:

```
blk inject  : flush lba 0 +1, 1 simulated failure(s)
vfs cache   : dirty pages written back and the backing device flushed
health      : degraded, warnings 1, retries 2, recovered 2, unrecovered 0, bad blocks 0
```

`blk viz 1` starts and closes the supervisor dashboard:

```
blk viz     : 1s storage health dashboard
blk viz     : closed
```

A persistent read fault is then armed with 99 failures:

```
blk fsck    : REFUSED: Io
blk fsck    : REFUSED: BadBlock
health      : failing, warnings 3, retries 5, recovered 2, unrecovered 1, bad blocks 1
last error  : read lba 2048 +8, reason io
bad sector  : lba 2048 +8, 1 failure(s)
```

After `blk clear` and `blk scrub 2048 16`:

```
blk scrub   : lba 2048 +16, 1 bad entr(ies) cleared, readback PASS
blk fsck    : PASS, 44 record(s), 8 inode(s), 5 file(s), 62222 data byte(s), 16270 free block(s)
health      : degraded, warnings 3, retries 5, recovered 2, unrecovered 1, bad blocks 0
bad sectors : none
```

The count grew from 37 to 44 records and from 4 to 5 files because the harness
added its scratch file; the product file and the phase-48 sale are unchanged.
The harness asserts the product is still 73 bytes / `0x3b60dc1d` and that
`sales verify` still says `PASS, 1 transaction(s)` after:

1. `vfs cache flush` and `vfs cache drop`;
2. `vfs unmount usb`, `vfs unmount /`, remount `/`;
3. a soft reboot and remount.

The final fsck after reboot also passes. A clean shutdown follows.

A second fixture is formatted with the demo tree, powered off, then one byte of
the products record payload is flipped directly on the image. The next boot's
fsck refuses it instead of inventing a clean volume:

```
blk fsck    : REFUSED: BadCrc
```

That is the corrupted-volume refusal path; the raw edit bypasses the VFS so it
cannot be mistaken for an application-level `sales verify` failure.

## Host tests

`zig build` is clean. `zig build test --summary all` reports **252/252** tests,
up from 248. The four new tests in `src/lib/storage_health.zig` cover:

- recovery from one media error: degraded, one warning, one retry, one recovered;
- exhausted retry, bounded quarantine, overlap update and scrub clearing;
- a full 32-entry table refusing eviction and reporting the full-table warning;
- independent write/flush failure counters and reasons (including an
  unsupported flush), so a flush fault cannot be misreported as a read failure.

## Regression sweep

All eleven pre-existing harnesses were run unchanged, one at a time, from this
tree. The observations from this run were:

| Harness | Observed |
|---|---|
| `qemu_input_test.py` | `4006381333931 (13 chars, 259 ms burst)`; `delivery : last 0 ms, max 0 ms ... (budget 20 ms)`; both input and no-input boots PASS |
| `qemu_usb_test.py` | all **4/4** scenarios: HID, hub, FTDI serial, no-controller |
| `qemu_power_test.py` | normal 2379 ms → critical 3885 ms (**1.63x**); powers off, brownout, fallback and screenshot scenarios PASS. The ratio is host-timing dependent and is asserted as throttling, not a fixed number. |
| `qemu_cassafs_test.py` | format/verify/read-back/reboot/fallback/corruption/absence PASS |
| `qemu_vfs_test.py` | mount/read/refusals/fallback/reboot PASS |
| `qemu_vfs_write_test.py` | write/overwrite, out-of-space and corruption refusal PASS |
| `qemu_page_cache_test.py` | 23/64 pages, 79% hit; 21 hit/6 miss cold; 22 readahead reads; max sale commit **29 ms**/100 ms; 64/64 pages, 344 evictions, 88 writebacks, 20 flushes; harness-asserted sale CRC `0x12b569fa`; cache drop/remount/host verify PASS |
| `qemu_fat32_test.py` | **10,000 rows / 220,021 B / max line 21 / CRC32C `0x8678e4e7`**; LFN, read-only, remount, reboot, corrupt-chain and one-partition cases PASS |
| `qemu_vfs46_test.py` | three-backend paths, tmpfs, chmod, locks, watches, remount PASS; FAT32 reimport `0x8678e4e7` |
| `qemu_retail_test.py` | 239 records, 64 receipts, 128 lines; retail PASS with cache drop/remount/reboot and `RecordCorrupt` refusal |
| `qemu_sales48_test.py` | three transactions / 6 units / 1555 cents / 2 terminals; `sales verify : PASS`; duplicate no-op, `Conflict`, `RecordCorrupt` across recovery boundaries PASS |

The page-cache harness asserts the sale file's 33-byte size and
`0x12b569fa` CRC rather than printing the CRC, so that value is a checked value
in the harness, not a transcript line.

## Limits (honest)

- **No eMMC/SD registers in QEMU.** The transport is virtio-blk. The health
  surface exposes transport-level operation/sector/retry/failure/bad-range
  counters, not eMMC EXT_CSD life-time estimates, SD status bits or SMART
  attributes. A real board port needs a device-specific health provider behind
  this policy; none is claimed here.
- **Bad ranges are in-memory.** The 32-entry table is not persisted, is cleared
  on re-probe and does not survive a reboot. The first read after reboot gets a
  fresh retry budget. There is no remap, spare-sector pool, ECC or persistent
  grown-defect list.
- **fsck refuses, it does not repair.** A damaged superblock or record is
  reported, not rewritten. `blk scrub` only proves the range can be read and
  removes the quarantine; it does not rewrite data or reconstruct a filesystem.
- **Bounded retry, not a recovery daemon.** Three attempts and one transport
  recovery per request; there is no background media scan, patrol read, thermal
  backoff or I/O scheduler priority for health work.
- **Only read and flush fault injection is boot-tested.** The write branch uses
  the same `request` function and health calls, but this phase has no separate
  booted write-fault scenario.
- **Single-writer shell.** Health counters and the bad table are not atomic
  across concurrent writers because the shell/block path is single-writer; a
  future multi-process storage service must add locking or atomics.
- **Simulated faults, not physical removal.** The harness proves the software
  retry/quarantine/refusal contract; it does not yank the virtio device or cut
  power during a write. The phase-44 page-cache and phase-48 sale harnesses
  separately prove cache-drop, unmount and reboot durability.
- **Dashboard render is not pixel-asserted here.** `blk viz` exercises the
  framebuffer drawing path and prints the same health snapshot, but this harness
  does not take a screenshot or compare pixels; the framebuffer pixel path is
  covered by phase 37/38/40 screenshots.
