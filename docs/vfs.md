# CassaOS VFS (phase 42)

The VFS is a read-only namespace above filesystem backends. It is implemented in
`src/lib/vfs.zig`; CASSAFS is the first backend, in `src/lib/cassafs_vfs.zig`, and the kernel
front end is `src/kernel/vfs.zig`. The design is deliberately backend-neutral: a second
filesystem only has to provide four callbacks and a root inode.

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
- 32 file handles, each pointing at a node, a sequential offset and open flags;
- counters for mounts, nodes, handles, lookups, reads and `readdir` calls.

`open` accepts read-only access, checks that the mode has at least one read bit, and refuses a
write flag with `ReadOnly`. A directory can be opened and iterated but `read` on it returns
`IsDirectory`. A file can be read but `readdir` on it returns `NotDirectory`. `readAt` clamps
to the inode size, so an offset at or past EOF returns zero bytes and a read crossing EOF is
short, never padded with stale memory. `read` advances the handle offset; `close` releases it.

Unmount checks every open handle and refuses with `Busy` while one references the mount.
A successful unmount removes the mount and every node that belonged to it.

## CASSAFS backend

`Adapter` translates inode numbers and calls `cassafs.readInodeRange`, which walks the ordered
extents and reads only the requested byte range. `readdir` walks the scan report's inode order
and filters by parent, so its ordering is the on-disk order and is stable across calls. `stat`
returns inode, parent, type, size and mode. Mount scans the volume from the active superblock,
honours A/B fallback, verifies every record CRC, the inode tree, extents, data CRCs and the free
map, and only then calls `vfs.mount`. A failed scan creates no mount entry.

## Commands

```text
vfs mount                 scan partition 1 and mount CASSAFS at /
vfs unmount               remove the mount (refused while handles are open)
vfs info                  mount, volume, node/handle and I/O counters
vfs ls [path]             stable readdir; a file is refused
vfs stat <path>           type, inode, parent, size and mode
vfs cat <path>            sequential read to EOF, with byte count and CRC32C
vfs read <path> <off> <n> range read, clamped at EOF
vfs selftest              namespace, handles, EOF, readdir and access checks
vfs viz [seconds]         live dashboard, if a framebuffer is present
```

## Failure modes

The kernel-side self-test reports each check explicitly. The QEMU harness additionally proves
three refusals: no block device, a CASSAFS volume with a damaged data record (mount refused
with `CRC32C mismatch`, no table entry), and a damaged B superblock (A/B fallback, then read).
The test fails if any mount, read, directory count or CRC diverges across an unmount/remount
and a soft reboot.

## Limits

- Read-only: no create, write, truncate, rename, unlink or `fsync`; the write path and recovery
  journal are phase 43.
- One reader per handle, no concurrent handle-table locking or shared file offsets. The shell is
  single-threaded, and the VFS tables are kernel-owned.
- CASSAFS on partition 1 only; the mount table supports other points and backends, but no other
  backend exists.
- The phase-41 reference format caps a volume at 128 inodes/records and eight extents per file.
  The PLAN's 100k-file tree and 2%-of-page-cache random-read target therefore cannot be met by
  this pass; a page cache is phase 44 and larger format bounds are a later scale-out change.
- No checkpoint redundancy or journal replay yet; a damaged checkpoint or data record is
  reported and refused rather than repaired.
