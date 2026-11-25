# CassaOS FAT32 reader (phase 45)

CassaOS imports a vendor catalog from a FAT32 stick without trusting it. The
reader is real on-disk FAT32 — BPB geometry, both FAT copies, LFN entries,
cluster chains, root and subdirectories — not a CSV dump with a FAT-like name.
It is **read-only** and validated at every boundary.

## Layers

- `src/kernel/fat32.zig` (phase 36) owns the format: BPB parsing, FAT
  arithmetic, directory iteration, LFN decoding, chain walking and consistency
  checking. Phase 45 adds `iterStartAt`, `findIn`, `readFileRange` and
  `validateFileChain`. The range reader is bounded and does not require the
  whole file to fit in a buffer; the old whole-file path is still available for
  small callers but is not used by catalog import.
- `src/lib/fat32_vfs.zig` is the read-only VFS adapter. FAT32 has no inode
  number, so a stable backend inode is the directory entry's `(sector, slot)`
  packed into a `u64`; root is inode 1. It caches up to 128 entry locations,
  resolves names case-insensitively, walks subdirectories by cluster, hides
  `.`/`..`, validates a file chain against its directory size, and returns
  `ReadOnly` for create/write.
- `src/lib/catalog_csv.zig` streams and validates the catalog schema. It keeps
  a 255-byte line buffer, never allocates, and accepts the exact header
  `sku,name,price_cents` followed by rows of three unquoted fields: numeric SKU,
  non-empty ASCII name, numeric price. A final row without a newline is
  accepted; a malformed header, row, empty data section or overlong line is
  refused at the byte that proves it.
- `src/kernel/vfs.zig` exposes `vfs mount usb`, `vfs unmount usb`, `vfs import`
  and the FAT32 lines in `vfs info`, `vfs selftest` and `vfs viz`.

## Mount and read-only policy

`vfs mount usb` reads the partition table, requires partition 2, wraps it in a
partition-offset block view, mounts the BPB geometry, reads the root directory
once to prove it is walkable, and only then registers `/media/usb` in the VFS.
A missing second partition, bad BPB, bad FAT marker or unreadable root directory
leaves the VFS table unchanged. The root CASSAFS mount remains independent.

The VFS checks `backend.writable` before it issues a handle, so a write/create
open on `/media/usb` fails with `this filesystem is read-only`; the adapter's
create/write callbacks also return `ReadOnly` as a second gate. No dirty page
cache exists for this backend because there is no write path.

## Import path

`vfs import /media/usb/store-catalog-2026.csv` opens a read handle, requests
4 KiB at a time, updates CRC32C over every byte, feeds the CSV parser, then
checks that the parsed byte count equals the directory size. It prints the row
count, line count, byte count, maximum line length, CRC32C and a PASS/refusal
verdict. Phase 47 adds an optional row sink to the parser and uses it to build
the retail snapshot in `docs/retail-phase47.md`; the default `vfs import` path
still only validates and prints the CRC.

The test fixture is a foreign-formatted 204,800-sector FAT32 volume:

- 512-byte sectors, one sector per cluster, two FATs, root cluster 2;
- 201,616 clusters, mounted as partition 2 at LBA 133120..337919;
- a 22-character LFN `store-catalog-2026.csv` (`STOREC~1CSV` short alias);
- 10,000 data rows plus header, **220,021 bytes**, maximum line 21,
  CRC32C **`0x8678e4e7`**.

The file is 3.3 times the old 64 KiB whole-file buffer, so the import exercises
the streaming chain reader rather than the legacy whole-file API.

## Evidence

`python3 tools/qemu_fat32_test.py` boots the real kernel on a two-partition
image and proves:

1. `vfs mount usb` reports `/media/usb <- fat32, read-only`; `vfs info` keeps the
   CASSAFS root counters and adds the FAT32 geometry.
2. `vfs ls /media/usb` decodes the 22-character LFN; `vfs stat` reports a
   read-only file with parent inode 1.
3. `vfs read ... 0 64` returns the CSV header; `vfs import` reads all 10,000
   rows / 220,021 bytes / CRC32C `0x8678e4e7`.
4. `vfs write` and `vfs create` on the FAT32 mount are refused as read-only.
5. After `vfs unmount usb` / `vfs mount usb`, and again after a soft reboot, the
   same import produces the same byte count and CRC.
6. A one-partition disk refuses the USB mount with `no FAT32 partition 2`.
7. A self-loop in the file's first FAT entry still leaves the volume mountable,
   but `vfs import` refuses with `integrity failure`; the CASSAFS root remains
   readable. No partial catalog is reported as imported.

Host tests (`zig build test`) are now **243/243**, including 10k-row parsing
across 7/31/4093-byte boundaries, malformed input, ordered/rejected row sinks,
FAT32 range reads and the read-only VFS mount.

## Limits

- There is no USB mass-storage class driver yet. Partition 2 stands in for the
  vendor stick so the FAT32 reader itself is exercised; the mount point and VFS
  interface are ready for a future block-device attachment.
- One FAT32 mount at a time, beside the one CASSAFS root. The phase-36 driver
  owns static scratch buffers.
- The LFN decoder maps non-ASCII UTF-16 units to `?`, caps names at 63 bytes and
  does not validate LFN checksums. `.`/`..` are hidden from the VFS.
- File size is the FAT 32-bit field. No write, `fsync`, permissions model,
  timestamp exposure, partition auto-discovery or hotplug.
- The CSV importer is deliberately strict. Its default `vfs import` path only
  validates; phase 47's optional sink builds the bounded 480-record retail
  snapshot. There is no 100k-item index or merge/update path yet.
