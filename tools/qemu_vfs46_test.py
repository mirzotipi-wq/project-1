#!/usr/bin/env python3
"""Phase 46 VFS evidence harness.

The real aarch64 kernel boots with a two-partition disk: CASSAFS at `/`, a
foreign FAT32 catalog at `/media/usb`, and the bounded tmpfs at `/tmp`. The
harness resolves the same canonical paths through all three backends, then
exercises tmpfs create/write/read, chmod refusal, advisory lock conflict,
change notifications and unmount/remount. It also streams the phase-45 catalog
through the same VFS to keep the retail path tied to real FAT32 evidence.

Usage:  python3 tools/qemu_vfs46_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_vfs46_test.py
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

from qemu_fat32_test import LONG_NAME, catalog_bytes, check_import, crc32c, prepare_fat_disk
from qemu_vfs_test import KERNEL, QEMU, Failure, Machine, cat_summary, check, log, mount_ready
from qemu_vfs_write_test import shutdown_clean

NOTICE = b"phase46"
APPEND = b"ok"
WATCH_FILE = "event.txt"


def stat_path(output: str, expected: str) -> None:
    match = re.search(r"vfs stat\s+:\s+(\S+)", output)
    check(match is not None, "stat summary missing:\n" + output[-2500:])
    check(match.group(1) == expected,
          f"stat resolved {match.group(1)!r}, expected {expected!r}:\n" + output[-2500:])


def main_scenario() -> None:
    work, disk, geo = prepare_fat_disk("vfs46")
    data = catalog_bytes()
    machine = Machine("vfs46-main", disk)
    try:
        mount_ready(machine)
        usb = machine.cmd("vfs mount usb")
        check("vfs mount   : /media/usb <- fat32" in usb, "FAT32 mount failed:\n" + usb[-2500:])
        tmp = machine.cmd("vfs mount tmpfs")
        check("vfs mount   : /tmp <- tmpfs" in tmp, "tmpfs mount failed:\n" + tmp[-2500:])
        check("mount table 3/8" in tmp, "three mounts were not recorded:\n" + tmp[-2500:])

        mkdir = machine.cmd("vfs mkdir /tmp/spool")
        check("vfs mkdir   : /tmp/spool" in mkdir, "tmpfs mkdir failed:\n" + mkdir[-2500:])
        created = machine.cmd("vfs create /tmp/spool/notice.txt")
        check("/tmp/spool/notice.txt" in created and "mode 0o100644" in created,
              "tmpfs create failed:\n" + created[-2500:])
        wrote = machine.cmd(f"vfs write /tmp/spool/notice.txt 0 {NOTICE.decode()}")
        check("wrote 7 byte(s), size 7 B" in wrote, "tmpfs write failed:\n" + wrote[-2500:])
        size, crc = cat_summary(machine.cmd("vfs cat /tmp/spool/notice.txt"), "/tmp/spool/notice.txt")
        check(size == len(NOTICE) and int(crc, 16) == crc32c(NOTICE),
              f"tmpfs readback was {size} B/{crc}:\n" + machine.cmd("vfs cat /tmp/spool/notice.txt")[-2500:])

        # Same resolver, three different backends: absolute, dot-relative and
        # dot-dot-relative inputs must all produce the same canonical path.
        stat_path(machine.cmd("vfs stat ./catalog/products.db"), "/catalog/products.db")
        stat_path(machine.cmd(f"vfs stat ./media/usb/./{LONG_NAME}"), f"/media/usb/{LONG_NAME}")
        stat_path(machine.cmd("vfs stat ./tmp/spool/../spool/notice.txt"), "/tmp/spool/notice.txt")
        listing = machine.cmd("vfs ls /tmp/spool")
        check("notice.txt" in listing and "size 7" in listing, "tmpfs readdir lost the file:\n" + listing[-2500:])

        chmod = machine.cmd("vfs chmod /tmp/spool/notice.txt 444")
        check("mode 0o100444" in chmod, "chmod did not apply read-only bits:\n" + chmod[-2500:])
        denied = machine.cmd("vfs write /tmp/spool/notice.txt 7 x")
        check("permission denied" in denied and "size 7 B" not in denied,
              "write after chmod 444 was not refused:\n" + denied[-2500:])
        check(machine.cmd("vfs cat /tmp/spool/notice.txt").find("7 byte(s)") >= 0,
              "read after chmod 444 was not allowed")
        chmod = machine.cmd("vfs chmod /tmp/spool/notice.txt 644")
        check("mode 0o100644" in chmod, "chmod did not restore write bits:\n" + chmod[-2500:])
        machine.cmd(f"vfs write /tmp/spool/notice.txt {len(NOTICE)} {APPEND.decode()}")
        total = NOTICE + APPEND
        size, crc = cat_summary(machine.cmd("vfs cat /tmp/spool/notice.txt"), "/tmp/spool/notice.txt")
        check(size == len(total) and int(crc, 16) == crc32c(total),
              "append after chmod 644 was not visible")

        locks = machine.cmd("vfs lock /tmp/spool/notice.txt")
        check("exclusive acquired" in locks and "second exclusive lock refused" in locks,
              "advisory lock conflict was not reported:\n" + locks[-2500:])
        check("shared locks coexist" in locks and locks.count("PASS") >= 2,
              "shared lock coexistence was not proven:\n" + locks[-2500:])

        watched = machine.cmd("vfs watch /tmp")
        check("vfs watch   : id 1 on /tmp" in watched, "watch registration failed:\n" + watched[-2500:])
        machine.cmd(f"vfs create /tmp/spool/{WATCH_FILE}")
        machine.cmd(f"vfs write /tmp/spool/{WATCH_FILE} 0 event")
        events = machine.cmd("vfs events")
        check("created /tmp/spool/event.txt" in events, "create event missing:\n" + events[-3000:])
        check("modified /tmp/spool/event.txt" in events, "write event missing:\n" + events[-3000:])
        check("2 event(s)" in events, "event count was not two:\n" + events[-3000:])

        info = machine.cmd("vfs info")
        check("3 mount(s)" in info and "/tmp <- tmpfs" in info, "vfs info lost tmpfs:\n" + info[-3000:])
        check("1 watch(es), 0 pending event(s)" in info,
              "watch/event accounting is wrong:\n" + info[-3000:])

        # The phase-45 retail path still imports through the same VFS, with the
        # same FAT32 chain reader and the same 10k-row CSV parser.
        check_import(machine, geo, data)

        unwatch = machine.cmd("vfs unwatch 1")
        check("id 1 removed" in unwatch, "unwatch failed:\n" + unwatch[-2000:])
        unmount = machine.cmd("vfs unmount tmpfs")
        check("/tmp removed; scratch data discarded" in unmount,
              "tmpfs unmount failed:\n" + unmount[-2000:])
        check("/tmp <- tmpfs" not in machine.cmd("vfs info"), "tmpfs remained visible after unmount")
        check("73 byte(s)" in machine.cmd("vfs cat /catalog/products.db"),
              "CASSAFS root was damaged by tmpfs unmount")
        remount = machine.cmd("vfs mount tmpfs")
        check("/tmp <- tmpfs" in remount, "tmpfs remount failed:\n" + remount[-2000:])
        check("1 node(s) used, 0 data byte(s)" in machine.cmd("vfs info"),
              "remounted tmpfs was not empty")
        machine.cmd("vfs unmount tmpfs")
        machine.cmd("vfs unmount usb")
        shutdown_clean(machine)
        log("      three-backend paths, tmpfs writes, chmod, locks, watches, unmount/remount: PASS")
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
    log("phase 46 VFS evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
