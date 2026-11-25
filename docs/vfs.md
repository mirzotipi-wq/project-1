# CassaOS VFS (phases 42–45)

The VFS is a namespace above filesystem backends with read and write handles. It is implemented
in `src/lib/vfs.zig`; CASSAFS is the writable root backend in `src/lib/cassafs_vfs.zig`, the
read-only FAT32 backend is `src/lib/fat32_vfs.zig`, and the kernel front end is
`src/kernel/vfs.zig`. The design is backend-neutral: both filesystems provide the same
callbacks and a root inode, and the core has no CASSAFS or FAT32 types.

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
The kernel mounts CASSAFS at `/` and can mount the read-only FAT32 reader at `/media/usb`
from partition 2; the core knows neither backend's types.

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
vfs unmount               remove the root mount (refused while handles or /media/usb exist)
vfs unmount usb           remove /media/usb (refused while handles are open)
vfs info                  mount, volume, node/handle and I/O counters
vfs ls [path]             stable readdir; a file is refused
vfs stat <path>           type, inode, parent, size and mode
vfs cat <path>            sequential read to EOF, with byte count and CRC32C
vfs create <path>         create a regular file and a write handle
vfs write <path> <off> <text>  offset write through a write handle
vfs df                    log head, free blocks, record budget and next inode
vfs read <path> <off> <n> range read, clamped at EOF
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
FAT chain with `integrity failure` while the CASSAFS root stays readable.

## Limits

- Writes are append-only. No truncate, unlink, rename, directory creation, `fsync`, garbage
  collection or journal replay yet; the phase-43 goal of arbitrary power-cut recovery is **not**
  met. The harness covers clean unmount/remount, soft reboot and deliberate corruption.
- One writer per handle and no concurrent handle-table locking or shared file offsets. The shell
  is single-threaded, and the VFS tables are kernel-owned.
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
