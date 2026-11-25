#!/usr/bin/env python3
"""Phase 45 FAT32 reader and catalog-import evidence harness.

The real aarch64 kernel boots a two-partition disk: partition 1 is the
CASSAFS root, partition 2 is a foreign-formatted FAT32 volume with a long-name
catalog file larger than the old whole-file buffer. The harness mounts the FAT32
volume read-only at /media/usb through the VFS, proves LFN lookup and cluster
reads, streams all 10,000 CSV rows through the bounded catalog importer, and
checks that writes are refused. It then unmounts/remounts, soft-reboots and
imports again, and finally corrupts the file's FAT chain to prove the reader
refuses bad data instead of returning a partial catalog.

Usage:  python3 tools/qemu_fat32_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_fat32_test.py
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from qemu_vfs_test import (
    KERNEL,
    QEMU,
    ROOT,
    SHOT_DIR,
    Failure,
    Machine,
    check,
    log,
    make_disk,
    mount_ready,
    prepare_formatted,
)
from qemu_vfs_write_test import shutdown_clean

SECTOR = 512
CASSA_START = 2048
CASSA_SECTORS = 131072
FAT_START = CASSA_START + CASSA_SECTORS
FAT_SECTORS = 204800
FAT_OFFSET = FAT_START * SECTOR
ROWS = 10_000
LONG_NAME = "store-catalog-2026.csv"
SHORT_NAME = b"STOREC~1CSV"
EXPECTED_CRC = None


class Geometry:
    def __init__(self, total: int, bps: int = 512, spc: int = 1, reserved: int = 32, fats: int = 2):
        self.total = total
        self.bps = bps
        self.spc = spc
        self.reserved = reserved
        self.fats = fats
        self.fat_sectors = 1
        while True:
            clusters = (self.total - self.reserved - self.fats * self.fat_sectors) // self.spc
            needed = ((clusters + 2) * 4 + self.bps - 1) // self.bps
            if needed == self.fat_sectors:
                break
            self.fat_sectors = needed
        self.data_start = self.reserved + self.fats * self.fat_sectors
        self.clusters = (self.total - self.data_start) // self.spc
        self.cluster_bytes = self.bps * self.spc

    @property
    def volume_bytes(self) -> int:
        return self.total * self.bps


def catalog_bytes() -> bytes:
    out = bytearray(b"sku,name,price_cents\n")
    for i in range(ROWS):
        out += f"{100000 + i:06d},Item {i:05d},100\n".encode()
    return bytes(out)


def crc32c(data: bytes) -> int:
    c = 0xFFFFFFFF
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
    return c ^ 0xFFFFFFFF


def put16(buf: bytearray, off: int, value: int) -> None:
    buf[off:off + 2] = value.to_bytes(2, "little")


def put32(buf: bytearray, off: int, value: int) -> None:
    buf[off:off + 4] = value.to_bytes(4, "little")


def lfn_checksum(short: bytes) -> int:
    value = 0
    for byte in short:
        value = (((value & 1) << 7) + (value >> 1) + byte) & 0xFF
    return value


def lfn_entries(name: str, short: bytes) -> bytearray:
    checksum = lfn_checksum(short)
    chunks = (len(name) + 12) // 13
    out = bytearray()
    offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
    for seq in range(chunks, 0, -1):
        raw = bytearray(b"\xff" * 32)
        raw[0] = seq | (0x40 if seq == chunks else 0)
        raw[11] = 0x0F
        raw[13] = checksum
        for k, off in enumerate(offsets):
            index = (seq - 1) * 13 + k
            code = ord(name[index]) if index < len(name) else (0 if index == len(name) else 0xFFFF)
            put16(raw, off, code)
        out += raw
    return out


def short_entry(short: bytes, cluster: int, size: int) -> bytearray:
    raw = bytearray(32)
    raw[0:11] = short
    raw[11] = 0x20
    put16(raw, 20, (cluster >> 16) & 0xFFFF)
    put16(raw, 26, cluster & 0xFFFF)
    put32(raw, 28, size)
    return raw


def build_fat32(total_sectors: int = FAT_SECTORS) -> tuple[bytearray, Geometry]:
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
    put32(boot, 44, 2)            # root cluster
    put16(boot, 48, 1)            # FSInfo
    put16(boot, 50, 6)            # backup boot sector
    boot[64] = 0x80
    boot[66] = 0x29
    put32(boot, 67, 0xCA55A045)
    boot[71:82] = b"CASSA-USB  "
    boot[82:90] = b"FAT32   "
    boot[510:512] = b"\x55\xaa"
    part[0:512] = boot
    part[6 * 512:7 * 512] = boot

    data = catalog_bytes()
    global EXPECTED_CRC
    EXPECTED_CRC = crc32c(data)
    file_clusters = (len(data) + geo.cluster_bytes - 1) // geo.cluster_bytes
    first_cluster = 3
    if first_cluster + file_clusters > geo.clusters + 2:
        raise Failure("FAT32 fixture file does not fit the volume")

    def set_fat(cluster: int, value: int) -> None:
        for copy in range(geo.fats):
            off = (geo.reserved + copy * geo.fat_sectors) * geo.bps + cluster * 4
            put32(part, off, value)

    set_fat(0, 0x0FFFFFF8)
    set_fat(1, 0x0FFFFFFF)
    set_fat(2, 0x0FFFFFFF)
    for i in range(file_clusters):
        cluster = first_cluster + i
        set_fat(cluster, cluster + 1 if i + 1 < file_clusters else 0x0FFFFFFF)

    root_off = (geo.data_start + (2 - 2) * geo.spc) * geo.bps
    directory = lfn_entries(LONG_NAME, SHORT_NAME)
    directory += short_entry(SHORT_NAME, first_cluster, len(data))
    directory += b"\x00" * 32
    if len(directory) > geo.cluster_bytes:
        raise Failure("FAT32 fixture directory does not fit one cluster")
    part[root_off:root_off + len(directory)] = directory

    data_off = (geo.data_start + (first_cluster - 2) * geo.spc) * geo.bps
    part[data_off:data_off + len(data)] = data

    info = bytearray(512)
    put32(info, 0, 0x41615252)
    put32(info, 484, 0x61417272)
    free = geo.clusters - 1 - file_clusters
    put32(info, 488, free)
    put32(info, 492, first_cluster + file_clusters)
    put32(info, 508, 0xAA550000)
    part[1 * 512:2 * 512] = info
    part[7 * 512:8 * 512] = info
    return part, geo


def make_two_partition_disk(path: Path) -> Geometry:
    part, geo = build_fat32()
    image = bytearray((FAT_START + FAT_SECTORS) * SECTOR)
    # Partition 1: CASSAFS root, same geometry the phase-42..44 harnesses use.
    image[446] = 0x80
    image[450] = 0x7F
    image[454:458] = CASSA_START.to_bytes(4, "little")
    image[458:462] = CASSA_SECTORS.to_bytes(4, "little")
    # Partition 2: foreign FAT32 stick.
    image[462] = 0x00
    image[466] = 0x0C
    image[470:474] = FAT_START.to_bytes(4, "little")
    image[474:478] = FAT_SECTORS.to_bytes(4, "little")
    image[510:512] = b"\x55\xaa"
    image[FAT_OFFSET:FAT_OFFSET + len(part)] = part
    path.write_bytes(image)
    return geo


def prepare_fat_disk(tag: str) -> tuple[Path, Path, Geometry]:
    work = Path(tempfile.mkdtemp(prefix=f"cassa-fat32-{tag}-"))
    disk = work / "two-part.img"
    geo = make_two_partition_disk(disk)
    formatter = Machine(f"{tag}-format", disk)
    try:
        formatted = formatter.cmd("cassafs format demo", 30.0)
        check("format      : OK" in formatted, "CASSAFS root format failed:\n" + formatted[-2500:])
        shutdown_clean(formatter)
    finally:
        formatter.close()
    return work, disk, geo


IMPORT_RE = re.compile(
    r"vfs import\s+:\s+(\d+)\s+data row\(s\),\s+(\d+)\s+line\(s\),\s+"
    r"(\d+)\s+byte\(s\), max line (\d+), CRC32C (0x[0-9a-f]{8})"
)


def check_import(machine: Machine, geo: Geometry, data: bytes) -> str:
    output = machine.cmd(f"vfs import /media/usb/{LONG_NAME}", 45.0)
    match = IMPORT_RE.search(output)
    check(match is not None, "catalog import summary missing:\n" + output[-3500:])
    rows = int(match.group(1))
    lines = int(match.group(2))
    size = int(match.group(3))
    max_line = int(match.group(4))
    crc = int(match.group(5), 16)
    check(rows == ROWS, f"catalog import read {rows} data rows, expected {ROWS}")
    check(lines == ROWS + 1, f"catalog import read {lines} lines, expected {ROWS + 1}")
    check(size == len(data), f"catalog import read {size} bytes, expected {len(data)}")
    check(max_line <= 255, f"catalog parser exceeded its line bound: {max_line}")
    check(crc == EXPECTED_CRC, f"catalog CRC is {crc:#010x}, expected {EXPECTED_CRC:#010x}")
    check("PASS" in output, "catalog import did not report PASS")
    log(f"      import: {rows} rows, {size} B, max line {max_line}, CRC32C {crc:#010x}")
    return output


def main_scenario() -> None:
    work, disk, geo = prepare_fat_disk("main")
    data = catalog_bytes()
    check(len(data) > 64 * 1024, "fixture must be larger than the old 64 KiB whole-file buffer")
    machine = Machine("fat32-main", disk)
    try:
        mount_ready(machine)
        usb = machine.cmd("vfs mount usb")
        check("vfs mount   : /media/usb <- fat32" in usb, "FAT32 mount failed:\n" + usb[-3000:])
        check("read-only" in usb, "FAT32 mount did not announce read-only")
        check("mount table 2/8" in usb, "FAT32 mount did not record a second mount:\n" + usb[-2500:])
        check("B/cluster" in usb and "cluster(s)" in usb, "FAT32 geometry was not reported")

        info = machine.cmd("vfs info")
        check("/media/usb <- fat32, read-only" in info,
              "vfs info did not report the FAT32 mount:\n" + info[-3000:])
        check("5 inode(s), 3 dir(s), 2 file(s), 158 data byte(s)" in info,
              "vfs info lost the CASSAFS root counters:\n" + info[-3000:])

        listing = machine.cmd("vfs ls /media/usb")
        check(LONG_NAME in listing, "FAT32 LFN was not decoded in readdir:\n" + listing[-3000:])
        check(f"size {len(data)}" in listing, "FAT32 readdir reported the wrong file size")
        stat = machine.cmd(f"vfs stat /media/usb/{LONG_NAME}")
        check(f"type file, inode" in stat and f"size {len(data)} B" in stat,
              "FAT32 stat did not report the file:\n" + stat[-2500:])
        check("mode 0o100444" in stat, "FAT32 file was not presented as read-only")
        check("parent 1" in stat, "FAT32 file parent is not the mounted root")

        head = machine.cmd(f"vfs read /media/usb/{LONG_NAME} 0 64")
        check("requested 64, returned 64 byte(s)" in head,
              "FAT32 range read returned the wrong length:\n" + head[-2500:])
        check("sku,name,price_cents" in head, "FAT32 range read returned the wrong header bytes")

        check_import(machine, geo, data)

        write = machine.cmd(f"vfs write /media/usb/{LONG_NAME} 0 x")
        check("this filesystem is read-only" in write,
              "write to FAT32 did not refuse as read-only:\n" + write[-2500:])
        create = machine.cmd("vfs create /media/usb/new.csv")
        check("this filesystem is read-only" in create,
              "create on FAT32 did not refuse as read-only:\n" + create[-2500:])

        unmount = machine.cmd("vfs unmount usb")
        check("vfs unmount : /media/usb removed" in unmount,
              "FAT32 unmount failed:\n" + unmount[-2500:])
        info_after = machine.cmd("vfs info")
        check("/media/usb <- fat32" not in info_after, "FAT32 mount remained visible after unmount")
        check("vfs cat" not in info_after, "invalid sentinel")

        remount = machine.cmd("vfs mount usb")
        check("vfs mount   : /media/usb <- fat32" in remount,
              "FAT32 remount failed:\n" + remount[-2500:])
        check_import(machine, geo, data)

        selftest = machine.cmd("vfs selftest")
        check("vfs selftest: PASS" in selftest, "VFS selftest failed with FAT32 attached:\n" + selftest[-4000:])
        check("FAT32 readdir decodes a long file name" in selftest,
              "selftest did not prove LFN readdir")
        check("FAT32 write open is refused as read-only" in selftest,
              "selftest did not prove read-only enforcement")

        machine.reboot()
        mount_ready(machine)
        check("vfs mount   : /media/usb <- fat32" in machine.cmd("vfs mount usb"),
              "FAT32 did not mount after a soft reboot")
        check_import(machine, geo, data)
        shutdown_clean(machine)
        log("      long-name lookup, 10k-row stream, read-only refusal, unmount/remount and soft reboot: PASS")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def corruption_scenario() -> None:
    work, disk, geo = prepare_fat_disk("corrupt")
    data = catalog_bytes()
    # Break the first file chain entry in the primary FAT: cluster 3 points at
    # itself. Mount still sees valid BPB/FAT geometry, but reading must refuse.
    fat_entry = FAT_OFFSET + geo.reserved * SECTOR + 3 * 4
    with disk.open("r+b") as f:
        f.seek(fat_entry)
        f.write((3).to_bytes(4, "little"))
    machine = Machine("fat32-corrupt", disk)
    try:
        mount_ready(machine)
        check("vfs mount   : /media/usb <- fat32" in machine.cmd("vfs mount usb"),
              "corrupt-chain FAT32 mount was refused too early")
        bad = machine.cmd(f"vfs import /media/usb/{LONG_NAME}", 30.0)
        check("PASS" not in bad, "corrupt FAT chain was reported as a successful import:\n" + bad[-3000:])
        check("integrity failure" in bad or "read failed" in bad,
              "corrupt FAT chain did not report corruption:\n" + bad[-3000:])
        good = machine.cmd("vfs cat /catalog/products.db")
        check("73 byte(s)" in good and "0x3b60dc1d" in good,
              "CASSAFS root was damaged by the FAT32 corruption path:\n" + good[-2500:])
        log("      looped FAT chain: import refused with corruption, CASSAFS root intact")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def no_partition_scenario() -> None:
    work, disk = prepare_formatted("fat32-one-part")
    machine = Machine("fat32-one-part", disk)
    try:
        mount_ready(machine)
        missing = machine.cmd("vfs mount usb")
        check("no FAT32 partition 2" in missing,
              "mount with no second partition did not name the absence:\n" + missing[-2500:])
        check("this filesystem is read-only" not in missing, "missing partition was treated as a mounted volume")
        check("73 byte(s)" in machine.cmd("vfs cat /catalog/products.db"),
              "CASSAFS root became unreadable after the USB mount refusal")
        log("      one-partition disk: USB mount refused, CASSAFS root still readable")
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
        no_partition_scenario()
    except Failure as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 45 FAT32 reader evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
