# CassaOS VFS (phases 42–44)

The VFS is a namespace above filesystem backends with read and write handles. It is implemented
in `src/lib/vfs.zig`; CASSAFS is the first backend, in `src/lib/cassafs_vfs.zig`, and the kernel
front end is `src/kernel/vfs.zig`. The design is deliberately backend-neutral: a second
filesystem provides the same callbacks and a root inode.

## Namespace

`normalizePath(cwd, input, out)` produces one canonical absolute path:

- `.` is dropped, `..` pops one component and stops at `/`;
- repeated and trailing slashes are collapsed;
- an empty input is `InvalidPath`; `""` is never treated as the root;
- names longer than 63 bytes and paths longer than 255 bytes are refused;
- relative paths are resolved against the current directory, which is canonical for shell
  commands in phase 42 (`/`).

Mounts are longest-prefix entries in an eight-entry table. A mount at `/` owns the normal
namespace; a mount at `/mnt/data` would shadow only that component subtree. Path lookup
selects the longest matching mount point, then walks the remaining components through the
backend. There is no second backend yet, but the VFS has no CASSAFS types in its core.

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

Unmount checks every open handle and refuses with `Busy` while one references the mount.
A successful unmount removes the mount and every node that belonged to it.

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
vfs unmount               remove the mount (refused while handles are open)
vfs info                  mount, volume, node/handle and I/O counters
vfs ls [path]             stable readdir; a file is refused
vfs stat <path>           type, inode, parent, size and mode
vfs cat <path>            sequential read to EOF, with byte count and CRC32C
vfs create <path>         create a regular file and a write handle
vfs write <path> <off> <text>  offset write through a write handle
vfs df                    log head, free blocks, record budget and next inode
vfs read <path> <off> <n> range read, clamped at EOF
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
with the host verifier.

## Limits

- Writes are append-only. No truncate, unlink, rename, directory creation, `fsync`, garbage
  collection or journal replay yet; the phase-43 goal of arbitrary power-cut recovery is **not**
  met. The harness covers clean unmount/remount, soft reboot and deliberate corruption.
- One writer per handle and no concurrent handle-table locking or shared file offsets. The shell
  is single-threaded, and the VFS tables are kernel-owned.
- CASSAFS on partition 1 only; the mount table supports other points and backends, but no other
  backend exists.
- The phase-41 reference format caps a volume at 128 inodes/records, 128 log records and eight
  extents per file (128 KiB per file). The PLAN's 100k-file tree and 2%-of-page-cache random-read
  target cannot be met by this pass; larger format bounds are a later scale-out change.
- The page cache is 64 pages / 16 dirty pages, single-mounted-volume and single-threaded, with no
  background writeback thread or cross-mount coherence. It does not implement the POS checkout;
  `vfs cache bench` measures a sale-sized storage commit under interleaved catalog reads.
- No checkpoint redundancy; a damaged checkpoint or data record is reported and refused rather
  than repaired. The A/B pair covers superblock damage only.
