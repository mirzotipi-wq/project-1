#!/usr/bin/env python3
"""Phase 48 transactional sale-log evidence harness.

The real aarch64 kernel boots on a two-partition disk and the harness proves the
sale log on top of the phase-45/47 evidence:

  1. re-import the phase-45 10,000-row FAT32 catalog and check its CRC32C;
  2. import the 8-product vendor catalog and build the phase-47 retail day;
  3. commit three sales through the real VFS/CASSAFS write path;
  4. retry one transaction exactly and prove it is a no-op (no double count);
  5. resubmit the same key with different lines and prove Conflict;
  6. report, replay and verify the chain, terminal-local sequences and totals;
  7. flush and drop the page cache, unmount/remount, soft-reboot and re-check;
  8. retry the transaction after reboot and prove it is still a no-op;
  9. corrupt one committed byte, then prove refusal survives cache drop,
     unmount/remount and another soft reboot.

Usage:  python3 tools/qemu_sales48_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_sales48_test.py
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
from pathlib import Path

from qemu_fat32_test import IMPORT_RE, crc32c
from qemu_retail_test import SMALL_NAME, make_disk
from qemu_vfs_test import KERNEL, QEMU, Failure, Machine, check, log, mount_ready
from qemu_vfs_write_test import shutdown_clean


SALES_INIT = "sales init : /catalog/sales.log, 64 B header, 0/16 transactions, capacity 8256 B"
REPORT = "sales report : 3 transaction(s), 6 unit(s), subtotal 1555, tax 0, total 1555 cents"
VERIFY = "sales verify : PASS, 3 transaction(s)"


def expect(machine: Machine, command: str, needle: str, why: str, timeout: float = 30.0) -> str:
    text = machine.cmd(command, timeout)
    check(needle in text, f"{why}:\n{text[-4000:]}")
    return text


def log_guest(text: str, *prefixes: str) -> None:
    """Print the guest lines that substantiate a check, without prompts/tokens."""
    for raw in text.replace("\r", "").split("\n"):
        line = raw.strip()
        if any(line.startswith(prefix) for prefix in prefixes):
            log("      " + line)


def main_scenario() -> None:
    work = Path(tempfile.mkdtemp(prefix="cassa-sales48-"))
    disk = work / "sales48.img"
    _geo, catalog = make_disk(disk)

    formatter = Machine("sales48-format", disk)
    try:
        formatted = formatter.cmd("cassafs format demo", 30.0)
        check("format      : OK" in formatted, "CASSAFS format failed:\n" + formatted[-2500:])
        shutdown_clean(formatter)
    finally:
        formatter.close()

    machine = Machine("sales48-main", disk)
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
              "phase-47 retail evidence is not green before phase 48:\n" + verified[-3000:])
        log("      phase-47 retail evidence: 239 records PASS")

        init = machine.cmd("sales init")
        check(SALES_INIT in init, "sales init failed:\n" + init[-3000:])
        log("      sale log initialized: 64 B header, 16-record bound")

        first = machine.cmd("sales sell T1 5001 100000 2 100001 1")
        check("sales commit: seq 1, terminal T1" in first and "local 1" in first and "txn 5001" in first,
              "first sale did not commit at sequence 1:\n" + first[-3000:])
        check("subtotal 680, tax 0, total 680 cents" in first,
              "first sale totals are wrong:\n" + first[-3000:])
        check("flush + reread PASS" in first, "first sale did not prove flush + reread:\n" + first[-3000:])
        check("512 B record at offset 64, 576 B log" in first,
              "first sale append offset/length is wrong:\n" + first[-3000:])
        log_guest(first, "sales commit")

        second = machine.cmd("sales sell T2 5002 100002 1")
        check("sales commit: seq 2, terminal T2" in second and "local 1" in second and "txn 5002" in second,
              "second sale did not commit at sequence 2:\n" + second[-3000:])
        check("subtotal 150, tax 0, total 150 cents" in second,
              "second sale totals are wrong:\n" + second[-3000:])
        check("512 B record at offset 576, 1088 B log" in second,
              "second sale append offset/length is wrong:\n" + second[-3000:])
        log_guest(second, "sales commit")

        third = machine.cmd("sales sell T1 5003 100003 1 100004 1")
        check("sales commit: seq 3, terminal T1" in third and "local 2" in third and "txn 5003" in third,
              "third sale did not commit at sequence 3:\n" + third[-3000:])
        check("subtotal 725, tax 0, total 725 cents" in third,
              "third sale totals are wrong:\n" + third[-3000:])
        check("512 B record at offset 1088, 1600 B log" in third,
              "third sale append offset/length is wrong:\n" + third[-3000:])
        log_guest(third, "sales commit")
        log("      sales committed: sequences 1..3, T1 local 1..2, T2 local 1")

        duplicate = machine.cmd("sales sell T1 5001 100000 2 100001 1")
        check("duplicate terminal T1 txn 5001 at sequence 1; no append, no double count" in duplicate,
              "exact retry was not deduplicated:\n" + duplicate[-3000:])
        check("sales commit:" not in duplicate, "exact retry appended a record:\n" + duplicate[-3000:])
        log_guest(duplicate, "sales sell")

        conflict = machine.cmd("sales sell T1 5001 100000 3")
        check("sales sell : REFUSED: Conflict" in conflict,
              "changed payload under the same key was not refused:\n" + conflict[-3000:])
        log_guest(conflict, "sales sell")

        unknown_terminal = machine.cmd("sales sell NOPE 5009 100000 1")
        check("sales sell : REFUSED: UnknownTerminal" in unknown_terminal,
              "an unknown terminal was not refused:\n" + unknown_terminal[-3000:])
        unknown_sku = machine.cmd("sales sell T1 5009 999999 1")
        check("sales sell : REFUSED: CatalogItemMissing" in unknown_sku,
              "an unknown SKU was not refused:\n" + unknown_sku[-3000:])

        report = machine.cmd("sales report")
        check(REPORT in report, "sale report totals are wrong:\n" + report[-3500:])
        check("sales chain : seq 1..3" in report, "sale sequence range is wrong:\n" + report[-3500:])
        check("sales terminals: 2 distinct" in report, "terminal count is wrong:\n" + report[-3500:])
        check("sales terminal : T1 (id " in report and "2 txn(s), total 1405 cents" in report,
              "T1 terminal report is wrong:\n" + report[-3500:])
        check("sales terminal : T2 (id " in report and "1 txn(s), total 150 cents" in report,
              "T2 terminal report is wrong:\n" + report[-3500:])
        verified = machine.cmd("sales verify")
        check(VERIFY in verified and "terminal(s)" in verified and "PASS" in verified,
              "sale chain did not verify:\n" + verified[-3500:])
        replayed = machine.cmd("sales replay")
        check("sales replay : [seq 1] T1 txn 5001 receipt 1 lines 2 total 680" in replayed,
              "replay of sequence 1 is wrong:\n" + replayed[-3500:])
        check("sales replay : PASS, 3 transaction(s)" in replayed,
              "replay did not finish with the committed count:\n" + replayed[-3500:])
        log_guest(report, "sales report", "sales chain", "sales terminal")
        log_guest(verified, "sales verify")
        log_guest(replayed, "sales replay")
        log("      report/verify/replay: 3 transactions, 6 units, 1555 cents, 2 terminals")

        flushed = machine.cmd("vfs cache flush")
        check("flush" in flushed.lower() or "dirty" in flushed.lower(),
              "page-cache flush did not report a result:\n" + flushed[-2000:])
        dropped = machine.cmd("vfs cache drop")
        check("every resident page dropped" in dropped,
              "page-cache drop did not discard resident pages:\n" + dropped[-2500:])
        expect(machine, "sales verify", VERIFY, "sale log did not survive cache drop")
        expect(machine, "sales report", REPORT, "sale totals changed after cache drop")
        log("      cache flush + drop: log reloaded from disk intact")

        machine.cmd("vfs unmount usb")
        unmounted = machine.cmd("vfs unmount /")
        check("/ removed and page cache flushed" in unmounted,
              "CASSAFS unmount did not flush and detach:\n" + unmounted[-2500:])
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS remount failed:\n" + mount[-2500:])
        expect(machine, "sales verify", VERIFY, "sale log did not survive unmount/remount")
        expect(machine, "sales report", REPORT, "sale totals changed after remount")
        log("      unmount/remount: log intact")

        machine.reboot()
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount after reboot failed:\n" + mount[-2500:])
        expect(machine, "sales verify", VERIFY, "sale log did not survive soft reboot")
        expect(machine, "sales report", REPORT, "sale totals changed after reboot")
        retry = machine.cmd("sales sell T1 5001 100000 2 100001 1")
        check("duplicate terminal T1 txn 5001 at sequence 1; no append, no double count" in retry,
              "retry after reboot was not deduplicated:\n" + retry[-3500:])
        expect(machine, "sales verify", VERIFY, "retry after reboot changed the committed log")
        log("      soft reboot: log intact; retry still a no-op")

        machine.cmd("sales corrupt")
        refused = machine.cmd("sales verify")
        check("sales verify : REFUSED: RecordCorrupt" in refused,
              "corrupted sale record was not refused:\n" + refused[-3500:])
        log_guest(refused, "sales verify")
        after_corrupt_sell = machine.cmd("sales sell T1 5010 100000 1")
        check("sales sell : REFUSED: RecordCorrupt" in after_corrupt_sell,
              "a sale was accepted over a corrupted log:\n" + after_corrupt_sell[-3500:])
        log_guest(after_corrupt_sell, "sales sell")
        machine.cmd("vfs cache drop")
        refused = machine.cmd("sales verify")
        check("sales verify : REFUSED: RecordCorrupt" in refused,
              "corruption refusal did not survive the page-cache drop:\n" + refused[-3500:])
        machine.cmd("vfs unmount /")
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS remount after corruption failed:\n" + mount[-2500:])
        refused = machine.cmd("sales verify")
        check("sales verify : REFUSED: RecordCorrupt" in refused,
              "corruption refusal did not survive unmount/remount:\n" + refused[-3500:])
        machine.reboot()
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount after corruption reboot failed:\n" + mount[-2500:])
        refused = machine.cmd("sales verify")
        check("sales verify : REFUSED: RecordCorrupt" in refused,
              "corruption refusal did not survive soft reboot:\n" + refused[-3500:])
        log("      corrupted record refused across cache drop, remount and reboot")

        machine.cmd("vfs unmount /")
        shutdown_clean(machine)
        log("      clean shutdown after the corruption test: OK")
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
    log("phase 48 transactional sale log evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
