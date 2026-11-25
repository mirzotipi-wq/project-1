#!/usr/bin/env python3
"""Phase 41 CASSAFS format evidence harness.

Boots the real Cassa aarch64 kernel under QEMU and checks the phase promises
end to end:

  * an unformatted partitioned disk is reported as such;
  * `cassafs format demo` writes the log, inode tree, extents and free map;
  * `cassafs info/verify/dump/cat` read the volume back through the kernel;
  * the host reference reader (same Zig library) verifies the image outside
    the guest, including a byte-for-byte CAT of the demo file;
  * the volume survives a clean shutdown and a reboot without reformatting;
  * a damaged superblock B falls back to A and reports the fallback;
  * a corrupted record payload is rejected by CRC32C, never accepted;
  * a machine with no disk reports the absence, refuses CASSAFS operations
    cleanly, still passes its kernel self-tests, and reaches the shell;
  * a framebuffer dashboard screenshot for docs/screenshots.

Usage:  python3 tools/qemu_cassafs_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_cassafs_test.py
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "zig-out" / "bin" / "cassa.bin"
HOST_TOOL = ROOT / "zig-out" / "bin" / "cassafs"
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
SUPER_A = PART_OFFSET
SUPER_B = PART_OFFSET + BLOCK
DATA_RECORD = 6  # products.db record header, payload begins one block later


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
    image[450] = 0x7F  # private CASSAFS partition type
    image[454:458] = PART_START.to_bytes(4, "little")
    image[458:462] = PART_SECTORS.to_bytes(4, "little")
    image[510] = 0x55
    image[511] = 0xAA
    path.write_bytes(image)
    log(f"      disk: {path} ({len(image) // (1024 * 1024)} MiB, CASSAFS partition 1 at LBA {PART_START})")


def host_tool(*args: str, timeout: float = 20.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(HOST_TOOL), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def host_verify(image: Path) -> str:
    result = host_tool("verify", "--image", str(image), "--partition", "1")
    check(result.returncode == 0, f"host cassafs verify failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def host_cat(image: Path, path: str) -> str:
    result = host_tool("cat", "--image", str(image), "--partition", "1", "--path", path)
    check(result.returncode == 0, f"host cassafs cat failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


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
        out = self.buffer
        self.buffer = ""
        return out

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
        raise Failure(f"timed out waiting for {needle!r}; tail:\n{self.buffer[-3000:]}")

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
        self.dir = Path(tempfile.mkdtemp(prefix=f"cassa-cfs-{tag}-"))
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
            "-no-reboot",
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

    def cmd(self, line: str, timeout: float = 20.0) -> str:
        self.serial.drain()
        self.serial_commands += 1
        token = f"__CASSA_DONE_{self.serial_commands}__"
        self.serial.send(line)
        self.serial.send("echo " + token)
        first = self.serial.until(token, timeout)
        second = self.serial.until(token, timeout)
        return first + second

    def shutdown(self, timeout: float = 20.0) -> tuple[str, int]:
        self.serial.drain()
        self.serial.send("poweroff")
        text = self.serial.until("clean shutdown complete", timeout)
        return text, self.wait_exit()

    def wait_exit(self, timeout: float = 15.0) -> int:
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            raise Failure(f"[{self.tag}] QEMU did not exit after shutdown")

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


def format_and_verify(machine: Machine) -> None:
    before = machine.cmd("cassafs info")
    check("no valid CASSAFS superblock" in before,
          "an unformatted partitioned disk was not reported cleanly:\n" + before[-2500:])

    formatted = machine.cmd("cassafs format demo", 25.0)
    check("formatted 20 block(s), 9 record(s)" in formatted,
          "format did not report its geometry:\n" + formatted[-2500:])
    check("format      : OK" in formatted, "format did not complete:\n" + formatted[-2500:])

    info = machine.cmd("cassafs info")
    check("CASSAFS format 1" in info, "info did not report the format version:\n" + info[-2500:])
    check("superblock A: valid, generation 1" in info, "superblock A was not reported:\n" + info[-2500:])
    check("superblock B: valid, generation 2" in info, "superblock B was not reported:\n" + info[-2500:])
    check("active      : B (both copies valid)" in info, "active superblock selection is wrong:\n" + info[-2500:])
    check("5 inode(s), 3 dir(s), 2 file(s), 158 data byte(s)" in info,
          "inode-tree counters are wrong:\n" + info[-2500:])

    verify = machine.cmd("cassafs verify")
    check("cassafs verify: PASS" in verify, "verify failed:\n" + verify[-2500:])
    check("every header and payload CRC32C OK" in verify,
          "verify did not check record CRC32C:\n" + verify[-2500:])
    check("bitmap agrees with log head 20" in verify,
          "free-map verification is wrong:\n" + verify[-2500:])

    cat = machine.cmd("cassafs cat /catalog/products.db")
    check("1001,Espresso,250" in cat and "1003,Water,150" in cat,
          "cat did not return the demo data:\n" + cat[-2500:])
    check("/catalog/products.db, 73 byte(s), CRC32C 0x3b60dc1d" in cat,
          "cat did not report the expected size/CRC:\n" + cat[-2500:])

    dump = machine.cmd("cassafs dump")
    check("/catalog/products.db" in dump and "/receipts/WELCOME.TXT" in dump,
          "dump did not show the inode tree:\n" + dump[-3000:])
    check("extent 0: logical 0, block 7, offset 0, length 73" in dump,
          "dump did not show the products.db extent:\n" + dump[-3000:])
    check("free-space map: 20 used / 16364 free of 16384" in dump,
          "dump did not show the free-space map:\n" + dump[-3000:])


def scenario_main() -> None:
    log("[main] format, verify, read back, host reader, reboot persistence")
    work = Path(tempfile.mkdtemp(prefix="cassa-cfs-main-"))
    disk = work / "cassafs.img"
    make_disk(disk)
    machine = Machine("format", disk)
    try:
        format_and_verify(machine)
        poweroff, code = machine.shutdown()
        check("clean shutdown complete" in poweroff, "shutdown did not complete:\n" + poweroff[-2000:])
        check(code == 0, "QEMU did not exit 0 after poweroff")
        log("      guest formatted, verified and shut down cleanly")
    finally:
        machine.close()

    outside = host_verify(disk)
    check("verify      : PASS" in outside, "host reader rejected the guest image:\n" + outside[-2500:])
    check("16384 total" in outside, "host reader saw the wrong volume size:\n" + outside[-2500:])
    cat = host_cat(disk, "/catalog/products.db")
    check("1001,Espresso,250" in cat, "host CAT did not return the demo data:\n" + cat[-2500:])
    check("73 byte(s), CRC32C 0x3b60dc1d" in cat, "host CAT size/CRC mismatch:\n" + cat[-2500:])
    log("      host reference reader verified the image and the demo payload")

    reboot = Machine("reboot", disk)
    try:
        info = reboot.cmd("cassafs info")
        check("5 inode(s), 3 dir(s), 2 file(s), 158 data byte(s)" in info,
              "the volume did not survive reboot:\n" + info[-2500:])
        verify = reboot.cmd("cassafs verify")
        check("cassafs verify: PASS" in verify, "verify after reboot failed:\n" + verify[-2500:])
        cat = reboot.cmd("cassafs cat /receipts/WELCOME.TXT")
        check("Welcome to Cassa POS." in cat, "the second demo file did not survive reboot:\n" + cat[-2500:])
        log("      volume and both demo files persisted across reboot")
    finally:
        reboot.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def scenario_fallback() -> None:
    log("[fallback] damaged superblock B falls back to A")
    work = Path(tempfile.mkdtemp(prefix="cassa-cfs-fallback-"))
    source = work / "source.img"
    disk = work / "fallback.img"
    make_disk(source)
    machine = Machine("prepare-fallback", source)
    try:
        machine.cmd("cassafs format demo", 25.0)
        _, code = machine.shutdown()
        check(code == 0, "preparation poweroff failed")
    finally:
        machine.close()
    shutil.copyfile(source, disk)
    with disk.open("r+b") as f:
        f.seek(SUPER_B + 200)
        f.write(b"\xff\xff\xff\xff\xff\xff\xff\xff")

    outside = host_verify(disk)
    check("active      : A (fallback)" in outside,
          "host reader did not fall back to superblock A:\n" + outside[-2500:])
    check("generation 2" not in outside.split("active")[0].split("superblock B")[-1],
          "host reader did not report the damaged B copy:\n" + outside[-2500:])

    machine = Machine("fallback", disk)
    try:
        info = machine.cmd("cassafs info")
        check("superblock A: valid" in info and "superblock B: INVALID" in info,
              "the damaged B copy was not detected:\n" + info[-2500:])
        check("active      : A (fallback; the other copy is damaged)" in info,
              "the kernel did not report A/B fallback:\n" + info[-2500:])
        verify = machine.cmd("cassafs verify")
        check("cassafs verify: PASS" in verify and "fallback" in verify,
              "fallback volume did not verify:\n" + verify[-2500:])
        log("      kernel and host reader both recovered from the damaged superblock")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def scenario_corruption() -> None:
    log("[corruption] a bad record payload is rejected by CRC32C")
    work = Path(tempfile.mkdtemp(prefix="cassa-cfs-corrupt-"))
    source = work / "source.img"
    disk = work / "corrupt.img"
    make_disk(source)
    machine = Machine("prepare-corrupt", source)
    try:
        machine.cmd("cassafs format demo", 25.0)
        _, code = machine.shutdown()
        check(code == 0, "preparation poweroff failed")
    finally:
        machine.close()
    shutil.copyfile(source, disk)
    offset = PART_OFFSET + (DATA_RECORD + 1) * BLOCK + 10
    with disk.open("r+b") as f:
        f.seek(offset)
        byte = f.read(1)
        f.seek(offset)
        f.write(bytes([byte[0] ^ 0xFF]))

    result = host_tool("verify", "--image", str(disk), "--partition", "1")
    check(result.returncode != 0, "host reader accepted a corrupted record")
    check("BadCrc" in result.stdout + result.stderr,
          "host reader did not name the CRC failure:\n" + result.stdout + result.stderr)

    machine = Machine("corrupt", disk)
    try:
        verify = machine.cmd("cassafs verify")
        check("CRC32C mismatch" in verify,
              "the kernel did not report the CRC failure:\n" + verify[-2500:])
        check("cassafs verify: PASS" not in verify,
              "the kernel accepted a corrupted record:\n" + verify[-2500:])
        check("cassafs verify: FAIL" in verify,
              "the kernel did not print a failed verdict:\n" + verify[-2500:])
        log("      corrupted payload rejected by both kernel and host reader")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def scenario_absence() -> None:
    log("[absence] no disk: report the absence, still pass self-tests")
    machine = Machine("absence", None, disk=False)
    try:
        info = machine.cmd("cassafs info")
        check("no block device; attach a disk with partition 1" in info,
              "the no-disk path was not reported:\n" + info[-2500:])
        verify = machine.cmd("cassafs verify")
        check("no block device" in verify and "cassafs verify: PASS" not in verify,
              "verify claimed success without a disk:\n" + verify[-2500:])
        selftest = machine.cmd("selftest")
        check("self-tests: PASS" in selftest,
              "the kernel self-test did not pass without a disk:\n" + selftest[-2500:])
        log("      absence reported; kernel self-tests PASS")
    finally:
        machine.close()


def scenario_screenshot() -> None:
    log("[screenshot] CASSAFS dashboard")
    work = Path(tempfile.mkdtemp(prefix="cassa-cfs-shot-"))
    disk = work / "shot.img"
    make_disk(disk)
    machine = Machine("screenshot", disk)
    try:
        machine.cmd("cassafs format demo", 25.0)
        machine.cmd("cassafs viz 5", 15.0)
        shot = SHOT_DIR / "phase41-cassafs.png"
        ppm = machine.dir / "cassafs-viz.ppm"
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
    for required in (KERNEL, HOST_TOOL):
        if not required.exists():
            log(f"missing {required}; run `zig build` first")
            return 2
    if not Path(QEMU).exists():
        log(f"missing QEMU ({QEMU}); set QEMU=...")
        return 2

    scenarios = [
        ("main", scenario_main),
        ("fallback", scenario_fallback),
        ("corruption", scenario_corruption),
        ("absence", scenario_absence),
        ("screenshot", scenario_screenshot),
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
            scenario()
            log(f"[ok]   {name}")
    except Failure as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 41 CASSAFS evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
