# CassaOS snapshots and recovery (phase 50)

Phase 50 makes a bad configuration recoverable without adding a second storage
system. Configuration and snapshots are ordinary files under `/catalog`; every
write goes through the existing VFS → CASSAFS page cache → partition view →
virtio-blk path from phases 41–49. The pure format/snapshot model is
`src/lib/recovery.zig`; the shell-facing persistence and policy are
`src/kernel/recovery.zig`.

The done criterion is narrow and is the one proved here: **a corrupted
configuration rolls back to the last known-good snapshot in one command**.

## Files and formats

The configuration is `/catalog/config.cfg`, a fixed 128-byte record:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `CFG050\0\0` |
| 8 | 2 | version 1 |
| 10 | 4 | generation |
| 14 | 4 | terminal ID |
| 18 | 1 | store-name length (1..32) |
| 19 | 1 | footer length (1..64) |
| 20 | 1 | tax mode (0 inclusive, 1 exclusive, 2 zero) |
| 21 | 2 | auto-lock seconds (0..3600) |
| 24 | 32 | store name, printable ASCII |
| 56 | 64 | receipt footer, printable ASCII |
| 124 | 4 | CRC32C over bytes 0..124 |

`/catalog/config.snap` is a fixed 544-byte set:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | magic `SNP050\0\0` |
| 8 | 2 | version 1 |
| 10 | 2 | slot size (128) |
| 12 | 1 | slot count (4) |
| 13 | 1 | next slot |
| 14 | 4 | snapshot generation |
| 18 | 10 | zero |
| 28 | 4 | header CRC32C over bytes 0..28 |
| 32 | 4 × 128 | four immutable configuration copies |

The four slots are a bounded FIFO. A new snapshot writes the next slot; the
fifth snapshot reuses slot 0. It never grows the file or allocates. Each slot
is a complete encoded configuration with its own CRC, so one bad slot is not
accepted; the header CRC makes a damaged set unambiguous. `latest` chooses the
valid slot with the highest configuration generation and refuses if no slot is
valid.

## Copy-before-write, not a second journal

`recovery set` parses and validates the requested change first, then:

1. copies the **current** configuration into the next snapshot slot;
2. writes the new 128-byte generation through the VFS;
3. flushes every dirty CASSAFS page;
4. reads the file back and decodes it before printing success.

That is copy-on-write at the configuration-record level: the previous record is
copied to an immutable slot before the live record is replaced. It is not a
block-level filesystem snapshot; CASSAFS remains the append-only log-structured
store underneath, and there is no second journal or block cache. If snapshot
saving fails, the live configuration is not changed.

The automatic snapshot is the pre-change state, which is the last known-good
state. `recovery snapshot` explicitly snapshots the current state, which lets an
operator mark a known-good configuration before a risky batch of changes.

## Commands

```
recovery init                 create config and the first snapshot
recovery status               config values, slot count, latest, audit size
recovery verify               decode and CRC-check the live config
recovery set <key> <value>    store|footer|terminal|tax|autolock
recovery snapshot             copy the current config into a slot
recovery rollback             write the newest valid snapshot back
recovery factory-reset [preserve]
recovery bundle               write /catalog/support.bundle
recovery corrupt config       test hook: flip one config payload byte
recovery corrupt snapshot     test hook: flip the snapshot header CRC
```

`recovery set` accepts raw printable ASCII values after the key, so
`recovery set footer Receipt footer` stores the two words. Quotes are not a
shell quoting mechanism.

### Refusals

Every failure is named rather than treated as success:

- a corrupted config is `recovery verify : REFUSED: BadCrc`;
- a corrupt snapshot header is `recovery rollback : REFUSED: BadCrc`;
- an unknown field is `REFUSED: BadKey`;
- an out-of-range value is `REFUSED: BadValue`;
- an unknown factory-reset policy is `REFUSED: UnsupportedPolicy`;
- missing files are `REFUSED: NotFound`;
- a snapshot set with no valid slot is `REFUSED: NoSnapshot`.

## Factory reset and audit

The audit trail is the existing phase-48 transactional sale log,
`/catalog/sales.log`. That log is already append-only, CRC-chained and idempotent;
phase 50 does not create a parallel audit mechanism.

