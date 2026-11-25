# CassaOS VFS (phases 42–46)

The VFS is a namespace above filesystem backends with read and write handles. It is implemented
in `src/lib/vfs.zig`; CASSAFS is the writable root backend in `src/lib/cassafs_vfs.zig`, the
read-only FAT32 backend is `src/lib/fat32_vfs.zig`, the bounded scratch backend is
`src/lib/tmpfs.zig`, and the kernel front end is `src/kernel/vfs.zig`. The design is
backend-neutral: every filesystem provides the same callbacks and a root inode, and the core
has no CASSAFS, FAT32 or tmpfs types.

## Namespace

`normalizePath(cwd, input, out)` produces one canonical absolute path:

- `.` is dropped, `..` pops one component and stops at `/`;
- repeated and trailing slashes are collapsed;
- an empty input is `InvalidPath`; `""` is never treated as the root;
- names longer than 63 bytes and paths longer than 255 bytes are refused;
- relative paths are resolved against the current directory, which is canonical for shell
  commands in phase 42 (`/`).

Mounts are longest-prefix entries in an eight-entry table. A mount at `/` owns the normal
namespace; a mount at `/media/usb` shadows only that component subtree. Path lookup selects
the longest matching mount point, then walks the remaining components through the backend.
The kernel mounts CASSAFS at `/`, the read-only FAT32 reader at `/media/usb` from partition 2,
and tmpfs at `/tmp`; the core knows none of their types. All three go through the same
longest-prefix lookup and component walk.

## Nodes and handles

The VFS owns:

- a 128-entry node table keyed by `(mount, backend inode)`, with the last `stat` result;
- 32 file handles, each pointing at a node, a sequential offset and open flags (`read`, `write`,
  `create`);
- counters for mounts, nodes, handles, lookups, reads and `readdir` calls.

`open` checks read/write mode bits and the backend's writable flag. A write open on a read-only
backend returns `ReadOnly`; a write open on a directory returns `IsDirectory`; `create` requires
the write flag and an existing directory parent. A file can be read but `readdir` on it returns
`NotDirectory`; a directory can be opened and iterated but `read`/`write` on it returns
`IsDirectory`. `readAt` clamps to the inode size, so an offset at or past EOF returns zero bytes
and a read crossing EOF is short, never padded with stale memory. `writeAt` writes at an explicit
offset and `write` advances the handle offset. On success the backend returns the refreshed
stat; the VFS updates the node before returning. `close` releases the handle.

Each handle also carries its canonical path. This is needed for change events: a write through
a handle names the exact file even after the path has been re-resolved or a directory has moved.

Unmount checks every open handle and refuses with `Busy` while one references the mount.
A successful unmount removes the mount and every node that belonged to it. Root unmount is also
refused while a child mount such as `/media/usb` or `/tmp` remains.

## Permissions, locks and events

Permissions are the mode bits returned by the backend. `chmod` accepts permission bits
`0..7777`, asks the backend to preserve the file-type bits, refreshes the VFS stat, and is only
available on a writable backend that supplies `chmod_fn`. CASSAFS does not implement it yet and
returns `Unsupported`; FAT32 is read-only. A mode with no read bits refuses `open` for read; a
mode with no write bits refuses a write open and a later write. tmpfs implements all of this.

Locking is advisory and whole-file. A handle may hold one shared or exclusive lock; shared
locks may coexist, while an exclusive lock conflicts with every other lock on the same node.
`lock` is non-blocking and returns `LockConflict`; `unlock` returns `NotLocked` when nothing is
held; `close` releases the lock automatically. Handles already prevent unmount, so a lock
cannot outlive its mount.

Watches are the VFS's inotify-style surface. `watch <path>` resolves an existing path and
returns a numeric id; a directory watch covers its subtree by component boundary, while a file
watch matches only that file. The VFS emits `created` on create/mkdir, `modified` on a successful
non-empty write, and `mounted`/`unmounted` on mount changes. There are eight watch slots and a
16-event ring; when the ring is full the oldest event is overwritten and `dropped_events` is
incremented, so a slow consumer can never make the kernel allocate without bound. `events`
drains the ring in sequence order; `unwatch` removes a watch.

