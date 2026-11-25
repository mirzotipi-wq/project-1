#!/usr/bin/env python3
"""Phase 47 retail data-model evidence harness.

The real aarch64 kernel boots on a two-partition disk: CASSAFS at `/` and a
foreign FAT32 volume at `/media/usb` containing both the phase-45 10,000-row
catalog and a small vendor catalog. The harness:

  1. re-imports the 10k catalog through the VFS and checks its CRC32C;
  2. imports the 8-product vendor catalog through the same VFS/FAT32 path;
  3. builds a deterministic day of 64 receipts / 128 lines / 3 terminals;
  4. verifies relations and recomputed totals, then flushes the page cache;
  5. unmounts/remounts the CASSAFS root and verifies the day again;
  6. soft-reboots, mounts, and verifies the day a third time;
  7. deliberately corrupts a record and proves the validator refuses it.

Usage:  python3 tools/qemu_retail_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_retail_test.py
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
from pathlib import Path

from qemu_fat32_test import (
    CASSA_START,
    CASSA_SECTORS,
    FAT_OFFSET,
    FAT_SECTORS,
    FAT_START,
    Geometry,
    IMPORT_RE,
    SECTOR,
    catalog_bytes,
    crc32c,
    lfn_entries,
    put16,
    put32,
    short_entry,
)
from qemu_vfs_test import KERNEL, QEMU, Failure, Machine, check, log, mount_ready
from qemu_vfs_write_test import shutdown_clean

SMALL_NAME = "retail-catalog.csv"
SMALL_SHORT = b"RETAIL~1CSV"

PRODUCTS = [
    ("100000", "Espresso", 250),
    ("100001", "Croissant", 180),
    ("100002", "Water", 150),
    ("100003", "Orange Juice", 300),
    ("100004", "Sandwich", 425),
    ("100005", "Cookie", 125),
    ("100006", "Tea", 200),
    ("100007", "Salad", 475),
]


def small_catalog_bytes() -> bytes:
    out = bytearray(b"sku,name,price_cents\n")
    for sku, name, price in PRODUCTS:
        out += f"{sku},{name},{price}\n".encode()
    return bytes(out)


def build_two_files(total_sectors: int = FAT_SECTORS) -> tuple[bytearray, Geometry]:
    geo = Geometry(total_sectors)
    part = bytearray(geo.total * geo.bps)
    boot = bytearray(512)
    boot[0:3] = b"\xeb\x58\x90"
    boot[3:11] = b"CASSAOS "
    put16(boot, 11, geo.bps)
    boot[13] = geo.spc
    put16(boot, 14, geo.reserved)
    boot[16] = geo.fats
    boot[21] = 0xF8
    put32(boot, 32, geo.total)
    put32(boot, 36, geo.fat_sectors)
    put32(boot, 44, 2)
    put16(boot, 48, 1)
    put16(boot, 50, 6)
    boot[64] = 0x80
    boot[66] = 0x29
    put32(boot, 67, 0xCA55A045)
    boot[71:82] = b"CASSA-RTL  "
    boot[82:90] = b"FAT32   "
    boot[510:512] = b"\x55\xaa"
    part[0:512] = boot
    part[6 * 512:7 * 512] = boot

    data1 = catalog_bytes()
    data2 = small_catalog_bytes()
    clusters1 = (len(data1) + geo.cluster_bytes - 1) // geo.cluster_bytes
    clusters2 = (len(data2) + geo.cluster_bytes - 1) // geo.cluster_bytes
    first1 = 3
    first2 = first1 + clusters1
    if first2 + clusters2 > geo.clusters + 2:
        raise Failure("two CATALOG files do not fit the FAT32 fixture")

    def set_fat(cluster: int, value: int) -> None:
        for copy in range(geo.fats):
            off = (geo.reserved + copy * geo.fat_sectors) * geo.bps + cluster * 4
            put32(part, off, value)

    set_fat(0, 0x0FFFFFF8)
    set_fat(1, 0x0FFFFFFF)
    set_fat(2, 0x0FFFFFFF)
    for i in range(clusters1):
        set_fat(first1 + i, first1 + i + 1 if i + 1 < clusters1 else 0x0FFFFFFF)
    for i in range(clusters2):
        set_fat(first2 + i, first2 + i + 1 if i + 1 < clusters2 else 0x0FFFFFFF)

    root_off = (geo.data_start + (2 - 2) * geo.spc) * geo.bps
    directory = lfn_entries("store-catalog-2026.csv", b"STOREC~1CSV")
    directory += short_entry(b"STOREC~1CSV", first1, len(data1))
    directory += lfn_entries(SMALL_NAME, SMALL_SHORT)
    directory += short_entry(SMALL_SHORT, first2, len(data2))
    directory += b"\x00" * 32
    if len(directory) > geo.cluster_bytes:
        raise Failure("FAT32 fixture directory does not fit one cluster")
    part[root_off:root_off + len(directory)] = directory

    off1 = (geo.data_start + (first1 - 2) * geo.spc) * geo.bps
    part[off1:off1 + len(data1)] = data1
    off2 = (geo.data_start + (first2 - 2) * geo.spc) * geo.bps
    part[off2:off2 + len(data2)] = data2

    info = bytearray(512)
    put32(info, 0, 0x41615252)
    put32(info, 484, 0x61417272)
    put32(info, 488, geo.clusters - 1 - clusters1 - clusters2)
    put32(info, 492, first2 + clusters2)
    put32(info, 508, 0xAA550000)
    part[1 * 512:2 * 512] = info
    part[7 * 512:8 * 512] = info
    return part, geo


def make_disk(path: Path) -> tuple[Geometry, bytes]:
    part, geo = build_two_files()
    image = bytearray((FAT_START + FAT_SECTORS) * SECTOR)
    image[446] = 0x80
    image[450] = 0x7F
    image[454:458] = CASSA_START.to_bytes(4, "little")
    image[458:462] = CASSA_SECTORS.to_bytes(4, "little")
    image[462] = 0x00
    image[466] = 0x0C
    image[470:474] = FAT_START.to_bytes(4, "little")
    image[474:478] = FAT_SECTORS.to_bytes(4, "little")
    image[510:512] = b"\x55\xaa"
    image[FAT_OFFSET:FAT_OFFSET + len(part)] = part
    path.write_bytes(image)
    return geo, catalog_bytes()


def expected_day() -> tuple[int, int, int, int, int, str, int, int]:
    """Mirror seedDay's deterministic arithmetic (tax class ZERO)."""
    product_count = len(PRODUCTS)
    prices = [p[2] for p in PRODUCTS]
    subtotal = 0
    units = 0
    cash = 0
    cash_by_shift = [0, 0, 0]
    units_by_product = [0] * product_count
    revenue_by_product = [0] * product_count
    for i in range(64):
        p1 = i % product_count
        p2 = (i * 3 + 1) % product_count
        q1 = 1 + (i & 1)
        q2 = 1
        if i % 8 == 0:
            discount = (prices[p1] * q1 * 1000) // 10000 if i % 16 == 0 else 50
        else:
            discount = 0
        line1 = prices[p1] * q1 - discount
        line2 = prices[p2] * q2
        receipt = line1 + line2
        subtotal += receipt
        units += q1 + q2
        units_by_product[p1] += q1
        units_by_product[p2] += q2
        revenue_by_product[p1] += line1
        revenue_by_product[p2] += line2
        if i % 2 == 0:
            cash += receipt
            cash_by_shift[i % 3] += receipt
    variance = 0 + 100 - 50
    top = max(range(product_count), key=lambda k: (units_by_product[k], -k))
    top_text = f"{PRODUCTS[top][0]} {PRODUCTS[top][1]}"
    return subtotal, units, cash, variance, top, top_text, units_by_product[top], revenue_by_product[top]


