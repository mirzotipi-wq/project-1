# CASSAFS format 1

CASSAFS is the crash-safe, log-structured filesystem Cassa is building for till workloads.
Phase 41 defines the on-disk format, the reference formatter, the verifier and the read-only
dump/cat path. Mounting and ordinary writes arrive in phases 42–43.

The authoritative implementation is `src/lib/cassafs.zig`; the kernel adapter is
`src/kernel/cassafs.zig`; the host reference reader is `tools/cassafs.zig`. All three use the
same codec, CRC32C and verifier.

## Physical layout

- Block size: **4096 bytes**.
- Volume bounds: 8 … 262,144 blocks (32 MiB … 1 GiB in the phase-41 implementation).
- Superblock A: block 0. Superblock B: block 1. Each is 512 bytes inside a zeroed 4 KiB block.
- Append-only log: starts at block 2. A record occupies one header block followed by
  `ceil(payload_len / 4096)` payload blocks.
- The penultimate log record is the **free-space map**; the last is the **checkpoint**.
- The free map covers every block in the volume. Phase 41 records are appended, so the map is
  an exact used prefix followed by free blocks. A future allocator can reuse the same bitmap.

The format command writes a demo tree `root -> catalog -> products.db` and
`root -> receipts -> WELCOME.TXT`; the empty format writes only the root inode.

## Superblock

Both A and B hold the same 512-byte structure. On format, A is generation 1 and B is generation 2.
The scanner decodes both, rejects either independently on magic/version/geometry/CRC failure,
and chooses the valid copy with the higher generation. A damaged copy is reported as a
fallback, not hidden.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `CSAS` (little-endian `0x53415343`) |
| 4 | 2 | format version = 1 |
| 6 | 2 | superblock size = 512 |
| 8 | 8 | generation |
| 16 | 4 | checkpoint block |
| 20 | 4 | block size = 4096 |
| 24 | 4 | total blocks |
| 28 | 4 | log head (first free block) |
| 32 | 8 | root inode number |
| 40 | 4 | free blocks |
| 44 | 4 | inode count |
| 48 | 8 | created wall-clock seconds |
| 56 | 8 | feature word (bit 0 = append-only log) |
| 64 | 4 | compatible features |
| 68 | 4 | incompatible features (unknown bits are refused) |
| 72 | 16 | volume UUID |
| 88 | 32 | label, NUL-padded |
| 120 | 8 | checkpoint sequence |
| 128 | 4 | checkpoint payload CRC32C |
| 508 | 4 | superblock CRC32C over bytes 0..507 |

The superblock is self-describing: a reader learns the block size, volume size, log head and
checkpoint location without trusting any external metadata.

## Record header and CRC32C

Every record begins with a 64-byte little-endian header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `CSAF` (`0x46415343`) |
| 4 | 1 | record version = 1 |
| 5 | 1 | kind: 1 inode, 2 data, 3 free map, 4 checkpoint |
| 6 | 2 | flags |
| 8 | 8 | sequence, contiguous from 1 |
| 16 | 4 | payload length in bytes |
| 20 | 4 | total blocks including this header |
| 24 | 4 | payload CRC32C |
| 32 | 8 | timestamp seconds |
| 60 | 4 | header CRC32C over bytes 0..59 |

CRC32C is the Castagnoli polynomial (reflected `0x82F63B78`), not CRC32. The payload CRC covers
exactly `payload_len` bytes, never padding. The scanner verifies the header CRC while reading
the header and the payload CRC after assembling every payload block, so a torn or bit-flipped
record is a typed failure before any inode or extent is trusted.

The scanner also enforces:

- sequence numbers are exactly `1..N` with no gap or reorder;
- `total_blocks == 1 + ceil(payload_len / 4096)` and every record stays below the log head;
- exactly one free-map record and one checkpoint record, in that order, at the end;
- the checkpoint's free-map block/sequence, log head, total blocks, inode counts and data
  bytes agree with the scanned log;
- the free-map bitmap marks exactly `[0, log_head)` used and the rest free.

## Inodes