## FAT32 read-only backend

`src/lib/fat32_vfs.zig` wraps the phase-36 driver. FAT32 has no inode number, so a stable
backend inode is the directory entry's on-disk `(sector, slot)` packed into a `u64`; the root
is inode 1. The adapter caches up to 128 entry locations, resolves names case-insensitively,
walks subdirectories by cluster, hides `.` and `..`, and validates a file's FAT chain against
its directory size before exposing it. Reads call `fat32.readFileRange`, which streams from a
cluster chain without the old whole-file 64 KiB buffer. The backend is registered with
`writable = false`; the VFS therefore refuses a write/create open with `ReadOnly` before the
backend can be asked, and the backend's create/write callbacks also return `ReadOnly`.

Mounting validates the BPB, FAT geometry, FAT[0] media marker and root directory before the
VFS table gets an entry. A corrupt file chain is refused when the file is looked up; a
self-loop in the FAT cannot become a partial catalog read. The phase-45 fixture is a
foreign-formatted 204,800-sector FAT32 partition with a 22-character LFN file, 201,616
512-byte clusters and root cluster 2. See [fat32-reader.md](fat32-reader.md).

## CASSAFS backend

`Adapter` translates inode numbers and calls `cassafs.readInodeRange`, which walks the ordered
extents and reads only the requested byte range. `readdir` walks the scan report's inode order
and filters by parent, so its ordering is the on-disk order and is stable across calls. `stat`
returns inode, parent, type, size and mode. Mount scans the volume from the active superblock,
honours A/B fallback, verifies every record CRC, the inode tree, extents, data CRCs and the free
map, and only then calls `vfs.mount`. A failed scan creates no mount entry.

`create` appends a new inode record and a new checkpoint/superblock generation. `writeAt` rebuilds
only the touched 16 KiB data chunks, appends a new inode record, free map, checkpoint and both
superblocks, then rescans the committed medium into the adapter's report. The mounted view is
not updated until that rescan succeeds; a failed or full write leaves the old committed view in
place. The append-only format has no journal replay or GC yet.

Both read and write calls pass through a **64-page (256 KiB) 4 KiB LRU page cache** between the
CASSAFS adapter and the partition block view. It has a 16-page dirty bound, four-page readahead,
dirty-written-before-eviction and a flush before the commit superblock barrier. The cache is
mounted in `src/kernel/cassafs.zig`; the scanner, validation and format are unchanged. Unmount
flushes and invalidates it. See [page-cache.md](page-cache.md).

## Commands

```text
vfs mount                 scan partition 1 and mount CASSAFS at /
vfs mount usb             mount read-only FAT32 from partition 2 at /media/usb
vfs mount tmpfs           mount the bounded writable scratch filesystem at /tmp
vfs unmount               remove the root mount (refused while handles or child mounts exist)
vfs unmount usb           remove /media/usb (refused while handles are open)
vfs unmount tmpfs         discard /tmp and remove it
vfs info                  mounts, volume, nodes/handles, locks, watches and events
vfs ls [path]             stable readdir; a file is refused
vfs stat <path>           type, inode, parent, size and mode
vfs cat <path>            sequential read to EOF, with byte count and CRC32C
vfs create <path>         create a regular file and a write handle
vfs mkdir <path>          create a directory on a backend with mkdir_fn
vfs chmod <path> <octal>  change permission bits on a backend with chmod_fn
vfs write <path> <off> <text>  offset write through a write handle
vfs df                    log head, free blocks, record budget and next inode
vfs read <path> <off> <n> range read, clamped at EOF
vfs lock <path>           prove exclusive refusal and shared coexistence
vfs watch <path>          add a bounded change watch
vfs unwatch <id>          remove a watch
vfs events                drain created/modified/mounted/unmounted events
vfs import <csv>          stream and validate a catalog CSV through the VFS
vfs cache [stats|flush|drop|bench]  page cache counters, flush, invalidate, sale-commit probe
vfs selftest              namespace, handles, EOF, readdir and access checks
vfs viz [seconds]         live dashboard, if a framebuffer is present
```

