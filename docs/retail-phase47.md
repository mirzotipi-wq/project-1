# CassaOS retail data model (phase 47)

Phase 47 is the durable schema a store needs for a trading day. It is pure Zig
logic in `src/lib/retail.zig`, with the persistence shell and VFS calls in
`src/kernel/retail.zig`. There is no allocator, no libc, no clock read inside the
model, and no second write path: `/catalog/retail.db` is created and written
through the normal VFS/CASSAFS `writeAt` path, and CSV rows enter through the
same bounded FAT32/VFS reader used by phase 45.

## Schema

Every record is 128 bytes and has one of thirteen kinds:

| Kind | What it carries |
|---|---|
| `product` | SKU/code, name, price (tax-exclusive cents), tax-class ref, supplier ref |
| `variant` | parent product, variant code/name, price override |
| `barcode` | barcode string, parent product or variant |
| `tax_class` | code/name, rate in basis points (0..10000) |
| `promotion` | code/name, percent or fixed-amount type, value, optional product scope |
| `user` | login code/name, role ref, optional terminal ref |
| `role` | code/name, permission bitmask |
| `receipt` | receipt number, shift/terminal/user refs, subtotal/tax/total/tender, line count, tender/status flags, time |
| `sale_line` | parent receipt, product/variant ref, promotion ref, quantity, unit price, discount, tax, line total, time |
| `shift` | shift code, terminal/user refs, opening cash, expected/counted cash, variance |
| `drawer` | drawer code, shift/terminal refs, opening, expected, counted, variance |
| `terminal` | terminal code/name and next receipt sequence value |
| `supplier` | supplier code/name |

The common record fields are `id`, `parent`, `ref1`, `ref2`, four signed
`i64` amounts, `i32` quantity, `u64` time, a 16-byte code and a 32-byte name.
All IDs are globally unique; codes are unique within a kind. Names and codes are
copied into fixed fields or the row is refused; they are never silently
truncated.

## Snapshot format and bounds

`/catalog/retail.db` is exactly **61,480 bytes**:

- 40-byte header: magic `CSRTL1`, version 1, record size 128, count/capacity,
  next ID, generation, update timestamp, header CRC32C;
- 480 records × 128 bytes;
- every record has its own CRC32C over the first 112 bytes, so a damaged record
  is identified rather than accepted as a valid day.

The 480-record bound leaves the live day at 239 records and still fits
comfortably under CASSAFS's 128 KiB file and 128 KiB file/extent limits. It is a
bounded model, not an unbounded product database: the phase-45 10k CSV is
validated by `vfs import` but cannot be imported into this snapshot (the retail
importer refuses at capacity with `NoSpace`).

## Import and atomicity

`src/lib/catalog_csv.zig` gained an optional `row_sink`; the existing validation
path and the 10,000-row VFS import are unchanged when no sink is installed.
`retail import <path>`:

1. loads the current snapshot (or starts an empty one);
2. copies it into a separate static staging database;
3. feeds the CSV to the parser one 4 KiB VFS read at a time;
4. copies each row into staging, refusing duplicate SKUs, malformed prices,
   overlong names/codes or a full model;
5. only after `finish()` succeeds and every row was accepted, replaces the
   current database and writes one complete 61,480-byte snapshot.

A rejected import never changes the committed snapshot. The booted harness
proves that with a second import of the same eight SKUs (`DuplicateCode`) while
the earlier 239-record day remains verifiable.

The real FAT32 fixture supplies both the phase-45 10,000-row catalog and an
eight-product vendor catalog. The same harness first re-imports the 10k file and
checks **10,000 rows / 220,021 bytes / max line 21 / CRC32C `0x8678e4e7`**, then
imports the vendor file and seeds the day.

## Deterministic demo day

`retail seedday` builds on imported products and is fixed for reproducibility:

- 8 products, 4 variants, 12 barcodes, 3 tax classes, 2 promotions;
- 3 roles, 4 users, 3 terminals, 3 shifts, 3 drawers, 2 suppliers;
- 64 receipts and 128 sale lines, 160 units;
- 3 closed shifts; one drawer per terminal.

The demo products use the `ZERO` tax class; `VAT20` (2000 bp) and `VAT5` (500 bp)
are present and host-tested, including a valid 20% receipt (1000 net, 200 tax,
1200 total). Prices are tax-exclusive. Promotions are real checks in `validate`:
a percentage promotion's discount is recomputed from its basis points, a fixed
promotion from its cents, and the line discount must match exactly.

Observed day totals from the booted guest:

```
sales         : 64 receipts, 128 lines, 160 units, subtotal 42020, tax 0, total 42020 cents
tender        : 42020 cents, cash 16540, change 0, drawer variance 50
top product   : 100001 Croissant, 24 units, 4320 cents
```

## Shell surface

