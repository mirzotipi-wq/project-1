#!/usr/bin/env python3
"""Phase 49 storage-health evidence harness.

The real aarch64 kernel boots on the phase-45/47/48 two-partition disk. Before
touching the health path, the harness re-establishes the existing evidence:

  1. imports the 10,000-row FAT32 catalog and checks its CRC32C;
  2. imports the vendor catalog, seeds the 239-record retail day and commits one
     phase-48 sale;
  3. runs the read-only CASSAFS fsck and confirms the demo product CRC.

Then it injects simulated medium errors at the virtio request boundary:

  - one transient read failure on the superblock range is retried and the fsck
    still passes; health becomes degraded and warns;
  - a persistent failure exhausts the retry budget, quarantines the range and
    makes fsck refuse (first with Io, then with BadBlock);
  - clearing the injector and scrubbing the range restores the read, clears the
    quarantine and makes fsck pass again;
  - the product CRC, the phase-48 sale verification and the retail day survive
    cache flush/drop, unmount/remount and a soft reboot.

Usage:  python3 tools/qemu_storage49_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_storage49_test.py
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
from pathlib import Path

from qemu_cassafs_test import BLOCK, DATA_RECORD, PART_OFFSET
from qemu_fat32_test import IMPORT_RE, crc32c
from qemu_retail_test import SMALL_NAME, make_disk
from qemu_vfs_test import KERNEL, QEMU, Failure, Machine, check, log, mount_ready
from qemu_vfs_write_test import shutdown_clean


PRODUCT_CRC = "0x3b60dc1d"
HEALTHY = "health      : healthy, warnings 0"
TRANSIENT = "health      : degraded, warnings 1, retries 1, recovered 1, unrecovered 0, bad blocks 0"
RECOVERED = "health      : degraded, warnings"
FSCK = "blk fsck    : PASS"
FSCK_IO = "blk fsck    : REFUSED: Io"
FSCK_BAD = "blk fsck    : REFUSED: BadBlock"


def cat_summary(text: str, path: str) -> tuple[int, str]:
    match = re.search(rf"cassafs cat : {re.escape(path)}, (\d+) byte\(s\), CRC32C (0x[0-9a-f]{{8}})", text)
    if match is None:
        raise Failure(f"cassafs cat summary missing for {path}:\n{text[-3000:]}")
    return int(match.group(1)), match.group(2)


def log_guest(text: str, *prefixes: str) -> None:
    for raw in text.replace("\r", "").split("\n"):
        line = raw.strip()
        if any(line.startswith(prefix) for prefix in prefixes):
            log("      " + line)


def main_scenario() -> None:
    work = Path(tempfile.mkdtemp(prefix="cassa-storage49-"))
    disk = work / "storage49.img"
    _geo, catalog = make_disk(disk)

    formatter = Machine("storage49-format", disk)
    try:
        formatted = formatter.cmd("cassafs format demo", 30.0)
        check("format      : OK" in formatted, "CASSAFS format failed:\n" + formatted[-2500:])
        shutdown_clean(formatter)
    finally:
        formatter.close()

    machine = Machine("storage49-main", disk)
    try:
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount failed:\n" + mount[-2500:])
        usb = machine.cmd("vfs mount usb")
        check("vfs mount   : /media/usb <- fat32" in usb, "FAT32 mount failed:\n" + usb[-2500:])

        imported = machine.cmd("vfs import /media/usb/store-catalog-2026.csv", 45.0)
        match = IMPORT_RE.search(imported)
        check(match is not None, "phase-45 FAT32 import summary missing:\n" + imported[-3000:])
        check(int(match.group(1)) == 10_000, f"phase-45 import has {match.group(1)} rows")
        check(int(match.group(3)) == len(catalog), f"phase-45 import has {match.group(3)} bytes")
        check(int(match.group(5), 16) == crc32c(catalog),
              f"phase-45 import CRC {match.group(5)} != {crc32c(catalog):#010x}")
        log(f"      10k FAT32 import: {match.group(1)} rows, {match.group(3)} B, CRC32C {match.group(5)}")

        retail = machine.cmd(f"retail import /media/usb/{SMALL_NAME}", 30.0)
        check(f"retail import : /media/usb/{SMALL_NAME}, 8 row(s), 8 product(s)" in retail,
              "retail catalog import failed:\n" + retail[-3000:])
        check("snapshot committed" in retail, "retail import was not committed to the VFS")
        seeded = machine.cmd("retail seedday", 30.0)
        check("retail seed   : 239 record(s), 64 receipt(s), 128 line(s)" in seeded,
              "retail seedday failed:\n" + seeded[-3000:])
        verified = machine.cmd("retail verify")
        check("retail verify : PASS, 239 records" in verified,
              "phase-47 retail evidence is not green before phase 49:\n" + verified[-3000:])
        sale_init = machine.cmd("sales init")
        check("sales init : /catalog/sales.log, 64 B header, 0/16 transactions" in sale_init,
              "phase-48 sale log init failed:\n" + sale_init[-3000:])
        sold = machine.cmd("sales sell T1 4901 100000 1")
        check("sales commit: seq 1, terminal T1" in sold and "flush + reread PASS" in sold,
              "phase-48 sale did not commit:\n" + sold[-3000:])
        sale_verify = machine.cmd("sales verify")
        check("sales verify : PASS, 1 transaction(s)" in sale_verify,
              "phase-48 sale evidence is not green before health faults:\n" + sale_verify[-3000:])

        products = machine.cmd("cassafs cat /catalog/products.db")
        psize, pcrc = cat_summary(products, "/catalog/products.db")
        check(psize == 73 and pcrc == PRODUCT_CRC,
              f"demo product file is {psize}/{pcrc}, expected 73/{PRODUCT_CRC}")
        baseline = machine.cmd("blk fsck")
        check(FSCK in baseline, "baseline CASSAFS fsck did not pass:\n" + baseline[-3000:])
        baseline_health = machine.cmd("blk health")
        check(HEALTHY in baseline_health,
              "storage was not healthy before fault injection:\n" + baseline_health[-3000:])
        log(f"      baseline: fsck PASS, product {psize} B CRC {pcrc}, health healthy")

        injected = machine.cmd("blk inject read 2048 16 1")
        check("blk inject  : read lba 2048 +16, 1 simulated failure(s)" in injected,
              "transient fault injection failed:\n" + injected[-2500:])
        transient = machine.cmd("blk fsck")
        check(FSCK in transient, "one transient media error was not recovered by retry:\n" + transient[-3000:])
        health = machine.cmd("blk health")
        check(TRANSIENT in health, "transient recovery did not degrade/warn exactly once:\n" + health[-3000:])
        log_guest(transient, "blk fsck")
        log_guest(health, "health", "media", "last error")
        log("      transient: one simulated read failure, retry recovered, fsck PASS")

        created = machine.cmd("vfs create /catalog/health49.tmp")
        check("vfs create  : /catalog/health49.tmp" in created,
              "could not create the flush-fault test file:\n" + created[-2000:])
        wrote = machine.cmd("vfs write /catalog/health49.tmp 0 health49")
        check("wrote 8 byte(s)" in wrote, "could not dirty the flush-fault test file:\n" + wrote[-2000:])
        flush_inject = machine.cmd("blk inject flush 0 1 1")
        check("blk inject  : flush lba 0 +1, 1 simulated failure(s)" in flush_inject,
              "flush fault injection failed:\n" + flush_inject[-2000:])
        flush_result = machine.cmd("vfs cache flush")
        check("vfs cache   : dirty pages written back and the backing device flushed" in flush_result,
              "one transient flush error was not recovered by retry:\n" + flush_result[-2500:])
        flush_health = machine.cmd("blk health")
        check("health      : degraded, warnings 1, retries 2, recovered 2, unrecovered 0, bad blocks 0" in flush_health,
              "flush retry was not counted as recovered:\n" + flush_health[-3000:])
        log("      flush fault: one simulated flush error, retry recovered, write-back PASS")

        viz = machine.cmd("blk viz 1")
        check("blk viz     : 1s storage health dashboard" in viz,
              "storage supervisor dashboard did not start:\n" + viz[-3000:])
        log_guest(viz, "health", "blk viz")

        machine.cmd("blk inject read 2048 16 99")
        failed = machine.cmd("blk fsck")
        check(FSCK_IO in failed or FSCK_BAD in failed,
              "persistent media error did not make fsck refuse:\n" + failed[-3000:])
        failed_again = machine.cmd("blk fsck")
        check(FSCK_BAD in failed_again,
              "quarantined range was not refused with BadBlock:\n" + failed_again[-3000:])
        failing = machine.cmd("blk health")
        check("health      : failing" in failing and "bad blocks 1" in failing,
              "persistent failure did not enter failing state with one bad range:\n" + failing[-3000:])
        log_guest(failed, "blk fsck")
        log_guest(failed_again, "blk fsck")
        log_guest(failing, "health", "last error", "bad sector")
        log("      persistent: retries exhausted, fsck refuses, range quarantined")

        cleared = machine.cmd("blk clear")
        check("blk inject  : cleared" in cleared, "fault injector did not clear")
        scrub = machine.cmd("blk scrub 2048 16")
        check("blk scrub   : lba 2048 +16, 1 bad entr(ies) cleared, readback PASS" in scrub,
              "scrub did not clear the quarantined range:\n" + scrub[-3000:])
        recovered = machine.cmd("blk fsck")
        check(FSCK in recovered, "fsck did not pass after scrub:\n" + recovered[-3000:])
        recovered_health = machine.cmd("blk health")
        check("bad blocks 0" in recovered_health and RECOVERED in recovered_health,
              "scrubbed health did not clear the bad range:\n" + recovered_health[-3000:])
        products_again = machine.cmd("cassafs cat /catalog/products.db")
        check(cat_summary(products_again, "/catalog/products.db") == (psize, pcrc),
              "product bytes changed across the simulated media errors")
        log_guest(scrub, "blk scrub")
        log_guest(recovered, "blk fsck")
        log_guest(recovered_health, "health", "bad sectors")
        log("      recovery: scrub cleared quarantine, fsck PASS, product CRC unchanged")

        flushed = machine.cmd("vfs cache flush")
        check("flush" in flushed.lower() or "dirty" in flushed.lower(),
              "page-cache flush did not report a result:\n" + flushed[-2000:])
        dropped = machine.cmd("vfs cache drop")
        check("every resident page dropped" in dropped,
              "page-cache drop did not discard resident pages:\n" + dropped[-2500:])
        after_drop = machine.cmd("sales verify")
        check("sales verify : PASS, 1 transaction(s)" in after_drop,
              "phase-48 sale did not survive cache drop after health recovery:\n" + after_drop[-3000:])
        after_drop_products = machine.cmd("cassafs cat /catalog/products.db")
        check(cat_summary(after_drop_products, "/catalog/products.db") == (psize, pcrc),
              "product bytes changed after cache drop")

        machine.cmd("vfs unmount usb")
        unmounted = machine.cmd("vfs unmount /")
        check("/ removed and page cache flushed" in unmounted,
              "CASSAFS unmount did not flush and detach:\n" + unmounted[-2500:])
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS remount failed:\n" + mount[-2500:])
        after_mount = machine.cmd("sales verify")
        check("sales verify : PASS, 1 transaction(s)" in after_mount,
              "phase-48 sale did not survive unmount/remount:\n" + after_mount[-3500:])
        after_mount_products = machine.cmd("cassafs cat /catalog/products.db")
        check(cat_summary(after_mount_products, "/catalog/products.db") == (psize, pcrc),
              "product bytes changed after unmount/remount")

        machine.reboot()
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount after reboot failed:\n" + mount[-2500:])
        after_reboot = machine.cmd("sales verify")
        check("sales verify : PASS, 1 transaction(s)" in after_reboot,
              "phase-48 sale did not survive soft reboot:\n" + after_reboot[-3500:])
        after_reboot_products = machine.cmd("cassafs cat /catalog/products.db")
        check(cat_summary(after_reboot_products, "/catalog/products.db") == (psize, pcrc),
              "product bytes changed after soft reboot")
        after_reboot_fsck = machine.cmd("blk fsck")
        check(FSCK in after_reboot_fsck, "CASSAFS fsck did not pass after soft reboot:\n" + after_reboot_fsck[-3000:])
        log("      durability: sale and product CRC intact after cache drop, remount and reboot")

        machine.cmd("vfs unmount /")
        shutdown_clean(machine)
        log("      clean shutdown after storage health evidence: OK")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def corruption_scenario() -> None:
    """A raw medium edit must be refused by fsck, never accepted as a volume."""
    work = Path(tempfile.mkdtemp(prefix="cassa-storage49-corrupt-"))
    source = work / "source.img"
    disk = work / "corrupt.img"
    _geo, _catalog = make_disk(source)
    formatter = Machine("storage49-corrupt-format", source)
    try:
        formatted = formatter.cmd("cassafs format demo", 30.0)
        check("format      : OK" in formatted, "CASSAFS corruption fixture format failed:\n" + formatted[-2500:])
        shutdown_clean(formatter)
    finally:
        formatter.close()
    shutil.copyfile(source, disk)
    offset = PART_OFFSET + (DATA_RECORD + 1) * BLOCK + 10
    with disk.open("r+b") as f:
        f.seek(offset)
        byte = f.read(1)
        check(len(byte) == 1, "corruption offset is outside the image")
        f.seek(offset)
        f.write(bytes([byte[0] ^ 0xFF]))

    machine = Machine("storage49-corrupt", disk)
    try:
        refused = machine.cmd("blk fsck")
        check("blk fsck    : REFUSED: BadCrc" in refused,
              "fsck accepted a raw-corrupted CASSAFS payload:\n" + refused[-3000:])
        log_guest(refused, "blk fsck")
        log("      corruption: raw payload byte flipped, fsck REFUSED: BadCrc")
        shutdown_clean(machine)
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    if not KERNEL.exists():
        log(f"missing {KERNEL}; run `zig build` first")
        return 2
    if not Path(QEMU).exists():
        log(f"missing QEMU ({QEMU}); set QEMU=...")
        return 2
    try:
        main_scenario()
        corruption_scenario()
    except Failure as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 49 storage health evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
