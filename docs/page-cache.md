# CASSAFS page cache (phase 44)

The page cache is a bounded 4 KiB LRU cache between the VFS/CASSAFS adapter and
the partition block view. It is implemented in `src/lib/page_cache.zig`; the
kernel mount in `src/kernel/cassafs.zig` owns the page array in `.bss`. The
on-disk format, scanner, CRC/tree/extent/free-map validation and write path are
unchanged.

## Geometry

| Item | Value |
|---|---:|
| Page size | 4 KiB |
| Resident pages | 64 (256 KiB) |
| Dirty-page bound | 16 (64 KiB) |
| Readahead | 4 pages after a miss |
| LRU clock | monotonic in-memory timestamp |

The cache presents a `cassafs.Device`, so every CASSAFS read and write — mount
scan, VFS reads, create, offset write and the post-commit rescan — passes
through it. The `cassafs info/verify/cat` diagnostics use their own uncached
view and always see the medium.

## Policy

- **Read hit:** copy the page, advance its LRU stamp, count the hit.
- **Read miss:** read exactly one block from the backing view, install it, copy
  the result, then prefetch up to four following blocks. A readahead error is
  counted and stops the prefetch run; it does not turn the requested read into a
  failure.
- **Write:** install or update a dirty page without reading the old block (the
  CASSAFS device writes whole 4 KiB blocks). The dirty bound is enforced by
  writing back the oldest dirty pages first.
- **Eviction:** evict the least-recently-used page. A dirty victim is written to
  the medium before its slot is reused. If that write fails, the page stays
  dirty and the operation returns the backing error.
- **Flush:** write back every dirty page in LRU order, then flush the block
  layer. A failed writeback retains the dirty page. CASSAFS calls this at its
  pre-superblock barrier and after both superblocks, so a commit cannot expose
  a checkpoint that is not durable.
- **Unmount:** the VFS refuses to unmount until the cache flush succeeds, then
  drops every resident page. Mount starts cold and rescans the medium.

## Accounting

`vfs cache` reports resident pages, pressure, dirty pages, hit rate, read/write
calls, evictions, writebacks, flushes and readahead reads/hits/errors.
`vfs info` and `vfs df` include the cache summary, and `vfs selftest` proves the
cache is bounded and accounts for VFS read traffic.

The sale-sized latency probe is `vfs cache bench`:

```text
vfs cache [stats|flush|drop|bench]
```

It opens `/receipts/sale44.tmp`, interleaves sixteen catalog reads (the two demo
files, 1,264 bytes in total across eight rounds) with eight 33-byte CASSAFS commits through the VFS,
and reports the maximum commit latency against the 100 ms budget. The POS
checkout path does not exist until a later phase; this is the storage commit a
sale will use, measured under an interleaved single-threaded read load, not a
concurrent checkout benchmark.

## Evidence

QEMU 8.2.2, `tools/qemu_page_cache_test.py`:

- mount scan: **23/64 pages resident, 35% pressure, 79% hit (19 hit / 5 miss)**;
- after a cache drop and cold range read: 21 hit / 6 miss, 77% hit,
  **22 cumulative readahead reads**, 0 readahead errors;
- benchmark: **8 sale-sized commits, 27–38 ms observed / 100 ms across verification runs**
  (the final verification run printed 38 ms), catalog
  **16 reads / 1,264 B**, 88% hit;
- pressure: **64/64 pages, 344 evictions, 88 writebacks, 20 flushes**, 0 dirty
  after the commits;
- committed sale: **33 bytes, CRC32C `0x12b569fa`**, identical after a cache
  drop, unmount/remount and the host verifier;
- screenshot: `docs/screenshots/phase44-cache.png`.

Host tests: **225/225** (`zig build test`), including six page-cache tests for
hit accounting, LRU, bounded write-back, readahead, writeback failure and
out-of-range refusal.

## Bug found and fixed

The first integration used 4 KiB locals for the backing read in both `read` and
`prefetch`. The CASSAFS scan already needs about 46 KiB; adding the cache pushed
the shell past its 64 KiB kernel stack. The scheduler caught the result as
`corrupt frame for thread 7 'wd'` after a mount. The fix is twofold: the cache
now owns one 4 KiB bounce page off the stack, and kernel thread stacks are 128
KiB. The phase-42/43/44 QEMU runs are stable after the fix.

## Limits

- One cache for the single mounted CASSAFS volume; there is no cross-mount
  coherence or invalidation protocol.
- No background writeback thread, no dirty-page throttling by process, and no
  concurrent access; the shell and VFS are single-threaded.
- No journal replay, garbage collection, checkpoint redundancy, atomic rename,
  unlink/truncate, `fsync`, or arbitrary power-cut recovery. These remain out.
- The format is still limited to 128 inodes/records, eight extents per file and
  128 KiB per file. A 64-page cache does not remove the larger-format work
  required for the 100k-file target.
- The 27–38 ms result is a QEMU demo workload; the real checkout remains a later
  phase, and “under 100 ms while a catalog import runs” is demonstrated by the
  interleaved storage probe rather than concurrent POS traffic.