```
retail init                 write an empty snapshot
retail import <csv-path>    stage and import through the VFS/FAT32 reader
retail seedday              build the deterministic 64-receipt day
retail report               counts and audited totals
retail verify               decode CRCs and recompute relations/totals/tax
retail corrupt              deliberately damage one record for refusal proof
```

`retail report` calls `validate` first. It refuses with a named error instead of
printing a plausible-looking day when a record CRC, reference, line total,
receipt total, tax amount or promotion discount is wrong.

## Durability evidence

`python3 tools/qemu_retail_test.py` boots the real aarch64 image and observes:

1. phase-45 FAT32 import still **10,000 / 220,021 B / max line 21 /
   `0x8678e4e7`**;
2. retail import of eight products from the real FAT32 LFN;
3. `retail seed : 239 record(s), 64 receipt(s), 128 line(s)`;
4. `retail verify : PASS, 239 records` and the exact report totals above;
5. duplicate import refused with `DuplicateCode`, day unchanged;
6. `vfs cache flush` then `vfs cache drop`; the day reloads from disk and the
   totals are unchanged;
7. `vfs unmount /` (which flushes the page cache) and remount; verify and totals
   unchanged;
8. soft reboot; verify and totals unchanged;
9. `retail corrupt` flips a byte in record 0; `retail verify` refuses with
   `RecordCorrupt` rather than reporting the damaged snapshot;
10. clean shutdown after the corruption test.

The harness adds no sleeps or raised timeout to mask a hang; it uses the
existing VM boot/command protocol.

## Regression sweep

All nine prior harnesses were re-run unchanged, one at a time, on the final
tree. The observed lines were:

| Harness | Observed |
|---|---|
| `qemu_input_test.py` | barcode `4006381333931`, **13 chars, 259 ms**, **0 ms** suffix-to-queue delivery; no-input boot PASS |
| `qemu_usb_test.py` | **4/4** scenarios (HID, hub, FTDI serial, no-controller) |
| `qemu_power_test.py` | thermal **2362 → 3995 ms (1.69x)**; watchdog/poweroff/brownout/fallback PASS |
| `qemu_cassafs_test.py` | format/verify/read-back/reboot/fallback/corruption/absence PASS |
| `qemu_vfs_test.py` | mount/read/refusals/fallback/reboot PASS |
| `qemu_vfs_write_test.py` | 7-byte CRC `0xdb03992b`; 8-byte CRC `0x394478f0`; out-of-space and corruption PASS |
| `qemu_page_cache_test.py` | 23/64 pages, 79% hit (19/5), 21/6 cold, 22 readahead reads, **37 ms** max sale commit, **64/64 pages**, 344 evictions, 88 writebacks, 20 flushes, asserted sale CRC `0x12b569fa` |
| `qemu_fat32_test.py` | **10,000 rows / 220,021 B / max line 21 / CRC32C `0x8678e4e7`**, read-only/remount/reboot/corrupt-chain PASS |
| `qemu_vfs46_test.py` | three-backend paths, tmpfs/chmod/locks/watches/remount PASS; FAT32 reimport `0x8678e4e7` |

## Tests

`zig build test --summary all` reports **243/243**, up from 233 (+10): eight
retail-model tests (tax integer math, day round-trip with exact counts and
totals, duplicate code, corrupted record CRC, mismatched tax class, a valid 20%
taxed receipt, capacity/name bounds, and overflow-domain refusal) and two CSV
row-sink tests (ordered delivery and rejection).

## Limits (honest)

- The model is a **snapshot**, not a transaction log. A save rewrites the whole
  file; phase 48's idempotent transaction log is the path to per-sale commits
  without exhausting CASSAFS's append-only record budget.
- One 61,480-byte file, 480 records, 16-byte codes and 32-byte names. Larger
  catalogs need a paged/indexed format; this phase deliberately refuses them.
- CASSAFS still has no `mkdir`, so the database lives in the demo volume's
  existing `/catalog` directory. No unlink/rename/truncate is used.
- The demo day is fixed (time base 2026-01-01, fixed receipts and terminal
  assignment) for reproducibility; live time and terminal sequence allocation
  are phase 48 work.
- User records carry role and terminal assignment, not a PIN/password
  credential or a cryptographic verifier. Authentication is a later layer.
- Receipts store a status/tender flag, not a full tender split (one tender per
  receipt in the demo). Discounts are line-scoped; no basket-level promotion
  engine, returns or exchanges yet.
- Drawers cover cash expected/counted/variance only; no card settlement or
  banking reconciliation. The VAT20/VAT5 records are supported by validation and
  the host tax test, while the deterministic seeded day is tax-free.
- The model is single-writer kernel state behind the shell, like the rest of
  the storage stack; no concurrent retail writers or user-space retail service
  exist yet.