`recovery factory-reset preserve` resets the live configuration to generation 1
and resets the snapshot file to a single default snapshot. It records the sale
log's size before and after and refuses with `AuditChanged` if it moved. It never
writes, truncates or deletes the sale log. This is the policy that is implemented.

`recovery factory-reset wipe` is deliberately **refused** with
`UnsupportedPolicy`: there is no safe delete/truncate path yet, and silently
leaving the audit intact while claiming a wipe would be dishonest.

## Support bundle

`recovery bundle` writes `/catalog/support.bundle`, a fixed-header binary
document containing:

- header magic `CSBND50\0`, version, flags;
- the raw 128-byte config and its validity flag;
- the raw 544-byte snapshot set and its validity flag;
- the committed sale-log bytes used as the audit excerpt;
- the phase-49 storage-health state, retry/recovered/unrecovered counters,
  bad-range count, media reads/writes/flushes;
- a CRC32C over the header and payload.

The bundle is written through the VFS, flushed, read back byte for byte, and its
size is cross-checked with `vfs stat`. It is a local export file; there is no
network or removable-media upload yet.

## Booted evidence

`python3 tools/qemu_recovery50_test.py` boots the real aarch64 image on the
phase-45/47/48/49 two-partition disk. It first proves the layers underneath:

```
10k FAT32 import: 10000 rows, 220021 B, CRC32C 0x8678e4e7
retail seed   : 239 record(s), 64 receipt(s), 128 line(s)
sales commit: seq 1, terminal T1
sales verify : PASS, 1 transaction(s)
blk health      : healthy, warnings 0, retries 0, recovered 0, unrecovered 0, bad blocks 0
blk fsck    : PASS, 37 record(s), 7 inode(s), 4 file(s), 62214 data byte(s), 16284 free block(s)
```

It then creates and changes configuration:

```
recovery init : /catalog/config.cfg, 128 byte(s), generation 1
recovery init : /catalog/config.snap, snapshot slot 0, 4-slot bound
recovery config : /catalog/config.cfg, 128 byte(s), generation 1, terminal 1
recovery snaps  : 1/4 valid, latest generation 1 in slot 0, next slot 1
recovery snapshot : generation 3 in slot 3, flush + reread PASS
recovery verify : PASS, generation 3, terminal 1, store "North Till", tax inclusive, autolock 60s
```

The live config is corrupted through the VFS and the one-command recovery is
proved:

```
recovery verify : REFUSED: BadCrc
recovery rollback : restored generation 3 from slot 3, store "North Till"
recovery rollback : flush + reread PASS
recovery verify : PASS, generation 3, ... store "North Till"
```

The same config and the one-sale audit log survive cache flush/drop,
unmount/remount and a soft reboot. After reboot:

```
recovery snaps  : 4/4 valid, latest generation 3 in slot 3, next slot 0
recovery rollback : restored generation 3 from slot 3, store "North Till"
```

The support bundle observed in this run:

```
recovery bundle : /catalog/support.bundle, 1312 byte(s), CRC32C 0x66d093ce
recovery bundle : config 128 B (valid), snapshot 544 B (valid), audit 576 B, health healthy
vfs stat    : /catalog/support.bundle
support bundle: 1312 B, 0x66d093ce, stat size matches
```

Factory reset with the preserve policy:

```
recovery reset : PASS, generation 1, 128-byte config, snapshot reset
recovery reset : audit preserved: /catalog/sales.log, 576 byte(s)
recovery verify : PASS, generation 1, ... store "Cassa Store"
sales verify : PASS, 1 transaction(s)
recovery reset : REFUSED: UnsupportedPolicy
```

Finally, a deliberately corrupted snapshot header is refused rather than
falling back to an invented slot:

```
recovery corrupt : flipped the snapshot header CRC; run 'recovery rollback'
recovery rollback : REFUSED: BadCrc
```

A clean shutdown follows.

## Host tests

`zig build test --summary all` reports **256/256**, up from 252. The four new
tests in `src/lib/recovery.zig` cover:

- config round-trip and validation bounds for every mutable field;
- config magic, version and CRC refusals as distinct errors;
- bounded four-slot rotation, highest-generation selection and overwrite;
- empty snapshot sets, slot round-trip and a corrupted header refusal.

`zig build` is clean.

## Regression sweep

All twelve prior harnesses were run unchanged, one at a time, from this tree.
The observations were:

