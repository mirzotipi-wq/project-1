#!/usr/bin/env python3
"""Phase 43 CASSAFS write-path evidence harness.

The real aarch64 kernel is booted under QEMU. A demo CASSAFS volume is
formatted, mounted through the VFS, a new file is created and written through
a VFS write handle, overwritten with an offset write, read back byte for byte,
unmounted/remounted, soft-rebooted, and read again. The script also proves the
out-of-space refusal on a tiny volume and that a deliberately corrupted volume
is still rejected by the phase-42 CRC/tree/extent scan.

Usage:  python3 tools/qemu_vfs_write_test.py [--only NAME] [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_vfs_write_test.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from qemu_vfs_test import (
    BLOCK,
    DATA_RECORD,
    KERNEL,
    PART_OFFSET,
    PRODUCTS_CRC,
    PRODUCTS_SIZE,
    QEMU,
    ROOT,
    Failure,
    Machine,
    cassafs_cat_summary,
    cat_summary,
    check,
    log,
    make_disk,
    mount_ready,
    prepare_formatted,
)

SHOT_DIR = ROOT / "docs" / "screenshots"
TINY_START = 8
TINY_SECTORS = 64


def make_tiny_disk(path: Path) -> None:
    """An 8-block CASSAFS volume: partition starts at a 4 KiB boundary."""
    image = bytearray((TINY_START + TINY_SECTORS) * 512)
    image[446] = 0x80
    image[450] = 0x7F
    image[454:458] = TINY_START.to_bytes(4, "little")
    image[458:462] = TINY_SECTORS.to_bytes(4, "little")
    image[510] = 0x55
    image[511] = 0xAA
    path.write_bytes(image)


def tiny_mount_ready(machine: Machine) -> str:
    for _ in range(20):
        blk = machine.cmd("blk")
        if "disk:" in blk:
            break
        time.sleep(0.15)
    last = ""
    for _ in range(4):
        last = machine.cmd("vfs mount")
        if "vfs mount   : / <- cassafs" in last:
            return last
        time.sleep(0.3)
    return last


def shutdown_clean(machine: Machine) -> None:
    poweroff, code = machine.shutdown()
    check("clean shutdown complete" in poweroff and code == 0,
          "guest did not shut down cleanly:\n" + poweroff[-2000:])


def host_verify(disk: Path) -> str:
    tool = ROOT / "zig-out" / "bin" / "cassafs"
    check(tool.exists(), f"host verifier missing: {tool}; run zig build")
    result = subprocess.run(
        [str(tool), "verify", "--image", str(disk), "--partition", "1"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    text = result.stdout + result.stderr
    check(result.returncode == 0 and "PASS" in text,
          "host verifier did not accept the written volume:\n" + text[-3000:])
    return text


def write_scenario() -> None:
    work, disk = prepare_formatted("write")
    machine = Machine("write", disk)
    try:
        mount = mount_ready(machine)
        check("5 inode(s), 2 file(s), 158 data byte(s)" in mount,
              "demo volume counters changed before the write:\n" + mount[-3000:])

        create = machine.cmd("vfs create /catalog/note.txt")
        check("vfs create  : /catalog/note.txt (inode 6, parent 2" in create,
              "file create failed:\n" + create[-3000:])
        check("out of space" not in create.lower(), "create unexpectedly ran out of space")

        write = machine.cmd("vfs write /catalog/note.txt 0 hello43")
        check("wrote 7 byte(s), size 7 B" in write, "first write failed:\n" + write[-3000:])
        note = machine.cmd("vfs cat /catalog/note.txt")
        nsize, ncrc = cat_summary(note, "/catalog/note.txt")
        check(nsize == 7 and "hello43" in note, "first read-back diverged:\n" + note[-3000:])
        log(f"      first write: {nsize} bytes, CRC32C {ncrc}")

        overwrite = machine.cmd("vfs write /catalog/note.txt 5 43!")
        check("wrote 3 byte(s), size 8 B" in overwrite,
              "offset overwrite/extend failed:\n" + overwrite[-3000:])
        updated = machine.cmd("vfs cat /catalog/note.txt")
        usize, ucrc = cat_summary(updated, "/catalog/note.txt")
        check(usize == 8 and "hello43!" in updated,
              "overwritten bytes diverged:\n" + updated[-3000:])
        log(f"      overwrite: {usize} bytes, CRC32C {ucrc}")

        stat = machine.cmd("vfs stat /catalog/note.txt")
        check("type file, inode 6, parent 2, size 8 B, mode 0o100644" in stat,
              "stat after writes is wrong:\n" + stat[-3000:])
        reference = machine.cmd("cassafs cat /catalog/note.txt")
        check(cassafs_cat_summary(reference, "/catalog/note.txt") == (usize, ucrc),
              "cassafs cat differs from the VFS read after write:\n" + reference[-3000:])

        # The phase-42 demo files must remain byte-identical while the log grows.
        products = machine.cmd("vfs cat /catalog/products.db")
        check(cat_summary(products, "/catalog/products.db") == (PRODUCTS_SIZE, PRODUCTS_CRC),
              "products.db changed while writing a new file:\n" + products[-3000:])
        welcome = machine.cmd("vfs cat /receipts/WELCOME.TXT")
        wsize, wcrc = cat_summary(welcome, "/receipts/WELCOME.TXT")
        check(wsize == 85, "welcome file size changed unexpectedly:\n" + welcome[-3000:])

        # Refusals: a missing path, a directory write, and a volume that was
        # deliberately damaged all have to name their reason, not panic.
        check("no such file or directory" in machine.cmd("vfs write /catalog/missing 0 x"),
              "write to a missing path did not report NotFound")
        check("is a directory" in machine.cmd("vfs write /catalog 0 x"),
              "write to a directory did not report IsDirectory")
        check("no such file or directory" in machine.cmd("vfs stat /catalog/missing"),
              "stat of a missing path did not report NotFound")

        df = machine.cmd("vfs df")
        check("block(s)" in df and "free" in df, "df did not report free space:\n" + df[-2000:])
        check("vfs selftest: PASS" in machine.cmd("vfs selftest"),
              "post-write VFS selftest failed")

        unmount = machine.cmd("vfs unmount")
        check("vfs unmount : / removed" in unmount, "unmount failed:\n" + unmount[-2000:])
        remount = mount_ready(machine)
        check("6 inode(s), 3 file(s), 166 data byte(s)" in remount,
              "remount did not see the committed data:\n" + remount[-3000:])
        after_remount = machine.cmd("vfs cat /catalog/note.txt")
        check(cat_summary(after_remount, "/catalog/note.txt") == (usize, ucrc),
              "bytes changed across unmount/remount:\n" + after_remount[-3000:])

        machine.reboot()
        reboot_mount = mount_ready(machine)
        check("6 inode(s), 3 file(s), 166 data byte(s)" in reboot_mount,
              "soft reboot did not mount the committed state:\n" + reboot_mount[-3000:])
        after_reboot = machine.cmd("vfs cat /catalog/note.txt")
        check(cat_summary(after_reboot, "/catalog/note.txt") == (usize, ucrc),
              "written bytes changed across a soft reboot:\n" + after_reboot[-3000:])
        check("hello43!" in after_reboot, "soft-reboot payload is wrong")
        check(cat_summary(machine.cmd("vfs cat /catalog/products.db"), "/catalog/products.db")
              == (PRODUCTS_SIZE, PRODUCTS_CRC), "products.db changed across reboot")
        check(cat_summary(machine.cmd("vfs cat /receipts/WELCOME.TXT"), "/receipts/WELCOME.TXT")
              == (wsize, wcrc), "welcome file changed across reboot")
        shutdown_clean(machine)

        verify = host_verify(disk)
        check("PASS" in verify, "host verifier output lacked PASS")
        log(f"      create/write/overwrite: note.txt {usize} bytes CRC32C {ucrc}; remount + reboot + host verify")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def out_of_space_scenario() -> None:
    work = Path(tempfile.mkdtemp(prefix="cassa-vfs-write-full-"))
    disk = work / "tiny.img"
    make_tiny_disk(disk)
    formatter = Machine("tiny-format", disk)
    try:
        formatted = formatter.cmd("cassafs format empty", 25.0)
        check("format      : OK" in formatted, "tiny volume format failed:\n" + formatted[-2500:])
        shutdown_clean(formatter)
    finally:
        formatter.close()

    machine = Machine("tiny", disk)
    try:
        mount = tiny_mount_ready(machine)
        check("1 inode(s), 0 file(s), 0 data byte(s)" in mount,
              "tiny volume did not mount empty:\n" + mount[-2500:])
        df = machine.cmd("vfs df")
        check("log head 8/8 block(s), 0 free" in df,
              "tiny volume did not report full free space:\n" + df[-2500:])
        full = machine.cmd("vfs create /full")
        check("out of space" in full, "out-of-space create did not refuse:\n" + full[-2500:])
        check("no such file or directory" in machine.cmd("vfs stat /full"),
              "out-of-space create left a visible file")
        root_ls = machine.cmd("vfs ls /")
        check("0 entries" in root_ls, "out-of-space create left a directory entry:\n" + root_ls[-2500:])
        check("self-tests: PASS" in machine.cmd("selftest"),
              "kernel self-tests failed on the full volume")
        shutdown_clean(machine)
        log("      tiny 8-block volume: 0 free, create /full refused with 'out of space'")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def corruption_scenario() -> None:
    work, disk = prepare_formatted("write-corrupt")
    try:
        # First create a committed file, then damage its payload on the medium.
        # Mount must run the same CRC/tree/extent scan as phase 42 and refuse
        # the whole written volume before exposing anything.
        preparer = Machine("write-corrupt-prepare", disk)
        try:
            mount_ready(preparer)
            check("vfs create  : /catalog/corrupt.bin" in preparer.cmd("vfs create /catalog/corrupt.bin"),
                  "corruption fixture create failed")
            check("wrote 13 byte(s)" in preparer.cmd("vfs write /catalog/corrupt.bin 0 corruption-43"),
                  "corruption fixture write failed")
            shutdown_clean(preparer)
        finally:
            preparer.close()
        image = disk.read_bytes()
        payload = b"corruption-43"
        offset = image.find(payload)
        check(offset >= 0, "could not locate the committed payload on the medium")
        with disk.open("r+b") as f:
            f.seek(offset)
            byte = f.read(1)
            f.seek(offset)
            f.write(bytes([byte[0] ^ 0xFF]))
        machine = Machine("write-corrupt", disk)
        try:
            mount = machine.cmd("vfs mount")
            check("vfs mount   : refused" in mount, "corrupt written volume falsely mounted:\n" + mount[-2500:])
            check("CRC32C mismatch; the volume is damaged" in mount,
                  "corrupt mount did not name CRC32C:\n" + mount[-2500:])
            check("no mounts" in machine.cmd("vfs info"), "corrupt mount left a table entry")
            check("self-tests: PASS" in machine.cmd("selftest"),
                  "kernel self-tests failed after the corrupt mount refusal")
            log("      committed file payload damaged on medium: refused with CRC32C, table stayed empty")
        finally:
            machine.close()
    finally:
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def screenshot_scenario() -> None:
    work, disk = prepare_formatted("write-screenshot")
    machine = Machine("write-screenshot", disk)
    try:
        mount_ready(machine)
        check("vfs create  : /catalog/note.txt" in machine.cmd("vfs create /catalog/note.txt"),
              "screenshot create failed")
        check("size 15 B" in machine.cmd("vfs write /catalog/note.txt 0 phase43-writes!"),
              "screenshot write failed")
        machine.cmd("vfs cat /catalog/note.txt")
        machine.cmd("vfs viz 3", 15.0)
        shot = SHOT_DIR / "phase43-write.png"
        ppm = machine.dir / "vfs-write-viz.ppm"
        machine.qmp.screendump(ppm)
        deadline = time.time() + 5
        while not ppm.exists() and time.time() < deadline:
            time.sleep(0.05)
        check(ppm.exists(), "screendump did not produce a frame")
        SHOT_DIR.mkdir(parents=True, exist_ok=True)
        try:
            from PIL import Image
        except ImportError as exc:
            raise Failure(f"Pillow is required to convert the dashboard frame: {exc}")
        with Image.open(ppm) as image:
            check(image.width >= 1280 and image.height >= 800,
                  f"dashboard frame is unexpectedly small: {image.size}")
            image.save(shot)
        log(f"      evidence: {shot.relative_to(ROOT)}")
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
    scenarios = [
        ("main", write_scenario),
        ("out-of-space", out_of_space_scenario),
        ("corruption", corruption_scenario),
        ("screenshot", screenshot_scenario),
    ]
    only = None
    if "--only" in sys.argv:
        index = sys.argv.index("--only")
        if index + 1 < len(sys.argv):
            only = sys.argv[index + 1]
    try:
        for name, scenario in scenarios:
            if only is not None and name != only:
                continue
            log(f"[{name}]")
            scenario()
            log(f"[ok]   {name}")
    except Failure as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 43 CASSAFS write evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
