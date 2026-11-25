#!/usr/bin/env python3
"""Phase 42 VFS mount/read evidence harness.

The real aarch64 kernel is booted under QEMU. The harness formats a CASSAFS
volume, mounts it through the kernel VFS, walks the directory tree, reads both
demo files through opened handles, checks the honest refusal paths, unmounts and
remounts, then soft-reboots QEMU and repeats the mount/read to prove the volume
and bytes survived.

Usage:  python3 tools/qemu_vfs_test.py [--only NAME] [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_vfs_test.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "zig-out" / "bin" / "cassa.bin"
SHOT_DIR = ROOT / "docs" / "screenshots"
QEMU = os.environ.get("QEMU") or str(Path.home() / "local/usr/bin/qemu-system-aarch64")
if not Path(QEMU).exists():
    QEMU = shutil.which("qemu-system-aarch64") or QEMU
LIB = os.environ.get("QEMU_LIB") or str(Path.home() / "local/usr/lib/x86_64-linux-gnu")

COMMON = [
    "-machine", "virt", "-cpu", "cortex-a53", "-m", "512M", "-smp", "4",
    "-display", "none", "-nic", "none",
    "-global", "virtio-mmio.force-legacy=false",
    "-device", "bochs-display,romfile=,xres=1280,yres=800",
]
SECTOR = 512
PART_START = 2048
PART_SECTORS = 131072
PART_OFFSET = PART_START * SECTOR
PART_BYTES = PART_SECTORS * SECTOR
BLOCK = 4096
DATA_RECORD = 6
PRODUCTS_CRC = "0x3b60dc1d"
PRODUCTS_SIZE = 73


class Failure(Exception):
    pass


def log(message: str) -> None:
    print(message, flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def make_disk(path: Path) -> None:
    image = bytearray(PART_OFFSET + PART_BYTES)
    image[446] = 0x80
    image[450] = 0x7F
    image[454:458] = PART_START.to_bytes(4, "little")
    image[458:462] = PART_SECTORS.to_bytes(4, "little")
    image[510] = 0x55
    image[511] = 0xAA
    path.write_bytes(image)


def wait_socket(path: str, timeout: float = 20.0) -> socket.socket:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            return sock
        except OSError as exc:
            last = exc
            time.sleep(0.03)
    raise Failure(f"did not connect to {path}: {last}")


class Serial:
    def __init__(self, path: str):
        self.sock = wait_socket(path)
        self.sock.settimeout(0.2)
        self.buffer = ""

    def pump(self) -> bool:
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return False
        if not data:
            return False
        self.buffer += data.decode(errors="replace")
        return True

    def drain(self, seconds: float = 0.25) -> str:
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.pump()
        text = self.buffer
        self.buffer = ""
        return text

    def until(self, needle: str, timeout: float = 20.0) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            index = self.buffer.find(needle)
            if index >= 0:
                end = index + len(needle)
                found = self.buffer[:end]
                self.buffer = self.buffer[end:]
                return found
            self.pump()
        raise Failure(f"timed out waiting for {needle!r}; tail:\n{self.buffer[-4000:]}")

    def send(self, line: str) -> None:
        self.sock.sendall(line.encode() + b"\n")


class Qmp:
    def __init__(self, path: str):
        self.sock = wait_socket(path)
        self.file = self.sock.makefile("rwb")
        self._read()
        self.call("qmp_capabilities")

    def _read(self) -> dict:
        line = self.file.readline()
        if not line:
            raise Failure("QMP closed unexpectedly")
        message = json.loads(line)
        if "error" in message:
            raise Failure(f"QMP error: {message['error']}")
        return message

    def call(self, name: str, arguments: dict | None = None):
        request = {"execute": name}
        if arguments is not None:
            request["arguments"] = arguments
        self.file.write(json.dumps(request).encode() + b"\n")
        self.file.flush()
        while True:
            message = self._read()
            if "return" in message:
                return message["return"]

    def screendump(self, path: Path) -> None:
        self.call("screendump", {"filename": str(path)})


class Machine:
    def __init__(self, tag: str, disk_path: Path | None, disk: bool = True):
        self.tag = tag
        self.dir = Path(tempfile.mkdtemp(prefix=f"cassa-vfs-{tag}-"))
        self.serial_path = str(self.dir / "serial.sock")
        self.qmp_path = str(self.dir / "qmp.sock")
        self.disk_path = disk_path
        env = os.environ.copy()
        if Path(LIB).is_dir():
            env["LD_LIBRARY_PATH"] = LIB + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        argv = [QEMU, *COMMON]
        if disk and disk_path is not None:
            argv += [
                "-drive", f"if=none,file={disk_path},format=raw,id=hd0",
                "-device", "virtio-blk-device,drive=hd0",
            ]
        argv += [
            "-serial", f"unix:{self.serial_path},server=on,wait=off",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-kernel", str(KERNEL),
        ]
        log(f"[{tag}] starting qemu (disk={disk})")
        self.proc = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        self.serial = Serial(self.serial_path)
        self.qmp = Qmp(self.qmp_path)
        self.serial_commands = 0
        self.boot = self.serial.until("shell    thread", 30.0)
        self.boot += self.ready_handshake()
        log(f"[{tag}] booted to shell prompt")

    def ready_handshake(self) -> str:
        time.sleep(0.3)
        token = "__CASSA_READY__"
        self.serial.send("echo " + token)
        first = self.serial.until(token, 10.0)
        second = self.serial.until(token, 10.0)
        return first + second

    def cmd(self, line: str, timeout: float = 25.0) -> str:
        self.serial.drain()
        self.serial_commands += 1
        token = f"__CASSA_DONE_{self.serial_commands}__"
        self.serial.send(line)
        self.serial.send("echo " + token)
        first = self.serial.until(token, timeout)
        second = self.serial.until(token, timeout)
        return first + second

    def reboot(self) -> str:
        self.serial.drain()
        self.serial.send("reboot")
        self.serial.until("resetting...", 10.0)
        self.boot = self.serial.until("shell    thread", 30.0)
        return self.boot + self.ready_handshake()

    def shutdown(self) -> tuple[str, int]:
        self.serial.drain()
        self.serial.send("poweroff")
        text = self.serial.until("clean shutdown complete", 25.0)
        try:
            code = self.proc.wait(timeout=15.0)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            raise Failure(f"[{self.tag}] QEMU did not exit after shutdown")
        return text, code

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if "--keep" not in sys.argv:
            shutil.rmtree(self.dir, ignore_errors=True)


def mount_ready(machine: "Machine") -> str:
    """Wait out a possible virtio device/serial startup race, then fail loudly.

    The kernel prints its shell prompt before a just-attached virtio-blk device
    has necessarily completed its first probe in a loaded CI VM. A real bad
    volume still fails all three attempts, and the last output is retained for
    the assertion message.
    """
    # First wait until the virtio-blk driver has completed capacity probing;
    # in a loaded CI VM the shell prompt can be visible before that.
    for _ in range(20):
        blk = machine.cmd("blk")
        match = re.search(r"disk: (\d+) sector\(s\)", blk)
        if match is not None and int(match.group(1)) >= 4096:
            break
        time.sleep(0.15)

    last = ""
    for _ in range(4):
        last = machine.cmd("vfs mount")
        if "vfs mount   : / <- cassafs" in last:
            return last
        time.sleep(0.5)
    return last


def cat_summary(output: str, path: str) -> tuple[int, str]:
    pattern = re.compile(
        rf"vfs cat\s+:\s+{re.escape(path)},\s+(\d+)\s+byte\(s\),\s+CRC32C\s+(0x[0-9a-f]{{8}})"
    )
    match = pattern.search(output)
    check(match is not None, f"cat summary for {path} missing:\n{output[-2500:]}")
    return int(match.group(1)), match.group(2)


def cassafs_cat_summary(output: str, path: str) -> tuple[int, str]:
    pattern = re.compile(
        rf"cassafs cat\s+:\s+{re.escape(path)},\s+(\d+)\s+byte\(s\),\s+CRC32C\s+(0x[0-9a-f]{{8}})"
    )
    match = pattern.search(output)
    check(match is not None, f"cassafs cat summary for {path} missing:\n{output[-2500:]}")
    return int(match.group(1)), match.group(2)


def directory_entries(output: str) -> list[str]:
    lines = []
    for line in output.splitlines():
        if line.startswith("              : ["):
            lines.append(line)
    return lines


def prepare_formatted(tag: str) -> tuple[Machine, Path, Path]:
    work = Path(tempfile.mkdtemp(prefix=f"cassa-vfs-{tag}-"))
    disk = work / "cassafs.img"
    make_disk(disk)
    machine = Machine(tag + "-format", disk)
    try:
        formatted = machine.cmd("cassafs format demo", 25.0)
        check("format      : OK" in formatted, "CASSAFS format failed:\n" + formatted[-2500:])
        poweroff, code = machine.shutdown()
        check("clean shutdown complete" in poweroff and code == 0,
              "format preparation did not shut down cleanly")
    finally:
        machine.close()
    return work, disk


def main_scenario() -> None:
    work = Path(tempfile.mkdtemp(prefix="cassa-vfs-main-"))
    disk = work / "cassafs.img"
    make_disk(disk)
    machine = Machine("main", disk)
    try:
        formatted = machine.cmd("cassafs format demo", 25.0)
        check("format      : OK" in formatted, "CASSAFS format failed:\n" + formatted[-2500:])
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "CASSAFS did not mount:\n" + mount[-2500:])
        check("mount table 1/1" in mount, "mount table did not record the mount:\n" + mount[-2500:])

        info = machine.cmd("vfs info")
        check("mount / <- cassafs (root ino 1)" in info, "VFS info did not report the root:\n" + info[-2500:])
        check("5 inode(s), 3 dir(s), 2 file(s), 158 data byte(s)" in info,
              "VFS info counters are wrong:\n" + info[-2500:])

        root_ls = machine.cmd("vfs ls /")
        check("catalog/" in root_ls and "receipts/" in root_ls,
              "root readdir did not show both directories:\n" + root_ls[-2500:])
        first_entries = directory_entries(root_ls)
        second_entries = directory_entries(machine.cmd("vfs ls /"))
        check(first_entries == second_entries, "root readdir ordering is not stable")
        check(len(first_entries) == 2, "root readdir returned the wrong number of entries")

        catalog_ls = machine.cmd("vfs ls /catalog")
        check("products.db" in catalog_ls, "catalog readdir did not show products.db:\n" + catalog_ls[-2500:])
        check("file; readdir requires a directory" in machine.cmd("vfs ls /catalog/products.db"),
              "readdir on a file did not refuse")

        stat = machine.cmd("vfs stat /catalog/products.db")
        check("type file, inode 3, parent 2, size 73 B" in stat,
              "stat did not report inode/parent/size:\n" + stat[-2500:])
        check("mode 0o100644" in stat, "stat did not report the read-only mode:\n" + stat[-2500:])

        products = machine.cmd("vfs cat /catalog/products.db")
        psize, pcrc = cat_summary(products, "/catalog/products.db")
        check(psize == PRODUCTS_SIZE and pcrc == PRODUCTS_CRC,
              f"products.db through VFS is {psize} bytes/{pcrc}, expected {PRODUCTS_SIZE}/{PRODUCTS_CRC}:\n{products[-2500:]}")
        check("1001,Espresso,250" in products and "1003,Water,150" in products,
              "products.db payload is wrong through VFS:\n" + products[-2500:])
        reference = machine.cmd("cassafs cat /catalog/products.db")
        check(cassafs_cat_summary(reference, "/catalog/products.db") == (psize, pcrc),
              "VFS bytes differ from cassafs cat for products.db:\n" + reference[-2500:])

        welcome = machine.cmd("vfs cat /receipts/WELCOME.TXT")
        wsize, wcrc = cat_summary(welcome, "/receipts/WELCOME.TXT")
        check("Welcome to Cassa POS." in welcome and "phase 41 reference formatter" in welcome,
              "welcome file payload is wrong through VFS:\n" + welcome[-2500:])
        check(wsize > 0, "welcome file is empty")
        reference = machine.cmd("cassafs cat /receipts/WELCOME.TXT")
        check(cassafs_cat_summary(reference, "/receipts/WELCOME.TXT") == (wsize, wcrc),
              "VFS bytes differ from cassafs cat for WELCOME.TXT:\n" + reference[-2500:])

        narrow = machine.cmd("vfs read /catalog/products.db 4 8")
        check("requested 8, returned 8 byte(s)" in narrow,
              "offset read did not return 8 bytes:\n" + narrow[-2500:])
        past = machine.cmd("vfs read /catalog/products.db 73 16")
        check("requested 16, returned 0 byte(s)" in past,
              "read past EOF returned data:\n" + past[-2500:])

        selftest = machine.cmd("vfs selftest")
        check("vfs selftest: PASS" in selftest, "VFS selftest failed:\n" + selftest[-4000:])
        for label in (
            "dot-dot at the root stays at the root",
            "absolute and relative paths normalize identically",
            "readdir on a file is refused",
            "read at EOF returns zero bytes",
            "read past EOF returns zero bytes",
            "write open is refused (read-only access check)",
            "root readdir returns a stable ordered set",
        ):
            check(f"[ok]   {label}" in selftest, f"selftest did not prove: {label}\n" + selftest[-4000:])

        unmount = machine.cmd("vfs unmount")
        check("vfs unmount : / removed" in unmount, "unmount failed:\n" + unmount[-2500:])
        check("no mounts" in machine.cmd("vfs info"), "info still showed a mount after unmount")

        remount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in remount, "remount failed:\n" + remount[-2500:])
        before = machine.cmd("vfs cat /catalog/products.db")
        check(cat_summary(before, "/catalog/products.db") == (PRODUCTS_SIZE, PRODUCTS_CRC),
              "read before reboot changed:\n" + before[-2500:])

        machine.reboot()
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "mount after soft reboot failed:\n" + mount[-2500:])
        after = machine.cmd("vfs cat /catalog/products.db")
        check(cat_summary(after, "/catalog/products.db") == (psize, pcrc),
              "products.db did not survive the soft reboot byte-identically:\n" + after[-2500:])
        welcome_after = machine.cmd("vfs cat /receipts/WELCOME.TXT")
        check(cat_summary(welcome_after, "/receipts/WELCOME.TXT") == (wsize, wcrc),
              "welcome.txt did not survive the soft reboot byte-identically:\n" + welcome_after[-2500:])
        check("vfs selftest: PASS" in machine.cmd("vfs selftest"), "post-reboot VFS selftest failed")
        log("      mount, stable readdir, both files, unmount/remount and soft reboot verified")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def refusal_scenario() -> None:
    machine = Machine("no-disk", None, disk=False)
    try:
        mount = machine.cmd("vfs mount")
        check("no block device; attach a disk with partition 1" in mount,
              "no-disk mount did not report the absence:\n" + mount[-2500:])
        check("vfs mount   : / <- cassafs" not in mount, "no-disk mount falsely succeeded")
        info = machine.cmd("vfs info")
        check("no mounts" in info, "no-disk info falsely showed a mount:\n" + info[-2500:])
        check("vfs selftest: FAIL: no volume mounted" in machine.cmd("vfs selftest"),
              "selftest did not refuse an unmounted volume")
        check("self-tests: PASS" in machine.cmd("selftest"),
              "kernel self-tests did not pass without a disk")
        log("      no disk: mount refused, no mount entry, kernel self-tests PASS")
    finally:
        machine.close()

    work, disk = prepare_formatted("bad-crc")
    try:
        offset = PART_OFFSET + (DATA_RECORD + 1) * BLOCK + 10
        with disk.open("r+b") as f:
            f.seek(offset)
            byte = f.read(1)
            f.seek(offset)
            f.write(bytes([byte[0] ^ 0xFF]))
        machine = Machine("bad-crc", disk)
        try:
            mount = machine.cmd("vfs mount")
            check("vfs mount   : refused" in mount, "bad-CRC mount did not refuse:\n" + mount[-2500:])
            check("CRC32C mismatch; the volume is damaged" in mount,
                  "bad-CRC mount did not name CRC32C:\n" + mount[-2500:])
            check("vfs mount   : / <- cassafs" not in mount, "bad-CRC mount falsely succeeded")
            check("no mounts" in machine.cmd("vfs info"), "bad-CRC mount left a half-mounted entry")
            check("vfs selftest: FAIL: no volume mounted" in machine.cmd("vfs selftest"),
                  "bad-CRC selftest did not refuse the unmounted volume")
            log("      bad CRC: mount refused with CRC32C, table stayed empty")
        finally:
            machine.close()
    finally:
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def screenshot_scenario() -> None:
    work, disk = prepare_formatted("screenshot")
    machine = Machine("screenshot", disk)
    try:
        mount = mount_ready(machine)
        check("vfs mount   : / <- cassafs" in mount, "screenshot volume did not mount:\n" + mount[-3000:])
        # Exercise the read path immediately before the dashboard so it is
        # evidence of a mounted and read filesystem, not just a tree drawing.
        products = machine.cmd("vfs cat /catalog/products.db")
        check("73 byte(s)" in products and "0x3b60dc1d" in products,
              "screenshot products read diverged:\n" + products[-2000:])
        welcome = machine.cmd("vfs cat /receipts/WELCOME.TXT")
        check("85 byte(s)" in welcome, "screenshot welcome read diverged:\n" + welcome[-2000:])
        machine.cmd("vfs viz 3", 15.0)
        shot = SHOT_DIR / "phase42-vfs.png"
        ppm = machine.dir / "vfs-viz.ppm"
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



def fallback_scenario() -> None:
    work, disk = prepare_formatted("fallback")
    try:
        with disk.open("r+b") as f:
            f.seek(PART_OFFSET + BLOCK + 200)
            f.write(b"\xff" * 8)
        machine = Machine("fallback", disk)
        try:
            mount = mount_ready(machine)
            check("vfs mount   : / <- cassafs" in mount, "fallback volume did not mount:\n" + mount[-2500:])
            check("active A (A/B fallback)" in mount, "mount did not report A/B fallback:\n" + mount[-2500:])
            info = machine.cmd("vfs info")
            check("active A (the other superblock copy is damaged)" in info,
                  "VFS info did not report the damaged B copy:\n" + info[-2500:])
            cat = machine.cmd("vfs cat /catalog/products.db")
            check(cat_summary(cat, "/catalog/products.db") == (PRODUCTS_SIZE, PRODUCTS_CRC),
                  "fallback mount read the wrong bytes:\n" + cat[-2500:])
            check("vfs selftest: PASS" in machine.cmd("vfs selftest"),
                  "fallback mount failed the VFS selftest")
            log("      damaged B superblock: mounted via A and read the demo tree")
        finally:
            machine.close()
    finally:
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
        ("main", main_scenario),
        ("refusals", refusal_scenario),
        ("fallback", fallback_scenario),
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
    log("phase 42 VFS evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
