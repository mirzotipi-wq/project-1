# CassaOS VFS phase 46: one namespace, three backends

Phase 46 turns the phase-42..45 read/write VFS into one interface over CASSAFS,
FAT32 and tmpfs, and adds the POS-relevant missing pieces: mutable permissions,
advisory file locks and bounded change notifications. The layer boundary is
unchanged: `src/lib/vfs.zig` owns namespace and policy; backend adapters own
storage. Only `src/lib/tmpfs.zig` is new storage.

## What shipped

- **tmpfs at `/tmp`** (`src/lib/tmpfs.zig`): 16 nodes, 4096 bytes per file,
  no allocation, nested directories, create/write/read/readdir and chmod. It is
  volatile scratch storage, not durable POS storage.
- **Optional backend operations**: `mkdir_fn` and `chmod_fn` on `Backend`.
  CASSAFS/FAT32 leave them null, so the VFS returns `Unsupported`/`ReadOnly`
  instead of pretending. tmpfs implements both.
- **Permissions**: `vfs chmod <path> <octal>` updates mode bits; read and write
  opens are checked against those bits. The file-type bits are preserved.
- **Locks**: per-handle advisory shared/exclusive whole-file locks. Shared locks
  coexist; an exclusive lock conflicts with every other handle. `close` releases
  the lock; a lock cannot outlive its mount because open handles already block
  unmount.
- **Watches/events**: eight watch slots and a 16-event ring. Directory watches
  match their subtree on component boundaries; file watches match one path.
  Events are `created`, `modified`, `mounted` and `unmounted`. A full ring
  overwrites the oldest event and increments `dropped_events`; it never grows.
- **Shell surface**: `vfs mount tmpfs`, `vfs unmount tmpfs`, `vfs mkdir`,
  `vfs chmod`, `vfs lock`, `vfs watch`, `vfs unwatch`, `vfs events`; `vfs info`
  and `vfs df` report tmpfs usage, locks, watches and pending/dropped events.
- **Input race repair**: the larger image exposed a pre-existing race in which
  `virtio_input.pollAll()` on the shell thread and the device IRQ handler could
  drain the same split virtqueue concurrently. `src/devices/virtio_input.zig`
  now serialises every drain with an IRQ-safe lock. The unchanged input harness
  captures all 13 barcode digits again.

## Backend contract

Every backend provides `stat`, `lookup`, `read`, `readdir`, `create` and `write`.
A writable backend may additionally provide `mkdir` and `chmod`. The VFS owns
canonicalisation, longest-prefix mount lookup, node identity, handles, mode-bit
checks, locks and watches. No backend knows about another backend's types.

Mounts are still longest-prefix and component-boundary checked. With all three
mounted the namespace is:

```text
/           CASSAFS, writable root
/media/usb  FAT32, read-only
/tmp        tmpfs, writable, volatile
```

`normalizePath` is shared, so a path is resolved the same way regardless of
which mount owns its first component. The phase-46 harness proves this with
dot-relative and dot-dot inputs:

```text
./catalog/products.db                         -> /catalog/products.db
./media/usb/./store-catalog-2026.csv           -> /media/usb/store-catalog-2026.csv
./tmp/spool/../spool/notice.txt               -> /tmp/spool/notice.txt
```

## Booted evidence

`python3 tools/qemu_vfs46_test.py` boots QEMU `virt` on a two-partition disk:
CASSAFS on partition 1 and a foreign-formatted FAT32 catalog on partition 2,
then mounts tmpfs at `/tmp`.

Observed on the final build:

- `mount table 3/8` after CASSAFS, FAT32 and tmpfs are mounted.
- tmpfs reports 16 nodes, 4096 B/file and is volatile.
- `notice.txt` is created and 7 bytes (`phase46`) are written; readback is
  **7 bytes, CRC32C `0x6d6a12e7`**.
- `vfs chmod /tmp/spool/notice.txt 444` reports `mode 0o100444`; a write is
  refused with `permission denied`, while a read still returns 7 bytes.
- `vfs chmod ... 644` restores writes; appending `ok` produces a **9-byte**
  file, read back with CRC32C **`0x9e9cac38`**.
- `vfs lock /tmp/spool/notice.txt` acquires exclusive, refuses a second
  exclusive handle with `LockConflict`, then proves two shared locks coexist;
  both PASS lines are printed.
- Watch id 1 on `/tmp` receives exactly two events:
  `created /tmp/spool/event.txt` and `modified /tmp/spool/event.txt`.
- `vfs info` reports `3 mount(s)`, `1 watch(es), 0 pending event(s)` after the
  drain.
- Unmounting tmpfs discards the scratch files; the CASSAFS root still reads
  `/catalog/products.db` at 73 bytes. A remount starts with **1 node / 0 data
  bytes**.
- The same VFS reimports the phase-45 FAT32 catalog:
  **10,000 rows, 220,021 bytes, max line 21, CRC32C `0x8678e4e7`**.

Host tests: `zig build test --summary all` reports **233/233**, up from 231.
The two new tests cover nested tmpfs paths and the permission/lock/event
contract. `zig build` is clean.

## Regression sweep

All eight prior harnesses pass unchanged, run one at a time on an idle host:

| Harness | Observed |
|---|---|
| `qemu_input_test.py` | barcode `4006381333931`, **13 chars, 259 ms**, **0 ms** suffix-to-queue, HID and no-input PASS |
| `qemu_usb_test.py` | **4/4** scenarios |
| `qemu_power_test.py` | thermal **2379 -> 3853 ms (1.62x)**, reset/poweroff/brownout/fallback PASS |
| `qemu_cassafs_test.py` | format/verify/reboot/fallback/corruption/absence PASS |
| `qemu_vfs_test.py` | mount/read/refusal/fallback/reboot PASS |
| `qemu_vfs_write_test.py` | 7-byte CRC `0xdb03992b`; 8-byte CRC `0x394478f0`; out-of-space/corruption PASS |
| `qemu_page_cache_test.py` | 23/64 pages, 79% hit, 21/6 cold, **29 ms** max sale commit, **64/64 pages**, 344 evictions, 88 writebacks, sale CRC `0x12b569fa` |
| `qemu_fat32_test.py` | **10,000 rows / 220,021 bytes / max line 21 / CRC32C `0x8678e4e7`**, read-only/remount/reboot/corrupt-chain PASS |

No assertion was weakened, no check skipped and no timeout was changed.

## Limits

- tmpfs is volatile and fixed at 16 nodes / 4 KiB per file. It does not survive
  unmount or reboot and must not hold receipts, catalog data or the sale log.
- Permissions are mode bits only. There is no uid/gid, ACL, ownership check,
  capability enforcement at the VFS boundary, or chmod on CASSAFS/FAT32.
- Locks are advisory, whole-file, non-blocking and have no deadlock detection.
  They protect cooperating POS processes, not a hostile process.
- Watches are kernel-internal and bounded. They are not a user-space inotify
  syscall yet, cover create/write/mount only, and cannot emit unlink/rename
  events because those operations do not exist.
- One tmpfs, one FAT32 mount and one CASSAFS root; the VFS table remains
  single-threaded kernel-owned state.
- `vfs selftest` still exercises the CASSAFS path. tmpfs, permission, lock and
  watch behavior is proven by the host tests and the phase-46 QEMU harness,
  not by expanding the boot self-test.