REPORT_RE = re.compile(
    r"retail report : (\d+) records, (\d+) products, (\d+) variants, (\d+) barcodes, "
    r"(\d+) tax classes, (\d+) promotions"
)


def main_scenario() -> None:
    work = Path(tempfile.mkdtemp(prefix="cassa-retail47-"))
    disk = work / "retail47.img"
    geo, catalog = make_disk(disk)
    formatter = Machine("retail47-format", disk)
    try:
        formatted = formatter.cmd("cassafs format demo", 30.0)
        check("format      : OK" in formatted, "CASSAFS root format failed:\n" + formatted[-2500:])
        shutdown_clean(formatter)
    finally:
        formatter.close()

    machine = Machine("retail47-main", disk)
    try:
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount failed:\n" + mount[-2500:])
        usb = machine.cmd("vfs mount usb")
        check("vfs mount   : /media/usb <- fat32" in usb, "FAT32 mount failed:\n" + usb[-2500:])

        # Tie the retail path to the phase-45 evidence: the same 10k FAT32
        # catalog, same VFS import, same expected CRC.
        imported = machine.cmd("vfs import /media/usb/store-catalog-2026.csv", 45.0)
        match = IMPORT_RE.search(imported)
        check(match is not None, "phase-45 FAT32 import summary missing:\n" + imported[-3000:])
        check(int(match.group(1)) == 10_000, f"phase-45 import has {match.group(1)} rows")
        check(int(match.group(3)) == len(catalog), f"phase-45 import has {match.group(3)} bytes")
        check(int(match.group(5), 16) == crc32c(catalog),
              f"phase-45 import CRC {match.group(5)} != {crc32c(catalog):#010x}")
        log(f"      10k FAT32 import: {match.group(1)} rows, {match.group(3)} B, CRC32C {match.group(5)}")

        imported = machine.cmd(f"retail import /media/usb/{SMALL_NAME}", 30.0)
        check(f"retail import : /media/usb/{SMALL_NAME}, 8 row(s), 8 product(s)" in imported,
              "retail catalog import failed:\n" + imported[-3000:])
        check("snapshot committed" in imported, "retail import was not committed to the VFS:")
        check("refused" not in imported, "retail import reported a refusal:\n" + imported[-3000:])
        log("      retail import: 8 products from real FAT32")

        seeded = machine.cmd("retail seedday", 30.0)
        check("retail seed   : 239 record(s), 64 receipt(s), 128 line(s)" in seeded,
              "retail seedday failed:\n" + seeded[-3000:])
        log("      day seeded: 239 records, 64 receipts, 128 lines")

        verified = machine.cmd("retail verify")
        check("retail verify : PASS, 239 records" in verified,
              "retail verify did not accept the seeded day:\n" + verified[-3000:])
        report = machine.cmd("retail report")
        rmatch = REPORT_RE.search(report)
        check(rmatch is not None, "retail report summary missing:\n" + report[-3500:])
        counts = [int(x) for x in rmatch.groups()]
        check(counts == [239, 8, 4, 12, 3, 2], f"retail report counts were {counts}")
        subtotal, units, cash, variance, top, top_text, top_units, top_revenue = expected_day()
        check(f"sales         : 64 receipts, 128 lines, {units} units" in report,
              f"retail report units diverged:\n{report[-3500:]}")
        check(f"subtotal {subtotal}, tax 0, total {subtotal} cents" in report,
              f"retail report totals diverged (expected {subtotal}):\n{report[-3500:]}")
        check(f"tender        : {subtotal} cents, cash {cash}, change 0, drawer variance {variance}" in report,
              f"retail report tender/drawer diverged:\n{report[-3500:]}")
        check(f"top product   : {top_text}, {top_units} units, {top_revenue} cents" in report,
              f"top product diverged:\n{report[-3500:]}")
        check("audit         : PASS" in report, "retail report audit did not pass")
        log(f"      day totals: subtotal {subtotal}, units {units}, cash {cash}, variance {variance}")
        log(f"      top product: {top_text}")

        # Refusal and atomicity: a second import would duplicate every SKU, and
        # the 10k catalog exceeds the bounded 480-record model. Neither may
        # leave a partial product set or a changed day behind.
        duplicate = machine.cmd(f"retail import /media/usb/{SMALL_NAME}", 30.0)
        check("retail import : refused" in duplicate and "DuplicateCode" in duplicate,
              "duplicate retail import was not refused:\n" + duplicate[-3000:])
        unchanged = machine.cmd("retail verify")
        check("retail verify : PASS, 239 records" in unchanged,
              "a refused import changed the committed day:\n" + unchanged[-3000:])
        log("      refused import: duplicate SKUs, committed day unchanged")

        flushed = machine.cmd("vfs cache flush")
        check("flush" in flushed.lower() or "dirty" in flushed.lower(),
              "page-cache flush did not report a result:\n" + flushed[-2000:])
        dropped = machine.cmd("vfs cache drop")
        check("every resident page dropped" in dropped,
              "page-cache drop did not discard the resident pages:\n" + dropped[-2500:])
        after_drop = machine.cmd("retail verify")
        check("retail verify : PASS, 239 records" in after_drop,
              "retail day did not reload after the cache was dropped:\n" + after_drop[-3000:])
        report_drop = machine.cmd("retail report")
        check(f"subtotal {subtotal}, tax 0, total {subtotal} cents" in report_drop,
              "retail totals changed after cache drop:\n" + report_drop[-3000:])
        log("      cache flush + drop: day reloaded from disk intact")
        machine.cmd("vfs unmount usb")
        unmounted = machine.cmd("vfs unmount /")
        check("/ removed and page cache flushed" in unmounted,
              "CASSAFS root unmount did not flush and detach:\n" + unmounted[-2500:])
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS remount failed:\n" + mount[-2500:])
        again = machine.cmd("retail verify")
        check("retail verify : PASS, 239 records" in again,
              "retail day did not survive unmount/remount:\n" + again[-3000:])
        report2 = machine.cmd("retail report")
        check(f"subtotal {subtotal}, tax 0, total {subtotal} cents" in report2,
              "retail totals changed after remount:\n" + report2[-3000:])
        log("      cache flush + unmount/remount: day intact")

        machine.reboot()
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount after reboot failed:\n" + mount[-2500:])
        again = machine.cmd("retail verify")
        check("retail verify : PASS, 239 records" in again,
              "retail day did not survive reboot:\n" + again[-3000:])
        report3 = machine.cmd("retail report")
        check(f"tender        : {subtotal} cents, cash {cash}, change 0, drawer variance {variance}" in report3,
              "retail totals changed after reboot:\n" + report3[-3000:])
        log("      soft reboot: day intact")

        machine.cmd("retail corrupt")
        refused = machine.cmd("retail verify")
        check("retail verify : REFUSED" in refused,
              "corrupted retail snapshot was not refused:\n" + refused[-3000:])
        check("RecordCorrupt" in refused, "retail corruption was not reported as a record CRC failure")
        log("      corrupted record: refused with RecordCorrupt")

        machine.cmd("vfs unmount /")
        shutdown_clean(machine)
        log("      clean shutdown after corruption test: OK")
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
    except Failure as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 47 retail model evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