## Failure modes

The kernel-side self-test reports each check explicitly. The phase-42 QEMU harness proves the
read path, no-disk/bad-CRC refusals and A/B fallback. The phase-43 harness proves a create,
7-byte write, offset overwrite to 8 bytes, CRC-validated read-back, unmount/remount, soft reboot,
an 8-block volume refusing a create with `NoSpace`, and a committed payload corrupted on the
medium being refused with `CRC32C mismatch` and no mount entry. The phase-44 harness proves
mount-warmed hits/misses, readahead, bounded dirty write-back and a sale-sized commit under the
100 ms budget, then drops the cache and checks the same committed bytes after unmount/remount and
with the host verifier. The phase-45 harness mounts a foreign FAT32 partition read-only, decodes
its 22-character LFN, streams 10,000 rows/220,021 bytes/CRC32C `0x8678e4e7` through `vfs import`,
refuses writes, repeats the import after unmount/remount and a soft reboot, and refuses a looped
FAT chain with `integrity failure` while the CASSAFS root stays readable. The phase-46 harness
mounts CASSAFS, FAT32 and tmpfs together, canonicalises relative/dot-dot paths through all
three, writes a 7-byte tmpfs file (CRC `0x6d6a12e7`), proves chmod 444 refusal and 644
restoration (9-byte CRC `0x9e9cac38`), exercises exclusive/shared locks, records exactly two
created/modified events for a watched tmpfs file, remounts tmpfs empty, and reimports the FAT32
catalog. See [vfs-phase46.md](vfs-phase46.md).

## Limits

- CASSAFS writes are append-only. No truncate, unlink, rename, `fsync`, garbage collection or
  journal replay yet; the phase-43 goal of arbitrary power-cut recovery is **not** met. `mkdir`
  is implemented on tmpfs only. The harness covers clean unmount/remount, soft reboot and
  deliberate corruption.
- One writer per handle and no concurrent handle-table locking or shared file offsets. The shell
  is single-threaded, and the VFS tables are kernel-owned. Locks are advisory and non-blocking.
- Permissions are mode bits without uid/gid or ACLs. There is no capability check at the VFS
  boundary and no `chmod` on CASSAFS or FAT32; tmpfs is the only backend with mutable modes.
- Watches are kernel-internal, bounded (8 watches/16 events), cover create/write/mount only,
  and are not exposed as a user syscall. There is no unlink/rename event because those
  operations do not exist yet.
- tmpfs is volatile and fixed at 16 nodes and 4 KiB per file. It is scratch storage only; it is
  not a durable receipt/catalog backend and does not survive unmount or reboot.
- CASSAFS on partition 1 is the only writable backend. FAT32 on partition 2 is read-only and
  only one FAT32 mount is supported at a time; the phase-36 driver owns static scratch buffers,
  and there is no USB mass-storage driver yet. A second partition stands in for the vendor stick.
- FAT32 exposes no ownership/mode/timestamps beyond a fixed read-only file mode; LFN non-ASCII
  units become `?`, names are capped at 63 bytes and LFN checksums are not validated. The CSV
  importer accepts only the exact `sku,name,price_cents` header and unquoted three-field rows.
- The phase-41 reference format caps a volume at 128 inodes/records, 128 log records and eight
  extents per file (128 KiB per file). The PLAN's 100k-file tree and 2%-of-page-cache random-read
  target cannot be met by this pass; larger format bounds are a later scale-out change.
- The page cache is 64 pages / 16 dirty pages, single-mounted-volume and single-threaded, with no
  background writeback thread or cross-mount coherence. It does not implement the POS checkout;
  `vfs cache bench` measures a sale-sized storage commit under interleaved catalog reads.
- No checkpoint redundancy; a damaged checkpoint or data record is reported and refused rather
  than repaired. The A/B pair covers superblock damage only.
