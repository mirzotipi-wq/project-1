# CassaOS transactional sale log (phase 48)

Phase 48 turns a sale into a durable, idempotent record. The log is the commit
point: a sale exists when one complete 512-byte record is present in the
committed prefix of `/catalog/sales.log`, and it does not exist when that record
is absent or the committed prefix cannot be validated. Success is printed only
after the append has crossed the VFS/CASSAFS page cache, been flushed, and been
read back.

The pure record model is `src/lib/sale_log.zig`; the shell and storage front end
is `src/kernel/sales.zig`. There is no allocator, no libc, no second write path
and no parallel import path. Prices and tax classes come from the phase-47
retail snapshot, which was itself imported through the phase-45 FAT32/VFS
reader.

## Why this is write-ahead ordering

A completed sale has no second in-memory state that could be committed before
the log. The log record *is* the sale. The ordering is therefore:

1. validate the catalog, terminal, quantity and price from the retail snapshot;
2. derive the line totals and tax in the kernel, never from a shell-supplied price;
3. append one record at the committed file end;
4. flush every dirty CASSAFS page;
5. read the file back through the VFS and verify the record chain;
6. only then print `sales commit` and a receipt number.

The immutable 64-byte header carries no record count. The number of records is
derived from the committed file length, so a partial append cannot make a stale
header claim a sale that is not on disk. Each record also carries the previous
record's CRC32C and the global sequence, so replay rejects a gap or a changed
predecessor instead of silently relabelling history.

## File and record layout

`/catalog/sales.log` is a header followed by zero to sixteen 512-byte records.
Capacity is **8,256 bytes**. The header is:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `CSLOG48\0` |
| 8 | 2 | version 1 |
| 10 | 2 | record size 512 |
| 12 | 2 | capacity 16 |
| 14 | 46 | zero |
| 60 | 4 | header CRC32C over bytes 0..60 |

Each record is:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `CSTXN48\0` |
| 8 | 2 | version 1 |
| 10 | 2 | record size 512 |
| 12 | 2 | line count 1..4 |
| 14 | 2 | flags (bit 0 committed, bit 1 closed) |
| 16 | 8 | global sequence, starts at 1, contiguous |
| 24 | 8 | terminal transaction ID (idempotency key half) |
| 32 | 4 | terminal identity ID (idempotency key half) |
| 36 | 4 | terminal-local sequence, starts at 1 per terminal |
| 40 | 4 | receipt number, equal to the global sequence |
| 48 | 8 | subtotal cents |
| 56 | 8 | tax cents |
| 64 | 8 | total cents |
| 72 | 8 | tender cents |
| 80 | 8 | timestamp (`uptimeMs` for now) |
| 88 | 4 | previous record CRC32C, 0 for the first |
| 96 | 256 | four 64-byte lines |
| 508 | 4 | record CRC32C over bytes 0..508 |

A line is `code[16]`, `code_len` at 16, `qty` (i32) at 20, `unit_price` (i64)
at 24, `tax` (i64) at 32 and `total` (i64) at 40. Unused line slots are zero and
are not decoded; a decoded line count outside 1..4 is refused.

## Idempotency and conflict

The key is `(terminal_id, txn_id)`, not the receipt number and not the arrival
time. On every sell the committed prefix is loaded first:

- the same key with an identical payload returns the existing sequence and
  **does not append**;
- the same key with a different line, quantity, total or tender returns
  `Conflict` and does not append;
- a new key gets the next global sequence and the terminal's next local
  sequence.

`time` and the terminal-local sequence are not part of payload equality: a
retry naturally has a later uptime and a later local sequence, but it is still
the same sale. Replaying the file never applies a sale twice.

## Shell surface

```
sales init                  create the empty header (refuses if it exists)
sales sell <terminal> <txn-id> <sku> <qty> [<sku> <qty> ...]
sales report                committed count, units, totals, terminals, chain CRC
sales verify                validate the chain and re-check prices/tax against retail
sales replay                print every committed transaction in sequence order
sales corrupt               test hook: flip one byte in the last record
```

`sales verify` is the durability check that matters. If the retail snapshot is
missing or a stored price/tax no longer matches its catalog source, it refuses
with a named reason rather than printing a plausible total. `sales replay`
refuses the same damaged chain.

## Bounds and refusal rules