| Harness | Observed |
|---|---|
| `qemu_input_test.py` | `4006381333931 (13 chars, 258–260 ms burst)`; suffix-to-queue delivery `0–1 ms`; no-input boot PASS |
| `qemu_usb_test.py` | **4/4** scenarios: HID, hub, FTDI serial, no-controller |
| `qemu_power_test.py` | normal 2365–2380 ms → critical 3866–3952 ms (**1.63–1.67x**; final validation 1.63x); brownout, fallback and dashboard PASS. The harness asserts throttling, not a fixed ratio. |
| `qemu_cassafs_test.py` | format/verify/read-back/reboot/fallback/corruption/absence PASS |
| `qemu_vfs_test.py` | mount/read/refusals/fallback/reboot PASS |
| `qemu_vfs_write_test.py` | write/overwrite, out-of-space and corruption refusal PASS |
| `qemu_page_cache_test.py` | 23/64 pages, 79% hit; 21 hit/6 miss cold; 22 readahead; max sale commit **27–31 ms**/100 ms (final validation 28 ms); 64/64 pages, 344 evictions, 88 writebacks, 20 flushes; harness-asserted sale CRC `0x12b569fa`; drop/remount/host verify PASS |
| `qemu_fat32_test.py` | **10,000 rows / 220,021 B / max line 21 / CRC32C `0x8678e4e7`**; read-only, remount, reboot, corrupt-chain and one-partition cases PASS |
| `qemu_vfs46_test.py` | three-backend paths, tmpfs, chmod, locks, watches, remount PASS |
| `qemu_retail_test.py` | 239 records, 64 receipts, 128 lines; cache drop/remount/reboot and `RecordCorrupt` refusal PASS |
| `qemu_sales48_test.py` | 3 transactions / 6 units / 1,555 cents / 2 terminals; `sales verify : PASS, 3 transaction(s)`; duplicate/no-op, `Conflict` and `RecordCorrupt` PASS |
| `qemu_storage49_test.py` | transient read/flush recovery, persistent `REFUSED: Io` then `REFUSED: BadBlock`, scrub recovery and raw `REFUSED: BadCrc` PASS |

The page-cache harness asserts the 33-byte sale file's `0x12b569fa` CRC rather
than printing it, so that is a checked value, not a transcript line.

The phase-48 sale-chain CRC is timestamp-dependent because each committed record
carries the boot's uptime. Validation boots printed `0x0b36f980`, `0xe3f9638e`,
`0xef7c61cc` and `0x7b9e804f`; the authoring run printed `0x5d5b8d8b`. The harness asserts
chain validity and `PASS`, not a fixed CRC. The support bundle was `1312 B` /
`0x66d093ce` in those runs; the harness checks its size, readback and internal
CRC rather than hard-coding the printed value.

## Limits (honest)

- **Record-level copy-on-write, not a block filesystem snapshot.** Snapshots
  copy the 128-byte configuration, not the CASSAFS image, retail database or sale
  log. There is no snapshot of arbitrary files yet.
- **Four slots and FIFO reuse.** The fifth snapshot overwrites the oldest slot.
  There is no retention policy, timestamp or archive.
- **Two files are not one atomic transaction.** Config and snapshot are written
  and flushed separately. A crash between them can leave the new config with the
  previous snapshot (rollback still returns the old state) or a snapshot with the
  old config (never reported as a successful change because the readback barrier
  is per command). There is no multi-file atomic commit.
- **Audit is the sale log, not a general event log.** Factory reset preserves
  `/catalog/sales.log`; it does not audit configuration changes themselves.
  `factory-reset wipe` is refused rather than silently leaving audit data behind.
- **Support bundle is local.** It is a CASSAFS file retrievable by the host
  reader; there is no network upload, removable FAT32 write or support service.
- **Raw values are printable ASCII and unquoted.** There is no escaping grammar;
  a value cannot contain control characters, and the parser does not accept
  quoted strings with spaces.
- **No background snapshot or automatic rollback.** Every operation is explicit
  and bounded; there is no watchpoint that rolls back a running app.
- **Corrupt snapshot slots fail closed.** A corrupted slot or header makes the
  set refuse; there is no attempt to guess bytes or silently choose a stale slot.
- **Test hooks are compiled in.** `recovery corrupt config|snapshot` intentionally
  damages the files for booted evidence, like the prior phases' corruption
  commands.