An inode payload is **268 bytes**:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | inode payload version = 1 |
| 1 | 1 | kind: 1 directory (`inode`), 2 file (`data`) |
| 2 | 1 | name length, 0..31 (0 only for root) |
| 3 | 1 | extent count, 0..8 |
| 4 | 8 | inode number, unique and below `next_ino` |
| 12 | 8 | parent inode (0 only for root) |
| 20 | 8 | file size in bytes |
| 28 | 4 | data CRC32C over the file's bytes |
| 32 | 8 | modification time |
| 40 | 2 | POSIX mode (040755 directory, 0100644 file) |
| 44 | 32 | name, NUL-padded |
| 76 | 192 | 8 extents × 24 bytes |

Every non-root inode has a parent that is a directory, and every child name is unique within
its parent. The scanner walks each inode to the root, detects cycles and depth overflow, and
rejects a parent pointer that is not a directory or a sibling-name duplicate. This is the inode
tree phase 42 mounts through the VFS.

## Extents

Each extent is 24 bytes:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | logical offset in the file |
| 8 | 4 | physical block containing the data |
| 12 | 2 | byte offset inside that block |
| 16 | 4 | length in bytes |

Extents are ordered and contiguous in logical space: the first starts at 0, each next starts
where the previous ended, and the final end equals the inode's size. The scanner checks every
extent against a data record's payload range, computes the file CRC from the extents in order
and compares it with the inode's `data_crc`. A 16 KiB data chunk becomes one extent; the phase-42
VFS reads a file by walking these records with no copy layer.

## Free-space map and checkpoint

The free-map payload starts with `total_blocks` and `log_head` (both u32), followed by a bitmap
with one bit per volume block, LSB-first. Its own record and the checkpoint's blocks are marked
used. The checkpoint payload (120 bytes) records:

`version`, `root_ino`, `next_ino`, `inode_count`, `dir_count`, `file_count`, `record_count`,
`log_head`, `total_blocks`, `used_blocks`, `free_blocks`, `free_map_block`, `free_map_seq`,
`data_bytes`, `uuid` and `label`.

The checkpoint is the atomic commit point: a superblock points at one checkpoint, and the
checkpoint points at the free map. Because both the checkpoint and free-map records carry their
own CRC32C, a reader can prove the pointers and allocation state before exposing a file.

## Versioning

- Format version is `1`. A different version is refused.
- Record version is independent; unknown record versions are refused.
- The incompatible feature word must have no bits outside the currently understood set.
- Compatible features may be added without changing the reader contract.
- The UUID identifies a volume independently of its label and generation.

## Commands

Kernel shell:

```
cassafs info                      geometry, A/B state, log, tree, free map
cassafs format [empty|demo]       write the format; refuses a live FAT journal
cassafs demo                      alias for format demo
cassafs verify                    full CRC/tree/extent/free-map verification
cassafs dump                      records, inode tree, extents, free-space map
cassafs cat <path>                read a file through extents and verify its CRC
cassafs viz [seconds]             live panel dashboard
```

Host tool (same library, image outside the guest):

```
zig-out/bin/cassafs info   --image disk.img --partition 1
zig-out/bin/cassafs verify --image disk.img --partition 1
zig-out/bin/cassafs dump   --image disk.img --partition 1
zig-out/bin/cassafs cat    --image disk.img --partition 1 --path /catalog/products.db
```

`--offset BYTES` reads a volume at a raw byte offset instead of an MBR partition. The reference
tool only reads; the kernel is the only writer in phase 41.

## Phase 41 limits

- The log is append-only; there is no garbage collection, in-place update or atomic rename yet
  (phase 43). Formatting rewrites the volume.
- `cassafs cat` is a read-only diagnostic path. Phase 42 mounts the same tree through the VFS
  (`vfs cat`, `vfs ls`, `vfs stat`); writes and recovery are phase 43.
- Eight extents and 128 inodes/records are the phase-41 reference bounds; they are compile-time
  constants so the formatter's memory use is bounded on a till.
- The power journal is still FAT-backed on partition 1. Formatting a volume while that journal
  is mounted is refused rather than invalidating it; phase 43 integrates the journal with
  CASSAFS.
- A/B fallback covers a damaged **superblock**. A damaged checkpoint is reported as a failure;
  redundant checkpoints are part of phase 43's recovery work.
