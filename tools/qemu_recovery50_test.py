#!/usr/bin/env python3
"""Phase 50 snapshot and recovery evidence harness.

The same two-partition disk carries the phase-45 FAT32 catalog, the phase-47
retail day and a phase-48 sale. On top of that the harness:

  - initializes a bounded 128-byte configuration and four snapshot slots;
  - changes two fields, explicitly snapshots the result, then corrupts the live
    configuration directly and proves `recovery verify` refuses with BadCrc;
  - proves `recovery rollback` restores the last snapshot in one command;
  - preserves config, snapshots and the phase-48 sale across cache drop,
    unmount/remount and a soft reboot;
  - writes a checksummed support bundle and checks its file size;
  - factory-resets with the preserve policy and proves the sale audit log is
    unchanged and still verifies;
  - corrupts the snapshot header and proves rollback refuses with BadCrc rather
    than inventing a fallback.

Usage:  python3 tools/qemu_recovery50_test.py [--keep]
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
from pathlib import Path

from qemu_fat32_test import IMPORT_RE
from qemu_retail_test import SMALL_NAME, make_disk
from qemu_storage49_test import cat_summary
from qemu_vfs_test import KERNEL, QEMU, Failure, Machine, check, log, mount_ready
from qemu_vfs_write_test import shutdown_clean


VERIFY_PASS = "recovery verify : PASS"
BUNDLE_RE = re.compile(r"recovery bundle : (/catalog/support\.bundle), (\d+) byte\(s\), CRC32C (0x[0-9a-f]{8})")
STAT_RE = re.compile(r"vfs stat    : /catalog/support\.bundle.*?size (\d+) B", re.S)


def log_guest(text: str, *prefixes: str) -> None:
    for raw in text.replace("\r", "").split("\n"):
        line = raw.strip()
        if any(line.startswith(prefix) for prefix in prefixes):
            log("      " + line)


def require(machine: Machine, command: str, expected: str, timeout: float = 30.0) -> str:
    result = machine.cmd(command, timeout)
    check(expected in result, f"{command!r} did not contain {expected!r}:\n{result[-3500:]}")
    return result


def main_scenario() -> None:
    work = Path(tempfile.mkdtemp(prefix="cassa-recovery50-"))
    disk = work / "recovery50.img"
    _geo, catalog = make_disk(disk)

    formatter = Machine("recovery50-format", disk)
    try:
        require(formatter, "cassafs format demo", "format      : OK", 30.0)
        shutdown_clean(formatter)
    finally:
        formatter.close()

    machine = Machine("recovery50-main", disk)
    try:
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS mount failed:\n" + mount[-2500:])
        require(machine, "vfs mount usb", "vfs mount   : /media/usb <- fat32")

        imported = machine.cmd("vfs import /media/usb/store-catalog-2026.csv", 45.0)
        match = IMPORT_RE.search(imported)
        check(match is not None, "phase-45 FAT32 import summary missing:\n" + imported[-3000:])
        check(int(match.group(1)) == 10_000, f"phase-45 import has {match.group(1)} rows")
        check(int(match.group(3)) == len(catalog), f"phase-45 import has {match.group(3)} bytes")
        log(f"      10k FAT32 import: {match.group(1)} rows, {match.group(3)} B, CRC32C {match.group(5)}")

        require(machine, f"retail import /media/usb/{SMALL_NAME}", "retail import :", 30.0)
        require(machine, "retail seedday", "retail seed   : 239 record(s), 64 receipt(s), 128 line(s)", 30.0)
        require(machine, "retail verify", "retail verify : PASS, 239 records")
        require(machine, "sales init", "sales init : /catalog/sales.log, 64 B header, 0/16 transactions")
        sale = require(machine, "sales sell T1 7001 100000 1", "sales commit: seq 1, terminal T1")
        check("flush + reread PASS" in sale, "phase-48 sale was not flushed and reread:\n" + sale[-3000:])
        require(machine, "sales verify", "sales verify : PASS, 1 transaction(s)")

        health = machine.cmd("blk health")
        check("health      : healthy" in health, "storage was not healthy before recovery evidence:\n" + health[-2500:])
        fsck = machine.cmd("blk fsck")
        check("blk fsck    : PASS" in fsck, "storage fsck was not green before recovery evidence:\n" + fsck[-3000:])

        init = require(machine, "recovery init", "recovery init : /catalog/config.cfg, 128 byte(s), generation 1")
        check("recovery init : /catalog/config.snap, snapshot slot 0, 4-slot bound" in init,
              "initial snapshot was not created:\n" + init[-2500:])
        log_guest(init, "recovery init")
        status = require(machine, "recovery status", "recovery config : /catalog/config.cfg, 128 byte(s), generation 1")
        check("recovery snaps  : 1/4 valid" in status, "initial snapshot count is wrong:\n" + status[-3000:])
        log_guest(status, "recovery config", "recovery values", "recovery snaps", "recovery audit")

        require(machine, "recovery set store North Till", 'recovery set : store = "North Till", generation 2')
        require(machine, "recovery set footer Receipt footer", 'recovery set : footer = "Receipt footer", generation 3')
        snapshot = require(machine, "recovery snapshot", "recovery snapshot : generation 3 in slot 3")
        log_guest(snapshot, "recovery snapshot")
        verify = require(machine, "recovery verify", "recovery verify : PASS, generation 3")
        check('store "North Till"' in verify and 'tax inclusive' in verify,
              "saved config values are wrong:\n" + verify[-2500:])
        log_guest(verify, "recovery verify")

        corrupt = machine.cmd("recovery corrupt config")
        check("recovery corrupt : flipped a config payload byte" in corrupt,
              "config corruption hook did not run:\n" + corrupt[-2000:])
        bad_verify = machine.cmd("recovery verify")
        check("recovery verify : REFUSED: BadCrc" in bad_verify,
              "corrupted config was not refused with BadCrc:\n" + bad_verify[-2500:])
        rollback = require(machine, "recovery rollback", "recovery rollback : restored generation 3 from slot 3")
        check("flush + reread PASS" in rollback, "rollback did not flush and reread:\n" + rollback[-2500:])
        restored = machine.cmd("recovery verify")
        check(VERIFY_PASS in restored and "generation 3" in restored and 'store "North Till"' in restored,
              "rollback did not restore the snapshot:\n" + restored[-3000:])
        log_guest(bad_verify, "recovery verify")
        log_guest(rollback, "recovery rollback")
        log("      corruption -> rollback: bad config refused, snapshot restored in one command")

        require(machine, "vfs cache flush", "vfs cache   : dirty pages written back")
        require(machine, "vfs cache drop", "every resident page dropped")
        require(machine, "recovery verify", "recovery verify : PASS, generation 3")
        require(machine, "sales verify", "sales verify : PASS, 1 transaction(s)")

        require(machine, "vfs unmount usb", "vfs unmount : /media/usb removed")
        require(machine, "vfs unmount /", "/ removed and page cache flushed")
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "remount failed:\n" + mount[-2500:])
        require(machine, "recovery verify", "recovery verify : PASS, generation 3")
        require(machine, "sales verify", "sales verify : PASS, 1 transaction(s)")
        log("      cache drop and unmount/remount: config and sale audit intact")

        machine.reboot()
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "mount after reboot failed:\n" + mount[-2500:])
        require(machine, "recovery verify", "recovery verify : PASS, generation 3")
        require(machine, "sales verify", "sales verify : PASS, 1 transaction(s)")
        require(machine, "blk fsck", "blk fsck    : PASS")
        after_reboot_status = require(machine, "recovery status", "recovery snaps  : 4/4 valid")
        check("latest generation 3 in slot 3" in after_reboot_status,
              "snapshot status did not survive reboot:\n" + after_reboot_status[-3000:])
        require(machine, "recovery corrupt config", "recovery corrupt : flipped a config payload byte")
        post_reboot_rollback = require(machine, "recovery rollback", "restored generation 3 from slot 3")
        require(machine, "recovery verify", "recovery verify : PASS, generation 3")
        log_guest(post_reboot_rollback, "recovery rollback")
        log("      soft reboot: config, four snapshot slots and sale audit intact; rollback still works")

        bundle = machine.cmd("recovery bundle")
        match = BUNDLE_RE.search(bundle)
        check(match is not None, "support bundle summary missing:\n" + bundle[-3000:])
        bundle_path, bundle_size, bundle_crc = match.group(1), int(match.group(2)), match.group(3)
        check(bundle_path == "/catalog/support.bundle" and bundle_size > 128,
              f"support bundle is {bundle_path}/{bundle_size}")
        stat = machine.cmd("vfs stat /catalog/support.bundle")
        stat_match = STAT_RE.search(stat)
        check(stat_match is not None, "support bundle stat missing:\n" + stat[-2500:])
        check(int(stat_match.group(1)) == bundle_size,
              f"bundle stat size {stat_match.group(1)} != summary {bundle_size}")
        log_guest(bundle, "recovery bundle")
        log_guest(stat, "vfs stat")
        log(f"      support bundle: {bundle_size} B, {bundle_crc}, stat size matches")

        require(machine, "recovery factory-reset preserve", "recovery reset : PASS, generation 1")
        check("recovery reset : REFUSED: UnsupportedPolicy" in machine.cmd("recovery factory-reset wipe"),
              "unsupported factory-reset policy did not refuse")
        verify_reset = require(machine, "recovery verify", "recovery verify : PASS, generation 1")
        check('store "Cassa Store"' in verify_reset, "factory reset did not restore defaults:\n" + verify_reset[-2500:])
        sale_after_reset = require(machine, "sales verify", "sales verify : PASS, 1 transaction(s)")
        log_guest(sale_after_reset, "sales verify")
        require(machine, "blk fsck", "blk fsck    : PASS")
        log("      factory reset preserve: default config restored, sale audit still verifies")

        corrupt_snapshot = machine.cmd("recovery corrupt snapshot")
        check("recovery corrupt : flipped the snapshot header CRC" in corrupt_snapshot,
              "snapshot corruption hook did not run:\n" + corrupt_snapshot[-2000:])
        refused = machine.cmd("recovery rollback")
        check("recovery rollback : REFUSED: BadCrc" in refused,
              "corrupted snapshot was not refused with BadCrc:\n" + refused[-3000:])
        log_guest(refused, "recovery rollback")
        log("      corrupted snapshot: rollback refuses BadCrc, no invented fallback")

        require(machine, "vfs unmount /", "/ removed and page cache flushed")
        shutdown_clean(machine)
        log("      clean shutdown after recovery evidence: OK")
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
    log("phase 50 snapshot and recovery evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