- At most **16 transactions per file**, **4 lines per transaction**, **16-byte
  codes**, **512-byte records**, **8,256-byte file**. A full log returns `Full`;
  it never overwrites or evicts a sale.
- All money is `i64` cents bounded to `1e12` per amount and `8e12` per
  transaction total; arithmetic uses checked add/multiply. An overflow is
  `BadAmount`, not a wrapped total.
- The file length must be exactly `64 + n*512` for `n <= 16`. A partial tail
  fails with `Truncated`; it is not guessed at, truncated or replayed.
- The header CRC, every record CRC and every `prev_crc` must match. A bad byte
  fails with `RecordCorrupt`, `Corrupt` or `BadChain`.
- Global sequences must be `1..n`; terminal-local sequences must be `1..m` per
  terminal; a duplicate key inside the committed prefix is `DuplicateKey`.
- A missing retail snapshot, terminal, SKU or tax class is a refusal. The shell
  cannot pass a price; it passes only terminal, transaction ID, SKU and quantity.

## Evidence

`python3 tools/qemu_sales48_test.py` boots the real aarch64 image on a
two-partition disk. It first proves the phase-45 and phase-47 evidence on the
same disk:

```
10k FAT32 import: 10000 rows, 220021 B, CRC32C 0x8678e4e7
phase-47 retail evidence: 239 records PASS
sale log initialized: 64 B header, 16-record bound
```

It then commits three sales:

```
sales commit: seq 1, terminal T1 (id 33, local 1), txn 5001, receipt 1
sales commit: 2 line(s), subtotal 680, tax 0, total 680 cents, flush + reread PASS
sales commit: 512 B record at offset 64, 576 B log, next sequence 2
sales commit: seq 2, terminal T2 (id 34, local 1), txn 5002, receipt 2
sales commit: 1 line(s), subtotal 150, tax 0, total 150 cents, flush + reread PASS
sales commit: 512 B record at offset 576, 1088 B log, next sequence 3
sales commit: seq 3, terminal T1 (id 33, local 2), txn 5003, receipt 3
sales commit: 2 line(s), subtotal 725, tax 0, total 725 cents, flush + reread PASS
sales commit: 512 B record at offset 1088, 1600 B log, next sequence 4
```

The exact retry and changed-payload checks:

```
duplicate terminal T1 txn 5001 at sequence 1; no append, no double count
sales sell : REFUSED: Conflict
sales sell : REFUSED: UnknownTerminal
sales sell : REFUSED: CatalogItemMissing
```

The replayable day:

```
sales report : 3 transaction(s), 6 unit(s), subtotal 1555, tax 0, total 1555 cents
sales chain : seq 1..3, chain CRC 0x01136c91
sales terminals: 2 distinct
sales terminal : T1 (id 33) 2 txn(s), total 1405 cents
sales terminal : T2 (id 34) 1 txn(s), total 150 cents
sales verify : PASS, 3 transaction(s), chain CRC 0x01136c91, 2 terminal(s)
sales replay : [seq 1] T1 txn 5001 receipt 1 lines 2 total 680
sales replay : PASS, 3 transaction(s)
```

The observed chain CRC was `0x01136c91` in this run. It is not a fixed
documentation number: `time` is part of each record, so it changes between boots
even when every sale is identical.

Durability and refusal are then proved across the real boundaries:

1. `vfs cache flush` then `vfs cache drop`; `sales verify` and `sales report`
   reload the same three transactions from disk;
2. `vfs unmount usb`, `vfs unmount /`, remount `/`; the same verify/report pass;
3. soft reboot, mount `/`; the same verify/report pass;
4. the same `T1/5001` retry after reboot prints the duplicate line and
   `sales verify` remains at three transactions;
5. `sales corrupt` flips one byte in the last record; `sales verify` prints
   `sales verify : REFUSED: RecordCorrupt`;
6. a sell attempt over the damaged log prints
   `sales sell : REFUSED: RecordCorrupt`; it does not append;
7. `vfs cache drop`, `vfs unmount /` + remount, and another soft reboot each
   preserve the refusal;
8. clean shutdown after the corruption test.

The observed terminal IDs are snapshot-assigned (33 and 34 in this run); the
record key is the ID, not the code.

## Host tests

`zig build test --summary all` reports **248/248**, up from 243. The five new
tests cover:

- record/header encode and decode with the sequence and CRC chain;
- exact duplicate key no-op and changed-payload `Conflict`;
- a corrupted record, broken predecessor CRC and a sequence gap;
- terminal-local sequence enforcement and bounded capacity;
- a non-zero tax record, malformed totals, empty lines and out-of-domain amounts.

`zig build` is clean.

## Regression sweep

All ten prior harnesses were run unchanged, one at a time, from this tree. The
observations were:

| Harness | Observed |
|---|---|
| `qemu_input_test.py` | barcode `4006381333931`, 13 characters, suffix-to-queue delivery asserted at 0 ms; no-input boot PASS |
| `qemu_usb_test.py` | **4/4** scenarios (HID, hub, FTDI serial, no-controller) |
| `qemu_power_test.py` | thermal **2374 → 4039 ms (1.70x)**, **2389 → 3847 ms (1.61x)** and **2361 → 3870 ms (1.64x)** across runs. The harness asserts throttling, not a fixed ratio; the prior 1.69x sample is inside this host-timing spread. Watchdog/poweroff/brownout/fallback PASS. |
| `qemu_cassafs_test.py` | format/verify/read-back/reboot/fallback/corruption/absence PASS |
| `qemu_vfs_test.py` | mount/read/refusals/fallback/reboot PASS |
| `qemu_vfs_write_test.py` | 7-byte CRC `0xdb03992b`; 8-byte CRC `0x394478f0`; out-of-space and corruption PASS |
| `qemu_page_cache_test.py` | 23/64 pages, 79% hit (19/5), 21 hit/6 miss cold, 22 readahead reads, 37 ms max sale commit, 64/64 pages, 344 evictions, 88 writebacks, 20 flushes; harness-asserted sale CRC `0x12b569fa`; cache drop/remount/host verify PASS |
| `qemu_fat32_test.py` | **10,000 rows / 220,021 B / max line 21 / CRC32C `0x8678e4e7`**, read-only/remount/reboot/corrupt-chain PASS |
| `qemu_vfs46_test.py` | three-backend paths, tmpfs/chmod/locks/watches/remount PASS; FAT32 reimport `0x8678e4e7` |
| `qemu_retail_test.py` | 239 records, 64 receipts, 128 lines, 160 units, subtotal 42,020, cash 16,540, variance +50, top `100001 Croissant`; duplicate import refused; cache drop/remount/reboot intact; corrupt record refused `RecordCorrupt` |

The page-cache harness asserts the 33-byte sale file's size and CRC rather than
printing the CRC, so `0x12b569fa` is a checked value from the harness, not a line
in the transcript.

## Limits (honest)

- **No rotation or compaction.** Sixteen transactions, four lines and 8,256
  bytes are the whole log. A busy till fills it and receives `Full`; phase 49+
  storage work must add rotation or a larger indexed log.
- **Single writer.** The shell is the only writer, like the rest of the storage
  stack. There is no concurrent till process, lock or multi-writer protocol yet.
- **No tail repair.** A crash that leaves a non-record-aligned tail makes the
  entire log refuse as `Truncated`. That is deliberate: refusing beats silently
  discarding a possibly committed sale, but it means an operator needs recovery
  tooling that does not exist yet.
- **CRC32C is integrity, not authentication.** It catches torn, corrupted and
  contradictory data; it does not prevent an adversary from rewriting a record
  and its chain. There is no signature or MAC.
- **Catalog prices are resolved at commit and verify time.** A later retail
  price/tax change makes an older sale fail `verify` with `PriceMismatch` or
  `TaxMismatch`; the log does not store a historical price table. The seeded demo
  products use the `ZERO` tax class, so every observed sale had tax 0; the
  VAT20/VAT5 paths exist in the retail model and host tests but were not used in
  this booted evidence.
- **Tender is exact.** A sale records one tender equal to the total; there is no
  split tender, change calculation or card settlement in this phase.
- **Terminal identity is an ID plus local sequence.** The terminal code is
  resolved from the retail snapshot for display; the record does not duplicate
  the code.
- **Time is uptime.** The timestamp is `uptimeMs`, not wall-clock time; wall
  clock/terminal time synchronization is later work. It does not participate in
  idempotency.
- **No end-to-end network path.** The idempotency guarantee is local to one
  terminal's key. A real network retry service and cross-terminal deduplication
  are future work.
- **Test hook.** `sales corrupt` is a deliberate fault injector, not a
  production command; it is compiled in for the booted harness like the earlier
  phases' corruption hooks.
